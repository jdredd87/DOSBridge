# Keyboard and mouse: driving the box from Windows

`KINJ` replays a script into an interactive program, `KNET` types into
one live. `knet.md` is KNET's full write-up.

Split out of `CLAUDE.md`, which keeps the summary and the pointer here.

## Driving an interactive program: `KINJ.COM`

**Built and verified on hardware 2026-09-05.** `starter/kinj.asm`, 1582 bytes,
with `starter/mkkeys.py` to compile scripts and `starter/session.txt` as a
worked example.

```
KINJ file.KI    load a script and go resident (reloads if already there)
KINJ /U         unhook and free
KINJ /D         print the captured screens as text
KINJ /S         resident? how many keys sent, how many screens grabbed
```

The proof is an exit code rather than an eyeball: `CHOICE /C:AB /N` was driven
with a script that answers `B`, and **`CHOICE` returned errorlevel 2** -- its
own report that B was chosen, not our echo of it.

### Why it has to be resident, and why the script is loaded up front

A job is a batch of commands run one after another, and **DOS is
single-tasking**: while the target runs, nothing else on the box does. So a
keystroke cannot be delivered by another program and a screen cannot be read
by one either -- there is no "meanwhile". The only code that runs during
somebody else's program is an interrupt handler.

**DOS is also not reentrant**, so the handler cannot open a file to read the
next keystroke or write a capture out. Both halves are solved the same way:
the script is read into resident memory at install time, while we are still
an ordinary program, and captures are buffered in resident memory and written
out by a later invocation. Nothing in the handler touches DOS at all.

### INT 16h, and why the obvious design is the wrong one

The natural injector hooks the timer and stuffs the BIOS keyboard buffer on a
schedule. **Hooking INT 16h is strictly better**: no timing to get right, no
15-entry ceiling, and no race with the target draining the buffer, because
the keystroke is manufactured at the moment it is asked for. It is also less
code -- a switch on the function number. 00h/10h consume a key, 01h/11h peek
without consuming, everything else chains.

Returning "no key" from a peek means clearing ZF **in the caller's flags on
the stack**, not in the live flags, which the IRET discards.

### Snapshots are taken when the program asks for a key

Which is exactly the moment worth photographing: it has finished drawing and
is waiting. No timer, no polling, nothing to race. `SNAP` fires at the next
INT 16h call, the handler copies the character plane out of B800 (or B000 --
the mode is read at the time rather than assumed), and `/D` prints it
afterwards. Six screens, characters only: an ASCII grab has no use for the
attribute plane.

**`SNAP` had to be made to obey `PAUSE`.** Without that it fired on the very
first poll after install, which is COMMAND.COM checking for Ctrl-C between
two batch commands -- so the photograph was of the batch file's own screen
rather than of the program the script was written to watch.

### Three things that will bite

* **Keys leak into COMMAND.COM.** Between two commands in a batch it polls
  the keyboard, and a key that has come due is handed over and executed as a
  command. Start every script with a `PAUSE` long enough to cover the gap,
  and load the TSR in the same job as the target, immediately before it.
* **A target that asks for more keys than the script holds will block the
  box.** Once the script is exhausted the handler chains to the real BIOS,
  which waits on a keyboard nobody is at -- and nothing polls while it does,
  so that is a needs-hands hang rather than a job timeout. End scripts with
  more keys than the program can possibly want.
* **Redirection can switch the prompt off entirely.** `MEM /P > NUL` does not
  page, so it never asks for a key and the script does nothing: measured, 0
  keys sent and 0 snapshots. A program that only prompts when writing to a
  console is not being tested at all when its output is redirected.

### Driving a full-screen editor: typing yes, menus no

Tried on 2026-09-05 against `EDIT.COM`, and the result splits cleanly.

**Typing works completely.** A 372-word script typed a whole short story into
MS-DOS EDIT -- **343 keystrokes, every one of them landed** -- and the file
was saved and read back off the disk afterwards. Escape dismissed the welcome
dialog and `Alt-F` opened the File menu, so INT 16h is being served properly
and even Alt-combinations arrive.

