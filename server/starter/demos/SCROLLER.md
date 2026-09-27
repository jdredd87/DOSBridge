# scroller

A side-scrolling landscape with sprites and AdLib music, in VGA mode X, on an
8086-class DOS machine.

    cd starter
    test.cmd scroller           build and run it for thirty seconds
    build.cmd scroller          build only

Or, once it is deployed to the box, just  dosexec "C:\TOOLS\SCROLLER.EXE"

    SCROLLER                    30 seconds, 2 px/frame, palette probed
    SCROLLER SECS 10 SPEED 5    shorter and faster
    SCROLLER MONO               force the grey ramp
    SCROLLER NOMUSIC            stay silent even with an AdLib fitted
    SCROLLER PROF               PIT-resolution breakdown of the frame
    SCROLLER NOSHOT             skip the ASCII thumbnail

Any keypress ends it early. It always restores the text mode it found, and it
always silences the FM chip on the way out.

## Measured on the NEC V30 box, 2026-09-01

    2096 frames in 30.00 s      69.8 fps
    frame                       14312 us = exactly 1 vertical refresh
    late frames                 0 of 2096
    music                       438 notes, 2 times round the 8 bars
    world paint (once)          1263 ms
    scrolled                    4192 px = 5 laps of the world

70 fps is the ceiling: a 320x200 VGA refreshes at 70.1 Hz and the frame loop
waits for it.

## What it is doing

The background is painted **once** and never redrawn. It lives in a mode X
virtual screen 1024 pixels wide, of which the monitor shows 320, and scrolling
is done by moving the CRTC start address plus the Attribute Controller's pixel
pan -- five OUTs a frame, for one-pixel granularity.

Redrawing it instead would be 64000 bytes a frame, which `BENCH` puts at 73ms.
That is 13 fps before deciding what to draw, so a software scroller on this
machine cannot be smooth however well it is written.

    virtual screen   1024 x 200, four planes      204800 of 262144 bytes
    world            columns 0..703
    wrap region      columns 704..1023 = a copy of columns 0..319

`704 + 320 = 1024` is the whole trick. At scroll 703 the 320-wide window shows
the end of the world followed by its beginning, so scroll can snap back to 0
with the picture unchanged and nothing is ever drawn as it comes on screen.

Everything is `-Pi8086`. Nothing is gated on `Has186` because nothing here
measured as worth a gate.

## The frame rate is quantised. Watch `late frames`, not fps

`ShowAt` blocks on the vertical retrace, so a frame occupies a whole number of
refreshes and the only rates available are 70.1 / N:

    N = 1   70.1 fps      needs the frame under 14.27 ms
    N = 2   35.0 fps                        under 28.54 ms
    N = 3   23.4 fps                        under 42.80 ms

Shaving 10% off the work usually buys nothing, and then one more percent
doubles the rate. The entire history of this demo, all measured on hardware:

| | work/frame | N | fps | |
|---|---|---|---|---|
| 6 sprites, blitter as a hand pixel loop | ~36 ms | 3 | 23.4 | steady |
| 6 sprites, blitter as `REP MOVSB` | ~24 ms | 2 | 35.1 | steady |
| 6 sprites + music | ~19 ms | 2/3 | 33 | **juddering** |
| 5 sprites + music | ~14.5 ms | 1/2 | 56 | **juddering** |
| 4 sprites + music | ~11.5 ms | 1 | 70.4 | steady |

**56 fps is worse than 35 fps.** A frame time that lands between two multiples
of 14.27ms gives a respectable-looking average and a picture that stutters,
because consecutive frames are held on screen for different lengths of time.
That is why `FlipLate` exists: it counts frames that reached `ShowAt` with the
retrace already under way. It is the number to check after any change.

Getting from N=3 to N=2 was one fix. `PROF` reported `draw` at 60% of the
frame while the scroll cost nothing measurable -- guessing would have gone
after the scroll. The fix is the ratio CLAUDE.md already records: a string
instruction beats a hand loop by roughly 7x, so the sprite data is
**deinterleaved into the four column groups** (`SprDI`), which makes each row
of each group four *consecutive* bytes in one plane and therefore one
`REP MOVSB`. Transparency comes from a precomputed (first, count) run per
group-row rather than a test per pixel, so the fast path stays a string
operation.

Getting from N=2 to N=1 was not tuning. It was dropping two sprites.

One caution about `PROF` itself: `Mark()` is called ~13 times a frame here and
its own cost lands inside the sections, so the profiled frame is noticeably
slower than the real one. Use it for **ratios**, and take absolute frame times
from a run without it.

## Sprites

Four 16x16 sprites, each in its own 42-row lane. The lanes are not a visual
choice: they guarantee no two sprites overlap, which is what makes
restore-save-draw safe to do one sprite at a time instead of in three passes
over all of them.

