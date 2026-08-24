# ngrok 远程访问 DSH（完整手册）

> 让手机/任意浏览器通过公网访问这台机器的 DSH web。
> 链路：`手机浏览器 → ngrok(TLS) → dsh-proxy(认证+兼容层) → dsh web → mcp server → bridge`
> 适用：iOS 16.4 等旧浏览器、中国大陆网络环境（Tailscale/ngrok OAuth 等不可用时）。

---

## 1. 架构总览

```
手机/电脑浏览器（任意设备）
   │  https://<ngrok-url>（公网，TLS 由 ngrok 提供）
   ▼
ngrok 隧道  (本机监控 http://127.0.0.1:4040)
   │  转发到 http://127.0.0.1:3200（仅本机，公网不可直连）
   ▼
dsh-proxy  (proxy/server.js，Node 反向代理)
   │  ① Cookie 会话认证（登录页 /__login，不再弹 basic 框）
   │  ② HTML 注入 polyfill（AbortSignal.any/timeout 等，兼容 iOS < 17.4）
   │  ③ 剥离 Origin 头（绕开 dsh web 的 browser-trust 严格同源校验）
   │  ④ WebSocket 握手转发（带 cookie → 放行；无 cookie → 403 应用层拒绝）
   ▼
dsh web  (127.0.0.1:3080，`dsh web --trusted-host <ngrok域名>` 启动)
   ▼
mcp server → bridge_godot / bridge_unity
```

**为什么要 dsh-proxy 这一层？（三层理由）**

| # | 问题 | 解法 |
|---|---|---|
| 1 | ngrok basic-auth 对 **WebSocket 无效**（WS 握手协议禁止自定义 Authorization 头，只认 cookie）→ dsh 实时通道每次重连 401 → **手机反复弹 basic 登录框** | proxy 改 **cookie 会话**：登录一次，WS 带 cookie 全通，永不弹窗 |
| 2 | dsh 前端用 `AbortSignal.any()`（仅 iOS 17.4+）→ 老手机（iOS 16.4）启动/发消息崩溃 | proxy 在 HTML `</head>` 前**注入 polyfill**，不用改 dsh 任何文件 |
| 3 | dsh web 的 browser-trust fence 要求带 Origin 的请求 **Origin 与 Host 精确同源**；经代理后判定误伤 → 工作区/会话数据接口 403 | proxy **转发时剥离 Origin 头** → fence 走"无 Origin → 放行"分支；**Host 白名单校验仍生效，安全不降级** |

---

## 2. 组件与配置

| 组件 | 位置 | 端口 | 说明 |
|---|---|---|---|
| ngrok | 自行安装 `ngrok.exe`（authtoken 在 `%LOCALAPPDATA%\ngrok\ngrok.yml`） | 4040 监控 / 公网 443 | 公网入口 |
| dsh-proxy | 本目录 `proxy/server.js` | 127.0.0.1:3200 | 依赖 http-proxy |
| dsh web | 本机 `dsh web`（需设 `DSH_HOME` 指向你的 .dsh） | 127.0.0.1:3080 | 仅绑本机 |
| 启动脚本 | 本目录 `start_dsh_web_remote.ps1/.bat` | — | 杀旧 3080 → 带 trusted-host 重启 |

**登录凭据**：`<DSH_PROXY_USER>` / `<DSH_PROXY_PASSWORD>`（proxy 登录页；通过环境变量配置，见 README）

**当前隧道 URL**：`https://<ngrok-url>`（免费随机域名，重启可能变化——见 §7 固定域名）

---

## 3. 启动流程（重启电脑后按序执行）

```powershell
# ① dsh-proxy（后台保持）
cd proxy
node server.js          # → listening on http://127.0.0.1:3200 -> 127.0.0.1:3080

# ② ngrok 隧道（后台保持，URL 显示在 "Forwarding" 行）
ngrok http 3200

# ③ dsh web：若未运行 / URL 变化，双击 start_dsh_web_remote.bat
#    脚本自动停旧实例、带 --trusted-host <ngrok域名> 重启（断页面 2~3 秒，会话持久化自动恢复）
```

**查当前隧道 URL**：
```powershell
(Invoke-RestMethod http://127.0.0.1:4040/api/tunnels).tunnels[0].public_url
```

**访问**：浏览器打开 https://<ngrok-url> → 登录页（用户名/密码）→ 进入与电脑同一 DSH 环境。

> 💡 若浏览器**之前登录过**（cookie 或记住的 basic 凭据有效）→ 不弹登录页是正常现象，直接放行。
> 💡 调试旧状态干扰用**无痕窗口**测试：无痕不带任何缓存/凭据，必弹登录页，走全新流程。

---

## 4. 验证命令（本机快速自检）

```powershell
# ① 无 cookie → 401（proxy 登录页）
curl.exe -s -o NUL -w "HTTP %{http_code}`n" https://<ngrok-url>

# ② 登录 → 302 + Set-Cookie
curl.exe -s -c $env:TEMP\c.txt -o NUL -X POST -d "u=<USER>&p=<PASSWORD>" https://<ngrok-url>/__login

# ③ 带 cookie 首页 → 200，且含 polyfill
curl.exe -s -b $env:TEMP\c.txt https://<ngrok-url> | Select-String 'AbortSignal\.any'

