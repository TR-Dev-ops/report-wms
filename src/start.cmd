@echo off
rem Double-click to open the WMS realtime report with the data file set in web\config.json (default: sample data).
rem Keep the black window open while viewing. Live WMS data: use start-live.cmd
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0server.ps1" %*
