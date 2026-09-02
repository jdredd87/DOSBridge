@ECHO OFF
REM  Addresses first: the banner below echoes them, so a box pointed at the
REM  wrong server says so on its own screen instead of just going quiet.
REM  `dosctl upgrade --agent` parses these two lines, so leave them alone --
REM  and never put the words SET S-R-V inside an ECHO, or the guard reads its
REM  own output back and thinks the address changed.
SET SRV=192.168.50.46:8080
SET UPHOST=192.168.50.46

REM  TZ lives here and not in AUTOEXEC.BAT: a mistake in AUTOEXEC.BAT breaks
REM  the network before the agent runs and needs hands on the keyboard, while
REM  a mistake here is fixable over the wire. mTCP refuses to stamp file
REM  timestamps without it and says so on every poll. Set it to YOUR zone;
REM  this is US Eastern. The environment on this box is nearly full, so if
REM  this prints "Out of environment space" it is harmless -- you lose the
REM  timestamps and the warning, and nothing else.
IF "%TZ%"=="" SET TZ=EST5EDT

:BANNER
ECHO.
echo ===================================================================
echo  dosd agent for MS-DOS 6.22
echo ===================================================================
REM  What this machine is running. Written by the client installer and
REM  rewritten by `dosctl upgrade`, so the box can answer the question
REM  itself instead of someone having to go and ask the Windows side.
IF EXIST C:\AI\VERSION.TXT TYPE C:\AI\VERSION.TXT
ECHO.
ECHO  jobs from   : %SRV%
ECHO  results to  : %UPHOST% port 8081
REM  Its own address, from whichever config mTCP is actually using. When this
REM  box went silent on an expired DHCP lease that was the missing fact: the
REM  screen looked healthy and said nothing about the network at all.
REM
REM  Branched with GOTO rather than chained as "IF NOT ... IF EXIST ... FIND",
REM  because COMMAND.COM 6.22 honours a chained IF when the command is
REM  INTERNAL (ECHO, GOTO) and SILENTLY DROPS IT when the command is EXTERNAL.
REM  FIND is external, so the chained form printed nothing at all and read as
REM  a missing config file. Copying MTCPCFG to a temp variable first is no
REM  good either -- it ran the environment out of space and truncated the path.
IF NOT "%MTCPCFG%"=="" GOTO SHOWIP
ECHO  own address : MTCPCFG is not set -- check AUTOEXEC.BAT
GOTO IPDONE
:SHOWIP
IF EXIST %MTCPCFG% FIND "IPADDR" %MTCPCFG%
IF NOT EXIST %MTCPCFG% ECHO  own address : no mTCP config at %MTCPCFG%
:IPDONE
ECHO.
IF EXIST C:\TOOLS\KEYHIT.COM ECHO  To stop the agent: press ScrollLock, or Ctrl-C.
IF NOT EXIST C:\TOOLS\KEYHIT.COM ECHO  KEYHIT.COM missing from C:\TOOLS - Ctrl-C is the only way out.
ECHO.
REM  Nothing above this line may block or touch the network. All of it runs
REM  before the agent starts polling, so anything that waits for input -- a
REM  bare DATE or TIME, a CHOICE with no timeout -- is a machine that boots,
REM  looks fine, and never calls home. That needs hands on the keyboard.
REM
REM  This banner scrolls off within about a minute, and that is a deliberate
REM  trade rather than a limitation. mTCP prints a version block on every
REM  poll, straight to the console where > NUL cannot catch it and
REM  COMMAND.COM 6.22 has no way to redirect it. HTGET -quiet DOES suppress
REM  it -- verified -- and the loop deliberately does not use it, because
REM  that chatter is the only continuous sign the machine has not wedged.
REM  A silent screen and a frozen box look exactly the same, which is the
REM  failure this bridge keeps having to design around. So the banner is a
REM  boot-time display: to see it again, stop the agent (the stop message
REM  repeats the addresses) or reboot.

REM ===================================================================
REM  Crash guard
REM ===================================================================
REM  TRYING.FLG exists at boot  => last boot ran a driver and never got
REM                                back here, i.e. it hung the machine.
REM  PEND.BAT exists, no flag   => a driver is staged and ready to try.
REM ===================================================================

IF EXIST C:\AGENT\TRYING.FLG GOTO CRASHED
IF EXIST C:\AGENT\PEND.BAT GOTO TRYIT
GOTO LOOP

:CRASHED
ECHO *** Previous boot hung. Reverting and reporting. ***
COPY C:\AGENT\PENDID.TXT C:\AGENT\RES.TXT > NUL
ECHO ##BOOTFAIL driver wedged the machine, not loaded this boot >> C:\AGENT\RES.TXT
ECHO ##RC=253 >> C:\AGENT\RES.TXT
NC -target %UPHOST% 8081 < C:\AGENT\RES.TXT > NUL
DEL C:\AGENT\TRYING.FLG
IF EXIST C:\AGENT\PEND.BAT DEL C:\AGENT\PEND.BAT
GOTO LOOP

