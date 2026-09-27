@ECHO OFF
REM  Addresses first: the banner below echoes them, so a box pointed at the
REM  wrong server says so on its own screen instead of just going quiet.
REM  `dosctl upgrade --agent` parses these two lines, so leave them alone --
REM  and never put the words SET S-R-V inside an ECHO, or the guard reads its
REM  own output back and thinks the address changed.
REM
REM  Nothing on this box uses SRV any more -- the loop polls UPHOST over
REM  UDP and mTCP is gone. It stays because it is half of the address
REM  check above, which is what stops an upgrade from installing an agent
REM  that points somewhere this machine cannot reach.
SET SRV=192.168.1.10:8080
SET UPHOST=192.168.1.10

REM  Which machine this is, when more than one DOS box shares the bridge.
REM  It rides in the poll's resource name -- `job.v30` instead of `job` --
REM  so dosd can hand each box its own queue. `dosctl upgrade --agent`
REM  writes this line from boxes.json, which is the registry dosd routes
REM  on, so the two cannot disagree.
REM
REM  LEAVING IT EMPTY IS FINE and is what every box did before this: dosd
REM  then routes the poll on the source address alone, which is why a
REM  second machine can join the bridge without this file being touched at
REM  all. What the id buys is the cross-check -- a box that says who it is
REM  AND polls from where it should be lets dosd shout when those two stop
REM  agreeing, which is what a cloned SD card or a moved card looks like.
REM
REM  One variable, not three, and the poll is branched below rather than
REM  built from it. The environment on this box is nearly full, and a SET
REM  that fails with "Out of environment space" would leave a name half
REM  built -- a poll for `job.` that no dosd will ever answer.
SET BOXID=

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
ECHO  server      : %UPHOST%   (UDP 8069, no mTCP)
REM  Its own address. When this box went silent on an expired DHCP lease that
REM  was the missing fact: the screen looked healthy and said nothing at all
REM  about the network.
REM
REM  UGET -INFO rather than FIND on the config file. FIND printed a filename
REM  header line as well as the address -- two lines, one of them noise -- and
REM  it could only ever read mTCP's config, not the bridge's own. -INFO
REM  reports whichever file was actually used, which matters now there are
REM  two candidates.
IF EXIST C:\TOOLS\UGET.EXE C:\TOOLS\UGET.EXE -INFO
IF NOT EXIST C:\TOOLS\UGET.EXE ECHO  address     : UGET.EXE missing, no network
IF EXIST C:\TOOLS\KEYHIT.COM ECHO  stop        : ScrollLock, or Ctrl-C
IF NOT EXIST C:\TOOLS\KEYHIT.COM ECHO  stop        : Ctrl-C only (no KEYHIT.COM)
echo -------------------------------------------------------------------
REM  Nothing above this line may block or touch the network. All of it runs
REM  before the agent starts polling, so anything that waits for input -- a
REM  bare DATE or TIME, a CHOICE with no timeout -- is a machine that boots,
REM  looks fine, and never calls home. That needs hands on the keyboard.
REM
REM  This banner now STAYS. It used to scroll away within a minute because
REM  mTCP printed a version block on every poll straight to the console,
REM  which "> NUL" cannot catch and COMMAND.COM 6.22 cannot redirect. With
REM  the poll on our own UDP the loop prints nothing at all; the only moving
REM  thing is UGET's in-place spinner, and jobs announce themselves as they
REM  run. So the screen is a live status display rather than a scrollback.

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
REM  The crash report is the one thing you cannot afford to lose: it is the
REM  only way the machine can say WHY it hung. UPUT retransmits internally,
REM  and if it still fails the next boot has nothing to add anyway.
C:\TOOLS\UPUT.EXE %UPHOST% C:\AGENT\RES.TXT result
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
C:\TOOLS\UPUT.EXE %UPHOST% C:\AGENT\RES.TXT result
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

