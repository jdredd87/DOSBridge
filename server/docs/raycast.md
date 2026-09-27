# The raycaster: every measurement, and what it cost

`starter/demos/raycast.pas` from 4.2 to 44.7 fps, with the wrong turns kept.
The most useful performance document here -- most of its lessons are
about measuring on an 8086, not about raycasting.

Split out of `CLAUDE.md`, which keeps the summary and the pointer here.

## The raycaster, and where the time actually goes

`starter/demos/raycast.pas` is a Wolfenstein-style raycaster in mode 13h. It walks
itself round a 16x16 maze -- there is nobody at the keyboard over the bridge --
and prints its own stats, the maze with the cells it visited, and an ASCII
thumbnail read back out of A000, so the whole run is checkable from Windows.

Three `BENCH` numbers shaped it more than the raycasting did:

```
32-bit multiply    10920/sec      REP STOSW to video   439821/sec
32-bit divide       7280/sec      per-pixel MemW[]      58640/sec
```

Which forces four decisions:

* **No divides in the DDA.** The textbook algorithm divides twice per column
  for `deltaDist = 1/|rayDir|`. Both depend only on the ray's *angle*, so they
  are precomputed into a 1024-entry table and the per-column cost becomes a
  lookup. 1024 divides once at startup against 640 every frame.
* **Q8, not Q10.** `IMUL` leaves the product in DX:AX and a `>>8` of that is
  two register moves -- `AL` takes `AH`, `AH` takes `DL`. A `>>10` needs a
  six-round `shl`/`rcl` chain, because the 8086 has no 32-bit shift. Same
  reasoning as `fractal.pas`.
* **One divide per column survives**, the perspective divide `height = k/dist`.
  That is the only thing left for a coprocessor to win, and it is exactly what
  the `FPU` path replaces -- three x87 instructions, `FILD`/`FDIVR`/`FISTP`.
  Everything else is identical between the two paths.
* **The blitter never touches a pixel.** Adjacent columns with the same top,
  bottom and colour are coalesced into runs, and each run is drawn as
  rectangles of `REP STOSB`. Facing a flat wall the entire screen collapses
  into a handful of rectangles; at an angle the runs narrow and it degrades to
  something close to per-column fills.

**Where the frame actually goes**, measured on the V30 with `NODRAW` and
`NOCAST` -- which run the loop with one half switched off, and which corrected
two wrong guesses:

| | |
|---|---|
| `FINE`, 320 rays at 1 px | 345 ms (2.9 fps) |
| default, 160 rays at 2 px | **238 ms (4.2 fps)** |
| &nbsp;&nbsp;casting | 79 ms |
| &nbsp;&nbsp;drawing | 159 ms -- of which 78 is the band clear |
| `BLOCKY`, 80 rays at 4 px | 182 ms (5.5 fps) |

**The band clear is the floor, and it is memory bandwidth, not code.** Two
full-screen rectangles are 64000 pixels; `BENCH` puts `REP STOSW` at 439821
words a second, which predicts 73 ms and measures 78. Nothing rearranges that
in mode 13h -- the screen has to be written once and that is what writing it
once costs. Everything below is about the other 160 ms.

Three things in that table are worth keeping:

* **The 8087 is worth 13 ms, about 5%.** That is the entire perspective
  divide -- 160 a frame, from a software 32-bit divide at 7280/sec to three
  x87 instructions at 34361/sec. It is a small share precisely because
  everything else was arranged to avoid 32-bit arithmetic. This is not a demo
  that needs a coprocessor, and it says so.
* **Casting was the biggest single cost, not the blitter.** That is the
  opposite of what it looked like, and only `NODRAW` showed it. The fix was
  removing procedure calls from the DDA -- a flat byte map indexed by a
  running offset instead of `CellAt` on an array of `ShortString`, and 16-bit
  positions instead of `LongInt`, which had been putting a 32-bit shift and
  AND in every column of every frame.
* **Hoisting beat micro-optimising, by a lot.** `MX`, `MY`, the grid index
  and both fractional positions were computed inside the per-column cast --
  two shifts, a multiply and two ANDs, 160 times a frame for an answer that
  depends only on where the camera is. Moving them to a once-per-frame
  `CamPrepare` took casting from 93 ms to 79. By contrast, unrolling the
  column blitter's row loop by two -- the obvious micro-optimisation, and the
  one that looked most promising -- was worth about 2%.
* **Doubling the rays costs 101 ms, almost exactly the extra casting.** Once
  ceiling and floor became bands, the ray count stopped affecting the fill at
  all -- so the first version's claim that 160 rays were "roughly three times"
  faster stopped being true the moment the bands went in. Measured claims go
  stale when the thing around them changes.

## Mode X, page flipping and the walk: 4.2 to 12.0 fps

Measured on the V30, all on the same maze and the same 30-second tour:

| | fps | |
|---|---|---|
| the old default: chained mode 13h, 160 rays | 4.2 | ceiling, then floor, then walls, visibly |
| mode X, 80 rays, single page | 8.6 | |
| **mode X, 80 rays, triple buffered** | **12.0** | nothing visible but finished frames |

**2.9x on the default path, and the tearing is gone.** Three separate changes,
each measured, and the one that mattered most to look at was not the one that
bought the most frames.

### Page flipping is the answer to "it draws the floor then the walls"

That complaint is exact, and it is not a rendering bug: the frame really is
assembled ceiling-first, then floor, then walls over the top of both, and at
four frames a second you watch it happen. **A chained 320x200 screen cannot
be double buffered** -- it is 64000 bytes and only one of those fits in the
64K window at A000, so there is nowhere to build the next frame out of sight.
Every mode 13h demo here has the same property; this is just the first one
slow enough for it to show.

Unchained, a page is 320x200/4 = 16000 bytes a plane against 65536 fitted, so
**three** pages fit. Three rather than two deliberately: with two, the page
drawing moves on to is the one still being displayed until the next retrace,
so the flip has to *wait* for that retrace -- up to 14 ms out of a frame
lasting 83. With three, the page we step to is two flips old and certainly
not on screen, so the flip waits for nothing and costs two OUTs. `FlipWait`
is reported and reads **0**.

The start address is written in the units `modex.pas` already uses for the
scroller -- one address is one byte a plane, four pixels, which is why
`ShowAt` there does `PixX shr 2`. Both halves go in during active display so
the CRTC cannot latch an address that is half old and half new; there is
deliberately **no** wait after them.

### Only clear the rows that are stale

Each page carries the top and bottom row its own previous frame put walls
into. Everything outside that band still holds the ceiling or floor colour it
was given two frames ago, so the clear is that band and not the screen. A
corridor fills most of the screen with wall and saves little; an open room
leaves a thin band and saves nearly all of it.

### `REP STOSB` for one byte is the wrong instruction

The wall slices went through the general rectangle fill, which sets up a
`REP STOSB` **per row**. A four-pixel-wide column in mode X is *one byte* a
row, so that was paying about 20 cycles of string setup to move a single
byte, for every wall on the screen. A plain store plus a stride, unrolled by
two, is about half the cost. Full-width bands went the other way: rows are 80
bytes and the stride is 80, so a full-width rectangle is one unbroken block
and can be a single `REP STOSW` with no row loop at all.

