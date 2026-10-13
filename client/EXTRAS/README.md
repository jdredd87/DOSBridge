# Optional extras

Optional DOS enhancements that ship with DOS Bridge but that **nothing installs for you** -- the kit's `INSTALL` never touches `CONFIG.SYS`.  Each folder holds the released binaries and a DOS-readable `.TXT` that says what the extra does and how to install it by hand.  Their sources, tests and full write-ups are in [`server/extras`](../../server/extras).  Written by **StevenC** and **Claude** (Anthropic).

| | |
|---|---|
| [`ANSISC`](ANSISC) | **ANSISC**, a drop-in `ANSI.SYS` replacement: everything MS-DOS 6.22's does, same screen, 3-4x faster console output. Built from Microsoft's MIT-licensed MS-DOS 4.0 source |
| [`DOSKEYSC`](DOSKEYSC) | **DOSKEYSC**, a DOSKEY for MS-DOS 5 and later: everything MS-DOS 6.22's does, key for key, plus **TAB filename completion** (TAB, TAB again, SHIFT+TAB). Written from a study of 6.22's DOSKEY, none of its code, and since 1.1 its help and messages are its own words too. Public domain |
| [`HWPROBE`](HWPROBE) | **HWPROBE**, four probes for a machine whose cards DOS cannot find: `NICSCAN` (an NE2000 at any ISA address, its MAC and the packet driver line), `PNPNIC` (wake a Plug-and-Play network card), `SNDPROBE` (a Sound Blaster, and a silent DMA + IRQ proof), `PCILIST` (the PCI bus and its IRQ routing). Three of them write to I/O ports -- read `HWPROBE.TXT` first |
| [`UMBSC`](UMBSC) | **UMBSC**, an upper memory manager for PCs with no 386 memory manager: `USE!UMBS.SYS` rebuilt to take no conventional memory (224 bytes back), same answers, same blocks. Public domain |
| [`XMSSC`](XMSSC) | **XMSSC**, XMS 3.0 for PCs with no extended memory, served out of EMS -- any EMS 3.2 driver, and on a PicoMEM it drives the card's page registers itself: small moves 22% faster than the EMS driver's own move. `CONFIG.SYS` driver or TSR (`/U` unloads). Written from the specifications. Public domain |
