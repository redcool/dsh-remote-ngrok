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
   │  ⑤ dsh 浏览器会话换票（见下表 #4：dsh 401 → 302 到 /?token=<启动token> → dsh 原生签发 cookie）
   │  ⑥ 上游 gzip/br 还原为明文后再注入（防压缩流注入损坏，见下表 #5）
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
| 4 | 新版 dsh（≥ 0.1.2-rc.1）浏览器访问根页面要求**启动 token 换 signed cookie**（无 → 401 "dsh web authentication required"，手机上即"需要 dsh web 授权"） | proxy 已过认证的访问遇到 dsh 401 → **302 到 /?token=<dsh 启动 token>**，由 dsh **原生**换票（按 Host 签 domain 绑定 cookie，30 天）；token 由一键脚本启动 dsh 时自动捕获写入 proxy/dsh_token.txt（`DSH_PROXY_DSH_TOKEN` 可覆盖）——不复制 dsh 内部 cookie 格式，天然兼容版本升级 |
| 5 | dsh 上游在远程访问场景把 HTML 回成 **gzip/br**；polyfill 注入对压缩流做会**破坏响应**（手机表现为连接中断/"socket hang up"） | proxy 转发前剥离 Accept-Encoding + html 分支**防御性解压**（gzip/br/deflate → 明文）→ 注入 → 去掉 content-encoding/vary 后以 chunked 明文回包 |

## 2. 环境准备

| 依赖 | 说明 | Windows | macOS / Linux |
|---|---|---|---|
| **Node.js** | proxy 用 Node 运行（http-proxy） | https://nodejs.org/zh-cn/download **LTS 版**，勾选 "Add to PATH" | `brew install node`（macOS）或官网 pkg；`apt install nodejs`（Linux） |
| git | 拉取本模块 | https://git-scm.com/download/win | macOS 自带 / `brew install git` |
| ngrok | 公网隧道 **（v3.39+，一键脚本会自动下载对应系统二进制，无需手动装）** | — | — |
| npm 依赖 | proxy 的 http-proxy | 见 §5 步骤 ① | 同左 |
| **dsh CLI** | DSH 本体（npm 包 `@deepseek-ai/dsh`）。官方 README 只列 npx 与源码构建，本手册推荐 **npm 安装（固定目录、版本可钉）**，见 §5 步骤 ② | 见 §5 步骤 ② | 同左 |

> Node.js 安装后**需重开终端**（PATH 才生效）。proxy 兼容任意现代 Node（v14+ 即可，建议 LTS）。

## 3. 目录结构

| 文件 | 作用 |
|---|---|
| `README.md` | 本文件（完整手册：环境/部署/使用/验证/排障） |
| **`start_remote_all.bat/.ps1`** | **Windows 一键拉起全链路**（proxy+ngrok+dsh web；**proxy 与 dsh web 均强制重启**以应用最新配置/代码；**本窗口即 dsh web 宿主，关窗 = 关 dsh**） |
| **`start_remote_all.sh`** | **macOS/Linux 一键拉起**（同功能；自动检测系统架构并下载对应 ngrok 二进制；proxy 强制重启，自动捕获换票 token）——**日常用这个** |
| `proxy/server.js` | 反向代理：cookie 会话认证 + polyfill 注入 + Origin 剥离 + dsh 换票自愈 + gzip 还原 |
| `proxy/package.json` | proxy 依赖声明（`npm install http-proxy`） |
| `proxy/dsh_token.txt` | **运行时生成（git 忽略）**：当前 dsh web 启动 token（proxy 自愈换票用；脚本启动 dsh 时自动写入，也可手动粘贴） |
| `config.json.temp` | **配置模板**（git 提交）：复制为 `config.json` 后填 ngrok token / dsh 路径 / proxy 凭据（见 §4 ②） |
| `config.json` | **本机配置（git 忽略）**：`ngrok_token`、`dsh_install_dir`、`dsh_home`、`ngrok_host`、`proxy_user`、`proxy_password` |
| `ngrok/` | **运行目录（git 忽略，自动管理）**：脚本自动下载对应系统二进制；运行时生成日志 |

