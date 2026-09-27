@echo off
REM  doskeysc -- assemble DOSKEYSC.COM with NASM
REM  StevenC & Claude, 2026.  Public domain.
REM
REM    build.cmd       DOSKEYSC.ASM -> build\DOSKEYSC.COM, and the test tool
REM                    test\DKTEST.ASM -> build\DKTEST.COM
REM
REM  To release a build, run the tests (README.md, "Proven") and copy it into
REM  bin\: the DOS Bridge kit ships bin\ as it is.  NASM is the one Free Pascal
REM  ships (C:\FPC\3.2.2\bin\i386-Win32\nasm.exe) or any other.

setlocal
cd /d "%~dp0"
if not exist build mkdir build
nasm -f bin -o build\DOSKEYSC.COM -l build\DOSKEYSC.LST DOSKEYSC.ASM || goto fail
nasm -f bin -o build\DKTEST.COM test\DKTEST.ASM || goto fail
echo built build\DOSKEYSC.COM and build\DKTEST.COM
fc /b build\DOSKEYSC.COM bin\DOSKEYSC.COM >/dev/null && echo IDENTICAL to bin\DOSKEYSC.COM || echo differs from bin\DOSKEYSC.COM
exit /b 0

:fail
echo build FAILED
exit /b 1
