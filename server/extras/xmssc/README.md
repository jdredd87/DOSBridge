# XMSSC -- XMS for PCs with no extended memory

*An optional DOS Bridge extra: it ships in the kit (`client\EXTRAS\XMSSC`)
and nothing installs it -- see `XMSSC.TXT`.*

**An XMS 3.0 driver for the 8088, 8086, V20, V30 and anything else with no
memory above 1 MB, built on the expanded memory an EMS board provides --
and on a PicoMEM, which is an EMS board too, it drives the card's page
registers itself: small moves 22% faster than the EMS driver's own move
function, 57% faster than going through the EMS driver.**

Written by **StevenC** and **Claude** (Anthropic), September 2026: StevenC
set the goal and the constraints, Claude did the design, the code, the
tests and the measurements on StevenC's V30.  Public domain (the
Unlicense).

> [!NOTE]
> XMSSC is a new driver, written from the XMS 2.0 and 3.0 and EMS 3.2 and
> 4.0 specifications.  The idea -- XMS served out of EMS -- is not new:
> Mateusz Viste's EXMS86 (https://mateusz.fr/exms86/, MIT) does it too, as
> XMS 2.0 over EMS 3.2.  Only that page's description was read; none of
> EXMS86's source was looked at, and none of its code is here.

## Why

Plenty of DOS software uses XMS when it is there -- for buffers, caches,
swapping, RAM disks -- and on an 8086 there never is: XMS manages memory
above 1 MB, and an 8086 has none.  But it may well have megabytes of
expanded memory on an EMS board, or on a PicoMEM, sitting unused by
anything that only knows XMS.  XMSSC hands that memory out through the XMS
interface.  **PKZIP 2.04g on the V30**, with EMS switched off in PKZIP
(`-+`), printed `XMS version 3.00 detected`, compressed 259 KB through
XMSSC's memory, and `PKUNZIP -t` passed every file.

## Loading it

After the EMS driver, either way:

```
DEVICE=C:\DRIVERS\XMSSC.SYS           in CONFIG.SYS, after the EMS driver

XMSSC                                 or as a TSR, from AUTOEXEC.BAT or a prompt
XMSSC /U                              ...and out again (if no block is allocated)
```

| switch | |
|---|---|
| `/V:2` | report XMS 2.00 rather than 3.00, for a program that is fussy about it |
| `/H:n` | `n` handles, 1-128 (32) |
| `/I:n` | PicoMEM: let interrupts in every `n` KB of a move, 1-8 (4) -- see "Interrupts" |
| `/G` | use EMS calls even on a PicoMEM |
| `/Q` | say nothing when loading |
| `/C:n` | treat the CPU as 0 8086, 1 186/V30, 2 286, 3 386 -- for testing |

```
XMSSC 1.0 -- XMS on expanded memory -- StevenC & Claude
  UMB calls go on to the UMB server already loaded.
  PicoMEM direct: port 2A8h, page frame E000h, EMS 4.0
  4080 KB free, 32 handles, NEC V20/V30, XMS 3.00
```

**3,696 bytes resident** as `XMSSC.SYS` on the V30 (`MEM /C`), about the
same as the TSR (32 handles, PicoMEM direct); 256 bytes less with `/G`,
which needs no table of the card's page numbers.  Load it low: code runs ~2.4x slower out of the
PicoMEM's upper memory (`docs/hardware.md`), and a move is mostly the
driver's own code.

It coexists with **UMBSC** (`extras/umbsc`) and anything else that answers
XMS only for upper memory blocks: XMSSC finds it at load, and passes the
UMB calls (10h-12h) on to it.  A real XMS driver already loaded makes
XMSSC refuse, as does a second copy of itself.  `/U` also refuses to unload
a *different build* of XMSSC: it would be reading that build's variables at
its own offsets.

## What it answers