Drawing went from ~76 ms a frame to ~47 ms, which made casting the bigger
half and sent the next round of work there -- see the section below, which
took another 14% off it. Where the frame stands now:

| | |
|---|---|
| `NODRAW` (casting only) | 29.4 fps, so ~34 ms |
| whole frame | 12.3 fps, so ~81 ms |
| therefore drawing | ~47 ms |

Drawing is close to memory bandwidth in mode X and there is not much left in
it: the screen is 16000 bytes, a contiguous `REP STOSW` moves one in about 7
cycles and a strided store about 18, and most of the frame is already the
cheaper of those.

### The walk was looping, and more time did not help

The tour is the point of the demo and it was **saturating**. The original went
straight until a wall stopped it, then turned right until something opened --
which is not a wall follower and does not explore. Measured: **22 cells of 256
in twelve seconds and 24 in thirty**. Tripling the run bought two cells.

It now walks cell to cell and picks the open neighbour it has visited *least*,
with a penalty on reversing. That cannot settle, because arriving somewhere
raises its count and makes it the least attractive way back, so the walk is
always pushed at the part of the maze it knows worst. Four comparisons a cell,
no queue and no stack.

| | old | new |
|---|---|---|
| 30 seconds | 24 cells | 30 |
| 60 seconds | -- | **65** |

**Linear in time rather than flat**, which is the property that was broken.
The default run is 30 seconds rather than 10 for the same reason: now that
longer runs see more, they are worth having.

**All of that was then outgrown by a bigger world -- see the next section.**
The rule above is a good LOCAL rule and it does not scale, which is worth
knowing before writing another one like it.

One tuning note that is easy to get backwards. Turning *while* moving cuts the
corner, and cutting the corner runs the camera into its own wall probe -- 44
of 85 cell choices were being thrown away and re-made. Pivoting on the spot
through the wide part of a turn dropped that to 9. It costs travel time at
every corner, so the turn rate is what decides how much of the maze a run
actually reaches; it is not a cosmetic number.

## A generated 64x64 maze, and a tour that seeks frontiers

The map was a hand-written 16x16 literal. It is now generated at 64x64 --
sixteen times the area, 2173 open cells against 116 -- and the tour that
walks it had to be replaced, because the greedy rule above stopped working
at that size rather than merely getting slower.

**64 is a ceiling, not a round number.** Positions are Q8 and held in an
Integer on purpose (a LongInt camera position put a 32-bit shift and AND in
every column of every frame). 64 * 256 = 16384, comfortably inside an
Integer; 128 cells would be 32768 and would not.

**The frame rate did not change.** 10.4 fps against 10.5 on the old map,
held over a ten-minute run: a
maze has short sightlines whatever its overall size, so the DDA still
averages 2.9 steps a ray. An open arena of the same size would not be free
-- it is the topology that is cheap, not the dimensions.

### Two things broke that a smaller map had been hiding

* **The DDA's side-distance compare was signed and had to become unsigned.**
  Side distances accumulate in a 16-bit register, and the worst case is a
  ray crossing the whole world (90 cells, 23040 in Q8) that then takes one
  step on the clamped axis: 23040 + 24000 = 47040. That is a positive Word
  and a NEGATIVE Integer, and `jge` on it steps the wrong axis for the rest
  of the ray. On 16x16 the sum could not reach 32767 whatever the maze
  looked like, so the signed compare was correct there **by accident of the
  size** and nothing in the code said so. `jae` costs the same. `DD_MAX`
  came down 32000 to 24000 in the same change, which is 93 cells against a
  90-cell diagonal -- it only has to be big enough that a near-axis ray
  leaves the world before that axis could step again.
* **The Y-step stride is unrolled.** `SIy = StpY * MAPW` was four `shl ax,1`
  for MAPW=16 and is six for 64. Nothing can check that, so there is a
  `{$IF}` in front of `CastColumn` that refuses to build if `MAPSHIFT`
  changes. Unrolled and not `shl ax,cl` because a shift by CL is ~8 + 4 per
  bit on an 8086: 32 cycles against 12, for two bytes of fetch.

### The tour: greedy locally, flood fill globally

The greedy rule picks the least-visited open neighbour. When it has nothing
unseen adjacent, the walk flood fills (breadth-first, over open cells) to
the nearest cell it has not seen this sweep and follows the route there.

**AND IT IS WORTH ALMOST NOTHING, WHICH IS NOT WHAT THIS SECTION SAID
FIRST.** `NOSEEK` turns the fill off and leaves the old rule on its own, so
the two run in one binary on one maze. That switch exists because the first
draft claimed a 42-to-154 improvement for the flood fill that **was not the
flood fill at all** -- the 42 came from an earlier build that also carried
the overshoot bug below and a slower walk, so three changes were being
credited to one of them, and the comparison was against a different binary
on a different maze. Measured properly:

| | 60 seconds | 10 minutes |
|---|---|---|
| greedy only (`NOSEEK`) | 154 of 2173 | 1261 |
| frontier seeking | 154 | 1300 |

**Nothing at one minute and 3% at ten.** The least-visited rule grades on
the visit COUNT, and that gradient turns out to be a decent global heuristic
on its own: it keeps pushing at whatever the walk knows worst, so it rarely
needs rescuing.

**It is kept, and the reason is not the 3%.** The greedy rule has no
termination property -- when the last unseen cell is across the maze,
nothing in a four-neighbour comparison can aim at it, so a `NOSEEK` run
cannot finish a sweep and the `full sweep` line can only ever say "not
completed". The fill can. That claim is **reasoning and not measurement**:
both runs above stop around 58%, which is well short of the endgame where
the difference would have to show, and a run long enough to reach it has not
been done. Treat the completion guarantee as untested until it has.

**It is not run every cell, and that is a cost decision.** A full fill is
~2000 open cells at four neighbours each, which `BENCH`'s 11 us per loop
iteration puts at about 80 ms -- one whole frame. Cheap at the 124 times a
ten-minute run actually needs it; ruinous at the three times a second the
walk chooses a cell. The counter is in the report (`flood fills : 124`) so
the assumption is visible rather than inferred.

Scratch for it is on the heap, not in DGROUP: three arrays of one entry per
cell is 16 KB on top of the ~40 KB of angle and texture tables already
there, and the heap has half a megabyte.

`Visited` holds the SWEEP NUMBER a cell was last walked in rather than a
count, so finishing the maze is one increment of a generation counter
instead of a pass that clears 4096 bytes. That matters because the coverage
report wants to know what was EVER reached, and clearing would throw exactly
that away. A tour that reaches the last cell starts another sweep rather
than stopping -- a demo standing still looks identical to a demo that
crashed, and over the bridge nobody can see which.

### The overshoot, and why going faster made it worse

The tour is locomotion-bound, not decision-bound: a cell costs 256/PERSEC to
cross plus 256/TURNSEC to turn through a right angle, and in a *generated*
maze almost every cell is a corner where the old hand-drawn map had long
straight corridors. So both constants went up, 700 to 1150 and 640 to 1400.

That made it **worse**, and the way it got worse is the diagnosis:

| | cells chosen | re-chosen at a wall |
|---|---|---|
| PERSEC 700 | 87 | 24 |
| PERSEC 1150 | 108 | **48** |

Arrival is tested as "at or past the centre", so a step lands up to a whole
step BEYOND it -- 0.45 of a cell at that speed and this frame rate. If the
next move is a turn, that is a camera sitting a third of the way into the
wall it is turning away from, the probe refuses to move, and the cell is
chosen again from a position it can never leave. **The faster it walked the
worse it got, which is the signature of a per-step overshoot rather than of
the speed itself.** Clamping the step to the distance remaining makes
arrival exact at any speed, and took re-choosing to **zero**.

Two more things moved with it. Pivoting now continues until the heading is
within 17 degrees rather than 56, because a carved maze turns at nearly
every cell. And braiding -- knocking interior walls back out after the carve
-- went from 16% to 25%: a recursive backtracker makes a PERFECT maze, one
route between any two cells, which is the wrong shape for something whose
job is to be walked and looked at. Every junction is a fork into a dead end
and the view is a wall two cells away in every direction. A braided wall is
also a straight run, so it buys back pivot time as well as making loops.

### The camera walked faster the faster it rendered

Found while trying to A/B the walk with `NODRAW`, and it is why that
comparison had to be thrown away and re-run: **398 cells with `NODRAW`
against 154 with the drawing left in**, over the same 60 seconds on the same
maze, for a walk whose entire design is that it is paced by the BIOS tick
and not by the frame count.

One line, and it had been there since the walk was written:

```pascal
if DTicks < 1 then DTicks := 1;      { Now - Last, in BIOS ticks }
```

The BIOS tick is 18.2 a second. **Below that rate the clamp never fires**,
because every frame spans at least one tick -- and this renders at about
ten, which is why it survived. Above it, `Now - Last` is frequently 0, the
clamp turned that into a whole tick, and the camera took a full tick of
movement on every frame: the tour walked at the FRAME rate rather than at
`PERSEC`. It is `if DTicks < 1 then Exit` now, so motion happens 18.2 times
a second however many frames are drawn.

Two things generalise:

* **It lived exactly where it would be quoted.** `NODRAW` and `NOCAST` are
  the measurement modes, they are the only things here that run above 18
  fps, and so they were the only place it could ever show. A correctness bug
  scoped to the diagnostic path is worse than one in the main path, because
  its output is what gets written into notes like this one.
* **Fixing it broke the thing it had been hiding.** With the walk correctly
  paced a `NODRAW` frame moves nothing on 99% of frames, so the pivot cache
  hands back the previous columns and the loop reaches **2083 fps casting
  nothing at all** -- an honest number and a useless one. `NODRAW` now turns
  the pivot cache off and casts every frame, which is what the figure meant
  historically anyway, back when the clamp was moving the camera on every
  frame by accident. It reads 41.6 fps.

The check that it is fixed is the one thing that must not depend on the
frame rate: **2.5 cells a second at 41.6 fps against 2.57 at 10.4.**

### The maze is generated, so SEED is the whole description of it

4096 characters of literal is not something anyone can check by eye, and a
generator gives a different world out of the same binary for free -- which
is what makes a performance number reproducible AND lets a bad case be
re-run. The seed is reported with the results. Note the value reported is
the seed AS GIVEN and not the live LCG state, which the carve has advanced
a few thousand times by then: a reported seed that does not reproduce the
maze is worse than not reporting one.

## A fault suspected in the pivot cache, and not found

Worth reading whole, because the argument for the fault is a good one and
will occur to the next person too -- and because acting on it shipped a
3.4% regression, briefly, to fix something that measures as absent.

**The report.** From somebody at the keyboard driving with `KEYS`: *"the
rendering is kinda funky when we are not at perfect 90 degree angles --
walls and stuff like corners render really strange looking."*

**The argument.** The cache shifts six column arrays, and they do not hold
rays. They hold heights, extents, texture offsets and texel steps, every one
of which comes through

```
Perp = RayD * ColCos[X]
```

and **`ColCos` is indexed by SCREEN COLUMN** -- it is the fisheye correction
for how far that column sits off the centre of view, running 256 in the
middle down to 225 at the edges (Q8, cosine of 28 degrees). The world ray
really does move from column `X+K` to column `X`, and its offset from the
middle of the screen changes when it does. So a cached column looks like it
must be carrying a height computed with `ColCos[X+K]` into a place where
`ColCos[X]` applies: up to 12% wrong, across half the screen, every time the
camera turns on the spot. That predicts the reported symptom exactly --
face-on every column is nearly the same height and 12% is invisible, while
on an oblique wall it bends the perspective.

**The measurement says no.** Camera turned 90 degrees on the spot in a
corridor then held still, so every column on screen came out of the cache
and none was re-cast (`1952 of 2160 reused`):

| | |
|---|---|
| `ColTop` and `ColBot`, cached against freshly cast | **identical, all 80** |
| ASCII thumbnail | byte-identical |

`ColOfs` differed by a constant 8 in every column, which is the texture heap
block landing at a different offset within its paragraph between two runs --
not a rendering difference, and the identical thumbnails confirm it.

So the argument is wrong somewhere and **the flaw in it has not been
found.** The cache is back on by default; `NOPIVOT` disables it, and that
stays because it is the only one-command A/B available to somebody who can
actually see the screen.

### The instrument built to settle it is NOT validated

`PIVCHK` re-casts every column from the camera state a run ended in and
reports how far the frame had drifted. No confound in it -- it compares a
frame against a re-cast of itself rather than against another run. `PIVBAD`
mis-shifts by one column on purpose so that `PIVCHK` can be shown to catch
something.

**`PIVCHK` read zero for `PIVBAD` as well**, which does not mean the cache
is sound; it means the reading was saturated. Every scripted viewpoint tried
ended with the camera close to a wall, where the perspective divide gives a
height over 200 and **every column clips at row 0**, so no difference can
show. A per-column dump reading `0 0 0 0 0 0 0 0 0 0` is what exposed that
-- the headline number on its own would have been quoted as a null result.

If this is picked up again: get a viewpoint looking down a long corridor at
an oblique angle, and require `PIVBAD` to read **non-zero** there *before*
putting any weight on the cache reading zero. Same rule the frame-stall work
had to learn -- a measurement is worth nothing until the instrument has been
shown able to fail.

### What the symptom is: SEEN, on the real screen

Settled on 2026-09-05 by pointing the capture card at it -- which is what
that feature is for, and the first time anybody could look at this from
Windows rather than at an ASCII thumbnail.

**Mode X casts 80 rays across 320 pixels, so every ray paints a column four
pixels wide.** Head-on that is invisible, because neighbouring columns are
the same height. Obliquely the depth changes fast across the screen, so the
wall becomes a **four-pixel staircase** -- and in the captured frame it is
plainly there: the top edge of every oblique wall steps in 4-pixel jumps,
and each mortar line is broken into 4-pixel segments rather than running as
a straight diagonal. The step size matches the ray width exactly.

That is a resolution artifact, not a bug, and it is consistent with the
pivot-cache measurement above rather than an alternative to it.

**`COARSE` is only half an A/B, and the reason is a hard coupling in the
source.** It halves the column to 2 px and the geometry edges do visibly
smooth -- but `raycast.pas` line 3542 reads

