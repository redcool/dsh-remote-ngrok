# ============================================================
# DSH 远程访问 · 一键拉起（proxy + ngrok + dsh web 全链路）
# 用法：双击 start_remote_all.bat（或在本目录跑本 ps1）
# 链路：手机/浏览器 → ngrok(TLS) → dsh-proxy(127.0.0.1:3200) → dsh web(127.0.0.1:3080)
# 幂等：ngrok 已在跑的不重启；**proxy 与 dsh web 均强制重启**（2026-08-27 用户：双击 = kill 当前 dsh 进程再拉起，保证配置/版本更新生效；2026-09-07 起 proxy 同样强制重启以应用代码更新）
# 配置：读 config.json（模板 config.json.temp 复制改名后填写：ngrok_token / dsh_install_dir / dsh_home / ngrok_host / proxy_user / proxy_password）
# ============================================================

$ErrorActionPreference = 'Continue'
$toolsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$cfgFile  = Join-Path $toolsDir "config.json"

# ========== 读取配置（config.json）==========
$script:ngrokToken   = ""
$script:dshInstallDir = ""
$script:dshHome      = ""
$script:ngrokHost    = ""
$script:proxyUser    = ""
$script:proxyPass    = ""
if (Test-Path $cfgFile) {
  try {
    $cfg = Get-Content $cfgFile -Raw -Encoding UTF8 | ConvertFrom-Json
    $script:ngrokToken   = [string]$cfg.ngrok_token
    $script:dshInstallDir = [string]$cfg.dsh_install_dir
    $script:dshHome      = [string]$cfg.dsh_home
    $script:ngrokHost    = [string]$cfg.ngrok_host
    $script:proxyUser    = [string]$cfg.proxy_user
    $script:proxyPass    = [string]$cfg.proxy_password
  } catch { Write-Host "[!] config.json 解析失败：$($_.Exception.Message)" -ForegroundColor Red }
}
if (-not $script:dshInstallDir) { Write-Host "[!] config.json 缺少 dsh_install_dir（DSH 安装位置）——请复制 config.json.temp 为 config.json 并填写" -ForegroundColor Red }
# ========== 配置区结束 ==========

# ngrok 域名策略：config.json 填了 ngrok_host（注册 ngrok 免费送的 .ngrok-free.dev 静态域名）→ 用静态域名（固定 URL）；
# 留空 → ngrok 自动分配临时随机域名（每次会话会变，但保证立刻能用），启动后打印真实 URL。
# 任何情况下，trusted-host 都以 ngrok API 查到的真实公网域名为准（静态/随机统一）。
$ngrokHost = $script:ngrokHost   # 可能为空 = 随机域名
$ngrokExe  = Join-Path $toolsDir "ngrok\ngrok.exe"
$proxyDir  = Join-Path $toolsDir "proxy"

# proxy 凭据：优先用户级环境变量；没有则用 config.json（proxy_user/proxy_password）；都没有则提示
$env:DSH_PROXY_USER = if ($env:DSH_PROXY_USER) { $env:DSH_PROXY_USER } elseif ($script:proxyUser) { $script:proxyUser } else { "" }
$env:DSH_PROXY_PASSWORD = if ($env:DSH_PROXY_PASSWORD) { $env:DSH_PROXY_PASSWORD } elseif ($script:proxyPass) { $script:proxyPass } else { "" }
if (-not $env:DSH_PROXY_USER -or -not $env:DSH_PROXY_PASSWORD) {
  Write-Host "[!] proxy 登录凭据未配置：请 setx DSH_PROXY_USER / DSH_PROXY_PASSWORD（或填入 config.json 的 proxy_user/proxy_password）——proxy 将无法启动" -ForegroundColor Yellow
}

function Test-PortListen([int]$port) {
  return $null -ne (Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1)
}

## 从 ngrok 本地 API 取当前隧道公网 URL（静态域名 / 随机域名统一入口）
function Get-TunnelUrl {
  try {
    $t = Invoke-RestMethod -Uri "http://127.0.0.1:4040/api/tunnels" -TimeoutSec 8
    if ($t.tunnels -and $t.tunnels.Count -gt 0) { return [string]$t.tunnels[0].public_url }
  } catch { }
  return ""
}

## authtoken 校验：非空、非占位、非 URL、形似 token（≥20 位 base62+下划线）
function Test-NgrokToken([string]$t) {
  $t = $t.Trim()
  if ($t.Length -lt 20) { return $false }
  if ($t -match '://') { return $false }
  if ($t -match 'YOUR_|TODO|example|示例|REPLACE') { return $false }
  if ($t -notmatch '^[A-Za-z0-9_\-]{20,}$') { return $false }
  return $true
}

