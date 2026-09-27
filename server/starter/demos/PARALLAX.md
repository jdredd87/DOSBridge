# NEON DRIFT

**A mode X parallax demo with an OPL2 soundtrack, for an 8086.**

Two hovercars race across a neon grid floor, under a synthwave sun, in front
of a city skyline. Thirty seconds by default.

```
dosrun starter/PARALLAX.EXE                 30 seconds, everything on
dosrun starter/PARALLAX.EXE SECS 90         run for 90
dosrun starter/PARALLAX.EXE SECS 10 PROF    ten seconds, with the frame breakdown
```

Measured on the NEC V30 box (8086-class, 8 MHz) on 2026-09-21:
**33.6 fps, locked to two vertical refreshes a frame**, band repaint 11.7 ms.

**The single biggest cause of visible jerkiness here was not the frame rate.**
It was the Attribute Controller's pixel pan being latched one refresh later
than the start address it belongs with, so every fourth frame -- the pan's own
period -- the whole far layer jumped four pixels and snapped three back. See
*The pan and the start address* below.

Three more things that make motion read as jerky even at a steady frame rate,
all fixed here:

* **A layer moving slower than one pixel a frame stutters.** The far layer ran
  at 0.22 px/frame, accumulated in 64ths -- so a 320x136 bitmap held still for
  four frames and then jumped a pixel, eight times a second. Mode X pans at
  one-pixel granularity and no finer, so the smoothest slow speed available is
  exactly one pixel a frame, not less.
* **A full-width line that can only be on a row or not on it lurches.** The
  depth lines advanced fast enough to cross a row boundary about four times a
  second, and near the horizon one phase step carries a line several rows at
  once. Slowing it does not make the jump smaller, but it makes it rare enough
  to read as the floor arriving rather than as the picture stumbling.

## What it is

| | |
|---|---|
| video | mode X, 320x200x256 unchained, 1024-pixel virtual width |
| split | CRTC line compare at display row 164 |
| sound | four voices on an OPL2 at 388h -- on this machine, the one a PicoMEM 2 emulates |
| sprites | two 24x12 hovercars, hand-drawn, in the band |
| coprocessor | used if it is fitted **and** wins a race against the integer path |

## The parallax is real, and that is the point

`starter/demos/scroller.pas` says, correctly, that its parallax is fake: one CRTC
start address moves the whole screen, so a single bitmap scrolls at a single
rate, and all the depth there comes from sprites.

This demo gets genuinely independent layers out of the same hardware by
splitting the screen with the CRTC **Line Compare** register:

| display rows | what happens | what is in it |
|---|---|---|
| 0..163 | address counter starts at the Start Address, so it **scrolls** | sky, stars, sun, mountain ridge, city -- 1 px/frame |
| 164..199 | line compare resets the counter to 0 mid-frame, so it is **pinned** | the grid floor, repainted every frame |

Because the band is repainted rather than scrolled, **every one of its 36 rows
can move at its own rate** -- and that is not an effect, it is the geometry. A
vertical line in the world at distance `z` lands on screen at an offset
proportional to `1/z`, and for a flat floor `1/z` is proportional to
`(row - horizon)`. So row `d` moves at a speed proportional to `d`:

```
horizon row   0.70 px/frame         23 px/s
bottom row    4.8  px/frame        160 px/s
far layer     1    px/frame         34 px/s
```

Two dozen distinct rates on the floor, plus the far layer above the split,
plus two cars weaving against each other. The ratio between the fastest floor
row and the far layer is about five to one.

## Memory

Per plane, 256 bytes a row at a 1024-pixel virtual width:

```
VRAM rows   0.. 35   the pinned band, columns 0..319 only
VRAM rows  36..199   the far layer, all 1024 columns
                     36 + 164 = 200 rows = 51200 bytes
```

That is exactly one mode X page, with nothing left over and nothing wasted.
All four planes together are 204800 of the VGA's 262144 bytes, which is also
why there is no back buffer and cannot be one.

## Why the band can afford to be repainted

In mode X with all four planes enabled, one byte write paints four horizontal
pixels. A 320-pixel row is 80 bytes, or 40 words through `REP STOSW`, and BENCH
puts `REP STOSW` to video at 439821 words/sec.

Measured on the V30, for the whole 36-row band:

```
row fills     4.1 ms   (1440 words through REP STOSW)
row loop      3.6 ms   (Pascal, no drawing at all)
lines + cars  4.0 ms
              -------
band repaint 11.7 ms   against 14.27 ms of beam
```

The grid lines are single byte stores at four-pixel granularity, so the map
mask never changes and **the band repaint contains not one `OUT` instruction.**

## The thing that actually made it look smooth

**The band has to be repainted faster than the beam reads it, and the sprites
have to go inside the repaint.** Everything else here is detail.

The beam reaches the top of the band about 11.2ms after the retrace and the
bottom of the screen at 14.27ms, and it reads top to bottom. The band is
painted top to bottom too, so the paint and the beam are in a race that the
paint has to win at *every* row. There is no back buffer to hide behind: the
picture already uses 204800 of the VGA's 262144 bytes, and the pinned region
reads from address zero by definition, so it cannot be page-flipped even if
there were room. Racing the beam is the only tool available.

At 64 rows the repaint took 19ms and the cars were drawn after it, at about
21ms. Two things followed, and they were reported as two different bugs:

* **The cars looked semi-transparent.** They were being drawn seven
  milliseconds after the beam had already read the rows they sit on, so on one
  refresh in two they were not on the screen at all. Counted off the capture
  card: the amber car was absent from **12 of 24 consecutive frames**. At 35 Hz
  that does not read as flicker, it reads as transparency.
* **The floor juddered.** The paint fell behind the beam around row 48, so the
  bottom third showed the *previous* frame for one refresh in two -- and those
  are the fastest-moving rows on the screen.

The fix is one idea applied twice: make the repaint fit, and draw each car the
instant its last row is painted rather than after the whole band. Getting it
to fit meant finding where the time went rather than guessing, and the answers
were not where they looked:

| | before | after |
|---|---|---|
| grid-line inner loop | recomputed the address from a fixed-point accumulator every line, 9.2us | steps the address directly with `ADC`, 4.7us |
| hazed rows near the horizon | repainted every frame | flat colour that never moves -- repainted only when a depth line crosses |
| `DrawSprite` | `Seg()`/`Ofs()` of a 4-D array per group: three multiplies each, 24 a frame | offsets computed once at startup |
| band height | 64 rows | 36 -- the height is a *timing* decision |

Result: the band repaint is **11.7 ms against 14.27 ms of beam**, with the cars
drawn inside it.

**Verified off the capture card, not from the clock.** The obvious instrument --
time the repaint with the PIT -- turned out to be unusable here, and finding out
why took longer than the fix: the BIOS runs PIT channel 0 in mode 3, so the
counter sweeps its whole range *twice* per tick and any sub-tick reading is
ambiguous by up to 27.5 ms, which is nearly twice a frame. The same unchanged
repaint measured 13.2 ms and then 24.4 ms on consecutive builds. `starter/prof.pas`
reads channel 0 the same way and has the same limit; it is written up in
`docs/tools.md`, and the per-frame timing was removed from this demo rather than
report a number that cannot be trusted.

What settles it instead has no such ambiguity: quarter the band, difference
successive captured frames, and look at whether all four quarters move together.
They do, with the lowest changing most -- which is what no stale rows looks
like -- and both cars are present in every one of 34 consecutive frames.

## The floor and the sky scrolled opposite ways

A grid line lands at screen `x = CX + (CamFp*d/64 + k*spacing)/64`, so
**increasing `CamFp` slides the lines right**. But increasing `SkyPix` moves the
window right through the world, which slides the scenery **left**. Advancing
both on `SweepDir > 0` drove the ground one way and the sky and skyline the
other.

It does not read as "the layers disagree", because nothing in shot belongs to
both. It reads as the scene travelling much further one way than the other,
which is how it was reported -- twice. Measured off the capture card at 33 fps,
the sun moved **+2.8** capture pixels a frame while the bottom of the floor
moved **-22**: right magnitude ratio, wrong sign. The camera step is negated
now, so a pan right takes everything left together.

The lesson is the measurement, not the fix: two layers moving at eight to one
look like parallax whichever way they go, and the eye reports the *consequence*
rather than the cause.

## The city only existed in half the world