```pascal
if not UseX then Textured := False;
```

and `COARSE` sets `WantX := False`. So a `COARSE` frame is **flat-shaded and
always will be**: it can show the wall-edge half of the symptom and can never
show the texture half. Comparing the two and concluding "textures look
different" would be reading a code path, not a rendering difference.

Doing this properly needs textures at 2 px a column, which today is not a
switch -- it is lifting the mode 13h restriction on the texture blitter.

## Driving it: `KEYS`, `PLAY`, and `starter/demos/kbd.pas`

`RAYCAST KEYS` puts a person at the controls -- W/S or the arrows to move,
A/D to turn, Q/E to strafe, Shift to run, Esc to quit.

**The BIOS key buffer cannot do this job, and that is not a performance
argument.** Every tool here that has wanted the keyboard so far wanted a
KEYSTROKE -- one answer to one question -- and INT 16h serves that perfectly
well. A camera wants key STATE: walking forward while turning left is two
keys held at once, and the BIOS offers neither fact. It offers a queue of
characters, gated by the typematic delay (about half a second before a held
key repeats at all) and with no concept of a release. Drive a camera from it
and the first half second of every movement is one lurch and then a pause,
which reads as a dropped frame rather than as input.

So `starter/demos/kbd.pas` hooks INT 9 and keeps a byte per scancode. The handler
is four instructions; everything careful in the unit is about giving the
vector back.

* **It chains rather than handling the keyboard itself.** Not chaining is
  less code and it is tempting. It also means acknowledging the keyboard
  controller by hand, and the correct acknowledgement differs between XT and
  AT class machines -- get it wrong and the keyboard is dead until somebody
  power cycles the box, which here means somebody walking to it. The BIOS
  already knows which machine this is. Chaining also keeps the BIOS key
  buffer, the lock LEDs, and **the keyboard flags byte at 0040:0017**
  working -- which is where ScrollLock lives, and ScrollLock is how the
  agent loop is stopped.
* **`ExitProc` is hooked before the vector is taken.** Same rule as
  `NetClose` and `release_type`: what gets left behind is a far pointer into
  memory DOS is about to hand the next program, and the next keystroke jumps
  into it. An explicit call at the end of the main program covers the happy
  path, which is not the one that needs covering. The exit hook goes on
  first, so there is no window in which the vector is ours and nothing is
  arranged to give it back.
* **FPC's `interrupt` directive does the hard part**, verified against the
  generated assembly rather than assumed: it saves ax bx cx dx si di ds es,
  **loads DS from DGROUP** -- which is the trap that makes hand-written
  handlers hard, and what `pktcap.pas` has to patch by hand -- sets up BP,
  and ends in IRET.
* **The chain is `call far [P]` through a `Pointer`, not through two Words.**
  It reads four contiguous bytes as offset-then-segment. Two separate Word
  variables read as the same thing and are not guaranteed to be laid out
  adjacently.

### `PLAY`: the same movement code, tested with nobody at the keyboard

An interactive mode that only a person can exercise is one that is verified
by hope. So the keyboard and a script file fill in the **same array of
intentions**, and the movement code cannot tell which:

```
dosexec "C:\TOOLS\RAYCAST.EXE PLAY C:\WORK\WALK.TXT SECS 20"
```

`starter/demos/mkwalk.py` writes one: `python mkwalk.py S2 E6 S6 E4` emits the
timed events for "south two cells, east six, south six, east four". Verified
on hardware -- the camera walked exactly that route, 19 cells, and stopped
on its own `+QUIT`.

**A script asks for a HEADING, not for a turn key held down, and the frame
rate is why.** The obvious way to turn a corner in a timed script is to hold
RIGHT for as long as a right angle takes. It cannot be made to work: a turn
is applied once a FRAME, this renders at about ten frames a second, and
TURNSEC puts 70 angle units in each of them -- so a 256-unit right angle is
3.66 frames and lands anywhere up to **25 degrees** past where it was aimed.
Over the six cells after the corner that is most of a cell of drift and the
camera grinds along the wall. `+SOUTH` turns to an absolute heading using
the same short-way-round arithmetic the tour uses, and suppresses movement
while the swing is wide, for the same reason the tour pivots.

`mkwalk.py` derives its timing from `MOVESEC` and `TURNSEC` rather than
having numbers typed into it, because those two are the constants most
likely to be tuned again -- they changed twice while this was being written
-- and a script carrying the old ones does not fail. It walks into walls and
produces a plausible-looking bad tour.

### What is verified, what needed a person, and what froze

Over the bridge: the hook installs, the run completes, and `IVT 9` reads
back **the same `13F3:0045` it did before**, so the vector is given back.
The scripted path is verified end to end.

**The chain itself is not**, and cannot be from here: it only runs when a
key is actually pressed, and there is nobody at the machine. Every run from
Windows installs the hook and then never executes it once. Same shape as
`SCRLOFF`'s keyboard lamp, which also needed somebody standing there.

**`KEYS` froze the machine once at the keyboard**, hard enough to need a
reboot, and worked after it. Not reproduced. The handler is the suspect
precisely because it is the one path here the bridge cannot exercise. Three
things changed in response, and none of them is a fix:

* **The vector is taken one statement before the frame loop**, not before
  the table builds. It used to be live across half a second of texture
  baking, the palette load and the mode set, for no benefit at all. A hook
  is a liability for exactly as long as it is installed.
* **`Output` is flushed before anything that could hang.** All that was on
  screen after the freeze was the attribution banner, which says nothing
  about where it stopped -- FPC buffers `Output`, so everything printed
  after it was still in the buffer when the machine died. `vmodes.pas`
  already flushes every line for this exact reason and the lesson did not
  travel. There is now also a `maze built :` line between the builds and the
  mode set, so a stall has somewhere to stop: that line still showing means
  the palette, the unchain or the hook; a graphical screen means it reached
  the frame loop.
* **The read-then-chain order was left alone, deliberately.** Reading port
  60h clears the controller's output-buffer-full flag, and a BIOS that tests
  that flag before reading could decide there was nothing to do -- a
  plausible hang. Chaining first and reading afterwards avoids that and
  breaks differently: the BIOS talks to the controller for the lock-key
  LEDs, so the data register would hold an ACK rather than a scancode, and a
  controller that advances on the BIOS's read would put every key one
  behind. **The current order is observed working on this machine; the other
  is a theory.** Do not swap them without a machine in front of you.

## Where the drawing goes, and why it is a hard floor rather than a soft one

With casting in assembler, drawing is three quarters of the frame. `NOWALL`
and `NOBAND` split it -- both skip work while leaving everything else intact,
including the dirty-band bookkeeping, so the pieces add up:

| | ms | share |
|---|---|---|
| wall columns | **51.0** | 53% |
| ceiling and floor bands | 17.7 | 18% |
| cast, the column loop and the flip | 27.2 | 28% |

**The wall blitter is running at essentially 100% bus utilisation, and that
is measurable rather than asserted.** Counting which sampling path draws each
row:

| path | rows | share | bytes/pixel |
|---|---|---|---|
| one lookup per 4 rows | 238800 | 23% | 6.5 |
| one lookup per 2 rows | 515832 | 49% | 8.0 |
| a lookup every row | 298969 | 28% | 11.0 |

That weights to **9.1 bytes of instruction fetch plus 2 data accesses per
pixel**. The measured cost is 51.0 ms for 10229 wall bytes a frame, which is
4.99 us a byte -- divide by 11.1 bus accesses and it comes to **about 3.6
clocks each**, against the 8086's four-clock bus cycle.

So there is no slack left to find: the loop is not waiting on anything except
memory, and the only thing that would make it faster is fewer bytes. Every
instruction in it is already the shortest encoding that does the job, which is
why `XLAT` and the DS/ES choice mattered and why unrolling further does not
-- the extra stores need disp16 and give the saving straight back.

### Why the overdraw stays, with the arithmetic

The bands paint the whole dirty band and the walls then cover about 10229
bytes of it, so roughly 43% of all writes are painted twice. Removing that
looks obviously right and is **wrong**, because the two writes are not the
same price:

| | us/byte |
|---|---|
| band, full-width contiguous `REP STOSW` | 1.23 |
| wall, strided and textured | 4.99 |
| a strided, row-shaded fill (what exact painting needs) | ~8.2 |

| | |
|---|---|
| today: 12600 bytes contiguous | **15.5 ms** |
| exact: 2371 bytes strided and shaded | 19.5 ms |

Painting five times the bytes in one unbroken `REP STOSW` beats painting the
minimum in a strided loop. The contiguous fill is 6.7x cheaper per byte, and
that ratio is bigger than the 5.3x saving in area.

### What did move: runs of equal shade in the band

`RowShade` has 16 levels over 100 rows, so about six consecutive rows share a
colour -- and rows are 80 bytes with an 80-byte stride, so those six are one
unbroken block. Restarting `REP STOSW` per row cost about 21 us a row in
setup for nothing. Emitting one per RUN instead took the bands from 17.7 ms
to 15.5 ms.

`NOWALL` and `NOBAND` are kept as arguments. They render nonsense on purpose
and exist to be timed against.

## Casting in assembler: 22.0 -> 44.7 fps, and the 8087 stops being worth it

The drawing had been assembler for a while; `CastColumn` was still Pascal,
and at ~38 ms of a 110 ms frame it was the last big block of it. Converting
it in four stages, each measured:

| | cast | frame |
|---|---|---|
| Pascal, after the five wins below | 26.4 | 9.1 |
| texture setup in asm | 28.8 | 9.3 |
| DDA in asm | 32.0 | 9.6 |
| head merged into the same block | 34.7 | 9.9 |
| tail in asm (fisheye, divide, extents) | 38.8 | 10.1 |
| ...and the divide made 16-bit | **44.7** | **10.5** |

`FLAT` went **12.1 -> 16.3 fps** over the same work.

**Nothing in there is clever, and that is the point.** The gain is almost
entirely that Pascal keeps every local in BP-relative memory, so each step
stores its result and the next one loads it back. In assembler the two side
distances stay in AX and BX and the grid index in SI for the whole walk.
Merging the angle lookup, both initial side distances and the DDA into ONE
block was worth another 8% on its own, purely from not round-tripping
between them.

### The perspective divide was 32-bit for no reason

The integer path read `Integer((LongInt(SCR_H) * ONE) div Perp)`, and FPC
calls a software routine for that -- `BENCH` puts a 32-bit divide at
7280/sec, **137 us**. But the numerator is `200 * 256 = 51200`, which fits
in a word, and `Perp` is clamped to at least `PERP_MIN`, so the quotient
cannot overflow. A plain 16-bit `DIV` does it in about 90 cycles.

**That reverses the guidance in `hardware.md` about the 8087.** The
earlier measurement was honest and is still correct as far as it went: the
coprocessor beat a *32-bit software divide* comfortably. It does not beat a
*16-bit hardware divide* -- FILD, FDIVR, FISTP and FWAIT go through memory
in both directions and cost roughly 300 cycles against 90.

| | cast | frame |
|---|---|---|
| `FPU` -- 8087 | 38.8 | 10.1 |
| `INT` -- 16-bit DIV | **43.6** | **10.5** |

So the integer path is now the default and `FPU` is kept for the
comparison. The general lesson is the one these notes keep relearning: **a
measurement is only valid against the alternative it was measured against.**
Nothing about the 8087 changed; the thing it was being compared with got 15
times faster, and the conclusion inverted.

This matters well beyond this box, too. Most 8086-class machines have no
coprocessor at all and were taking the integer branch -- so they were paying
137 us a column for a divide that never needed 32 bits.

### Two traps in converting Pascal to asm here

* **IMUL owns DX**, so anything already in it is gone. In the merged block
  `SdX` is pushed on the stack across the second multiply because there is
  no spare register; the push/pop nests inside the SI/DI pair so the block
  stays balanced on every path.
* **FPC addresses locals and parameters through BP.** Every one of these
  blocks preserves SI and DI explicitly and never touches BP -- the one time
  that rule was broken, in the first texture blitter, it wedged the machine
  and needed a power cycle.

## Five optimisations that did land, 8.2 -> 9.1 fps

Run after the floor measurement below, which is why each one is small: the
easy factors were already gone. Every number is measured on the V30.

| | | cast | frame |
|---|---|---|---|
| | starting point | 22.0 | 8.2 |
| A | `-O2` into a **private unit directory** | 23.7 | 8.5 |
| B | video in DS, texture in ES | -- | 8.6 |
| C+D | no DDA bounds check; branchless texture flip | 25.4 | 8.8 |
| E | pivot cache | -- | **9.1** |

`FLAT` came along for the ride: **12.1 -> 13.5 fps**, and its cast went 28.6
-> 35.7. Texture setup in the cast is now 9.9 ms a frame.

**A. `-O2` is safe once the units are not shared.** The long-standing
objection was real -- `build/` is one unit directory, so optimised `vga`,
`cpu` and `net` `.ppu` files would be what `UGET`, `UPUT` and `TFTP` link
next, and a miscompile in those is the failure this project designs against.
Pointing one target at its own `-FU` directory removes the coupling instead
of the gain. `build.cmd` now does that for any target with a `<name>.o2` file
beside it; `raycast.o2` explains itself. Nothing else in `starter/` changes,
and deleting the file puts it back on the shared unoptimised units.

**B. Which segment register holds what is worth 1%.** A segment override is
one byte, and on an 8086 a byte of instruction fetch is a bus cycle, so the
question is only which operand appears more often. In the four-rows-a-texel
path there are four stores and ONE lookup -- so video goes in DS (stores lose
their prefix) and the texture in ES (`xlat es:[bx]` pays it once). 29 bytes
per four pixels down to 26. Note `mov [di],al` is DS:[DI]; only the string
instructions default to ES. FPC accepts `xlat es:[bx]` and rejects `es xlat`.

**C. The DDA bounds checks were dead weight, and took `MX`/`MY` with them.**
Every edge cell of `MAP` is a wall, so a ray always terminates on `Cell <> 0`
and the two range tests can never fire. `MX`/`MY` existed only to feed them,
so dropping the tests drops two increments per DDA step as well. `Guard`
still bounds the loop at 64 steps, which is what makes it safe rather than
merely likely -- and nothing in there writes through `Idx`.