REM  A flag left by the outage that was in progress when the box went
REM  down would silence the first [offline] notice after a reboot.
IF EXIST C:\AGENT\OFFLINE.FLG DEL C:\AGENT\OFFLINE.FLG
IF EXIST C:\AGENT\OFFSAID.FLG DEL C:\AGENT\OFFSAID.FLG
REM  NETCHK's count of failed polls is per BOOT, and clearing it here is
REM  the half of its loop guard that stops a reboot following straight on
REM  from a reboot: every boot has to fail a full round of polls again
REM  before it may decide anything. NETBOOT.DAT, the count of reboots, is
REM  deliberately NOT cleared here -- only a poll that works clears it.
IF EXIST C:\AGENT\NETFAIL.DAT DEL C:\AGENT\NETFAIL.DAT

:LOOP
IF EXIST C:\AGENT\STOP.FLG GOTO QUIT
REM  KEYHIT tests the ScrollLock bit in the BIOS keyboard flags -- NOT a
REM  keystroke. A queued keypress cannot work here: mTCP watches the keyboard
REM  so ESC can abort a transfer, and it consumed whatever was waiting, so a Q
REM  pressed during the poll was eaten before this line ran. Measured, not
REM  assumed -- and it still decides the design even though mTCP is gone,
REM  because a flag bit is simply the right thing to test.
REM  ScrollLock is a flag bit nothing else touches, and its LED
REM  shows the state without needing anything on screen.
REM
REM  Checked BEFORE the fetch. Keys survive in the flag either way, but after
REM  the fetch this would throw away a job the poll had already collected, and
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
REM  POLL tells UGET this is the long poll: several seconds per attempt,
REM  up to three attempts. Retransmitting a poll request is only safe
REM  because dosd DEDUPLICATES it -- a repeat request from a client it is
REM  already holding one for is ignored, so it cannot take a second job off
REM  the queue while the first goes nowhere. Change one without the other
REM  and jobs start disappearing.
REM
REM  UGET draws a spinner in place while it waits, so an idle box still
REM  shows a pulse without scrolling the banner above away.
REM
REM  Two lines rather than one built from a variable. `job.%BOXID%` with an
REM  empty BOXID asks for `job.`, which is a name no dosd serves, and the
REM  box would poll for ever getting nothing -- a silent machine, and the
REM  one failure mode here that costs a trip to the keyboard. A branch
REM  cannot half-work that way.
IF "%BOXID%"=="" GOTO POLLANY
C:\TOOLS\UGET.EXE %UPHOST% job.%BOXID% C:\AGENT\JOB.BAT POLL
GOTO POLLED
:POLLANY
C:\TOOLS\UGET.EXE %UPHOST% job C:\AGENT\JOB.BAT POLL
:POLLED
REM  There is NO fallback here, and that is the point: this machine needs
REM  no part of mTCP to do its job. The HTGET line that used to sit here
REM  was removed on 2026-09-02 after the poll was measured clean over a
REM  long run -- it had been carrying roughly one poll in five.
REM
REM  A lost poll is now simply a lost poll: UGET gives up, the OFFLINE
REM  branch waits five seconds and the loop tries again. No job is lost
REM  by that -- dosd requeues a job whose UDP delivery went unacked, so
REM  the cost of a miss is latency and nothing else.
REM
REM  If this ever needs putting back, it was one line:
REM    IF NOT EXIST C:\AGENT\JOB.BAT HTGET -quiet -o C:\AGENT\JOB.BAT http://%SRV%/job > NUL
IF NOT EXIST C:\AGENT\JOB.BAT GOTO OFFLINE
REM  A poll worked, so any outage NETCHK was counting is over. /OK logs
REM  the recovery if it had rebooted for it and clears both counters.
REM  Only NETCHK ever creates NETBOOT.DAT, so it is certainly there to run.
IF EXIST C:\AGENT\NETFAIL.DAT DEL C:\AGENT\NETFAIL.DAT
IF EXIST C:\AGENT\NETBOOT.DAT C:\TOOLS\NETCHK.EXE /OK
REM  Coming back after an outage is worth exactly one line. Without
REM  it the screen goes from an [offline] notice straight into job
REM  traffic, and there is no way to tell a server that recovered
REM  from one that was never down.
IF NOT EXIST C:\AGENT\OFFLINE.FLG GOTO GOTJOB
REM  Only worth saying if [offline] was actually printed. A single
REM  dropped poll sets OFFLINE.FLG and says nothing, so it must clear
REM  just as quietly -- otherwise the recovery line reappears for an
REM  outage nobody was ever told about.
IF NOT EXIST C:\AGENT\OFFSAID.FLG GOTO OFFCLR
ECHO  [online] %UPHOST% is answering again
DEL C:\AGENT\OFFSAID.FLG
:OFFCLR
DEL C:\AGENT\OFFLINE.FLG
:GOTJOB
CALL C:\AGENT\JOB.BAT
GOTO LOOP