## 取 ngrok token：config.json → 无效则询问并写回 config.json
function Get-NgrokToken {
  if (Test-NgrokToken $script:ngrokToken) { return $script:ngrokToken }
  Write-Host ""
  Write-Host "──────────────────────────────────────────────" -ForegroundColor Cyan
  Write-Host " 需要 ngrok authtoken（config.json 缺失或无效）" -ForegroundColor Yellow
  Write-Host " 1) 打开 https://dashboard.ngrok.com → Your Authtoken，复制" -ForegroundColor Gray
  Write-Host " 2) 粘贴到下面（会写回 config.json）："
  $token = (Read-Host " authtoken").Trim()
  if (Test-NgrokToken $token) {
    _Save-CfgToken $token
    Write-Host "[+] 已更新 config.json" -ForegroundColor Green
    return $token
  }
  Write-Host "[!] 输入不像有效 authtoken；ngrok 可能启动失败" -ForegroundColor Red
  return ""
}

## 写回 token 到 config.json（保留原文件其他字段与格式宽松化——只更新 ngrok_token）
function _Save-CfgToken([string]$token) {
  $cfg = @{}
  if (Test-Path $script:cfgFile) {
    try { $cfg = Get-Content $script:cfgFile -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $cfg = @{} }
  }
  $cfg.ngrok_token = $token
  [System.IO.File]::WriteAllText($script:cfgFile, ($cfg | ConvertTo-Json), (New-Object System.Text.UTF8Encoding($false)))
}

## 捕获 dsh web 启动时打印的 "dsh web: http://127.0.0.1:3080/?token=<启动token>" 行，
## 把 token 写入 proxy/dsh_token.txt —— proxy 收到 dsh 的 401（"dsh web authentication required"）时
## 用它 302 到 /?token=... 让 dsh 原生换浏览器会话 cookie（手机不用复制 token）。
## 幂等：每次 dsh 重启 token 都会变，本函数每次启动都会覆写；proxy 每请求读该文件，无需随 token 变化重启。
function _Dsh-Line([string]$line) {
  Write-Host $line
  $m = [regex]::Match($line, '//[^/]+/\?token=([A-Za-z0-9_\-]+)')
  if ($m.Success) {
    try {
      [System.IO.File]::WriteAllText((Join-Path $proxyDir 'dsh_token.txt'), $m.Groups[1].Value, (New-Object System.Text.UTF8Encoding($false)))
      Write-Host "[+] 已记录 dsh 启动 token（proxy 自动换票用；也可手动粘贴到 proxy\dsh_token.txt）" -ForegroundColor DarkGray
    } catch { Write-Host "[!] 写 dsh_token.txt 失败：$($_.Exception.Message)" -ForegroundColor Yellow }
  }
}

# ① dsh-proxy（3200：cookie 会话认证 + iOS polyfill + Origin 剥离 + dsh token 换票——手机能用的关键层）
# 2026-09-07：与 dsh web 同理，proxy 也强制重启——保证最新代理代码生效（proxy/dsh_token.txt 每请求读取，token 变化无需重启）
$proxyConn = Get-NetTCPConnection -LocalPort 3200 -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
if ($proxyConn) {
  Stop-Process -Id $proxyConn.OwningProcess -Force -ErrorAction SilentlyContinue
  Start-Sleep -Seconds 2
  Write-Host "[*] 已停旧 proxy（强制重启：3200 旧进程 PID $($proxyConn.OwningProcess)）"
}
Write-Host "[*] 启动 dsh-proxy（3200）..."
Start-Process -FilePath "node" -ArgumentList "server.js" -WorkingDirectory $proxyDir -WindowStyle Hidden
Start-Sleep -Seconds 3
if (Test-PortListen 3200) { Write-Host "[+] proxy 3200 在线" } else { Write-Host "[!] proxy 启动失败（查 DSH_PROXY_PASSWORD 环境变量 / proxy/node_modules）" -ForegroundColor Red }

