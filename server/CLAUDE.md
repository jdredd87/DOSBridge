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

Hardware: NEC V30, MS-DOS 6.22, PicoMEM 1.14 card providing WiFi. About 514 KB
free heap.

| | |
|---|---|
| Windows box | runs `dosd.py` on ports 8080/8081/8082, plus UDP 8069 |
| DOS box | polls for jobs at a static address; see below |

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
| `capture.md` | running the capture card: live preview, stills, recording |
| `knet.md` | the live remote keyboard, and its four hazards |
| `starter/SCROLLER.md` | the mode X scroller |
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
| packet driver | `C:\drivers\pm2000.com 0x60` (PicoMEM native, not NE2000) |
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

Symptom to recognise: the box stops polling and never comes back on its own,
while `dosd` is plainly still listening on 8080/8081/8082. Check with `netstat`
before assuming the daemon died — the failure looks identical from the CLI.

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
palette. `starter/fractal.pas` does this and takes a `MONO`/`COLOUR` argument to
override the probe, which is how to test the path the card didn't boot into.

Note a colour ramp is *not* automatically safe on mono: the monitor sums R+G+B,
so two different colours can land on the same grey. Mono needs its own evenly
spaced ramp.

`C:\MTCP` exists but is empty; the real tools are under `C:\NETWORK\MTCP`.
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

## Commands

```
dosnew NAME                   scaffold projects/NAME/ for a new project
makeinst                      rebuild C:\DosBridgeInstaller (bumps the build number)
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
dosctl status                 liveness check
dosctl shutdown               stop dosd itself (from this machine only)
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
`C:\DosBridgeInstaller\` — that whole tree is a build artifact, overwritten
wholesale by `makeinst.cmd`.

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
HD file [ofs] [len]       hex dump + CRC-32 of any file
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
                          Read-only: no handle, cannot disturb the link
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

The four coprocessor rows print `no coprocessor, skipped` here; see below.

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
DOS Bridge tools  --  StevenC
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
                  here; the built installer goes to C:\DosBridgeInstaller.
                  buildno.txt is the build counter -- keep it in version
                  control, it is what makes "build 7" mean one thing.
                  The output's README.md is the install steps plus THIS
                  tree's README.md appended whole, assembled at build
                  time -- never hand-write a second copy of it
makeinst.cmd      build that installer from the current dev tree
dos/              files that live on the DOS box. Top level is a TEMPLATE for a
                  fresh install; dos/live/ mirrors THIS box; dos/archive/ is
                  superseded versions. See dos/README.md -- they are different
files/            dosd's serving root for /f/ fetches; holds staged programs and
                  the EXIT0.COM dosd writes on first run
projects/         YOUR work: one folder per project, made by `dosnew NAME`.
                  Staged under its own namespace so filenames cannot collide
starter/          FPC cross-compile setup, test harness, worked examples.
                  Reserved for the bridge's own tools -- not for new projects.
                  scroller.pas + modex.pas + music.pas live here rather than
                  in projects/ because they ship in the client kit: the
                  scroller is the demo that shows what the machine can do,
                  and SCROLLER.md is its write-up. kbd.pas is the INT 9
                  key-state unit RAYCAST KEYS uses; mkwalk.py generates the
                  timed-event scripts RAYCAST PLAY reads, and walk.txt is one
                  it made for the default seed. kinj.asm is the resident
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

Known not exercised: `dosctl stop` over the wire (the flag arrives from Windows
rather than the keyboard, same `:QUIT` path), `dosreboot --cold`, `HANG.SYS`,
and the 186/286/386 branch of the CPU probe -- `AAD` answers NEC first and
short-circuits it.

The verification record behind all of this, and the quiet-failure gap that
`PEND.BAT` and `DRVOUT.TXT` were written to close, is in `docs/agent.md`.
