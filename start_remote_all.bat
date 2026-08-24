@echo off
rem DSH 远程访问一键拉起（proxy + ngrok + dsh web）
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0start_remote_all.ps1"
pause
