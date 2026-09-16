# Graphics plumbing: the VGA unit, mode X, and sound

The shared units the demos are built on. The raycaster's own story is
in `raycast.md`; the scroller's is in `starter/SCROLLER.md`.

Split out of `CLAUDE.md`, which keeps the summary and the pointer here.

## Shared graphics plumbing: the `VGA` unit

**The video card reports a different amount of memory on different boots, and
therefore a different mode list.** This is the second boot-time lottery on this
machine, alongside mono-vs-colour, and it is much bigger. Two boots, same
hardware, nothing reconfigured:

| | one boot | another |
|---|---|---|
| `4F00h` reports | 256 KB | **1024 KB** |
| graphics modes offered | 2 | **18** |
| of those, 8bpp or better | **0** | 14 |
| best available | 800x600x4 planar | 1280x1024x4, 1024x768x8, 640x480x24 |

So `svgatext.pas` asking for VBE 101h (640x480x256) **succeeds or fails
depending on the boot**. It used to exit 1 and draw nothing when the card came
up small, which is why these notes claimed for a while that the demo "does not
run on this box and never has" -- wrong, and wrong in a way that only a second
boot could expose. It now falls back to mode 13h (320x200x256, guaranteed on
any VGA, no banking) and runs either way.

**The rule this forces:** never record a video capability here as a property of
the machine. Probe it at run time, every run. `VESACHK` and `VMODES` describe
*this boot*, not the card. An earlier `VESACHK` reading of "0 modes" was itself
a filter bug -- but even fixed, its answer is only good until the next reset.

`starter/vga.pas` holds the mode 13h helpers the demos share: `SetMode`,
`GetMode`, `Ticks`, `OutB`/`InB`, `DisplayCode`/`IsColourDisplay`,
`ChoosePalette` (the `MONO`/`COLOUR` argument override), `DacSeek`/`DacRGB`/
`DacGrey`, `WaitRetrace` and `FillSpan`. `fractal.pas`, `balls.pas` and
`vidchk.pas` all build on it; `uses VGA` and the `-FUbuild` already in
`build.cmd` is enough.

It exists because those ~60 lines had been copied between two demos and every
fix — the bounded retrace wait, the six-bit DAC, the display probe — had to be
made twice or silently drift. Two things in it are load-bearing and easy to
reintroduce as bugs if you write your own:

* **`WaitRetrace` is bounded.** An unbounded `repeat until port` wedges the
  machine and needs a physical reset if that bit stops toggling. It counts
  give-ups in `RetraceTimeouts` and accepts tearing instead.
* **`FillSpan` is `REP STOSB`, not a pixel loop.** Per-pixel `Mem[]` reloads a
  far pointer every time and measures ~7x slower; this is what doubled the
  bouncing-ball frame rate.

`fractal.pas` is colour-only by choice. A colour ramp is *not* automatically
safe on a mono display — the monitor sums R+G+B, so two different colours can
land on the same grey — so on a mono boot it looks muddy rather than merely
desaturated. Check with `VIDCHK` first. `balls.pas` still carries both palettes
and picks at run time, which is the pattern to copy for anything that has to
work whichever way the card came up.

## Smooth scrolling: mode X, and why the frame rate is quantised

`starter/scroller.pas` is a side-scrolling landscape with sprites and AdLib
music, and `starter/modex.pas` is the reusable half: unchained
320x200x256 with a virtual screen wider than the display. Verified on hardware
2026-09-01 -- 2096 frames in 30.00s, **69.8 fps, one vertical refresh per
frame, zero late frames**, which is as fast as a 320x200 VGA goes.

**A software scroller cannot be smooth on this box, and the arithmetic says so
before you write one.** A mode 13h frame is 64000 bytes, which `BENCH` puts at
73ms -- 13 fps before a single pixel has been *decided*. So the scroll has to
move to the CRTC: tell the card the picture is 1024 pixels wide while the
monitor shows 320, then move the window with the Start Address (CRTC 0Ch/0Dh)
and the Attribute Controller pixel pan (index 13h). Start address steps four
pixels, pixel pan supplies the remaining nought-to-three, and the whole frame
costs five OUTs.

Unchaining is four registers, and `Enter` reads all four back rather than
trusting them -- a card that ignores one leaves a picture that is *skewed*
rather than absent, which is a confusing way to spend an afternoon:

```
Sequencer 04h  = 06h        Chain-4 off, keep Extended Memory + sequential
CRTC      14h  bit 6 = 0    doubleword off
CRTC      17h  bit 6 = 1    byte mode on
CRTC      13h  = VW/8       Offset: 128 for a 1024-pixel virtual width
```

Two consequences that are easy to miss:

* **Solid fills get *cheaper*.** With all four planes enabled one byte write
  sets four horizontal pixels, so a span is a quarter of the STOSBs mode 13h
  needs. What gets dearer is anything vertical or unaligned, which has to be
  done a plane at a time.
* **There is no room left for a back buffer**, and that is a real trade, not
  an oversight. At 1024 wide the picture is 204800 of the card's 262144
  bytes. Hardware scrolling and page flipping compete for the same memory and
  on a wide world the scroll wins easily -- but it means sprites are erased
  and redrawn in place, so they can shimmer when the beam catches one
  mid-update. The scroll itself never tears; that is the CRTC.