`BuildSkylines` generated towers with `while X < PERIOD - DUPW` -- world column
384 of 704. The bound was correct when the view scrolled one way forever and
wrapped, because a tower straddling the seam would be cut in half by the
duplicate-columns copy. It stopped being correct the moment the view began
sweeping instead.

The result was reported, twice, as the scene scrolling much further one way
than the other. It was not scrolling unevenly. The mountains and stars are
generated across the full `PERIOD` and kept going; the city simply ran out:

| sweep position | window | city under it |
|---|---|---|
| left end | world 96..416 | 288 of 320 px |
| right end | world 288..608 | **96 of 320 px** |

**A motion bug would have been symmetric.** "It does not do this going the
other direction" was the clue that it could not be motion at all -- only
missing content can show on one side. Two earlier attempts went to the start
position and then the scroll direction, and neither touched it.

Towers now run the whole width, clipped at `PERIOD`, and the report counts the
visible tower columns at each end of the sweep so the next person does not have
to eyeball it: **198 and 198**.

## The first two seconds were the scenery being assembled

There is no back buffer, so everything is built in visible video memory. Until
the display was blanked for it, the opening showed the sky bands filling in,
the stars appearing, the sun being plotted a pixel at a time, the skyline going
up column by column -- and then sixty band repaints from the startup
benchmarks, the last twenty of which draw the floor with no grid lines at all.

The screen is now blanked from the mode set until one complete frame is staged
-- floor, grid, both cars, start address and pan -- and comes back on at a
retrace boundary. Verified by bursting across the transition: blank, blank,
blank, then a finished picture, with no partial frame between.

The Sequencer's Clocking Mode bit is used rather than the Attribute
Controller's palette-enable, because `ShowFar` writes the AC to set the pixel
pan and would switch the screen back on mid-staging. Blanking also stops the
CRTC fetching, so the world paints faster as well as invisibly.

## The pan and the start address

`ModeX.ShowAt` sets the start address, waits for the vertical retrace, *then*
sets the pixel pan. On this card the pan written after the retrace has begun is
already too late -- it takes effect one refresh after the address it belongs
with.

Invisible while both are advancing. Visible on the one frame in four where the
pan **wraps**: the address steps on by a whole four-pixel unit and the pan drops
3 to 0, so that frame shows the new address with the old pan. A frame here is
two refreshes, so the first refresh shows a 4-pixel jump and the second shows
the 3-pixel correction -- the entire sky, skyline and sun shimmering at 35 Hz.

Tracked off the capture card, sun centroid per frame:

```
before   +1.1 +1.1  0  +1.1  0  +1.1  0  +4.5  -3.4   0  +1.1 ...   screen px
after    every step 1.1, no glitch in 34 consecutive frames
```

**The periodicity identified it.** One frame in four is the pan's own period
and nothing else in the demo has it; the size alone could have been anything.
The fix is to write the pan *before* the retrace wait so both latch together.

`starter/demos/modex.pas` is deliberately **not** changed -- `scroller.pas` depends on
it and its frame budget is documented and verified -- but anything scrolling a
mode X layer a pixel a frame will show this. It is written up in
`docs/graphics.md`.

## A mixed frame rate is worse than a slower steady one

With the work at ~15ms against a 14.27ms refresh, a frame took one refresh when
it came in under and two when it did not: **38.4 fps**, a mixture of 14.3ms and
28.5ms frames. That averages to a good-looking number and judders, because a
one-pixel-a-frame layer lands its steps at uneven intervals.

The frame is now padded up to a whole number of refreshes (`REFRESH_LOCK = 2`)
before ShowFar waits for the retrace. A short frame spins; one that already
overran does not wait. Steady 33.5 fps, evenly spaced.

## Five bugs worth keeping

Each of these looked like something other than what it was. They are written
up in the source at the place they happened.

**The screen went pink.** Not the palette, not the mode. `SetSplit` finished
with `OutB($3C0, $20)` meaning "re-enable the palette", but the Attribute
Controller's index/data flip-flop was in DATA state by then, so it landed on
register 10h as data and cleared bit 6 -- 8-bit colour. With PELWIDTH off a
256-colour mode feeds the DAC the wrong thing and every colour is wrong. The
two bit-5s in that routine are different bits of different registers written
to the same port; conflating them is the whole bug.