## 4. ngrok 域名与配置

> **authtoken 与 ngrok 二进制都不随仓库提交**。一键脚本（.bat/.ps1/.sh）都会**自动下载**当前系统的 ngrok 二进制（v3.39+，darwin/linux/windows × amd64/arm64 全支持），无需手动安装。
> ⚠ 不用 winget 渠道的 v3.3.1：**读不懂新版 `version:"3"` 配置文件，启动即秒退**。

**① 域名策略**（重要）：
- **ngrok_host（静态域名，推荐）**：**注册 ngrok 免费账号就送一个** `xxx.ngrok-free.dev` 静态域名（https://dashboard.ngrok.com → Domains）。填进 config.json 的 `ngrok_host` → URL 永久固定。免费版可用 1 个静态域名 + 每次会话可开 1 条隧道。
- **留空**：脚本用 ngrok 自动分配的**临时随机域名**（每次启动会变，但保证立刻能用），启动日志会打印真实 URL。

**② 配置 authtoken / 基本信息**（一键脚本启动时自动处理）：
- 复制 `config.json.temp` → 改名 `config.json` → 填：`ngrok_token`（https://dashboard.ngrok.com → Your Authtoken）、`dsh_install_dir`（DSH 安装目录，见 §5 ②）、`dsh_home`（DSH 数据目录）、推荐填 `ngrok_host`（你的静态域名，见 ①）、`proxy_user` / `proxy_password`（proxy 登录凭据，也可用环境变量）
- token 缺失/无效时运行脚本会**交互询问**，粘贴即写回 `config.json`
- token 通过 `NGROK_AUTHTOKEN` 环境变量传给 ngrok（优先于全局配置，**不改动你机器上的 ngrok.yml**）

## 5. 首次使用（部署）

**Windows**：
```powershell
# ① 安装 proxy 依赖（只需一次；前提：Node.js 已装）
cd proxy
npm install http-proxy

# ② 安装 DSH（推荐：npm 专用目录安装，该目录即 config.json 的 dsh_install_dir）
#    本机 harness 实例（如 H:/AI/dsh）就是这种装法——一个依赖 @deepseek-ai/dsh 的目录
mkdir D:\dsh
cd /d D:\dsh
npm init -y
npm install @deepseek-ai/dsh
#    升级：cd /d D:\dsh && npm update @deepseek-ai/dsh
#    可选全局安装：npm install -g @deepseek-ai/dsh（macOS/Linux 脚本有 PATH 兜底；Windows 仍建议专用目录）
#    为何不用 npx / git clone：见下文「DSH 安装方式对比」

# ③ 配置 proxy 登录密码（必做，否则 proxy 拒绝启动；环境变量持久化）
setx DSH_PROXY_USER "dsh"
setx DSH_PROXY_PASSWORD "换成你的强密码"

# ④ 复制 config.json.temp → config.json，填 ngrok_token / dsh_install_dir（= ② 的目录，如 D:/dsh）/ dsh_home（§4②）
#    推荐填 ngrok_host（你的静态域名，§4①）
# ⑤ 一键拉起
# 双击 start_remote_all.bat（窗口即 dsh web 宿主；关闭窗口 = 关闭 dsh）
```

**macOS / Linux**：
```bash
# ① 安装 proxy 依赖（只需一次；前提：Node.js 已装）
cd proxy && npm install http-proxy

# ② 安装 DSH（推荐：npm 专用目录安装，该目录即 config.json 的 dsh_install_dir）
mkdir -p ~/dsh && cd ~/dsh
npm init -y
npm install @deepseek-ai/dsh
#    升级：cd ~/dsh && npm update @deepseek-ai/dsh
#    为何不用 npx / git clone：见下文「DSH 安装方式对比」

# ③ 配置 proxy 登录密码（写入 shell 配置 ~/.zshrc 或 ~/.bashrc）
export DSH_PROXY_USER="dsh"
export DSH_PROXY_PASSWORD="换成你的强密码"

# ④ 复制 config.json.temp → config.json，填 ngrok_token / dsh_install_dir（= ② 的目录，如 ~/dsh）/ dsh_home（§4②）
#    推荐填 ngrok_host（你的静态域名，§4①）；ngrok 二进制脚本会自动下载
# ⑤ 一键拉起
bash start_remote_all.sh    # 终端即 dsh web 宿主；Ctrl+C / 关窗口 = 关 dsh
```