**Wrapping needs no repainting at all** if the geometry is chosen for it. Make
the world 704 columns and the last 320 a copy of the first 320: `704 + 320 =
1024`, so at scroll 703 the window shows the end of the world followed by its
beginning and the scroll can snap back to 0 with the picture unchanged.
Nothing is ever drawn as it comes on screen.

**Parallax is not available.** One start address moves the entire screen. CRTC
line compare gives a second region, but that region is pinned to address 0 and
cannot be panned horizontally, so it can only ever be a *static* band. Depth
has to come from sprites, which are drawn per frame and can drift at any rate.

### The frame rate is 70.1 / N, and nothing in between

This is the part worth internalising before optimising anything that syncs to
the display. Waiting on the vertical retrace means a frame occupies a whole
number of refreshes:

```
N = 1   70.1 fps    needs the frame under 14.27 ms
N = 2   35.0 fps                      under 28.54 ms
N = 3   23.4 fps                      under 42.80 ms
```

So shaving 10% off usually buys **nothing at all**, and then one more percent
doubles the rate. Every step of tuning this demo, measured on hardware:

| | work/frame | N | fps | |
|---|---|---|---|---|
| 6 sprites, blitter as a hand pixel loop | ~36 ms | 3 | 23.4 | steady |
| 6 sprites, blitter as `REP MOVSB` | ~24 ms | 2 | 35.1 | steady |
| 6 sprites + music | ~19 ms | 2/3 | 33 | **juddering** |
| 5 sprites + music | ~14.5 ms | 1/2 | 56 | **juddering** |
| 4 sprites + music | ~11.5 ms | 1 | 70.4 | steady |

**56 fps is worse than 35 fps, and this is the trap.** A frame time landing
*between* two multiples of 14.27ms gives a respectable-looking average and a
picture that stutters, because consecutive frames are held on screen for
different lengths of time. An average frame rate cannot show you that. Count
the frames that arrive at the flip with the retrace already under way --
`FlipLate` in `modex.pas`, three lines -- and check *that* after any change.

`PROF` is what found the blitter: it reported `draw` at 60% of the frame while
the scroll cost nothing measurable. Guessing would have gone after the scroll.
But note `Mark()` is called ~13 times a frame there and its own cost lands
inside the sections, so a profiled frame is materially slower than a real one.
**Use `PROF` for ratios and take absolute frame times from a run without it**
-- believing the profiled number here hid a whole refresh boundary for two
rounds of measurement.

The fix is the ratio already recorded above, applied to sprites: the sprite
data is **deinterleaved into the four column groups** `c mod 4`, because within
one group the four columns land on four *consecutive* addresses in one plane,
which turns a row into one `REP MOVSB`. Transparency comes from a precomputed
(first, count) run per group-row instead of a test per pixel, so the fast path
stays a string instruction. Copy that pattern for any mode X sprite.

Save and restore of sprite backgrounds use write mode 1 (VRAM-to-VRAM through
the latches), where one byte moved carries four pixels across all four planes
-- four times cheaper per pixel than drawing them.

**`VSHOT` cannot photograph an unchained mode.** It reads A000 linearly, which
is meaningless once the chain is broken, so `scroller` prints its own ASCII
thumbnail by reading pixels back through Read Map Select. Anything written for
mode X needs its own read-back if it is to be checkable over the bridge. Rank
such a thumbnail by a **depth-ordered grey ramp, not by true luminance** -- a
colour palette is chosen for hue, and ranking it by brightness turns a legible
picture into noise.

## Sound while something else is running: `starter/opl2.pas`

`AMOZART` plays a tune and does nothing else, so it can key a note and wait.
Anything with a frame loop cannot, and that is the whole difficulty. The unit
holds the parts that are about the chip rather than the music: `OplDetect`
(the timer method), `OplWrite`, `OplVoice`, `OplNoteOn`/`Off`, `OplSilence`.
`starter/music.pas` is the worked example of driving it from a frame
loop. Note `amozart.pas` predates the unit and still carries its own copy.

Three things learned wiring music into the scroller:

* **Register writes are dear, and it is all waiting.** The chip needs >3.3us
  after an address byte and >23us after data, spent reading the status port.
  `amozart.pas` does that with a Pascal loop, which `BENCH` puts at ~11us an
  iteration, so each register write costs it roughly 480us. Fine for a program
  doing nothing else; far too much inside a frame. The unit uses an assembler
  loop -- same number of bus cycles, about a sixth of the wall clock. Even so,
  three voices changing together is nine writes and about 0.8ms, and that was
  enough to cost the demo a sprite.
* **Take the tempo from the BIOS tick, never from the frame count.** Counting
  frames is the obvious thing when the caller already has a frame loop, and it
  is wrong precisely because of the quantisation above: one sprite more or
  less does not slow the music by 10%, it halves it.
* **Silence the chip on every exit path**, including the error ones. A program
  that quits with a voice still ringing leaves the machine droning, and over
  the bridge nobody can hear that it happened.
