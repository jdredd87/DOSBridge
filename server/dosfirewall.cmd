@echo off
REM Opens the firewall for the DOS boxes. Needs Administrator -- the script
REM says so and stops if it is not elevated. See dosfirewall.ps1 for why.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0dosfirewall.ps1" %*