**DSH 安装方式对比（为什么用 npm install，而不是官方 README 的 npx / 源码构建）**

| 方式 | 官方 README | 对本工具集的适配 |
|---|---|---|
| `npx @deepseek-ai/dsh web` | 官方「Run from npm」 | ❌ npx 是**即取即跑**：包缓存在 npm `_npx` 缓存目录，路径随版本漂移 → 启动脚本无法得到稳定的 `dsh_install_dir`；默认拉 `latest`，而 DSH 处于 developer preview（官方明示会有 breaking changes）→ 版本不可控 |
| `git clone` + `pnpm install` + `pnpm build` | 官方「Run from source」 | ❌ 源码开发路径：需 pnpm + 整仓构建，对「只想远程访问 DSH」的终端用户过重、脆弱 |
| `npm install @deepseek-ai/dsh`（**本手册推荐**） | npm 包已发布（`@deepseek-ai/dsh`，bin: `dsh`），官方未单列 | ✅ 固定安装目录 → 填进 `dsh_install_dir`；版本可钉（`@0.1.x`）可平滑升级（`npm update`）；无需构建；一键脚本本就是按此布局定位 dsh（`<目录>/node_modules/@deepseek-ai/dsh/lib/bin.js`） |

> DSH 本体 harness 最常见的落地方式（含本机实例 `H:/AI/dsh`）就是一个纯 npm 依赖目录——`npm install` 就是稳定工作方式，官方 README 只是没把它列为独立安装项。
> 安装后可用 `node <目录>/node_modules/@deepseek-ai/dsh/lib/bin.js web` 快速自检；一键脚本内部调用的正是这个入口，参数与官方 `dsh web` 完全一致（`--port 3080 --trusted-host <域名> --no-open`）。

**登录**：浏览器打开脚本打印的 ngrok URL → 登录页输入 `DSH_PROXY_USER / DSH_PROXY_PASSWORD`。

> 💡 若浏览器**之前登录过**（cookie 或记住的 basic 凭据有效）→ 不弹登录页是正常现象，直接放行。
> 💡 调试旧状态干扰用**无痕窗口**测试：无痕不带任何缓存/凭据，必弹登录页，走全新流程。

## 6. 日常使用

| 操作 | Windows | macOS / Linux |
|---|---|---|
| 开机/断链后拉起 | 双击 `start_remote_all.bat` | `bash start_remote_all.sh` |
| 停止 dsh web | 关闭 bat 窗口（窗口即宿主） | 终端 Ctrl+C 或关窗口 |
| 查当前隧道 URL | `(Invoke-RestMethod http://127.0.0.1:4040/api/tunnels).tunnels[0].public_url` | `curl -s http://127.0.0.1:4040/api/tunnels` |
| 换静态域名 | 改 config.json 的 `ngrok_host` → 重跑 | 同左 |

> 首次运行都会自动下载对应系统的 ngrok 二进制到 `ngrok/`（之后不再下载）。运行日志在 `ngrok/ngrok.log`。

## 7. 验证命令（本机快速自检）

```powershell
# ① 无 cookie → 401（proxy 登录页）
curl.exe -s -o NUL -w "HTTP %{http_code}`n" https://<ngrok-url>

# ② 登录 → 302 + Set-Cookie
curl.exe -s -c $env:TEMP\c.txt -o NUL -X POST -d "u=<USER>&p=<PASSWORD>" https://<ngrok-url>/__login

