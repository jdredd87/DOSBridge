# DOS Bridge — build 71

_Built 2026-09-27 from `C:\dosbridgeDEV`._

Run and test DOS software on a real 8086-class DOS machine from your Windows
command line, over whatever network card that machine has. Claude Code drives
it like any other test runner: it types `dosrun PROG.EXE`, gets the program's
stdout back, and gets the errorlevel as the exit code.

Every address in this file is an example. Nothing here has one baked in.

It can also **see the screen** and **type at it**: an optional capture card
turns the machine's real video output into stills and video, and two small
TSRs deliver keystrokes to a program that is already running -- one from a
script, one live from your keyboard over the network.

No MCP server. Claude Code already has a shell; this just gives that shell a
command that happens to execute on a 40-year-old computer.

```
Claude Code  ──shell──>  dosrun PROG.EXE
                              │
                dosd.py (Windows: HTTP 8080, TFTP/UDP 8069)
                              │  UDP   ▲ UDP
                              ▼        │
                   AUTOEXEC.BAT loop on the DOS machine
                    UGET job → run → UPUT result back
```

---

## What is in this folder

**Nothing here is edited by hand** — every file is a copy, and the next build
overwrites the lot. It is a build artifact: delete it and run `makeinst.cmd`
again.

Two halves. You need both, and they are installed in this order:

| | | |
|---|---|---|
| **`server\`** | the Windows PC | `dosd.py`, `dosctl`, the tool sources, the docs |
| **`client\`** | the DOS machine | the agent loop, the built tools, `INSTALL.BAT` |

**Server first.** The client half cannot be tested until something is
listening for it to poll.

## Install, step 1: `server\` — the Windows PC

Copy it somewhere permanent (e.g. `C:\dosbridge`), open a command prompt inside
it, and follow `INSTALL.txt`. In short:

    install.cmd            PATH + firewall (needs an admin prompt)
    check.cmd              verifies Python, Free Pascal, PATH, firewall
    dosd.cmd               the daemon — leave it running in its own window
    python selftest.py     proves the Windows half works with no hardware

Free Pascal is a separate download and is not bundled. You need the **i386
win32** compiler first, then the **i8086-msdos cross** package — the Win64
build is not a substitute.

## Install, step 2: `client\` — the DOS machine

Carry it over by floppy, USB, disk image or network share and run `INSTALL`
there. You cannot use the bridge to install the bridge.

`README.TXT` inside it lists the two things you must supply yourself: a
packet driver for your NIC, and `CHOICE.COM`.

**mTCP is not one of them.** The bridge moved onto its own IPv4/UDP stack
and nothing it does touches the mTCP directory. The installer will write a
`MTCP.NEW` config if you point it at one, but that is for mTCP's own
diagnostic tools and is entirely optional.

## Addresses, before you hand this to anybody

Check these on the built kit, and again on the DOS machine:

* `AI.BAT` — `SET SRV=` and `SET UPHOST=` must be **this Windows PC's LAN
  address**. If it was auto-detected it may have picked a VPN or virtual
  adapter; that produces a client which polls forever and is never answered.
* `MTCP.NEW` — the DOS machine's own static address. Nothing has checked that
  it is free on your network. Reserve it, or exclude it from the DHCP pool.

`MTCP.NEW` is deliberately **not** called `MTCP.CFG`. If you already have a
working config, merge the two by hand rather than letting an installer
overwrite something that took effort to get right.

---

# The project's own README

Everything below is `README.md` from the source tree, shipped whole so this is
one guide rather than two. It describes the tree that `server\` is a copy of,
so once you have copied `server\` somewhere permanent — `C:\dosbridge` in its
examples — its paths and commands are the ones you want.

Four things it mentions are **not** in `server\`, because they exist only to
build an installer or to test the bridge itself:

| in the source tree | in this kit |
|---|---|
| `installer-src\` | not shipped. This kit is what it produces |
| `drvtest\` | not shipped — throwaway drivers for exercising `dosdrv` |
| `dos\` | not shipped; its runtime files are in `client\` instead |
| `starter\` | sources only. The built `.EXE` and `.COM` tools are in `client\`, and `INSTALL.BAT` copies them to `C:\TOOLS` on the DOS machine |

---

## What you need

**On Windows 11:** Python 3.8+. Nothing else, no pip installs.

**On the DOS machine:**

| | |
|---|---|
| `NE2000.COM` or `PM2000.COM` | a packet driver for your card. **The only network software needed.** |
| `DEVLOAD.COM` | only for `dosdrv`; freeware, not part of DOS 6.22 |
| `REBOOT.COM`, `COLDBOOT.COM` | in `dos/`, 16 bytes each, included here |
| `CHOICE.COM` | ships with DOS 6.22, used as a sleep |

**mTCP is not required.** It used to be: `HTGET.EXE` fetched jobs and `NC.EXE`
returned results. Both are gone -- the bridge now speaks IPv4, UDP and TFTP
directly to the packet driver (`starter/net.pas`, `starter/tftp.pas`), and the
last mTCP call of any kind went on 2026-09-02. If you happen to have mTCP its
tools are handy for diagnosis, and `C:\AI\NET.CFG` deliberately uses the same
key names as `MTCP.CFG`, but nothing here will ask for it.

Note the packet driver is a different thing and **is** still required: it is
the driver for the network card, not part of mTCP.

---

## Setup

> **You already have the built installer: it is this folder.** Inside
> `server\`, `check.cmd` reports what is missing without changing
> anything, and `install.cmd` does the PATH and firewall work. The
> rest of this section is the same thing by hand, and is worth reading
> once -- it is what those two scripts actually do.

**1. Windows side.** Put this folder anywhere, e.g. `C:\dosbridge`. Add it to
your PATH so Claude Code can call `dosrun` directly. Start the daemon in its own
window and leave it running:

```
C:\dosbridge> dosd.cmd
[10:14:02] dosd listening: http :8080   results :8081   pull :8082
[10:14:02] waiting for the DOS box to poll /job ...
```

**2. Firewall.** This is the step that eats an afternoon if you skip it. Set
the WiFi profile to **Private**, then, in an admin PowerShell:

```powershell
New-NetFirewallRule -DisplayName "dosbridge" -Direction Inbound `
  -Protocol TCP -LocalPort 8080,8081,8082 -Action Allow -Profile Private
New-NetFirewallRule -DisplayName "dosbridge-tftp" -Direction Inbound `
  -Protocol UDP -LocalPort 8069 -Action Allow -Profile Private
