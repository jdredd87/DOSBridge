@echo off
REM  One command for Claude Code: compile everything, run it on the DOS machine,
REM  exit non-zero if any test failed. This is the whole loop.
setlocal
call build.cmd %1 run
exit /b %ERRORLEVEL%