**D. `255 - U` and `U xor 255` are the same thing for a byte.** Whether a
face is mirrored depends only on which way the ray steps, so it is a property
of the angle: hold it as a per-angle MASK rather than a flag and the flip is
an XOR with no branch, folded into the same `if Side` that already picks the
direction table.

**E. The pivot cache: +3.4%, and the estimate was twice the truth.** It was
later suspected of rendering wrong geometry and measured as not doing so --
read the section below before suspecting it again. The walk turns on the spot, so on
those frames the camera's POSITION is unchanged and a cast result is still
valid for the absolute angle it was taken at. Ray X's angle is
`Ang + (X - NRays/2)*RayStep`, so turning by `K*RayStep` makes ray X equal to
old ray `X+K` -- the frame becomes a shift of six column arrays plus `|K|`
newly exposed columns.

That is why `FOV` went from 170 to 160: the mapping is exact only when
`RayStep` is a whole number of angle units, and `Advance` snaps the turn to a
multiple of it. Snapping discards at most one ray of turn per frame, under
half a degree. `Move` is `memmove`, so the overlap is safe either way.

**Predicted 8%, measured 3.4%** -- because pivots turned out to be about 17%
of frames rather than the 40% the estimate assumed. The counter is in the
report (`columns cast : 7904, 816 reused`) precisely so the assumption is
visible rather than inferred.

## Where the textured frame's floor is, and four things that did not move it

Measured on the V30, and this is the point to start from before optimising
anything here again:

| | |
|---|---|
| casting, `FLAT` (`NODRAW`) | 28.6 fps -> ~35 ms |
| casting, `TEX` (`NODRAW`) | 22.0 fps -> ~45 ms |
| whole textured frame | 8.2 fps -> ~122 ms |
| therefore drawing | ~77 ms |

So texture setup in the cast costs **10.5 ms a frame, 131 us a column**, and
drawing is roughly 60% of the frame.

**Four attempts to reduce that measured as nothing at all**, and they are
worth recording because each looked obviously right:

* **Folding the bank index and the texture column into one offset.** Removes
  an array store from the cast and three array reads plus an add from every
  column of the draw loop. Result: **22.0 -> 21.7 fps**, slightly *worse* --
  because `bank * BANKSZ` where BANKSZ is 4160 is a real 16-bit multiply, ~17
  us, which costs more than the store it replaced. Tabling the bank offsets
  put it back to 22.0 and **exactly** 8.2 fps on the frame. Kept only because
  one array and one heap block are simpler than two and eight, not because it
  is faster.
* **`-O2`.** +7% on the cast, +4% on the frame, declined -- the gain is in the
  shared units and `build/` is one unit directory, so it would follow into
  `UGET`/`UPUT`/`TFTP`. See the section below.
* **A smaller memory model.** `-WmSmall` is 28% less code and measures
  identically.
* **A full-assembler draw loop** replacing the 80 per-column calls. Measured
  before writing it, by adding a second blitter call per column with `Rows=0`
  so it returns immediately: **8.2 -> 8.0 fps, so 38 us a call and 3.05 ms a
  frame -- 2.5%.** Not worth an asm rewrite of the whole loop, and knowing
  that cost 40 seconds instead of an afternoon.

The lesson that keeps repeating: **`BENCH`'s per-operation figures do not
predict the marginal cost of an operation inside this code.** Four times now,
removing something `BENCH` prices at 15 us has changed nothing. Measure the
specific change, by adding the work if that is easier than removing it.

**What is actually left**, in case someone wants it later: not re-casting
during a pivot. The camera does not move while it turns on the spot, so a
cast result is still valid for a given absolute ray angle; with `FOV` made
divisible by `NRays` a rotation of one ray-step would shift the column arrays
instead of re-casting them. Estimated at about 8% of the frame, and it needs
an FOV change, angle snapping and a `REP MOVSW` of six arrays. Not obviously
worth it, and unmeasured -- which after the four results above is exactly the
reason not to trust the estimate.

## Distance fog, and why the floor is not textured

Fog costs **0.2 fps of 8.4** and is the largest visual improvement left. It
works because nothing about it happens per pixel:

* **Walls** select one of 8 pre-baked banks -- 2 wall types x 4 distance
  bands -- so the blitter reads a different bank and does no shading
  arithmetic at all. The wall's facing folds in as one extra step of
  darkening, so a far wall and a side-on near wall can land on the same bank.
* **Floor and ceiling** take a colour per ROW from a table. A row below the
  horizon is a constant distance from the camera, so `RowShade` depends only
  on the geometry and is built once. Rows are 80 bytes and the stride is 80,
  so `REP STOSW` walks straight through the band and never restarts; the
  only per-row cost is a table lookup and a fresh CX.

One call does each whole band, because 200 Pascal calls a frame at ~30 us
each would cost more than the gradient does.

**The banks moved to the heap.** Eight of them is 33 KB and the data segment
already holds ~40 KB of tables. The blitter has always taken a segment and an
offset rather than a Pascal pointer, so `GetMem` costs nothing here and takes
the 64 KB ceiling off the bank count entirely -- with 540 KB free there is
room for many more.

Two details that are easy to get backwards:

* **Scale both ends of each ramp, not just the top.** Fading only the
  highlights makes a distant wall look washed out rather than dim; the
  mortar has to stay dark at every distance.
* **Compares, not `Perp shr 9`, to pick the band.** A shift by CL is about
  44 cycles on an 8086, and across 80 columns that is more than the whole
  gradient is worth. Three compares cost a handful.

### Textured floors and ceilings are NOT affordable, and here is the sum

This is the obvious next step and it does not work on this class of machine.
A floor needs a **2D** texture coordinate, so the inner loop carries two
accumulators and builds the index out of both high bytes:

```
mov bh,dh / mov bl,ch / mov al,es:[bx] / mov ds:[di],al
inc di / add dx,ustep / add cx,vstep / cmp di,end / jne
```

That is about **24 bytes a pixel against 7.25 for a wall**, over roughly
twice as many pixels (16000 of floor and ceiling against 8000 of wall). Call
it six times the current wall drawing -- around 400 ms a frame, so about 2
fps. Which is why Wolfenstein 3D shipped flat floors on a 286 and only Doom,
on a 386, textured them.

### The thumbnail broke, and it broke in the documented way

Once the bands became 16-level gradients, all three surfaces had brightness
ramps, and mapping them all by brightness put walls, floor and ceiling on the
same ASCII characters. The picture came back as a field of noise with no
readable geometry -- **exactly** the failure `SCROLLER.md` describes.

The fix is the rule that section already states: rank by **depth order
first**, then by gradient within each surface. Ceiling gets ramp slots 0-1,
floor 2-3, walls 4-9. The fog is then visible in the thumbnail itself -- a
near wall reads `#`/`%` and a distant one `+`/`*`, which is how the whole
feature was verified over the bridge in the first place.

## Textured walls, and why XLAT is the instruction that matters

`RAYCAST` draws textured walls by default; `FLAT` gets the old solid
colours back for comparison. Four 64x64 banks -- two wall types, each baked
lit and shaded -- generated procedurally at startup so there is no art to
ship. Measured on the V30 over the same 30-second tour:

| | fps |
|---|---|
| `FLAT` | 12.1 |
| textured, first working version | 6.7 |
| textured, tuned | 8.4 |
| **textured + distance fog** | **8.2** |

**The texture is stored COLUMN-MAJOR, and that is the whole design.** A wall
slice reads one texture *column* top to bottom, so transposing the data makes
those 64 texels contiguous; the inner loop then reaches any of them with a
single byte index. Row-major would need a multiply or a 64-byte stride per
texel, in the hottest loop in the program.

### On an 8086 the figure to shrink is BYTES per pixel, not instructions

The bus is the limit and **instruction fetch competes with data** for it, so a
shorter encoding is faster even at equal instruction count. That is what makes
`XLAT` the right instruction here: it is **one byte** for the whole table
lookup, against four for a `mov` with a base+index operand.

| | fps | |
|---|---|---|
| `mov bl,dh` / `and bl,63` / `mov al,[bx+si]` | 6.7 | 4 bytes for the fetch |
| `mov al,dh` / `xlat` | 7.4 | **1 byte**, +10% |
| ...unrolled to four, row stride in the store displacement | 7.8 | +5% |
| ...sampling the texture less often on near walls | **8.4** | +8% |

### Sample the texture as often as the wall is magnified, not once a row

A slice stretches `TEXH` texels over however many rows it covers, so a near
wall already shows each texel several rows deep and sampling per row is
repeated work. `VStep` is texels-per-row in Q8, so it states the
magnification directly and the blitter picks a rate from it:

| `VStep` | | sampling | bytes/pixel |
|---|---|---|---|
| <= 64 | 4+ rows a texel | one lookup per **4** rows | 7.25 |
| <= 128 | 2+ rows a texel | one lookup per **2** rows | 8.5 |
| else | | every row | 11.5 |

The stores cannot go -- one byte a row, 80 apart -- but the `XLAT` and the
accumulate can be shared, and those are three fetched bytes each. All three
paths share one remainder loop so each can assume a multiple of four.

Sampling at the top of a group rather than the middle can put a texel
boundary one row early. At 2x magnification or more that is invisible, and
it is close to what nearest-neighbour produced anyway.

**The stores are now most of what is left.** Per four pixels the bulk loop is
17 bytes of stores against 3 for the lookup, and the alternatives measure no
better: stepping `DI` between stores costs more than the disp16 on the third
and fourth, and `XLAT`'s one-byte encoding only works against `DS`, so the
video segment has to be the one carrying the override.

The texel index is deliberately **not masked**. The arithmetic lands on
exactly 64 at the bottom row of an unclipped slice, so the worst case reads
the next column's first texel into the last row -- one pixel, invisible --
and each bank is padded by `TEXH` so even the last column stays in bounds.
Masking cost 4 cycles and 3 bytes on every pixel to prevent that.

### Two things that are NOT divides

* **The texel step needs no divide.** `VStep` is `TEXH*256/Hgt`, and `Hgt` is
  `SCR_H*ONE/Perp`, so the two cancel: `VStep = Perp * 0.32`, one multiply.
  A second divide per column would have cost more than the whole blitter
  tuning bought back.
* **The texture coordinate needs the PRE-fisheye distance.** `Pos + RayD*Dir`
  is the hit point only while `Dir` is a unit vector and `RayD` is measured
  along the ray. Using the corrected distance bends the texture towards the
  edges of the screen.

### What it costs, and where

| | flat | textured |
|---|---|---|
| casting | ~34 ms | ~44 ms |
| drawing | ~47 ms | ~84 ms |

Casting grew because the cast now writes four more arrays per column, and
`BENCH` puts an array store at 14.6 us -- four of them across 80 columns is
~4.7 ms before any arithmetic. Drawing grew because **run coalescing is gone
and cannot come back**: adjacent columns sample different texture columns, so
every run is one ray wide by definition. That is why the coalescing is still
there on the `FLAT` path and why the two paths are kept side by side.

### The bug that wedged the machine

The first version hung the box hard enough to need a power cycle. **FPC
addresses procedure parameters through BP**, and the blitter loaded `VStep`
into BP before it had read `TOfs` and `TSeg` -- so those two came from
whatever the stack happened to hold. Nothing warns. Every parameter is now
read before BP is touched, and the comment there says so.

Worth pairing with the other trap from the same session: **`InC` IS `Inc`.**
A loop variable named `InC` shadows the built-in, and `Inc(L, 2)` two lines
later stops compiling. That one failed loudly; the BP one did not. Pascal
being case-insensitive has now cost two names in one file -- see also
`DdX`/`DDX` below.

### EMS would not help, and neither would a smaller memory model

Both were asked and both were measured or reasoned to nothing:

* **EMS.** The whole texture bank is 8 KB against 540 KB free, so there is
  nothing to page out. EMS is a capacity mechanism: data sits behind a 16 KB
  window and anything outside the mapped page needs an `INT 67h` remap
  costing hundreds of cycles. The texture fetch is the innermost instruction
  in the frame.

  A **Lo-tech 2 MB ISA card** was fitted on 2026-09-04 and worked -- `MEM`
  reported 2,048 KB total and free, at a cost of 5 KB of conventional
  memory for the driver. It changed nothing about the frame rate and was
  not expected to.

  **It is GONE, removed 2026-09-08, and the reason has nothing to do with
  memory.** The board sat at I/O 0260, which is the CH375 USB card's base
  address, and the two fought: the CH375 read back `FF` and the packet
  driver's receive buffers filled with it. `LTEMM` went with it, because it
  probes 0260 and finds the CH375 instead. Put both back together or
  neither -- and if EMS is ever wanted alongside the USB adapter, one of
  them has to move off 0260 first. Where it *would* earn its keep is content: many more wall
  types, plus floor, ceiling and sprite art, paged at **wall-type
  granularity** -- a handful of `INT 67h` switches a frame rather than one
  per pixel, which is affordable. Capacity, not speed.
* **The memory model.** `-WmSmall` is 28% less code than `-WmLarge` (44346
  against 31697 bytes) and measured **identically** -- 29.6 against 29.8 fps
  on the cast, 12.3 both on the frame. FPC keeps `DS` on the data segment
  either way, so "far data" costs nothing for direct global access.

## The cast loop: a far call cost 29.5 us, and there were four a column

With drawing halved by the page-flip work above, casting became the bigger
half of the frame and the question was what it actually spends its time on.
80 rays at ~2.8 DDA steps each is not much arithmetic, so the ~485 us a ray
had to be going somewhere else.

**The measurement that answered it was a deliberately wasteful one.** Rather
than reason about the cost of a call, add one: a fourth `MulQ8` per column,
its result parked in a global so nothing optimises it away.

| | cast fps |
|---|---|
| as it was | 27.7 |
| with one extra call a column | 26.0 |

2.36 ms a frame across 80 columns, so **29.5 us for a single call** -- more
than BENCH's 21.5 us for a bare procedure call, which is what a far call in
the large model with two parameters and a return value costs.

There were four such calls per column: two for the initial side distances,
one for the fisheye correction, one for the perspective divide. Writing all
four out where they are used:

| | cast | frame |
|---|---|---|
| calls | 25.8 fps | 11.5 fps |
| written out | **29.4 fps** | **12.3 fps** |

14% off casting, 7% off the frame, and **no compiler flag involved**. Note the
saving is about half what 4 x 2.36 ms predicts: staging operands into locals
for the `asm` block gives some of it back. Predicted savings from a per-call
cost are an upper bound, not an estimate.

**FPC will not inline an assembler routine, and it tells you so.** Marking
`MulQ8` as `inline` produces `Call to subroutine ... marked as inline is not
inlined` and byte-identical output. Believe the note.

### Two traps in writing it, one of which cannot bite twice

* **A local called `DX` is unreachable from an `asm` block.** The assembler
  resolves the name as the register, and nothing warns. The locals here are
  `RdX`/`RdY` for that reason.
* **Pascal is case-insensitive, so `DdX` *is* `DDX`.** The obvious rename
  collided with the `DDX`/`DDY` reciprocal tables and shadowed them into a
  plain Integer. That one failed loudly -- `Illegal qualifier` on `DDX[RA]`
  -- but only because the shadowed thing was indexed. A shadowed scalar would
  have compiled and quietly read the wrong variable.

### Two changes that measured as nothing

Recorded because both looked obviously right:

* **`Inc(Idx, SY * MAPW)` is not a multiply.** It reads like one in the
  hottest loop in the program, and hoisting it into a per-angle table changed
  the frame rate by nothing at all. `MAPW` is 16, so the compiler had always
  been emitting a shift. Reverted. Check the constant before optimising the
  operator.
* **`-O2` is real but was declined.** Measured: +7% on casting, +4% on the
  frame; `-O3` was no better and produced a bigger binary. `build.cmd` passes
  no `-O` at all, so everything in `starter/` is unoptimised.

  It was not adopted because **the gain is in the shared units, not in
  `raycast.pas`** -- pinning it to the one file with `{$OPTIMIZATION LEVEL2}`
  measured identically to no directive. Optimising the units means `vga`,
  `cpu`, `about` and eventually `net` compile through an optimiser none of
  them has been through, and `build/` is one shared unit directory, so those
  `.ppu` files are what `UGET`, `UPUT` and `TFTP` would link next. Those are
  the programs the box needs in order to be reachable at all; they are I/O
  bound, so there is nothing there to win, and a miscompile in one of them is
  the failure this project designs against. 4% of a demo's frame is not worth
  buying with that.

  Worth knowing separately: **`{$OPTIMIZATION LEVEL2}` placed after the
  `program` header does nothing and says nothing.** Byte-identical output. It
  is a global switch and has to precede the header -- and even correctly
  placed it only covers that one file, which is what the measurement showed.

## Mode X: the earlier step, and two orderings that bit twice

`RAYCAST MODEX` unchains the display. With the map mask at `$0F` one byte
write paints four horizontal pixels, so the full-screen band clear -- measured
as the floor of the mode 13h version at 78 ms -- becomes 16000 writes instead
of 64000, and a four-pixel wall column is one byte a row instead of four.

Measured on the V30:

| | |
|---|---|
| default, 160 rays, mode 13h | 4.1 fps |
| `BLOCKY`, 80 rays, mode 13h | 5.5 fps |
| **`MODEX`, 80 rays, unchained** | **8.6 fps** |

2.1x, not the 3x the write count suggests -- the per-byte cost does not vanish
just because each byte covers more pixels, and casting is untouched at ~40 ms.

The four registers are set in `raycast.pas` rather than reusing `modex.pas`,
which hardwires the scroller's 1024-pixel virtual screen. Parameterising that
unit would put its verified 70 fps at the mercy of edits made for a demo
running at eight. `XEnter` reads all four back: a card that ignores one leaves
a picture that is *skewed* rather than absent.

**`VSHOT` cannot photograph an unchained mode**, so the ASCII thumbnail reads
back through Read Map Select -- `XPeek` picks the plane with `X and 3`. Without
that there would be no way to tell a working renderer from a broken one over
the bridge, which is the whole reason the thumbnail exists.

**The same ordering mistake was made twice, and is worth naming.** Both times
a value was consumed before the thing that decides it had run:

* The header printed `video : mode 13h -- unchain refused at check 0` with all
  four readbacks reading zero. `XEnter` had not run yet: the banner is printed
  before the mode is chosen. The report belongs with the results, not the
  header -- it is an outcome, not a setting.
* `NRays` was forced to 80 inside `BuildColumns`, gated on `UseX`. But
  `BuildColumns` runs long before the card is asked to unchain, so the guard
  read a `UseX` that was still False and the demo drew two-pixel columns
  through a four-pixel blitter. Now forced where the argument is parsed.

Both printed or produced something plausible rather than failing, which is why
neither was obvious. If a flag is set by a probe, check what has already
consumed it.

**There is no `Has186` fast path in it, and that is a consequence rather than
an oversight.** The extension that would matter is the shift by an immediate
count, worth about 11% by `BENCH` (206260 against 185021) -- on an operation
this program deliberately never performs. Q8 scaling is a byte shuffle, screen
offsets are computed once per rectangle rather than per pixel, and the fill is
a string instruction. Designing the 32-bit arithmetic out took the 186 case out
with it. `CpuName` is still reported, because knowing what it ran on is the
point.

## What the music actually costs, and the PC speaker

The AdLib is the obvious suspect when a demo is choppy, and on this one it is
innocent. Measured on hardware, same maze, same 30 seconds:

| | fps |
|---|---|
| `QUIET` -- no music at all | 11.2 |
| AdLib playing | **11.1** |

**0.1 fps, under 1%.** A note event is about 0.8 ms of register writes and
there are only a couple a second against an 83 ms frame.

The intuition that it must be expensive is right about the mechanism and right
about the *scroller*, where the notes below record music costing a whole
sprite. The difference is the frame budget: at 70 fps a frame is 14.27 ms, so
0.8 ms is 5.6% of it **and** going over pushes the frame across a retrace
boundary, where the cost is not 6% but half the frame rate. The raycaster
waits for no retrace and has an 83 ms frame, so the same absolute cost is six
times smaller in relative terms and has no cliff to fall off. **Ask what
fraction of the frame it is, and whether anything quantises the frame.**

Also worth knowing before reaching for one: **a Sound Blaster would not help.**
Its FM synthesis *is* an OPL2/OPL3 at the same ports 388h/389h, so it is the
same cost to the byte. Only its DMA digital audio is cheap, and that needs
sample data and a DSP.

`RAYCAST SPKR` plays through the PC speaker instead, and that is the automatic
fallback when no OPL2 answers -- which matters because most 8086-class
machines have none and were getting silence. It is about **availability, not
speed**: four OUTs with no mandated delay against nine register writes each
needing a settling wait, roughly a hundred times cheaper per note, and none
of that is worth 0.1 fps.

The catch is real. The speaker is one voice, the theme is three, and the
tritone that makes it sound like a mystery is an interval *between* two of
them -- something a monophonic device cannot state at all. What it plays is a
reduction: the melody where there is one, the chromatic walk where there is
not. Recognisably the same tune, not the same effect.