```

**The UDP rule is the one that matters.** Every job poll, every file fetch and
every result now travels over TFTP on UDP 8069; the TCP ports are the legacy
path, kept so a box running an older agent still works. Open only the TCP ports
and the box will boot, show a healthy banner, and never poll -- which looks
exactly like a hung machine.

The built installer's `install.cmd` adds both rules for you.

**3. Addresses.** Fill in your own: this PC's LAN address wherever the DOS
agent names the server, and a free address on the same subnet for the DOS
machine. The DOS side reads them from `C:\AI\NET.CFG`, which uses the same key
names as an mTCP config, so an existing `MTCP.CFG` can simply be copied over it.

**Use a static address.** Reserve it in your router by MAC, or exclude it from
the DHCP pool, so nothing else takes it -- see the DHCP note under "Things that
will bite you" for why a lease is worse than it sounds.

The client half of the built installer writes `NET.CFG` for you, with this PC's
address auto-detected at build time.

**4. DOS side.** Create `C:\AI` (the agent loop), `C:\AGENT` (bridge state),
`C:\TOOLS` (tools, put it on PATH) and `C:\WORK` (per-job scratch). Copy in
`dos/REBOOT.COM`, `dos/COLDBOOT.COM`, the built tools from `starter/build`, and
`dos/AUTOEXEC.BAT`. Edit the top of `AUTOEXEC.BAT`:

```
SET SRV=10.0.0.5:8080         <- put YOUR Windows box's LAN address here
SET UPHOST=10.0.0.5           <- the same address, without the port
...
NE2000.COM 0x60 3 0x300       <- match your PicoMEM IRQ/port
```

> **The files at the top of `dos/` are templates for a fresh install, not a
> mirror of any running machine.** They assume `NE2000.COM` and a self-contained
> `AUTOEXEC.BAT`; a box with a different packet driver, or one already running
> the agent from `C:\AI\AI.BAT`, needs its own. Copying a template over a
> working `AUTOEXEC.BAT` is the fastest way to take a box off the network, and
> that is not recoverable from this end.
>
> `dos/live/` holds byte-verified copies of whatever the development box was
> actually running, and `dos/README.md` explains the difference. Read them as
> one worked example, not as a target to match.

Reboot. You should see `dosd` log `waiting...` turn into steady polling.

```
C:\dosbridge> dosctl status
DOS box: alive, polled 0.4s ago
```

---

## Using it

```
dosrun build\PROG.EXE                 push, run, capture, return errorlevel
dosrun build\PROG.EXE -v --loop 5     args after the exe pass through
dosrun PROG.EXE --timeout 300         for slow tests
dospush FONT.DAT DATA.BIN             stage on the Windows side only
dosdeploy FONT.DAT C:\WORK            copy onto the DOS box, verified
dospull C:\AI\AI.BAT                  copy a file back, byte-exact
dospull C:\WORK\PROG.EXE --out saved.exe ...to a chosen local path
dosexec "MEM /C" "DIR C:\WORK"        arbitrary DOS commands
dosdrv build\NEWDRV.SYS /i:3          stage a driver, reboot, report
dosdrv build\NEWDRV.SYS --device MYDEV fail unless MYDEV registers
dosreboot [--cold]                    reboot and wait for it to come back
dosrun/dosexec --quiet                do not echo output on the DOS console
dosctl status                         is it alive?
dosctl stop                           stop the agent loop (one-way, see below)
dosctl shutdown                       stop dosd itself (this machine only)
dospower [status|on|off|cycle]        smart plug, if one is configured
```

Seeing and driving the machine -- all optional, all detailed below:

```
doscap live                           watch the real screen, with sound
doscap shot [FILE]                    one still
doscap rec SECS [--audio] [--shots N] record it
KINJ  file.KI                         replay a keystroke script into a program
KNET  [port]                          type at the box live, over the network
```

Starting something new, and keeping the DOS side current:

```
dosnew mandel                         scaffold projects\mandel\
dosctl clean [--all]                  delete regenerable build junk
dosctl upgrade --dry-run              what would change on the DOS box
dosctl upgrade                        send new tools + agent, then reboot
dosctl version                        what build the DOS machine is running
dosctl verify                         CRC-32 every tool on the box
makeinst.cmd                          build the installer (into ..Installer\)
```

Your own work goes in `projects\NAME\`, never in `starter\` (reserved for the
bridge's own tools) and never in the built installer tree (overwritten
wholesale). Staging is namespaced per project, so two projects can both build a
`HELLO.EXE` without one silently clobbering the other.

`dospush` stages a file into `files/` so the DOS box *can* fetch it; it does
not put anything on the box. `dosdeploy` does the whole job — stage, fetch it
down with `UGET`, confirm it arrived, and then **check it by CRC-32**. Size
alone would accept a transfer that arrived truncated to exactly the right
length, which is not hypothetical: it has happened here.

`dospull` is binary-exact and is the only correct way to get a file back. It
travels over the same TFTP transport, which is a block protocol with a byte
count, so there is no text mode to get wrong. Do not substitute
`dosexec "TYPE ..."` for it on anything but text — see the file-transfer note
below.

Both directions negotiate 1400-byte blocks (RFC 2348) and both resume from a
byte offset if a transfer stalls, so multi-megabyte files move reliably. Raise
`--timeout` for those: it does not scale with file size.

A typical Claude Code loop then looks like:

```
fpc -Tmsdos -WmLarge prog.pas  &&  dosrun prog.exe
```

See `starter/README.md` for the cross-compiler setup and `drvtest/README.md`
for testing driver deployment.

Claude reads the compiler errors, fixes them, reads the DOS machine's output,
iterates.
You don't touch the DOS machine.

---

## Seeing the screen: `doscap`

Optional, off unless configured, and the first thing here that does not look
at the DOS box **through DOS**.

Everything else in this bridge is the machine reporting on itself. `WriteLn`
goes through captured stdout, `SCRAPE` reads the text buffer back, `VSHOT`
reads mode 13h back. All of that can only show what somebody wrote code to
show, and only while the box is still running.

A USB capture card sees what a monitor sees: POST, a BIOS prompt, whichever
way the video card lost its boot lottery, a frozen screen with the last line
still on it, and every graphical demo as it actually renders.

It earned its keep immediately. `dosctl status` said:

```
DOS box: STALE, last poll 2518s ago (hung? powered off?)
```

and it cannot do better, because the thing that would have to answer is the
thing that is not running. One frame showed the box sitting in **MS-DOS EDIT
with a dialog open** -- somebody had been at the keyboard. Not hung, not off,
and a power cycle would have been exactly the wrong response.

```
doscap devices                what capture hardware this PC has
doscap modes                  what the configured device can produce
doscap status                 device present? is a picture arriving?
doscap live [--mute]          live preview window, with sound (q to quit)
doscap shot [FILE]            one still
doscap rec SECS [FILE]        record. --audio, --shots N
doscap burst N [--every S]    a series of stills
doscap still REC SECS [FILE]  pull a frame out of a recording
```

**Setup.** You need `ffmpeg` (`winget install Gyan.FFmpeg`), then copy
`capture.example.json` to `capture.json` and set the device name that
`doscap devices` prints. Configuration is required rather than auto-detected
because the DirectShow device name belongs to one machine -- a shipped default
would be wrong everywhere else. `capture.json` is gitignored and never ships,
the same rule as `power.json`.

Verified here at **1600x1200 yuyv422 60 fps, 4:3** on a MacroSilicon-class
HDMI stick. Four things measured rather than assumed:

* **The device is exclusive.** A second capture fails promptly with "already
  in use" -- cleanly, not as a hang. So `rec --shots N` records first and
  extracts the stills from the finished file afterwards.
* **`rtbufsize` is a correctness setting, not a tuning knob.** ffmpeg's
  default real-time buffer is about 3 MB and one 1600x1200 frame is 3.84 MB --
  less than a single frame -- so it drops frames before it has a whole one.
* **x264 `ultrafast` keeps up and `veryfast` does not.** Over 8 seconds:
  ultrafast gave 481 frames, zero drops, 3.1 MB. MJPEG stream-copy drops
  nothing either and is 80 MB for the same clip.
* **A recording survives a DOS video mode change.** Text to unchained mode X
  and back: 2701 frames in 45.016 s, exactly 60 fps, zero drops. The switch
  costs about a second of black while the converter re-syncs, and `doscap`
  reports such a frame as `blank` rather than pretending it is a picture.

**Sound comes too, but only from the sound card.** `rec --audio` and
`doscap live` take the HDMI audio. Measured: `MOZART` on the PC speaker reads
0.5 dB from silence -- a buzzer soldered to the motherboard has no path into
the converter -- while `RAYCAST`'s AdLib sits 37 dB above the noise floor and
plays back cleanly. OPL2 music is checkable from another machine for the first
time; the PC speaker is not.

**Two limits worth stating.** It is a *second opinion, not a replacement*:
`SCRAPE` and `VSHOT` give exact framebuffer bytes, this gives photons after a
converter has scaled them, so do not CRC a captured frame. And it is *not a
frame-rate instrument* -- the box's text and mode 13h output is 70 Hz and the
capture is 60 Hz, so a recording duplicates and drops frames by construction.

Full write-up, including the live-preview clock-sync trap that makes audio
choppy if you get it wrong, is in **`capture.md`**.

---

## Typing at the machine: `KINJ` and `KNET`

DOS is single-tasking and **not reentrant**. While your program runs, nothing
else on the box does, and an interrupt handler cannot call DOS to read a file
or a socket. That one fact shapes both of these tools.

### `KINJ` -- a scripted keystroke injector

The script is compiled on Windows and loaded into resident memory *before* the
target starts, because the handler cannot read a file later. It hooks **INT
16h**, so a key is manufactured at the moment the program asks for one: no
timing to get right, no 15-entry BIOS buffer ceiling, and no race with the
target draining it.

```
python mkkeys.py session.txt > SESSION.KI      compile a readable script
dosdeploy SESSION.KI C:\WORK
dosexec "C:\TOOLS\KINJ.COM C:\WORK\SESSION.KI" "SOMEPROG" ^
        "C:\TOOLS\KINJ.COM /D" "C:\TOOLS\KINJ.COM /U"
