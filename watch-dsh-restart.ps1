# ============================================================
# dsh web 看门狗：监控 3080，挂了自动拉起 start_remote_all.bat
# 2026-09-19 用户需求：确保 dsh 挂了及时重上线
#
# 行为：
#   - 启动后 60 秒宽限期（避免和用户手动启动竞争）
#   - 3080 连续 3 次（每 5 秒）检测空闲 -> 运行 start_remote_all.bat
#   - 拉起后最多等 4 分钟确认 3080 上线；未上线记日志但不立即重试
#   - 10 分钟内最多重启 3 次，超限进入 30 分钟冷却（防故障死循环）
#   - 全程写日志到本目录 watchdog.log（带毫秒时间戳）
#
# 常驻方式：计划任务 ONLOGON（登录即自动启动，见注册命令）或加入 shell:startup
# ============================================================
$ErrorActionPreference = "Continue"
$toolsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$batFile  = Join-Path $toolsDir "start_remote_all.bat"
$logFile  = Join-Path $toolsDir "watchdog.log"
$startupGraceSec = 60
$confirmCount    = 3
$confirmInterval = 5
$waitUpSec       = 240
$maxRestarts     = 3
$cooldownSec     = 1800
$restartTimes    = [System.Collections.ArrayList]@()

# --- 单实例保护：同一登录会话只允许一个 watchdog（防 start_remote_all.bat 反复拉起多开打架）---
$watchdogMutex = $null
try {
  $watchdogMutex = [System.Threading.Mutex]::new($false, "dsh-web-watchdog")
  if (-not $watchdogMutex.WaitOne(0)) {
    Write-Host "watchdog 已在运行，本实例退出（PID 见 watchdog.log）"
    exit 0
  }
} catch {
  # 权限等异常时退化为不检查，宁可允许重复也不让监控缺失
  Write-Host "[!] 单实例锁不可用（$($_.Exception.Message)），继续运行"
}

function Log([string]$msg) {
  $line = "[{0}] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff"), $msg
  Write-Host $line
  try { [System.IO.File]::AppendAllText($logFile, $line + [Environment]::NewLine, (New-Object System.Text.UTF8Encoding($false))) } catch { }
}

function Test-3080Up {
  return $null -ne (Get-NetTCPConnection -LocalPort 3080 -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1)
}

Log "watchdog v1 started (PID=$PID, grace=${startupGraceSec}s)"
Log "  bat=$batFile log=$logFile"
$startedAt = Get-Date
$skipUntil = $null

while ($true) {
  Start-Sleep -Seconds 5

  if ($skipUntil -and (Get-Date) -lt $skipUntil) { continue }
  if ((Get-Date) -lt $startedAt.AddSeconds($startupGraceSec)) { continue }

  if (Test-3080Up) {
    $restartTimes.Clear()
    continue
  }

  # 空闲确认：连续 confirmCount 次都是空闲才判定 dsh 真挂了
  $stillFree = $true
  for ($i = 1; $i -le $confirmCount; $i++) {
    Start-Sleep -Seconds $confirmInterval
    if (Test-3080Up) { $stillFree = $false; break }
  }
  if (-not $stillFree) { continue }

  # 频率限制：10 分钟内最多重启 maxRestarts 次
  $now = Get-Date
  $windowStart = $now.AddMinutes(-10)
  $recent = @($restartTimes | Where-Object { $_ -gt $windowStart })
  if ($recent.Count -ge $maxRestarts) {
    $skipUntil = $now.AddSeconds($cooldownSec)
    Log "10 分钟内已重启 $($recent.Count) 次，进入 ${cooldownSec}s 冷却（疑似故障循环，暂停自动拉起）"
    continue
  }

  Log "dsh 3080 空闲确认（连续 ${confirmCount} 次 x ${confirmInterval}s）——拉起：$batFile"
  try {
    $proc = Start-Process -FilePath "cmd.exe" -ArgumentList "/c", "`"$batFile`"" -WorkingDirectory $toolsDir -PassThru
    Log "已拉起 start_remote_all.bat（cmd pid=$($proc.Id)），等待 3080 上线（最多 ${waitUpSec}s）..."
    $null = $restartTimes.Add($now)
    $deadline = (Get-Date).AddSeconds($waitUpSec)
    $up = $false
    while ((Get-Date) -lt $deadline) {
      Start-Sleep -Seconds 5
      if (Test-3080Up) { $up = $true; break }
    }
    if ($up) {
      $conn = Get-NetTCPConnection -LocalPort 3080 -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
      Log "3080 已恢复（PID=$($conn.OwningProcess)）"
    } else {
      Log "等待 ${waitUpSec}s 后 3080 仍未上线——本轮不立即重试，请查同目录 logs/dsh-web.log"
    }
  } catch {
    Log "拉起失败：$($_.Exception.Message)"
  }
}