:OFFLINE
REM  Once per outage, not once per retry. UGET used to print its own
REM  two-line failure every five seconds and this line added a third;
REM  one daemon restart cost sixteen rows and scrolled the banner
REM  away. UGET is now silent on a failed POLL (-V still reports),
REM  and the retries show as its spinner, which animates in place and
REM  scrolls nothing.
REM
REM  The flag is made with ECHO and not COPY: EXIT0.COM is fetched by
REM  the first job, so on a box that has not run one yet there is
REM  nothing to copy, COPY would fail, the flag would never appear
REM  and the message would be back every five seconds.
REM  Nothing is said on the FIRST failed poll -- only the second.
REM
REM  About one idle poll in six gets no reply on this link: the server's
REM  'nothing for you' answer is sent after a hold, by which time this
REM  host's ARP entry for the box may have lapsed, and nothing here
REM  answers ARP. Announcing the first miss turned each of those single
REM  dropped packets into an [offline] and an [online] -- two lines for
REM  an event that cost 5 seconds and lost nothing. Waiting for a second
REM  consecutive failure is what separates a dropped packet from a
REM  server that is actually gone.
IF EXIST C:\AGENT\OFFLINE.FLG GOTO OFFSAY
ECHO . > C:\AGENT\OFFLINE.FLG
GOTO OFFWAIT
:OFFSAY
IF EXIST C:\AGENT\OFFSAID.FLG GOTO OFFWAIT
ECHO  [offline] no reply from %UPHOST% - retrying, Q quits
ECHO . > C:\AGENT\OFFSAID.FLG
:OFFWAIT
REM  Is it us, or them? A failed poll has three causes and only one of
REM  them is cured by rebooting THIS box. Once per 30 failures (about four
REM  minutes) NETCHK ARPs the server, then the router:
REM    server answers        dosd is down; our link is fine    keep polling
REM    only router answers   the server's host is gone         keep polling
REM    neither answers       our own link is dead              errorlevel 3
REM  The 386SX lost its WiFi on 2026-09-22 and sat here for half an hour,
REM  healthy and deaf, until a power cycle brought it straight back.
REM
REM  It will reboot at most three times for one outage, then only poll.
REM  The counters and the reasons are in C:\AGENT\NETCHK.LOG, and
REM  NETCHK /STATUS prints them. Silent except when it decides something.
IF NOT EXIST C:\TOOLS\NETCHK.EXE GOTO OFFCHOICE
C:\TOOLS\NETCHK.EXE %UPHOST%
IF ERRORLEVEL 3 GOTO NETBOOT
GOTO OFFCHOICE
:NETBOOT
REM  COLD, meaning a full POST, because that is the most a program can do
REM  towards what a power cut did. Whether it is enough to bring the
REM  PicoMEM's WiFi back is not yet known: NETCHK.LOG will say, because a
REM  reboot that worked is followed by a RECOVERED line.
IF EXIST C:\AI\COLDBOOT.COM C:\AI\COLDBOOT.COM
IF EXIST C:\AI\REBOOT.COM C:\AI\REBOOT.COM
:OFFCHOICE
REM  /N hides CHOICE's own "[Q,Y]?" prompt, which was the ugliest thing on
REM  the screen. The line above already says what the keys are.
REM
REM  Q works here and nowhere else, because CHOICE reads the keyboard
REM  itself. > NUL catches CHOICE's echo of the answer it picked: /N hides
REM  the prompt but NOT the chosen character, so every timed-out retry
REM  printed a bare "Y" -- one line per retry, which is most of what moving
REM  the [offline] notice behind a flag was meant to stop. Redirecting its
REM  stdout does not stop Q from working.
REM
REM  EXIT0.COM first, and this is load-bearing. The test below used to be a
REM  bare "IF ERRORLEVEL 2 GOTO LOOP / GOTO QUIT", whose comment claimed a
REM  CHOICE that did not run was safe because "the errorlevel is whatever
REM  the poll left, which is 20 or more". That was true of the old fetch
REM  tool, which returned 20 or more even on success. It stopped being true
REM  the day the poll became UGET, whose exit code is honest: a failed poll
REM  leaves 1.
REM
REM  Note the wording, not only the logic. A greater-than sign immediately
REM  followed by an equals sign is read by COMMAND.COM as a redirection with
REM  no filename, even inside a REM, and prints "Syntax error" on the console
REM  every time the line is reached. Nothing is created and nothing breaks --
REM  REM does not open the file -- but it is noise on a screen whose whole
REM  job is to be readable. An arrow like "-" then ">" is fine, and so is an
REM  equals then a greater-than; only that one pairing is malformed.
REM  Verified on hardware 2026-09-03.
REM
REM  So the fallback had silently inverted. Reaching here at all means the
REM  poll just failed, so ERRORLEVEL was 1, and 1 is below 2 -- the agent
REM  quit instead of retrying, on a box nothing could then reach. Anything
REM  that stops CHOICE resolving (a truncated PATH from a full environment
REM  is the one to expect here) turns an outage into a stopped agent.
REM
REM  Forcing 0 first makes the three cases distinguishable again:
REM    2  CHOICE timed out          -> keep polling
REM    1  somebody pressed Q        -> stop
REM    0  CHOICE never ran, or was interrupted -> keep polling
REM  Quitting is now the ONLY case that needs positive evidence, which is
REM  the right way round for the one branch that cannot be undone remotely.
IF EXIST C:\AGENT\EXIT0.COM C:\AGENT\EXIT0.COM
CHOICE /C:QY /N /T:Y,5 > NUL
IF ERRORLEVEL 2 GOTO LOOP
IF ERRORLEVEL 1 GOTO QUIT
GOTO LOOP