# ④ fence 放行验证（带 Origin 应不再 403）
curl.exe -s -b $env:TEMP\c.txt -H "Origin: https://<ngrok-url>" -w "`n%{http_code}`n" http://127.0.0.1:3200/api/status
```

---

## 5. 故障排查表

| 现象 | 根因 | 处理 |
|---|---|---|
| 浏览器反复弹 basic 登录框 | basic-auth 对 WS 无效 → WS 重连 401 | 已由 cookie 会话根治；老标签清缓存/关掉重开 |
| 输入框发消息报 `abortSignal.any` / 页面空白 | iOS < 17.4 缺 AbortSignal.any 等 API | polyfill 注入（§1 表 #2）；确认走 proxy 而非直连 3080 |
| 页面能开但工作区/会话为空 | ① **content-length bug**：注入 polyfill 后 HTML 变长但旧 content-length 未更新 → 浏览器截断页面 → 前端崩；② fence 403 拦带 Origin 的数据请求 | ① proxy 已修：注入后重算 content-length；② proxy 已修：剥离 Origin 头 |
| 添加工作区报 `transport failure for /api/host.pickDirectory: HTTP 403` | fence 要求 Origin 与 Host 精确同源，代理场景误判 | 已修（剥离 Origin 头）；Host 白名单校验仍在，安全保留 |
| ERR_NGROK_3200 / endpoint offline | ngrok 进程退出或被杀，或安装目录被删除 | 重启 ngrok（目录没了就重装）；authtoken 在 `%LOCALAPPDATA%\ngrok\` 不受影响 |
| ngrok 重启后 URL 变了 | 免费随机域名 | 更新脚本 `$ngrokHost` → 重启 dsh web；正式用静态域名（§7） |
| 本机能看、手机/远程看不到 | 浏览器旧缓存/旧凭据 | 无痕窗口测试；清该站点缓存 |
| 登录页不弹（进了 DSH） | 浏览器 cookie/basic 凭据仍有效——正常行为 | 无需处理；想强制重登：清站点数据或换无痕 |

---

## 6. proxy 实现要点（server.js 设计备忘）

- **会话**：内存 Map（token→过期时间），Set-Cookie `dsh_session` HttpOnly SameSite=Lax，24h。
- **兼容 basic-auth**：`Authorization: Basic <user:pass>` 命中直接放行（浏览器记住的旧凭据也能进）。
- **响应注入**：`selfHandleResponse:true` 手动回写；HTML 缓冲 → `</head>` 前插 `<script>` polyfill → **重算 `content-length`**（否则截断）；其他类型原样 pipe。
- **WS 转发**：`upgrade` 事件 → 校验 cookie（无 → 403 应用层拒绝，不带 WWW-Authenticate，不弹框）→ `proxy.ws` 转发；同样剥离 Origin。
- **polyfill 内容**：AbortSignal.any/timeout、Promise.withResolvers、URL.canParse、Object.hasOwn、Array.at/findLast/findLastIndex。
- **密码不硬编码**：`DSH_PROXY_USER` / `DSH_PROXY_PASSWORD` 环境变量读取，未设置则拒绝启动。

---

## 7. 进阶：固定 URL（推荐正式用）

免费随机域名重启会变。正式使用申请**静态域名**（免费账号送 1 个）：

1. 登录 https://dashboard.ngrok.com → **Domains** → New Domain（如 `dsh-xxx.ngrok.app`）
2. 启动绑定：`ngrok http 3200 --url https://dsh-xxx.ngrok.app`
3. `start_dsh_web_remote.ps1` 的 `$ngrokHost` 改为静态域名，重启 dsh web
4. 此后 URL 永久不变，trusted-host 只配一次

**建议**：三个常驻进程（proxy/ngrok/dsh web）可封装成一个 bat 一键拉起（依次启动、等端口就绪、输出 URL）。

---

## 8. 安全注意事项

- **不要在 ngrok 侧加 basic-auth**（traffic policy）——对 WS 无效且弹窗；认证统一由 proxy 的 cookie 会话负责。
- proxy 仅监听 127.0.0.1；公网唯一入口是 ngrok（TLS）。
- fence 的 **Host 白名单校验保留**（`--trusted-host` 只放行指定域名），剥离 Origin 不降低安全。
- 密码用环境变量配置，**不要提交到公开仓库**。
- DSH 环境含 API key 等敏感配置：仅给信任的人提供访问，URL 不要公开张贴。

---

## 9. 变更记录

- **v3（完成态）**：解决 content-length 截断 bug + 剥离 Origin 头绕开 fence 严格同源判定 + 扩展 polyfill → 手机/远程全功能（工作区/会话/发消息/添加工作区）验证通过。密码改为环境变量配置（可提交 GitHub）。
- v2：ngrok basic-auth → proxy cookie 会话；polyfill 注入；修复 http-proxy selfHandleResponse 双写头崩溃。
- v1：初始方案探索（traffic policy basic-auth 语法 5 连踩坑——`credentials` 为 `"user:pass"` 字符串数组；`--basic-auth` flag 已废弃）。
- 背景：iOS 16.4 无 `AbortSignal.any` + ngrok basic-auth 对 WS 弹窗 + Tailscale 中国大陆不可登录 → 自建 proxy 层解决全部三问题。