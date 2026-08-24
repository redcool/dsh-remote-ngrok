# dsh-remote — DSH 远程访问工具集（独立可复用模块）

> 通过 ngrok 让**手机/任意浏览器**访问本机 DSH web 的完整方案：**一键启动脚本 + 反向代理源码 + 完整手册**。
> 可独立提交 git 仓库，作为子模块/子目录被其他项目引用。
> 适用场景：iOS 16.4 等旧浏览器、中国大陆网络环境（Tailscale/ngrok OAuth 等不可用）。

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

## 2. 环境准备

| 依赖 | 说明 | 安装（Windows） |
|---|---|---|
| **Node.js** | proxy 用 Node 运行（http-proxy） | https://nodejs.org/zh-cn/download 下载 **LTS 版**（如 20.x/22.x）→ 安装（勾选 "Add to PATH"）→ 新开终端验证 `node -v` |
| git | 拉取本模块 | https://git-scm.com/download/win |
| ngrok | 公网隧道（v3.39+，**手动下载，见 §4**） | — |
| npm 依赖 | proxy 的 http-proxy | 见 §5 步骤 ① |

> Node.js 安装后**需重开终端**（PATH 才生效）。proxy 兼容任意现代 Node（v14+ 即可，建议 LTS）。

## 3. 目录结构

| 文件 | 作用 |
|---|---|
| `README.md` | 本文件（完整手册：环境/部署/使用/验证/排障） |
| **`start_remote_all.bat/.ps1`** | **一键拉起全链路**（proxy+ngrok+dsh web，幂等：在跑的不重启）——**日常用这个** |
| `proxy/server.js` | 反向代理：cookie 会话认证 + polyfill 注入 + Origin 剥离（需环境变量，见 §5 ②） |
| `proxy/package.json` | proxy 依赖声明（`npm install http-proxy`） |
| `ngrok_token.txt.temp` | **ngrok authtoken 模板**：复制为 `ngrok_token.txt` 后填入自己的 token（见 §4 ②） |
| `ngrok/` | **运行目录（git 忽略）**：ngrok.exe 首次使用自行下载放入；运行时生成日志 |

## 4. ngrok 下载与配置

> **ngrok.exe（约 30MB）与 authtoken 不随仓库提交**。

**① 下载 ngrok.exe（Windows x64，v3.39+）**，解压出 `ngrok.exe` 放入本目录 `ngrok\`：
```
https://bin.equinox.io/c/bNyj1mQVY4c/ngrok-v3-stable-windows-amd64.zip
```
- 为什么必须 v3.39+：winget 渠道的 v3.3.1 **读不懂新版 `version:"3"` 配置文件**——启动即秒退。⚠ 别用 PATH 里那个 winget 版。
- 官方下载页（备选）：https://ngrok.com/download

**② 配置 authtoken**（`start_remote_all.bat` 启动时自动处理）：
- 复制 `ngrok_token.txt.temp` → 改名 `ngrok_token.txt` → 填入你的 token（https://dashboard.ngrok.com → Your Authtoken）
- 或直接运行 `start_remote_all.bat`：检测到缺失/无效 token 时**交互询问**，粘贴即保存
- token 通过 `NGROK_AUTHTOKEN` 环境变量传给 ngrok（优先于全局配置，**不改动你机器上的 ngrok.yml**）

**③ 静态域名（可选，推荐）**：免费随机域名重启会变。正式使用申请静态域名：dashboard.ngrok.com → Domains → New Domain（如 `dsh-xxx.ngrok.app`）→ 脚本顶部 `$ngrokHost` 改为该域名（trusted-host 自动同步），此后 URL 永久不变。

## 5. 首次使用（部署）

```powershell
# ① 安装 proxy 依赖（只需一次；前提：Node.js 已装）
cd proxy
npm install http-proxy

# ② 配置 proxy 登录密码（必做，否则 proxy 拒绝启动；环境变量持久化）
setx DSH_PROXY_USER "dsh"
setx DSH_PROXY_PASSWORD "换成你的强密码"

# ③ 下载 ngrok.exe（§4①）→ 配置 authtoken（§4②）
# ④ 检查本机 dsh 安装位置（start_remote_all.ps1 顶部 $dshtmWebDir / $dshtmHome）
#    申请静态域名后改 $ngrokHost（§4③）