# ③ 带 cookie 首页 → 自动完成 dsh 换票（302:/?token=... → 303+Set-Cookie → 200），且含 polyfill
curl.exe -s -L -b $env:TEMP\c.txt -c $env:TEMP\c.txt https://<ngrok-url> | Select-String 'AbortSignal\.any'

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
| ERR_NGROK_3200 / endpoint offline | ngrok 进程退出或被杀，或安装目录被删除 | 重跑一键脚本（自动拉起；二进制没了会自动重下） |
| 脚本提示 ngrok 二进制缺失/下载失败 | 网络无法访问 bin.equinox.io；或旧版 winget ngrok 冲突 | 手动下载对应平台 zip 解压到 `ngrok/`（见 §4）；确保 PATH 无 v3.3.1 旧版 |
| 本机能看、手机/远程看不到 | 浏览器旧缓存/旧凭据 | 无痕窗口测试；清该站点缓存 |
| 手机打开显示 **"需要 dsh web 授权"（dsh web authentication required）** | dsh ≥ 0.1.2-rc.1 的浏览器会话认证：缺启动 token 换的 signed cookie（proxy 已过认证但 dsh 侧无 cookie）——多因**手动重启过 dsh web**（token 已轮换）或 proxy 还是旧代码 | **重跑 start_remote_all(.bat/.ps1/.sh)**：脚本会重启 dsh 并自动捕获新 token 写入 proxy/dsh_token.txt → 手机**刷新页面即可**（proxy 自动完成换票，之后 30 天无需再弄）。应急：把 dsh 启动终端里打印的 `dsh web: http://127.0.0.1:3080/?token=xxx` 整行发给 proxy 端，将 `xxx` 粘贴到 proxy/dsh_token.txt 即可立即生效（无需重启任何进程） |
| 手机能登录但首页**一直转圈/连不上（socket hang up）** | 上游把 HTML 回成 gzip/br，旧 proxy 向压缩流注入 polyfill 损坏响应；或手机访问的是 ngrok 的 502/校验页 | 升级 proxy（v12 起剥离 Accept-Encoding + 解压后再注入）；确认手机 URL 是脚本打印的 ngrok 地址而非 127.0.0.1 |
| 登录页不弹（进了 DSH） | 浏览器 cookie/basic 凭据仍有效——正常行为 | 无需处理；想强制重登：清站点数据或换无痕 |
| 随机域名下重启后 URL 变了 | 未填 `ngrok_host`，ngrok 每次分配临时域名 | 接受（日志会打印新 URL），或注册填静态域名（§4①） |

## 9. proxy 实现要点（server.js 设计备忘）

- **会话**：内存 Map（token→过期时间），Set-Cookie `dsh_session` HttpOnly SameSite=Lax，24h；>256 条时惰性清理过期（防无限增长）。
- **登录防爆破**：连续失败 >5 次 → 延迟 1s（每来源计数，5 分钟窗口自清）。来源取 `X-Forwarded-For`（ngrok 场景 socket 端恒为 127.0.0.1，XFF 才是真实客户端 ip）。
- **兼容 basic-auth**：`Authorization: Basic <user:pass>` 命中直接放行（浏览器记住的旧凭据也能进）；用 `crypto.timingSafeEqual` 恒定时间比较（防时序侧信道）。
- **响应注入**：`selfHandleResponse:true` 手动回写；HTML 缓冲 → **若上游带 `content-encoding: gzip/br/deflate` 先解压成明文**（转发前也已剥离 Accept-Encoding，双保险）→ `</head>` 前插 `<script>` polyfill（**无条件注入**——polyfill 幂等，勿用 `includes('AbortSignal')` 做 guard，页面含该字样会跳过注入）→ 去掉 content-length/TE/connection/content-encoding/vary 后以 **chunked 明文**回包（旧版曾写死 content-length，导致与上游 chunked 冲突报 Parse Error——v12 起统一不写长度，浏览器同样正确读全）；其他类型原样 pipe；上游流异常兜底销毁连接防挂起。
- **WS 转发**：`upgrade` 事件 → 校验 cookie（无 → 403 应用层拒绝，不带 WWW-Authenticate，不弹框）→ `proxy.ws` 转发；同样剥离 Origin。
- **polyfill 内容**：AbortSignal.any/timeout、Promise.withResolvers、URL.canParse、Object.hasOwn、Array.at/findLast/findLastIndex。
- **密码不硬编码**：`DSH_PROXY_USER` / `DSH_PROXY_PASSWORD` 环境变量读取，未设置则拒绝启动。

