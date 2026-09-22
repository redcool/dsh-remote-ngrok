# dsh web 反复挂断问题——根因定位与修复记录

> 日期：2026-09-19 ~ 2026-09-20
> 状态：根因已定位，补丁已应用，待长期验证

---

## 一、问题现象

dsh web（3080 端口）自 2026-09-17 起反复"挂断"，已发生多次：

| 时间 | dsh PID | 运行时长 | 备注 |
|---|---|---|---|
| 09-17 18:17 → 09-18 14:49 | 22488 | ~20h | 用户手动重启 |
| 09-18 14:49 → 09-19 ~01:00 | 41472 | ~10h | 单 gpt6 会话挂机时死 |
| 09-19 15:44 → 09-19 22:13 | 30380 | ~6.5h | 死前日志首次捕获（8082 错误风暴） |
| 09-19 22:13 → 09-20 15:05 | 14608 | ~17h | **首次捕获完整崩溃堆栈** |

共同特征：
- 挂断前都有**会话在活跃工作**（尤其是 codex/gpt6 会话），空闲时反而不挂
- 之前表面看是"安静退出"（无崩溃记录、exit 0），**实为未捕获异常崩溃**（当时只看了 stdout 日志，漏掉了 stderr 堆栈）

---

## 二、最终根因（2026-09-20 确认）

2026-09-20 15:05 dsh（14608）挂断时，cmd 窗口捕获到**完整崩溃堆栈**：

```
node:fs:561
  return binding.open(
                 ^
System.Management.Automation.RemoteException
Error: ENOENT: no such file or directory, open 'C:\Users\Admin\AppData\Local\Temp\dsh-subprocess-qqGg7B\dsh-subprocess-14608-1-b468b8a1cdea-stderr.log'
    at openSync (node:fs:561:18)
    at OutputCollector.spillAll (file:///H:/AI/dsh/node_modules/@deepseek-ai/dsh-subprocess-local/lib/runner-launch-COYGu0Dl.js:766:19)
    at OutputCollector.push (.../runner-launch-COYGu0Dl.js:742:75)
    at Socket.<anonymous> (.../runner-launch-COYGu0Dl.js:981:14)
    at Socket.emit (node:events:509:28)
    ...
Node.js v24.15.0
```

### 崩溃机制（四点链）

