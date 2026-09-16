# KNET — a live remote keyboard for the DOS box

You type on Windows; the keystrokes go into whatever is already running on the
DOS machine, as though you had pressed them there.

`KINJ` replays a script loaded before the target starts. **KNET is live** —
keys arrive while the program is already waiting for them. Paired with
`doscap live` it is real remote control: see the screen, type into it.

Verified on hardware 2026-09-05. `CHOICE /C:AB` was left waiting on the box,
`B` was typed on Windows, and CHOICE echoed `B` and returned **errorlevel 2**
— its own report of what it received, not our echo of what we sent.

---

## Quick start

Three windows: one to watch, one to run the target, one to type in.

```
# 1 — watch the screen
doscap live

# 2 — load KNET, run something, unload it. ALL ONE JOB.
dosexec "C:\TOOLS\KNET.COM" "CHOICE /C:AB /T:A,30" "C:\TOOLS\KNET.COM /U"

# 3 — type at it. Ctrl-] to stop.
cd C:\dosbridge\starter
python sendkeys.py 192.168.1.255
```

**That is the broadcast address, not the box's own.** It is not a typo — see
below, it is the single most important thing on this page.

```
KNET /T          listen and report, NEVER resident   <- start here
KNET [port]      go resident (default UDP 8071)
KNET /W<secs>    idle seconds before the handle is released (default 120)
KNET /S          resident? counters
KNET /U          release the handle, unhook, unload
```

Windows side:

```
python sendkeys.py <bcast>                    interactive: type, it goes
python sendkeys.py <bcast> --show             ...print keys, send NOTHING
python sendkeys.py <bcast> --text "DIR C:\"   send a string once
python sendkeys.py <bcast> --test             a known A B C Enter burst
```

### If a key does nothing, use `--show` first

`--show` prints what each key *would* send and sends nothing, so a mapping
problem can be separated from a delivery problem without the DOS box being
involved at all:

```
  scan 21  ascii 00     Alt   -> 2100
  scan 1C  ascii 0D     -> 1C0D
```

If `--show` prints the right scan code and the box still does not react, the
problem is delivery (broadcast? is KNET resident? `KNET /S`) or the target
reads INT 9 rather than INT 16h.

### Alt and Ctrl work, and getting there mattered

The first version read the keyboard with `msvcrt.getch()` and **Alt
combinations could not be sent at all** -- the console never hands them to
`getch()` as characters, so `Alt-F` was silently unsendable, which makes a
remote keyboard useless for anything with a menu.

It reads console *events* now, via `ReadConsoleInput`, which carries the
modifier state explicitly instead of folding it into a character that does not
exist. That brings a second win: **Windows' `wVirtualScanCode` IS the PC set-1
scan code, the same number DOS reports through INT 16h**, so the word is built
from what the key actually is rather than translated through a table of
guesses. Arrows, function keys and Alt-letters all come out right with no
special cases -- verified against `mkkeys.ALT_LETTER`, e.g. `Alt-F` -> `2100`.

The console is put in raw mode while it runs, so `Ctrl-C` is forwarded to the
DOS box rather than killing the sender. **`Ctrl-]` is the way out.**

---

## Four things that will bite

### 1. Broadcast, always

Unicast to the box **silently delivers nothing**. Measured in one 15-second
run:

| | frames reaching our port |
|---|---|
| unicast to the box | **0** |
| broadcast | **23**, carrying 92 keys |

**Nothing on the box answers ARP while KNET holds the IP handle.** By then the
0806 handle is long released, so Windows cannot revalidate its cache and stops
delivering — the same mechanism `docs/agent.md`'s poll-hold section documents, seen
from the other side.

Broadcast needs no address resolution at all. That is also why the TSR carries
no gratuitous-ARP emitter: a whole block of interrupt-time code that would
otherwise have to exist and be correct.

**The cost: every host on the segment sees your keystrokes. Do not type a
password through it.**

### 2. Do not load KNET as the last thing a job does

This is the trap, and it is the obvious thing to try. While KNET is resident
it holds ethertype 0800, so `UGET` cannot get a handle and the box cannot
poll:

```
UGET: access_type refused for ethertype 0800, driver error 10
[offline] no reply from 192.168.1.10 - retrying, Q quits
```

The machine is perfectly healthy and completely unreachable.

**Load KNET and the target in the SAME job**, so the job is still running
while you type and reaches `/U` when the target exits:

```
dosexec "C:\TOOLS\KNET.COM" "EDIT C:\WORK\STORY.TXT" "C:\TOOLS\KNET.COM /U"
```

That is the pattern for interactive use: the target holds the job open, you
type at it, and quitting the target lets the job finish and unload.

### The watchdog: it un-strands itself

Relying on `/U` always being reached is not good enough, so KNET gives the
handle back on its own after **120 seconds with no keystroke** — `/W<secs>` to
change it, and the timer resets on every key, so typing keeps it alive.

Verified by causing the fault deliberately: KNET loaded with no `/U`, job
ended, network dead, then left alone.

```
RECOVERED ON ITS OWN after ~6s
```

`/S` says so afterwards:

```
KNET: resident on port 8071, frames 29 -- IDLE, handle given back (run /U to unload)
```

**It releases the handle but does NOT unhook itself, deliberately.** Restoring
the INT 16h vector needs `INT 21h`, and the watchdog can run from inside DOS —
COMMAND.COM polls the keyboard from its break check, which is itself inside an
`INT 21h`, and reentering DOS there is a crash. The packet-driver release
touches no DOS at all, so that half is safe and it is the half that matters:
the network comes back. The vector stays hooked and chaining, and about 2 KB
stays allocated until someone runs `/U` or reboots. A small leak beats a trip
to the machine.

