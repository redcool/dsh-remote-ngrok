# ============================================================
# DSH 远程访问 · 一键拉起（proxy + ngrok + dsh web 全链路）
# 用法：双击 start_remote_all.bat（或在 dshTools 目录跑本 ps1）
# 链路：手机/浏览器 → ngrok(TLS) → dsh-proxy(127.0.0.1:3200) → dsh web(127.0.0.1:3080)
# 幂等：已在跑的组件不重启（页面不断线），缺哪个补哪个
# ============================================================

$ErrorActionPreference = 'Continue'
$toolsDir = Split-Path -Parent $MyInvocation.MyCommand.Path

# ========== 配置区 ==========
$ngrokHost = "happier-custodian-hastily.ngrok-free.dev"   # ngrok 静态域名（与 trusted-host 一致）
$dshtmWebDir  = "H:\AI\dsh"          # dsh 安装位置
$dshtmHome    = "D:\Users\Admin\.dsh" # DSH 数据目录
$ngrokExe     = Join-Path $toolsDir "ngrok\ngrok.exe"     # 新版 ngrok（v3.39+，稳定位置勿放 tmp）
$proxyDir     = Join-Path $toolsDir "proxy"
# proxy 凭据：优先用已有用户级环境变量；没有则用下方默认（首次运行后已 setx 持久化）
if (-not $env:DSH_PROXY_USER)     { $env:DSH_PROXY_USER = "dsh" }
if (-not $env:DSH_PROXY_PASSWORD) { $env:DSH_PROXY_PASSWORD = "FeiTu-2026-dsh" }
# ========== 配置区结束 ==========

function Test-PortListen([int]$port) {
  return $null -ne (Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1)
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
  if (-not (Test-Path $ngrokExe)) { Write-Host "[!] 缺 $ngrokExe —— 首次使用请到 https://bin.equinox.io/c/bNyj1mQVY4c/ngrok-v3-stable-windows-amd64.zip 下载 v3.39+ 并解压放入 ngrok\ 目录（详见 README.md「ngrok 下载」节）" -ForegroundColor Red }
  else {
    Write-Host "[*] 启动 ngrok → 3200（静态域名 $ngrokHost）..."
    Start-Process -FilePath $ngrokExe -ArgumentList "http","3200","--url=$ngrokHost","--log=stdout" -WindowStyle Hidden `
      -RedirectStandardOutput (Join-Path $toolsDir "ngrok\ngrok.log") -RedirectStandardError (Join-Path $toolsDir "ngrok\ngrok_err.log")
    Start-Sleep -Seconds 8
    try {
      $t = Invoke-RestMethod -Uri "http://127.0.0.1:4040/api/tunnels" -TimeoutSec 8
      $t.tunnels | ForEach-Object { Write-Host ("[+] ngrok: {0} → {1}" -f $_.public_url, $_.config.addr) }
    } catch { Write-Host "[!] ngrok 未就绪（看 ngrok\ngrok_err.log）" -ForegroundColor Red }
  }
}

# ③ dsh web（3080：带 --trusted-host 重启；已在跑且域名一致就不动）
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
  Write-Host "[*] 启动 dsh web →  http://127.0.0.1:3080  |  公网 https://$ngrokHost （账号 $env:DSH_PROXY_USER）"
  Start-Process -FilePath "node" -ArgumentList (Join-Path $dshtmWebDir "node_modules\.bin\dsh") , "web", "--port", "3080", `
    "--trusted-host", $ngrokHost, "--no-open" -WorkingDirectory $dshtmWebDir -WindowStyle Hidden
  Start-Sleep -Seconds 5
  if (Test-PortListen 3080) { Write-Host "[+] dsh web 3080 在线" } else { Write-Host "[!] dsh web 未起来（手动跑 start_dsh_web_remote.bat 看输出）" -ForegroundColor Red }
}

Write-Host ""
Write-Host "=================================================="
Write-Host " 手机/浏览器访问: https://$ngrokHost"
Write-Host " 登录: $env:DSH_PROXY_USER / $env:DSH_PROXY_PASSWORD"
Write-Host " （凭据可用 setx DSH_PROXY_USER / DSH_PROXY_PASSWORD 改）"
Write-Host "=================================================="
