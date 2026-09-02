@echo off
REM Installs the Windows half: PATH, firewall rule, directories.
REM Run check.cmd first to see what is missing. Safe to run twice.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1" %*
