# DOSKEYSC -- DOSKEY, with TAB completion

*An optional DOS Bridge extra: it ships in the kit (`client\EXTRAS\DOSKEYSC`)
and nothing installs it -- see `DOSKEYSC.TXT`.*

Written by **StevenC** and **Claude** (Anthropic), September 2026.  Public
domain.

## What it is

A DOSKEY for MS-DOS 5 and later that does everything MS-DOS 6.22's DOSKEY
does -- the line editor, the DOS template keys F1-F6, history (Up, Down,
PgUp, PgDn, F7, F8, F9, Alt+F7), macros with `$1-$9 $* $T $G $L $B $$`,
Alt+F10, and `/BUFSIZE /HISTORY /MACROS /INSERT /OVERSTRIKE /REINSTALL` --
with the same result on the screen, key for key, and adds:

| key | |
|---|---|
| **TAB** | complete the file or directory name being typed |
| TAB again | the next name that matches, in name order, wrapping round |
| **SHIFT+TAB** | the previous one |

`/NOTAB` turns completion off (TAB then inserts a tab, as 6.22's does) and
`/TAB` back on; both work on an already-loaded copy.

It is written from a study of 6.22's `DOSKEY.COM` -- disassembled, every
routine read -- and contains none of its code.  There is no published
source for DOSKEY: it arrived in MS-DOS 5, after the MS-DOS 4.0 release
Microsoft has open-sourced.

## How completion behaves

* **The word** is what runs back from the cursor to a blank or one of
  `; , = + < > | " /` (and `^T`).  Only the part before the cursor is
  matched; the whole word is replaced -- TAB in the middle of `autoexec.b|at`
  gives `autoexec.bat`, not `autoexec.batat`; at the start of a word it
  completes from nothing and replaces that word.
* **The pattern** is that part plus `*.*` (plus `*` if it already has a
  dot), so `\dos\m`, `*.bat` and `config.s` all work, and a directory or
  drive in front of the name is kept exactly as typed.
* **Order** is plain byte order of `NAME.EXT`, which is what `DIR /ON`
  shows for 8.3 names.  Each TAB takes the least name after the last one
  (SHIFT+TAB the greatest before it) and wraps.  One directory scan finds
  the next eight in order and keeps them (112 bytes), so seven presses in
  eight cost no disk access; it scans again when they run out, when the
  direction changes, or for a new word.  `test\tabdiff.py` holds this to
  exactly the answers of scanning on every press.
* **Case** follows the nearest letter before the cursor: typing in lower
  case gets `autoexec.bat`.
* **Directories get no `\` after them**, because `CD` will not take one:
  `CD \DOS\` is "Invalid directory" on MS-DOS 6.22.  (The first release
  added one -- StevenC found it at the keyboard on the first day.)  To go
  inside, type the `\` and TAB again -- any key but TAB ends the cycle.
* **Found by** find-first/next with attribute 10h -- hidden and system
  files are not offered, `.` and `..` are skipped.  While it looks, INT 24h
  answers Fail and INT 23h is ignored, so a drive with no disk finds nothing
  instead of stopping at "Abort, Retry, Fail?"; the caller's DTA and both
  vectors are put back.
* A result that would make the line longer than 127 characters is not
  put in.

## Compatible with 6.22's DOSKEY, in memory too

The resident part keeps 6.22's layout for everything its command line
touches: offsets 103h-243h (the caller's buffer, the macro area, the
history ring and its pointers, the insert default, and the editor state
6.22's `/H` and `/M` code writes while printing).  So each program's
`/M`, `/H`, `/INSERT`, `/OVERSTRIKE` and macro definitions work on the
other's resident copy -- verified both ways in `test\directed.py`.  Its
own additions (the TAB state, and `DKSC` at 244h so it can tell itself
from 6.22's) come after that.  INT 2Fh AX=4800h answers `AA02h`, as 6.22's
does, which is what makes the other DOSKEY treat it as its own.

Windows 3.x and the DOS task switcher get instance data for everything
that must be per session (INT 2Fh 1605h / 4B05h), as with 6.22's.

## Proven

**In an 8086 emulator** (`test\emudoskey.py`: Unicorn, a BIOS and a DOS in
Python, COMMAND.COM's side of INT 2Fh 4810h), 6.22's DOSKEY and DOSKEYSC
are driven with the same keystrokes and compared after every line on the
line handed back, the whole screen, the cursor, the cursor shape, the BIOS
insert flag and beeps:

| | |
|---|---|
| random sessions (`emudoskey.py --fuzz`) | 1,200 sessions of up to 60 lines -- typing, every editing key, recall, the template keys, F7 F8 F9, macros being defined, used, listed and deleted, buffers from 257 bytes up, `/INSERT` -- each run twice, with and without a console driver that answers the generic IOCTL (F7's page length comes from it): **identical** |
| chosen sessions (`directed.py`) | F7 paging past a screen, F9 with every kind of number, F8, a full history ring, macros taking history space until "Insufficient memory", a macro expanding past 127 characters, `^T` lines, edits on the bottom row, the template, switches: **identical**; and each DOSKEY's command line on the other's resident copy: **identical** |
| the test is sharp | three one-line bugs planted in DOSKEYSC (Down on an empty line, `^U`'s width, the 258-byte history floor) are each caught |

TAB is the one thing with nothing to compare against, so `test\tabtest.py`
holds it to 94 directed cases (the line each must give, over a made-up
disk) and 2,000 random sessions after each of which the screen must show
exactly the prompt and the line, nothing left over, cursor at the end.

**On the real machine** -- the NEC V30 behind DOS Bridge, MS-DOS 6.22,
ANSISC as the console: `test\DKTEST.ASM` plays a key script to whichever
DOSKEY is loaded, answering its keyboard reads itself so no keystroke can
be left over, and reports the line, the cursor and the whole text screen
after every line; `test\hwcheck.py` makes the same report in the emulator.

| | report lines | differ from the emulator |
|---|---|---|
| 6.22's DOSKEY, 52-line editing script | 1,431 | **0** |
| DOSKEYSC, the same script | 1,431 | **0** -- and byte-identical to 6.22's report |
| DOSKEYSC, TAB over the V30's own `C:\`, `C:\DOS` and `C:\DRIVERS` | 17 lines | all as expected, including a drive that does not exist |

What it costs there:

| | |
|---|---|
| memory (`MEM /C`, 512-byte buffer) | 4,144 bytes for 6.22's DOSKEY, **5,232** for DOSKEYSC -- the TAB code and its state are most of the difference |
| 20 TABs in `C:\DOS` (132 files) | about 1.0 s on the V30, 0.05 s a press (a scan every press, as first released: 4.8 s) |
| a TAB in `C:\` (32 names) | about 0.04 s |

## Where it deliberately differs from 6.22's

* TAB and SHIFT+TAB (with `/NOTAB`, TAB is 6.22's again).
* `/TAB`, `/NOTAB`, and its own `/?` text.
* "Insufficient memory to store macro" is spelled right.
* It runs on DOS 5.00 and later; 6.22's insists on exactly 6.22.
* Plain `DOSKEYSC` with 6.22's DOSKEY already loaded says so (and that
  `/REINSTALL` loads it over), where 6.22's is silent: otherwise it would
  do nothing and leave TAB not working with no explanation.

## Building and testing

```
build.cmd       DOSKEYSC.ASM -> build\DOSKEYSC.COM (compared with bin\),
                test\DKTEST.ASM -> build\DKTEST.COM
```

NASM.  `bin\DOSKEYSC.COM` is the released build the kit ships.

The comparisons need 6.22's `DOSKEY.COM` in `ref\` -- **Microsoft's
proprietary binary, never committed** (`.gitignore`); copy your own there.
Python 3 with `unicorn` (and `capstone` for `test\rdis.py`, the
disassembler used to study it).

```
cd test
python emudoskey.py ..\ref\DOSKEY.COM ..\build\DOSKEYSC.COM --fuzz 1200
python directed.py  ..\ref\DOSKEY.COM ..\build\DOSKEYSC.COM
python tabtest.py   ..\build\DOSKEYSC.COM --fuzz 2000
python dkemu.py     ..\build\DOSKEYSC.COM ..\build\DKTEST.COM T.KEY
```

On a real machine through DOS Bridge (`keysets.py` writes `E.KEY` and
`T.KEY`; `dkemu.py` above checks DKTEST itself in the emulator first):

```
python keysets.py
dosdeploy ..\build\DKTEST.COM C:\DKSC      (and E.KEY, DOSKEYSC.COM)
dosexec "C:\DKSC\DOSKEYSC.COM /REINSTALL"
dosexec "C:\DKSC\DKTEST.COM C:\DKSC\E.KEY C:\DKSC\R.TXT"
dospull C:\DKSC\R.TXT
python hwcheck.py diff R.TXT ..\build\DOSKEYSC.COM E.KEY
```

Two things DKTEST has to do that are easy to miss: a bridge job's stdout
is a file, and DOSKEY echoes through stdout (INT 21h AH=02h), so DKTEST
points its stdout at CON for the test and back afterwards; and the scripts
start with Alt+F7 Alt+F10, because the DOSKEY already on the box has
history and the model starts empty.