| | |
|---|---|
| 00h version | 3.00 (`/V:2`: 2.00), revision 1.00, no HMA |
| 01h, 02h HMA | 90h: there is no HMA on an 8086 |
| 03h-07h A20 | the truth: an 8086 or 186 has no A20 line and always wraps at 1 MB, so enable is 82h, disable succeeds, query says off.  On a 286 or later, the wrap is tested |
| 08h free | the EMS driver's free pages, in KB |
| 09h, 0Ah, 0Fh | allocate, free, reallocate: each block is an EMS handle, sizes to the KB, pages to the 16 KB |
| 0Bh move | all of it -- conventional memory, blocks, both ways, overlapping either way (it copies from the top when it must), odd offsets, across pages, lengths to 4 GB |
| 0Ch lock | ADh: a block in EMS has no linear address to hand out |
| 0Dh, 0Eh | unlock (AAh), handle information |
| 10h-12h UMB | passed to the UMB server loaded before it; 80h if none |
| 88h 89h 8Eh 8Fh | the XMS 3.0 32-bit calls, on a 386 or later; 80h below that, where no program can make them |

Zero-size blocks, reallocating to and from zero, the error codes for a bad
handle, offset or length on either side of a move, running out of memory
(A0h) and of handles (A1h) -- all as the specification says, and all
checked (below).

## How it works

A block is an EMS handle.  A move maps a block's page into a window of the
64 KB EMS page frame and copies it with `REP MOVSW`; a move that crosses a
16 KB page boundary does it a slice at a time.  The page map a program has
set is always put back, a conventional address *inside* the frame reads
through whatever that program has mapped there, and the window a move
borrows is one that address does not touch.

There are two ways to change a window, chosen when it loads:

**PicoMEM direct.**  A PicoMEM's four EMS page registers are I/O ports
(`INT 13h AX=6001h` says where: 2A8h on the V30) and they **read back**.
XMSSC checks that at load -- it maps a page of its own through the EMS
driver, reads the register, and checks that writing that number to another
window shows the same memory, both ways -- and only then uses them.  When
it allocates a block it learns the card's number for each of its pages the
same way, inside a saved page map; after that a move is four `IN`s and
`OUT`s and a copy, with no call to the EMS driver at all.  The registers go
back to exactly the values read, so the EMS driver's own record of the
frame is never wrong.

**EMS calls** (`/G`, and any EMS board that is not a PicoMEM): the page map
saved with 4Eh on the caller's stack, pages mapped with 44h, the map put
back after every slice.  It needs only EMS 3.2 (EMS 3.2 has no reallocate,
so there a block grows by being copied to a new handle), and it is safe to
call from an interrupt routine.

**One 57h a slice, on EMS 4.0, was built, measured and taken out**
(2026-09-28).  The idea was one EMS call per slice instead of a map, a
save and a restore.  On the V30 it was *slower* -- 579 512-byte moves a
second against 625, 624 KB/s against 688 at 16 KB -- because PMEMMSC's 57h
costs more than the three calls it replaces; and PMEMMSC is the Lo-tech
board's LTEMM underneath, so that board would very likely see the same.
It was written to be safe on old EMS drivers (never a 57h across a 16 KB
page, where LTEMM's corrupted data; never for overlaps or conventional
memory in the frame), and the emulator's EMS 4.0 model keeps a 57h for
whoever tries again -- the test now checks XMSSC makes none.

### The fast path

Most moves are the same shape: one side conventional memory, the other a
block, forwards -- a RAM disk's sectors, a cache's buffers, a swapper's
pages.  **The fast path** is only that, as short as it can be made: one
window, the block's page and the offset in it kept as it goes rather than
worked out from 32 bits each slice, and a conventional pointer renormalised
only every 32 KB.  Everything else -- block to block, an overlap that must
be copied from the top, conventional memory touching the frame,
conventional to conventional, EMS-call mode -- goes to the general engine.
In the emulator (`test\instrs.py`) a 512-byte move is 151 instructions
besides the copy; the first working version took 190, with more memory
traffic.

A second fast path, for block to block and lengths past 64 KB, was built,
measured and **taken out**: the card itself stops block-to-block copies at
~445 KB/s and the general engine already reaches 432, big moves spend 98%
of their time copying either way, and it cost ~900 bytes of conventional
memory.  The one fast path now takes any length instead.