```

A script is plain text -- `PAUSE`, `DELAY`, `TEXT`, `KEY`, `SNAP`, `END`.
`SNAP` photographs the screen the next time the program asks for a key, which
is exactly the moment worth capturing: it has finished drawing and is waiting.
`/D` prints those grabs, `/S` reports, `/U` unloads.

Proven with an exit code rather than an eyeball: `CHOICE /C:AB` driven by an
injected `B` returned **errorlevel 2**. It has also typed a 343-keystroke
story into MS-DOS EDIT and saved it to disk.

### `KNET` -- a live remote keyboard over the network

Same INT 16h delivery, but nothing is scripted: you type on Windows and the
keys arrive while the program is already waiting for them.

```
# 1 -- watch the screen
doscap live

# 2 -- load KNET *and the target* in ONE job
dosexec "C:\TOOLS\KNET.COM" "EDIT C:\WORK\STORY.TXT" "C:\TOOLS\KNET.COM /U"

# 3 -- type at it.  Ctrl-] to stop.
python starter\sendkeys.py 192.168.1.255
```

The way in is the **packet driver**: it is callable at interrupt time and
needs no DOS at all, so a receiver of ours can queue a keystroke without
touching DOS. Plain UDP rather than a private ethertype, because raw layer-2
sending from Windows would mean installing a capture driver and a UDP socket
needs nothing at all.

Three things that will bite:

* **Use the broadcast address**, not the box's own. Nothing on the box answers
  ARP while KNET holds the IP handle, so Windows stops delivering unicast.
  Measured in one 15-second run: **0 frames unicast, 23 broadcast**. Everyone
  on the segment sees the keystrokes -- do not type a password through it.
* **Do not load KNET as the last thing a job does.** It holds ethertype 0800,
  so `UGET` cannot get a handle and the box cannot poll --
  `access_type refused ... driver error 10`, a healthy machine that is
  completely unreachable. Load it and the target in the same job.
* **`/T` first, always.** It acquires, listens, reports and releases in one
  run and never goes resident, and it counts frames at each stage of the parse
  so a failure is diagnosable. The dangerous thing here is a far pointer the
  driver calls at interrupt time; prove it before anything stays in memory.

Because relying on `/U` being reached is not good enough, **KNET gives the
handle back on its own** after 120 idle seconds (`/W<secs>`; the timer resets
on every keystroke). Verified by causing the fault deliberately and then
walking away: recovered on its own in about 6 seconds.

`sendkeys.py` reads console *events* rather than characters, so Alt- and
Ctrl-combinations work; `--show` prints what each key would send without
sending anything, which separates a mapping problem from a delivery one.

### What neither one can drive

Both serve **INT 16h**, so a program that reads the keyboard at INT 9 never
sees any of it. That is most games, and it is `EDIT.COM`'s menus -- typing
into the editor works completely, `Alt+F` then `x` does nothing. Reaching
those means 8042 command `D2h`, which is written up and untried.

Full write-up in **`knet.md`**; `starter/session.txt` and `starter/story.txt`
are worked KINJ scripts.

---

## How driver testing survives a hang

`dosdrv` never writes to `CONFIG.SYS`. That's deliberate: a bad `CONFIG.SYS`
hangs the machine *before* `AUTOEXEC.BAT` runs, so no software on the box can
undo it, and power-cycling just re-runs the same bad config. You'd need hands.

Instead the driver is staged into `PEND.BAT` and loaded via `DEVLOAD` from
`AUTOEXEC.BAT`, **after** the network is already up, behind a flag file:

```
boot ──> packet driver + agent ──> TRYING.FLG present?
                             yes ──> last boot hung. Report it, delete the
                                     staged driver, carry on. Self-healed.
                             no  ──> create flag, DEVLOAD driver, delete flag,
                                     report success + MEM /C output.
