# ============================================================
# DSH 远程访问 · 一键拉起（proxy + ngrok + dsh web 全链路）
# 用法：双击 start_remote_all.bat（或在本目录跑本 ps1）
# 链路：手机/浏览器 → ngrok(TLS) → dsh-proxy(127.0.0.1:3200) → dsh web(127.0.0.1:3080)
# 幂等：proxy/ngrok 已在跑的不重启；dsh web 前台窗口打开（关窗口 = 关 dsh，可自控）
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

# ngrok 静态域名（优先 config.json 的 ngrok_host；为空则用默认）
$ngrokHost = if ($script:ngrokHost) { $script:ngrokHost } else { "happier-custodian-hastily.ngrok-free.dev" }
$script:defaultHost = "happier-custodian-hastily.ngrok-free.dev"
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

# ① dsh-proxy（3200：cookie 会话认证 + iOS polyfill + Origin 剥离——手机能用的关键层）
if (Test-PortListen 3200) {
  Write-Host "[*] proxy 已在跑（3200）— 跳过"
} else {
  Write-Host "[*] 启动 dsh-proxy（3200）..."
  Start-Process -FilePath "node" -ArgumentList "server.js" -WorkingDirectory $proxyDir -WindowStyle Hidden
  Start-Sleep -Seconds 3
  if (Test-PortListen 3200) { Write-Host "[+] proxy 3200 在线" } else { Write-Host "[!] proxy 启动失败（查 DSH_PROXY_PASSWORD 环境变量 / proxy/node_modules）" -ForegroundColor Red }
}

# ② ngrok（→3200！不要直连 3080——绕过 proxy 手机会崩）
if (Test-PortListen 4040) {
  Write-Host "[*] ngrok 已在跑（4040）— 跳过"
} else {
  if (-not (Test-Path $ngrokExe)) {
    Write-Host "[!] 缺 $ngrokExe —— 首次使用请到 https://bin.equinox.io/c/bNyj1mQVY4c/ngrok-v3-stable-windows-amd64.zip 下载 v3.39+ 并解压放入 ngrok\ 目录（详见 README.md「ngrok 下载与配置」节）" -ForegroundColor Red
  } else {
    $tok = Get-NgrokToken
    if ($tok) { $env:NGROK_AUTHTOKEN = $tok }  # 子进程继承，优先于全局配置
    Write-Host "[*] 启动 ngrok → 3200（静态域名 $ngrokHost）..."
    Start-Process -FilePath $ngrokExe -ArgumentList "http","3200","--url=$ngrokHost","--log=stdout" -WindowStyle Hidden `
      -RedirectStandardOutput (Join-Path $toolsDir "ngrok\ngrok.log") -RedirectStandardError (Join-Path $toolsDir "ngrok\ngrok_err.log")
    Start-Sleep -Seconds 8
    try {
      $t = Invoke-RestMethod -Uri "http://127.0.0.1:4040/api/tunnels" -TimeoutSec 8
      $t.tunnels | ForEach-Object { Write-Host ("[+] ngrok: {0} → {1}" -f $_.public_url, $_.config.addr) }
    } catch {
      Write-Host "[!] ngrok 未就绪（看 ngrok\ngrok_err.log；authtoken 无效/内存不足都会这样）" -ForegroundColor Red
      Get-Content (Join-Path $toolsDir "ngrok\ngrok_err.log") -Tail 3 -ErrorAction SilentlyContinue | ForEach-Object { Write-Host "   $_" -ForegroundColor DarkGray }
    }
  }
}

# ③ dsh web（3080：带 --trusted-host 前台运行——bat 窗口即宿主，关窗 = 关 dsh）
$webOk = $false
$conn = Get-NetTCPConnection -LocalPort 3080 -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
if ($conn) {
  $cmdline = (Get-CimInstance Win32_Process -Filter "ProcessId = $($conn.OwningProcess)" -ErrorAction SilentlyContinue).CommandLine
  if ($cmdline -and $cmdline.Contains($ngrokHost)) {
    Write-Host "[*] dsh web 已在跑且 trusted-host 匹配 — 跳过"
    $webOk = $true
  } else {
    Stop-Process -Id $conn.OwningProcess -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
    Write-Host "[*] 停旧 dsh web（trusted-host 不匹配，重启）"
  }
}
if (-not $webOk) {
  if (-not $script:dshInstallDir) {
    Write-Host "[!] 无法启动 dsh web：config.json 未配置 dsh_install_dir" -ForegroundColor Red
  } else {
    Write-Host ""
    Write-Host "==================================================" -ForegroundColor Cyan
    Write-Host " 启动 dsh web → 本窗口即宿主（关闭本窗口 = 关闭 dsh）"
    Write-Host " 公网: https://$ngrokHost  （登录 $env:DSH_PROXY_USER）"
    Write-Host " 本机: http://127.0.0.1:3080"
    Write-Host "==================================================" -ForegroundColor Cyan
    Write-Host ""
    $shim = Join-Path $script:dshInstallDir "node_modules\.bin\dsh.cmd"
    # dsh 数据目录（config.json dsh_home，对应环境变量 DSH_HOME）——必须在启动前设置，否则 dsh 用默认 HOME 找错数据
    if ($script:dshHome) { $env:DSH_HOME = $script:dshHome }
    if (Test-Path $shim) {
      # 前台调用 dsh.cmd（cmd 包装 → node）：阻塞在本窗口，关窗 = 终止进程树 = 关 dsh
      & $shim web --port 3080 --trusted-host $ngrokHost --no-open
    } else {
      node (Join-Path $script:dshInstallDir "node_modules\@deepseek-ai\dsh\lib\bin.js") web --port 3080 --trusted-host $ngrokHost --no-open
    }
    # dsh 退出后（窗口被关/手动 Ctrl+C）回到这里
    Write-Host "[*] dsh web 已停止" -ForegroundColor DarkGray
  }
}

Write-Host ""
Write-Host "=================================================="
Write-Host " 手机/浏览器访问: https://$ngrokHost"
Write-Host " 登录: $env:DSH_PROXY_USER / $env:DSH_PROXY_PASSWORD"
Write-Host " （凭据可用 setx DSH_PROXY_USER / DSH_PROXY_PASSWORD 改）"
Write-Host "=================================================="