@echo off
rem LIVE data + LAN view (Phase 3): like start-live.cmd, but allowed team computers on the LAN can open the pages too.
rem Before the first use the owner / IT does README section 8.9 (URL registration + firewall rule, Run as administrator).
rem This file never changes Windows settings and never asks for admin rights.
rem Allowed LAN ranges + click quotas: src\lan.local.json (copy lan.example.json; without it = private ranges + a warning).
rem Stop LAN mode: close this window (and the fetcher window), then use start-live.cmd as before.
if not exist "%~dp0..\.env" (
  echo .env not found in the project folder.
  echo Copy .env.example to .env and fill in WMS_BASE_URL, WMS_USERNAME, WMS_PASSWORD - see README section 8.
  pause
  exit /b 1
)
start "WMS fetcher - keep this window open" cmd /k powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0fetch-wms.ps1"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0server.ps1" -Live -Lan %*