```

So a wedged driver costs you one power cycle and reports itself. Nothing is
ever left in a state that won't boot.

**A driver that fails *quietly* is the harder case**, and the crash guard says
nothing about it — surviving the boot is not the same as loading. Pass
`--device NAME` and the staged `PEND.BAT` checks whether the driver actually
registered, emitting `##DEVFAIL` if not, which `dosctl` turns into a non-zero
exit. DEVLOAD's own output is captured to `C:\AGENT\DRVOUT.TXT` and folded into the
report; without that it goes to a screen nobody is watching. This is why
`PEND.BAT` is served over HTTP instead of being built with `ECHO` on the DOS
side: COMMAND.COM has no way to escape a `>` inside an `ECHO`, so an ECHO-built
`PEND.BAT` could never redirect anything.

For a driver that genuinely must live in `CONFIG.SYS`, don't automate it.
Boot from a PicoMEM floppy image with a known-good minimal config and keep the
test surface on the hard disk.

---

## Things that will bite you

**Direct video writes vanish.** `> C:\WORK\OUT.TXT` only captures output that goes
through DOS. Anything writing straight to B800 produces an empty log. Have your
test harnesses print deliberately to stdout.

**A DHCP lease is a time bomb.** `DHCP.EXE` is one-shot — it stamps `IPADDR`,
`TIMESTAMP` and `LEASE_TIME` into `MTCP.CFG` and exits, and nothing renews it.
When the lease expires every mTCP tool refuses to run and the box goes silent.
It cannot recover on its own either: the agent loop retries the poll forever
but never re-runs `DHCP`, so it sits retrying the one thing that cannot work
and you end up walking to the machine. The trap is the shape, not the tool — a
retry loop around the one operation the failure has disabled.

