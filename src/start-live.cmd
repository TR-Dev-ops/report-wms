@echo off
rem LIVE data (Phase 2): double-click to start the WMS fetcher (its own window) and the web server.
rem Needs ..\.env  (copy .env.example to .env in the project folder and fill it in yourself).
rem Sample data only: use start.cmd instead.
if not exist "%~dp0..\.env" (
  echo .env not found in the project folder.
  echo Copy .env.example to .env and fill in WMS_BASE_URL, WMS_USERNAME, WMS_PASSWORD - see README section 8.
  pause
  exit /b 1
)
start "WMS fetcher - keep this window open" cmd /k powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0fetch-wms.ps1"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0server.ps1" -Live %*
