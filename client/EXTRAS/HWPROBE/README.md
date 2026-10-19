# HWPROBE

**HWPROBE**, four probes for a machine whose cards DOS cannot find: `NICSCAN` (an NE2000 at any ISA address, its MAC and the packet driver line), `PNPNIC` (wake a Plug-and-Play network card), `SNDPROBE` (a Sound Blaster, and a silent DMA + IRQ proof), `PCILIST` (the PCI bus and its IRQ routing). Three of them write to I/O ports -- read `HWPROBE.TXT` first

**Files:** `NICSCAN.EXE`, `PCILIST.EXE`, `PNPNIC.EXE`, `SNDPROBE.EXE`

## HWPROBE.TXT

The notes that travel with it to the DOS machine:

```
HWPROBE -- find network and sound cards     a DOS Bridge extra (optional)
StevenC & Claude, 2026.

WHAT IT IS
  Four probes for a machine whose cards DOS cannot find by itself,
  written to bring a Pentium II with a D-Link DE-220PCT (an NE2000 with
  no jumpers) and an onboard Yamaha YMF740C onto the bridge, after
  D-Link's own setup program and driver both said there was no card.

  NICSCAN [/Q]
    Every address an ISA network card can have, 200h to 3E0h. Where an
    NE2000 (8390) answers: its MAC address, its IRQ if the chip raises
    one, and the packet driver line to try. It also lists anything else
    that answers -- the "I/O conflict" in a vendor's message.

  PNPNIC [/L] [/C:id] [/D:n] [/P:hhh] [/I:n] [/Q]
    Wakes a Plug-and-Play network card with nothing to switch it on:
    isolation, then its I/O address and IRQ. /L only lists the PnP
    cards and changes nothing. A Creative card is never picked unless
    it is named with /C:.

  SNDPROBE [/P:hhh] [/T] [/I:n] [/D:n]
    Is there a Sound Blaster? The DSP at 220h, 260h and 280h (NOT 240h,
    where a network card often lives), its version, the AdLib at 388h,
    and the BLASTER variable. /T proves the DMA and the IRQ with a
    silent 256-byte transfer on DMA d (/D:0, 1 or 3; 1 by default)
    and IRQ n (/I:n, 5 by default).

  PCILIST
    Every PCI device through the BIOS, read-only: vendor and device ID,
    class, and the IRQ the BIOS routed its interrupt pin to.

READ THIS FIRST
  NICSCAN, PNPNIC and SNDPROBE WRITE TO I/O PORTS. Run them only on the
  machine that has the card you are looking for. On a machine with a
  PicoMEM (the boot disk!) or a CH375 card, those ports are theirs.
  PCILIST only reads.

  A green link LED does not mean the cable is good. Swap the cable
  before believing anything else.

INSTALL
  Nothing installs these. Copy the EXEs from this folder to C:\TOOLS,
  or run them from the floppy. They need DOS and an 8086 or better.

SOURCE
  On the Windows side: server\extras\hwprobe\ (Free Pascal 3.2.2,
  build.cmd). README.md there has what each found on the machines they
  were written for.
```

Source, tests and the full write-up: [`server/extras/hwprobe`](../../../server/extras/hwprobe)