**Menu navigation does not.** Once the File menu is open, neither the
accelerator (`x` for Exit, either case) nor Down-arrow-then-Enter has any
effect: the menu just sits there highlighted on "New". Whatever EDIT reads
its menus with, it is not the INT 16h path this TSR hooks. One run did exit
cleanly on that same sequence, which was never reproduced -- treat it as
unexplained rather than as evidence the keys sometimes work.

So: KINJ can fill a text field or answer a prompt. It cannot navigate a
full-screen application's menus, and a script that assumes it can will strand
itself -- which is the far more serious problem:

### A STRANDED script is worse than an exhausted one

The note above says an exhausted script blocks the box. A script that stops
*part way* is worse, because it outlives the job that loaded it.

`/S` says `script finished` when the script ran to `END`. When it does not,
the TSR stays resident **with keys still pending**, and COMMAND.COM polls the
keyboard between every pair of batch commands -- including the agent loop's.
Observed: `343 key(s) sent` with no `script finished`, the job timed out, and
then **`AI.BAT` itself froze** and never picked up another job. It took
Ctrl-C and answering `N` at the keyboard to free it.

That is a hazard with a delay fuse: the job that created it has already gone,
and the machine stops polling some time later for no visible reason. Three
rules follow:

* **`KINJ /U` belongs in the same job as the target** -- and on a line the
  job will actually reach. Putting it after the target is not enough if the
  target can hang.
* **Prefer a target that cannot outlast the script**, the way every `CHOICE`
  in the demo carries `/T`. A timeout makes a missed key cost a default
  instead of the box.
* **Check `/S` for `script finished`.** It is the difference between a TSR
  that is done and one that is still holding keys for whoever asks next.

### What it cannot drive

**Anything that hooks INT 9 and reads key state itself never calls INT 16h**,
so it never sees any of this. That is most games, and it is `RAYCAST KEYS`.
Reaching those means the keyboard controller: 8042 command **D2h**, "write to
output buffer", presents a byte as though the keyboard had sent it and raises
IRQ1, so the real INT 9 chain runs on a scancode of your choosing. This box
has a genuine 8042 -- `SCRLOFF.COM` already drives it through ports 60h/64h
-- so it should work here. **Untried**, and not every clone implements D2h.

Buffer stuffing -- scancode/ASCII pairs into 0040:001E, tail advanced at
0040:001C -- still works and needs no resident code, but it holds 15 entries
and can only ever *pre-load* a program's input, never steer it while it runs.
`STUFFQ.COM` did exactly that when ScrollLock was being chosen over a
keypress.

### A live remote keyboard: `KNET.COM`

**Built and verified on hardware 2026-09-05.** `starter/knet.asm` (2276
bytes) with `starter/sendkeys.py` on the Windows side. **`knet.md` is the
full write-up** -- setup, the three-window pattern, the wire format and
troubleshooting; what follows is the part worth knowing without going there. Where `KINJ` replays a
script loaded up front, this delivers keys **as you press them**, into a
program that is already running.

```
KNET /T          listen and report, NEVER resident   <-- always start here
KNET [port]      go resident (default UDP 8071)
KNET /S          resident? counters
KNET /U          release the handle, unhook, unload
```

The proof is an exit code again: `CHOICE /C:AB` was left waiting on the box,
`B` was typed on Windows, and `CHOICE` echoed `B` and returned **errorlevel
2**. Paired with `doscap live` this is real remote control -- see the screen,
type into it.

### The packet driver is the only way in

DOS is single-tasking and not reentrant, so while the target runs nothing
else does and an interrupt handler cannot call DOS to read a socket -- which
is exactly why `KINJ` has to load its whole script before the target starts.
The one exception is the **packet driver**: it is callable at interrupt time
and needs no DOS at all. It calls our receiver for every matching frame, and
that receiver queues a keystroke touching nothing but our own memory. INT 16h
then hands the queue out.

### Plain UDP, not a private ethertype

A private ethertype (88B5, say) would leave IP untouched, but sending raw
layer-2 frames from Windows means installing a capture driver. Ordinary UDP
needs nothing at all, at the price of parsing IP and UDP headers by hand in
assembler and of **holding ethertype 0800**, which takes IP away from
`UGET`/`UPUT`.

That sounds fatal and mostly is not: while the target is running the agent
loop is **blocked running it**, so nothing else wants IP during a session.
The handle is held for the session and released before the job ends.

