@echo off
REM  umbsc -- assemble UMBSC.SYS with NASM
REM  StevenC & Claude, 2026.  Public domain.
REM
REM    build.cmd       UMBSC.ASM -> build\UMBSC.SYS
REM
REM  To release a build, test it (test\emuumb.py) and copy it into bin\: the
REM  DOS Bridge kit ships bin\ as it is.  NASM is the one Free Pascal ships
REM  (C:\FPC\3.2.2\bin\i386-Win32\nasm.exe) or any other.

setlocal
cd /d "%~dp0"
if not exist build mkdir build
nasm -f bin -o build\UMBSC.SYS UMBSC.ASM || goto fail
echo built build\UMBSC.SYS
fc /b build\UMBSC.SYS bin\UMBSC.SYS >nul && echo IDENTICAL to bin\UMBSC.SYS || echo differs from bin\UMBSC.SYS
exit /b 0

:fail
echo build FAILED
exit /b 1
