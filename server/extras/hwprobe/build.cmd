@echo off
REM  hwprobe -- build NICSCAN, PNPNIC, SNDPROBE and PCILIST with Free Pascal
REM  StevenC & Claude, 2026.
REM
REM    build.cmd       *.pas -> build\*.exe, then compared with bin\
REM
REM  To release a build: run it on a machine with the card, then copy the
REM  EXE into bin\ -- the DOS Bridge kit ships bin\ as it is.  A rebuild on a
REM  new day differs from bin\ in the About unit's date stamp alone.

setlocal
cd /d "%~dp0"
if not exist build mkdir build
for %%p in (nicscan pnpnic sndprobe pcilist) do (
  fpc -Tmsdos -Pi8086 -WmLarge -O2 -Fu..\..\starter -FEbuild -FUbuild %%p.pas >nul || goto fail
  fc /b build\%%p.exe bin\%%p.exe >nul && echo %%p.exe IDENTICAL to bin\ || echo %%p.exe differs from bin\
)
exit /b 0

:fail
echo build FAILED
exit /b 1
