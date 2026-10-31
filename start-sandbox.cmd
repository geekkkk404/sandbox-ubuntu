@echo off
rem Double-click entry: pick an Ubuntu version, get a fresh disposable sandbox.
rem See README.md for details. Args are forwarded, e.g.:
rem   start-sandbox.cmd -Version 22.04        (skip the menu)
rem   start-sandbox.cmd -SkipShell            (verify only, no interactive shell)
rem   start-sandbox.cmd -ListVersions
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0start-sandbox.ps1" %*