Use a static address. `C:\AI\NET.CFG` is where the bridge reads it, and the
installer writes it for you.

Easy to misdiagnose, too: from the CLI this looks exactly like `dosd` having
died. Check `netstat` for listeners on 8080/8081/8082 before blaming the daemon.

**Errorlevel is capped at 20.** DOS 6.22 can't read `ERRORLEVEL` into a
variable, so the generated batch ladders `IF ERRORLEVEL n` from 1 to 20. Return
small codes. (Raise `MAX_ERRORLEVEL` in `dosd.py` if you must; it costs a line
of batch each.)

**8.3 names.** `dosctl` uppercases and rejects long names rather than letting
DOS silently truncate.

**Binary files need `dospull`.** `TYPE` stops dead at the first 0x1A (Ctrl-Z),
so `dosexec "TYPE PROG.EXE"` returns a truncated prefix that looks like a short
file rather than an error. `dospull` moves bytes over TFTP, which carries an
explicit length and has no text mode to get wrong.

This used to be the sharp edge here: the old path piped through `NC`, and
without its `-bin` flag it opened stdin in text mode and silently ate every
0x0D and 0x1A — a 27298-byte binary came back as 27258, corrupt but entirely
plausible-looking. That whole class of bug is gone with the pipe.

**Verify anything that matters.** `HD` on the DOS box produces a CRC-32 that
matches Python's `zlib.crc32`, so a transfer can be checked from either end
without moving it again. `dosdeploy` does this automatically and `dosctl verify`
does it for every tool on the box.

