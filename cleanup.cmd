@echo off
rem Force-clean leftover sandbox/base-build instances (use after an abnormal exit).
rem Verified cleanup + honest report: see cleanup.ps1 (same standard as start-sandbox.ps1).
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0cleanup.ps1" %*
