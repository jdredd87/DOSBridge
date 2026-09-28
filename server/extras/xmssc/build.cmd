@echo off
REM  xmssc -- assemble XMSSC.SYS and XMSSC.COM with NASM, and build the tests
REM  StevenC & Claude, 2026.  Public domain (the Unlicense).
REM
REM    build.cmd       XMSSC.ASM          -> build\XMSSC.SYS, build\XMSSC.COM
REM                    test\IRQCOUNT.ASM  -> build\IRQCOUNT.COM
REM                    test\xmstest.pas   -> build\xmstest.exe  (Free Pascal)
REM
REM  To release a build: test\emuxms.py must pass every configuration, and
REM  XMSTEST must pass on the machine; then copy the two drivers into bin\
REM  -- the DOS Bridge kit ships bin\ as it is.  NASM is the one Free Pascal
REM  ships (C:\FPC\3.2.2\bin\i386-Win32\nasm.exe) or any other.
REM
REM  The probes (test\xprobe*.pas) build the same way as xmstest:
REM    fpc -Tmsdos -Pi8086 -WmLarge -Fu..\..\starter -FEbuild -FUbuild test\xprobe.pas

setlocal
cd /d "%~dp0"
if not exist build mkdir build
nasm -f bin -o build\XMSSC.SYS -l build\XMSSC.LST XMSSC.ASM || goto fail
nasm -f bin -DCOM -o build\XMSSC.COM XMSSC.ASM || goto fail
nasm -f bin -o build\IRQCOUNT.COM test\IRQCOUNT.ASM || goto fail
fpc -Tmsdos -Pi8086 -WmLarge -Fu..\..\starter -FEbuild -FUbuild test\xmstest.pas >nul || goto fail
echo built build\XMSSC.SYS, build\XMSSC.COM, build\IRQCOUNT.COM, build\xmstest.exe
fc /b build\XMSSC.SYS bin\XMSSC.SYS >nul && echo XMSSC.SYS IDENTICAL to bin\ || echo XMSSC.SYS differs from bin\
fc /b build\XMSSC.COM bin\XMSSC.COM >nul && echo XMSSC.COM IDENTICAL to bin\ || echo XMSSC.COM differs from bin\
exit /b 0

:fail
echo build FAILED
exit /b 1
