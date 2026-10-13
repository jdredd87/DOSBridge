# HWPROBE -- PNPNIC, NICSCAN, SNDPROBE, PCILIST: network and sound cards from DOS

Four probes for a machine whose cards DOS cannot find by itself: an ISA
network card (NICSCAN, PNPNIC), a Sound Blaster and its IRQ and DMA
(SNDPROBE), and what is on the PCI bus (PCILIST).

Written by **StevenC** and **Claude** (Anthropic), 2026-10-13, to bring a
third machine, **p3box**, onto the bridge with a **D-Link DE-220PCT rev D2**:
NE2000-style, no jumpers, its I/O address and IRQ in a 93LC56 EEPROM.

D-Link's own setup program (v2.61) and packet driver (`DE22XPD.COM` v5.00)
both said the card was not there.  The driver set is right for the card --
D-Link's August 1998 release for Rev. D ships the same two programs, byte for
byte -- so the question was where the card was, not which software.

## NICSCAN -- find it

```
NICSCAN [/Q]
```

Every address an ISA network card can have, 200h to 3E0h in steps of 20h:

* the NE2000 test Linux's `ne.c` makes -- page 1's MAR5 written, page 0's
  tally counter read back, which an 8390 clears on read -- and what it wrote
  is put back when the answer is no;
* where it is an 8390: a reset and the 32-byte station address PROM through
  remote DMA (word mode, then byte mode); D-Link's start `00 80 C8`;
* its IRQ: one remote-DMA-complete interrupt, the PICs' request registers
  read before and after with interrupts off;
* every address that answers but is not an 8390 -- what the "I/O conflict"
  in D-Link's message would be.

It prints the packet driver line to use.  **It writes to whatever answers,**
so run it only on the machine with the card: on the 486 and the V30 those
addresses are the PicoMEM's (their boot disk) and the CH375's.

On p3box: `NE2000 at 240h  MAC 00-80-C8-xx-xx-xx` (D-Link's prefix) -- matching the card's label --
in jumperless mode, where D-Link's search does not look.  The IRQ did not
show (the remote-DMA-complete interrupt may not be raised on this chip); it
is **3**, and `DE22XPD 0x60 0x240 3` brought the machine onto the bridge --
once the network cable, which was bad, had been changed.  Something also
answers at 3C0h: the VGA's registers.

## PNPNIC -- wake a Plug-and-Play one

```
PNPNIC [/L] [/C:id] [/D:n] [/P:hhh] [/I:n] [/Q]
```

For a card that *is* in Plug-and-Play mode with nothing to switch it on: the
initiation key, isolation, a card select number, then its logical device's
I/O address and IRQ through 279h/A79h (PNPSB's code, `projects/pnpsb`), and
the NE2000 reset tried at the new address.  `/L` lists every PnP card and
changes nothing; a Creative card is never picked unless named with `/C:`.
Tested on the 486, whose only PnP card is the AWE64: listed, left alone (and
`PNPSB /I:9 /FM /Q` run after, to be sure -- the right switches matter: a
bare `PNPSB /Q` puts that card on IRQ 5, which never reaches the 486's
processor).  On p3box StevenC's first run found nothing; later, with the
driver loaded and the bridge up, `/L` listed the card as **`DLK2201`** --
so it does answer isolation, and why the first run did not is not known.

## SNDPROBE -- is there a Sound Blaster, and do its IRQ and DMA work?

```
SNDPROBE [/P:hhh] [/T] [/I:n]
```

The DSP reset at 220h, 260h and 280h -- **not 240h**, where p3box's network
card lives (SBPROBE, which scans 210h-280h, would have written into it) --
and its version; the AdLib timer test at 388h; the `BLASTER` variable.
`/T` is PNPSB's proof: a silent 256-byte 8-bit DMA transfer on DMA 1 that
must end in the card's interrupt on IRQ `/I:n` (5 by default), and the DMA
count left says which half failed (FFFFh: the DMA moved everything).

p3box's onboard **Yamaha YMF740C** (PCI): nothing answered at all until
Yamaha's `SETUPDS /S`; then DSP 3.1 at 220h and the OPL at 388h -- but `/T`
on IRQ 5 failed with the DMA complete.  The interrupt came on **IRQ 10**,
the chip's PCI line (`/T /I:10` passed): in Yamaha's PCI mode
(`DS.INI`'s `IRQMODE=1`) the Sound Blaster interrupt rides INTA#.  With
`IRQMODE=0` it is a classic ISA IRQ 5 -- `/T` passed -- and IRQ 5 is what a
DOS game can use (Wolf3D: 2, 3, 5, 7).  (`PIRQRC=1` did not move it.)

## PCILIST -- what is on the PCI bus

```
PCILIST
```

Every PCI device through the BIOS's PCI services (INT 1Ah B101h, B109h),
read-only: bus, device, function, vendor and device ID, class, and the
interrupt pin and the IRQ the BIOS routed it to.  On p3box, which the CPU
probe could only call "386 or later": an Intel 440BX board (`8086:7190`,
PIIX4 `7110-7113`), the Yamaha YMF740C (`1073:000C`, INTA# to IRQ 10), two
3dfx Voodoo2s (`121A:0002`) and an ATI Rage Pro AGP (`1002:475A`).

## Building

`build.cmd` compiles all four into `build\` and compares each with `bin\`,
which is what the kit ships (`HWPROBE.TXT` beside it, in the client half's
`EXTRAS\HWPROBE\`).  One by one:

```
fpc -Tmsdos -Pi8086 -WmLarge -O2 -Fu../../starter -FEbuild -FUbuild nicscan.pas
```

This was `projects/pnpnic` until 2026-10-13, when it became an extra so the
public kit carries it.