Sprites live in **world** coordinates and each one stores the address it saved
its background from, restoring to that same address rather than a recomputed
one. Without that, every sprite would corrupt the background once per lap, at
the moment the scroll wraps.

Save and restore are VRAM-to-VRAM latch copies (write mode 1), so one byte
moved carries four pixels across all four planes -- four times cheaper per
pixel than drawing them. Neither inner loop pushes the row start on the stack;
`REP MOVSB` leaves the pointers a known distance on, so the step to the next
row is arithmetic. Four stack operations a row was worth about a millisecond a
frame, and here a millisecond is a refresh boundary.

Sprites may shimmer occasionally. There is no back buffer and there cannot be:
the picture already uses 204800 of the card's 262144 bytes. A sprite is
updated over ~3 ms while the beam crosses it in ~1 ms, so sometimes the beam
catches one half-drawn. The scrolling is never affected -- that is the CRTC,
and it cannot tear.

## Music

Three voices on an AdLib / OPL2, if one answers at 388h: a lead with vibrato,
an eighth-note bass pulse, and a sixteenth-note arpeggio. D minor,
`Dm Dm Bb C | Dm F Bb A`, 136 BPM, eight bars, about 14 seconds round.

The chip is probed at run time by the timer method, and if nothing answers the
demo runs exactly as before -- there is no silent-mode special case anywhere,
because `MusicTick` and `MusicStop` return immediately when `MusicOn` is
false.

Two things about it are load-bearing:

* **It must not block.** The usual way to write a tune is key a note, wait,
  key the next. That would stall the scroll dead. `MusicTick` is called once
  per frame and returns immediately; the sequencer is a step counter and three
  pieces of per-voice state.
* **The tempo comes from the BIOS tick, not the frame count.** Counting frames
  is the obvious thing when the caller already has a frame loop, and it is
  wrong here: the frame rate is quantised to 70.1/N, so one sprite more or
  less does not slow the music by 10%, it halves it. A step is two ticks and
  `MusicTick` catches up to wall time, capped so a stall cannot fire off a
  hundred notes at once.

Adding the music cost a sprite. Nine OPL register writes when all three voices
change on the same step is about 0.8ms, and the register writer spends nearly
all of that waiting for the chip -- which was enough to cross a refresh
boundary.

`MusicStop` is called on **every** exit path including the mode-refused one. A
program that quits with a voice still ringing leaves the machine droning, and
over the bridge nobody can hear that it happened.

## Two things it cannot do

**Parallax.** One start address moves the whole screen, so the landscape can
only scroll at one rate. What looks like depth comes from the sprites, which
are drawn per frame and drift at their own speeds. CRTC line compare would
give a second region, but that region is pinned to address 0 and so cannot be
panned horizontally at all.

**`VSHOT`.** It reads A000 linearly, which is meaningless once the chain is
broken. That is why the program prints its own ASCII thumbnail instead,
reading pixels back through the Read Map Select register. It is the only
evidence over the bridge that a picture existed -- nothing drawn to A000 is
captured.

The thumbnail is always ranked by the **grey** ramp even when the colour
palette is loaded. The colour ramp is chosen for hue, not brightness -- the
sky at the horizon is lighter than the ground -- so ranking by true luminance
turns a legible landscape into noise.

## Files

All in `starter/`, alongside the rest of the tool suite:

    scroller.pas    the demo: world generation, sprites, the frame loop
    modex.pas       unchained 320x200x256 and the hardware pan
    music.pas       the score and the non-blocking sequencer

It began life in `projects/scroller/` and moved here so it ships in the client
kit -- it is the demo that shows what one of these machines can actually do, so
it belongs with the tools rather than alongside your own work. `build.cmd` and
`test.cmd` in `starter/` take it as an argument like any other target.

`modex.pas` is deliberately a separate unit, and general: `Enter`, `MapMask`,
`HSpan`, `VRun`, `CopyRect`, `PeekPix`, `ShowAt`. The FM plumbing it leans on
lives in `opl2.pas` for the same reason. Anything else wanting a wide
virtual screen or an OPL2 can use either without dragging the landscape along.

## If it refuses

`Enter` writes the four unchaining registers and then reads all four back. If
any of them did not take it returns False, the program restores text mode and
reports `mode X: REFUSED`. A card that quietly ignores one of those leaves a
picture that is *skewed* rather than absent, which is a confusing way to spend
an afternoon.

Note this box boots mono or colour at random, so the palette is probed every
run and there are two independently built ramps. The colour one is not safe on
a mono monitor -- the monitor sums R+G+B, so two different colours can land on
the same grey.
