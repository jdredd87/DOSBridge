# extras/ -- optional DOS enhancements

Things that make a DOS machine better, which ship with DOS Bridge but which
**nothing installs for you**. `INSTALL.BAT` puts the bridge's tools in
`C:\TOOLS` and sets up the agent; it never touches `CONFIG.SYS`, and it never
installs anything from here.

Each extra is a folder with its source, a `bin\` of released binaries, and a
DOS-readable `.TXT` explaining what it does and how to install it by hand.

| | |
|---|---|
| `ansisc\` | **ANSISC**, a drop-in `ANSI.SYS` replacement: everything MS-DOS 6.22's does, same screen, 3-4x faster console output. Built from Microsoft's MIT-licensed MS-DOS 4.0 source |
| `umbsc\` | **UMBSC**, an upper memory manager for PCs with no 386 memory manager: `USE!UMBS.SYS` rebuilt to take no conventional memory (224 bytes back), same answers, same blocks. Public domain |
| `doskeysc\` | **DOSKEYSC**, a DOSKEY for MS-DOS 5 and later: everything MS-DOS 6.22's does, key for key, plus **TAB filename completion** (TAB, TAB again, SHIFT+TAB). Written from a study of 6.22's DOSKEY, none of its code, and since 1.1 its help and messages are its own words too. Public domain |
| `xmssc\` | **XMSSC**, XMS 3.0 for PCs with no extended memory, served out of EMS -- any EMS 3.2 driver, and on a PicoMEM it drives the card's page registers itself: small moves 22% faster than the EMS driver's own move. `CONFIG.SYS` driver or TSR (`/U` unloads). Written from the specifications. Public domain |

## How extras ship

* **server half** (`server\extras\`) -- everything here, source included,
  except build output (`build\`) and anything a folder's `.gitignore`
  excludes.
* **client half** (`client\EXTRAS\<NAME>\`) -- each extra's `bin\*` and its
  `.TXT`, for carrying to the DOS machine with the rest of the kit.

Nothing is rebuilt at kit time: an extra may need the DOS machine to build
(ANSISC is assembled by MASM on DOS, over the bridge), so what ships is what
was released into its `bin\` -- update `bin\` deliberately, after testing.

## Adding one

A folder here with a `bin\` and a `.TXT` is picked up by the kit builders
without any list to edit.  Credit **StevenC & Claude** in its banner, source
headers and README, as everywhere else.