**`dosexec` exit codes are only as good as the last command.** DOS internal
commands (`ECHO`, `VER`, `DIR`, `IF`, `DEL`, `TYPE`) never set `ERRORLEVEL`, so
the ladder has nothing of its own to read. `dosd` works around this by running
a 5-byte `EXIT0.COM` immediately before your commands to force a known 0 — it
writes that file into `files/` at startup and the DOS box fetches it once into
`C:\AGENT\`. What this *cannot* fix: a failing internal command still reports 0,
because DOS never told anyone it failed. `DIR C:\NOSUCH` exits 0. Assert on
stdout for those; the exit code is trustworthy only when the last command is an
external program. If `dosexec` starts returning 20 for everything again,
`EXIT0.COM` isn't reaching the DOS box.

**A missing program used to report success.** `dosexec "C:\BAD.EXE"` returned
no output and rc 0: COMMAND.COM writes `Bad command or file name` to a console
DOS 6.22 cannot redirect, and a bad command leaves `ERRORLEVEL` alone — which
`EXIT0.COM` has just forced to 0. The generated batch now checks any command
that names a program by explicit path, and `dosctl` reports it and exits 127.

A bare name resolved through PATH still cannot be checked from the DOS side
(`IF EXIST` searches only the current directory, so testing one would report
every working tool as missing). For those, `dosctl` says that empty output with
rc 0 is also what a missing program looks like, and leaves the code alone.

**Reserve exit codes.** 253 = driver hung the machine, 254 = file download
failed, 127 = a command named a program that is not there, 124 = timed out
waiting for the DOS box.

**Only one `dosd` at a time, and a second one now says so.** Two instances ran
side by side for half an hour once, both bound to UDP 8069 because
`SO_REUSEADDR` was set on that socket -- UDP has no `TIME_WAIT`, so the option
bought nothing and only let the second bind succeed quietly. Each arriving
datagram then went to one daemon or the other at random, splitting
multi-datagram transfers between two of them: stalled deploys, failed CRCs,
results that never arrived. Every one of those reads as a fault on the DOS box
or on the wire. The option is gone, so a second instance is refused with errno
10048 instead of competing. TCP was never affected -- a connection belongs to
whichever listener accepts it.

**If a transfer stalls, suspect ARP before the wire.** The one bug that cost
the most here was the DOS box never answering an ARP request: the peer's cache
expired mid-transfer, the peer stopped sending, and it looked for weeks like a
link that dropped frames. `starter/net.pas` answers ARP now, and 10 MB moves
byte-exact. Two habits came out of it and both are worth keeping -- run mTCP as
a control, because it is a completely independent stack on the same card and
driver, so if it moves a large file cleanly the fault is ours; and do not trust
`arp -a`, which prints a `dynamic` entry for an address whose neighbour state is
`Unreachable`. The right hypothesis was raised and discarded months earlier
because the tool could not express the answer. `docs/network.md` has the whole
account.

**Read `dosd.log`, not the console.** `dosd` mirrors everything it prints to a
file beside `dosd.py`. The lines that say whether a batch was dispatched and
whether the box acknowledged it (`-> dispatch`, `acked` / `NO ACK`, `<- result`)
answer nearly every "is it the box or is it us?" question, and for a long time
they existed only in whichever window the daemon happened to be running in.
`DOSD_LOGFILE=` turns it off.

---

## Recovering a box you cannot reach

Optional, off by default, and it needs a smart plug. Every unrecoverable
failure here ends the same way -- "needs hands on the keyboard" -- because the
thing that would have to act is the thing that is not running. A switched plug
is the one lever left.

```
dospower                      state, power draw, and how many cycles are left
dospower on | off
dospower cycle [--force]      off, wait, on
dospower reset                forget the cycle history
```

Copy `power.example.json` to `power.json` and fill in your plug's model and
address. **No `power.json` ships with the installer**, and with no such file
every entry point reports "not configured" and no code can reach a relay. A kit
that arrived carrying somebody else's plug address, or that overwrote a working
local config on upgrade, would be worse than not having the feature.

**The guards are the feature, not the on/off.** A recovery that can loop is
worse than none: a box that will not come back for a reason power cannot fix --
a bad `AUTOEXEC.BAT`, a dead PSU, an unplugged aerial -- would otherwise be cut
every couple of minutes, forever, with nobody watching.

| | |
|---|---|
| `min_interval_secs` | refuse a second cycle too soon. `--force` overrides |
| `max_cycles` / `window_secs` | hard ceiling. `--force` does **not** override |

That asymmetry is deliberate. Being asked twice in a minute is impatience, and
a human typing `--force` settles it. Hitting the ceiling means power has
already failed to fix this several times, and the honest conclusion is that it
is not going to. Both limits are counted on disk, so they survive a `dosctl`
re-run in a loop.

With `"auto": true`, `dosreboot` and `dosctl upgrade` use it by themselves when
the box fails to come back.

**Read the power draw, not just the relay state.** `dospower` reports watts,
and that is the part worth having: it separates a machine that is *off* from
one that has power and has *hung*, and those need opposite responses.

Tested against a Shelly Plug (Gen2/3/4 RPC). Also written, but never run
against hardware: `shelly-gen1`, `tasmota`, `kasa`, `homeassistant`, and a
generic `http` driver you point at your own URLs. The untested ones say so the
first time you use them.

---

## Files

```
CLAUDE.md         project instructions for Claude Code -- read this first
docs/             the long-form reference: the tools, the hardware, the
                  graphics work, the raycaster, keyboard injection, the
                  network stack and the agent loop. One subject per file
