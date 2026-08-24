# dsh-remote — DSH 远程访问工具集（独立可复用模块）

> 通过 ngrok 让手机/任意浏览器访问本机 DSH web 的完整方案：**文档 + 一键启动脚本 + 反向代理源码**。
> 可独立提交 git 仓库，作为子模块/子目录被其他项目引用。
> 完整原理与排障见 [`ngrok-remote-dsh.md`](ngrok-remote-dsh.md)。

```
手机/浏览器 → ngrok(TLS) → dsh-proxy(认证+兼容层) → dsh web(127.0.0.1:3080) → mcp server → bridge
```

## 目录结构

| 文件 | 作用 |
|---|---|
| `README.md` | 本文件（模块说明 + ngrok 下载指引） |
| `ngrok-remote-dsh.md` | 完整手册：架构 / 启动 / 验证 / 排障 / 实现要点 |
| **`start_remote_all.bat/.ps1`** | **一键拉起全链路**（proxy+ngrok+dsh web，幂等：在跑的不重启）——**日常用这个** |
| `start_dsh_web_remote.ps1` | 只重启 dsh web 并携带 `--trusted-host <ngrok域名>` |
| `start_dsh_web_remote.bat` | 双击入口（调 ps1） |
| `proxy/server.js` | 反向代理：cookie 会话认证 + polyfill 注入 + Origin 剥离（**需先设环境变量**） |
| `proxy/package.json` | proxy 依赖声明（`npm install` 时安装 http-proxy） |
| `ngrok/` | **ngrok.exe 存放目录（git 忽略，首次使用自行下载放入，见下）** |

## 首次使用（部署）

```powershell
# 0) 安装 proxy 依赖（只需一次）
cd proxy
npm install http-proxy

# 1) 配置密码（proxy 登录页用；必做，否则 proxy 拒绝启动）
setx DSH_PROXY_USER "dsh"
setx DSH_PROXY_PASSWORD "换成你的强密码"

# 2) 下载 ngrok.exe 放入 ngrok\ 目录（见「ngrok 下载」节）
#    并配置 authtoken:  ngrok config add-authtoken <你的token>

# 3) 检查本机 dsh 安装位置（start_remote_all.ps1 顶部 $dshtmWebDir / $dshtmHome）
#    申请自己的静态域名后，改 $ngrokHost 并同步 trusted-host

# 4) 一键拉起
# 双击 start_remote_all.bat
```

**登录**：浏览器打开 ngrok URL → 登录页输入 `DSH_PROXY_USER / DSH_PROXY_PASSWORD`。

## ngrok 下载

> ngrok.exe（约 30MB）**不随仓库提交**（git 忽略 `ngrok/ngrok.exe` 与日志）。首次使用手动下载放入 `ngrok\` 目录：

**Windows x64 稳定版（v3.39+，推荐）：**
```
https://bin.equinox.io/c/bNyj1mQVY4c/ngrok-v3-stable-windows-amd64.zip
```
解压出 `ngrok.exe` 放到本目录 `ngrok\` 下即可。

- 为什么不用旧版：winget 渠道的 v3.3.1 **读不懂新版 `version:"3"` 配置文件**，启动即秒退。务必备 v3.39+。
- 官方下载页（备选）：https://ngrok.com/download
- `start_remote_all.ps1` 检测到 `ngrok\ngrok.exe` 缺失时会提示下载地址。

## ⚠ 两个踩过的坑（2026-08-24）

1. **ngrok 必须隧道到 3200（proxy），不能直连 3080**——绕过 proxy 会丢手机兼容层（iOS<17.4 提交 prompt 崩溃）和 cookie 认证。修复链路时照手册架构来。
2. **ngrok.exe 别放 tmp/**（清理会连累隧道进程/exe 丢失）；PATH 里 winget 版 3.3.1 读不懂 `version:"3"` 配置会秒退——统一用 `ngrok/ngrok.exe`（v3.39+）。proxy 依赖 `http-proxy` 若缺：`cd proxy && npm install http-proxy`。

## 安全提醒

- 密码**不要硬编码**在代码或脚本里（`server.js` 从 `DSH_PROXY_PASSWORD` 环境变量读取；`start_remote_all.ps1` 里默认凭据仅供本地首次使用，请在 README 与脚本注释指引下 setx 换成强密码）。
- proxy 仅监听 127.0.0.1；公网唯一入口是 ngrok（TLS）。
- **不要在 ngrok 侧加 basic-auth**（traffic policy）——对 WebSocket 无效且会弹窗，认证统一由 proxy 的 cookie 会话负责。
- DSH 环境含 API key 等敏感配置：仅给信任的人提供访问。

## 提交说明

- `.gitignore` 已忽略：`ngrok/ngrok.exe`、`ngrok/*.log`、`proxy/node_modules/`。
- proxy 依赖由 `package.json` 声明，clone 后 `npm install` 即可（或直接 `cd proxy && npm install http-proxy`）。