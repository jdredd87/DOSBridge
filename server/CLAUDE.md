# CLAUDE.md

Project context for Claude Code. Read this before touching anything here.

## What this is

A bridge that lets you build DOS software on this Windows 11 machine and run it
on a real 8086-class PC over WiFi. The DOS box is reachable as a test runner:
you run a command, it executes on the DOS machine, you get stdout and an exit
code back. Treat it exactly like a compiler or test suite.

Nothing in the bridge or in `starter/` is tied to one CPU. Everything is built
for the plain 8086 so it runs on any DOS box; where a faster part can do
better, the fast path is selected at run time via `Has186` in `starter/cpu.pas`.
The specifics below describe *this* machine, not a requirement.

**Two DOS machines have been used, one at a time**, and the bridge does not
care which is on the end of it:

| | |
|---|---|
| the original | **NEC V30**, MS-DOS 6.22, **an 8087 fitted**, VBE video with 1 MB. About 514 KB free heap. **Sits beside the router** |
| the second | **RETIRED 2026-09-26 -- not on the bridge.** **Gateway 2000 386SX/25**, MS-DOS 6.22, no 387. 515 KB free, BIOS of 03/25/92, VGA colour. **Was DOWNSTAIRS on a noticeably weaker link until 2026-09-23, when it moved into the V30's room** because the link had become spotty all the time (1 MB over HTGET swinging 10-101 s). Everything below about "downstairs" describes it before that move. **Its PicoMEM 1 then died, the same afternoon -- confirmed dead in more than one machine, so the 386SX has no card and is off the bridge until it gets one** -- after a night and a day of dropouts, a failure to rejoin WiFi after a power cut, and link deaths that happened in the V30's room too. So the later 386 "link" faults were at least partly a card failing, not distance alone |

**Where the machines physically are is bridge configuration, not trivia.**
The 386SX's distance from the AP is why it loses whole job RESULTS while the
V30 never does -- a large payload on a weak link -- and on 2026-09-21 that
asymmetry was measured carefully and then attributed to the wrong thing: the
two boxes differ in CPU, PicoMEM model and card firmware date all at once, so
the older card on the older firmware looked causal. It was not. Nobody needed
to swap a card or flash anything. **Ask where a machine is before blaming
what is plugged into it.** `docs/network.md` has the measurements and the
mitigation, which is to make the jobs smaller rather than retry the big ones.

**The PicoMEM card is not a property of the machine.** Both boxes boot from
one and reach the network through it, and the cards get swapped between
them -- so which card is in which box is a fact with a date on it, not a
fixture. **Both cards were read off their ROMs on 2026-09-21:**

| | card | BIOS date | board id |
|---|---|---|---|
| V30 | **PicoMEM 2** | 2026-06-16 | 11, parameter area at +886 |
| 386SX | **PicoMEM 1** -- **DEAD 2026-09-23**, fails in any machine | 2025-11-02 | not reported (all three bytes 0), parameter area at +374 |

**THE 386SX IS RETIRED, 2026-09-26 -- StevenC's decision. Do not test on
it, and do not plan work around it.** It is gone from `boxes.json` (and its
plug history from `power.state`), so the V30 with the PicoMEM 2 is the one
box on the bridge and the default for every command. Everything else this
file says about the 386SX is history, kept because what it found still
applies to code written here: the INT 10h hook, the 256-byte environment,
and "run on both -- gate at run time" for any 386 someone else has.

Its last day, for the record: with the PicoMEM 1 it ran `PM2000` SC5
CRC-exact, at the original's speed. With the **PicoMEM 2** it never got a
packet out -- not on the original driver, not on SC2 -- although the card
reported WiFi joined at -36 dB, and **SC5 locked the machine up**, which SC2
(the same code with the register pauses kept) did not. That was not
resolved; `CH375USB/PicoMEM/netdrv/README.md` carries it as a known issue.

The two paragraphs below are 2026-09-25, when the cards and SD cards were
crossed; they stay as the record of why an id is checked before it is
trusted.

**2026-09-25: the cards moved again, and the 386SX is NOT dead-and-idle any
more.** Per StevenC, **the 386SX has the PicoMEM 2 and is busy with other
work -- do not run jobs on it, reboot it or cycle its plug (`.205`) unless
StevenC says so.** It is not polling this bridge (`v30` reads STALE), and
which SD card it has was not established. That instruction came after the
386SX's plug had already been cycled once by mistake at ~19:40, by the
box-id/plug confusion described next.

**The V30 is running a PicoMEM 1 and the 386SX's SD card.**
StevenC put "the PicoMEM 1.11 board" in the V30; `PMINFO` reads BIOS
2025-11-02, no board id, parameter area at +374 -- the same firmware as the
card recorded dead above, and whether it is that board was not
established. Because the SD card is the 386's, **the V30 boots the 386's
`NET.CFG` and polls as `sx386` from `.67`**, while `v30` shows STALE.
Nothing warns about that (`docs/multibox.md`, "Also not built"), and it
splits two commands from each other: **a box id follows the SD card, a
smart plug and the capture stick follow the machine.** `dospower cycle
--box sx386` cut the 386SX's plug; the V30's is still `--box v30`. After
any swap, run `FPU.EXE` and `PMINFO.EXE` before trusting an id.

**Identify the card with `CH375USB/PicoMEM/bin/PMINFO.EXE`, which reads the
BIOS date out of the ROM, rather than inferring it from the machine.** This
table has now been wrong twice in the other direction. It once claimed the
V30 had a "PicoMEM 1.14", which was never checked; it then said "as of
2026-09-20 the 386SX holds the PicoMEM 2", and on 2026-09-21 the cards were
the other way round -- so a session read that line, repeated it, and built a
hypothesis about a transport fault on top of it before running `PMINFO`. The
date stamp is not decoration: **a dated claim about which card is where is
evidence that it was true once, and nothing more.** One command settles it.

**The 386SX's card is a firmware release behind, and that is a footnote
rather than a lead.** The newest PicoMEM 1 WiFi build is
`PM_W_11_16_25.uf2`, 16 Nov 2025, from `firmware/` in
https://github.com/FreddyVRetro/ISA-PicoMEM (PicoMEM 2 builds live in
`firmware/PicoMEM2/`). `PMINFO` reports "firmware: revision not reported; go
by the BIOS date", so the ROM date is a proxy for the build, not the build
number.

It is listed here for completeness, **not** as the explanation for anything:
that box's transfer losses are its distance from the router, per the table
above. Updating needs MicroUSB and the BOOTSEL button -- it cannot be done
over the bridge -- and **the card is the boot disk**, so read the PicoMEM
README first and have a reason better than "it was behind".

**There is only ONE SD card**, and it moves between the two PicoMEM cards.
So the boot disk is the same disk whichever card is in the machine: one
`C:\TOOLS`, one `C:\AI`, no drift and nothing to re-sync after a swap. The
disk images live on that card, so a swap does move the boot disk physically
-- it just moves the *same* one.

The 386SX is four to five times the V30 on every `BENCH` row (`docs/hardware.md`
has the table) and it found two faults the V30 never could: FPC's runtime
hooking INT 10h, and CH375Camera counting packets where it should have
measured time. Anything written here must run on both -- gate a faster path
at run time, never at compile time.

| | |
|---|---|
| Windows box | runs `dosd.py` on ports 8080/8081/8082, plus UDP 8069 |
| DOS box | polls for jobs at a static address; see below |

**Since 2026-09-26 there is ONE machine again: the 386SX is retired and
`boxes.json` lists only `v30`.** The multi-box support stays built and
working -- `--box` is accepted, and a second machine goes back in with one
`boxes.json` entry -- so the paragraph below describes the capability, not
the current fleet.

**BOTH MACHINES WERE ON THE BRIDGE AT ONCE, 2026-09-21 to 09-26.** There are two SD cards, so
the "one at a time" above is history: `boxes.json` registers the V30 and the
386SX at their own addresses and one `dosd` serves both. Every command takes
`--box ID`, and `--box all` runs it on both and prints the answers side by
side. With no `boxes.json` nothing changes and the bridge talks to one
machine exactly as before. **`docs/multibox.md` Part 1 is the operating
manual** -- how a poll finds its box, what is per box and what must never
be, and the step-by-step for adding a second machine.

**Which box a command means is never guessed.** `--box ID`, then `$DOSBOX`,
then a `.dosbox` file at or above the working directory, then `default` in
`boxes.json`, then the sole registered box -- and ambiguity is a hard error
listing the candidates. A job that silently picks a machine comes back
looking entirely correct, having run on the wrong CPU, and nothing in the
output says so. `dospower cycle` and `dosctl stop` refuse a default outright
and make you name the machine.

**Every IP address and MAC in this file is an illustrative placeholder.** They
are written as `192.168.1.x` and `AA:BB:CC:...` so a transcript reads sensibly,
not because any of them mean anything. Nothing in the bridge has an address
baked into it: the Windows side is auto-detected, the DOS side is written into
`C:\AI\NET.CFG` when the client kit is built, and both are reported by
`dosctl status` and by the box's own boot banner. If you are copying a command
out of this file, substitute your own.

## The rest of the documentation

This file used to be 4700 lines and was loaded whole at the start of every
session. It is now the part that applies to *everything* -- the machine, the
commands, the constraints, the toolchain -- and each subject that had grown
its own long history lives beside it:

| | |
|---|---|
| `docs/tools.md` | why the tools on the box behave the way they do |
| `docs/hardware.md` | CPU, coprocessor, the CMOS fault, the smart plug, video capture |
| `docs/graphics.md` | the `VGA` and `modex` units, and OPL2 sound from a frame loop |
| `docs/raycast.md` | the raycaster, 4.2 to 44.7 fps. **The performance reference** |
| `docs/input.md` | `KINJ`, `KNET`, mouse injection, the Mouse Systems protocol |
| `docs/network.md` | packet driver, our own IPv4/UDP, TFTP, every transport fault. **The mid-transfer stall is solved: the box did not answer ARP.** Read that section before touching the transport |
| `docs/agent.md` | `AI.BAT`: upgrading it, stopping it, every way it has gone quiet |
| `docs/multibox.md` | **BUILT 2026-09-21.** Two or more DOS boxes on one bridge. **Part 1 is the operating manual** -- how a poll finds its box, what is per box and what must never be, and a step-by-step setup for a second machine. Part 2 is the design record. Read Part 1 before adding a box or debugging one |
| `capture.md` | running the capture card: live preview, stills, recording |
| `knet.md` | the live remote keyboard, and its four hazards |
| `starter/demos/SCROLLER.md` | the mode X scroller |
| `starter/demos/PARALLAX.md` | NEON DRIFT: real per-row parallax off the CRTC line compare, and the five bugs that looked like something else |
| `CH375.md` | the CH375 USB work: what came out of it and where it went |
| `README.md` | setup, and the failure modes worth knowing |

**Nothing was deleted in the split** -- every measurement, dead hypothesis and
wrong turn moved across verbatim. That matters because most of the value in
those files is the record of what did *not* work: this file has repeatedly had
to relearn that a plausible fix which measures as nothing is usually
unapplied rather than ineffective, and each of those stories is the evidence.

