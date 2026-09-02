@echo off
REM  build.cmd [name]      compile <name>.pas for real-mode DOS
REM  build.cmd [name] run  ...and immediately run it on the DOS machine
REM
REM  Default target is hello. Requires the FPC i8086-msdos cross-compiler
REM  and C:\dosbridge on PATH.

setlocal
set TARGET=%1
if "%TARGET%"=="" set TARGET=hello
if not exist build mkdir build

fpc -Tmsdos -Pi8086 -WmLarge -FEbuild -FUbuild %TARGET%.pas
if errorlevel 1 (
  echo.
  echo BUILD FAILED
  exit /b 1
)

if /I "%2"=="run" (
  echo.
  dosrun build\%TARGET%.exe
  exit /b %ERRORLEVEL%
)

echo.
echo Built build\%TARGET%.exe  --  run it with:  dosrun build\%TARGET%.exe
