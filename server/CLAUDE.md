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
| Windows box | `192.168.50.46` — runs `dosd.py` on ports 8080/8081/8082 |
| DOS box | polls for jobs; gets its address by DHCP, so don't assume one |

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
192.168.50.66` with no lease. Before that it took a 4-hour DHCP lease, and when
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
`CONFIG.SYS` has one active line, `device=c:\bp\bin\ch375R9.sys`. The box also
carries unrelated software (`WINDOWS`, `BP`, `GAMES`, `NASM`) — don't disturb it.

## Prerequisite for every session

`dosd.py` must already be running in its own window. If commands hang or report
"cannot reach dosd", say so — do not try to start it yourself in a way that
blocks, and do not work around it by skipping hardware tests.

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
dospull C:\PATH\FILE          copy a file off the DOS box, byte-exact
dosexec "MEM /C" "DIR C:\WORK" run arbitrary DOS commands
dosdrv DRV.SYS [args]         stage a driver, reboot, report whether it survived
dosdrv DRV.SYS --device NAME  ...and fail unless NAME registers as a device
dosreboot [--cold]            reboot and wait for it to come back
dosctl stop                   stop the agent loop (one-way -- see below)
dosctl upgrade                update the DOS box over the wire: tools + agent
dosctl upgrade --tools        only the tools in C:\TOOLS (no reboot)
dosctl upgrade --agent        only C:\AI\AI.BAT (swaps, then reboots)
dosctl upgrade --dry-run      say what would change, touch nothing
dosctl version                what build the DOS machine is running
dosctl status                 liveness check
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
PKTCAP [secs] [type|ALL]  capture Ethernet frames. Default 5s of ARP.
                          Opens a handle -- read the warning below
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
```

The graphics and sound demos, built from the same tree but not diagnostics:

```
FRACTAL [INT|FPU] [ZOOM n] [SECS n]   Mandelbrot, both inner loops
BALLS                     bouncing balls in mode 13h, mono or colour
MATRIX [seconds]          the falling-green-text screensaver, text mode
SCROLLER [SECS n] [SPEED n]   mode X scroller, sprites + AdLib. See SCROLLER.md
SVGATEXT [text]           rotating text; VBE 640x480x256, else mode 13h
GTEST                     mode 13h test pattern, deliberately leaves the mode set
PROFTEST                  exercises the Prof unit's section timing
```

`VIDCHK` duplicates one line of `HWINFO` on purpose: `HWINFO` prints it among
thirty others and cannot be branched on, whereas `VIDCHK` is an external program
so its `ERRORLEVEL` is trustworthy. This card boots mono or colour at random, so
`dosexec "VIDCHK"` is the cheap way to find out which before running anything
graphical. Read `HWINFO` when you want the whole picture; run `VIDCHK` when code
has to decide.

`VMODES` is the answer to "what resolutions does this card really do?", and it
exists because enumeration lies -- in both directions.

It under-reports: `VESACHK` once produced **`modes listed: 0`**, reading as "no
SVGA at all", because it filtered on `BitsPerPixel >= 8` and that boot offered
only 800x600 *planar* modes, which report fewer bits per pixel and vanished
silently. That filter is now a label, not a filter.

It also over-reports what is *unavailable*: on the small-memory boot the card
does not list 640x480x256 at all, yet `4F02h` accepted it when asked. Listing a
mode and being able to set it are separate questions, which is exactly why
`VMODES -t` sets each one rather than trusting the list.

`VMODES` with no argument lists standard BIOS modes 00h-13h plus every VESA
entry with its raw attribute word, so you can see *why* something is or is not
usable. `VMODES -t` sets each one, confirms it with `INT 10h AH=0Fh` (or
`4F03h`), pokes the framebuffer, and restores text mode -- in milliseconds,
drawing nothing.

**`-t` alone proves the BIOS accepted a mode, not that it displays.** For that,
`VMODES -t -d 3` draws a test pattern in every mode and holds it three seconds:
a border showing the visible area, sixteen colour bars, two diagonals, and for
text modes cycling attributes across every cell so a 132-column mode rendering
as 80 is obvious. **A monitor that cannot sync still logs as `OK`**, so this
mode says in its own banner that somebody has to be watching. Pair it with
`BEEP` so you know when to look:

```
dosexec "C:\TOOLS\BEEP.EXE ALERT" "C:\TOOLS\VMODES.EXE -t -d 3" "C:\TOOLS\BEEP.EXE DONE"
```

The pattern is drawn one pixel at a time through `INT 10h AH=0Ch`. That is slow
-- about a millisecond a pixel here, which is why it is sparse rather than
filled -- but it is the only way to draw into CGA's interleaved pairs, EGA/VGA's
four bit planes and VESA's banked windows without per-layout framebuffer code:
the BIOS knows the layout and the caller does not.

Two details make it safe to run remotely:

* **Every line is flushed as it is written.** DOS buffers redirected output and
  drops the buffer if the machine wedges, so an unflushed log would end *before*
  the mode that caused the problem. Flushed, the last line names the culprit.
* **Text mode is restored after every mode, not once at the end.** A hang
  halfway through still leaves a usable screen.

Note `-t` and not `/T`: from the Bash tool a leading slash gets mangled into a
Windows path (`/T` becomes `T:/`). Both spellings work on the DOS side.

`BEEP` exists because several tools need a human at the keyboard at a specific
moment, and a message in a window nobody is watching does not achieve that.
Compose it: `dosexec "BEEP ALERT" "MOUSE 15" "BEEP DONE"`. Keep alerts long —
the first version was a 440ms chirp and went unheard; a second and a half of
two-tone siren works.

`IVT` completes the trio with `DEVS` and `MEMMAP`: the device chain, the memory
map, and the interrupt table. A TSR that hooks an interrupt without registering
a device is invisible to the other two, so this is what finds it. Any vector
pointing below A000 has something resident in its path; it walks the MCB chain
to name the owner.

It is also the quickest proof of how a mouse driver installed. `INT 0Ch` owned
by CTMOUSE means it took the COM1 IRQ4 path — which verifies a serial-mode
install without anyone having to move the mouse.

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

### Portability, and the `Cpu` unit

Everything is compiled `-Pi8086` and sticks to the plain 8086 instruction set,
so a binary built here loads on any DOS box. That is deliberate and should stay
that way: a program that will not run on the machine at the other end is worse
than one that runs slower.