**Read the topic doc before optimising, debugging or extending its subject.**
Four separate attempts to speed up the raycaster failed because `BENCH`'s
per-operation figures do not predict marginal cost inside real code; four
hypotheses about the transport stall were built, measured and removed. Both
lists are written down so nobody pays for them twice.

**New findings go in the topic doc, not here.** Add a line here only when what
you learned changes how everything else has to be written -- which is what the
Hard constraints section is for.

**Before blaming the link, run the control.** mTCP is installed on the box and
is a completely independent stack -- different code, different transport, same
card and driver and AP. If it moves a large file cleanly while ours stalls, the
fault is ours and no amount of staring at the wire will find it. That single
measurement is what finally identified the transport stall on 2026-09-12, after
weeks in which "the link drops frames" was taken as given; mTCP moved 10 MB at
83 KB/s while our stack could not finish 5 MB. `docs/network.md` has it.

The companion rule, from the same bug: **a null result is worth exactly what
the instrument is worth.** The right hypothesis had been proposed and discarded
months earlier because `arp -a` prints a `dynamic` entry for an address whose
neighbour state is `Unreachable`. The tool could not express the answer, so the
answer read as "no".

## How this box is actually set up

Verified by reading the machine, not from these notes. **The `dos/` directory in
this repo does not match it** — deploying `dos/AUTOEXEC.BAT` as `README.md` step
4 describes would break networking.

| | on the box |
|---|---|
| packet driver | `C:\drivers\pm2000.com 0x60` (PicoMEM native, not NE2000). **On the V30 since 2026-09-23 that file is our rebuilt `0.5-SC5`** (StevenC and Claude), about 27% faster; the shipped one is `C:\DRIVERS\PM2000.ORG`. **The 386SX's SD card has it too since 2026-09-25**, measured on a PicoMEM 1 in the V30 (about 20% faster, every CRC exact) and in the 386SX on 2026-09-26 (same speed -- a 386 already had the fast copy -- and CRC-exact through the fixed `REP INSW` path); with a PicoMEM 2 in the 386SX it locked the machine up (see the retirement note at the top); its original is also at `C:\PMNET\ORIG.COM`, because **DOS will not run a `.ORG`** -- a live swap back to it unloads the driver and loads nothing. `docs/network.md` has why |
| addressing | `DHCP` |
| mTCP | `C:\NETWORK\MTCP`, config `c:\network\mtcp\mtcp.cfg` |
| boot chain | `CONFIG.SYS` → `AUTOEXEC.BAT` → `cd AI` → `C:\AI\AI.BAT` |
| agent loop | `C:\AI\AI.BAT` — the job loop and crash guard live here |
| work dirs | `C:\AGENT` (bridge state), `C:\TOOLS` (permanent, on PATH), `C:\WORK` (per-job scratch) |

### Why three working directories

Renamed on 2026-08-30. `C:\A` and `C:\T` are gone; do not recreate them.

| | |
|---|---|
| `C:\AI` | the agent loop itself — `AI.BAT`, `REBOOT.COM`, `COLDBOOT.COM` |
| `C:\AGENT` | bridge state — `JOB.BAT`, `EXIT0.COM`, `PEND.BAT`, `PENDID.TXT`, `TRYING.FLG`, `DRVOUT.TXT` |
| `C:\TOOLS` | the permanent tools, and the reason they resolve by bare name |
| `C:\WORK` | per-job scratch — pushed programs, `OUT.TXT`, `RES.TXT` |

The split that matters is `TOOLS` from `WORK`. The old `C:\T` held both the
disposable scratch *and* the entire toolset, so `DEL C:\T\*.*` — the obvious way
to clear scratch — would have taken `HWINFO`, `DEVS`, `SCRAPE` and the rest with
it. `C:\WORK` is now safe to wipe at any time and `C:\TOOLS` is never touched by
a job.

`C:\AGENT` is separate from `C:\WORK` because some of it must **survive a
reboot**: `PEND.BAT`, `PENDID.TXT` and `TRYING.FLG` are written by one boot and
read by the next, and they are the only way the machine can report *why* it
hung. Never write there yourself — a stray `PEND.BAT` or `TRYING.FLG` makes the
next boot think a driver test is in flight.

Paths live in `dosd.py` (generated batches), `dosctl.py` (the `deploy` default),
`C:\AI\AI.BAT` on the box, and the `PATH` line in `C:\AUTOEXEC.BAT`. Change one
without the others and jobs half-work. No `.pas` source hardcodes them.

**The network is STATIC, and must stay that way.** As of 2026-08-30 the box no
longer runs `DHCP` at boot; `C:\NETWORK\MTCP\MTCP.CFG` carries `IPADDR
192.168.1.20` with no lease. Before that it took a 4-hour DHCP lease, and when
the lease expired every mTCP tool refused to run — the box went silent and
needed hands on the keyboard.

The reason it could not recover by itself is worth remembering: `AI.BAT`'s
`:OFFLINE` branch retries `HTGET` every 5 seconds forever but **never re-runs
`DHCP`**, so once the lease lapsed it retried the one thing that could not
work. `DHCP.EXE` is one-shot — it stamps the address plus `TIMESTAMP` and
`LEASE_TIME` into `MTCP.CFG` and exits; nothing renews it.

So: never re-enable the `DHCP` line in `AUTOEXEC.BAT`, and never hand-write
`TIMESTAMP` or `LEASE_TIME` into `MTCP.CFG`. Those two directives are exactly
what the tools test to decide a lease has expired. Backups on the box are
`C:\AUTOEXEC.SAV` and `C:\NETWORK\MTCP\MTCP.BAK`; the live files are mirrored in
`dos/live/`, with the pre-static version kept in `dos/archive/`.
**`dos/live/AUTOEXEC.BAT` had drifted and was not a mirror at all** --
corrected 2026-08-31 by pulling the real one. The better, never-deployed
version is now `dos/AUTOEXEC.proposed.bat`; it is what would put
`C:\TOOLS` on the box's PATH.

**It happened again on the 386SX, 2026-09-23, and the bridge hid it.** Its
own SD card's `MTCP.CFG` had `DHCPVER`, `TIMESTAMP`, `HOSTNAME_ASSIGNED` and
`LEASE_TIME` stamped in -- someone ran `DHCP.EXE` at the keyboard while
chasing the WiFi -- and once the 8 hours were up every mTCP tool printed
"Your DHCP lease has expired!" and quit. **The agent kept polling
perfectly**, because `UGET`/`UPUT` are our own stack and read `C:\AI\NET.CFG`,
not `MTCP.CFG`; only a job that ran `HTGET` found out. Fixed by deleting
those four lines (the stamped file is kept as `MTCP.DHC`). **After anyone
has been at a box's keyboard fixing the network, `TYPE` its `MTCP.CFG`.**

Symptom to recognise: the box stops polling and never comes back on its own,
while `dosd` is plainly still listening on 8080/8081/8082. Check with `netstat`
before assuming the daemon died — the failure looks identical from the CLI.

**This section is about the V30. The 386SX CANNOT be fixed the same way --
its BIOS will not accept a date past 2010.** So that machine stamps every
file it writes somewhere around 2010, and **that is expected rather than a
fault to chase.** Do not run the `SNTP -set` below on it hoping to correct
it; the BIOS setup will not take the year, so anything DOS manages to write
to the RTC is at best good until the next cold boot.

Two practical consequences. **Never compare file dates between the two
machines** -- one is roughly right and the other is sixteen years out, so a
side-by-side `DIR` makes the 386SX's files look ancient regardless of when
they were written. Nothing in the bridge depends on this: `upgrade --tools`
compares sizes, `verify` compares CRC-32, and neither reads a date. It only
misleads a human reading a listing.

**The clock was two years slow, and is now right.** Every file the box created
was stamped 2024 while the world was in 2026 -- month, day, hour and minute all
correct, only the year wrong. Fixed on 2026-08-31 with the mTCP client already
on the machine:

```
dosexec "SET TZ=EST5EDT" "SNTP -set pool.ntp.org"
```

It **survived a reboot**, so the CMOS battery is fine and the year had simply
never been set. Two things worth keeping:

* `SNTP` and `HTGET` both refuse to touch timestamps unless `TZ` is set, and
  `AUTOEXEC.BAT` does not set it -- so the `SET TZ=` above is needed on any job
  that cares, until someone adds it at the keyboard.
* Never run bare `DATE` or `TIME` over the bridge to check the clock. With no
  argument they prompt for input and block forever, which is indistinguishable
  from a hang and needs hands on the machine. `SNTP` without `-set` reports
  both times and changes nothing, which is the safe way to ask.

**The video card boots to mono sometimes.** Observed both ways in one session:
display combination code 7 (VGA mono, text mode 7) on one boot and code 8 (VGA
colour, text mode 3) on the next, with no configuration change. Anything that
touches the screen must decide at *run time* — probe `INT 10h AH=1Ah` (AL=1Ah
means the code in BL is valid; 1, 5, 7 and 0Bh are mono) rather than baking in a
palette. `starter/demos/fractal.pas` does this and takes a `MONO`/`COLOUR` argument to
override the probe, which is how to test the path the card didn't boot into.

Note a colour ramp is *not* automatically safe on mono: the monitor sums R+G+B,
so two different colours can land on the same grey. Mono needs its own evenly
spaced ramp.

`C:\MTCP` exists but is empty; the real tools are under `C:\NETWORK\MTCP`.

**`CONFIG.SYS` and `AUTOEXEC.BAT` since the tuning of 2026-09-27 evening**
-- measured one boot configuration at a time, `projects/dostune` has the
numbers and the tools (`tune.py apply VARIANT` writes, reads back and
reboots safely).  Program loads 23% faster, console 55-68% faster, opens
22% faster, for 10 KB of conventional memory (576,080 free).  The files
before it are `C:\CONFIG.TU0` and `C:\AUTOEXEC.TU0`:

```
DOS=UMB                                          CONFIG.SYS
FILES=30
BUFFERS=30
device=c:\drivers\umbsc.sys C800-D000 D800-E000
devicehigh=c:\drivers\pmemmsc.sys /n
device=c:\drivers\ansisc.sys

LH C:\DOS\DOSKEYSC.COM                           AUTOEXEC.BAT (the rest
LH C:\DOS\FASTOPEN.EXE C:=50                      as before)
LH C:\drivers\pm2000.com 0x60
```

**The disk was checked the same evening**: `CHKDSK` had found 23 lost
allocation units in 7 chains (94 KB, from earlier crashes -- the biggest was
an old AXPKT log); StevenC ran `CHKDSK /F` at the keyboard, the recovered
`FILE000n.CHK` files were deleted, and `CHKDSK` now reports no errors.

**A disk cache does not help this machine** -- `projects/cachesc` built one
(CACHESC, correct, verified on the V30) and measured it: DOS's BUFFERS
already hold what comes round, and everything outside 640 KB is the
PicoMEM's and nearly as slow per byte as the disk.  Do not build another
without reading that README.