# ② ngrok（→3200！不要直连 3080——绕过 proxy 手机会崩）
if (Test-PortListen 4040) {
  Write-Host "[*] ngrok 已在跑（4040）— 跳过"
} else {
  if (-not (Test-Path $ngrokExe)) {
    Write-Host "[!] 缺 $ngrokExe —— 首次使用请到 https://bin.equinox.io/c/bNyj1mQVY4c/ngrok-v3-stable-windows-amd64.zip 下载 v3.39+ 并解压放入 ngrok\ 目录（详见 README.md「ngrok 下载与配置」节）" -ForegroundColor Red
  } else {
    $tok = Get-NgrokToken
    if ($tok) { $env:NGROK_AUTHTOKEN = $tok }  # 子进程继承，优先于全局配置
    if ($ngrokHost) {
      Write-Host "[*] 启动 ngrok → 3200（静态域名 $ngrokHost）..."
      $ngrokArgs = @("http","3200","--url=$ngrokHost","--log=stdout")
    } else {
      Write-Host "[*] 启动 ngrok → 3200（config 未填 ngrok_host，用临时随机域名）..."
      $ngrokArgs = @("http","3200","--log=stdout")
    }
    Start-Process -FilePath $ngrokExe -ArgumentList $ngrokArgs -WindowStyle Hidden `
      -RedirectStandardOutput (Join-Path $toolsDir "ngrok\ngrok.log") -RedirectStandardError (Join-Path $toolsDir "ngrok\ngrok_err.log")
    Start-Sleep -Seconds 8
  }
}
# 统一取当前隧道公网 URL（静态/随机都走这里）
$script:tunnelUrl = Get-TunnelUrl
if ($script:tunnelUrl) {
  Write-Host "[+] ngrok: $($script:tunnelUrl) → http://127.0.0.1:3200"
  if (-not $ngrokHost) { Write-Host "    提示：注册 ngrok 免费送 .ngrok-free.dev 静态域名，填入 config.json 的 ngrok_host 可固定 URL" -ForegroundColor DarkGray }
} else {
  Write-Host "[!] ngrok 未就绪（看 ngrok\ngrok_err.log；authtoken 无效/内存不足都会这样）" -ForegroundColor Red
  Get-Content (Join-Path $toolsDir "ngrok\ngrok_err.log") -Tail 3 -ErrorAction SilentlyContinue | ForEach-Object { Write-Host "   $_" -ForegroundColor DarkGray }
}

# ③ dsh web（3080：带 --trusted-host 前台运行——bat 窗口即宿主，关窗 = 关 dsh）
# 2026-08-27 用户：双击启动 = 强制重启链路 → 无条件停掉当前在跑的 dsh web（3080 占用者），再拉新实例。
# trusted-host 以 ngrok 真实公网域名为准（随机域名下 config 的 ngrok_host 可能为空）
$tunnelHost = if ($script:tunnelUrl) { ([uri]$script:tunnelUrl).Host } else { $ngrokHost }
$webOk = $false
$conn = Get-NetTCPConnection -LocalPort 3080 -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
if ($conn) {
  Stop-Process -Id $conn.OwningProcess -Force -ErrorAction SilentlyContinue
  Start-Sleep -Seconds 2
  Write-Host "[*] 已停旧 dsh web（强制重启：3080 旧进程 PID $($conn.OwningProcess)）"
}
if (-not $webOk) {
  if (-not $script:dshInstallDir) {
    Write-Host "[!] 无法启动 dsh web：config.json 未配置 dsh_install_dir" -ForegroundColor Red
  } else {
    Write-Host ""
    Write-Host "==================================================" -ForegroundColor Cyan
    Write-Host " 启动 dsh web → 本窗口即宿主（关闭本窗口 = 关闭 dsh）"
    Write-Host " 公网: $($script:tunnelUrl)  （登录 $env:DSH_PROXY_USER）"
    Write-Host " 本机: http://127.0.0.1:3080"
    Write-Host "==================================================" -ForegroundColor Cyan
    Write-Host ""
    $shim = Join-Path $script:dshInstallDir "node_modules\.bin\dsh.cmd"
    # dsh 数据目录（config.json dsh_home，对应环境变量 DSH_HOME）——必须在启动前设置，否则 dsh 用默认 HOME 找错数据
    if ($script:dshHome) { $env:DSH_HOME = $script:dshHome }
    if (Test-Path $shim) {
      # 前台调用 dsh.cmd（cmd 包装 → node）：阻塞在本窗口，关窗 = 终止进程树 = 关 dsh
      # 2>&1 逐行过 _Dsh-Line：既保持控制台输出，又捕获启动 URL 里的 token → proxy/dsh_token.txt
      & $shim web --port 3080 --trusted-host $tunnelHost --no-open 2>&1 | ForEach-Object { _Dsh-Line $_ }
    } else {
      node (Join-Path $script:dshInstallDir "node_modules\@deepseek-ai\dsh\lib\bin.js") web --port 3080 --trusted-host $tunnelHost --no-open 2>&1 | ForEach-Object { _Dsh-Line $_ }
    }
    # dsh 退出后（窗口被关/手动 Ctrl+C）回到这里
    Write-Host "[*] dsh web 已停止" -ForegroundColor DarkGray
  }
}

Write-Host ""
Write-Host "=================================================="
if ($script:tunnelUrl) { Write-Host " 手机/浏览器访问: $($script:tunnelUrl)" } else { Write-Host " 手机/浏览器访问: （ngrok 未就绪，见上方日志）" -ForegroundColor Red }
Write-Host " 登录: $env:DSH_PROXY_USER / $env:DSH_PROXY_PASSWORD"
Write-Host " （凭据可用 setx DSH_PROXY_USER / DSH_PROXY_PASSWORD 改）"
Write-Host "=================================================="