**If the box is already stuck** it is not hung — the agent loop is running and
retrying. At the keyboard press **`Q`** (the offline branch offers it), then:

```
C:\TOOLS\KNET.COM /U
AI
```

### 3. Start with `/T` on anything new

```
dosexec "C:\TOOLS\KNET.COM /T"
# meanwhile, from starter\:
python sendkeys.py 192.168.1.255 --test
```

`/T` acquires the handle, listens for 15 seconds, reports, and releases — **in
one run, never going resident**. It also counts frames at each stage of the
parse:

```
KNET: frames seen  : 29
KNET: keys queued  : 92
KNET:   ethertype 0800: 29
KNET:   protocol UDP  : 29
KNET:   our port      : 23
KNET:   our magic     : 23
KNET: handle released, not resident
```

That breakdown is what turned "0 keys and no idea why" into "23 reach the port
on broadcast, 0 on unicast" in a single run. **Build the instrument before
trusting the null result.**

### 4. It cannot drive menus

KNET serves **INT 16h**, so it inherits KINJ's exact blind spot: a program
that reads the keyboard at INT 9 never sees any of this. `EDIT.COM` is the
worked example — typing into the document works completely, and `Alt+F` then
`x` does nothing.

A live keyboard does not change that, because the limitation is in what the
target *reads*, not in how the keys arrive. Reaching those programs means 8042
command **D2h**, which is still untried.

---

## How it works

The obstacle is that **DOS is single-tasking and not reentrant**. While your
target runs, nothing else on the box does, and an interrupt handler cannot
call DOS to read a socket — which is precisely why KINJ has to load its whole
script up front.

The one opening is the **packet driver**: it is callable at interrupt time and
needs no DOS at all.

```
you type on Windows
   → UDP broadcast on the wire
      → packet driver calls our receiver   (interrupt time, no DOS)
         → the key goes in a ring buffer
            → target calls INT 16h and gets it
```

The receiver touches nothing but our own memory: no INT 21h, no DOS buffers.
That is what makes it safe to run at interrupt time, and it is the reason
`/T` can print while still holding the handle — something `pktcap.pas`
forbids for its own receiver, which is not DOS-free.

### Why plain UDP rather than a private ethertype

A private ethertype (88B5, say) would leave IP untouched — but sending raw
layer-2 frames from Windows means installing a capture driver. An ordinary UDP
socket needs nothing at all.

The price is parsing Ethernet, IP and UDP headers by hand in assembler, and
holding ethertype 0800, which takes IP away from `UGET`/`UPUT`. That sounds
fatal and mostly is not: **while the target runs, the agent loop is blocked
running it**, so nothing else wants IP during a session anyway.

### The wire format

One UDP datagram, port 8071 by default:

```
'K' 'N' '0' '1'   magic
<count>           little-endian word
<key> ...         little-endian words, AH=scancode AL=ascii
```

A key word is exactly what `INT 16h AH=00h` returns, so the DOS side does no
translation — it copies the word into its ring and hands it over. All the
scancode knowledge lives in `sendkeys.py`, which imports the tables from
`mkkeys.py` rather than keeping a second copy. Same split as `mkwalk.py`: the
assembler does what must happen on the box, Python does what need not.

There is no retransmission. A dropped keystroke is one you press again, and a
retry protocol inside a resident interrupt handler is a lot of code that can
go wrong on the one machine where going wrong means driving to it.

### Two orderings that are load-bearing

* **Hook INT 16h only after `access_type` succeeds.** Otherwise a refused
  handle leaves us resident, hooked and useless — and unhooking is the part
  that needs us to still be there.
* **On unload: release, then unhook, then free.** Free first and the driver is
  left calling into a block DOS has already handed to the next program. That
  takes the network down, and the bridge runs over that network.

KNET **chains when its queue is empty**, so the real keyboard keeps working
throughout and somebody at the machine can always take over.

---

## When it goes wrong

| symptom | what it means |
|---|---|
| `/T` shows frames but `our port : 0` | you sent unicast. Use the broadcast address |
| `/T` shows `frames seen : 0` | nothing is reaching the box at all — wrong subnet, or the job had already finished |
| `our port` counts but `our magic : 0` | something else is on that port; change it with `KNET <port>` |
| `access_type refused` | something already holds ethertype 0800 |
| job times out and the box goes quiet | `/U` never ran. The box has no IP: `dospower cycle`, or hands |
| keys do nothing in a full-screen app | it reads INT 9, not INT 16h. See above |
| `KNET: already resident` | a previous run left it loaded. `KNET /U` |

---

## What is verified, and what is not

**Verified on hardware:**

* the interrupt-time receiver, IP/UDP parsing, magic check and ring buffer —
  92 keys queued in one `/T` run
* the broadcast-versus-unicast result, both directions, in the same run
* resident install, live delivery into `CHOICE`, `/S` counters, `/U` release
* that the job's result still comes back afterwards, which is itself the
  proof that `release_type` worked

**Verified at the keyboard:** interactive mode types into the box and works.
Alt-combinations did NOT before the `ReadConsoleInput` rewrite above -- that
was found by using it, not by testing it, which is the usual way.

**Not verified:** the less common keys. `--show` prints exactly what each one
would send, so checking any particular key costs nothing and needs no DOS box.
The numeric keypad and the grey/extended duplicates are the likeliest to
differ, since Windows and DOS disagree about a few of those scan codes.
