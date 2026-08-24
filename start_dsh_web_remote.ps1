# ============================================================
# DSH Web 隧道模式启动器（重启 dsh web，带 --trusted-host）
# 用法：双击 start_dsh_web_remote.bat 即可（页面会断约 3 秒后自动恢复）
# 效果：绑定 127.0.0.1:3080，公网入口只有 ngrok 隧道（proxy 密码保护）
# ⚠️ 提交 GitHub 前：把下方 PASSWORD 换成你自己的强密码（不要提交真实密码）
# ============================================================

$ErrorActionPreference = 'Continue'

# ========== 配置区（按本机修改） ==========
# ngrok 隧道域名（与当前 ngrok URL 一致；重启 ngrok 变了就更新这里）
$ngrokHost = "happier-custodian-hastily.ngrok-free.dev"
# proxy 登录页凭据（仅用于启动横幅提示；proxy 实际从 DSH_PROXY_USER/PASSWORD 环境变量读取）
$DSH_USER = "dsh"
$DSH_PASSWORD = "PLEASE_SET_YOUR_OWN_PASSWORD"
# dsh 安装位置与数据目录
$DSH_DIR  = "H:\AI\dsh"
$DSH_HOME = "D:\Users\Admin\.dsh"
# ========== 配置区结束 ==========

# 1) 按端口发现并停止旧 dsh web（不管 PID 是多少）
try {
    $conn = Get-NetTCPConnection -LocalPort 3080 -State Listen -ErrorAction Stop
    $oldPid = $conn.OwningProcess
    if ($oldPid -and $oldPid -ne $PID) {
        Write-Host "[*] 停止旧 dsh web (PID $oldPid, 监听 3080) ..."
        Stop-Process -Id $oldPid -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 2
    }
} catch {
    Write-Host "[*] 3080 无旧实例（干净启动）"
}

# 2) 启动前再确认端口已空闲
if (Get-NetTCPConnection -LocalPort 3080 -State Listen -ErrorAction SilentlyContinue) {
    Write-Host "[!] 3080 仍被占用，启动中止（请手动结束占用进程后重试）" -ForegroundColor Red
    exit 1
}

# 3) 以隧道模式启动 dsh web（前台运行，保持此窗口开着 = dsh web 在跑）
# 绑定保持 127.0.0.1：仅本机可达，公网入口只有 ngrok 隧道，安全面最小
# ⚠️ trusted-host 需与当前 ngrok URL 域名一致；同时给出 无端口 / :443 / :80 三种形式，
#    覆盖 fence 对不同 Origin 端口的匹配（https=443）
Write-Host "[*] 启动 dsh web →  本机 http://127.0.0.1:3080  |  公网隧道 https://$ngrokHost （账号 $DSH_USER）"
Set-Location $DSH_DIR
$env:DSH_HOME = $DSH_HOME
& "$DSH_DIR\node_modules\.bin\dsh.ps1" web --port 3080 --trusted-host $ngrokHost --trusted-host "$ngrokHost:443" --trusted-host "$ngrokHost:80" --no-open
Write-Host "[*] dsh web 已退出 (code=$LASTEXITCODE)"