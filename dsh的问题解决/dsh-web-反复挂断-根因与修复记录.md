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