:QUIT
REM  Clear the flag on the way out, or restarting the agent would stop it
REM  again immediately.
IF EXIST C:\AGENT\STOP.FLG DEL C:\AGENT\STOP.FLG
IF EXIST C:\AGENT\JOB.BAT DEL C:\AGENT\JOB.BAT
REM  Un-arm ScrollLock, for the same reason the flag file is deleted above:
REM  it LATCHES, so an agent that stopped on it and left it set would stop
REM  again on its first poll after being restarted. SCRLOFF also puts the
REM  keyboard lamp out -- the lamp is what somebody standing at the machine
REM  reads as the armed state, so leaving it lit on a box that is no longer
REM  stopped is worse than not clearing anything.
IF EXIST C:\TOOLS\SCRLOFF.COM C:\TOOLS\SCRLOFF.COM
ECHO.
ECHO ===================================================================
ECHO  Agent stopped. Nothing is polling now, so dosctl on the Windows
ECHO  side cannot reach this machine until it is running again.
ECHO.
ECHO   jobs from   : %UPHOST% port 8069
ECHO   results to  : %UPHOST% port 8069
IF NOT "%MTCPCFG%"=="" GOTO QIP
ECHO   own address : MTCPCFG is not set
GOTO QIPDONE
:QIP
IF EXIST %MTCPCFG% FIND "IPADDR" %MTCPCFG%
:QIPDONE
ECHO.
IF EXIST C:\TOOLS\SCRLOFF.COM ECHO  ScrollLock has been cleared for you.
IF NOT EXIST C:\TOOLS\SCRLOFF.COM ECHO  Turn ScrollLock OFF, or it stops again.
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
