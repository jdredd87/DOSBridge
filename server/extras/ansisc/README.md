# ANSISC -- ANSI.SYS, fast

*An optional DOS Bridge extra: it ships in the kit (`client\EXTRAS\ANSISC`)
and nothing installs it -- see `ANSISC.TXT`.*

**A drop-in replacement for MS-DOS 6.22's `ANSI.SYS` that draws text 3 to 4
times faster through DOS on the V30 (`TYPE`, `DIR`, anything written to the
console) -- 5 times in the driver alone, 27 times for a raw write request --
with the same result on the screen, character for character.**

Written by **StevenC** and **Claude** (Anthropic), September 2026: StevenC
guiding and testing on his V30, Claude doing the analysis, code, tests and
measurements.

> [!NOTE]
> ANSISC is built from **Microsoft's MS-DOS 4.0 source of `ANSI.SYS`**,
> which Microsoft published under the MIT licence
> (https://github.com/microsoft/MS-DOS), with the changes MS-DOS 6.22 made to
> it re-implemented, and new fast paths.  It is not Microsoft's MS-DOS 6.22
> `ANSI.SYS` and contains none of its code.  `ms40\LICENSE` is Microsoft's
> licence; our changes are under the same terms.

## Everything 6.22's ANSI.SYS does

It is the same driver, from Microsoft's own source, so it keeps all of it:
the escape sequences (cursor movement and positioning, save/restore, erase
display and line, colours and attributes, mode set and reset, line wrap,
the cursor position report), keyboard key reassignment, the extended
keyboard, `MODE CON` (the generic IOCTL: display mode get and set, 25, 43
and 50 rows, blink or intensity), the INT 2Fh interface (the installation
check programs use to find ANSI.SYS, the IOCTL through INT 2Fh, and the
DISPLAY.SYS handshake), the INT 10h hook that follows programs' mode sets,
graphics modes, pages, 40 columns.

MS-DOS 6.22 changed the 4.0 driver in places, and ANSISC does what **6.22**
does -- each found by comparing the two drivers' code and checked in the
emulator against the 6.22 binary:

| | 4.0 | 6.22 and ANSISC |
|---|---|---|
| switches | `/X /L /K` | also `/R`, `/S`, `/SCREENSIZE` |
| rows | what `MODE CON` last set | read from the BIOS on every request, so a program switching to 43/50 rows is followed |
| cursor down (`ESC[nB`) | could go one row off the screen | stops on the last row |
| cursor positioning | always on video page 0 | on the active page |
| scrolling | moved video memory itself, modes 2/3 | new line in the current colour, in every text mode including mono |
| `/R` | -- | scrolls through the BIOS, for screen readers |
| `/S`, `/SCREENSIZE` | -- | sets the BIOS row count to 25 at load, for BIOSes that leave it 0 |
| `/L` | keeps the row count across mode sets | accepted and ignored |
| waiting for a key | -- | tells a BIOS that supports it that the machine is idle (INT 15h 41h) |
| `MODE CON` | -- | 6.22's rewrite: intensity read from the VGA, DISPLAY.SYS consulted before a row change, VGA recognised by INT 10h 1Ah |
| DOS version | exactly 4.00 | ANSISC: 4.00 or later |

## Why it is faster

Every character 6.22's ANSI.SYS draws costs **two video BIOS calls**, one
to write the character and one to move the cursor -- and DOS sends almost
all console output to it a character at a time, through INT 29h.

ANSISC, in a text mode, on a video card that does not snow (EGA, VGA,
MCGA, monochrome):

* **INT 29h has a fast path**: a printable character with no escape
  sequence in progress, not in the last column, is written straight into
  video memory and the cursor moved -- BIOS data area and CRTC -- in about
  seventy instructions.  Everything else goes the full way.
* **A write request draws a whole run of characters in one loop** and
  moves the cursor once at the end: programs that write to CON in raw mode
  get the most from this.
* **Scrolling moves video memory directly**, with the same result as 6.22's
  BIOS scroll -- the new line in the current colour, and nothing scrolled
  when the cursor is not on the BIOS's bottom row, exactly as the BIOS
  behaves.
* **On a 186 or later, or an NEC V20/V30**, the general path saves and
  restores registers with `PUSHA`/`POPA`, patched in at load time; an
  8086/8088 keeps the original code.  One binary for every PC.
* A real **CGA** keeps the BIOS path: writing its memory directly snows.
  `/R` keeps the BIOS path too, so a screen reader sees every character.

### Measured on the V30

`ANSITEST` loads a driver into its own memory, runs it on the real screen
and puts everything back; the same script through both drivers gives the
same screen CRC (`E64DEEAF`) through both paths.

| characters per second | 6.22, low | **ANSISC, low** | 6.22, high | ANSISC, high |
|---|---|---|---|---|
| INT 29h, lines, scrolling | 1,658 | **5,217** | 1,294 | 3,114 |
| INT 29h, no scrolling | 1,826 | **9,743** | 1,359 | 4,059 |
| write request, scrolling | 1,899 | **50,960** | 1,386 | 21,249 |
| escape sequences | 3,324 | **10,238** | 2,069 | 3,722 |

**Load it low for speed.**  "High" is upper memory, which on this machine
is RAM on the PicoMEM card -- and code runs from there about **2.4 times
slower** than from the PC's own memory, because every instruction is
fetched over the 8-bit ISA bus.  Low costs ~4.9 KB of conventional memory.

Scrolling is now the limit: a scroll moves 3,840 bytes of video memory
across the ISA bus, about 7 ms a line on the V30.  The only faster way is
the video card's own start-address scrolling, which would move the screen
from where the BIOS and every program expect it.

## Using it

```
DEVICE=C:\DRIVERS\ANSISC.SYS            (fastest: conventional memory)
DEVICEHIGH=C:\DRIVERS\ANSISC.SYS        (saves ~4.9 KB, ~2.4x slower)
```

with the same switches as 6.22's: `/X`, `/K`, `/R`, `/S`, `/SCREENSIZE`,
`/L`.

## How it is proven

`test\emuansi.py` runs the **real binaries** -- 6.22's `ANSI.SYS` as the
reference and ANSISC -- in an 8086 emulator over a model PC whose BIOS
works on real video memory and the real BIOS data area, and compares the
screen (characters and attributes), the cursor in the BIOS and in the
CRTC, and the result of every operation, across:

* 6 video setups: VGA colour, VGA booted mono (the V30 does this), EGA
  colour, EGA mono (5151), CGA, MDA
* 8 switch sets: none, `/X`, `/K`, `/R`, `/S`, `/X /R`, `/L`, `/S /K`
* ~40 scenarios: text, wrapping, scrolling, control characters, every SGR
  code, cursor movement and clamping, erasing, save/restore, wrap on/off,
  bad and partial sequences, 80 parameters, the cursor position report,
  key reassignment (keys, strings, F-keys, grey keys, redefinition,
  deletion, many at once), extended keys, non-destructive read and flush,
  mono, 40 columns, 50 rows set behind the driver's back, video page 1,
  graphics modes 12h and 13h, modes set by escape and by programs through
  INT 10h, cursor shapes, `MODE CON` get and set with every error, INT 2Fh
* both output paths (INT 29h and the write request), and both code paths
  (8086, and 186/V20/V30)

-- about 7,700 comparisons.  Result: see "Status".

`ANSITEST.EXE` does the same on the real machine and screen.

## Building

```
build.cmd          src\  -> build\ANSISC.SYS
build.cmd ms40     ms40\ -> build\ANSI40.SYS   (Microsoft's 4.0, unchanged)
```

A build lands in `build\`, which is not shipped.  To release one, test it
(`test\emuansi.py ANSI622.SYS build\ANSISC.SYS`, then `ANSITEST` on the
machine) and copy it into `bin\`: the DOS Bridge kit ships `bin\` as it is.

MASM 5.1, LINK and the message tools from Microsoft's MS-DOS 4.0 release,
running on the DOS machine over DOSBridge.  `stage.py` packs the tree
(Microsoft's repository stores LF; the tools want CRLF).

## Files

| | |
|---|---|
| `ms40\` | Microsoft's MS-DOS 4.0 `ANSI.SYS` source, the includes and tools it needs, unchanged, with Microsoft's `LICENSE` |
| `src\` | ANSISC: `ANSI.ASM`, `ANSIINIT.ASM`, `PARSER.ASM`, `MSGSERV.ASM` changed (each change marked `SC:` or `6.22:`), `IOCTL.ASM` rewritten |
| `test\emuansi.py` | the emulator comparison |
| `ansitest.pas` | `ANSITEST.EXE`: drivers on the real screen, CRC and speed |
| `ansibnch.pas` | `ANSIBNCH.EXE`: the installed console's speed, through DOS |
| `bin\` | the released binaries: `ANSISC.SYS`, `ANSITEST.EXE`, `ANSIBNCH.EXE` -- what the DOS Bridge kit ships in `client\EXTRAS\ANSISC\` |
| `ANSISC.TXT` | the instructions that ship beside them, for reading on the DOS machine |
| `ANSI622.SYS` | not included -- it is Microsoft's.  To run the emulator test, copy `C:\DOS\ANSI.SYS` from a 6.22 machine here under that name (`dospull C:\DOS\ANSI.SYS --out ANSI622.SYS`); `.gitignore` keeps it out of the repository and the kit |

## Status

**Installed on the V30, 2026-09-27**, loaded low
(`device=c:\drivers\ansisc.sys`, CRC `E9BE86B7`; 6.22's line kept as a
`REM`, the previous `CONFIG.SYS` is `C:\CONFIG.SC2`).

* **Emulator: 7,296 comparisons against the 6.22 binary, 0 differences, 0
  errors** -- every hardware setup, switch set, scenario, output path and
  CPU path above.
* **Hardware: the same screen CRC as 6.22** through INT 29h and the write
  request (`ANSITEST`), on the V30.
* **Installed, through DOS** (`ANSIBNCH`, the real console, against the
  morning's baseline with 6.22's `ANSI.SYS` loaded high):

| characters per second | 6.22 (high) | ANSISC (low) | |
|---|---|---|---|
| CON handle, lines, scrolling -- what TYPE and DIR do | 1,213 | **3,831** | **3.2x** |
| CON handle, no scrolling | 1,296 | **5,519** | **4.3x** |
| INT 29h | 1,253 | **4,812** | **3.8x** |
| escape sequences | 1,811 | **4,653** | 2.6x |
| DOS function 02h | 970 | 970 | same |

  Function 02h does not move because DOS checks the keyboard for Ctrl-C
  before every character it sends that way; that, not the drawing, is its
  limit.
* `MEM /C`: ANSISC 4,928 bytes conventional; free conventional 581,408.