**The conventional side is made even** before the words start: on the V30
a misaligned word costs 16% in conventional memory and nothing on the
card, whose bus is 8 bits anyway (measured, below).  On a 386 or later,
doublewords when both sides are even.

### Interrupts

On a PicoMEM a move holds interrupts off while it has a window borrowed,
and lets them in every `/I` KB.  Otherwise an interrupt routine that maps a
page through the EMS driver could meet a frame the driver thinks is mapped
one way and is in fact mapped another -- PMEMMSC, for one, skips the port
write when it thinks the page is already there.  The windows are put back
before interrupts are let in, and interrupts come back as the caller had
them, never forced on.

**4 KB is the default because it costs nothing and loses nothing**: 16 KB
moves run at 704 KB/s with 4 KB slices and with 16 KB ones, 672 with 1 KB.
A 4 KB slice holds interrupts off for ~6 ms (conventional memory to a
block) or ~9 ms (block to block) on the V30.  `/I` stops at 8 KB because
**longer than about 27 ms -- half a timer tick -- loses BIOS clock ticks on
this machine** (below).

## Measured on the V30

NEC V30, PicoMEM 2 (BIOS 2026-06-16), PMEMMSC, all of it loaded low,
XMSSC from `CONFIG.SYS`, `XMSTEST`, two seconds a row:

| a second | XMSSC | XMSSC `/G` | EMS 57h | |
|---|---|---|---|---|
| 512-byte move to/from a block | **977** | 625 | 804 | **+22%** on 57h, **+56%** on EMS calls |
| 1 KB | **582** | 437 | 513 | +13% |
| 4 KB | **169** | 154 | 163 | +4% |
| 16 KB | **44 = 704 KB/s** | 43 | 44 | the card's ceiling |
| 16 KB, the conventional side odd | **704 KB/s** | 688 | 592 (EMSTEST) | alignment |
| block to block, 16 KB | **432 KB/s** | 432 | | the card's ceiling is ~445 |
| conventional to conventional, 16 KB | 1,696 KB/s | | | |
| allocate + free | 634 | | | |

**The ceiling**, measured by `test\xprobe.pas` with bare `REP MOVSW`: 712
KB/s between conventional memory and the frame, 1,780 in conventional
memory, and 440-453 between two frame windows.  XMSSC reaches the first
and the last; the 57h column's 32 KB figure is not shown because it is not
real (below).

What it cost to get there, all on the V30 (512-byte moves a second): the
first working version 813; the conventional-to-block fast path, 976; a
general any-shape fast path alone, 926; both, 979 -- then the second one
went (above) for 580 bytes of resident code, and the first took over any
length: 977.  Odd conventional addresses: 560 KB/s before the alignment
rule, 704 after.

### 8087, 186 and 386 paths

**The 8087 is no help, measured.**  A copy through the coprocessor (`FILD`
/ `FISTP` of qwords) runs at 405 KB/s in conventional memory against 1,780
for `REP MOVSW`, and 307 against 712 to the card -- 4.4 and 2.3 times
slower -- so XMSSC has no FPU path.  The V30 has an 8087 fitted, so this is
a measurement rather than an assumption.

**The 186/V30 instructions are not worth a path**: nothing on a move's hot
path gains measurably from `PUSHA` or an immediate shift, and DOS Bridge's
rule is not to gate for less (`BENCH`: 11%).  XMSSC identifies the V30 --
by `AAD`, since a V30 does not mask shift counts the way an 80186 does --
and says so, and that is all.

**On a 386 or later**: doubleword copies, the XMS 3.0 32-bit calls, and a
real A20 test.  These are **verified in the emulator only** (a 386 core,
`/C:3`).  A 486DX/33 joined the bridge on 2026-09-28 with a PicoMEM 1, but
that card's configuration has **EMS off** (`PMCFG`), and XMSSC needs EMS
under it; switching it on is a setting on the card that is also the
machine's boot disk, left for StevenC.  With it on, `XMSTEST` there
exercises all three.

## What the PicoMEM taught us