**The floor dissolved into noise.** Each row had its own phase accumulator
stepped by that row's own speed, which is the obvious way to write it. The
step is an integer number of 64ths, so it is not *exactly* proportional to
depth -- row 16 stepped 119 where the geometry wanted 119.0, row 17 stepped
126 where it wanted 126.4. A thousand frames later adjacent rows were six
pixels apart and the converging rays had become a field of unrelated dashes.
Every row is now derived from **one** camera position, which removes the
possibility rather than reducing the error.

**Then the rays sheared.** Same symptom, different cause: the spacing table
was in whole pixels, truncated from `GW*d/64`. Rounded to whole pixels it
stops being exactly proportional to depth, so the error compounds along each
row and the outer lines walk away from the rays they belong to -- five pixels
by the edge of the screen. The spacing is now kept exactly, in the same 64ths
as the camera.

**The cars looked see-through.** The blitter copies a sprite row as one
`REP MOVSB` per column group, from the group's first opaque pixel to its last.
Any transparent pixel caught between them is copied too -- as colour 0, which
is black. The first pair of cars had separate left and right thruster pads
with a gap between, so six black pixels were stamped across each car's
underside every frame. On a dark floor that does not read as a bug, it reads
as the car being transparent with the grid showing through.

Every sprite row must therefore be **one contiguous run**, which is sufficient
as well as necessary: a contiguous column range gives every group a contiguous
run of samples. `BuildSprites` counts violations and the report prints the
count, so it cannot come back silently.

**17 fps.** Two `LongInt` multiplies per row in the band loop, which read as
one multiply each and are 92us each on this machine -- CLAUDE.md's table says
so. Six milliseconds a frame re-evaluating an expression that does not change
from row to row. Both quantities are arithmetic progressions down the band, so
they accumulate instead. That plus moving the grid-line inner loop out of
Pascal (`Mem[]` reloads a far pointer per access: 17us a store, against about
2us from a loop that holds `ES`) took it from 17.4 fps to 35.1.

## The coprocessor

There is exactly one float-shaped workload here: the perspective tables, which
want 32-bit divides and a square root per row of the sun. The demo does not
assume. It builds the tables **both ways**, checks the two agree entry for
entry, times each at PIT resolution, and uses whichever won:

```
integer (32-bit, software)  : 4211.409 ms
coprocessor (Intel 8087)    : 1313.767 ms
the two tables agreed on    : 217 of 217 entries
USING the coprocessor -- measured faster on this machine
```

Both paths **truncate**, and that is a correctness decision rather than a taste
in rounding. The first version had the integer path round half-up against the
coprocessor's default round-to-nearest-even, and they disagreed on exactly
eight of 217 entries -- every fourth row, where `GW*d/64` lands on an exact
half. Eight wrong entries is a floor with a visible kink in it, and the demo
would have shipped with the coprocessor switched off and the report blaming
it. Floor has no half-way case, so the two paths are now bit-identical by
construction and the agreement check is a real check.

The tables are built once before the world is painted, so a wrong call here
costs startup milliseconds and can never cost a frame.

## If there is no sound card

Nothing happens, and there is no second code path. `MusicStart` probes the
chip by its own timers; if nothing answers, `MusicTick` and `MusicStop` do
nothing at all and the demo runs silently. `NOMUSIC` forces the same state on
a machine that does have one.

The same is true of the coprocessor (`NOFPU`), the PicoMEM (absent is a
reported fact, not a failure) and the display: mono or colour is probed at run
time with `INT 10h AH=1Ah`, because this card boots either way, and the two
palettes are built separately. A colour ramp is not safe on a mono monitor --
it sums R+G+B, so two colours chosen for hue can land on the same grey.

## Arguments

```
SECS n     how long to run, 1..600.  DEFAULT 30
SPEED n    floor speed, 1..16 (default 7).  One knob for the whole scene
SWEEP n    how far the view swings EACH SIDE of centre, 8..192 (default 96)
CARS n     how many of the two cars to draw, 0..2 (default 2)
MONO       force the grey ramp
COLOUR     force the colour ramp
NOMUSIC    stay silent even if an OPL2 answers
NOFPU      ignore the coprocessor even if one is fitted
NOPAUSE    do not hold the information dump on screen before starting
NOSHOT     skip the ASCII thumbnail at the end
PROF       time the frame at PIT resolution and print the breakdown
```