**The same file earlier on 2026-09-27** -- written over the bridge, at
StevenC's explicit instruction, one change at a time with a reboot and a
check after each. `C:\CONFIG.SC0` is the file before any of it,
`C:\CONFIG.SC1` the one before `BUFFERS` came down from 40, `C:\CONFIG.SC2`
the one before ANSISC replaced `ANSI.SYS` (later that day the REM lines
were dropped and ANSISC moved high at the keyboard; the tuning put it back
low):

```
DOS=UMB
FILES=30
BUFFERS=20
REM Device=c:\drivers\USE!UMBS.SYS C800-D000 D800-E000
Device=c:\drivers\umbsc.sys C800-D000 D800-E000
REM Devicehigh=c:\drivers\pmemm.exe /n
Devicehigh=c:\drivers\pmemmsc.sys /n
REM devicehigh=c:\dos\ansi.sys
device=c:\drivers\ansisc.sys
```

`ANSISC` (2026-09-27, `extras/ansisc` -- an optional extra that ships in the kit) is ANSI.SYS rebuilt from
Microsoft's MIT-licensed MS-DOS 4.0 source, with MS-DOS 6.22's changes
re-implemented and new fast paths: 3-4x faster console output through DOS
on the V30, and the same screen as 6.22's driver across ~7,300 emulator
comparisons and on the real machine.  It is loaded LOW on purpose -- code
in the PicoMEM's upper memory runs ~2.4x slower (`docs/hardware.md`).  Its
README has everything.  **`extras/ansisc/ANSI622.SYS` is Microsoft's
proprietary 6.22 binary, the test reference: it is in `.gitignore` and must
never be committed.**

`UMBSC` and `PMEMMSC` are StevenC's and Claude's UMB manager and EMS
driver -- no conventional memory for the UMB manager (224 bytes back), EMS
page mapping 45-57% faster, and five EMS bugs fixed.  `UMBSC` lives HERE,
`extras/umbsc` (an optional extra, since 2026-09-27; it is not
PicoMEM-specific); `PMEMMSC` is PicoMEM-only and stays in
`C:\CH375USB\PicoMEM\emm`.  Their READMEs have the measurements. `BUFFERS=20` (from 40) gave
back another 10,640 bytes -- 532 a buffer; nothing in the bridge needs
more, and `FILES=30` is the setting jobs depend on. With both, free
conventional memory went from 575,472 to **586,336**. **Build a CONFIG.SYS in a
Python file, never with `printf` or an inline script:** the first attempt
turned `c:\dos\ansi.sys` into `c:\dos<BEL>nsi.sys` (`\a`), and it was
caught only because the file was read back before the reboot. Read it
back byte for byte, every time, before rebooting.

The version below is the file before any of that, as found on 2026-09-10.

**`CONFIG.SYS`, read off the box 2026-09-10** -- and it is nothing like what
this file used to claim, which was "one active line,
`device=c:\bp\bin\ch375R9.sys`":

```
FILES=30
BUFFERS=40
;device=c:\drivers\LTEMM.EXE /n
;device=c:\bp\bin\ch375R9.sys @260 %0
```

`FILES=30` was raised at the keyboard on 2026-09-10 and it matters. At the
DOS default of 8, a session running dozens of programs an hour exhausts the
handles, and the symptom is vicious rather than obvious: every command still
runs and still prints to the CONSOLE, but the batch can no longer open
`C:\WORK\OUT.TXT`, so jobs come back with **no output and rc 0** -- which is
also exactly what a missing program looks like, so it reads as the wrong
fault entirely. `doscap` is what identifies it, from "Extended Error 4" on
the DOS screen. A warm reboot clears it.