## 10. 安全提醒

- 密码**不要硬编码**：`server.js` 从环境变量读取；一键脚本不写死凭据（可填 config.json 的 proxy_user/proxy_password，或环境变量）；未配置则 proxy 拒绝启动。
- proxy 仅监听 127.0.0.1；公网唯一入口是 ngrok（TLS）。
- **不要在 ngrok 侧加 basic-auth**（traffic policy）——对 WebSocket 无效且会弹窗，认证统一由 proxy 的 cookie 会话负责。
- fence 的 **Host 白名单校验保留**（`--trusted-host` 只放行指定域名），剥离 Origin 不降低安全。
- DSH 环境含 API key 等敏感配置：仅给信任的人提供访问，URL 不要公开张贴。

## 11. 提交说明

- `.gitignore` 已忽略：`config.json`（含真 token/路径）、`ngrok/`（整个目录）、`proxy/node_modules/`。
- 提交的模板：`config.json.temp`（clone 后复制为 `config.json` 填自己的配置）。
- proxy 依赖由 `package.json` 声明，clone 后 `cd proxy && npm install http-proxy`。

## 12. 变更记录

- **v12（2026-09-07）**：修复新版 dsh（≥ 0.1.2-rc.1）的**浏览器会话认证**——手机访问显示"需要 dsh web 授权"。① proxy 新增**换票自愈**：dsh 返回 401 时 302 到 `/?token=<dsh 启动 token>`，由 dsh 原生换 signed cookie（不再复制 dsh 内部 cookie 格式）；token 由一键脚本启动 dsh 时捕获写入 `proxy/dsh_token.txt`（`DSH_PROXY_DSH_TOKEN` 可覆盖，proxy 每请求读取，token 轮换无需重启）。② 修复**远程场景 gzip 破坏注入**：上游回 gzip/br 时旧代码向压缩流注入 polyfill 损坏响应（手机"socket hang up"）；v12 剥离 Accept-Encoding + html 分支防御性解压 → 明文注入 → chunked 明文回包（不再写死 content-length，消除此前 CL+TE 并存 Parse Error 隐患）。③ 一键脚本（.bat/.ps1 与 .sh 同步）：dsh web 启动输出逐行捕获 token 写入 proxy/dsh_token.txt；**proxy 也改为强制重启**（与应用代码更新）；proxy/dsh_token.txt 已加入 .gitignore（内含每进程随机 token，勿提交）。适配版本基线（0.1.2-rc.1）与升级再适配指引见 **§13**。
- **v10（2026-09-05）**：新增 **`start_ngrok.bat` / `start_ngrok.ps1`（只开 ngrok 隧道）**——双击即可：读 config.json 的 `ngrok_token`/`ngrok_host`（token 无效则交互询问写回）、只用本地 `ngrok\ngrok.exe`（避开 PATH 上 winget v3.3.1 旧版）、默认转发 3200（dsh-proxy，`-Port` 可改）、已在跑则直接打印现有 URL、前台同窗运行（关窗=停）。
- **v9（2026-08-24）**：新增 **DSH 的 npm 安装说明**——§2 依赖表加 dsh CLI 行；§5 步骤 ② 给出 npm 专用目录安装（mkdir + npm init + npm install @deepseek-ai/dsh，升级 npm update）与可选全局安装；新增「DSH 安装方式对比」表解释为何不用官方 README 的 npx / git clone（npx 缓存路径漂移、版本不可控；源码构建过重）；config.json.temp 的 dsh_install_dir 注释同步指向 §5 ②。
- **v8（2026-08-24）**：新增 **`start_remote_all.sh`（macOS/Linux 一键脚本）**——自动检测系统架构并下载对应 ngrok 二进制（darwin/linux × amd64/arm64）；ngrok 域名策略改为 **ngrok_host 静态域名优先（注册 ngrok 免费送 .ngrok-free.dev）+ 留空自动随机域名兜底**，trusted-host 以 ngrok API 拿到的真实公网域名为准；config.json.temp/README 全量同步。
- **v7（2026-08-24）**：提交前复查——polyfill 无条件注入（修 `AbortSignal` guard 隐患）、basic-auth 改用 timingSafeEqual、防爆破来源取 X-Forwarded-For（ngrok 下才有效）、删 ps1 死代码；proxy 逻辑单测通过（401/限速/502）。
- **v6**：config.json 字段改名对齐环境变量语义——`dshtmWebDir→dsh_install_dir`、`dshtmHome→dsh_home`、`ngrokHost→ngrok_host`、`proxyUser→proxy_user`、`proxyPassword→proxy_password`（见名知意，新用户友好）；config.json 补齐全部字段（proxy 凭据从 setx 环境变量同步）。
- **v5**：代码审查加固——dshtmHome 生效（DSH_HOME 环境变量）、ngrokHost/proxy 凭据纳入 config.json（去硬编码）、_Save-CfgToken 保留其他字段、前窗宿主语义（关窗=关 dsh）、proxy 加登录防爆破/会话清理/流错误兜底。
- **v4**：合并手册与 README 为单文档；补 Node.js 安装说明；`start_dsh_web_remote.*` 删除（并入一键脚本）；ngrok authtoken 走 config.json + 交互询问流程；`ngrok/` 整目录 git 忽略。
- v3：解决 content-length 截断 bug + 剥离 Origin 头绕开 fence 严格同源判定 + 扩展 polyfill → 手机/远程全功能验证通过。密码改环境变量配置。
- v2：ngrok basic-auth → proxy cookie 会话；polyfill 注入；修复 http-proxy selfHandleResponse 双写头崩溃。
- v1：初始方案探索（traffic policy basic-auth 语法 5 连踩坑；`--basic-auth` flag 已废弃）。
- 背景：iOS 16.4 无 `AbortSignal.any` + ngrok basic-auth 对 WS 弹窗 + Tailscale 中国大陆不可登录 → 自建 proxy 层解决全部三问题。