`starter/cpu.pas` is how to go faster without giving that up.

```pascal
uses Cpu;

CpuClass   { cpu8086, cpuNecV, cpu186, cpu286, cpu386 }
CpuName    { 'NEC V20/V30', 'Intel 80286', ... }
Has186     { the 80186 instruction-set extensions are safe to execute }
```

**`Has186` is the gate for any CPU-specific code.** The NEC V20/V30 and the
80186 add instructions the 8086 lacks — shifts by an immediate count, `IMUL`
with an immediate, `PUSHA`/`POPA`, `ENTER`/`LEAVE`, string I/O. Executing one
on an 8086 is an invalid opcode. So: write the portable version, write the fast
version, choose between them with `if Has186`, and never delete the portable
one. Emit the non-baseline instruction as `db` bytes — the assembler targets
the 8086 and is right to reject it as source. `BENCH` does this for immediate
shifts and prints both numbers, which is the place to check whether a fast path
is worth writing at all.

The probe runs three tests in an order that matters: FLAGS bits 12-15 to split
8086-class from 286 from 386+, then the undocumented `AAD` opcode to split NEC
from Intel, then shift-count masking to split 8086 from 186. The shift test is
last because sources disagree about whether the V20/V30 masks shift counts, so
the probe never asks it that question. Only the `AAD` step has been run on real
hardware; a 186/286/386 result is unconfirmed.

`SYSINFO` and `HWINFO` both report `CpuName`, so the answer costs one round
trip.

### The math coprocessor

Same unit, same rule, but the failure mode is nastier:

```pascal
HasFpu       { a coprocessor -- or an emulator -- is there }
FpuClass     { fpuNone, fpu8087, fpu287, fpu387 }
FpuName      { 'Intel 8087', '80387 or later', 'none' }
FpuCw, FpuSw { control and status words straight after FNINIT }
```

**An x87 instruction with no coprocessor fitted does not fault on an 8086.**
The CPU decodes the ESC opcode, runs a dummy bus cycle, and carries on — so
the code runs and quietly produces garbage. Nothing reports it. Every tool and
demo in `starter/` therefore stays on the integer path regardless of what is
fitted; `FPU.EXE` is the only program that executes an ESC opcode, and even it
checks `HasFpu` first.

Three things in the probe must not be "simplified":

* **`FNINIT`/`FNSTSW`/`FNSTCW`, never the un-prefixed forms.** `FINIT` and
  friends assemble a `WAIT` (9Bh) in front, and `WAIT` with no coprocessor
  waits on the TEST pin forever. That hangs the box, and over the bridge a hang
  looks like every other hang — it needs hands on the keyboard. FPC emits the
  FN forms verbatim; the probe in the linked binary is
  `DB E3 / B9 14 00 / 49 / 75 FD / DD 3E / D9 3E`, checked byte by byte, no 9Bh.
* **Seed the status word with `5A5Ah`.** With no coprocessor nothing writes
  back, so the seed survives; reading 0 is what proves something answered.
* **Delay between `FNINIT` and the store.** The 8086 does not interlock with
  the 8087 and can reach the store first.

Generation comes from control-word bit 7 — the 8087's Interrupt Enable Mask,
which `FNINIT` sets, giving `03FFh`; a 287 or later dropped the bit and gives
`037Fh`. A software emulator on INT 7 is indistinguishable from silicon here,
and `FPU.EXE` says so rather than overclaiming.

`HWINFO` also decodes equipment-word bit 1, the BIOS's own opinion, and prints
`** MISMATCH` when it disagrees with the probe.

**This box is exactly such a case, confirmed on hardware 2026-08-30.** Its
equipment word reads `4223`, which has bit 1 set -- the BIOS claims a
coprocessor is fitted. `FNINIT` says there is none, and there is none:

```
    coproc bit     : yes   (BIOS opinion; probe says none)
    ** MISMATCH    : equipment word and FNINIT probe disagree
```

Believe the probe. The equipment bit is stamped by POST from a jumper or a
strap and is simply wrong on plenty of clones. This matters because reading
that bit is the *obvious* way to detect a coprocessor and it is what a lot of
period software does -- trust it here and you execute x87 on a machine with no
coprocessor, which on an 8086 does not fault. It quietly computes nothing.

**The 8087 is worth using, and the earlier guidance here was wrong.** Measured
2026-09-01, against the integer paths in the same run:

| | |
|---|---|
| 8087 vs **16-bit** integer | a wash — 61661 against 60660 multiplies/sec |
| 8087 vs **32-bit** `LongInt` | **5.6x faster** — 61661 against 10920 |
| 8087 divide vs `LongInt` divide | **5.0x faster** — 34361 against 6916 |
| `FSQRT` | 42460/sec, with no integer equivalent at all |

So: anything using `LongInt` arithmetic is a strong candidate, and gets full
64-bit double precision for free. Anything already in 16-bit fixed point gains
nothing in throughput — but can trade that even swap for far more precision,
**`fractal.pas` now carries both loops**, chosen at run time:

```
FRACTAL                 use the 8087 if fitted, else Q8 integer
FRACTAL INT             force the integer path
FRACTAL FPU             force the 8087 (refuses if none is fitted)
FRACTAL ZOOM 300 SECS 45    deep zoom -- needs the coprocessor
```

Measured on this box: the Q8 path completes all 200 rows in ten seconds, the
8087 path manages 124. **The coprocessor version is slower**, and that is not a
contradiction of the `BENCH` figures above -- the multiply rates are near
identical, but the x87 loop keeps its values in memory and pays for a
load/store per operation, plus an `FSTSW`/`FWAIT` round trip for every escape
test. It buys precision, not speed.

Precision is the whole point of `ZOOM`. Q8 resolves 1/256, so past ~100x the
window is narrower than one fixed-point step and the picture collapses to flat
blocks; the integer path refuses `ZOOM` for that reason rather than drawing a
lie. Two things learned finding a zoom target worth looking at: every point on
the **real axis** is solidly inside or outside the set, so magnifying the cusp
or the Feigenbaum point just fills the screen with one colour (both tried, both
flat black at 200-400x). The structure is on the boundary and the boundary is
**off-axis** -- so zoomed runs use seahorse valley and give up the mirror,
drawing all 200 rows for a picture that is actually worth looking at.

