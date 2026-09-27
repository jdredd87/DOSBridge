@echo off
REM  build.cmd [name]      compile <name>.pas for real-mode DOS
REM  build.cmd [name] run  ...and immediately run it on the DOS machine
REM
REM  Default target is hello. Requires the FPC i8086-msdos cross-compiler
REM  and C:\dosbridge on PATH.
REM
REM  The tools' sources are here; the demos' (RAYCAST, PARALLAX, SCROLLER, ...)
REM  and the units only they use are in demos\.  A name is looked for here
REM  first, then in demos\, and everything builds into the one build\ -- the
REM  folder the kit, dosctl upgrade and verify all read.

setlocal
set TARGET=%1
if "%TARGET%"=="" set TARGET=hello
if not exist build mkdir build

set SRC=%TARGET%.pas
set DIR=.
if not exist %SRC% if exist demos\%TARGET%.pas (
  set SRC=demos\%TARGET%.pas
  set DIR=demos
)
if not exist %SRC% (
  echo No %TARGET%.pas here or in demos\
  exit /b 1
)

REM  A target opts into optimisation by having <name>.o2 beside it, and gets
REM  its OWN unit directory when it does -- build\ is shared by every target,
REM  so optimised units would otherwise follow into the network tools. See
REM  the .o2 file itself for why that matters.
set OPTFLAG=
set UNITDIR=build
if exist %DIR%\%TARGET%.o2 (
  set OPTFLAG=-O2
  set UNITDIR=build-%TARGET%
  if not exist build-%TARGET% mkdir build-%TARGET%
)

fpc -Tmsdos -Pi8086 -WmLarge %OPTFLAG% -Fu. -Fudemos -FEbuild -FU%UNITDIR% %SRC%
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
