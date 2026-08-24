@echo off
title DSH Web (隧道远程模式)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0start_dsh_web_remote.ps1"
pause