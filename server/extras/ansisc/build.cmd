@echo off
REM  ansisc -- build ANSI.SYS on the DOS machine, from MS-DOS 4.0 source
REM  StevenC & Claude, 2026
REM
REM    build.cmd          src\  -> build\ANSISC.SYS   (ours)
REM    build.cmd ms40     ms40\ -> build\ANSI40.SYS   (Microsoft's, unchanged)
REM
REM  The source, the includes and the tools (MASM 5, LINK, EXE2BIN,
REM  BUILDMSG, BUILDIDX) are Microsoft's MS-DOS 4.0 release, MIT licence:
REM  https://github.com/microsoft/MS-DOS.  They are real-mode DOS programs,
REM  so the build runs on the DOS box over DOSBridge.

setlocal
cd /d "%~dp0"
if "%DOSBRIDGE%"=="" set DOSBRIDGE=C:\dosbridgeDEV
set WHICH=src
set OUTNAME=ANSISC.SYS
if /i "%1"=="ms40" set WHICH=ms40
if /i "%1"=="ms40" set OUTNAME=ANSI40.SYS
if not "%ANSIOUT%"=="" set OUTNAME=%ANSIOUT%
set DOSCTL=python "%DOSBRIDGE%\dosctl.py"

if not exist build mkdir build
python stage.py %WHICH% build\ANSIB.ZIP || goto fail
REM  Never DEL *.* here: it asks "Are you sure?" and the box waits for a key.
%DOSCTL% exec "IF NOT EXIST C:\ANSIB\NUL MD C:\ANSIB" "IF EXIST C:\ANSIB\ANSI.SYS DEL C:\ANSIB\ANSI.SYS" "IF EXIST C:\ANSIB\ANSI.EXE DEL C:\ANSIB\ANSI.EXE" "IF EXIST C:\ANSIB\*.OBJ DEL C:\ANSIB\*.OBJ" || goto fail
%DOSCTL% deploy "%~dp0build\ANSIB.ZIP" C:\ANSIB || goto fail
REM  Each step is its own command: COMMAND.COM cannot redirect the output of
REM  a CALLed batch file, so a BLD.BAT would lose every error message.
%DOSCTL% exec --timeout 900 "CD C:\ANSIB" "C:\SOFTWARE\PKZIP\PKUNZIP.EXE -o ANSIB.ZIP > NUL" "BUILDIDX USA-MS.MSG > NUL" "BUILDMSG USA-MS ANSI.SKL > NUL" "MASM -Mx -I. ANSI.ASM,ANSI.OBJ;" "MASM -Mx -I. IOCTL.ASM,IOCTL.OBJ;" "MASM -Mx -I. ANSIINIT.ASM,ANSIINIT.OBJ;" "MASM -Mx -I. PARSER.ASM,PARSER.OBJ;" "LINK @ANSI.LNK" "EXE2BIN ANSI.EXE ANSI.SYS" || goto fail
%DOSCTL% pull C:\ANSIB\ANSI.SYS --out "%~dp0build\%OUTNAME%" || goto fail
echo built build\%OUTNAME%
exit /b 0

:fail
echo build FAILED
exit /b 1