A key press stops it early. No argument takes a `/` or `-` prefix, which keeps
it usable from Git Bash -- see the note in CLAUDE.md about `/X` flags.

## Files

All in `starter/`, because it ships in the client kit for the same reason the
scroller does -- it is the demo that shows what the machine can do.

```
parallax.pas   the demo            build.cmd parallax
retro.pas      the four-voice OPL2 sequencer.  Non-blocking, tick-driven
pmdet.pas      PicoMEM detection.  STRICTLY read-only -- see below
PARALLAX.md    this file
```

```
build.cmd parallax          compile it
test.cmd  parallax          compile AND run it on the DOS box
dosrun starter/PARALLAX.EXE ...run what is already built
```

`pmdet.pas` asks the card BIOS one question through `INT 13h AH=60h` and then
does nothing but read. It has no write path at all, because on both
development machines **the PicoMEM is the boot disk**. What it knows is taken
from `CH375USBTools/PicoMEM` rather than rediscovered.

The shared units -- `VGA`, `ModeX`, `Opl2`, `Cpu`, `Prof`, `About` -- are the
suite's own. `About` pulls in `VidFix`, which matters here: FPC's i8086 runtime
hooks INT 10h, and on a 386 with no 387 that wedges the machine on the first
video BIOS call.

**`starter/demos/modex.pas` is deliberately not modified.** Its `ShowAt` has the
pixel-pan ordering bug described above, and `scroller.pas` depends on its
measured frame budget; `ShowFar` here is a local copy with the fix. Both are
written up in `docs/graphics.md`.

## Known, and deliberate

* **The scene sweeps left and right instead of scrolling one way.** Scrolling
  one way forever means the world has to wrap, and a wrap means the sun and the
  skyline come round again -- which reads as the scenery repeating, because it
  is. Sweeping means the 320-pixel window never reaches the seam at all. The
  turn is abrupt and at full speed on purpose; easing through it would take the
  far layer below one pixel a frame, which is the sub-pixel crawl that stutters.
  **It starts in the middle of the sweep**, not at one end -- starting at an end
  means the first thing the demo does is travel the whole range one way before
  it ever comes back, which reads (correctly) as scrolling further one way than
  the other. `SWEEP n` sets how far it swings each side of centre.
* **The cars weave rather than drive off the edges.** The blitter has no
  horizontal clip -- a sprite is whole column groups of consecutive addresses,
  and trimming one costs more than the frame can spend. But a racing camera
  travels with the cars and what moves is the ground, which here is already
  rushing past at 280 px/s. The two weave periods differ (128 frames against
  85) so they change places continually.
* **Sprites can shimmer.** There is no back buffer, so a car drawn while the
  beam is crossing its rows shows half-drawn for one refresh. The band is
  repainted first, immediately after the retrace, because the beam does not
  reach row 136 for about nine milliseconds -- a tear in the full-width
  fast-moving floor would be far more visible than a car flickering.
* **The rate is quantised.** `ShowFar` blocks on the vertical retrace, so only
  70.1/N is available. The number to watch after any change is `late frames`,
  not the frame rate: a frame time landing *between* two multiples of 14.27ms
  averages out respectably and judders.
* **The grid lines step four pixels at a time**, and on the V30 there is no
  headroom to fix it. Mode X positions a byte write to four pixels of all four
  planes at once; putting a line at an arbitrary pixel needs the map mask
  changed per line, which measured about 4 ms a frame. The frame already
  finishes at 28.4 ms against a two-refresh budget of 28.54 -- 127
  microseconds of slack -- so anything added drops it to three refreshes and
  23 fps, which is much worse than the stepping. Rows whose speed happens to
  be a whole number of addresses per frame (about 4 px/frame and 8 px/frame at
  the default speed) are smooth; the ones in between alternate.

  Three ways out, none of them free: shrink the band (48 rows buys about 6 ms),
  move the band row loop into assembler (the Pascal overhead is roughly 5 ms of
  the 19), or repaint the band incrementally -- erase only the previous frame's
  line positions instead of filling all 2560 words, which is worth about 7 ms
  and would put the whole demo at one refresh. All three are real; none was
  needed to make it look right.