## 13. dsh 版本适配基线与升级再适配（必读）

> 本代理适配的是 **dsh 0.1.2-rc.1** 的行为。dsh 升级可能改掉下列行为，届时需要**按 §13.3 自查并小改**；
> 设计上已尽量把耦合降到最低（见 §13.2「刻意不耦合」），通常再适配只改一两处字符串/状态码，10 分钟以内。

### 13.1 本次适配基线（2026-09-07 实测）

| 包 | 版本 | 说明 |
|---|---|---|
| `@deepseek-ai/dsh` | **0.1.2-rc.1** | CLI / 启动器（`dsh web --trusted-host <域名> --port 3080`） |
| `@deepseek-ai/dsh-client-connection` | **0.1.2-rc.1** | 浏览器会话认证（token 换票 + signed cookie）在此实现 |
| `@deepseek-ai/dsh-web-frontend` | **0.1.2-rc.1** | 前端 dist（index HTML + JS bundle，polyfill 注入对象） |
| `@deepseek-ai/dsh-web-app` | **0.1.2-rc.1** | Web 服务主进程（渲染/静态服务） |

适配依据直接取自安装包源码（`dsh-client-connection/lib/index.js`）与实测：

- `TOKEN_QUERY = "token"`（L199）；换票条件：`GET /` + 仅 1 个 token + `tokenMatches` + Host 可解析 → `303 + Location:/ + Set-Cookie(dsh-auth-*)`（L366-385）；
- 未换票/无有效 cookie → **401** + 正文 `dsh web authentication required; reopen the URL printed by dsh web.`（L419-424）——手机上看到的「需要 dsh web 授权」即此文案；
- cookie 按 Host 绑定、实测 30 天（`Max-Age=2592000`），**跨 dsh 重启有效**（密钥持久化，登录一次 30 天内无需再换）；
- Host 白名单 fence：非 `--trusted-host` 域名 → 403（代理链路只放行 ngrok 静态域名）；
- 远程访问路径（带 x-forwarded-*）上游会把 HTML 回成 **gzip/br**（实测 3658B gzip ≈ 26.5KB 明文），本地直连为明文。