Two caveats that have not gone away. **Gate it on `HasFpu`** — this suite is
built for machines that may have no coprocessor, and x87 arithmetic carries
`WAIT` prefixes that hang hard when nothing answers. And **`FPU /T` is opt-in**
for the same reason: a probe wrong in the optimistic direction turns a
diagnostic into a machine somebody has to walk over to.

### Profiling your own code: the `Prof` unit

### Shared graphics plumbing: the `VGA` unit

**The video card reports a different amount of memory on different boots, and
therefore a different mode list.** This is the second boot-time lottery on this
machine, alongside mono-vs-colour, and it is much bigger. Two boots, same
hardware, nothing reconfigured:

| | one boot | another |
|---|---|---|
| `4F00h` reports | 256 KB | **1024 KB** |
| graphics modes offered | 2 | **18** |
| of those, 8bpp or better | **0** | 14 |
| best available | 800x600x4 planar | 1280x1024x4, 1024x768x8, 640x480x24 |

So `svgatext.pas` asking for VBE 101h (640x480x256) **succeeds or fails
depending on the boot**. It used to exit 1 and draw nothing when the card came
up small, which is why these notes claimed for a while that the demo "does not
run on this box and never has" -- wrong, and wrong in a way that only a second
boot could expose. It now falls back to mode 13h (320x200x256, guaranteed on
any VGA, no banking) and runs either way.

**The rule this forces:** never record a video capability here as a property of
the machine. Probe it at run time, every run. `VESACHK` and `VMODES` describe
*this boot*, not the card. An earlier `VESACHK` reading of "0 modes" was itself
a filter bug -- but even fixed, its answer is only good until the next reset.

`starter/vga.pas` holds the mode 13h helpers the demos share: `SetMode`,
`GetMode`, `Ticks`, `OutB`/`InB`, `DisplayCode`/`IsColourDisplay`,
`ChoosePalette` (the `MONO`/`COLOUR` argument override), `DacSeek`/`DacRGB`/
`DacGrey`, `WaitRetrace` and `FillSpan`. `fractal.pas`, `balls.pas` and
`vidchk.pas` all build on it; `uses VGA` and the `-FUbuild` already in
`build.cmd` is enough.

It exists because those ~60 lines had been copied between two demos and every
fix — the bounded retrace wait, the six-bit DAC, the display probe — had to be
made twice or silently drift. Two things in it are load-bearing and easy to
reintroduce as bugs if you write your own:

* **`WaitRetrace` is bounded.** An unbounded `repeat until port` wedges the
  machine and needs a physical reset if that bit stops toggling. It counts
  give-ups in `RetraceTimeouts` and accepts tearing instead.
* **`FillSpan` is `REP STOSB`, not a pixel loop.** Per-pixel `Mem[]` reloads a
  far pointer every time and measures ~7x slower; this is what doubled the
  bouncing-ball frame rate.

`fractal.pas` is colour-only by choice. A colour ramp is *not* automatically
safe on a mono display — the monitor sums R+G+B, so two different colours can
land on the same grey — so on a mono boot it looks muddy rather than merely
desaturated. Check with `VIDCHK` first. `balls.pas` still carries both palettes
and picks at run time, which is the pattern to copy for anything that has to
work whichever way the card came up.

### Smooth scrolling: mode X, and why the frame rate is quantised

`starter/scroller.pas` is a side-scrolling landscape with sprites and AdLib
music, and `starter/modex.pas` is the reusable half: unchained
320x200x256 with a virtual screen wider than the display. Verified on hardware
2026-09-01 -- 2096 frames in 30.00s, **69.8 fps, one vertical refresh per
frame, zero late frames**, which is as fast as a 320x200 VGA goes.

**A software scroller cannot be smooth on this box, and the arithmetic says so
before you write one.** A mode 13h frame is 64000 bytes, which `BENCH` puts at
73ms -- 13 fps before a single pixel has been *decided*. So the scroll has to
move to the CRTC: tell the card the picture is 1024 pixels wide while the
monitor shows 320, then move the window with the Start Address (CRTC 0Ch/0Dh)
and the Attribute Controller pixel pan (index 13h). Start address steps four
pixels, pixel pan supplies the remaining nought-to-three, and the whole frame
costs five OUTs.

Unchaining is four registers, and `Enter` reads all four back rather than
trusting them -- a card that ignores one leaves a picture that is *skewed*
rather than absent, which is a confusing way to spend an afternoon:

```
Sequencer 04h  = 06h        Chain-4 off, keep Extended Memory + sequential
CRTC      14h  bit 6 = 0    doubleword off
CRTC      17h  bit 6 = 1    byte mode on
CRTC      13h  = VW/8       Offset: 128 for a 1024-pixel virtual width
```

Two consequences that are easy to miss:

* **Solid fills get *cheaper*.** With all four planes enabled one byte write
  sets four horizontal pixels, so a span is a quarter of the STOSBs mode 13h
  needs. What gets dearer is anything vertical or unaligned, which has to be
  done a plane at a time.
* **There is no room left for a back buffer**, and that is a real trade, not
  an oversight. At 1024 wide the picture is 204800 of the card's 262144
  bytes. Hardware scrolling and page flipping compete for the same memory and
  on a wide world the scroll wins easily -- but it means sprites are erased
  and redrawn in place, so they can shimmer when the beam catches one
  mid-update. The scroll itself never tears; that is the CRTC.

**Wrapping needs no repainting at all** if the geometry is chosen for it. Make
the world 704 columns and the last 320 a copy of the first 320: `704 + 320 =
1024`, so at scroll 703 the window shows the end of the world followed by its
beginning and the scroll can snap back to 0 with the picture unchanged.
Nothing is ever drawn as it comes on screen.

**Parallax is not available.** One start address moves the entire screen. CRTC
line compare gives a second region, but that region is pinned to address 0 and
cannot be panned horizontally, so it can only ever be a *static* band. Depth
has to come from sprites, which are drawn per frame and can drift at any rate.

#### The frame rate is 70.1 / N, and nothing in between

This is the part worth internalising before optimising anything that syncs to
the display. Waiting on the vertical retrace means a frame occupies a whole
number of refreshes:

```
N = 1   70.1 fps    needs the frame under 14.27 ms
N = 2   35.0 fps                      under 28.54 ms
N = 3   23.4 fps                      under 42.80 ms
```

So shaving 10% off usually buys **nothing at all**, and then one more percent
doubles the rate. Every step of tuning this demo, measured on hardware:

