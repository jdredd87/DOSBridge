@ECHO OFF
REM ===================================================================
REM  dosbridge client install, for MS-DOS 6.22
REM
REM    INSTALL              mTCP assumed in C:\MTCP
REM    INSTALL C:\NET\MTCP  mTCP somewhere else
REM
REM  Creates the four working directories, installs the agent loop and
REM  the tools, and drops a suggested AUTOEXEC at C:\AUTOEXEC.NEW.
REM
REM  It does NOT touch your AUTOEXEC.BAT or CONFIG.SYS. Overwriting a
REM  boot file from a script on a machine you may not be sitting at is
REM  how you end up needing a boot floppy.
REM ===================================================================

SET MTCPDIR=%1
IF "%MTCPDIR%"=="" SET MTCPDIR=C:\MTCP

ECHO.
ECHO dosbridge client install
ECHO ========================
ECHO   mTCP directory: %MTCPDIR%
ECHO.

REM --- directories ---------------------------------------------------
REM \NUL is the DOS idiom for "does this directory exist".
IF NOT EXIST C:\AI\NUL MD C:\AI
IF NOT EXIST C:\AGENT\NUL MD C:\AGENT
IF NOT EXIST C:\TOOLS\NUL MD C:\TOOLS
IF NOT EXIST C:\WORK\NUL MD C:\WORK
IF NOT EXIST %MTCPDIR%\NUL MD %MTCPDIR%
ECHO [1/4] Directories: C:\AI C:\AGENT C:\TOOLS C:\WORK

REM --- agent loop ----------------------------------------------------
REM Destinations are spelled out in full on purpose. "COPY X C:\AI\"
REM with a trailing backslash fails silently on DOS 6.22.
COPY AI.BAT C:\AI\AI.BAT > NUL
COPY REBOOT.COM C:\AI\REBOOT.COM > NUL
COPY COLDBOOT.COM C:\AI\COLDBOOT.COM > NUL
REM  The build stamp AI.BAT shows at boot, so the machine itself can say
REM  which version it is running without asking the Windows side.
IF EXIST VERSION.TXT COPY VERSION.TXT C:\AI\VERSION.TXT > NUL
ECHO [2/4] Agent loop  -^> C:\AI

REM --- tools ---------------------------------------------------------
IF NOT EXIST *.EXE GOTO NOTOOLS
COPY *.EXE C:\TOOLS > NUL
ECHO [3/4] Tools       -^> C:\TOOLS
GOTO CFG
:NOTOOLS
ECHO [3/4] Tools       -^> none in this kit, skipped

REM --- mTCP config ---------------------------------------------------
:CFG
REM  Your MTCP.CFG is NEVER written, overwritten or edited by this script.
REM  It holds settings only you know -- the packet interrupt your card is on,
REM  and on a DHCP setup a lease that other tools rely on. An example is
REM  dropped alongside it instead, and merging is left to you.
COPY MTCP.NEW %MTCPDIR%\MTCP.NEW > NUL
IF EXIST %MTCPDIR%\MTCP.CFG GOTO HAVECFG
ECHO [4/4] mTCP config -^> wrote %MTCPDIR%\MTCP.NEW
ECHO       You have no MTCP.CFG yet. To use the example as-is:
ECHO           REN %MTCPDIR%\MTCP.NEW MTCP.CFG
GOTO CFGDONE
:HAVECFG
ECHO [4/4] mTCP config -^> wrote %MTCPDIR%\MTCP.NEW
ECHO       Your existing MTCP.CFG was left untouched. Compare the two and
ECHO       copy across only what you need (IPADDR, NETMASK, GATEWAY).
:CFGDONE

REM --- suggested AUTOEXEC --------------------------------------------
:AUTOEX
COPY AUTOEXEC.NEW C:\AUTOEXEC.NEW > NUL

ECHO.
ECHO Done. Nothing has been made to run yet.
ECHO.
ECHO NEXT, BY HAND:
ECHO   1. Check %MTCPDIR% has HTGET.EXE and NC.EXE from mTCP.
ECHO   2. Check your packet driver loads (PM2000.COM or NE2000.COM).
ECHO   3. Merge %MTCPDIR%\MTCP.NEW into your MTCP.CFG, or rename it
ECHO      if you do not have one. IPADDR, NETMASK, GATEWAY.
ECHO   4. Compare C:\AUTOEXEC.NEW against your AUTOEXEC.BAT and merge
ECHO      the parts you want. Keep a backup:
ECHO         COPY C:\AUTOEXEC.BAT C:\AUTOEXEC.SAV
ECHO   5. Reboot. The Windows side should log a poll within seconds.
ECHO.
ECHO Do NOT run DHCP. See the README - an expiring lease strands the
ECHO machine and the agent loop cannot recover from it on its own.
ECHO.