:TRYIT
ECHO Loading staged driver...
ECHO trying > C:\AGENT\TRYING.FLG
CALL C:\AGENT\PEND.BAT
DEL C:\AGENT\TRYING.FLG
DEL C:\AGENT\PEND.BAT
COPY C:\AGENT\PENDID.TXT C:\AGENT\RES.TXT > NUL
ECHO ##BOOTOK machine survived the driver load >> C:\AGENT\RES.TXT
ECHO --- driver load output --- >> C:\AGENT\RES.TXT
IF EXIST C:\AGENT\DRVOUT.TXT TYPE C:\AGENT\DRVOUT.TXT >> C:\AGENT\RES.TXT
IF NOT EXIST C:\AGENT\DRVOUT.TXT ECHO (no output captured) >> C:\AGENT\RES.TXT
ECHO --- MEM /C --- >> C:\AGENT\RES.TXT
MEM /C >> C:\AGENT\RES.TXT
ECHO ##RC=0 >> C:\AGENT\RES.TXT
NC -target %UPHOST% 8081 < C:\AGENT\RES.TXT > NUL
GOTO LOOP

REM ===================================================================
REM  Main job loop
REM ===================================================================
REM  Both clean exits land HERE, at the top, between jobs. That is the whole
REM  point of them: Ctrl-C stops wherever it happens to land, and mid-JOB.BAT
REM  that means the closing NC never runs, so the Windows side waits its full
REM  timeout and then wrongly calls the box hung. Inside :TRYIT it is worse --
REM  it leaves TRYING.FLG behind and the next boot reports a driver crash that
REM  never happened. Ctrl-C stays as the hammer for a job that is truly stuck.
REM ===================================================================

:LOOP
IF EXIST C:\AGENT\STOP.FLG GOTO QUIT
REM  KEYHIT tests the ScrollLock bit in the BIOS keyboard flags -- NOT a
REM  keystroke. A queued keypress cannot work here: mTCP watches the keyboard
REM  so ESC can abort a transfer, and it consumes whatever is waiting, so a Q
REM  pressed during the poll is eaten by HTGET before this line runs. Measured,
REM  not assumed. ScrollLock is a flag bit nothing else touches, and its LED
REM  shows the state without needing anything on screen.
REM
REM  Checked BEFORE the fetch. Keys survive in the flag either way, but after
REM  the fetch this would throw away a job HTGET had already collected, and
REM  dosd would wait for a result that never came and time out calling the box
REM  hung -- the exact wrong-blame failure these exits exist to avoid.
REM
REM  Guarded by IF EXIST because without it a missing KEYHIT.COM would leave
REM  the previous errorlevel standing and the ladder would read that instead.
IF NOT EXIST C:\TOOLS\KEYHIT.COM GOTO NOKEY
C:\TOOLS\KEYHIT.COM
IF ERRORLEVEL 1 GOTO QUIT
:NOKEY
IF EXIST C:\AGENT\JOB.BAT DEL C:\AGENT\JOB.BAT
REM  Not -quiet. It works, and it is left off on purpose: see the banner
REM  note above. The four lines this prints per poll are the heartbeat.
HTGET -o C:\AGENT\JOB.BAT http://%SRV%/job > NUL
IF NOT EXIST C:\AGENT\JOB.BAT GOTO OFFLINE
CALL C:\AGENT\JOB.BAT
GOTO LOOP

:OFFLINE
ECHO dosd unreachable at %SRV% - retrying, Q quits...
REM  If CHOICE is missing the errorlevel is HTGET, which is >= 20, so this
REM  falls to GOTO LOOP. The safe direction: keep polling rather than exit.
REM  Q works here and nowhere else, because CHOICE reads the keyboard itself.
CHOICE /C:QY /T:Y,5
IF ERRORLEVEL 2 GOTO LOOP
GOTO QUIT

:QUIT
REM  Clear the flag on the way out, or restarting the agent would stop it
REM  again immediately.
IF EXIST C:\AGENT\STOP.FLG DEL C:\AGENT\STOP.FLG
IF EXIST C:\AGENT\JOB.BAT DEL C:\AGENT\JOB.BAT
ECHO.
ECHO ===================================================================
ECHO  Agent stopped. Nothing is polling now, so dosctl on the Windows
ECHO  side cannot reach this machine until it is running again.
ECHO.
ECHO   jobs from   : %SRV%
ECHO   results to  : %UPHOST% port 8081
IF NOT "%MTCPCFG%"=="" GOTO QIP
ECHO   own address : MTCPCFG is not set
GOTO QIPDONE
:QIP
IF EXIST %MTCPCFG% FIND "IPADDR" %MTCPCFG%
:QIPDONE
ECHO.
ECHO  If ScrollLock stopped it, turn ScrollLock OFF or it will stop again.
ECHO  Then type  C:\AI\AI.BAT  to restart. Rebooting also restarts it.
ECHO ===================================================================
ECHO.
GOTO END

:NONET
ECHO.
ECHO *** Network failed to start. Check the packet driver settings above
ECHO *** and the PicoMEM WiFi config. Dropping to a prompt.
ECHO.

:END
REM ##AGENT-END