installer-src/    authored installer scripts. `makeinst.cmd` turns these
                  plus the tree below into the installer folder beside this
                  one -- nothing generated is kept in here
projects/         your own work; one folder per project, made by `dosnew NAME`
starter/          FPC cross-compiler setup, test harness, worked examples.
                  Reserved for the bridge's own tools, not for new projects
drvtest/          throwaway drivers for exercising dosdrv's recovery path
dosd.py           the daemon: file serving, job queue, TFTP, result intake
dosd.log          everything dosd printed, mirrored to disk
dosctl.py         the CLI Claude Code drives
power.py          optional smart-plug support; power.example.json to enable it
capture.py        optional video capture off a USB capture card. Needs ffmpeg
                  and a capture.json; copy capture.example.json to enable it
capture.md        using the capture: live preview, stills, recording, sound
knet.md           using the live remote keyboard, and its hazards
dos*.cmd          Windows shims: dosrun, dospush, dosdeploy, dospull, dosexec,
                  dosdrv, dosreboot, dosd, dosshutdown, dospower, doscap
files/            what dosd serves over /f/ -- staged programs, plus the
                  EXIT0.COM it generates on first run
simulate_dos.py   fake DOS box for testing the plumbing without hardware
selftest.py       runs dosd + simulator + CLI end to end
dos/              files that live on the DOS box: templates at the top,
                  dos/live/ mirroring the real machine, dos/archive/ for
                  superseded versions, plus AUTOEXEC.proposed.bat