# ⑤ 一键拉起
# 双击 start_remote_all.bat
```

**登录**：浏览器打开 ngrok URL → 登录页输入 `DSH_PROXY_USER / DSH_PROXY_PASSWORD`。

> 💡 若浏览器**之前登录过**（cookie 或记住的 basic 凭据有效）→ 不弹登录页是正常现象，直接放行。
> 💡 调试旧状态干扰用**无痕窗口**测试：无痕不带任何缓存/凭据，必弹登录页，走全新流程。

## 6. 日常使用

| 操作 | 做法 |
|---|---|
| 开机/断链后拉起 | 双击 `start_remote_all.bat`（幂等：已在跑的不重启，页面不断线） |
| 只重启 dsh web | 重跑 `start_remote_all.bat` 即可（trusted-host 不匹配时会自动重启 dsh web） |
| 查当前隧道 URL | `(Invoke-RestMethod http://127.0.0.1:4040/api/tunnels).tunnels[0].public_url` |
| 换静态域名 | 改脚本 `$ngrokHost` → 重跑一键脚本 |

## 7. 验证命令（本机快速自检）

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

## 8. 故障排查表

| 现象 | 根因 | 处理 |
|---|---|---|
| 浏览器反复弹 basic 登录框 | basic-auth 对 WS 无效 → WS 重连 401 | 已由 cookie 会话根治；老标签清缓存/关掉重开 |
| 输入框发消息报 `abortSignal.any` / 页面空白 | iOS < 17.4 缺 AbortSignal.any 等 API | polyfill 注入（§1 表 #2）；**确认走 proxy 而非直连 3080** |
| 页面能开但工作区/会话为空 | ① content-length bug：注入 polyfill 后 HTML 变长但旧 content-length 未更新 → 浏览器截断；② fence 403 拦带 Origin 的数据请求 | ① proxy 已修：注入后重算 content-length；② proxy 已修：剥离 Origin 头 |
| 添加工作区报 `transport failure for /api/host.pickDirectory: HTTP 403` | fence 要求 Origin 与 Host 精确同源，代理场景误判 | 已修（剥离 Origin 头）；Host 白名单校验仍在，安全保留 |
| ERR_NGROK_3200 / endpoint offline | ngrok 进程退出或被杀，或安装目录被删除 | 重跑 `start_remote_all.bat`（自动拉起）；exe 没了就重下（§4①） |
| ngrok 启动即秒退 | 用了 v3.3.1 旧版（读不懂 v3 配置） | 换 `ngrok/ngrok.exe` v3.39+（§4①） |
| 本机能看、手机/远程看不到 | 浏览器旧缓存/旧凭据 | 无痕窗口测试；清该站点缓存 |
| 登录页不弹（进了 DSH） | 浏览器 cookie/basic 凭据仍有效——正常行为 | 无需处理；想强制重登：清站点数据或换无痕 |

## 9. proxy 实现要点（server.js 设计备忘）

- **会话**：内存 Map（token→过期时间），Set-Cookie `dsh_session` HttpOnly SameSite=Lax，24h。
- **兼容 basic-auth**：`Authorization: Basic <user:pass>` 命中直接放行（浏览器记住的旧凭据也能进）。
- **响应注入**：`selfHandleResponse:true` 手动回写；HTML 缓冲 → `</head>` 前插 `<script>` polyfill → **重算 `content-length`**（否则截断）；其他类型原样 pipe。
- **WS 转发**：`upgrade` 事件 → 校验 cookie（无 → 403 应用层拒绝，不带 WWW-Authenticate，不弹框）→ `proxy.ws` 转发；同样剥离 Origin。
- **polyfill 内容**：AbortSignal.any/timeout、Promise.withResolvers、URL.canParse、Object.hasOwn、Array.at/findLast/findLastIndex。
- **密码不硬编码**：`DSH_PROXY_USER` / `DSH_PROXY_PASSWORD` 环境变量读取，未设置则拒绝启动。

## 10. 安全提醒

- 密码**不要硬编码**在代码或脚本里（`server.js` 从环境变量读取；`start_remote_all.ps1` 里默认凭据仅供本地首次使用，请 setx 换成强密码）。
- proxy 仅监听 127.0.0.1；公网唯一入口是 ngrok（TLS）。
- **不要在 ngrok 侧加 basic-auth**（traffic policy）——对 WebSocket 无效且会弹窗，认证统一由 proxy 的 cookie 会话负责。
- fence 的 **Host 白名单校验保留**（`--trusted-host` 只放行指定域名），剥离 Origin 不降低安全。
- DSH 环境含 API key 等敏感配置：仅给信任的人提供访问，URL 不要公开张贴。

## 11. 提交说明

- `.gitignore` 已忽略：`ngrok/`（整个目录）、`ngrok_token.txt`（真 token）、`proxy/node_modules/`。
- 提交的模板：`ngrok_token.txt.temp`（clone 后复制为 `ngrok_token.txt` 填自己的 token）。
- proxy 依赖由 `package.json` 声明，clone 后 `cd proxy && npm install http-proxy`。

## 12. 变更记录

- **v4（2026-08-24）**：合并手册与 README 为单文档；补 Node.js 安装说明；`start_dsh_web_remote.*` 删除（并入一键脚本）；ngrok authtoken 走 `ngrok_token.txt` + 交互询问流程；`ngrok/` 整目录 git 忽略。
- v3：解决 content-length 截断 bug + 剥离 Origin 头绕开 fence 严格同源判定 + 扩展 polyfill → 手机/远程全功能验证通过。密码改环境变量配置。
- v2：ngrok basic-auth → proxy cookie 会话；polyfill 注入；修复 http-proxy selfHandleResponse 双写头崩溃。
- v1：初始方案探索（traffic policy basic-auth 语法 5 连踩坑；`--basic-auth` flag 已废弃）。
- 背景：iOS 16.4 无 `AbortSignal.any` + ngrok basic-auth 对 WS 弹窗 + Tailscale 中国大陆不可登录 → 自建 proxy 层解决全部三问题。