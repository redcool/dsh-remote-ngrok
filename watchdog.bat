@echo off
rem DSH web 看门狗（双击启动；已在运行则自动退出）
start "dsh-watchdog" /min powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0watch-dsh-restart.ps1"
