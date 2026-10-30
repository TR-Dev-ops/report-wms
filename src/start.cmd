@echo off
rem Double-click to open the WMS realtime report (Phase 1). Keep the black window open while viewing.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0server.ps1" %*