**The trap is loading KNET as the last thing a job does**, which is the
obvious way to try typing interactively. The handle is still held when the job
ends, so `UGET` cannot get one and the box cannot poll:

```
UGET: access_type refused for ethertype 0800, driver error 10
```

Healthy machine, completely unreachable. Load KNET **and the target in the
same job**, so the job is still running while you type and reaches `/U` when
the target exits.

**And it un-strands itself.** Relying on `/U` being reached is not good
enough, so after 120 idle seconds (`/W<secs>`; the timer resets on every key)
KNET gives the handle back by itself. Verified by causing the fault
deliberately and then leaving it alone: **recovered on its own in ~6
seconds**, no hands.

It releases but deliberately does **not** unhook: restoring the vector needs
`INT 21h` and the watchdog can run from inside DOS -- COMMAND.COM polls the
keyboard from its break check, itself inside an `INT 21h`. The packet-driver
release touches no DOS, so that half is safe and is the half that matters.
~2 KB stays allocated until `/U` or a reboot; a small leak beats a trip to
the machine.

### Keystrokes MUST be broadcast

Not a convenience -- measured, in a single 15-second run:

| | frames reaching our port |
|---|---|
| unicast to the box | **0** |
| broadcast | **23**, carrying 92 keys |

**Nothing on the box answers ARP while KNET holds the IP handle.** By then
the 0806 handle is long released, so Windows cannot revalidate its cache and
quietly stops delivering unicast -- the same mechanism the poll-hold section
above documents, seen from the other side.

Broadcast needs no resolution at all, which also means this TSR needs **no
gratuitous-ARP emitter**: a whole block of interrupt-time code that would
otherwise have to exist and be correct. The cost is that every host on the
segment sees the keystrokes. On a lab network that is a fair trade; do not
type a password through it.

### `/T` exists because the failure mode is a dead network

`access_type` hands the driver a **far pointer into our code** which it calls
at interrupt time. Exit without `release_type` and that pointer dangles into
memory DOS reuses, the next matching frame jumps into it, and the bridge runs
over that network.

So `/T` acquires, listens, reports and releases in **one run, never going
resident**. It also counts frames at each stage of the parse -- ethertype,
protocol, port, magic -- which is what turned "0 keys, no idea why" into "23
frames reach the port on broadcast and 0 on unicast" in a single run. Build
the instrument before trusting the null result; these notes have had to
relearn that repeatedly.

Two orderings are load-bearing:

* **Hook INT 16h only after `access_type` succeeds.** Otherwise a refused
  handle leaves us resident, hooked and useless -- and unhooking is the part
  that needs us to still be there.
* **On unload: release, then unhook, then free.** Free first and the driver
  is left calling into a block DOS has already handed to the next program.

### What it still cannot do

It serves **INT 16h**, so it inherits `KINJ`'s exact blind spot: a program
that reads the keyboard at INT 9 never sees any of it. That includes
`EDIT.COM`'s menus -- typing into the editor works and the menus do not, and
a live keyboard does not change that, because the limitation is in what the
target reads rather than in how the keys arrive. Reaching those still means
8042 command **D2h**, still untried.

Note also that `KNET` chains when its queue is empty, so the real keyboard
keeps working throughout and somebody standing at the machine can always take
over.

## Mouse injection: easier, and a different shape entirely

There is no queue to stuff. INT 33h is a **driver call interface**, so
faking it means hooking INT 33h and answering the functions an application
asks -- 03h (position and buttons), 0Bh (motion counters), 05h/06h (press
and release counts) -- chaining everything else. That is simpler than the
keyboard TSR, not harder: no ISR, no hardware port, no timing.

Two things worth knowing before trying it. **Moving the pointer needs no
hook at all** -- INT 33h function 04h sets the cursor position and any
ordinary program can call it; only the BUTTONS need interception. And an
application that installed an event handler with function 0Ch expects
callbacks, so a complete fake has to call that handler itself rather than
just answering polls.

On this box `CTMOUSE` owns COM1 in Mouse Systems mode -- and only after
`CTMOUSE /S1 /M /3`, since `AUTOEXEC.BAT` still carries the line that probes
wrong. A hook would sit above it and would not care.

## The mouse is a Mouse Systems device, not Microsoft

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