**There is no `SHELL=` line, so the environment is DOS's default 256
bytes, and the 386SX's SD card fills it.** Its `AUTOEXEC.BAT` and agent set
`PATH` (95 bytes), `MTCPCFG`, `TEMP`, `SRV`, `UPHOST`, `BOXID` and `TZ`,
which leaves no room for the `SET RC=` of the errorlevel ladder dosd puts
at the end of every job. Seen 2026-09-25 as `Out of environment space` on
the box's screen after every job, and `rc FAILED` in the agent's log line:
**the output still comes back, only the exit code is lost** -- so a job
can read as failed when it worked. `dosexec "SET TEMP="` frees enough until
the next boot (jobs run in the agent's own shell, so it sticks), **but it
leaves `TEMP` set to a single space** -- the generated line ends in one --
and then every `|` pipe fails silently, because COMMAND.COM builds a pipe
from temp files in `%TEMP%`. Batch files here redirect to a file instead.
The cure is `SHELL=C:\COMMAND.COM C:\ /E:1024 /P` in `CONFIG.SYS`, **added
by StevenC at the keyboard, not over the bridge** -- see "Never write to
CONFIG.SYS" below.

**Both `device=` lines are commented out, and the reason is a hazard worth
knowing before putting anything on the ISA bus.** The comment on the box
records that the Lo-tech 2 MB EMS board sat at **I/O 0260 -- the same port as
the CH375 USB card** -- and the two fought: the CH375 read back `FF` and the
packet driver's receive buffers filled with it. The board was removed
2026-09-08, and `LTEMM` had to go with it because it probes 0260 and finds
the CH375 instead. Put both back together or neither. `ch375R9.sys` is
Borland's CH375 driver and would contend with `USBPKT` for the same chip.

So **anything at 0260 corrupts CH375 reads on this machine, demonstrably** --
which is directly relevant to the corruption being chased in CH375Net.

The box also carries unrelated software (`WINDOWS`, `BP`, `GAMES`, `NASM`)
-- don't disturb it.

## Prerequisite for every session

**TWO daemons can no longer run at once, and one pair was found doing it.**
On 2026-09-10 the process list held two `dosd.py` instances started thirty
minutes apart, both bound to UDP 8069, both appending to the same `dosd.log`
so the log read as perfectly continuous. `SO_REUSEADDR` on the UDP socket is
what allowed it: UDP has no `TIME_WAIT` so the option bought nothing there,
and on Windows it lets a second bind succeed silently.

The consequence is worth understanding, because it does not look like a
Windows-side problem at all. Two sockets on one UDP port means each arriving
datagram goes to one of them arbitrarily, so a multi-datagram TFTP transfer
is split between two daemons that each hold their own transfer state --
producing stalled transfers, deploys that fail their CRC, and results that
never come back. Every one of those reads as a fault on the DOS box or on
the wire.

The option is gone from that socket, so a second instance now fails to bind
and says so instead of quietly competing. Verified rather than assumed: a
plain bind is refused with errno 10048 *even when the socket already holding
the port set `SO_REUSEADDR`*, so the guard works against an older daemon
too. TCP was never affected -- a connection is owned by whichever listener
accepts it, so HTTP transfers cannot be split this way.

`dosd.py` must already be running in its own window. If commands hang or report
"cannot reach dosd", say so — do not try to start it yourself in a way that
blocks, and do not work around it by skipping hardware tests.

**dosd writes `dosd.log` beside `dosd.py`**, mirroring everything its console
shows. That exists because the console was for a long time the *only* record:
the lines that say whether a batch was dispatched and whether the box
acknowledged it (`-> dispatch`, `acked` / `NO ACK`, `<- result`) are the ones
that answer nearly every "is it the box or is it us?" question, and they were
visible only to whoever was sitting in front of that window, scrolling away
while anyone else reasoned from symptoms. `DOSD_LOGFILE=` turns it off.

Stop the daemon with Ctrl-C in its window, or `dosctl shutdown` from anywhere
on this machine. The endpoint refuses anything but loopback -- every other
route into dosd exists for the DOS box to reach across the LAN, and this is
the one that must not be.

Check liveness first if anything looks wrong:

```
dosctl status
```

`DOS box: alive, polled <10s ago` is healthy. "STALE" or "never seen" means the
DOS box is off, hung, or the firewall is blocking 8080/8081/8082.

**The firewall really does block it, and it looks nothing like a firewall.**
On 2026-09-21 both machines went silent at once and stayed silent through a
reboot, a power cycle and a daemon restart. Neither was broken: this PC's LAN
interface is on the **Private** profile, the only inbound Allow rules for
`python.exe` were scoped to **Public**, and the default inbound action is
block -- so every poll was dropped before `dosd` ever saw it. `netstat`
showed the daemon bound to `0.0.0.0:8069` throughout, and both boxes' screens
showed a healthy agent banner. Run `dosfirewall.cmd` as Administrator; it
adds port-scoped rules limited to the boxes' own subnet.

Two things from that hunt are general:

* **Two machines failing identically at the same moment means look at what
  they share**, and what they share is this host. It is the same lesson as
  running mTCP as an independent control, arriving from the other direction.
* **`ping` proves nothing here** -- nothing on the DOS side answers ICMP.
  Send a UDP datagram to the box to force this host to ARP for it, then read
  `netsh interface ipv4 show neighbors`. `Reachable` means the box's own
  stack answered, which separates "the machine is dead" from "the machine is
  talking and we are not listening". `arp -a` cannot express that and is
  what caused the earlier misdiagnosis this file already records.

## Commands

```
dosnew NAME                   scaffold projects/NAME/ for a new project
makeinst                      rebuild C:\dosbridgeDEVInstaller (bumps the build number)
makeinst --no-bump            ...without advancing it, for test builds
dosctl clean [--all]          delete regenerable build junk (--all: EXEs too)
dosrun PROG.EXE [args]        push, run on the DOS box, capture stdout, return errorlevel
dospush FILE [FILE...]        stage a file on the Windows side only (see below)
dosdeploy FILE [C:\DEST]      stage AND copy onto the DOS box, verified. default C:\WORK
                              DEST is a DIRECTORY. A full file path makes
                              C:\DIR\FILE.EXE\FILE.EXE and fails on the copy
dospull C:\PATH\FILE          copy a file off the DOS box, byte-exact
dosexec "MEM /C" "DIR C:\WORK" run arbitrary DOS commands
dosrun/dosexec --quiet        ...without echoing the output on the DOS console
dosdrv DRV.SYS [args]         stage a driver, reboot, report whether it survived
dosdrv DRV.SYS --device NAME  ...and fail unless NAME registers as a device
dosreboot [--cold]            reboot and wait for it to come back
dosctl stop                   stop the agent loop (one-way -- see below)
dosctl upgrade                update the DOS box over the wire: tools + agent
dosctl upgrade --tools        only the tools in C:\TOOLS (no reboot)
dosctl upgrade --agent        only C:\AI\AI.BAT (swaps, then reboots)
dosctl upgrade --dry-run      say what would change, touch nothing
dosctl version                what build the DOS machine is running
dosctl verify                 CRC-32 every tool on the box against the build
dosctl status                 liveness check -- a row per box
dosctl boxes                  which DOS machines this bridge knows
dosctl shutdown               stop dosd itself (from this machine only)
--box ID                      which machine. --box all where it can compare
                              (run, exec, verify). REQUIRED, not defaulted,
                              for `stop` and `power cycle`
dosfirewall.cmd               let the boxes reach dosd through Windows
                              Firewall. Needs Administrator; see below
dospower [status|on|off|cycle]  smart plug, if one is configured
doscap [devices|modes|status]   video capture, if a card is configured
doscap live [--mute]            watch the box live, WITH SOUND (q to quit)
doscap shot [FILE]              one still of the box's REAL screen
doscap rec SECS [--audio]       record it. --shots N pulls stills out
doscap burst N [--every S]      a series of stills, S seconds apart
doscap still REC SECS           pull one frame out of a recording
```

### Where new work goes

**`starter/` is reserved** for the bridge's own tools and worked examples; it is
copied into the installer kits. Anything else belongs in **`projects/NAME/`**,
created with `dosnew NAME`. Never author anything under
`C:\dosbridgeDEVInstaller\` — everything below its `.git` is a build
artifact, overwritten wholesale by `makeinst.cmd`. See **Cutting a public
release** below for what that folder is.

Staging is namespaced by project, because `files/` used to be one flat
directory keyed on the filename: two projects that both built a `HELLO.EXE`
silently overwrote each other, last writer winning with no warning. 8.3 leaves
only eight characters, far too few to prefix a project name into, so the split
has to be by directory.

| where the file lives | stages as |
|---|---|
| `projects/mandel/build/HELLO.EXE` | `mandel/HELLO.EXE` |
| `starter/build/HELLO.EXE` | `starter/HELLO.EXE` |
| anywhere else | `local/HELLO.EXE` |

`dosrun mandel/HELLO.EXE` names one explicitly. A bare `dosrun HELLO.EXE` still
works when the name is unique, and is a hard error listing the candidates when
it is not — the ambiguity is the whole point, so guessing would defeat it.
Override the inference with `--project NAME`.

**The DOS side is unchanged.** `C:\WORK` is flat and only ever sees the leaf
name, which stays safe because every job does `IF EXIST <dest> DEL <dest>`
before the HTGET — a same-named binary from another project can never be the
one that runs. `C:\TOOLS` is still flat and still clobberable, so deploying
there is the one place to check the name yourself.

`EXIT0.COM` and `PEND.BAT` stay at the root of `files/` and are fetched by bare
name; references are validated to at most one directory level, with `..`,
backslashes and absolute paths refused rather than normalised.

### Build numbers

`makeinst` increments `installer-src/buildno.txt` on every build and stamps the
number into four places in the output:

```
VERSION.txt              build 1 / built <date> / source <path>
README.md                the heading
server/INSTALL.txt       first line
client/README.TXT        first line (CRLF preserved -- it is read on DOS)
```

`server/VERSION.txt` is also read by `dosd` at startup, so a running daemon
says which packaged build it came from:

```
[13:00:04] DOS Bridge build 1 built 2026-08-30
```

That file exists only in a built installer, so the dev tree prints nothing --
the line appears exactly when it is useful.

**Bump by default.** The number exists to tell two artifacts apart, so the
failure that matters is two different builds both claiming the same one --
never a gap in the sequence. Numbers are free; ambiguity is not.

`--no-bump` is only for a build whose output you are about to throw away, such
as iterating on the packaging scripts themselves. If the artifact could end up
on another machine, let it increment.

### Cutting a public release

`C:\dosbridgeDEVInstaller` is **a checkout of the public repo**,
https://github.com/jdredd87/DOSBridge, and not merely a build output. The
release is: build into that checkout, read the diff, commit, push. The
default output path is derived from the source folder's name -- `C:\dosbridgeDEV`
gives `C:\dosbridgeDEVInstaller` -- so a bare `makeinst` lands in the right
place and nothing needs `--out`.

```
git status                        the dev tree must be clean first
makeinst --server 192.168.1.10 --ip 192.168.1.20
cd C:\dosbridgeDEVInstaller
git add -A  &&  git status        READ THIS. See below
git commit  &&  git push
```

**Those two addresses are not optional.** With nothing on the command line
`makekit` auto-detects this PC's LAN address and bakes the real pair into
`client\AI.BAT`, `NET.CFG`, `MTCP.NEW` and `README.TXT` -- which is correct
for a kit you are carrying to your own DOS box and wrong for one going on
the internet. `192.168.1.10` (server) and `192.168.1.20` (DOS box) are the
documented placeholders, the same pair every example in these files uses.
Build 61 had this machine's real subnet in it and was never published;
grep the output for your own addresses before pushing, because nothing in
the build will tell you.

**Read `git status` in the checkout before committing.** Many files will
show as modified with an empty `git diff`: the repo stores CRLF, the build
writes LF, and `git add` normalises them away. What survives staging is the
real change, and it should be a short list you can account for. A build that
touches a file you did not expect is worth understanding before it ships.

Two things that are NOT verified by building:

* **The client kit ships whatever is in `starter\build`,** and nothing checks
  those binaries against their sources. `PKTCAP.EXE` was six days behind
  `pktcap.pas` at build 62 and would have shipped a tool that did not do what
  its own documentation said. Rebuild `starter\` first.

  **This note used to say "everything unchanged comes out byte-identical, so
  the ones that do change are exactly the ones that were stale", and that is
  WRONG.** The `About` unit embeds the build date, so a rebuild on a new day
  changes **every** binary -- 36 of them on 2026-09-22 -- and the signal the
  sentence promised is buried in 36 false positives. Checked rather than
  assumed: `hello.exe` differed from its committed copy at **exactly one byte
  offset**, the `built 2026/09/20` string, same length and same file size.

  So compare the *bytes that are not the date stamp*, or compare sizes and
  then diff the outliers. A rebuild whose only change is the date stamp
  proves nothing was stale, which is the answer you wanted -- and shipping
  that churn is worse than useless, because it also drops every DOS box out
  of `verify` agreement for a one-byte cosmetic difference. On 2026-09-22 the
  rebuild was run as a check and then reverted, and the verified binaries
  shipped.

  Build with `.\build.cmd NAME` from `cmd`: this machine sets
  `NoDefaultCurrentDirectoryInExePath=1`, so a bare `build.cmd` is "not
  recognized" and a loop over every target reports all 36 as failures.
* **`selftest.py` cannot run while `dosd` is up** -- it needs 8069 and
  8080-8082 -- and stopping the daemon is a one-way door if it is serving the
  DOS box. `server\check.py` can run any time and reports what is missing
  from the built kit without touching anything.

Finally, `C:\DOSBridgeInstaller` (no `DEV`) is an older checkout of the same
public repo. One checkout is enough; if it is still there, it is stale by
definition.

**Check that `C:\dosbridgeDEVInstaller` still has its `.git` before
building.** On 2026-09-26 it had none -- it held a plain build 63 -- and
build 65 had been pushed from `C:\DOSBridgeInstaller` instead. The
folder was set aside as `C:\dosbridgeDEVInstaller.build63-nogit`, the
public repo cloned back into it, and build 66 released from there. A
`makeinst` into a folder with no `.git` succeeds and leaves nothing to
commit, so it fails silently at the push step.

### Compilers are not fixed

The bridge only ever needs a path to a `.EXE`, so it does not care what built
one. FPC cross-compiling to `i8086-msdos` is what is set up here and what the
scaffold uses, but a project can use anything that emits a real-mode DOS
binary — Open Watcom on the Windows side, or `TPC`/`TASM` running natively on
the DOS machine (both verified working; see the Borland section). Point the
project's `build.cmd` at whichever, and nothing else in the bridge changes.

`dospush` only stages into `files/` for serving over `/f/` — it does **not** put
anything on the DOS box. Use `dosdeploy` to actually get a file there; it verifies
with `IF EXIST` rather than trusting HTGET's exit code, which is >= 20 even on
success. `dospull --out PATH` controls where the file lands locally.

From `starter/`:

```
build.cmd <name>              cross-compile <name>.pas for real-mode DOS
test.cmd <name>               compile AND run it on the DOS box  <-- the main loop
```

The normal iteration is `test.cmd <name>`. It exits non-zero if any test failed,
so branch on that.

## Tools installed on the DOS box

Built with FPC and deployed to `C:\TOOLS`. Sources in `starter/`. These exist
because the same questions kept costing minutes of round-trips.

**`C:\TOOLS` is currently NOT on the box's PATH.** Checked 2026-08-30:

```
PATH=C:\WINDOWS;C:\;C:\DOS;C:\NETWORK\MTCP;C:\DRIVERS;C:\SOFTWARE\PKZIP;C:\BP\BIN
```

So a bare `dosexec "FPU"` silently does nothing -- COMMAND.COM does not even
get a bad-command message into the captured output. Call them by full path,
`dosexec "C:\TOOLS\FPU.EXE"`, until a `PATH` line is added to `AUTOEXEC.BAT`.
`dosrun` is unaffected: it pushes the binary into `C:\WORK` and runs it there.

```
DSTAT [path]              recursive file/dir/byte totals + top directories
DEVS                      list the DOS device chain
DEVS NAME                 exit 0 if character device NAME is loaded, else 1
HD file [ofs] [len]       hex dump + CRC-32 of any file. ~64 KB/s on the
                          V30 (was 16 before 2026-09-25): 10 MB is ~3 min
SCRAPE [/A] [/R]          capture the TEXT screen and print it through DOS
VSHOT [/K]                capture a mode 13h screen as ASCII art
MEMMAP [/F] [/S]          walk the MCB chain: every block, owner, size
HWINFO                    CPU, BIOS, memory, equipment, ports, video, drives
GTEST                     draw a known mode 13h pattern (for testing VSHOT)
SERIAL [/T] [n /M secs]   UART/RS232 probe; optional type ID and byte monitor
MOUSE [seconds]           exercise the mouse through the INT 33h driver
BENCH [ticks-per-test]    measured cost of the operations that matter here
BEEP [ALERT|DONE|f t n]   PC speaker; ALERT is a ~1.5s siren for attention
IVT [/A] [nn]             interrupt vectors, each attributed to its owner
VIDCHK                    mono or colour? rc 0=colour 1=mono 2=no BIOS opinion
PKTDRV [vec]              find the packet driver, report class/type/name.
                          Read-only: no handle, cannot disturb the link.
                          rc = the NUMBER of drivers found, so a healthy
                          box returns 1 -- documented in its own header,
                          and not a failure however it looks over the bridge
PKTCAP [secs] [type|ALL] [vec]  capture Ethernet frames. Default 5s of ARP
                          on the first driver found. Opens a handle --
                          read the warning below, and give it a vector
ARP addr [-w n]           who has this IP? rc = hosts that answered
ARP -scan a.b.c [-w n]    sweep a /24 and list every host that replies
VMODES [-t] [-d n] [m]    every video mode. -t sets and verifies each one;
                          -d n also DRAWS a pattern and holds it n seconds
                          (needs a human watching). rc = number that failed
FPU [/T]                  coprocessor: fitted, and which? Detect-only by
                          default; /T also runs the arithmetic, which is
                          opt-in because x87 carries WAIT prefixes and WAIT
                          with nothing answering hangs the machine.
                          rc 0=present 1=none 2=present but a test FAILED
MOZART [ticks]            Eine kleine Nachtmusik on the PC speaker (one voice)
AMOZART [ticks]           the same in two voices on an AdLib/OPL2, detected first
FPUPROBE                  coprocessor timing diagnostic: walks the delay
                          lengths and prints the raw words. No FWAIT, so it is
                          safe with or without a coprocessor fitted
KEYHIT                    rc 1 if ScrollLock is on, else 0. 22 bytes, silent;
                          the agent loop runs it once per poll
SCRLOFF                   turn ScrollLock off, keyboard lamp included. The
                          agent runs it as it stops, because the flag
                          LATCHES: an agent that stopped on ScrollLock and
                          left it set stopped again on its first poll after
                          being restarted. Every keyboard-controller wait in
                          it is bounded, so a keyboard that never answers
                          costs a stale lamp and not a wedged box.
                          Verified at the keyboard 2026-09-04, lamp included
KINJ file.KI | /U | /D | /S
                          Resident keystroke injector and screen grabber, so
                          an INTERACTIVE program can be driven and watched
                          from Windows. Hooks INT 16h. /D prints the screens
                          it captured, /U unhooks and frees, /S reports.
                          1582 bytes of NASM; mkkeys.py compiles the scripts.
                          It CANNOT drive anything that reads INT 9 itself
KNET [port] | /T | /S | /U
                          LIVE remote keyboard: you type on Windows, the
                          keystrokes are injected into whatever is running
                          here. Takes a packet driver handle and serves the
                          keys through INT 16h. /T proves the receive path
                          WITHOUT going resident -- always start there.
                          starter/sendkeys.py is the Windows end.
                          Keys must be BROADCAST; see below
NTP [a.b.c.d]             what time does that server think it is? Our own
                          UDP, not mTCP. Read-only -- it never sets the clock
UGET ip name file [POLL]  fetch a file from dosd over UDP. The HTGET
                          replacement. Silent unless -V; honest exit code
UPUT ip file name         send a file to dosd over UDP. The NC replacement
NETCHK ip | /PROBE ip | /OK | /STATUS
                          the agent's "is it us or them?" check. On every
                          30th failed poll it ARPs the server, then the
                          router; only if NEITHER answers -- or there is
                          no packet driver at all, since 2026-09-25 --
                          does it tell AI.BAT to cold-boot, at most 3
                          times an outage.
                          /STATUS prints C:\AGENT\NETCHK.LOG. See
                          docs/network.md, "The link that does not come back"
ELAPSED /S | <text>       job stopwatch. /S stashes the tick; otherwise
                          prints <text> with the time since, on ONE row
```

The graphics and sound demos, built from the same tree but not diagnostics:

```
RAYCAST [INT|FPU] [SECS n] [SEED n] [KEYS|PLAY file] [HOLD] [NOPIVOT]
        [QUIET|SPKR] [TEX|FLAT] [M13|COARSE|FINE] [NOSEEK]
                          Wolfenstein-style raycaster with AdLib music. Walks
                          itself round a GENERATED 64x64 maze and prints what
                          it drew, or is driven -- KEYS from the keyboard,
                          PLAY from a file of timed events. SECS goes to 1800
                          now that longer runs see more; raise --timeout to
                          match. SEED is the whole description of the world
FRACTAL [INT|FPU] [ZOOM n] [SECS n]   Mandelbrot, both inner loops
BALLS                     bouncing balls in mode 13h, mono or colour
MATRIX [seconds]          the falling-green-text screensaver, text mode
SCROLLER [SECS n] [SPEED n]   mode X scroller, sprites + AdLib. See SCROLLER.md
PARALLAX [SECS n] [SPEED n] [SWEEP n] [CARS n] [MONO|COLOUR]
         [NOMUSIC] [NOFPU] [NOPAUSE] [NOSHOT] [PROF]
                          NEON DRIFT. Mode X split-screen parallax: a CRTC
                          line compare pins the bottom 36 rows, so the grid
                          floor is repainted every frame and EVERY ROW gets
                          its own scroll rate -- the geometry, not an effect.
                          Two hovercars, OPL2 soundtrack, and the coprocessor
                          used only if it wins a race against the integer
                          path. Dumps system and PicoMEM info first.
                          See PARALLAX.md
SVGATEXT [text]           rotating text; VBE 640x480x256, else mode 13h
GTEST                     mode 13h test pattern, deliberately leaves the mode set
PROFTEST                  exercises the Prof unit's section timing
```

The ones whose behaviour is not obvious from a one-line description have their
reasoning in `docs/tools.md`: `VMODES` and the two directions in which mode
enumeration lies, `BEEP` and why alerts have to be long, `IVT`, `SERIAL`'s
opt-in switches, `SCRAPE`/`VSHOT`, `DSTAT`, `DEVS NAME`, `HD`, and the `Prof`
unit's sampling rules.

### Measured performance — check here before optimising

`BENCH` measured on this box (an NEC V30 at 8086 speeds), operations per second:

```
loop + increment    88961      procedure call      46501
16-bit add          72800      shl by CL (8086)   185021
16-bit multiply     58640      shl by imm (186)   206260
16-bit divide       52561      MemW[] to B800      58640
32-bit multiply     10920      REP STOSW to B800  439821
32-bit divide        7280      array[] store       68322
```

**This box has an 8087 fitted**, confirmed 2026-09-20, so the four
coprocessor rows print rather than skipping: FPU add 71780, multiply 61661,
divide 34361, sqrt 42460 per second. That is about **five times** the
software 32-bit routines above -- and it still does not beat the integer
path in real code, because `FRACTAL`'s Q8 loop is 16-bit `IMUL` and was
never paying for those routines. Measured: 108 rows against the 8087's 60,
in the same time. `docs/hardware.md` has the detail.

Two ratios explain nearly every performance problem hit so far:

* **32-bit arithmetic costs 5-8x its 16-bit equivalent.** FPC calls software
  routines for `LongInt` multiply and divide. Converting the Mandelbrot inner
  loop from Q10 `LongInt` maths to Q8 with a single `IMUL` was worth more than
  everything else combined.
* **`REP STOSW` beats per-element `Mem[]`/`MemW[]` by 7.4x.** Every `Mem[]`
  access reloads a far pointer. Replacing a per-pixel loop with one string
  instruction is what doubled the bouncing-ball frame rate.

A third ratio, measured on hardware 2026-08-30, is worth knowing before you
reach for `Has186`: the 186-class immediate shift is **only about 11% faster**
than going through CL (206260 vs 185021 per second). Real, but small. Do not
write a gated fast path for a shift alone -- the gate costs more to maintain
than the win buys. Save `Has186` for something that measures better.

Run `BENCH` before theorising about where time goes. Guessing produced two
wrong answers during the graphics work — blaming VBE bank switching and then
call overhead, both of which measured as irrelevant.

### Attribution: the `About` unit

Every program in `starter/` has `About` in its uses clause, and that is all it
takes -- the banner is printed from the unit's `initialization` section, which
FPC runs before the main program body, so the line lands above whatever header
the tool prints for itself:

```
DOS Bridge tools  --  StevenC & Claude  --  built 2026/09/23
=== sysinfo ===
```

One place rather than a `WriteLn` pasted into twenty-nine programs, because a
banner copied twenty-nine times says twenty-nine slightly different things
within a year -- and the one moment it matters is an EXE found on a disk with
no context, which is exactly where the drift would show. Because the string is
printed it is certainly linked, so `HD` on the binary identifies it even if
nobody runs it. Verified: all 29 EXEs carry both `DOS Bridge` and `StevenC`.

Adding it to a new tool is one word in the uses clause. Nothing to call, and
nothing to forget.

**Credit StevenC AND Claude on anything new -- StevenC's standing rule,
2026-09-23.** "Make sure Claude is mentioned too in anything we do. I am
guiding you, but you are doing the heavy lifting." So every new program
banner, source header, README and changelog entry names both, in the form
the PicoMEM driver set:

```
Optimized by StevenC & Claude: ...                          (a banner line)
Written by **StevenC** and **Claude** (Anthropic): ...      (a README)
```

A `Co-Authored-By: Claude` commit trailer does not count on its own -- the
credit belongs where a reader sees it. Every README and CHANGELOG in this repo
and in `C:\CH375USB` says so as of that date, and `C:\CH375USB\CLAUDE.md`
carries the same rule for a session opened there.

**Every binary was rebuilt with the new credit on 2026-09-24**, at
StevenC's request: the `About` banner above, every starter tool, and every
program and driver in `C:\CH375USB` (`USBKBD 1.7.1 -- StevenC & Claude` and
the rest), then deployed to the V30 -- 35 tools to `C:\TOOLS` and 82
programs to `C:\CH375\`, every one CRC-checked on the box. Versions were not
bumped -- no code changed -- so two builds of, say, `USBKBD 1.7.1` exist;
the CRC tells them apart, and each project's CHANGELOG records the rebuild.
A README that quotes a banner quotes the new one. Historical transcripts in
the docs (a banner with a date on it) stay as they were printed.

**Silent by design, so not credited in their output**: `UGET`, `UPUT`,
`NETCHK`, `KEYHIT`, `SCRLOFF` and `ELAPSED` run inside the agent loop or a
job, where a banner would print on every poll; `KINJ` and `KNET` are
resident. Their source headers carry the credit. **`UGET` and `UPUT` were
deliberately NOT replaced**: a fresh build came out ~400 bytes smaller than
the committed one from unchanged sources (the old binary was made from some
other compiler/unit state), so shipping it would have swapped the V30's
proven transport for an unproven one, with nobody at the machine, for a
change that adds no credit. Those binaries -- CRC `A3B45BDD` and
`8FA5110E` -- stayed until the transport changed for its own reasons, which
it did on 2026-09-27 (below): **the transport now is `UGET` `502A18C8` and
`UPUT` `C944798B`**, proven on the V30 with StevenC at the machine, the old
pair kept on the box as `C:\TOOLS\UGET.OLD` and `UPUT.OLD`. `NTP.EXE`
rebuilt ~420 bytes smaller the same way and did ship: it is not in the
transport.

**The transport got 4x faster on 2026-09-27, without changing the
protocol.** `docs/network.md`, "Where the time went", has it: the UDP
checksum was Pascal calling a procedure per word (52 ms a 1400-byte block,
now 3 ms in `starter/sumbuf.inc`, proven equal by `sumtest.pas` over 18,180
cases), payloads were copied a byte at a time, and every block was its own
disk write or read.  `dospull` of 512 KB: 57.6 s -> 13.8 s.  Still
stop-and-wait -- the rule below about nothing on the wire while in DOS
holds, and a sliding window is still undone.

## Hard constraints — these are not style preferences

**Exit codes must be ≤ 20.** DOS 6.22 cannot read `ERRORLEVEL` into a variable,
so `dosd.py` generates an `IF ERRORLEVEL n` ladder that stops at 20. A program
returning 47 will report as 20. `Tester.Finish` already caps at this.

**A DOS critical error is a remote hang.** Anything that touches a drive with
no media — `INT 21h AH=36h` on an empty floppy is the one that caught us — puts
"Abort, Retry, Fail?" on the console and blocks until somebody presses a key.
Over the bridge that is indistinguishable from a wedged machine, and it needs
physical hands to clear. Never probe A: or B: speculatively; `hwinfo` starts its
drive scan at C: for exactly this reason. The general fix, if a tool ever really
must touch removable media, is an `INT 24h` handler that returns 3 (fail)
instead of prompting.

Symptom to recognise: output truncated mid-line with `##RC=` glued to the end.
That is DOS never flushing its buffer because the program was aborted at the
prompt, not a crash.

**Never move binaries with `TYPE` or a bare `NC`.** Use `dospull`. DOS `TYPE`
stops dead at the first 0x1A (Ctrl-Z), and `NC` without `-bin` opens stdin in
text mode and silently eats every 0x0D and 0x1A — a 27298-byte EXE came back as
27258, corrupt but plausible-looking. `dospull` uses `NC -bin` into a dedicated
raw port (8082) that does no decoding at all; that `-bin` is load-bearing.
`dosexec "TYPE ..."` is fine for text files and nothing else.

**A job that reboots cannot report back.** `dosexec "REBOOT.COM"` runs the
reboot partway through `JOB.BAT`, so the machine is gone before the `NC` that
would send the result. The old behaviour was a silent 120-second wait ending in
"DOS box may be hung", which blames the box for doing exactly what it was told.
`dosctl exec` now spots `REBOOT`/`COLDBOOT` in the command list, says so, and
switches to watching the box drop and return instead of waiting for a result.
It also warns that any commands *after* the reboot will never run.

Use `dosreboot` to reboot, or `dosrun --reboot` to run something and then
reboot. `dosdrv` already does this correctly -- its batch ends with
`COLDBOOT.COM` and reports through the crash guard on the next boot instead.

**Don't trust `dosexec`'s exit code for internal commands.** DOS internal
commands (`ECHO`, `VER`, `DIR`, `IF`, `DEL`, `TYPE`) never set `ERRORLEVEL`.
`dosd` runs a generated `EXIT0.COM` before your commands so the ladder reads a
known 0 instead of a stale value, but a *failing* internal command still can't
report failure — `DIR C:\NOSUCH` exits 0. Assert on stdout for those. The exit
code is only meaningful when the last command is an external program. `dosrun`
is unaffected: the program it runs sets a real `ERRORLEVEL`.

**A missing program was the worst version of this, and it is now caught.**
`dosexec "C:\BAD.EXE"` used to return **no output and rc 0** — a confident
success for a program that never ran. Two things conspire: COMMAND.COM writes
`Bad command or file name` to a console 6.22 cannot redirect (there is no
stderr redirection at all), and a bad command leaves `ERRORLEVEL` untouched,
which `EXIT0.COM` has just forced to a clean 0. The box says so on its own
screen and has no way to tell anyone.

So `dosd` now emits a guard before any command that names a program by an
explicit path:

```
IF NOT EXIST C:\BAD.EXE ECHO ##NOEXEC=C:\BAD.EXE >> C:\WORK\OUT.TXT
```

`dosctl` lifts that marker out of the captured output, prints the program that
was missing, and exits **127**.

**The check is deliberately narrow: an explicit path AND an executable
extension.** Both halves are load-bearing, and widening either would make it
worse than useless:

* `IF EXIST FOO.EXE` searches only the current directory, so checking a
  PATH-resolved name would report every working tool as missing. A false
  "not found" on a command that runs is worse than the silence it replaces.
* `C:\TOOLS\FPU` has no extension, and COMMAND.COM would happily find
  `FPU.EXE` for it. Flagging that would be wrong too.

Narrow still covers the case that actually bites, because `C:\TOOLS` is not on
the box's PATH: the documented way to call every tool in the kit is by full
path, so a typo in one of those is exactly what used to vanish.

For everything else — a bare name resolved through PATH — nothing on the DOS
side can tell us. `dosctl` falls back to saying so: a job that returns empty
output with rc 0, where some command could have been a program, prints a note
that this is also what a missing program looks like. It does not change the
exit code, because a job made of `DEL` and `SET` is legitimately silent.

**Output must go through DOS.** `WriteLn` is captured; direct writes to B800
video memory are not. A program that only draws to the screen returns an empty
log. If you write screen code, make it also `WriteLn` what it did.

**8.3 filenames.** `dosctl` rejects long names rather than letting DOS silently
truncate them.

**A `>` immediately followed by `=` is a syntax error, even inside a `REM`.**
COMMAND.COM parses redirection before it works out that the command is a
comment, and `>=` is a redirect with no filename. Every time the line is
reached it prints `Syntax error` on the console. Nothing is created and
nothing breaks -- `REM` never opens the file -- but it is noise on a screen
whose whole job is to be readable, and it appears at exactly the moments
somebody is standing there reading it.

Verified on hardware 2026-09-03, one form at a time:

| in a `REM` line | |
|---|---|
| `-` then `>` (an arrow) | fine |
| `=` then `>` | fine |
| `>` then `=` | **`Syntax error`** |
| `> NUL` | fine |

It arrived in a comment explaining the `ERRORLEVEL` fix above -- the phrase
"which is >= 20" -- so the agent printed a syntax error on every failed poll
while working perfectly. Write "20 or more" in batch comments. The first
attempt at the fix reintroduced it in the sentence describing the rule, which
is why the check that catches it is a grep for `>=` on `REM` lines and not a
careful read.

**A chained `IF` silently drops an external command.** COMMAND.COM 6.22 runs
`IF cond IF cond CMD` correctly when `CMD` is *internal* (`ECHO`, `GOTO`,
`DEL`), and does **nothing at all** when it is *external*. No error, no output.
This cost a debugging round: `IF NOT "%MTCPCFG%"=="" IF EXIST %MTCPCFG% FIND
"IPADDR" %MTCPCFG%` printed nothing and read as a missing config file, while
the same `FIND` behind a single `IF` worked. One `IF` per line; branch with
`GOTO` when two conditions are needed.

**mTCP tools consume queued keystrokes.** `HTGET` and `NC` poll the keyboard so
ESC or Ctrl-Break can abort a transfer, and they eat whatever is waiting. Never
build a control mechanism on `INT 16h` buffered input in a loop that also does
network I/O -- see the ScrollLock section above for what to do instead.

**Never write to CONFIG.SYS.** This is the important one. A bad driver in
`CONFIG.SYS` hangs the machine before `AUTOEXEC.BAT` runs, which means no code
on the box can undo it and power-cycling just re-runs the same bad config — it
needs a boot floppy and physical hands. `dosdrv` therefore stages drivers into
`C:\AGENT\PEND.BAT` and loads them with `DEVLOAD` from `AUTOEXEC.BAT`, after the
network is already up, behind a `TRYING.FLG` guard. If you are ever tempted to
edit `CONFIG.SYS` to make something work, stop and raise it instead.

**A program that runs for more than a few seconds must prove it is alive,
and the proof has to be driven by the CLOCK.** A silent program and a
hard-locked machine are indistinguishable from here, and everything in this
project that ever needed hands on the keyboard looked like a hang first. A
45-minute test that prints nothing at the start and nothing until the end is
45 minutes in which nobody can tell which of those two things is happening.

Three parts, and each of them is load-bearing:

* **On stderr, not stdout.** A job's stdout is redirected into
  `C:\WORK\OUT.TXT` and reaches nobody until the job ends. COMMAND.COM 6.22
  has no stderr redirection at all -- normally a nuisance here -- so handle 2
  lands on the real screen, where `doscap` can photograph it, while the
  captured output stays clean for the result.
* **Driven by the tick, never by the work.** An indicator that advances per
  packet or per block freezes both when the program dies *and* when the work
  merely stops, which are the two cases most worth telling apart. Time-driven
  it reads:

  | | |
  |---|---|
  | advancing, counters rising | working normally |
  | advancing, counters static | alive, nothing arriving |
  | frozen | the machine is locked |

* **In place, so it scrolls nothing.** One character then a backspace, or a
  carriage return and no newline. The console here is a status display and
  the boot banner is worth keeping on it -- `UGET`'s spinner takes its phase
  from the BIOS tick at `0040:006C` and needs no state of its own.

`starter/uget.pas` is the original; `CH375Net`'s `RAMPCHK` and `USBVFY` both
carry one. RAMPCHK's first version ticked once per 256 KB, which on this box
is one move every eighteen seconds -- a heartbeat slower than the observer's
patience is not a heartbeat, and it would have failed at the one job it
exists to do.

**Any program that touches the screen must pull in `VidFix`.** FPC's i8086
runtime installs a coprocessor-error handler on **INT 10h**, the video BIOS
vector. On an 8086/V30 with no 8087 its `FNSTSW` reads back zero and the stub
chains harmlessly; on a **386 with no 387** it reads back with bit 7 set, the
stub takes its error path, and the first video BIOS call never returns -- the
machine dies in silence, printing nothing, because the output is still in a
buffer. That is one box working and another wedging on the same binary.

`starter/vidfix.pas` puts the vector back, and only when it is certain: no
coprocessor, the vector points inside the running program, the bytes are the
stub with `FNSTSW`, and the saved address it recovers is in ROM. It is inert
where nothing is hooked, so one binary suits both machines. `About` pulls it
in, so every tool with a banner has it; `UGET` and `UPUT` name it explicitly
because they deliberately print no banner. A fixed EXE contains the string
`coprocessor, and the stub`.

**Upgrade the transport last.** `dosctl upgrade --tools` deploying tools built
before that fix took the 386 off the bridge, because `UGET` was among them and
the agent needs it to poll. Recovery was `HTGET` at the keyboard.

**Avoid SysUtils in Pascal.** `IntToStr` and friends link a lot of dead weight
into a 16-bit real-mode binary. `Tester.Note` has a `LongInt` overload for this
reason.

**`dosctl stop` is a one-way door.** Once the agent loop exits, nothing on the
box is polling, so nothing on this side can reach it. Restarting needs someone
at its keyboard typing `C:\AI\AI.BAT`, or a power cycle. The same is true of a
Ctrl-C at the machine. See `docs/agent.md` for the safe exit points.

**A box that has stopped polling is not necessarily hung.** A stalled transfer
used to leave `UGET` rebuilding its flow for minutes with the agent loop
perfectly healthy, and that is indistinguishable from a wedge from here. It
was misdiagnosed three times in one day and twice ended in a power cut to a
machine that was going to come back on its own. Check `doscap shot` and
`dospower` (watts, not just the relay) before cutting power; `docs/agent.md`
has both failure signatures and how to tell them apart.

**A power cut does not currently recover this box unattended.** POST stops at
"Press F1 to continue" because of the CMOS fault, so a cycle leaves the machine
powered, drawing ~37 W and never polling -- which looks exactly like the hang
it was meant to fix. Read a failed recovery as "check the screen", not "the
machine is dead". Prefer a warm `dosreboot` whenever the box still answers.
`docs/hardware.md` has the diagnosis and the POST codes that settle it.

**After a freeze, read `C:\AGENT\PHASE.LOG` before anything else.** Every
generated batch drops a breadcrumb per phase, so the last line says whether it
died in the transfer, between commands, inside the program, or in the poll --
and an *absent* new entry is itself the signal for a poll hang.

```
dosexec "TYPE C:\AGENT\PHASE.LOG"      or  dospull C:\AGENT\PHASE.LOG
```

**If an agent upgrade leaves the box unreachable**, at the keyboard:
`COPY C:\AI\AI.BAK C:\AI\AI.BAT`. Note that "it did not come back" has been
reported for an upgrade that completely succeeded -- give it a minute and run
`dosctl status` before reaching for the rollback.

**`##BOOTOK` means the machine survived, not that the driver loaded.**
`DEVLOAD` exits 0 for a character device but returns the first assigned drive
number for a block device, so its errorlevel alone cannot be trusted. Always
confirm with `MEM /C` and `IF EXIST <DEVICENAME>`, or use `dosdrv --device
NAME`, which turns the miss into a non-zero exit.

**`drvtest/TESTDEV.SYS` hangs the machine.** It is not the safe known-good
driver its README claimed: run directly under `DEVLOAD /V` it wedged the box
and needed a physical reset. `drvtest/HANG.SYS` wedges it on purpose and has
never been exercised -- only run either with somebody at the machine.

## Reserved exit codes

| | |
|---|---|
| 253 | driver wedged the machine; it was skipped on the recovery boot |
| 254 | file download to the DOS box failed |
| 127 | a command named a program that is not on the DOS box |
| 124 | timed out waiting for the DOS box (probably hung) |

127 is the conventional shell code for "command not found" and cannot collide
with a DOS program's own status, because the `IF ERRORLEVEL` ladder stops at
20.

## Toolchain

Free Pascal 3.2.2 cross-compiling to `i8086-msdos`. The **i386/win32** native
compiler is the prerequisite for the cross package, not the Win64 one.

```
fpc -Tmsdos -Pi8086 -WmLarge -FEbuild -FUbuild <name>.pas
```

Memory model is `-WmLarge` by default. `-WmSmall` if the binary is tight and
data fits in 64K.

### Assembling on the DOS box itself

Use **`MNASMFIX.COM`** for `.ASM` files. It is a build of `mininasm`, a
NASM-compatible assembler that runs in **real mode**:

```
C:\WORK\MNASMFIX.COM -O9 -f bin -o FILE.COM FILE.ASM
```

**It is not on the box, and this file said for a long time that it was.**
The path given here used to be `E:\MNASMFIX.COM`, which does not exist: a
job naming it gets `Bad command or file name` on the box's own screen and,
but for the missing-program guard, would have come back as rc 0 with no
output. The working copy lives in the CH375USB collection at
`CH375Mouse/tools/MNASMFIX.COM` -- deploy it with `dosdeploy` like anything
else.

**It has no include path.** `-I` does nothing, so a source using `%include`
needs every included file in the CURRENT DIRECTORY and the assembler run
from there: `CD C:\WORK` first, then plain filenames. `-O9` matters too;
without it some jumps stay in their long form.

Only `-f bin` and `-f com` are supported — no `obj`, so no linker step. That is
fine for `.COM` programs and for `.SYS` device drivers, which are flat binary
images anyway. It defines `__MININASM__`, and supports the usual NASM
preprocessor (`%INCLUDE`, `%DEFINE`, `%IFDEF`, `TIMES`, `STRICT`).

**Do not use `C:\NASM\NASM.EXE`.** It is a 32-bit DJGPP build that needs
`CWSDPMI`, and this box is 8086-class with no protected mode at all, so it cannot
run on this machine. That is what `MNASMFIX.COM` exists to work around.

Verified end to end on 2026-08-29: a 281-byte `.ASM` deployed with `dosdeploy`,
assembled to a 40-byte `.COM`, ran, and returned its output and errorlevel 3.

### Borland Pascal 7 / TASM

`C:\BP\BIN` holds a full BP7 install, but it is **not** all real-mode native.
Exercised from the bridge on 2026-08-30:

| | |
|---|---|
| `TPC.EXE` | **works.** Turbo Pascal 7.0 command-line compiler, real mode |
| `TASM.EXE` | **works.** Turbo Assembler 3.2, real mode, writes to stdout |
| `BPC.EXE` | **no** — `Stub error (2001): needs at least 286` |
| `TLINK.EXE` | **no** — `Failed to locate DPMI server (DPMI16BI.OVL)` |
| `BP.EXE` | never run it over the bridge: full-screen IDE, waits for a key |

So on an 8086-class box the usable pair is `TPC` (which has its own built-in
linker and needs no TLINK) and `TASM`. `BPC` and `TLINK` are DPMI applications
and are simply unavailable here.

Verified end to end: a `.PAS` deployed with `dosdeploy`, compiled with
`C:\BP\BIN\TPC.EXE`, run, output captured, `Halt(3)` came back as errorlevel 3.

Two gotchas worth knowing:

* **`BPC` writes its errors straight to video memory**, so a failed `BPC` run
  returns completely empty output and rc=0 over the bridge — it looks like a
  command that did nothing. That is how the 286 stub error stayed invisible
  until `SCRAPE` was run in the same job. `TPC` and `TASM` both use stdout and
  capture normally.
* **Never `uses Crt` in a program driven over the bridge.** Crt's unit
  initialisation replaces the standard Output driver with one that writes
  straight to video memory, so every `WriteLn` after it stops being captured
  and the job returns empty. If you need the speaker, program ports 43h/42h/61h
  directly the way `starter/beep.pas` does, and take timing from the BIOS tick
  counter at `0040:006C` rather than Crt's `Delay` -- which also sidesteps the
  Runtime Error 200 calibration bug. Verified working in `C:\BPDEMOS\BPHELLO.PAS`.
* `TPC` prints a progress counter that relies on carriage returns overwriting
  in place. Redirected to a file it accumulates, so a clean compile looks like
  `BPHELLO.PAS(1)BPHELLO.PAS(1)BPHELLO.PAS(9)BPHELLO.PAS(9)`. That is normal
  output, not an error.

`TPC.CFG` and `BPC.CFG` both point `/U` at `C:\BP\UNITS`, which is **empty** on
this box; the real `TURBO.TPL` lives in `C:\BP\BIN` and the compiler finds it
next to itself, so a plain program compiles regardless. Anything needing `Crt`,
`Dos` or `Graph` may need `/UC:\BP\BIN` adding.

Code size is the reason to care: `TPC` built a 2,320-byte hello, against
25,880 bytes for the same thing cross-compiled with FPC.

## Testing without hardware

`selftest.py` runs `dosd.py`, a simulated DOS box, and the CLI end to end. Use
it to check changes to the bridge itself before involving the hardware. It does
not exercise the packet driver or any real hardware — a green selftest means the
Windows half is sane, nothing more. It needs 8069 and 8080-8082, so stop the
daemon first (`dosctl shutdown`).

**Its daemon binds LOOPBACK ONLY (`DOSD_BIND=127.0.0.1`), and that is
load-bearing.** A selftest daemon on `0.0.0.0` is indistinguishable, to a
real DOS machine polling the LAN, from the one it just replaced. On
2026-09-21 both live boxes polled a selftest daemon and raced the simulated
box for its jobs — and step 1 dispatches `run local/PROG.EXE`, where
`PROG.EXE` is 3600 bytes of generated pattern rather than a program. **A
real 386SX executed it and had to be recovered by hand.** It had always
worked this way and had never bitten, because the host firewall was quietly
dropping every inbound poll; fixing the firewall removed that accidental
protection and the hazard surfaced the same afternoon. Never take the
loopback bind off, and if you write another test that starts a daemon, give
it the same treatment: **a test that can reach production hardware
eventually will.**

**`simulate_dos.py` speaks the real transport**, and that is the part worth
protecting. It does actual TFTP against `dosd` — RRQ/WRQ, block numbering, ACKs
and the `blksize` negotiation — rather than pattern-matching the batch.

It did not always. The old version grepped each batch for `HTGET -o <url>` and
fetched over HTTP, so when the transport moved to UGET/UPUT **the regex simply
stopped matching and every run kept passing while transferring nothing at all**.
A test that cannot fail is worse than no test, because it is counted as
evidence: `selftest.py` was cited as "the Windows half is sane" during the very
session the 513-byte bug was loose.

Two properties keep it honest, and both are deliberate:

* **The payload crosses a block boundary.** It was 8 bytes (`"MZ fake"`), which
  is why nothing here could ever have caught a truncation at 513 — no transfer
  it made reached a second block. It is 3600 bytes now: three blocks at 1400,
  eight at 512.
* **A file is round-tripped and compared byte for byte.** Both directions are
  stop-and-wait with a short final block meaning "done", so an off-by-one in
  block sizing yields a file that is plausible, complete-looking and wrong.
  Only comparing against the source catches that, which is the same reason
  `dosctl upgrade` CRC-checks what it deployed.

The step numbering is a reminder rather than a rule: if you change the
transport, change the simulator in the same commit, and check the test still
*fails* when you break something on purpose.

## Layout

```
dosd.py           daemon: file serving, job queue, result intake
dosctl.py         the CLI; dos*.cmd are thin shims so it works from any directory
docs/             the long-form documentation this file used to carry whole.
                  One subject per file -- see "The rest of the documentation"
                  above. Anything learned about a subject goes in its file
installer-src/    AUTHORED installer scripts only -- install.ps1, check.py,
                  the two makekit.py, makeinst.py. Nothing generated lives
                  here; the built installer goes to C:\dosbridgeDEVInstaller.
                  buildno.txt is the build counter -- keep it in version
                  control, it is what makes "build 7" mean one thing.
                  The output's README.md is the install steps plus THIS
                  tree's README.md appended whole, assembled at build
                  time -- never hand-write a second copy of it
makeinst.cmd      build that installer from the current dev tree
dos/              files that live on the DOS box. Top level is a TEMPLATE for a
                  fresh install; dos/live/ mirrors THIS box; dos/archive/ is
                  superseded versions. See dos/README.md -- they are different
boxes.py          the registry of DOS machines, shared by dosd and dosctl.
                  boxes.json is per machine and never ships, same rule as
                  power.json and capture.json; boxes.example.json is the
                  schema. Absent means one box and no behaviour change
dosfirewall.ps1   adds the inbound rules the boxes need, scoped to their
                  subnet. dosfirewall.cmd is the shim; both need admin
files/            dosd's serving root for /f/ fetches; holds staged programs and
                  the EXIT0.COM dosd writes on first run
projects/         YOUR work: one folder per project, made by `dosnew NAME`.
                  Staged under its own namespace so filenames cannot collide
extras/           optional DOS enhancements that SHIP with the kit but that
                  nothing installs (INSTALL.BAT never edits CONFIG.SYS):
                  ansisc/ is the fast ANSI.SYS, umbsc/ the UMB manager
                  that uses no low memory, doskeysc/ a DOSKEY with TAB
                  filename completion.  Each extra has its source,
                  a released bin/ and a DOS-readable .TXT; the server half
                  carries the folder, the client half gets EXTRAS\NAME\ with
                  bin/ + .TXT.  Nothing is rebuilt at kit time -- update bin/
                  deliberately.  extras/README.md says how to add one
starter/          FPC cross-compile setup, test harness, worked examples.
                  Reserved for the bridge's own tools -- not for new projects.
                  The TOOLS' sources are in starter/ itself; the DEMOS' are
                  in starter/demos/ (since 2026-09-27) with the units only
                  they use (modex, music, mystery, opl2, retro, pmdet, kbd).
                  build.cmd looks in both, everything builds into the one
                  starter/build/, and the kit ships the demos in client\DEMOS
                  but INSTALL.BAT still puts them in C:\TOOLS -- upgrade and
                  verify look there.  hello.pas stays in starter/: it is the
                  worked example build.cmd and test.cmd default to.
                  demos/: scroller.pas + modex.pas + music.pas are the
                  scroller, the demo that shows what the machine can do,
                  and SCROLLER.md is its write-up. parallax.pas + retro.pas +
                  pmdet.pas are NEON DRIFT, the split-screen parallax demo,
                  with PARALLAX.md as its write-up. kbd.pas is the INT 9
                  key-state unit RAYCAST KEYS uses; mkwalk.py generates the
                  timed-event scripts RAYCAST PLAY reads, and walk.txt is one
                  it made for the default seed.
                  starter/ itself: kinj.asm is the resident
                  keystroke injector and screen grabber, mkkeys.py compiles
                  its scripts, session.txt is a worked one. knet.asm is the
                  LIVE remote keyboard -- keys typed on Windows injected into
                  a running program -- and sendkeys.py is its Windows end
capture.py        optional video capture off a USB capture card, so the box's
                  REAL screen can be seen, recorded and photographed. Needs
                  ffmpeg and a capture.json; capture.example.json ships and
                  the live one never does, same rule as power.json
capture.md        how to run the capture: live preview, stills, recording
knet.md           how to use the live remote keyboard, and its four hazards
drvtest/          two throwaway drivers for exercising dosdrv's recovery path
selftest.py       end-to-end test of the Windows half
simulate_dos.py   fake DOS box, used by selftest
```

Each directory has its own README with detail. `README.md` at the root covers
setup and the failure modes worth knowing.

## The other repository this machine builds

Most of the recent work is not in this tree. `C:\CH375USB` is a separate
collection -- https://github.com/jdredd87/CH375USBTools -- of DOS drivers for a
WCH CH375 in USB host mode, and **the bridge is how all of it is built and
tested**: every `build.cmd` in it shells out to `dosctl.py` here, so
`DOSBRIDGE` must point at this folder and `dosd` must be running for any of
those projects to be exercised at all.

Ten projects: a USB mouse driver, a keyboard driver, a combined one, probe
tools, a packet driver for USB Ethernet that reaches the internet, a
DisplayLink second screen, a USB audio project that measures why playback is
impossible on this chip, a USB-to-serial link that talks to a real modem,
`CH375Fossil` -- a FOSSIL driver presenting either that serial link or a TCP
listener to DOS software as a modem on `INT 14h` -- and `CH375Camera`, colour
stills from an IBM PC Camera over an isochronous stream the audio work had
seemed to rule out.

**One more project in that collection is not about the CH375 at all**:
`PicoMEM` reads the PicoMEM card each DOS machine boots from and reaches the
network through -- what it is, its configuration, its live memory map, which
of its emulated devices answer (the 386SX has a working AdLib at 388h and no
sound card in it), a USB mouse arriving byte by byte, and what reading it
costs. Twelve tools, all of which run on a PicoMEM 1 and a PicoMEM 2
unchanged. It sends the card nothing but read-only queries and two mouse
switches, from a whitelist enforced in the one routine that writes its port,
because on both machines **the card is the boot disk**. Read its README
before sending that card anything.

It was two projects, `PicoMEM1` and `PicoMEM2`, merged on 2026-09-20 once
every tool had been run on both cards: the split described the order the work
happened in, not a difference between the cards.

`CH375.md` in this tree is the handover note that started it, and it has been
kept current as the work moved. Read it before touching anything CH375, and
`CH375Net/NEXT.md` over there before touching the packet driver, and
`CH375Camera/NEXT.md` before adding a camera -- it is parked waiting for more
cameras to try, and that file is the plan.

**One constraint from that work applies to this machine generally**: the CH375
card sits at I/O 0260, and anything else put there corrupts its reads --
which is why both `device=` lines in `CONFIG.SYS` are commented out and must
stay together or not at all.

## Status

What is installed and working, as opposed to what is written up:

* **The job loop, both directions of transport, and the whole toolset.** FPC
  cross-compilation, errorlevel propagation through `dosrun` and `dosexec`,
  `dosctl upgrade` over the wire with CRC verification, and `dosctl reboot`
  (warm; `--cold` is still untried).
* **`DEVLOAD.COM` v3.25** at `C:\DOS\DEVLOAD.COM`, on the box's PATH, so
  `dosdrv` is unblocked. Its plumbing -- staging, `PEND.BAT`, the `TRYING.FLG`
  guard, cold reboot, the `##BOOTOK` report -- is verified on hardware, and
  `C:\AGENT` is left clean afterwards.
* **The stop path, end to end at the keyboard**: ScrollLock stops the agent
  and `SCRLOFF` clears the flag on the way out, keyboard lamp included, so the
  restart-stops-again trap is gone rather than merely documented.
* **The CPU and coprocessor probes.** `AAD` identifies the V30 and `Has186`'s
  `db`-encoded immediate shift really executes; the FPU probe runs on a machine
  with no coprocessor without hanging.

* **The transport, at size.** 10 MB byte-exact in one attempt once the box
  started answering ARP; both directions resume from a byte offset. Before
  that, multi-megabyte transfers stalled partway and it read as a flaky link
  for weeks. `docs/network.md` is the account, and it is the first thing to
  read before touching `net.pas` or `tftp.pas`.
* **Build 71 is public** (2026-09-27: DOSKEYSC's TAB remembers the next eight
  names, 5x faster cycling). **Build 70** (2026-09-27: DOSKEYSC, a directory completes with no
  trailing `\`, which CD refuses). **Build 69** (2026-09-27: `extras/doskeysc`, DOSKEYSC -- 6.22's
  DOSKEY key for key plus TAB filename completion, in `client\EXTRAS`).
  **Build 68** (2026-09-27: the kit's demos in `client\DEMOS`, their
  sources in `starter/demos`). **Build 67** (2026-09-27) added the optional `extras/` -- ANSISC, the
  fast 6.22-exact ANSI.SYS, and UMBSC, the UMB manager with no low memory
  -- in `client\EXTRAS` and `server\extras`), at
  https://github.com/jdredd87/DOSBridge.  Build 66 (2026-09-26) brought
  `NETCHK`, the faster `HD` and the StevenC & Claude credit. **A `.SYS` in a
  release can be a driver, not text:** the dev repo's `*.SYS text` rule
  corrupted both extras' drivers once before anything was pushed, and
  `extras/*/bin/*` is binary now -- check a new binary's stored bytes
  (`git cat-file -p :path`) before pushing. Build 62 was the
  first release carrying `docs/`, the ARP fix and the `dosd` single-instance
  guard. See **Cutting a public release** above for how, and for the two
  things building does not verify.
* **Multi-box, built and verified on BOTH REAL MACHINES 2026-09-21.** The V30
  and the 386SX poll one `dosd` at once and are addressed independently;
  `dosrun FPU.EXE --box all` ran one binary on both in parallel and the diff
  table named the difference (`NEC V20/V30` + Intel 8087 against `80386 or
  later` + none), which is exactly what `boxes.json` says to expect of each.
  Two **concurrent** `dospull`s of the same path returned each machine's own
  `NET.CFG` -- `.66` to the V30 and `.67` to the 386SX -- which is the case
  that silently returned the other box's bytes before the pull was keyed on
  the job id. `selftest.py` step 7 covers the same ground with two simulated
  boxes and fails if that keying is reverted.

  **`verify --all` says the two `C:\TOOLS` have NOT drifted**: 41 tools
  checked on each, byte-identical to each other on all 33 that differ from
  the current local build, `PARALLAX.EXE` missing on both. So the
  one-identical-toolset property survived the second SD card, and both boxes
  are simply still on the 2026-09-19 deploy.

  `SET BOXID=` is written into `dos/live/AI.BAT` but **not deployed**, and
  did not need to be: `dosd` routes an untagged poll on its source address,
  so both machines work with nothing on either DOS box touched. It buys the
  identity cross-check, not the routing. `docs/multibox.md` has the account.
* **`PARALLAX` (NEON DRIFT), verified on the V30 on 2026-09-21**: 33.6 fps
  locked to two refreshes, band repaint 11.7ms against 14.27ms of beam, city
  coverage equal at both ends of the sweep (198 and 198 of 320 columns), the
  8087 winning the table race 1067ms to 3850ms, and 461 notes of OPL2 through
  the PicoMEM's emulated AdLib. It is **not** in a public build yet -- cutting
  one is a separate deliberate step.

  Three of its findings are general and are in the topic docs rather than
  here: the pixel pan is latched a refresh later than the start address
  (`docs/graphics.md`, and **`starter/demos/modex.pas` still has it**, so
  `scroller.pas` almost certainly shimmers the same way); a frame that is
  sometimes one refresh and sometimes two is worse than always two
  (`docs/graphics.md`); and PIT channel 0 is in mode 3, so every sub-tick
  measurement -- `starter/prof.pas` included -- is ambiguous by half a tick
  (`docs/tools.md`).

**The V30 was re-verified on 2026-09-20** and the `VidFix` change broke
nothing on it. `VMODES -t` set and confirmed **38 of 38** video modes;
`HWINFO`, `VIDCHK`, `FPU /T`, `BENCH`, `FPUPROBE`, `SYSINFO`, `DSTAT`,
`DEVS`, `MEMMAP`, `IVT`, `SERIAL`, `PKTDRV`, `SCRAPE`, `VESACHK` and
`PROFTEST` all pass, as do `GTEST`, `BALLS`, `MATRIX`, `SVGATEXT`, `MOZART`,
`AMOZART`, `SCROLLER`, `RAYCAST` and `FRACTAL` on both inner loops. `VidFix`
is inert here for a reason worth knowing: with an 8087 fitted it sees a
coprocessor and exits before touching anything.

The CH375 side passed too, on the same machine: the full `USBINFO`
descriptor dump, `SERPROBE`, `SERTALK` pulling a complete `ATI4` S-register
dump off the modem through a Keyspan, `FOSDET` both ways round, and
`FOSTEST` at **57 passed, 0 failed** over the loopback transport.

Known not exercised: `dosctl stop` over the wire (the flag arrives from Windows
rather than the keyboard, same `:QUIT` path), `dosreboot --cold`, `HANG.SYS`,
and the 186/286 branch of the CPU probe -- `AAD` answers NEC first and
short-circuits it; the 386 branch is confirmed on the Gateway 2000 386SX/25. `selftest.py` has not been run since the transport moved to
UGET/UPUT, because it needs the ports `dosd` is holding.

The verification record behind all of this, and the quiet-failure gap that
`PEND.BAT` and `DRVOUT.TXT` were written to close, is in `docs/agent.md`.