Everything here was measured on the V30 with the PicoMEM 2; the probes are
in `test\` and `docs/hardware.md` has the same list.

* **The EMS page registers read back**, and an `OUT` of a number read back
  maps that page.  That is what makes the direct path possible.
* **Changing a page register is free.**  An `OUT` takes ~4 us whether the
  number changes or not, and 512 bytes read straight after a change take
  the same time as with no change -- cycling 1, 2, 3, 4, 6, 8 or 16
  different pages through one window made no difference at all.  There is
  no page cache to thrash, so nothing is gained by avoiding a remap.
* **The frame's speed depends on the direction**: 712 KB/s between
  conventional memory and the frame, ~445 between two windows (the card
  serves both sides of the copy).
* **`INT 13h AX=6000h/6001h` returns with interrupts off.**  The PicoMEM
  BIOS hands back its own flags.  A program that calls it and then waits
  for the BIOS clock waits for ever -- this hung the V30 twice before it
  was found -- so XMSSC and its probes wrap the call in `PUSHF`/`POPF`.
* **Holding interrupts off past ~27 ms loses timer ticks** on this
  machine, and a benchmark timed by the BIOS clock then reads fast.  It
  cost an afternoon: 16 KB frame-to-frame copies with interrupts off
  appeared to run 32% faster, and a whole design was about to be built on
  it.  Timed by the PIT, with every IRQ masked for three seconds, the copy
  ran at the same 444 KB/s as with interrupts on; only a copy long enough to
  hold interrupts off past half a tick "gained", and 8 KB copies (18 ms)
  did not.  The dead end is recorded so nobody walks it again.
* **PMEMMSC's move (57h) held interrupts off for the whole move**, so a
  long one lost clock ticks: its "32 KB at 1,184 KB/s" in `XMSTEST`, faster
  than the card can go, was that, and so were EMSTEST's "EMS to EMS 640
  KB/s" (really 416) and "exchange 576 KB/s" (really 160).  **Fixed the
  same day in PMEMMSC r01-SC2**: 4 KB pieces, interrupts let in between
  them with the caller's page map put back first.
* **PMEMMSC restored a window nobody had mapped as page 0**, not as
  disabled, because its record of the frame started that way (a leftover
  from the Lo-tech source, which disabled with 0).  It showed as XMSTEST
  failing "the EMS page map changed" on the first `/G` move after a
  **fresh boot** only.  **Fixed in r01-SC2** too; `C:\CH375USB\PicoMEM\emm\README.md`
  has both.  XMSSC's direct mode was never affected: it puts the
  registers back as read.

## Tested

**`test\emuxms.py`**: the real binary in an 8086 emulator (Unicorn),
initialised as DOS initialises a driver, with UMBSC and PMEMMSC loaded
before it in the V30's order, and called through the entry point INT 2Fh
hands out.  The PicoMEM's EMS hardware is modelled as four windows whose
registers read back.  Eight configurations:

| | EMS driver | CPU paths | mode |
|---|---|---|---|
| `pm-direct-8086` | the real PMEMMSC binary | 8086 | PicoMEM direct |
| `pm-direct-386` | PMEMMSC | 386 | PicoMEM direct |
| `pm-generic-8086` | PMEMMSC | 8086 | EMS calls |
| `model40-direct-186` | a Python EMS 4.0 driver | 186 | PicoMEM direct |
| `model40-generic-8086` | Python EMS 4.0 | 8086 | EMS calls |
| `model32-generic-8086` | a Python EMS **3.2** driver | 8086 | EMS calls, reallocate by copying |
| `model32-generic-386` | Python EMS 3.2 | 386 | EMS calls |
| `com-pm-direct-8086` | PMEMMSC | 8086 | the TSR, loaded, used and unloaded |

The Python EMS drivers hand out their pages in **shuffled order and move
one on every reallocate**, so a driver that assumed a block's pages were
consecutive, or kept a stale map, reads the wrong memory.  Each
configuration runs the directed tests -- every function, every error code,
every move shape, the frame, overlaps, reallocation, handles running out,
`/U` refusing another build -- then **1,500 random operations**, and after
**every call** checks the registers that must not change, the direction and
interrupt flags, the four page registers and the EMS driver's own page map.
Every block's contents are checked against a reference copy **read through
the EMS driver, never through XMSSC**.  All eight: **0 checks failed**.

And the test was checked for bite: nine deliberate breakages -- the window
choice ignoring the frame, the page lookup ignoring the block, never
copying backwards, a page never advancing, a window never given back, the
same-block overlap check or the frame check removed, the conventional
pointer renormalised wrongly, the frame check dropping a length's high
word -- each failed checks.  The last one **at first failed none**: no test
moved 64 KB or more from below the frame into it.  The test that was added
for it then found a real bug in EMS-call mode, which put the caller's page
map back only at the end of a move, so a late slice could read
conventional memory through a window an early one had borrowed.  Fixed:
the map goes back after every slice, as the ports do in direct mode.

**`XMSTEST.EXE`** on the V30, against whatever XMS driver is loaded: the
behaviour checks with the page registers and PMEMMSC's map compared after
every call, then the benchmark above.  XMSSC: **0 checks failed** -- the TSR
direct and `/G`, 3.00 and 2.00, and `XMSSC.SYS` from `CONFIG.SYS`;
transcript CRC `DFBE8844` (`/V:2`: `624B68D9`, the version line).  Run with
no XMSSC it finds UMBSC and fails 17 checks, as it should.

**From `CONFIG.SYS` on the V30** (2026-09-28, `projects/dostune`'s variant
`xms2`): `DEVICE=C:\DRIVERS\XMSSC.SYS` after PMEMMSC and ANSISC.  It booted
in 20 seconds, DOS's upper memory blocks came through unchanged (UMBSC's,
reached through XMSSC's entry), XMSTEST passed, and PKZIP 2.04g detected
XMS 3.00 and made an archive `PKUNZIP -t` passed.  And the refusal path: a
second copy loaded with `DEVLOAD` printed "XMSSC is already loaded" and had
DOS discard it, leaving memory as it was.

`DEVLOAD` needed `LASTDRIVE=G` for that: with DOS's default it refuses
every driver, before calling it, for want of a free drive letter.

## Limits

* A move takes the caller's stack, measured in the emulator with its return
  address: 74 bytes on the fast path, 138 on the general engine, 212 in
  EMS-call mode with PMEMMSC underneath.
* Each block is an EMS handle, so blocks share the EMS driver's handles
  (PMEMMSC has 64) with every EMS program.  A zero-size block takes none.
* PicoMEM direct keeps a byte per allocated page: 256 pages, 4 MB, which is
  all a PicoMEM's EMS has.
* A block is at most 65,535 KB (the XMS 2.0 limit; 3.0's 32-bit calls take
  more, and get A0h).
* A conventional address past 1 MB wraps, as it does on an 8086.

## Files

| | |
|---|---|
| `XMSSC.ASM` | the driver: `nasm -f bin -o XMSSC.SYS XMSSC.ASM`, and `-DCOM` for the TSR |
| `bin\` | the released `XMSSC.SYS` and `XMSSC.COM` |
| `XMSSC.TXT` | the DOS-readable version of this, for the kit |
| `build.cmd` | builds both drivers, `XMSTEST` and `IRQCOUNT` into `build\` |
| `test\emuxms.py` | the emulator test.  `--quick`, `--only NAME`, `-v`; `$PMEMM` names the EMS driver binary |
| `test\instrs.py` | instructions executed per move, and where, in the emulator |
| `test\xmstest.pas` | `XMSTEST.EXE` |
| `test\xprobe.pas` | the card: its report, the readback, the copy ceilings, the 8087 copy |
| `test\xprobe2.pas`, `xprobe3.pas` | the cost of changing a page register; 1-16 pages in turn |
| `test\xprobe5.pas`, `xprobe6.pas` | frame-to-frame copies against the interrupt mask (timed by the PIT) and against copy size and `CLI` (timed by the BIOS tick): the lost-tick finding |
| `test\IRQCOUNT.ASM` | how often each IRQ fires |