```

## Tools on the DOS machine

Built from `starter/` and deployed to `C:\TOOLS`. The full list and the traps
are in `CLAUDE.md`; the ones worth knowing about up front:

| | |
|---|---|
| `HWINFO` `SYSINFO` | CPU, coprocessor, BIOS, memory, ports, drives |
| `DSTAT` `DEVS` `MEMMAP` `IVT` `HD` | filesystem, device chain, memory map, vectors, hex dump |
| `SCRAPE` `VSHOT` | capture a text or graphics screen back through DOS |
| `VMODES` `VIDCHK` `VESACHK` | every video mode; `-t` sets each, `-d n` displays it |
| `FPU` `BENCH` `PROFTEST` | coprocessor tests, measured timings, profiling |
| `RAYCAST` `FRACTAL` `SCROLLER` | the demos: raycaster, Mandelbrot, mode X scroller |
| `PKTDRV` `PKTCAP` `ARP` | packet driver probe, frame capture, who-has and `/24` sweeps. `PKTCAP` takes the vector to attach to — give it one on a machine with two adapters, or it captures from the network the bridge runs over |
| `UGET` `UPUT` `NTP` | the bridge's own UDP transport, and what time a server thinks it is |
| `SERIAL` `MOUSE` `BEEP` | UART, INT 33h mouse, PC speaker |
| `ELAPSED` `KEYHIT` | job stopwatch, and the ScrollLock stop signal |
| `KINJ` `KNET` | keystroke injection: scripted, and live over the network |

Anything that draws to the screen is **invisible over the bridge** — video
writes bypass DOS. Run `SCRAPE` or `VSHOT` in the same job to get the screen
back as text.

Run `python selftest.py` to confirm the Windows half works before you touch
the DOS machine. Stop the daemon first (`dosctl shutdown`) — the test starts
its own on the same ports.

It drives a simulated DOS box that speaks the **real** transport: actual TFTP
against `dosd`, block numbering, ACKs and `blksize` negotiation. It moves a
file bigger than one block and compares it byte for byte on the way back,
because both directions treat a short block as "done" — so a sizing bug
produces a complete-looking file that is quietly wrong.

## If you are picking this up cold

`CLAUDE.md` is the real reference and is worth reading before changing
anything. The parts that cost the most to rediscover:

* **Exit codes must be <= 20**, filenames are 8.3, and a DOS critical error
  blocks forever and looks exactly like a hang.
* **Output must go through DOS.** `WriteLn` comes back; direct video writes do
  not.
* **Never write `CONFIG.SYS`, and do not deploy `AUTOEXEC.BAT` remotely.** Both
  run before the agent, so a bad one is unrecoverable without hands on the
  machine.
* **A job that reboots cannot report its result** — the machine is gone before
  the reply is sent. Use `dosreboot`, or `dosrun --reboot`.
* **Anything that opens a packet-driver handle must release it.** Exit without
  `release_type` and the driver calls into freed memory, which takes the box
  off the network entirely.
* **A resident tool left holding something is a hazard with a delay fuse.** A
  `KINJ` script that stops part way keeps handing keys to whoever asks next --
  including the agent loop, which then freezes minutes later for no visible
  reason. `KNET` holding the IP handle stops the box polling at all. Both
  report it in `/S`, and `KNET` releases itself after an idle timeout, but the
  rule stands: unload it in the same job that loaded it.

---

## Credits

Written by **StevenC** and **Claude** (Anthropic): StevenC guiding, deciding and testing on real hardware, Claude doing most of the analysis, code and measurement.

The tools on the DOS machine say so too: every one prints
`DOS Bridge tools -- StevenC & Claude` from the `About` unit.
