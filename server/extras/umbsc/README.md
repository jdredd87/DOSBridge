# UMBSC -- an upper memory manager that uses no conventional memory

*An optional DOS Bridge extra: it ships in the kit (`client\EXTRAS\UMBSC`)
and nothing installs it -- see `UMBSC.TXT`.*

Written by **StevenC** and **Claude** (Anthropic), September 2026.  Public
domain, like the work it comes from: `USE!UMBS.SYS` by Marco van
Zwetselaar (1991) and Krister Nordvall's NASM rewrite, v2.2.

## What it is for

A PC with no 386 memory manager -- 8088, 8086, NEC V20/V30, 286 -- can still
have RAM in the upper memory area: an EMS board, a RAM card, a PicoMEM.  A
UMB manager is what lets DOS 5 and later use it (`DOS=UMB`, `DEVICEHIGH`,
`LOADHIGH`).  `USE!UMBS.SYS` is the classic one.

## What is different

`USE!UMBS.SYS` keeps its XMS entry point, its INT 2Fh hook and its list of
free blocks in the driver's own memory.  DOS loads it before there is any
upper memory, so that is **224 bytes of conventional memory for the whole
session**, for code that runs a dozen times during boot.

UMBSC copies those 125 bytes to the end of the last upper memory block
(8 paragraphs), hands DOS the rest, and has DOS **discard the driver
entirely**: it clears bit 15 of its attribute word and reports zero units,
which DOS treats as a block device that found no drives.  That path is in
Microsoft's published MS-DOS source (`SYSCONF.ASM`, `ISBLOCK` ->
`Erase_Dev_do`) and prints nothing.

The resident part goes at the END of the last range so that every block
keeps its start and DOS is handed them in the same order as before.

## Proven

`test\emuumb.py` boots a UMB manager in an 8086 emulator four ways -- no
XMS driver, an XMS driver without UMBs already loaded (it must chain), one
with UMBs (it must not install), and a bad command line -- and asks for
upper memory the way DOS does, writing an MCB into each block it is given
and calling the driver again afterwards:

| | `USE!UMBS` 2.2 | UMBSC |
|---|---|---|
| conventional memory kept | 208 + 16 bytes | **0** |
| blocks DOS is given | C800h 32 KB, D800h 32 KB | C800h 32 KB, D800h 32 KB - 128 bytes |
| order | C800h first | C800h first |
| XMS 00h/08h/11h, INT 2Fh 4300h, other INT 2Fh | as below | identical |
| an XMS driver without UMBs first | chains to it | chains to it |
| an XMS driver with UMBs first | not installed, INT 2Fh untouched | the same |
| a bad command line | not installed | the same |

```
python test\emuumb.py USE!UMBS.SYS bin\UMBSC.SYS
```

**On a real machine**: the NEC V30 behind DOS Bridge has run it since
2026-09-27 (`DEVICE=C:\DRIVERS\UMBSC.SYS C800-D000 D800-E000`, PicoMEM card
RAM): `MEM /C` shows no UMB manager in conventional memory, 224 more bytes
free, and every driver that was loaded high still loaded high -- so MS-DOS
6.22 does link the UMBs through a driver it has just discarded, the one
thing the emulator could not show.

## Building

```
build.cmd          UMBSC.ASM -> build\UMBSC.SYS, compared with bin\UMBSC.SYS
```

NASM.  `bin\UMBSC.SYS` (CRC `C80F0E0C`, 1,220 bytes) is the released build
the kit ships; a fresh build is byte-identical to it.

## History

UMBSC was written in the CH375USBTools repository's PicoMEM work
(`PicoMEM/emm`) beside the PicoMEM EMS driver, and moved here on 2026-09-27:
it is a DOS tool, not a PicoMEM one, and this is now its only copy.