### 13.2 耦合点清单（dsh 改了这里 → 我方要动）

| # | dsh 现在的行为（0.1.2-rc.1） | 我方的适配（文件位置） | 若 dsh 改了会怎样 / 怎么改 |
|---|---|---|---|
| 1 | 缺会话 cookie 时对 `/` 回 **401** | `server.js` heal 分支：dsh 401 且 pathname=`/` 且已过代理认证且无 `?token=` → 302 到 `/?token=<启动token>` | 状态码/判据变了 → 换票不触发（手机仍见授权页）。按新行为调整 heal 条件即可 |
| 2 | 换票入口 **`/?token=<启动token>`**（`TOKEN_QUERY="token"`），成功回 303+Set-Cookie | 依赖此入口做自愈换票（`dsh_token.txt` 由脚本捕获） | **若 dsh 删除/改名这个入口** → 需更换方案（回退到「读 `.credentials.yaml` 密钥复刻 cookie」——该方案已在独立实例验证过构造正确，见 SESSION_MEMORY，或跟随 dsh 新机制） |
| 3 | 启动时打印 `dsh web: http://127.0.0.1:3080/?token=xxx` | `start_remote_all.ps1/_Dsh-Line` 正则捕获写 `proxy/dsh_token.txt` | 输出格式变了 → 捕获失败（`dsh_token.txt` 无更新）。改正则即可；也可用 `DSH_PROXY_DSH_TOKEN` 环境变量兜底 |
| 4 | `--trusted-host <域名>` 白名单 fence（403） | 脚本以 ngrok 真实公网域名启动 dsh | 参数名/语义变了 → 远程 403。改脚本启动参数 |
| 5 | 远程路径 HTML 回 **gzip/br/deflate** | `server.js`：转发前剥 `Accept-Encoding` + html 分支防御性解压 → 明文注入 | 压缩算法变了 → 增加对应解压分支（现有 gzip/br/deflate 已覆盖主流） |
| 6 | WS 握手认 cookie 会话 | proxy cookie 会话（登录一次全通） | 握手鉴权方式变了 → 调整 upgrade 分支 |
| 7 | 前端（index bundle）用 `AbortSignal.any` 等新 API | 无条件注入 polyfill（幂等，勿加 `includes` guard） | 页面用了更新的 API → 扩 polyfill 即可 |

### 13.3 刻意不耦合的部分（dsh 怎么改都不用动）

- **cookie 内部格式**：名字（`dsh-auth-<sha256(authority)>`）、载荷 (`v1.{...}.{hmac}`)、密钥存储（`.credentials.yaml` 的 `client-connection/browser-session`）。v12 改用「dsh 原生换票」，不复制这些格式——只要 `/?token=` 换票入口还在，dsh 随便改 cookie 细节都不影响本代理。
- **签名密钥读取**：曾实现「读密钥复刻 cookie」并验证构造正确，但 live 实例拒收（疑进程内存密钥≠磁盘记录，成因未决）→ 弃用密钥方案、改用 token 换票，顺带把这块耦合彻底去掉。

### 13.4 升级 dsh 后自查（runbook，约 10 分钟）

1. 升级：在 `dsh_install_dir` 执行 `npm update @deepseek-ai/dsh`（或官方升级方式）。
2. 重跑 `start_remote_all.bat`（脚本自动重启 dsh + 捕获新 token + 重启 proxy）。
3. 无痕窗口走完整链路（§7 验证命令 + 下面完整链路）：登录 proxy → `GET /`（302 换票）→ `/?token=`（303+Set-Cookie）→ `GET /` **200 且含 polyfill**。
4. 手机实测一遍；若出现「需要 dsh web 授权」→ 查 §8 对应行；若 401 文案/换票参数已变 → 对照 §13.2 表改 `server.js` 对应处。
5. 把新基线版本与改动补进 §13.1 与 §12 变更记录。