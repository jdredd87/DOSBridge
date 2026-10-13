# DOS Bridge demos

Eleven small programs that show what an 8086-class PC can do when the code
respects it -- smooth scrolling, real parallax, a textured raycaster, FM music
-- and that prove the bridge works end to end.  Written by **StevenC** and
**Claude** (Anthropic), and developed on an NEC V30 at 8 MHz.

Every one is plain 8086 code, so it runs on anything from an original PC
upward.  Where a faster part helps (an 8087, a 186's instructions) it is
picked at run time, never assumed.  And every one **reports what it did
through DOS** as well as on the screen, so when it is run over the bridge
the result comes back as text: frame rates, notes played, what was detected.

## The demos

Each name links to its source.  [`starter/demos`](../../server/starter/demos/.) has every demo and
the units only they use; [`starter`](../../server/starter/demos/..) has the shared units (`About`,
`Cpu`, `Tester`, `VGA`, `Prof`) and the build scripts.

| | needs | what it is |
|---|---|---|
| [**SCROLLER**](../../server/starter/demos/scroller.pas) | VGA, AdLib optional | A side-scrolling landscape with sprites and music in mode X: **70 fps on a V30**, one refresh per frame, no late frames. The background is painted once and scrolled by the CRTC start address. [SCROLLER.md](../../server/starter/demos/SCROLLER.md) tells the whole story |
| [**PARALLAX**](../../server/starter/demos/parallax.pas) | VGA, AdLib optional | **NEON DRIFT**: real per-row parallax. A CRTC line compare pins the bottom 64 rows so the perspective grid floor is repainted every frame, and every row scrolls at its own rate -- the geometry, not an effect. Two hovercars, an OPL2 soundtrack, and the 8087 used only if it wins a race against the integer path. [PARALLAX.md](../../server/starter/demos/PARALLAX.md) |
| [**RAYCAST**](../../server/starter/demos/raycast.pas) | VGA, AdLib optional | A Wolfenstein-style raycaster with textured walls in a generated 64x64 maze. Walks itself round, or is driven from the keyboard or from a script |
| [**FRACTAL**](../../server/starter/demos/fractal.pas) | VGA | The Mandelbrot set, with two inner loops: 16-bit fixed point, and the 8087 -- which buys precision, not speed, so `ZOOM` goes deep only with one fitted |
| [**BALLS**](../../server/starter/demos/balls.pas) | VGA | Bouncing balls in mode 13h, colour or mono |
| [**SVGATEXT**](../../server/starter/demos/svgatext.pas) | VGA; VESA for SVGA | Rotating text at 640x480x256 through VESA bank switching, or mode 13h if the card cannot |
| [**MATRIX**](../../server/starter/demos/matrix.pas) | any colour text | The falling green rain, in 80x25 text mode |
| [**AMOZART**](../../server/starter/demos/amozart.pas) | AdLib (OPL2) | Mozart's *Eine kleine Nachtmusik* in two voices on an FM chip, found by its own timers first |
| [**MOZART**](../../server/starter/demos/mozart.pas) | PC speaker | The same melody in one voice on the PC speaker, timed by the clock so it plays at the same tempo on any CPU |
| [**HELLO**](../../server/starter/demos/../hello.pas) | nothing | The smoke test: prints a line and runs two checks, one failing on purpose. Its exit code is the number that failed |
| [**PROFTEST**](../../server/starter/demos/proftest.pas) | nothing | Exercises the `Prof` profiling unit on work whose relative cost is already known |

## Running them

On the DOS machine the kit's `INSTALL` puts them in `C:\TOOLS`.  Run one at
the prompt:

```
C:\TOOLS\SCROLLER
C:\TOOLS\PARALLAX SECS 60
C:\TOOLS\RAYCAST KEYS
```

Or from Windows, over the bridge -- the program is pushed, run, and its
report comes back with its exit code:

```
dosrun SCROLLER.EXE
dosrun RAYCAST.EXE SECS 300 --timeout 400
```

A job times out after 120 seconds unless `--timeout` says otherwise, so give
a long run the time it asks for.

Every demo ends by itself -- a program that waits for a key looks exactly
like a hung machine when nobody is there to press one.

## Command lines

```
SCROLLER [SECS n] [SPEED n]

PARALLAX [SECS n] [SPEED n] [SWEEP n] [CARS n] [MONO|COLOUR]
         [NOMUSIC] [NOFPU] [NOPAUSE] [NOSHOT] [PROF]

RAYCAST  [INT|FPU] [SECS n] [SEED n] [KEYS|PLAY file] [HOLD] [NOPIVOT]
         [QUIET|SPKR] [TEX|FLAT] [M13|COARSE|FINE] [NOSEEK]
           KEYS   W/S or arrows move, A/D or arrows turn, Q/E strafe,
                  Shift runs, Esc quits
           PLAY   a file of timed key events (mkwalk.py writes them;
                  walk.txt is one for the default seed)
           SEED   a different maze -- the seed is the whole world
           HOLD   leave the picture up on exit, for VSHOT

FRACTAL  [INT|FPU] [ZOOM n] [SECS n]
           ZOOM 500 SECS 40   500x into the Feigenbaum point (needs an 8087)

SVGATEXT [text]            up to 30 characters, typed as you like
MATRIX   [seconds]         default 30
MOZART   [ticks]           eighth-note length, 2..16 (default 4)
AMOZART  [ticks]
BALLS
HELLO
PROFTEST
```

## Building them

They are built with Free Pascal 3.2.2 cross-compiling for real-mode DOS,
from `starter\`, with the units only the demos use kept here beside them
(`modex`, `music`, `opl2`, `retro`, `pmdet`, `kbd`, `mystery`):

```
cd starter
build.cmd scroller          compile into starter\build
test.cmd scroller           compile AND run it on the DOS machine
```

## Worth reading even if you never run them

The sources are written to be read.  Each header says what was measured on
the real hardware and why the code is the shape it is -- including the
attempts that measured as nothing.  The short version, which applies to
anything on an 8086:

* **32-bit arithmetic costs 5-8x its 16-bit equivalent.** Fixed point in 16
  bits beat everything else combined in the Mandelbrot loop.
* **`REP STOSW` beats a per-pixel loop by 7x.** One string instruction
  doubled the bouncing balls' frame rate.
* **A frame rate is quantised by the refresh.** 56 fps that alternates one
  and two refreshes looks worse than a steady 35.  Count the late frames, not
  the average.