| | work/frame | N | fps | |
|---|---|---|---|---|
| 6 sprites, blitter as a hand pixel loop | ~36 ms | 3 | 23.4 | steady |
| 6 sprites, blitter as `REP MOVSB` | ~24 ms | 2 | 35.1 | steady |
| 6 sprites + music | ~19 ms | 2/3 | 33 | **juddering** |
| 5 sprites + music | ~14.5 ms | 1/2 | 56 | **juddering** |
| 4 sprites + music | ~11.5 ms | 1 | 70.4 | steady |

**56 fps is worse than 35 fps, and this is the trap.** A frame time landing
*between* two multiples of 14.27ms gives a respectable-looking average and a
picture that stutters, because consecutive frames are held on screen for
different lengths of time. An average frame rate cannot show you that. Count
the frames that arrive at the flip with the retrace already under way --
`FlipLate` in `modex.pas`, three lines -- and check *that* after any change.

`PROF` is what found the blitter: it reported `draw` at 60% of the frame while
the scroll cost nothing measurable. Guessing would have gone after the scroll.
But note `Mark()` is called ~13 times a frame there and its own cost lands
inside the sections, so a profiled frame is materially slower than a real one.
**Use `PROF` for ratios and take absolute frame times from a run without it**
-- believing the profiled number here hid a whole refresh boundary for two
rounds of measurement.

The fix is the ratio already recorded above, applied to sprites: the sprite
data is **deinterleaved into the four column groups** `c mod 4`, because within
one group the four columns land on four *consecutive* addresses in one plane,
which turns a row into one `REP MOVSB`. Transparency comes from a precomputed
(first, count) run per group-row instead of a test per pixel, so the fast path
stays a string instruction. Copy that pattern for any mode X sprite.

Save and restore of sprite backgrounds use write mode 1 (VRAM-to-VRAM through
the latches), where one byte moved carries four pixels across all four planes
-- four times cheaper per pixel than drawing them.

**`VSHOT` cannot photograph an unchained mode.** It reads A000 linearly, which
is meaningless once the chain is broken, so `scroller` prints its own ASCII
thumbnail by reading pixels back through Read Map Select. Anything written for
mode X needs its own read-back if it is to be checkable over the bridge. Rank
such a thumbnail by a **depth-ordered grey ramp, not by true luminance** -- a
colour palette is chosen for hue, and ranking it by brightness turns a legible
picture into noise.

### Sound while something else is running: `starter/opl2.pas`

`AMOZART` plays a tune and does nothing else, so it can key a note and wait.
Anything with a frame loop cannot, and that is the whole difficulty. The unit
holds the parts that are about the chip rather than the music: `OplDetect`
(the timer method), `OplWrite`, `OplVoice`, `OplNoteOn`/`Off`, `OplSilence`.
`starter/music.pas` is the worked example of driving it from a frame
loop. Note `amozart.pas` predates the unit and still carries its own copy.

Three things learned wiring music into the scroller:

* **Register writes are dear, and it is all waiting.** The chip needs >3.3us
  after an address byte and >23us after data, spent reading the status port.
  `amozart.pas` does that with a Pascal loop, which `BENCH` puts at ~11us an
  iteration, so each register write costs it roughly 480us. Fine for a program
  doing nothing else; far too much inside a frame. The unit uses an assembler
  loop -- same number of bus cycles, about a sixth of the wall clock. Even so,
  three voices changing together is nine writes and about 0.8ms, and that was
  enough to cost the demo a sprite.
* **Take the tempo from the BIOS tick, never from the frame count.** Counting
  frames is the obvious thing when the caller already has a frame loop, and it
  is wrong precisely because of the quantisation above: one sprite more or
  less does not slow the music by 10%, it halves it.
* **Silence the chip on every exit path**, including the error ones. A program
  that quits with a voice still ringing leaves the machine droning, and over
  the bridge nobody can hear that it happened.