1. **dsh 用 `OutputCollector` 收集子进程输出**：子进程（codex/gpt6 等）的 stderr 超过内存上限时触发 "spill"（落盘到 `%TEMP%\dsh-subprocess-XXX\` 目录）
2. **临时目录被系统清理**：dsh 长期运行（>10h）期间，Windows 临时文件清理/存储感知会删掉 `dsh-subprocess-*` 目录（崩溃时该目录已不存在，只剩新进程的目录）
3. **打开文件无保护**：`spillAll()` 用 `openSync(path, "wx", 384)` **同步打开、无 try/catch** → 目录不存在 → 抛 `ENOENT`
4. **异常逃逸导致宿主崩溃**：该异常抛在 **Socket 'data' 事件回调**（异步上下文）→ Node `uncaughtException` 默认行为 = 打印堆栈并退出进程 → **整个 dsh web 崩溃**

### 与现象的对应关系

- 为什么"有会话工作（大量输出）才挂"：只有输出量超阈值才触发 spill → 空闲时路径不经过，不崩溃
- 为什么 codex/gpt6 最高发：其输出量大（skill 报错、命令输出、MCP 错误），最易超阈值
- 为什么之前查不到崩溃：monitor 只记录 stdout/PID；崩溃堆栈在 stderr，被 launcher 重定向后此前未捕获

---

## 三、叠加因素（次要，已另行处理）

### 1. codex config 里的死 MCP 配置（unityMCP / 8082）

`C:\Users\Admin\.codex\config.toml` 曾有：

```toml
[mcp_servers.unityMCP]
url = "http://127.0.0.1:8082/mcp"
```

- 该服务是"即开即用"型，**不常驻**；codex 每次会话启动都尝试连 8082 → 失败
- 死前日志 250 行中 `Transport channel closed @8082` 出现 **87 次**（错误风暴）
- 注意：SimpleMcpServer 实际端口是 **45678**（git 历史证明从未用过 8082），unityMCP 配置与 SimpleMcpServer 无关

**处理**：已注释禁用（保留备份 `config.toml.bak-unitymcp`）。需要时临时启用。

### 2. codex 插件升级

- dsh-subagent-codex `0.0.1-rc.1` → `0.1.5-rc.2`（已装，待用户重启 dsh 后验证）
- 排查过其源码：插件本身无 kill 宿主行为（异常封装在 `CodexRunFailure`），主因确认是 spill 崩溃

---

## 四、修复：dsh-subprocess-local 补丁

### 修改文件

`H:\AI\dsh\node_modules\@deepseek-ai\dsh-subprocess-local\lib\runner-launch-COYGu0Dl.js`
（崩溃堆栈指向的正是该文件）

### 补丁内容（两处）

**① `spillAll()` 打开 spill 文件加防御**：目录被删时自动重建重试；仍失败则降级为纯内存模式，**绝不抛异常逃逸**：

```js
if (this.spillFd === void 0) {
    this.spillFile = join(this.spillDir, `dsh-subprocess-${process.pid}-${++spillCounter}-${randomBytes(6).toString("hex")}-${this.label}.log`);
    try {
        this.spillFd = openSync(this.spillFile, "wx", 384);
    } catch (error) {
        // Spill dir may have been cleaned up by the OS (Temp cleanup).
        // Recreate it once and retry; if that still fails, degrade to
        // in-memory mode: never let a spill write-back crash the host.
        try {
            mkdirSync(this.spillDir, { recursive: true });
            this.spillFd = openSync(this.spillFile, "wx", 384);
        } catch {
            this.spillDisabled = true;
            this.spillFile = void 0;
            return;
        }
    }
    ...
}
```

**② import 增加 `mkdirSync`**（node:fs）。

**③ 固化已存在文件写入循环与主 `writeSync` 的 try/catch**。

### 验证

- `node --check` 通过
- 备份：`runner-launch-COYGu0Dl.js.bak-spill`
- **注意**：补丁对运行中的 dsh 进程无效（模块已加载进内存），需重启 dsh 生效

---

## 五、监控与自动恢复体系（本次建设的完整链路）

| 组件 | 路径 | 作用 |
|---|---|---|
| watchdog 脚本 | `dsh-remote\watch-dsh-restart.ps1` | 每 5s 探测 3080；空闲 15s 确认后自动拉起；单实例 mutex；3 次/10min 上限→30min 冷却 |
| watchdog 入口 bat | `dsh-remote\watchdog.bat` | 手动双击启动（最小化窗口） |
| 登录自启 | `Startup\dsh-watchdog.cmd` | 登录自动启动 watchdog |
| launcher 集成 | `start_remote_all.ps1` | 每次启动确保 watchdog 在跑；dsh 退出/死时打停止标记（`=== dsh web stopped ===`） |
| dsh 运行日志 | `dsh-remote\logs\dsh-web.log`（+ .prev.log 轮转） | 每秒时间戳捕获 dsh stdout 全部行（含 codex stderr 转发） |
| watchdog 日志 | `dsh-remote\watchdog.log` | 记录启动/检测/拉起/恢复全过程 |

### 已实证的自动恢复（watchdog 两次成功拉起）

```
[2026-09-19 22:13:45] 检测 3080 空闲 → 拉起 start_remote_all.bat → 22:13:55 3080 恢复 (PID 14608)
[2026-09-20 15:05:22] 检测 3080 空闲 → 拉起 start_remote_all.bat → 15:05:38 3080 恢复 (PID 42368)
```

**从检测到恢复约 10 秒**。用户无感恢复。

---

## 六、结论与待办

### 结论

- **主因（确认）**：dsh-subprocess-local 的 spill 落盘在临时目录被清理时抛未捕获异常 → 崩溃宿主。补丁已使其不可崩溃。
- **次因（已处理）**：codex 死 MCP 配置（8082）造成错误风暴，已禁用。
- watchdog 自动恢复体系工作正常，dsh 挂后 10s 内自动上线。

### 待办 / 验证清单

- [ ] 用户重启 dsh，确认补丁代码已被加载（新 PID 的 spill 逻辑带防御）
- [ ] 用 gpt6/codex 会话工作 ≥1 晚，观察 `dsh-web.log` / `watchdog.log` 是否还有挂断
- [ ] 若再有挂断，检查新崩溃是否仍指向 spill（预期已消失）；若指向他处，按新堆栈继续定位
- [ ] 长期：建议向上游 dsh 提 issue/PR（spill 打开文件需 try/catch + 目录重建），本补丁是本地先行修复

---

# 附：手机 4G 远程访问变慢——定位与修复（2026-09-22）

## 一、现象

dsh 重启后不再挂断（spill 补丁生效，dsh 19936 连续稳定运行），但**手机浏览器（4G）访问 dsh-remote 明显变慢**。

## 二、链路测速（实测数据）

链路：手机 4G → ngrok(日本 jp 节点) → dsh-proxy(3200) → dsh web(3080)

| 项目 | 本地 3200 | 经 ngrok 公网 | 结论 |
|---|---|---|---|
| 首字节 TTFB | 2ms | 250~460ms | ngrok 日节点 RTT 正常（本机环回） |
| 740KB JS 下载 | 27ms / 27MB/s | 1.1s / 665KB/s | ngrok free 带宽有限（~5Mbps） |
| 前端总资源 | 4.5MB（91 个文件，JS 3.39MB） | 4.5MB 明文 | **压缩前全部明文传输** |

## 三、根因

1. **proxy 无差别剥离 Accept-Encoding**：`proxy/server.js` 为做 iOS polyfill 注入，对所有请求执行 `delete req.headers["accept-encoding"]` → dsh 上游对静态资源也返回明文，**前端 4.5MB 零压缩**。
2. **dsh 上游实际支持 gzip**：同一 740KB JS，带 `Accept-Encoding: gzip` 时返回 **209KB（-72%）**。
3. ngrok free 计划带宽有限（实测 ~665KB/s ≈ 5.3Mbps）+ 日本节点 RTT 叠加，明文 4.5MB 在手机上自然明显卡。

## 四、修复（proxy/server.js）

改为**仅 HTML 请求剥离 Accept-Encoding**（polyfill 注入需要明文 HTML），静态资源（js/css/woff/ttf/svg/png/ico 等）保留压缩，让 dsh 上游 gzip/br 后原样透传。

```js
const isStaticAsset = /\.(js|css|woff2?|ttf|svg|png|jpe?g|gif|ico|webmanifest|map)(\?|$)/i.test(u.pathname);
if (!isStaticAsset) delete req.headers["accept-encoding"];
```

## 五、修复后实测（已生效）

| 项目 | 修复前 | 修复后 |
|---|---|---|
| 静态资源大小 | 740KB 明文 | **209KB gzip（-72%）** |
| 经 ngrok 公网下载 | 1.1s / 665KB/s | **0.56s**（流量 -72%） |
| HTML 页面 | 明文 + polyfill 注入 | 不变（安全） |

- proxy 已热重启（PID 36764，旧 28128 已停），**dsh 3080 未动、会话无中断**
- `node --check` 通过

## 六、剩余说明

- ngrok free 带宽上限（~5Mbps）仍是非热点文件（如大图）的固有瓶颈；若要更快可考虑付费 ngrok / 自建 frp / Cloudflare Tunnel
- 手机浏览器首次首屏仍会拉 ~4.5MB（压缩后 ~1.3MB），二次访问有缓存会明显变快
- 若手机端仍慢：优先检查 4G 信号；其次可尝试把 ngrok region 换成 ap（`ngrok http 3200 --region=ap ...`）
## 七、9/22 追加审核：发现并修复复合 bundle 漏压缩 + 验证 2 分钟重试补丁生效

### 1) 复合 bundle 漏压缩（二次修复，当日补）

首屏实际引用多个复合 JS bundle：`/plugins/??@deepseek-ai/…/client.js&rev=…`——URL 里 `?` 使
`new URL(req.url).pathname` 截断为 `/plugins/`（无扩展名），首版正则按 pathname 判断把
这类请求误判为 HTML → 剥离 Accept-Encoding → 复合 bundle 也明文传输（漏压缩）。

**修复**：判定改用完整 `req.url`（含 query），匹配 `.js/.mjs/.cjs/.css/woff/ttf/svg/png…`
扩展名后随 `? , &` 或行尾即视为静态资源。

实测（修复后）：`/plugins/??…client.js&rev=…` → `200 + Content-Encoding: gzip` ✅
HTML 根页仍明文 + polyfill 注入正常 ✅（见下方 3 的完整链路验证）

### 2) dsh-remote 复核结论（2026-09-22）

- **git 安全**：.gitignore 已排除 config.json（含 ngrok token）、proxy/dsh_token.txt、ngrok/、proxy/node_modules——机密不入库 ✅
- **watchdog**：PID 41800 自 9/19 常驻运行，单实例锁正常（多开自动退让）；9/19 22:13 与 9/20 15:05 两次自动恢复均有日志 ✅
- **launcher**：proxy 与 dsh web 均强制重启保证新代码生效；dsh web 前台阻塞、关窗即关 dsh 符合预期 ✅
- **proxy 认证**：cookie 会话 24h + 失败 5 次延迟 1s 防爆破 + timingSafeEqual + 每请求读 dsh_token.txt 换票（token 轮换无需重启 proxy）✅

### 3) 2 分钟自动重试补丁——实证生效（回应"2 会话未完成没重试"）

结论：**补丁已生效，9/21 白天的失败会话发生在补丁就位/重启之前，属预期行为。**

实证（会话日志 dump，时间为 UTC，北京 = +8）：
- 9/21 白天 turn 59-65 过载失败（15:04-18:55 北京）——**早于补丁写入（18:48）与 dsh 重启（19:19）**，旧进程无补丁 → 不重试 ⇒ 符合预期
- **9/21 19:30（dsh 重启后）turn 66 过载**：日志记录 `llm/retry delayMs=120000`（正好 2 分钟）→ 19:32 `llm/retry-started` → **19:34 turn 完成（重试成功）** ✅
- 9/21 19:47 会话（239d79ab）另有 2 次 llm/retry ✅
- `sessionProjections llmRetry` 键正确持久化（重试计数可跨断点续）

**结论**：2 分钟过载自循环工作正常。若想再看一次重试触发点，跑一个 codex 会话撞到
overload 时留意 `llm/retry` 事件即可；平时无过载不会触发（正常）。



