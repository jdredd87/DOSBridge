# The tools on the DOS box, in detail

The listing lives in `CLAUDE.md`. This is the reasoning behind the
ones whose behaviour is not obvious from a one-line description.

Split out of `CLAUDE.md`, which keeps the summary and the pointer here.

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

`SCRAPE` and `VSHOT` exist to defeat the "output must go through DOS" rule in
`CLAUDE.md`. Anything drawing straight to video memory is invisible
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

## PIT channel 0 is in MODE 3, so sub-tick timing is ambiguous by half a tick

**Found on 2026-09-21 while chasing a frame-timing problem in
`starter/parallax.pas`.** `starter/prof.pas` gets its resolution by latching PIT
channel 0 and pairing the counter with the BIOS tick, and so did a stopwatch
written in that project. Both are wrong below about 30ms, and for the same
reason.

The BIOS programs channel 0 in **mode 3, square wave**. In that mode the
counter is decremented by two and reloaded when it reaches zero, so it sweeps
its whole range **twice per tick** -- once per half-cycle of the output. Reading
it tells you how far through a *half* tick you are and nothing about which
half. Every sub-tick reading is therefore ambiguous by up to **27.5ms**.

What that looks like in practice:

* The same unchanged band repaint measured **13.2ms** and then **24.4ms** on
  consecutive builds, bimodally, with nothing between.
* Per-frame figures never reconciled with their own mean -- 75% of frames
  "over budget" while the mean sat comfortably under it.
* `ProfReport`'s section percentages sum to about **140%** of its own elapsed
  time, which is the same error showing up as apparently overlapping sections.

**It does not affect long measurements.** The coprocessor-versus-integer race
in `starter/parallax.pas` runs for seconds, where 27.5ms is noise, and its
numbers are sound. The rule is: trust channel 0 over intervals much longer than
half a tick, and not at all over a frame.

Fixing it properly means a free-running counter of your own on **channel 2**,
gated through port 61h -- channel 2 drives the speaker, so it is free whenever
the sound is coming from an OPL2 rather than the beeper. That has not been
done. The frame timing that prompted this was settled off the capture card
instead, which has no such ambiguity: quarter the region, difference successive
frames, and look at whether all the quarters move together.