`starter/prof.pas` times sections inside a program, so finding a hotspot no
longer means building cut-down copies of it (which is what locating the SVGA
demo's bottleneck actually took).

```pascal
uses Prof;
...
ProfStart;
BuildFrame;   Mark('build');
PaintFrame;   Mark('paint');
ProfReport;
```

Resolution comes from latching PIT channel 0 rather than reading BIOS ticks,
giving ~0.84us instead of 55ms. Reading it needs care: the counter runs down
and wraps slightly before the BIOS ISR bumps the tick, so pairing a post-wrap
counter with a pre-wrap tick makes time run *backwards*. `HiRes` retries until
two tick reads agree, and `Mark` adds one tick back if a delta still comes out
negative.

`ProfReport` also prints a stack watermark, sampled at each `Mark`. That is
there because a recursive directory walker with 12KB frames overflowed the
stack and hung the machine with no diagnostic at all — DOS has no stack guard.

**Give each section at least a few thousand iterations.** Sections of about a
thousand measure roughly 2x slow — `MemW` to B800 read 27763/sec over 1000
writes but 61573/sec over 10000, the latter agreeing with `BENCH`. The cause is
not understood and it is not a fixed overhead (a 4000-iteration section was
accurate to 3%), so treat short sections as unreliable rather than trusting the
absolute number.

`SERIAL` reads the UART registers back rather than assuming anything, so it
shows the baud rate, framing and modem lines a driver has actually configured.
On this machine COM1 (03F8) reads 1200 baud, DTR and RTS asserted, OUT2 set and
the receive interrupt enabled — the exact fingerprint of `CTMOUSE` driving a
serial mouse. DTR/RTS are not incidental there; they are what powers the mouse.

Reading the baud divisor requires setting DLAB in the LCR, which is a write to
a live port, so it is done with interrupts disabled and the LCR restored
immediately. `/T` (UART generation) is opt-in because it writes the scratch and
FIFO registers, and `/M` monitor mode **steals bytes from whatever driver owns
the port** — do not point it at COM1 here while CTMOUSE is loaded.

`MOUSE` deliberately uses INT 33h rather than the UART for that reason: CTMOUSE
owns COM1 and its interrupt. It reports travel and button transitions so the
result is verifiable from the Windows side, but someone has to actually move the
mouse while it samples — run it with `run_in_background` so you can say so
before it finishes. Better still, prefer `SERIAL 1 /ID`, which power-cycles the
mouse via DTR/RTS and reads its reply: silence there is real evidence, whereas
silence from `MOUSE` only means nobody happened to touch it.

### The mouse is a Mouse Systems device, not Microsoft

Worked out on 2026-08-29 by capturing the raw wire. It sends **5-byte packets
with a `1000 0xxx` header** (buttons active-low in bits 2..0, `87` = none down),
where a Microsoft mouse sends 3-byte packets with bit 6 as the sync flag and an
ASCII `M` at power-up. A driver framing for the wrong one sees pure noise.

`AUTOEXEC.BAT` runs `ctmouse /m /3`, and that is **not** enough: `/M` only means
"try old Mouse Systems for non-PnP mice", so CuteMouse's probe still settled on
the wrong protocol and INT 33h reported no movement at all. What works is
forcing the port:

```
CTMOUSE /U
CTMOUSE /S1 /M /3        -> "Installed at COM1 (03F8h/IRQ4) in Mouse Systems mode"
```

After that the mouse reports properly. This is currently a run-time fix only;
`AUTOEXEC.BAT` still has the old line, so it reverts on reboot.

Beware when writing protocol detectors: negative movement deltas (`DD`, `E2`,
`EB`, `F4`, `FC` …) all have bit 6 set. Testing `B and $40` counts movement data
as Microsoft headers and misreports a working Mouse Systems mouse the moment
somebody moves it. Match the whole header shape — `(B and $F8) = $80` for Mouse
Systems, `(B and $C0) = $40` for Microsoft.

`SCRAPE` and `VSHOT` exist to defeat the "direct video writes vanish" rule at
the top of this file. Anything drawing straight to video memory is invisible
over the bridge; these read the buffer back and send it through DOS as ordinary
captured text. Run them in the same job, right after the program:

```
dosexec "MYPROG" "SCRAPE"          text screens
dosexec "GTEST" "VSHOT"            graphics screens
```

Setting a video mode clears video memory, so a program that restores text mode
on exit leaves `VSHOT` nothing to capture. The demos in `starter/` all restore.
`GTEST` deliberately does not, which is what makes it a usable test fixture.
`VSHOT` derives brightness from the DAC rather than the palette index, because
index order says nothing about brightness.

`DSTAT` replaces `DIR /S` piped through a batch file and parsed on Windows:
19 seconds instead of ~5 minutes, and it returns twenty lines rather than
200 KB. It is also *more accurate* than `DIR /S`, which silently skips hidden
directories — on `E:` it finds 3549 files where `DIR /S` reports 3545, the
difference being 4 files inside two hidden `SYSTEM~n` folders. Note `DIR /S`'s
own "Total files listed" counts directories and every `.`/`..` entry as files.

`DEVS NAME` is the reliable answer to "did my driver actually load?" — the
question `##BOOTOK` cannot answer. `MEM /C` only shows drivers that own a
memory block, so it can miss one; this walks the chain DOS really keeps.
Use it after `dosdrv`, and note it only matches *character* devices by name.

`HD` reads binaries that `TYPE` truncates at the first 0x1A. Its CRC-32 matches
Python's `zlib.crc32`, verified on a 25872-byte file, so a deployed file can be
checked against the Windows copy without transferring it.

## Upgrading the DOS box over the wire

Once the bridge is up, the client half updates itself; no USB, no floppy.

```
dosctl upgrade --dry-run      always start here
dosctl upgrade                tools that differ, then the agent, then reboot
```

**Tools** are ordinary `dosdeploy`s into `C:\TOOLS`. One `DIR` listing is
compared against `starter/build` by **file size** and only the differences are
sent — one round trip instead of twenty-five. Size is a proxy, not a hash, so
`--force` resends everything.

**The agent loop is the dangerous one, and the ordering is the safety
mechanism.** COMMAND.COM reads a batch file incrementally *by byte offset*,
re-opening it after every line. Overwrite `C:\AI\AI.BAT` while it is running
and control returns to the old offset inside the new file, landing mid-line and
executing whatever text is there — on a machine that no longer has a working
agent to tell you about it. So the swap happens inside `JOB.BAT` and is
followed immediately by `REBOOT.COM`: `AI.BAT` is never read again after it is
overwritten. Same trick the driver path uses to end with `COLDBOOT.COM`.

Three guards run before anything is overwritten:

* **The end marker.** `dosctl` appends `REM ##AGENT-END` as the last line when
  staging, and the DOS side runs `FIND` for it. A truncated download therefore
  cannot become the agent. This costs nothing and needs no CRC.
* **The address check.** `dosctl` pulls the running `AI.BAT` first and compares
  `SET SRV=` / `SET UPHOST=`. The box is reaching you on those values right
  now, so they are the only ones known to work; sending an agent with different
  ones produces a machine that boots, never polls, and needs hands. Refused
  unless `--force`.
* **The rollback.** The outgoing agent is kept as `C:\AI\AI.BAK`.

If it does not come back, at the keyboard: `COPY C:\AI\AI.BAK C:\AI\AI.BAT`.

Verified on hardware 2026-08-31: a tool and the agent both went over the wire,
the box rebooted into the new agent and resumed polling, and `AI.BAK` held the
previous one.

### What version is the box on?

`C:\AI\VERSION.TXT` on the DOS machine, three short lines. `AI.BAT` `TYPE`s it
in the boot banner, so the machine answers the question on its own screen
instead of someone having to go and ask the Windows side:

```
DOS Bridge client
build 1+
deployed 2026-08-31
```

The client installer writes it; `dosctl upgrade` rewrites it, **last and only
on success** -- a stamp claiming a build the machine did not receive is worse
than no stamp at all. `dosctl version` reads it back over the wire and prints
it next to what this bridge would send.

**The `+` matters.** A packaged installer stamps a bare `build 1`. `dosctl
upgrade` sends whatever is in the working tree, which is normally *ahead* of
the last build cut, so it stamps `build 1+` -- "at least build 1". Claiming a
plain build number for an unpackaged tree would be a lie the moment anyone
edited a `.pas` file.

A box with no `VERSION.TXT` predates stamping or was installed by hand;
`dosctl version` says so rather than guessing, and the next upgrade fixes it.

Note `AUTOEXEC.BAT` and `CONFIG.SYS` are **not** upgradeable this way and
should not be. A bad `AUTOEXEC.BAT` breaks the network before the agent runs,
which is unrecoverable from here; `CONFIG.SYS` is worse still.

## Writing network tools in Pascal

FPC has **no TCP/IP stack for `-Tmsdos`** -- no `Sockets` unit, no resolver,
nothing. Two routes exist and they differ enormously in ambition:

**Shell out to mTCP.** `C:\NETWORK\MTCP` holds `PING`, `NC`, `HTGET`, `SNTP`,
`DNSTEST`, `FTP`, `TELNET`, `SPDTEST`, `PKTTOOL` and more. Drive them with
`dosexec` and read their output. Nothing to build, but you get only what they
already do.

**Talk to the packet driver.** This is the layer mTCP itself sits on: a small,
documented interrupt API published by a resident driver on one vector in
60h..80h. `starter/pktdrv.pas` is the entry point. It finds the driver by the
`PKT DRVR` signature the spec places at offset 3 of the handler, then calls
`driver_info` (AH=1Fh). On this box:

```
INT 60h  name NE2000, spec 11, class 1 (DIX Ethernet), type 54, funcs 2
```

Note the name. `AUTOEXEC.BAT` loads `C:\drivers\pm2000.com`, but PicoMEM's
driver presents an NE2000-compatible interface and reports itself as `NE2000`.
Both statements are true: the file is not the name.

Calling a vector known only at run time needs a trick, because the `INT` opcode
takes an immediate operand. `pktdrv.pas` reads the vector out of the table and
does `PUSHF` followed by a far `CALL`, which leaves the stack exactly as `INT`
would and unwinds correctly on the driver's `IRET`. The fiddly part is that the
call returns with `DS` pointing at the *driver's* segment, so until `DS` is put
back every global in the program is unreachable and storing a result would
write into the driver. Move what you need into registers first, restore `DS`,
then store -- `MOV` does not touch the flags, so the carry the driver returned
is still valid when you test it.

### Capturing frames: `PKTCAP`

`starter/pktcap.pas` is the next step up and the only program here that calls
`access_type` (AH=02h). Verified on hardware 2026-08-31 -- eight seconds of ARP
gave six frames, zero dropped, and the bridge was unaffected:

```
    destination  : FF:FF:FF:FF:FF:FF        (broadcast)
    source       : 74:5D:22:58:B0:98
    ethertype    : 0806  (ARP)
      0000  FF FF FF FF FF FF 74 5D 22 58 B0 98 08 06 00 01
      0010  08 00 06 04 00 01 74 5D 22 58 B0 98 C0 A8 32 1E
      0020  00 00 00 00 00 00 C0 A8 32 D3 ...
```

which decodes as 192.168.50.30 asking who has 192.168.50.211.

Three things in it are load-bearing:

* **`access_type` hands the driver a far pointer to your code**, which it then
  calls at interrupt time for every matching frame. Exit without
  `release_type` (AH=03h) and that pointer dangles into memory DOS has since
  reused -- the next matching frame jumps into it. That is a box with no
  network, and the bridge runs over that network, so recovery needs hands on
  the keyboard. Everything between acquire and release is straight-line code
  with **no DOS calls and no WriteLn**; nothing is printed until the handle is
  back.
* **A frame delivered to your handle is not delivered to mTCP's.** `ALL` takes
  every frame away from the stack this bridge uses, so it is opt-in and the
  default is ARP -- broadcast, frequent, and not something an established
  connection depends on moment to moment.
* **The receiver runs at interrupt time with `DS` belonging to the driver**, so
  none of the program's data is reachable until `DS` is replaced. The first
  fourteen bytes of `PktRecv` are hand-written `db`/`dw` precisely so the two
  words needing run-time patching sit at known offsets `+7` (data segment) and
  `+12` (`Ofs(Shared)`). Let the assembler choose the encoding and those
  offsets stop being knowable from Pascal. **If you edit that prologue, re-check
  the offsets against the linked binary before running it** -- a wrong patch
  corrupts an interrupt-time routine, which fails at the worst possible moment.

The driver calls the receiver twice per frame: `AX=0` asks for a buffer of
`CX` bytes (return `ES:DI`, or `0:0` to drop it), `AX=1` says it has been
copied in. A `Busy` flag makes the second call's buffer safe to read from the
main loop: while it is set the handler returns `0:0` and counts a drop rather
than overwriting a frame being read.

### Transmitting: `ARP`

`starter/arp.pas` sends as well as receives, and the striking thing is how much
easier sending is. `send_pkt` (AH=04h) takes `DS:SI` and `CX` and nothing
else -- no handle, no callback, no interrupt-time code, nothing to release. All
the care in `pktcap.pas` is about the receive path; the transmit half here is a
dozen lines.

ARP was the right first thing to send: complete in 42 bytes, no IP stack
needed, and a reply proves both directions of the driver at once. Verified on
hardware 2026-08-31:

```
ARP 192.168.50.1        ->  192.168.50.1   04:D4:C4:D2:2B:00
ARP -scan 192.168.50    ->  30+ hosts, MAC for each
```

`get_address` (AH=06h) is in there too -- it needs the handle, so it lives
between Acquire and Release. This box reports `28:CD:C1:11:6B:27`, a Raspberry
Pi OUI, which is the PicoMEM's own WiFi radio.

**A bug worth keeping as a warning.** The first version guessed our own sender
address as `.0` of the target's range and got *no replies at all*. The packet
driver has no idea what our IP is -- addresses are a concept one layer up -- so
it has to come from somewhere, and `.0` is a network address that well-behaved
hosts are right to ignore. `arp.pas` now reads `IPADDR` from the file
`%MTCPCFG%` points at, the same place every mTCP tool looks, with `-ip` to
override. If a tool here ever transmits and hears nothing back, suspect the
sender address before suspecting the wire.

### Where to go next

IPv4 is stateless -- a 20-byte header and a 16-bit one's-complement checksum --
and **UDP is then almost free**: eight more bytes and another checksum, no
state machine, no timers, no reassembly. That opens SNTP, DNS, TFTP, syslog and
Wake-on-LAN, each a small program.

**TCP is a different category and probably should not be written here.**
Sequence arithmetic, the connection state machine, retransmission timers,
windowing, out-of-order reassembly. Thousands of lines whose failure mode is
the bad one: correct on the bench, silently corrupting data under loss. mTCP
already has a tested stack on the box, and the bridge itself uses it. Write TCP
only if writing TCP is the point.

## Stopping the agent loop

Three ways, and they fail differently.

| | |
|---|---|
| **ScrollLock** at the box | clean. Noticed within one poll, always between jobs |
| **`dosctl stop`** from Windows | clean, same exit point. One-way: see below |
| **Ctrl-C** at the box | the hammer. Use it for a job that is genuinely stuck |

`AI.BAT` checks both signals at the **top** of the loop, before the `HTGET`
that fetches work. That ordering is the whole point: an exit taken after the
fetch would discard a job the server had already dispatched, and `dosd` would
then wait out its full timeout and report the box as hung -- blaming the
machine for doing what it was told, which is the failure this project keeps
having to design around.

Ctrl-C has no such safe point. Landing mid-`JOB.BAT` means the closing `NC`
never runs and the Windows side times out the same way; landing inside
`:TRYIT` leaves `TRYING.FLG` on disk, and the *next* boot then reports
`##BOOTFAIL rc=253` for a driver that was fine.

**`dosctl stop` is a one-way door.** Once the loop exits, the box sits at a
prompt with nothing polling, so nothing on the Windows side can reach it.
Restarting needs someone at its keyboard typing `C:\AI\AI.BAT`, or a power
cycle. `dosctl` says so before it acts, and then watches the box go quiet
rather than claiming success the moment the flag lands.

**Verified on hardware 2026-09-01**: a reboot into the new agent, ScrollLock
pressed at the keyboard, the loop stopped, and `C:\AI\AI.BAT` restarted it.
Note the box comes back with ScrollLock still *on* if you do not clear it --
the stop message says so, because the agent would otherwise quit again on
its first poll.

### Why ScrollLock and not a keypress

The obvious design is to read the keyboard buffer and look for a letter. **It
cannot work here, and it fails silently.** mTCP's tools watch the keyboard so
ESC or Ctrl-Break can abort a transfer, and in doing so they *consume* whatever
is queued. The agent spends effectively all of its time inside `HTGET`
long-polling for a job, so a keypress is eaten before the loop looks at it.
Measured on hardware 2026-09-01, faking the keystroke by writing into the BIOS
buffer at `0040:001E`:

```
STUFFQ then KEYHIT             ->  rc 1   the key was there
STUFFQ then HTGET then KEYHIT  ->  rc 0   HTGET ate it
```

ScrollLock is not a queued keystroke at all -- it is bit 4 of the BIOS keyboard
flags byte at `0040:0017`, set by the keyboard ISR and touched by nothing else.
It survived the same test with the `HTGET` in the middle. It also has an LED,
so the machine displays its own armed state with nothing on screen.

`KEYHIT.COM` is 22 bytes of hand-assembled code, generated by
`starter/mkkeyhit.py` -- the listing and the byte table are the same file, so
they cannot drift. It is deliberately **not** an FPC program: the loop runs it
every eight seconds forever, and 25 KB of binary re-loaded each time would be
silly, quite apart from `uses About` repainting the attribution banner on the
console every eight seconds.

`CHOICE` in the `:OFFLINE` branch is the one place a real keypress works, since
`CHOICE` reads the keyboard itself. `Q` quits there.

## What the box says on its own screen

`AI.BAT` prints a boot banner: the build from `C:\AI\VERSION.TXT`, the job
server and result host it will use, and its own `IPADDR` read out of whatever
`%MTCPCFG%` points at. That last line exists because when this box went silent
on an expired DHCP lease, the screen looked perfectly healthy and said nothing
at all about the network.

**It scrolls off within about a minute, and that is on purpose.** mTCP prints
a four-line version block on every poll, straight to the console; `> NUL` does
not catch it and COMMAND.COM 6.22 has no stderr redirection.

`HTGET -quiet` **does** suppress it -- measured 2026-09-01: with it on, 55
seconds of idle polling left the screen completely unchanged, against roughly
seven version blocks without it. It was tried, and then taken back out.

The reason is worth keeping. That chatter is the **only continuous evidence the
box has not wedged**, and a machine that has stopped polling looks exactly like
a machine that is quietly waiting -- which is the failure this bridge keeps
having to design around, and the one that costs a walk to the keyboard. Four
noisy lines every eight seconds buys a heartbeat you can see from across the
room. Quieting them buys a readable banner nobody is looking at.

So treat the banner as a boot-time display. The stop message repeats the same
addresses, which is the other place to read them, and `dosctl version` /
`dosctl status` answer from this side.

If the banner ever does need to persist, the way to do it is not `-quiet` --
it is a tiny .COM printing a spinner character followed by a backspace, which
animates in place and scrolls nothing. Same trick as `KEYHIT`, about 30 bytes,
and it can take its state from the BIOS tick counter at `0040:006C` so it needs
none of its own.

`AI.BAT` also sets `TZ`, which `AUTOEXEC.BAT` does not. Without it mTCP refuses
to stamp file timestamps and says so on every poll -- a quarter of everything
on that screen was this one warning. It goes in `AI.BAT` and **not**
`AUTOEXEC.BAT` for the usual reason: a mistake in `AUTOEXEC.BAT` breaks the
network before the agent runs and needs hands on the keyboard, while a mistake
in `AI.BAT` is fixable over the wire.

The environment on this box is nearly full, so a `SET` in the agent can fail
with `Out of environment space`. That is survivable for `TZ` -- you lose the
timestamps and nothing else -- but it is why the banner reads `%MTCPCFG%`
directly rather than copying it to a working variable first. Copying it
*truncated the path* and made a present config file look missing.

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

**Output must go through DOS.** `WriteLn` is captured; direct writes to B800
video memory are not. A program that only draws to the screen returns an empty
log. If you write screen code, make it also `WriteLn` what it did.

**8.3 filenames.** `dosctl` rejects long names rather than letting DOS silently
truncate them.

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

**Avoid SysUtils in Pascal.** `IntToStr` and friends link a lot of dead weight
into a 16-bit real-mode binary. `Tester.Note` has a `LongInt` overload for this
reason.

## Reserved exit codes

| | |
|---|---|
| 253 | driver wedged the machine; it was skipped on the recovery boot |
| 254 | file download to the DOS box failed |
| 124 | timed out waiting for the DOS box (probably hung) |

## Toolchain

Free Pascal 3.2.2 cross-compiling to `i8086-msdos`. The **i386/win32** native
compiler is the prerequisite for the cross package, not the Win64 one.

```
fpc -Tmsdos -Pi8086 -WmLarge -FEbuild -FUbuild <name>.pas
```

Memory model is `-WmLarge` by default. `-WmSmall` if the binary is tight and
data fits in 64K.

### Assembling on the DOS box itself

Use **`E:\MNASMFIX.COM`** for `.ASM` files. It is a build of `mininasm`, a
NASM-compatible assembler that runs in **real mode**:

```
E:\MNASMFIX.COM -f bin C:\WORK\FILE.ASM -o C:\WORK\FILE.COM
```

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
it to check changes to the bridge itself before involving the hardware. It does not
exercise mTCP, the packet driver, or anything real — a green selftest means the
Windows half is sane, nothing more.

## Layout

```
dosd.py           daemon: file serving, job queue, result intake
dosctl.py         the CLI; dos*.cmd are thin shims so it works from any directory
installer-src/    AUTHORED installer scripts only -- install.ps1, check.py,
                  the two makekit.py, makeinst.py. Nothing generated lives
                  here; the built installer goes to C:\DosBridgeInstaller.
                  buildno.txt is the build counter -- keep it in version
                  control, it is what makes "build 7" mean one thing
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
                  and SCROLLER.md is its write-up
drvtest/          two throwaway drivers for exercising dosdrv's recovery path
selftest.py       end-to-end test of the Windows half
simulate_dos.py   fake DOS box, used by selftest
```

Each directory has its own README with detail. `README.md` at the root covers
setup and the failure modes worth knowing.

## Status

Verified on hardware 2026-09-01, the agent controls:

- `KEYHIT.COM` reads ScrollLock correctly (rc 1 on, rc 0 off) **and the
  reading survives a full `HTGET`** -- which is the whole reason it tests a
  flag bit rather than the keyboard buffer. A stuffed keystroke did not
  survive the same test.
- The boot banner renders every line, `IPADDR` included, with no
  `Out of environment space`.
- `TZ` set in `AI.BAT` removed mTCP's timestamp warning from every poll.
- The `STOP.FLG` mechanism `dosctl stop` uses: `COPY` creates it, the DOS
  side sees it, `DEL` clears it.
- End to end at the keyboard: reboot, ScrollLock, loop stopped, restarted.

Still not exercised: `dosctl stop` itself over the wire (same `:QUIT` path,
but the flag arrives from Windows rather than the keyboard), and
`selftest.py` against these changes -- it needs port 8080, so it has to run
with `dosd` stopped.

Verified on the real hardware: the job loop, both directions of transport
(including the mTCP `NC` return path), FPC cross-compilation of `hello` and
`sysinfo`, errorlevel propagation through `dosrun` and `dosexec`, and the
`AAD`-based NEC detection now in `starter/cpu.pas`, which reports
`CPU: NEC V20/V30` correctly on this box.

Verified on hardware 2026-08-30, after the coprocessor work:

- The rewritten CPU probe still identifies the V30 (FLAGS test routes it into
  the 8086-class branch, `AAD` then splits NEC from Intel). `Has186` comes back
  true and the `db`-encoded 186 immediate shift really does execute -- so the
  whole gating mechanism works end to end, not just in theory.
- The **shift-count test has still never run here**: `AAD` answers NEC first
  and short-circuits it. A 186/286/386 result remains unconfirmed.
- The FPU probe runs on a machine with **no** coprocessor without hanging,
  which was the main risk in it. `FPU.EXE` reports `none` and exits 1;
  `BENCH`'s four coprocessor rows skip cleanly.
- The BIOS equipment word disagrees with the probe on this box (see above).

`DEVLOAD.COM` is installed: v3.25 (FreeDOS, GPL2), copied from `E:\DEVLOAD.COM`
to `C:\DOS\DEVLOAD.COM`, which is on the box's PATH. Confirm with
`dosexec "IF EXIST C:\DOS\DEVLOAD.COM ECHO present"`. Its usage is
`DEVLOAD [switches] filename [params]`, which matches what `build_driver_batch`
generates. `dosdrv` is therefore unblocked.

The agent on the box was updated on 2026-08-29 to close the quiet-failure gap:

- `PEND.BAT` is now **served over HTTP** rather than assembled on the DOS side
  with `ECHO`. COMMAND.COM cannot escape a `>` inside an `ECHO`, so the old
  ECHO-built `PEND.BAT` could never contain a redirection — which is what was
  needed to capture DEVLOAD's output at all.
- It runs `DEVLOAD /V` and captures everything to `C:\AGENT\DRVOUT.TXT`, which
  `:TRYIT` now folds into the report. Previously that output went to a screen
  nobody was watching.
- With `--device NAME`, `PEND.BAT` also emits `##DEVICE` or `##DEVFAIL`, and
  `dosctl` turns `##DEVFAIL` into a non-zero exit.

`##RC=0` from `:TRYIT` still only means *the machine survived* — DEVLOAD exits 0
for a character device but returns the first assigned drive number for a block
device, so its errorlevel alone can't be trusted. `--device` is the reliable
check. The live agent is mirrored at `dos/live/AI.BAT`, the pre-change version
at `dos/archive/AI.pre-drvout.bat`, and `C:\AI\AI.BAK` on the box is a rollback
copy.

`dosdrv`'s **plumbing** is now verified on hardware: staging, `PEND.BAT`, the
`TRYING.FLG` guard, cold reboot, and the `##BOOTOK` report with `MEM /C` all
work, and `C:\AGENT` is left clean afterwards.

**But `drvtest/TESTDEV.SYS` is broken — it hangs the machine.** It is not the safe
driver its README claimed. Loaded via `dosdrv` it reported `##BOOTOK` while
silently failing to install (absent from `MEM /C`, `IF EXIST TESTDEV` false);
run directly as `DEVLOAD /V C:\WORK\TESTDEV.SYS` it wedged the machine and needed
a physical reset. Do not use it as a known-good driver. See `drvtest/README.md`.

This is the quiet-failure gap above, observed for real: `##BOOTOK` means "the
machine survived", not "the driver loaded". Always check `MEM /C` and
`IF EXIST <DEVICENAME>`.

`dosctl reboot` is verified: a warm reboot took the box down and back in 28
seconds, the drop-then-return detection worked, and the job loop was healthy
afterwards. `--cold` (full POST) is still untried.

Still not exercised: the `HANG.SYS` crash-recovery path. It deliberately wedges
the box and needs a physical power cycle — only run it when someone is at the
machine.
