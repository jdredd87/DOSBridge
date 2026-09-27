program Parallax;
{ DOS Bridge  --  StevenC & Claude }
{ NEON DRIFT -- a mode X parallax demo with an OPL2 soundtrack.

  Everything here is plain 8086 and runs on any DOS box with a VGA.  It was
  written on the NEC V30 machine with a PicoMEM 2 in it, which is where the
  AdLib at 388h comes from -- the card emulates one -- but nothing in the code
  knows or cares.  The chip is found by its own timers, so a real AdLib, an
  emulated one and no sound hardware at all are three outcomes of one probe.

  WHAT MAKES THE PARALLAX REAL

  starter/scroller.pas says, correctly, that its parallax is fake: one CRTC
  start address moves the whole screen, so a single bitmap can only scroll at
  a single rate, and the depth you see there comes entirely from sprites.
  This demo gets genuinely independent layers out of the same hardware by
  splitting the screen with the CRTC Line Compare register:

      display rows 0..135    the address counter starts at the Start Address,
                             so this region SCROLLS.  Sky, stars, the sun, the
                             mountain ridge and the city -- the far layer, at
                             a fraction of a pixel per frame

      display rows 136..199  line compare resets the address counter to 0 part
                             way down the frame, so this region is PINNED to
                             the bottom of video memory and the start address
                             does not move it.  It is repainted every frame,
                             which is what lets every one of its 64 rows have
                             its own scroll rate

  The lower band is a perspective grid floor, and the per-row rates are not
  decoration -- they are the actual geometry.  A vertical line in the world at
  distance z lands on screen at an offset proportional to 1/z, and for a flat
  floor 1/z is proportional to (row - horizon).  So row d moves at a speed
  proportional to d: the row at the horizon creeps, the row at your feet
  tears past, and every row in between is correct.  That is nine or ten
  distinct scroll rates on screen at once, plus the far layer above the split,
  plus six sprites drifting at rates of their own.

  WHY THE BAND CAN AFFORD TO BE REPAINTED

  Because in mode X, with all four planes enabled, one byte write paints four
  horizontal pixels.  A 320-pixel row is 80 bytes, or 40 words through REP
  STOSW, and BENCH puts REP STOSW to video at 439821 words/sec.  Sixty-four
  rows is 2560 words -- under 6ms.  The grid lines on top of that are single
  byte stores at four-pixel granularity, so the map mask never changes and
  the whole band repaint contains not one OUT instruction.

  The same arithmetic is why the far layer is NOT repainted: it is 1024 pixels
  wide and 136 rows deep, and it is scrolled by five OUTs a frame instead.

  MEMORY.  Per plane, at a 1024-pixel virtual width, 256 bytes per row:

      VRAM rows   0.. 63   the pinned band, columns 0..319 only
      VRAM rows  64..199   the far layer, all 1024 columns
                           -- 64 + 136 = 200 rows = 51200 bytes, exactly the
                           mode X page, with nothing left over and nothing
                           wasted

  The band only shows its first 320 pixels, so addresses 80..255 of its rows
  are off screen and that is where the sprite backing store lives -- 176 bytes
  a row, two sprites to a row.

  ARGUMENTS, in any order:

    SECS n     how long to run, 1..600.  DEFAULT 30
    SPEED n    floor speed, 1..16 (default 7).  The far layer and every grid
               row scale off this, so it is one knob for the whole scene
    CARS n     how many of the two cars to draw, 0..2 (default 2)
    MONO       force the grey ramp
    COLOUR     force the colour ramp
    NOMUSIC    stay silent even if an OPL2 answers
    NOFPU      ignore the coprocessor even if one is fitted
    NOPAUSE    do not hold the information dump on screen before starting
    NOSHOT     skip the ASCII thumbnail at the end
    PROF       time the frame at PIT resolution and print the breakdown

  A key press stops it early.  So does the run time expiring, which is the
  normal way out.

  THE COPROCESSOR.  There is exactly one float-shaped workload here -- the
  perspective tables, which want 32-bit divides and a square root per row of
  the sun -- and CLAUDE.md is blunt about how those usually go: the 8087 is
  five times the software 32-bit routines and still loses to a 16-bit integer
  path in real code.  So the demo does not assume either way.  It builds the
  tables BOTH ways, checks the two agree entry for entry, times each at PIT
  resolution, and uses whichever won.  The report prints both numbers.  That
  is the whole of "use the FPU if it actually improves performance": it is a
  measurement, not a preference, and it is made on the machine that is running.

  None of it touches the frame loop.  The tables are built once before the
  world is painted, so a wrong answer here costs startup milliseconds and
  cannot cost a frame. }

{$MODE OBJFPC}{$H-}
{$ASMMODE INTEL}

uses VGA, ModeX, Opl2, Retro, Cpu, PmDet, Prof, About;

const
  { ---- the screen split ---- }

  { Display row the pinned band starts at.

    THE BAND'S HEIGHT IS A TIMING DECISION, not a visual one, and this is the
    number that sets it.  The beam reaches the top of the band about 11.2ms
    after the retrace and the bottom of the screen at 14.3ms, and the band is
    repainted top to bottom -- so the repaint plus the cars has to finish
    inside roughly 14.3ms or the lowest rows are still being written after the
    beam has read them.  Those rows then show the PREVIOUS frame for one
    refresh in two, and since they are also the fastest-moving rows on the
    screen, that reads as judder.  Measured at 64 rows the repaint was 19ms
    and the bottom eight rows were always late.

    There is no back buffer to hide it behind: the picture already uses 204800
    of the VGA's 262144 bytes, and the pinned region reads from address zero by
    definition, so it cannot be page-flipped even if there were room.  Racing
    the beam is the only tool, and the band height is the knob.  136 leaves the far layer exactly
    the 136 rows that fit above the band in one mode X page. }
  SPLIT   = 164;
  BANDH   = VH - SPLIT;          { = 64 rows of grid floor }
  FARROW  = BANDH;               { VRAM row the far layer starts at }
  FARBASE = Word(FARROW) * VWB;  { ...as an address, added to every ShowAt }

  { Line compare counts SCAN LINES, and mode X inherits mode 13h's Maximum
    Scan Line of 1 -- every display row is drawn twice.  So the split at
    display row SPLIT is scan line SPLIT*2.  Reading it back is the only
    check available: a card that ignored the write leaves a picture that is
    wrong rather than absent. }
  LCVAL   = SPLIT * 2;

  { ---- the far layer's world ---- }
  PERIOD  = 704;                 { the world repeats every this many pixels }

  { The middle of the sweep, in world pixels.  Chosen so the sun -- which is
    at world x 352 and is the thing the eye tracks -- sits dead centre of the
    screen at the middle of the travel: 352 - 320/2 = 192. }
  SWEEP_MID = 192;

  { Default half-range.  The view swings SWEEP_HALF pixels each side of the
    middle, so 96 is a 192-pixel sweep: about five and a half seconds each
    way at one pixel a frame.  SWEEP n on the command line changes it. }
  SWEEP_HALF = 96;
  DUPW    = DISP_W;              { last DISP_W columns duplicate the first }

  { ---- the grid floor ---- }

  { Depth of the topmost band row.  Not zero: at zero the row is at the
    horizon, where the spacing is nought and the geometry divides by it. }
  D0      = 6;

  { Grid line spacing in pixels = GW * d / 64.  At the bottom row (d = 69)
    that is 51 pixels; at the top it is under four, which is why rows whose
    spacing falls below MINSP get no vertical lines at all and read as haze.
    That is not a fudge -- an infinitely dense grid at the horizon is what
    the geometry actually says, and drawing it would just alias. }
  GW      = 48;

  { Rows whose spacing falls below this get no vertical lines and read as
    haze.  Twenty rather than twelve for two reasons that happen to agree:
    below about twenty pixels the lines are close enough to alias into a
    shimmer at these speeds, and the densest rows are also where most of the
    line-drawing time goes -- the count per row is 320 divided by the
    spacing, so the cheapest lines to give up are the ones worth least. }
  MINSP   = 14;

  { Horizontal (depth) lines.  z is proportional to 1/d, so Zof[b] = ZK div d
    and a line goes wherever (Zof + phase) crosses a multiple of 64.  The
    step being a power of two is deliberate: it makes the per-frame test a
    shift and a compare instead of 64 divides. }
  ZK      = 4096;
  ZSHIFT  = 6;

  { Lateral speed.  The camera advances LATBASE * Speed sixty-fourths
    of a pixel per frame and row d sees that scaled by d/64, so the whole
    floor is one number and every row stays in proportion to every other.  At the default
    Speed of 7 that is 0.70 pixels a frame at the horizon and 8.0 at the
    bottom of the screen -- a factor of eleven between the slowest and
    fastest thing on the floor, with everything in between.

    It is one global accumulator rather than one per row -- see PaintBand for
    why that is a correctness requirement and not a saving -- and it is kept
    modulo GW pixels, so it stays well inside a Word however long the demo
    runs. }
  LATBASE = 68;

  { ---- palette ---- }
  C_SKY   = 1;    N_SKY   = 16;   { 1..16   top of sky to horizon }
  C_SUN   = 17;   N_SUN   = 6;    { 17..22  pale gold to hot magenta }
  C_MTN   = 23;                   { 23..25  ridge, mid, lit rim }
  C_CITY  = 26;                   { 26..28  tower, tower lit face, window }
  C_STAR  = 29;                   { 29..31  three star brightnesses }
  C_HGLOW = 32;                   { 32..34  the glow along the horizon }
  C_FLOOR = 40;   N_FLOOR = 16;   { 40..55  floor, far to near }
  C_GRID  = 56;   N_GRID  = 16;   { 56..71  grid lines, far to near }
  C_SPR   = 80;                   { 80..103 six sprite ramps of four }

  { ---- sprites: two hovercars racing across the plain ---- }

  { BOTH OF THEM LIVE IN THE BAND, and that is the whole reason there are
    only two and they cost nothing.  A sprite above the split has to save the
    background it covers and put it back next frame -- three VRAM-to-VRAM
    rectangle moves per sprite per frame, which on this machine measured 5.9
    milliseconds each and was most of the frame.  A sprite in the band needs
    neither: the band is repainted from scratch every frame, so the erase has
    already happened before the car is drawn.  Draw only, about 1.2ms each.

    So the demo's sprites went where the demo's cheap frame is, and the
    picture is better for it -- cars belong on the ground. }
  NSPR    = 2;
  SPR_W   = 24;
  SPR_H   = 12;
  SPR_AW  = (SPR_W div 4) + 1;   { addresses a 24-pixel sprite can touch: 7 }
  SPR_K   = SPR_W div 4;         { columns per deinterleaved group: 6 }

  { Screen travel.  Bounded so the rightmost address a car touches stays
    inside the visible 80: (276+3) div 4 + 8 = 77. }
  CAR_XMAX = 284;

  { ---- the sun ---- }
  SUNX    = 352;                 { world column of its centre }
  SUNY    = 84;                  { row of its centre, in the far layer }
  SUNR    = 44;

  { ---- clocks ---- }
  TICKS10   = 182;               { BIOS ticks in ten seconds, not one }
  TICKDAY   = 1573040;           { ticks in a day, for the midnight wrap }
  USPERTICK = 54945;
  USPERREFR = 14268;             { one 70.1 Hz vertical refresh }

  { Microseconds from the start of the vertical blank -- which is when ShowFar
    returns -- to the beam reaching the last row of the screen.  One whole
    refresh, less nothing: the blank comes first and the last row is drawn at
    the very end of the active period, so the budget for repainting the band
    IS the refresh.  The band is repainted top to bottom and the beam reads it
    top to bottom, which is why the whole refresh is available rather than
    just the part before the beam reaches the split. }
  BEAM_US   = 14268;

  { Refreshes per frame.  Two is the smallest the work reliably fits into;
    one would be 70 fps and is out of reach on this machine.  The point is
    that it is FIXED rather than whatever each frame happens to manage. }
  REFRESH_LOCK = 2;

  { Pad each frame to just past the last refresh boundary before the one it
    should end on, so ShowFar's retrace wait always lands on the same one.
    The 600us of slack covers the granularity of the PIT read itself. }
  PACE_US = (REFRESH_LOCK - 1) * USPERREFR + 600;

  { How long the beam takes to cross the band itself, so an overshoot in
    microseconds can be turned into the number of rows it spoiled. The active
    display is about 12700us for 200 rows. }
  ACTIVE_US = 12700 * BANDH div VH;

  { How many times the perspective tables are built when the two paths are
    raced.  Sixty puts each pass at a quarter of a second or so on the
    slowest machine here, which is far more than the PIT needs to separate
    them and still barely noticeable at startup. }
  BENCH_REPS = 60;

  SHOT_W = 64;
  SHOT_H = 23;
  Shades = ' .:-=+*#%@';

var
  { ---- options ---- }
  RunSecs   : Integer;
  Speed     : Integer;
  NSprites  : Integer;
  WantMusic : Boolean;
  WantFpu   : Boolean;
  WantShot  : Boolean;
  WantPause : Boolean;
  Profiling : Boolean;
  Colour    : Boolean;
  Forced    : ShortString;
  BadArg    : ShortString;

  { ---- state ---- }
  OldMode   : Byte;
  Frames    : LongInt;
  StartTick : LongInt;
  Elapsed   : LongInt;
  PaintMs   : LongInt;
  SplitOk   : Boolean;
  AcMode    : Byte;       { Attribute Controller 10h, read back after the split }
  Lum       : array[0..255] of Byte;
  Shot      : array[0..SHOT_H - 1] of ShortString;

  { Far layer scroll, in 64ths of a pixel so it can creep slower than one
    pixel a frame -- which is the whole point of it being the far layer. }
  SkyPix    : Word;
  SkyStep   : Word;       { whole pixels of far-layer scroll per frame }
  SweepDir  : Integer;    { +1 or -1: the whole scene swings together }
  SweepLo   : Word;
  SweepHi   : Word;
  SweepHalf : Integer;
  CityAtLo  : Integer;    { visible tower columns at each end of the sweep }
  CityAtHi  : Integer;
  Sweeps    : LongInt;    { times the scene turned round }
  SkyLo, SkyHi: Word;

  { ---- the grid floor, one entry per band row ---- }
  SpacePx   : array[0..BANDH - 1] of Integer;   { grid spacing, pixels }
  CamFp     : Word;                             { the camera, 64ths of a px }
  Zof       : array[0..BANDH - 1] of Word;      { ZK div d, for depth lines }
  FloorCol  : array[0..BANDH - 1] of Byte;
  GridCol   : array[0..BANDH - 1] of Byte;
  IsHLine   : array[0..BANDH - 1] of Boolean;
  WasH      : array[0..BANDH - 1] of Boolean;
  ForceFill : Boolean;    { first frame, or after anything else drew there }
  NHaze     : Integer;    { rows 0..NHaze-1 carry no grid lines }
  ZPhase    : Word;
  ZAcc      : Word;

  { The integer and coprocessor builds write here in turn so they can be
    compared entry for entry before either is trusted. }
  RefSpace  : array[0..BANDH - 1] of Integer;
  RefZof    : array[0..BANDH - 1] of Word;
  RefSun    : array[0..2 * SUNR] of Integer;
  SunHW     : array[0..2 * SUNR] of Integer;    { sun half-width per row }

  { ---- coprocessor race ---- }
  FpuFitted : Boolean;
  FpuUsed   : Boolean;
  UsIntBuild: LongInt;
  UsFpuBuild: LongInt;
  UsBand    : LongInt;    { measured cost of one band repaint, on this box }
  UsFill    : LongInt;    { ...and of just the row fills inside it }
  UsLoop    : LongInt;    { ...and of going round the rows with no drawing }
  BandUs    : LongInt;    { this frame's band+cars time }
  BandUsMax : LongInt;
  BandUsSum : LongInt;
  BandLate  : LongInt;    { band rows read before they were written }
  BandLateFrames: LongInt;
  LateRows  : LongInt;
  LoopSink  : Word;       { keeps the empty loop from being optimised away }
  FpuDiffs  : Integer;
  FpuWhy    : ShortString;

  { ---- far layer skylines ---- }
  MtnTop    : array[0..PERIOD - 1] of Integer;
  CityTop   : array[0..PERIOD - 1] of Integer;
  CityLit   : array[0..PERIOD - 1] of Byte;

  { ---- sprites ---- }
  Shape     : array[0..SPR_H - 1, 0..SPR_W - 1] of Byte;
  SprDI     : array[0..NSPR - 1, 0..3, 0..SPR_H - 1, 0..SPR_K - 1] of Byte;
  SprSpan   : array[0..NSPR - 1, 0..3, 0..SPR_H - 1, 0..1] of Byte;
  SprR0     : array[0..NSPR - 1] of Word;
  SprRH     : array[0..NSPR - 1] of Word;
  SprHoles  : Integer;                      { transparent pixels inside a run }
  CarX      : array[0..NSPR - 1] of Word;
  CarY      : array[0..NSPR - 1] of Word;
  CarBot    : array[0..NSPR - 1] of Word;   { last band row the car touches }
  { The blitter's source addresses, worked out ONCE.  Taking Seg() and Ofs()
    of SprDI[I, G, R0, 0] at draw time looks free and is not: it is a
    four-dimensional index with three runtime subscripts, so FPC emits three
    multiplies for it, and the same again for the span table -- twenty-four
    multiplies a frame at 17us each on this machine.  The blit itself is only
    288 bytes.  Measured in situ, the two cars cost 4.5ms of a 14.3ms frame
    before this, and the pixels were never the problem. }
  SprSeg    : Word;
  SprDIOfs  : array[0..NSPR - 1, 0..3] of Word;
  SprSpOfs  : array[0..NSPR - 1, 0..3] of Word;
  SprPh     : array[0..NSPR - 1] of Word;   { lateral weave }
  SprBob    : array[0..NSPR - 1] of Word;   { hover }

  Rnd       : Word;

  { Scratch the coprocessor blocks read and write.  Globals rather than
    locals: an x87 memory operand takes the default segment for its
    addressing mode, and a global is DS-relative with nothing to think
    about. }
  FI, FJ, FK: LongInt;
  FCw       : Word;

const
  { Quarter sine, 0..90 degrees in 64 steps, scaled to +-64. }
  SinQ: array[0..64] of Integer = (
      0,   2,   3,   5,   6,   8,   9,  11,  12,  14,  16,  17,  19,
     20,  22,  23,  24,  26,  27,  29,  30,  32,  33,  34,  36,  37,
     38,  39,  41,  42,  43,  44,  45,  46,  47,  48,  49,  50,  51,
     52,  53,  54,  55,  56,  56,  57,  58,  59,  59,  60,  60,  61,
     61,  62,  62,  62,  63,  63,  63,  64,  64,  64,  64,  64,  64);

{ ================================================================ helpers }

function NumStr(V: LongInt): ShortString;
var
  S: ShortString;
  N: Boolean;
begin
  { SysUtils would drag a lot of dead weight into a real-mode binary for the
    sake of IntToStr; see CLAUDE.md. }
  if V = 0 then begin NumStr := '0'; Exit; end;
  N := V < 0;
  if N then V := -V;
  S := '';
  while V > 0 do
  begin
    S := Chr(Ord('0') + (V mod 10)) + S;
    V := V div 10;
  end;
  if N then S := '-' + S;
  NumStr := S;
end;

function HexStr(V: Word): ShortString;
const
  D = '0123456789ABCDEF';
var
  S: ShortString;
  I: Integer;
begin
  S := '';
  for I := 0 to 3 do
  begin
    S := D[1 + (V and 15)] + S;
    V := V shr 4;
  end;
  HexStr := S + 'h';
end;

function Pad(const S: ShortString; N: Integer): ShortString;
var
  R: ShortString;
begin
  R := S;
  while Length(R) < N do R := R + ' ';
  Pad := R;
end;

function Clamp(V, Lo, Hi: Integer): Integer;
begin
  if V < Lo then Clamp := Lo
  else if V > Hi then Clamp := Hi
  else Clamp := V;
end;

function Random16: Word;
begin
  { Plain LCG.  The scenery only has to look unrepeatable, and this keeps the
    world identical between runs -- which matters when two frame-rate
    measurements are being compared. }
  Rnd := Rnd * 25173 + 13849;
  Random16 := Rnd;
end;

function Sine(A: Word): Integer;
var
  I: Word;
begin
  I := A and 255;
  if I < 64 then Sine := SinQ[I]
  else if I < 128 then Sine := SinQ[128 - I]
  else if I < 192 then Sine := -SinQ[I - 128]
  else Sine := -SinQ[256 - I];
end;

{ Phase for N whole cycles across the 704-column world.  Whole cycles are
  what make the world join up to itself at the wrap. }
function Phase(X, N: Word): Word;
begin
  Phase := ((X * 8 * N) div 22) and 255;
end;

function ParseInt(const S: ShortString; out V: Integer): Boolean;
var
  I: Integer;
begin
  V := 0;
  if Length(S) = 0 then begin ParseInt := False; Exit; end;
  for I := 1 to Length(S) do
  begin
    if (S[I] < '0') or (S[I] > '9') then begin ParseInt := False; Exit; end;
    V := V * 10 + (Ord(S[I]) - Ord('0'));
  end;
  ParseInt := True;
end;

function Upper(const S: ShortString): ShortString;
var
  I: Integer;
  R: ShortString;
begin
  R := S;
  for I := 1 to Length(R) do
    if (R[I] >= 'a') and (R[I] <= 'z') then R[I] := Chr(Ord(R[I]) - 32);
  Upper := R;
end;

{ ============================================================ microseconds }

{ The BIOS tick is 54.9ms, which cannot tell a quarter-second apart from a
  fifth.  Channel 0 of the PIT is the same clock before the divider, so
  reading its counter gives the fraction of the current tick at 0.84us.

  The tick and the counter must be read consistently: if the tick rolls over
  between the two reads the answer is a whole 54.9ms out, which on a
  quarter-second measurement is a 22% error and would decide the race by
  itself.  Reading the tick on both sides and retrying when it moved is the
  standard fix and costs nothing -- it almost never retries. }

var
  MicBaseT: LongInt;
  MicBaseC: Word;

function ReadPit0: Word; assembler;
asm
  mov  al, 0          { latch counter 0 }
  mov  dx, 43h
  out  dx, al
  mov  dx, 40h
  in   al, dx
  mov  bl, al
  in   al, dx
  mov  ah, al
  mov  al, bl
end;

procedure SampleClock(out T: LongInt; out C: Word);
var
  T2: LongInt;
begin
  repeat
    T  := MemL[$0040:$006C];
    C  := ReadPit0;
    T2 := MemL[$0040:$006C];
  until T = T2;
end;

procedure MicReset;
begin
  SampleClock(MicBaseT, MicBaseC);
end;

function MicRead: LongInt;
var
  T : LongInt;
  C : Word;
  Us: LongInt;
begin
  SampleClock(T, C);
  { Counter 0 counts DOWN, so the part of the tick already spent is
    65536 - counter.  0.8381us a count, taken as 3433/4096 to keep the
    product inside a LongInt: 65536 * 3433 is 225 million. }
  Us := (T - MicBaseT) * USPERTICK;
  Inc(Us, (LongInt(65536 - C) * 3433) shr 12);
  Dec(Us, (LongInt(65536 - MicBaseC) * 3433) shr 12);
  MicRead := Us;
end;

{ ====================================================== perspective tables }

{ Both builds fill the same three tables.  They are written to separate
  arrays so the results can be compared before either is believed -- a
  coprocessor path that is faster and WRONG is the failure mode worth
  guarding against, and it is invisible unless you look. }

{ BOTH PATHS TRUNCATE, and that is a correctness decision rather than a
  taste in rounding.

  The first version had the integer path round half-up and left the
  coprocessor on its default round-to-nearest-EVEN, and the two disagreed on
  exactly eight of 217 entries -- every fourth row of the grid spacing, where
  GW*d/64 lands on an exact half and the two rules break the tie in opposite
  directions.  Eight wrong entries out of 217 is a floor with a visible kink
  in it, and the demo would have shipped with the coprocessor path switched
  off and a report line blaming it.

  Truncation removes the tie instead of arbitrating it: floor has no
  half-way case at all, so the two paths are bit-identical by construction
  and the agreement check is a real check rather than a tolerance. }
function ISqrtR(N: LongInt): LongInt;
var
  Rem, Root, Bit: LongInt;
begin
  { Digit-by-digit integer square root, truncated.  All 32-bit, which on an
    8086-class machine is exactly the work CLAUDE.md says costs five to eight
    times its 16-bit equivalent -- and that is the point: this is the honest
    integer competitor, not a straw man. }
  if N <= 0 then begin ISqrtR := 0; Exit; end;
  Root := 0;
  Rem  := N;
  Bit  := LongInt(1) shl 30;
  while Bit > Rem do Bit := Bit shr 2;
  while Bit <> 0 do
  begin
    if Rem >= Root + Bit then
    begin
      Dec(Rem, Root + Bit);
      Root := (Root shr 1) + Bit;
    end
    else
      Root := Root shr 1;
    Bit := Bit shr 2;
  end;
  ISqrtR := Root;
end;

procedure BuildInt;
var
  B, K, Dy: Integer;
  D       : LongInt;
begin
  for B := 0 to BANDH - 1 do
  begin
    D := B + D0;
    RefSpace[B] := Integer((LongInt(GW) * D) shr 6);
    RefZof[B]   := Word(LongInt(ZK) div D);
  end;
  for K := 0 to 2 * SUNR do
  begin
    Dy := K - SUNR;
    RefSun[K] := Integer(ISqrtR(LongInt(SUNR) * SUNR - LongInt(Dy) * Dy));
  end;
end;

const
  { FIMUL and FIDIV take their operand from memory, so the constants they
    use have to be addressable rather than immediate. }
  F64: LongInt = 64;

{ The same three tables on the coprocessor.  FILD/FIMUL/FIDIV/FSQRT/FISTP --
  integers in, integers out, with the arithmetic in between done at 80 bits.
  Never called unless HasFpu said yes: an ESC opcode on a machine with no
  coprocessor does not fault on an 8086, it is simply ignored, so the code
  would run and quietly produce garbage. }
procedure BuildFpu;
var
  B, K, Dy: Integer;
begin
  { FNINIT leaves the control word at 037Fh, which is round to nearest even.
    0F7Fh is the same word with the rounding field set to truncate, so every
    FISTP below floors -- see the note on ISqrtR for why that matters more
    than it looks. }
  FCw := $0F7F;
  asm
    fninit
    fldcw FCw
  end;
  for B := 0 to BANDH - 1 do
  begin
    FI := B + D0;
    FJ := GW;
    asm
      fild  FI
      fimul FJ
      fidiv F64
      fistp FK
      fwait
    end;
    SpacePx[B] := Integer(FK);

    FJ := ZK;
    asm
      fild  FJ
      fidiv FI
      fistp FK
      fwait
    end;
    Zof[B] := Word(FK);
  end;

  for K := 0 to 2 * SUNR do
  begin
    Dy := K - SUNR;
    FI := LongInt(SUNR) * SUNR - LongInt(Dy) * Dy;
    asm
      fild  FI
      fsqrt
      fistp FK
      fwait
    end;
    SunHW[K] := Integer(FK);
  end;
end;

{ Race the two, check they agree, keep the winner's answers.  Everything this
  decides is setup-only, so a wrong call costs startup time and can never
  cost a frame. }
procedure ChooseAndBuild;
var
  I, R: Integer;
begin
  FpuFitted  := HasFpu;
  FpuUsed    := False;
  UsIntBuild := 0;
  UsFpuBuild := 0;
  FpuDiffs   := 0;

  { The integer path always runs and is always timed -- it is the one that
    has to work everywhere. }
  MicReset;
  for R := 1 to BENCH_REPS do BuildInt;
  UsIntBuild := MicRead;

  if not FpuFitted then
    FpuWhy := 'no coprocessor fitted'
  else if not WantFpu then
    FpuWhy := 'NOFPU on the command line'
  else
  begin
    MicReset;
    for R := 1 to BENCH_REPS do BuildFpu;
    UsFpuBuild := MicRead;

    { Agreement before speed.  BuildFpu has just left its answers in the live
      tables and BuildInt left its in the reference ones. }
    for I := 0 to BANDH - 1 do
    begin
      if SpacePx[I] <> RefSpace[I] then Inc(FpuDiffs);
      if Zof[I] <> RefZof[I] then Inc(FpuDiffs);
    end;
    for I := 0 to 2 * SUNR do
      if SunHW[I] <> RefSun[I] then Inc(FpuDiffs);

    if FpuDiffs <> 0 then
      FpuWhy := 'it disagreed with the integer path -- not trusted'
    else if UsFpuBuild < UsIntBuild then
    begin
      FpuUsed := True;
      FpuWhy  := 'measured faster on this machine';
    end
    else
      FpuWhy := 'measured SLOWER than the integer path here';
  end;

  { Whichever won, the live tables are filled from the reference copy unless
    the coprocessor earned them.  BuildFpu already wrote them, so this is
    only needed the other way round. }
  if not FpuUsed then
  begin
    for I := 0 to BANDH - 1 do
    begin
      SpacePx[I] := RefSpace[I];
      Zof[I]     := RefZof[I];
    end;
    for I := 0 to 2 * SUNR do SunHW[I] := RefSun[I];
  end;

  { Everything derived from the tables, which is the same either way. }
  NHaze := 0;
  for I := 0 to BANDH - 1 do
  begin
    if SpacePx[I] < MINSP then
    begin
      SpacePx[I] := 0;                            { 0 = haze, no lines }
      if I = NHaze then Inc(NHaze);
    end;
    FloorCol[I] := C_FLOOR + Byte((I * N_FLOOR) div BANDH);
    { Grid lines fade with distance, so the ramp runs the other way: the
      brightest neon is at the horizon where the lines are densest. }
    GridCol[I] := C_GRID + Byte(((BANDH - 1 - I) * N_GRID) div BANDH);
  end;
end;

{ ========================================================= command line }

procedure ParseArgs;
var
  I, V: Integer;
  A   : ShortString;
begin
  RunSecs   := 30;
  Speed     := 7;
  SweepHalf := SWEEP_HALF;
  NSprites  := NSPR;
  WantMusic := True;
  WantFpu   := True;
  WantShot  := True;
  WantPause := True;
  Profiling := False;
  Forced    := '';
  BadArg    := '';
  Colour    := IsColourDisplay;

  I := 1;
  while I <= ParamCount do
  begin
    A := Upper(ParamStr(I));
    if A = 'MONO' then begin Colour := False; Forced := 'MONO'; end
    else if (A = 'COLOUR') or (A = 'COLOR') then
      begin Colour := True; Forced := A; end
    else if A = 'NOMUSIC' then WantMusic := False
    else if A = 'NOFPU'   then WantFpu   := False
    else if A = 'NOSHOT'  then WantShot  := False
    else if A = 'NOPAUSE' then WantPause := False
    else if A = 'PROF'    then Profiling := True
    else if (A = 'SECS') and (I < ParamCount) then
    begin
      Inc(I);
      if ParseInt(ParamStr(I), V) then RunSecs := Clamp(V, 1, 600)
      else BadArg := 'SECS ' + ParamStr(I);
    end
    else if (A = 'SWEEP') and (I < ParamCount) then
    begin
      Inc(I);
      if ParseInt(ParamStr(I), V) then SweepHalf := Clamp(V, 8, 192)
      else BadArg := 'SWEEP ' + ParamStr(I);
    end
    else if (A = 'SPEED') and (I < ParamCount) then
    begin
      Inc(I);
      if ParseInt(ParamStr(I), V) then Speed := Clamp(V, 1, 16)
      else BadArg := 'SPEED ' + ParamStr(I);
    end
    else if ((A = 'CARS') or (A = 'SPRITES')) and (I < ParamCount) then
    begin
      Inc(I);
      if ParseInt(ParamStr(I), V) then NSprites := Clamp(V, 0, NSPR)
      else BadArg := 'CARS ' + ParamStr(I);
    end
    else
      BadArg := ParamStr(I);
    Inc(I);
  end;
end;

{ ============================================================== palette }

{ One ramp, written to the DAC and to the luminance table at the same time.
  The grey values are supplied separately rather than derived: a mono
  monitor sums R+G+B, so two colours chosen for hue can land on the same
  grey, and a ramp that reads as depth in colour can read as noise without
  it.  The luminance table drives the ASCII thumbnail and always takes the
  grey, for the same reason. }
procedure Ramp(First, N: Integer;
               R0, G0, B0, R1, G1, B1: Integer;
               L0, L1: Integer);
var
  I, D: Integer;
begin
  D := N - 1;
  if D < 1 then D := 1;
  for I := 0 to N - 1 do
  begin
    DacSeek(Byte(First + I));
    if Colour then
      DacRGB(Byte(R0 + ((R1 - R0) * I) div D),
             Byte(G0 + ((G1 - G0) * I) div D),
             Byte(B0 + ((B1 - B0) * I) div D))
    else
      DacGrey(Byte(L0 + ((L1 - L0) * I) div D));
    Lum[First + I] := Byte(L0 + ((L1 - L0) * I) div D);
  end;
end;

procedure One(Idx, R, G, B, L: Integer);
begin
  DacSeek(Byte(Idx));
  if Colour then DacRGB(Byte(R), Byte(G), Byte(B)) else DacGrey(Byte(L));
  Lum[Idx] := Byte(L);
end;

procedure LoadPalette;
var
  I: Integer;
begin
  for I := 0 to 255 do Lum[I] := 0;
  One(0, 0, 0, 0, 0);

  { Sky: deep indigo overhead through violet to a hot magenta horizon.  The
    grey ramp climbs steadily so the sky still reads as getting lighter
    towards the horizon on a mono monitor. }
  Ramp(C_SKY, N_SKY,  4, 0, 14,  58, 14, 34,   3, 26);

  { The sun.  Pale gold at the top through orange to magenta at the bottom,
    which is the one gradient this whole look is built on. }
  One(C_SUN + 0, 63, 60, 28, 62);
  One(C_SUN + 1, 63, 48, 16, 57);
  One(C_SUN + 2, 63, 34, 12, 52);
  One(C_SUN + 3, 62, 22, 20, 47);
  One(C_SUN + 4, 56, 12, 32, 42);
  One(C_SUN + 5, 46,  6, 40, 37);

  { The ridge is nearly black against the sky, with a lit rim.  On mono it
    has to go the other way -- DARKER than the sky it sits against -- or the
    silhouette stops being a silhouette. }
  One(C_MTN + 0,  8,  2, 18,  6);
  One(C_MTN + 1, 14,  4, 26, 11);
  One(C_MTN + 2, 52, 18, 50, 40);

  One(C_CITY + 0,  5,  2, 14,  4);
  One(C_CITY + 1, 12,  6, 24,  9);
  One(C_CITY + 2, 58, 52, 20, 55);

  One(C_STAR + 0, 63, 63, 63, 63);
  One(C_STAR + 1, 46, 46, 56, 46);
  One(C_STAR + 2, 32, 32, 44, 33);

  One(C_HGLOW + 0, 63, 40, 58, 60);
  One(C_HGLOW + 1, 58, 24, 52, 51);
  One(C_HGLOW + 2, 44, 12, 44, 42);

  { The floor darkens towards the viewer so the grid lines on it stay the
    brightest thing in the band. }
  Ramp(C_FLOOR, N_FLOOR,  22, 2, 30,   4, 0, 10,   17, 4);

  { Grid neon: cyan at the horizon warming to magenta underfoot. }
  Ramp(C_GRID, N_GRID,  20, 62, 60,   60, 20, 62,   58, 44);

  { The two cars.  Four shades each, brightest first, written out rather
    than interpolated because a car is a drawing and its highlight wants to
    be near white while its body stays saturated -- which a linear ramp
    between the two will not give you.

    On mono all eight shades live at the top of the range.  The floor greys
    run 4 to 17 and the grid lines 44 to 58, so a car shaded by true
    luminance would sink into one or the other; these are spaced to stay
    above both. }
  One(C_SPR + 0, 63, 60, 42, 63);    { amber racer -- the one colour on the }
  One(C_SPR + 1, 63, 34,  8, 54);    { floor that is neither magenta nor    }
  One(C_SPR + 2, 40, 14,  2, 45);    { cyan, so it cannot hide in the grid  }
  One(C_SPR + 3, 20,  6,  0, 36);

  One(C_SPR + 4, 56, 63, 63, 60);    { cyan racer }
  One(C_SPR + 5, 16, 56, 60, 51);
  One(C_SPR + 6,  6, 32, 38, 42);
  One(C_SPR + 7,  2, 16, 20, 33);
end;

{ ====================================================== the screen split }

const
  AC_INDEX = $3C0;
  AC_READ  = $3C1;

procedure CrtcW(Idx, Val: Byte);
begin
  OutB(CrtcBase, Idx);
  OutB(CrtcBase + 1, Val);
end;

function CrtcR(Idx: Byte): Byte;
begin
  OutB(CrtcBase, Idx);
  CrtcR := InB(CrtcBase + 1);
end;

{ Blank and unblank the display, via the Sequencer's Clocking Mode register
  (3C4h index 01h, bit 5 "screen off").

  Everything this demo puts on the screen is built in VISIBLE video memory --
  there is no back buffer and no room for one -- so without this the first
  couple of seconds are a slideshow of the scenery being assembled: the sky
  bands filling in, the stars appearing, the sun being plotted a pixel at a
  time, the skyline going up column by column, and then sixty band repaints
  from the startup benchmarks, the last twenty of which draw the floor with
  no grid lines on it at all.  All of that is real work that has to happen;
  none of it is anything anybody wants to watch.

  The Sequencer is used rather than the Attribute Controller's palette-enable
  bit because ShowFar writes the AC to set the pixel pan, and an AC index
  write with bit 5 set would switch the screen back on halfway through the
  staging.  The Sequencer is independent of it.

  Turning the screen off also stops the CRTC fetching, which gives the CPU
  the full memory bandwidth -- so the world paints faster as well as
  invisibly.  The CRTC itself keeps running, so the retrace polling that
  paces everything still works while blanked. }
procedure ScreenOff;
var
  V: Byte;
begin
  OutB($3C4, 1);
  V := InB($3C5);
  OutB($3C4, 1);
  OutB($3C5, V or $20);
end;

procedure ScreenOn;
var
  V: Byte;
begin
  OutB($3C4, 1);
  V := InB($3C5);
  OutB($3C4, 1);
  OutB($3C5, V and $DF);
end;

{ Line compare is ten bits spread across three registers, which is the only
  awkward part.  Bit 8 lives in the Overflow register and bit 9 in Maximum
  Scan Line, both of which carry other fields that must survive untouched --
  clobbering Maximum Scan Line would undo mode 13h's line doubling and leave
  a picture in the top half of the screen. }
function SetSplit(Line: Word): Boolean;
var
  V: Byte;
begin
  AcMode := 0;
  CrtcW($18, Byte(Line and $FF));

  V := CrtcR($07) and $EF;
  if (Line and $0100) <> 0 then V := V or $10;
  CrtcW($07, V);

  V := CrtcR($09) and $BF;
  if (Line and $0200) <> 0 then V := V or $40;
  CrtcW($09, V);

  { Attribute Controller Mode Control bit 5, "pixel panning compatibility":
    with it set the pan is forced to zero below the split.  Without it the
    pinned band would pan with the far layer, so the sub-pixel smoothness
    that makes the sky creep nicely would appear as a one-to-three pixel
    wobble on the floor, at a different rate again.  Reading the register
    back needs 3C1h; writing it needs 3C0h, and bit 5 of the index has to
    stay set throughout or the palette goes dark. }
  { THE TWO BIT-5s HERE ARE DIFFERENT BITS, and conflating them is what
    turned the whole picture magenta the first time.

    Bit 5 of the INDEX byte written to 3C0h is Palette Address Source: it
    has to stay set on every index write or the screen goes black.  Bit 5 of
    the DATA byte of register 10h is Pixel Panning Compatibility, which is
    the one actually wanted.  They are written to the same port, and which
    one you are writing depends only on the state of a flip-flop that
    toggles on every write and is reset by reading the status register.

    The first version finished with an index write followed by `OutB($3C0,
    $20)`, meaning it as "re-enable the palette".  The flip-flop was in DATA
    state by then, so it landed on register 10h as data instead and cleared
    bit 6 -- 8-bit colour.  With PELWIDTH off, a 256-colour mode feeds the
    DAC the wrong thing entirely and every colour on screen is wrong.  The
    mode was fine, the palette was fine, and the picture was pink. }
  InB(StatBase);                  { reset the flip-flop to INDEX }
  OutB(AC_INDEX, $10 or $20);     { index := 10h, palette enabled -> DATA }
  V := InB(AC_READ);              { the current Mode Control }
  OutB(AC_INDEX, V or $20);       { data := it, with PPM set    -> INDEX }
  InB(StatBase);                  { back to INDEX, and stay there }
  OutB(AC_INDEX, $20);            { palette enabled, nothing else touched }

  { Read it all back, Mode Control included.  A card that quietly ignored one
    of these leaves a picture that is wrong rather than absent, which is a
    confusing way to spend an afternoon -- and the Mode Control check is here
    because getting that register wrong is exactly how an afternoon went. }
  InB(StatBase);
  OutB(AC_INDEX, $10 or $20);
  AcMode := InB(AC_READ);
  InB(StatBase);
  OutB(AC_INDEX, $20);

  SetSplit := (CrtcR($18) = Byte(Line and $FF))
          and (((CrtcR($07) and $10) <> 0) = ((Line and $0100) <> 0))
          and (((CrtcR($09) and $40) <> 0) = ((Line and $0200) <> 0))
          and ((AcMode and $20) <> 0)    { pixel panning compatibility }
          and ((AcMode and $40) <> 0);   { 8-bit colour -- the pink bug }
end;

{ ModeX.ShowAt assumes the picture starts at address zero.  Here it starts
  FARBASE in, above the pinned band, so this is that routine with the base
  added -- and nothing else changed, because the ORDER of the two waits is
  what stops the picture tearing three pixels sideways.  See modex.pas. }
procedure ShowFar(PixX: Word);
var
  Addr, Guard: Word;
begin
  Addr := FARBASE + (PixX shr 2);

  if (InB(StatBase) and 8) <> 0 then Inc(FlipLate);

  { Wait for active display, so both halves of the start address are written
    well before the retrace latches them and the picture cannot be shown with
    one byte old and one byte new. }
  Guard := 0;
  while ((InB(StatBase) and 1) <> 0) and (Guard < 60000) do Inc(Guard);
  if Guard >= 60000 then Inc(FlipTimeouts);

  CrtcW($0C, Hi(Addr));
  CrtcW($0D, Lo(Addr));

  { THE PAN IS SET HERE, BEFORE THE RETRACE, AND THAT IS THE WHOLE FIX.

    ModeX.ShowAt sets it AFTER waiting for the retrace, and says the order
    matters because the CRTC latches the start address at the top of the
    retrace while the Attribute Controller latches the pan at the start of the
    frame.  On this card the pan written after the retrace has begun is
    already too late: it takes effect one refresh later than the address it
    belongs with.

    Most of the time that is invisible, because both are advancing.  It shows
    up on the one frame in four where the pan WRAPS -- the address steps on by
    a whole four-pixel unit and the pan drops 3 to 0.  For that frame the
    screen gets the new address with the old pan, which is the far layer four
    pixels too far along, and then it snaps three pixels back.  A frame here
    is two refreshes, so the first refresh shows the jump and the second shows
    the correction: a 4-pixel shimmer of the entire sky, skyline and sun, at
    35 Hz.

    Measured off the capture card before the fix: the sun advanced a clean
    +1.1 screen pixels a frame, then +4.5 and -3.4 on every fourth frame,
    repeating exactly.  That periodicity -- one in four, the pan's own period
    -- is what identified it; the size alone could have been anything.

    Written before the wait, both registers are latched by the same retrace
    and the far layer moves one pixel a frame with nothing else happening. }
  InB(StatBase);                       { reset the AC index/data flip-flop }
  OutB(AC_INDEX, $13 or $20);
  OutB(AC_INDEX, (PixX and 3) shl 1);

  { Now the retrace itself.  This is what paces the whole demo. }
  Guard := 0;
  while ((InB(StatBase) and 8) = 0) and (Guard < 60000) do Inc(Guard);
  if Guard >= 60000 then Inc(FlipTimeouts);
end;

{ ============================================================ primitives }

{ A horizontal run as WORDS rather than bytes.  ModeX.HSpan is REP STOSB,
  which is the right shape for arbitrary lengths; the band repaint always
  moves a whole 320-pixel row, so it can halve the iteration count and with
  it the single largest cost in the frame. }
procedure FillW(Ofs, Words: Word; Col: Byte); assembler;
asm
  push es
  push di
  mov  ax, VGA_SEG
  mov  es, ax
  mov  di, Ofs
  mov  cx, Words
  mov  al, Col
  mov  ah, al
  cld
  rep  stosw
  pop  di
  pop  es
end;

{ One row of the grid: every vertical line in it, evenly spaced.

  THIS ROUTINE IS WHY THE DEMO RUNS.  The first version was the obvious Pascal
  loop, `Mem[VGA_SEG : Base + (X shr 2)] := Col` stepping X by the spacing, and
  it cost 17 fps.  CLAUDE.md says why in one line: every Mem[] access reloads a
  far pointer, and it measures the Pascal path to video at 58640 stores a
  second -- 17us each.

  The second version held ES once and recomputed the address from a 64ths-of-a-
  pixel accumulator every line: `mov ax,si / mov al,ah / xor ah,ah / add ax,bx /
  mov di,ax`, five instructions and a 15-cycle JMP back, measured at 9.2us a
  line.  This one steps the address DIRECTLY, carrying the fraction in a second
  register and letting ADC move the address when it overflows -- so the whole
  per-line cost is a store, an add, an adc and a bottom test, about 4.7us.

  There are two entry points rather than one with a flag, because a test inside
  the loop costs more than the duplicated setup outside it.  The wide variant
  writes a second byte unconditionally: the last line can put it at address 80,
  which is off the visible 320 pixels and, now that the cars need no backing
  store, off anything else too. }

procedure GridRow(Base, X0, Step, Col: Word); assembler;
asm
  push es
  push di
  push si
  push bx
  mov  ax, VGA_SEG
  mov  es, ax

  mov  ax, X0
  mov  dx, ax
  mov  dl, dh
  xor  dh, dh          { dx = X0 shr 8, the whole addresses }
  add  dx, Base
  mov  di, dx          { di = the first address }
  mov  ah, al
  xor  al, al
  mov  si, ax          { si = the fraction, in the high byte }

  mov  ax, Step
  mov  dx, ax
  mov  dl, dh
  xor  dh, dh
  mov  bx, dx          { bx = whole addresses per line }
  mov  ah, al
  xor  al, al
  mov  cx, ax          { cx = fraction per line }

  mov  ax, Base
  add  ax, DISP_W / 4  { the limit: one past the visible 320 pixels }
  mov  dx, Col         { dl = the colour }

@@l:
  mov  es:[di], dl
  add  si, cx
  adc  di, bx
  cmp  di, ax
  jb   @@l

  pop  bx
  pop  si
  pop  di
  pop  es
end;

procedure GridRowWide(Base, X0, Step, Col: Word); assembler;
asm
  push es
  push di
  push si
  push bx
  mov  ax, VGA_SEG
  mov  es, ax

  mov  ax, X0
  mov  dx, ax
  mov  dl, dh
  xor  dh, dh
  add  dx, Base
  mov  di, dx
  mov  ah, al
  xor  al, al
  mov  si, ax

  mov  ax, Step
  mov  dx, ax
  mov  dl, dh
  xor  dh, dh
  mov  bx, dx
  mov  ah, al
  xor  al, al
  mov  cx, ax

  mov  ax, Base
  add  ax, DISP_W / 4
  mov  dx, Col

@@l:
  mov  es:[di], dl
  mov  es:[di + 1], dl
  add  si, cx
  adc  di, bx
  cmp  di, ax
  jb   @@l

  pop  bx
  pop  si
  pop  di
  pop  es
end;

{ ====================================================== the far layer }

procedure BuildSkylines;
var
  X, T, W, H, G, I: Integer;
begin
  for X := 0 to PERIOD - 1 do
  begin
    { Three frequencies, all whole cycles across 704, so column 703 runs into
      column 0 without a step. }
    MtnTop[X] := 96 + (Sine(Phase(X, 1)) * 14) div 64
                    + (Sine(Phase(X, 3)) *  7) div 64
                    + (Sine(Phase(X, 7)) *  4) div 64;
    CityTop[X] := SPLIT;
    CityLit[X] := 0;
  end;

  { Towers, generated across the WHOLE world.

    They used to stop at PERIOD - DUPW, which is world column 384 of 704.
    That bound came from the wrap: the last DUPW columns get overwritten by a
    copy of the first DUPW, so a tower straddling the join would be cut in
    half.  It was correct when the view scrolled one way forever and wrapped.

    It stopped being correct the moment the view started sweeping instead,
    and it is what "the cityscape scrolls to one side much more than the
    other" actually was.  The city existed only in the left half of the
    world, so sweeping right drained it off the screen -- 288 of 320 pixels
    of skyline at one end of the sweep against 96 at the other -- while the
    mountains and stars, which are generated across the full PERIOD, stayed
    put.  Nothing was moving unevenly.  There was simply nothing there.

    The window now spans world 96..608 at the extremes of the sweep and never
    comes near the seam at 704, so the towers can run the whole way and the
    join does not matter.  The last one is clipped at PERIOD so it cannot
    write past the end of the array. }
  Rnd := 4711;
  X := 0;
  while X < PERIOD do
  begin
    W := 7 + (Random16 mod 18);
    H := 10 + (Random16 mod 22);
    T := SPLIT - H;
    if X + W > PERIOD then W := PERIOD - X;
    for I := 0 to W - 1 do
    begin
      CityTop[X + I] := T;
      { A lit face on the left three columns of every tower, and windows in
        a regular grid: two cues that say "building" for almost nothing. }
      if I < 3 then CityLit[X + I] := 1 else CityLit[X + I] := 0;
    end;
    G := 4 + (Random16 mod 13);
    Inc(X, W + G);
  end;
end;

procedure PaintSky;
var
  Y, Band: Integer;
begin
  MapMask($0F);
  for Y := 0 to SPLIT - 1 do
  begin
    Band := (Y * N_SKY) div SPLIT;
    HSpan(Word(FARROW + Y) * VWB, VWB, Byte(C_SKY + Band));
  end;
end;

procedure PaintStars;
var
  K, X, Y: Integer;
begin
  for K := 1 to 300 do
  begin
    X := Random16 mod PERIOD;
    Y := 2 + (Random16 mod 62);
    { Only a few of the brightest, or it reads as noise rather than sky. }
    if (K and 7) = 0 then PlotPix(X, FARROW + Y, C_STAR)
    else PlotPix(X, FARROW + Y, Byte(C_STAR + 1 + (K and 1)));
  end;
end;

{ The sun: a disc with horizontal slits that widen towards the bottom, which
  is the single image this entire palette exists to serve.  SunHW came out of
  the perspective table build -- it is the one square root in the program, and
  the reason the coprocessor gets a look in at all. }
procedure PaintSun;
var
  K, Dy, Y, HW, X, X0, X1, Gap, Per, Sh: Integer;
begin
  for K := 0 to 2 * SUNR do
  begin
    Dy := K - SUNR;
    Y  := SUNY + Dy;
    if (Y < 0) or (Y >= SPLIT) then Continue;
    HW := SunHW[K];
    if HW <= 0 then Continue;

    { Slits only below the sun's shoulder, widening as they go down.  Above
      it the disc is solid, which is what makes the thing read as a sun
      rather than as a barcode. }
    if Dy >= -8 then
    begin
      Per := 11;
      Gap := 1 + (Dy + 8) div 13;
      if ((Dy + 8) mod Per) < Gap then Continue;
    end;

    Sh := ((Dy + SUNR) * N_SUN) div (2 * SUNR + 1);
    Sh := Clamp(Sh, 0, N_SUN - 1);

    X0 := SUNX - HW;
    X1 := SUNX + HW;
    for X := X0 to X1 do
      if (X >= 0) and (X < PERIOD) then
        PlotPix(X, FARROW + Y, Byte(C_SUN + Sh));
  end;
end;

procedure PaintColumn(X: Integer);
var
  Base, Mt, Ct, Y: Integer;
begin
  Base := X shr 2;
  MapMask(1 shl (X and 3));

  { The ridge, with two rows of lit rim along the top. }
  Mt := MtnTop[X];
  VRun(Word(FARROW + Mt) * VWB + Word(Base), SPLIT - Mt, C_MTN);
  VRun(Word(FARROW + Mt) * VWB + Word(Base), 2, C_MTN + 2);

  { Towers in front of it. }
  Ct := CityTop[X];
  if Ct < SPLIT then
  begin
    if CityLit[X] <> 0 then
      VRun(Word(FARROW + Ct) * VWB + Word(Base), SPLIT - Ct, C_CITY + 1)
    else
      VRun(Word(FARROW + Ct) * VWB + Word(Base), SPLIT - Ct, C_CITY);

    { Windows: every third column, every fourth row.  Regular on purpose --
      irregular windows at this size just look like dirt. }
    if (X mod 3) = 0 then
    begin
      Y := Ct + 3;
      while Y < SPLIT - 2 do
      begin
        Mem[VGA_SEG : Word(FARROW + Y) * VWB + Word(Base)] := C_CITY + 2;
        Inc(Y, 4);
      end;
    end;
  end;
end;

{ The glow where the far layer meets the floor.  Painted last, over
  everything, so mountains and towers are cut off by it cleanly -- the
  horizon is supposed to be the brightest line on the screen. }
procedure PaintGlow;
var
  Y: Integer;
begin
  MapMask($0F);
  for Y := 0 to 2 do
    HSpan(Word(FARROW + SPLIT - 3 + Y) * VWB, VWB, Byte(C_HGLOW + 2 - Y));
end;

procedure PaintWorld;
var
  X: Integer;
begin
  Rnd := 31337;
  PaintSky;
  PaintStars;
  PaintSun;
  for X := 0 to PERIOD - 1 do PaintColumn(X);
  PaintGlow;

  { The seam: the last DUPW columns are made a copy of the first DUPW, so a
    320-wide window at scroll 703 shows the end of the world followed by its
    beginning and the wrap needs no repainting at all.  704 + 320 = 1024 is
    the whole trick.  Both edges are four-pixel aligned, so this is a straight
    address-range move and the latches carry all four planes at once. }
  CopyRect(FARBASE, VWB, FARBASE + PERIOD div 4, VWB, DUPW div 4, SPLIT);
end;

{ ================================================================ sprites }

{ The two cars, as pixel art rather than as a formula.

  The rest of the scenery here is generated -- skylines from sine sums, the
  sun from a square root, the grid from the perspective -- because generated
  scenery can be a thousand pixels wide for twenty lines of code.  A car
  cannot.  A recognisable vehicle at 24 by 10 is a drawing, and the only
  honest way to write a drawing is to draw it.

      H  highlight, the brightest shade      D  underside
      B  body                                S  shadow
      space  transparent

  Both face right, and the bar under each one is its hover glow.

  EVERY ROW MUST BE ONE CONTIGUOUS RUN OF NON-SPACE, and that is a constraint
  the blitter imposes rather than a style.  A sprite row is copied as a single
  REP MOVSB per column group, from the first opaque pixel of the group to the
  last, and any transparent pixel caught between them is copied too -- as
  colour 0, which is black.  The first pair of cars had separate left and
  right thruster pads with a gap between, so six black pixels were stamped
  across the underside of each car every frame.  On a dark floor that does not
  read as a bug, it reads as the car being see-through.

  A contiguous row gives every group a contiguous run of samples, so the rule
  is sufficient as well as necessary.  BuildSprites counts violations and the
  report prints the count, so it cannot come back silently. }
const
  CarArt: array[0..NSPR - 1, 0..SPR_H - 1] of String[SPR_W] = (
    ('                        ',
     '          HHHH          ',
     '       HHHBBBBHH        ',
     '    HHHBBBBBBBBHH       ',
     '  HHBBBBBBBBBBBBBHH     ',
     ' HBBBBBBBBBBBBBBBBBHH   ',
     'HBBBBBBBBBBBBBBBBBBBBH  ',
     'HDDDDDDDDDDDDDDDDDDDDH  ',
     ' DDDDDDDDDDDDDDDDDDDD   ',
     '   HHHHHHHHHHHHHHHH     ',
     '      BBBBBBBBBB        ',
     '                        '),

    ('              HH        ',
     '       HHHHHHHHH        ',
     '    HHHBBBBHHHHH        ',
     '  HHHBBBBBBBBBBBHH      ',
     ' HHBBBBBBBBBBBBBBBHH    ',
     'HBBBBBBBBBBBBBBBBBBBH   ',
     'HBBBBBBBBBBBBBBBBBBBBH  ',
     'HDDDDDDDDDDDDDDDDDDDDH  ',
     '  DDDDDDDDDDDDDDDDDD    ',
     '    HHHHHHHHHHHHHH      ',
     '       BBBBBBBBB        ',
     '                        '));

procedure BuildSprites;
var
  S, C, R, G, K          : Integer;
  First, Last, RFirst, RLast: Integer;
  Ch                     : Char;
  Sh                     : Integer;
  Any                    : Boolean;
begin
  SprHoles := 0;
  for S := 0 to NSPR - 1 do
  begin
    RFirst := SPR_H;
    RLast  := -1;

    for R := 0 to SPR_H - 1 do
    begin
      Any := False;
      for C := 0 to SPR_W - 1 do
      begin
        Ch := CarArt[S, R][C + 1];
        case Ch of
          'H': Sh := 0;
          'B': Sh := 1;
          'D': Sh := 2;
          'S': Sh := 3;
        else
          Sh := -1;
        end;
        if Sh < 0 then
          Shape[R, C] := 0
        else
        begin
          Shape[R, C] := Byte(C_SPR + S * 4 + Sh);
          Any := True;
        end;
      end;
      if Any then
      begin
        if R < RFirst then RFirst := R;
        RLast := R;
      end;
    end;

    if RLast < RFirst then begin RFirst := 0; RLast := 0; end;
    SprR0[S] := RFirst;
    SprRH[S] := RLast - RFirst + 1;

    SprSeg := Seg(SprDI[0, 0, 0, 0]);
    for G := 0 to 3 do
    begin
      SprDIOfs[S, G] := Ofs(SprDI[S, G, RFirst, 0]);
      SprSpOfs[S, G] := Ofs(SprSpan[S, G, RFirst, 0]);
    end;

    { Deinterleave into the four column groups c mod 4.  Within one group the
      six columns land on six CONSECUTIVE addresses in one plane, which is
      what turns the inner loop into a REP MOVSB instead of six test-and-
      store sequences.  Which plane a group goes to depends on the sprite x;
      the grouping does not, so this is built once and works everywhere. }
    for G := 0 to 3 do
      for R := 0 to SPR_H - 1 do
      begin
        First := -1;
        Last  := -1;
        for K := 0 to SPR_K - 1 do
        begin
          SprDI[S, G, R, K] := Shape[R, G + K * 4];
          if Shape[R, G + K * 4] <> 0 then
          begin
            if First < 0 then First := K;
            Last := K;
          end;
        end;
        if First < 0 then
        begin
          SprSpan[S, G, R, 0] := 0;
          SprSpan[S, G, R, 1] := 0;
        end
        else
        begin
          SprSpan[S, G, R, 0] := First;
          SprSpan[S, G, R, 1] := Last - First + 1;
          { Anything transparent inside the run will be blitted as black.
            Counted rather than worked around: the fix belongs in the art. }
          for K := First to Last do
            if SprDI[S, G, R, K] = 0 then Inc(SprHoles);
        end;
      end;
  end;
end;

{ Where each car sits.  They weave rather than drive off the edges, and that
  is a choice about what a race looks like as much as one about clipping.

  The blitter has no horizontal clip -- a sprite is whole column groups of
  consecutive addresses, and trimming one costs more than this demo can
  spend.  Driving the cars off the screen would therefore mean popping them
  in and out at the edges.  But a racing camera does not sit still and watch
  cars leave: it travels with them, and what moves is the ground.  The
  ground here is already rushing past at 280 pixels a second, so keeping the
  cars in shot and letting them jockey against each other reads as a race
  AND never touches an edge.  The two weave periods are different -- 128
  frames against 85 -- so they change places continually instead of drifting
  in lockstep. }
const
  CarCx   : array[0..NSPR - 1] of Integer = (138, 134);
  CarAmp  : array[0..NSPR - 1] of Integer = (118, 108);
  CarRate : array[0..NSPR - 1] of Word    = (2, 3);
  { Well apart, and both in the near half of the floor.  The first version
    put one at row 30, where the grid lines are still magenta, and painted it
    magenta -- it was on screen the whole time and could not be seen. }
  CarLane : array[0..NSPR - 1] of Integer = (15, 24);
  CarBobR : array[0..NSPR - 1] of Word    = (5, 7);

procedure InitSprites;
var
  I: Integer;
begin
  for I := 0 to NSPR - 1 do
  begin
    SprPh[I]  := Word(I) * 96;
    SprBob[I] := Word(I) * 40;
  end;
end;

{ One column group of one sprite: Rows rows of up to SPR_K consecutive bytes,
  source stride SPR_K, destination stride VWB.  Lifted from
  starter/scroller.pas, where the history is recorded: the first version
  tested and stored one pixel at a time and cost 60% of the whole frame.
  Transparency comes from the precomputed run rather than a test per pixel,
  so the fast path stays a string operation. }
procedure SprGroup(SSeg, SOfs, SpanOfs, VOfs, Rows: Word); assembler;
asm
  push ds
  push es
  push si
  push di
  push bx
  mov  si, SOfs
  mov  bx, SpanOfs
  mov  di, VOfs
  mov  dx, Rows
  mov  ax, VGA_SEG
  mov  es, ax
  mov  ax, SSeg
  mov  ds, ax
  cld
@@row:
  mov  al, [bx]        { first opaque pixel of this row, 0..SPR_K-1 }
  xor  ah, ah
  add  si, ax
  add  di, ax
  mov  cl, [bx + 1]    { how many of them }
  xor  ch, ch
  add  ax, cx
  jcxz @@empty
  rep  movsb
@@empty:
  { Wind back rather than saving the row start on the stack: two SUBs against
    four stack operations, and at hundreds of rows a frame that is worth more
    than it looks. }
  sub  si, ax
  sub  di, ax
  add  bx, 2
  add  si, SPR_K
  add  di, VWB
  dec  dx
  jnz  @@row
  pop  bx
  pop  di
  pop  si
  pop  es
  pop  ds
end;

{ The Sequencer's Map Mask, written directly.  ModeX.MapMask is a far call
  that makes two more to VGA.OutB; at four a sprite and two sprites a frame
  that is twenty-four far calls for six OUT instructions. }
procedure SetPlane(M: Byte); assembler;
asm
  mov  dx, 3C4h
  mov  al, 2
  out  dx, al
  inc  dx
  mov  al, M
  out  dx, al
end;

procedure DrawSprite(I: Integer; WX, WY: Word);
var
  G, RowBase, Rows: Word;
begin
  { The row address does not depend on the column group, so it is computed
    once rather than four times -- one multiply instead of four. }
  RowBase := (WY + SprR0[I]) * VWB;
  Rows    := SprRH[I];
  for G := 0 to 3 do
  begin
    { Group G holds sprite columns G, G+4 ... G+20.  All of them land in
      plane (WX + G) mod 4 at consecutive addresses from (WX + G) div 4, so
      the sprite x supplies the phase and the group table never shifts. }
    SetPlane(1 shl ((WX + G) and 3));
    SprGroup(SprSeg, SprDIOfs[I, G], SprSpOfs[I, G],
             RowBase + ((WX + G) shr 2), Rows);
  end;
end;

{ ========================================================== the grid floor }

{ The whole of the per-frame background, and the reason the parallax is real.

  Not one OUT instruction in it: the map mask is set to all four planes once
  before the loop and every write after that -- the row fill, the depth
  lines, the grid lines -- paints four pixels at a time at a four-pixel
  boundary.  That granularity is why the grid lines are four pixels wide,
  and at these speeds nobody can tell. }
{ The row fills of a band repaint and nothing else, so the benchmark can say
  how the cost divides between moving bulk pixels and placing the lines.
  Never called from the frame loop. }
procedure BandFillOnly;
var
  B   : Integer;
  Base: Word;
begin
  MapMask($0F);
  Base := 0;
  for B := 0 to BANDH - 1 do
  begin
    FillW(Base, DISP_W div 8, FloorCol[B]);
    Inc(Base, VWB);
  end;
end;

{ The whole of the per-frame background, and the reason the parallax is real.

  EVERY ROW IS DERIVED FROM ONE CAMERA POSITION, and it has to be.  The first
  version gave each row its own phase accumulator and stepped it by that
  row's own speed, which is the obvious way to write it and is subtly wrong.
  The step is an integer number of sixty-fourths, so it is not EXACTLY
  proportional to depth -- row 16 stepped 119 where the geometry wanted
  119.0 and row 17 stepped 126 where it wanted 126.4.  Four tenths of a
  sixty-fourth a frame is nothing; a thousand frames later adjacent rows were
  six pixels apart and the converging rays had dissolved into a field of
  unrelated dashes.  It looked like noise, not like a bug.

  Deriving every row from one number removes the possibility rather than
  reducing the error: line k of row d sits at

      x = CX + (CamX + k*GW) * d / 64

  which is proportional to d for every k, so the lines are straight rays
  through the vanishing point at CX by construction, at any camera position,
  forever.

  The arithmetic still has to fit in sixteen bits and avoid multiplies.  Both
  halves of CamX times d are arithmetic progressions down the band, so they
  accumulate; what is left per row is two adds, a shift and one divide for
  the modulo.  The camera itself is kept modulo GW pixels, which is the
  period of the pattern, so it can run forever without overflowing. }
{ The band's row loop with both drawing calls left out, so the benchmark can
  separate three costs that are otherwise indistinguishable: moving bulk
  pixels, placing the grid lines, and simply going round 64 times in Pascal.
  Guessing which of those dominates is exactly the mistake CLAUDE.md records
  being made four times on the raycaster. }
procedure BandLoopOnly;
var
  B       : Integer;
  Base, Ph: Word;
  SpFp, Xw: Word;
  A1, A2  : Word;
  CHi, CLo, Stp: Word;
  Q, QPrev: Integer;
  Sink    : Word;
begin
  Stp  := Word(LATBASE) * Word(Speed);
  CHi  := CamFp shr 6;
  CLo  := CamFp and 63;
  A1   := CHi * D0;
  A2   := CLo * D0;
  SpFp := Word(GW) * D0;
  Base := 0;
  Sink := 0;
  QPrev := Integer((Zof[0] + ZPhase) shr ZSHIFT);
  for B := 0 to BANDH - 1 do
  begin
    Q := Integer((Zof[B] + ZPhase) shr ZSHIFT);
    IsHLine[B] := (B > 0) and (Q <> QPrev);
    QPrev := Q;
    if not IsHLine[B] then
      if SpacePx[B] > 0 then
      begin
        Xw := A1 + (A2 shr 6);
        Ph := (Word(DISP_W div 2) * 64 + Xw) mod SpFp;
        Inc(Sink, Ph + GridCol[B] + FloorCol[B]);
      end;
    WasH[B] := IsHLine[B];

    Inc(A1, CHi);
    Inc(A2, CLo);
    Inc(SpFp, GW);
    Inc(Base, VWB);
  end;
  ForceFill := False;
  LoopSink := Sink;
end;

procedure PaintBand;
var
  B       : Integer;
  Base, Ph: Word;
  SpFp, Xw: Word;
  A1, A2  : Word;
  CHi, CLo: Word;
  Stp     : Word;
  Q, QPrev: Integer;
begin
  MapMask($0F);

  { The camera, in 64ths of a pixel, wrapped at the pattern period.  One
    multiply a frame and none per row.  It takes its direction from the same
    flag the sky does, so the whole scene swings together rather than the
    ground going one way and the horizon the other. }
  Stp := Word(LATBASE) * Word(Speed);

  { THE FLOOR MOVES THE OPPOSITE WAY TO CamFp, and getting that sign wrong is
    what made the scene look like it scrolled further one way than the other.

    A grid line lands at screen x = CX + (CamFp*d/64 + k*spacing)/64, so
    INCREASING CamFp slides the lines to the RIGHT.  But SkyPix increasing
    means the window is moving right through the world, which slides the
    scenery to the LEFT.  Advancing both on SweepDir > 0 therefore drove the
    ground one way and the sky and skyline the other.

    It does not read as "the layers disagree", because there is nothing in
    shot that belongs to both.  It reads as the whole scene travelling much
    further one way than the other, which is what it was reported as.
    Measured off the capture card at 33 fps: the sun moving +2.8 capture
    pixels a frame while the bottom of the floor moved -22.

    So the camera step is negated here.  Pan right, and everything on screen
    goes left together. }
  if SweepDir > 0 then
  begin
    { Wrapping downwards: add the period first, because CamFp is a Word and
      cannot go negative -- it would silently become 65000-odd. }
    Inc(CamFp, GW * 64);
    Dec(CamFp, Stp);
    while CamFp >= GW * 64 do Dec(CamFp, GW * 64);
  end
  else
  begin
    Inc(CamFp, Stp);
    while CamFp >= GW * 64 do Dec(CamFp, GW * 64);
  end;

  CHi := CamFp shr 6;          { whole pixels, 0..GW-1 }
  CLo := CamFp and 63;         { and the fraction }

  { A1 + (A2 shr 6) is CamX * d / 64, exactly, with the product split so
    neither half can leave a Word: 47*69 and 63*69 both fit easily. }
  A1 := CHi * D0;
  A2 := CLo * D0;

  { The spacing, exactly, in the same 64ths the camera is kept in: it is
    GW*d and nothing is rounded.  The pixel table SpacePx is a truncation of
    this and using it here was the second bug in the floor -- with the
    spacing rounded to whole pixels it stops being exactly proportional to
    depth, so the error compounds along each row and the outer lines shear
    away from the rays they belong to.  Five pixels by the edge of the
    screen, which reads as a staircase rather than as a mistake. }
  SpFp := Word(GW) * D0;

  Base  := 0;
  QPrev := Integer((Zof[0] + ZPhase) shr ZSHIFT);

  for B := 0 to BANDH - 1 do
  begin
    { A depth line wherever the depth crossed a boundary since the row above.
      ZPhase is kept modulo the step, so when it wraps every row's quotient
      changes together and the set of crossings does not move -- which is why
      the floor can rush towards the viewer forever without a glitch. }
    Q := Integer((Zof[B] + ZPhase) shr ZSHIFT);
    IsHLine[B] := (B > 0) and (Q <> QPrev);
    QPrev := Q;

    { A row with no grid lines in it is a FLAT COLOUR THAT NEVER MOVES, so
      there is nothing to repaint: it only has to be touched on the frame its
      depth-line state changes, or on the first frame.  Those are the hazed
      rows nearest the horizon -- eighteen of the forty-eight here -- and
      skipping them is worth about two milliseconds a frame, which is the
      difference between the paint beating the beam down the screen and
      losing to it.

      Safe only because no car ever reaches them: the cars sit at rows 18 and
      upward and the haze ends at row 17.  The report prints both numbers so
      the invariant is visible rather than assumed. }
    if (SpacePx[B] = 0) and not ForceFill and (IsHLine[B] = WasH[B]) then
      { nothing to do }
    else if IsHLine[B] then
      FillW(Base, DISP_W div 8, GridCol[B])
    else
    begin
      FillW(Base, DISP_W div 8, FloorCol[B]);

      if SpacePx[B] > 0 then
      begin
        { CamX * d / 64, in 64ths, with the product split so neither half can
          leave a Word.  The same units as the spacing, which is the whole
          point -- mixing 64ths with whole pixels here was the first bug. }
        Xw := A1 + (A2 shr 6);

        { The one divide in the loop.  Adding CX before reducing is what puts
          the vanishing point in the middle of the screen rather than at its
          left edge: at the horizon d is zero, so Xw and the spacing are both
          zero and every line collapses onto CX. }
        Ph := (Word(DISP_W div 2) * 64 + Xw) mod SpFp;

        { The nearest third of the floor gets lines eight pixels wide, which
          is what perspective would do to them. }
        if B > (BANDH * 2) div 3 then
          GridRowWide(Base, Ph, SpFp, GridCol[B])
        else
          GridRow(Base, Ph, SpFp, GridCol[B]);
      end;
    end;

    { THE CARS GO IN HERE, not after the loop, and that is what stopped them
      flickering.

      The beam reaches band row r about 11 + 0.064r milliseconds after the
      retrace and crosses the whole band in three.  Drawing the cars after the
      band finished meant they were drawn at 21ms -- seven milliseconds after
      the beam had already read the rows they sit on.  So on one refresh out
      of every two the cars were simply not on the screen: counted off the
      capture card, the amber car was absent from twelve of twenty-four
      consecutive frames.  At 35 Hz that does not read as flicker, it reads as
      the car being semi-transparent.

      Drawn the instant its last row is painted, a car is on screen a
      millisecond or two before the beam arrives at its first. }
    { Unrolled, because this runs on every row of every frame and a Pascal
      FOR loop of two iterations costs more than the two compares it saves. }
    if (NSprites > 0) and (CarBot[0] = Word(B)) then
    begin
      DrawSprite(0, CarX[0], CarY[0]);
      SetPlane($0F);           { DrawSprite leaves one plane selected }
    end;
    if (NSprites > 1) and (CarBot[1] = Word(B)) then
    begin
      DrawSprite(1, CarX[1], CarY[1]);
      SetPlane($0F);
    end;

    WasH[B] := IsHLine[B];

    Inc(A1, CHi);
    Inc(A2, CLo);
    Inc(SpFp, GW);
    Inc(Base, VWB);
  end;
  ForceFill := False;

  { Depth motion: the floor rushing towards the viewer.  Kept modulo the line
    step so it never overflows and never glitches.

    Three and not eight.  A depth line is a whole row wide and can only be on
    a row or not on it, so it advances in jumps however smoothly the phase
    moves -- and near the horizon, where a row is worth a lot of distance, one
    phase step can carry a line several rows at once.  At the original rate
    that lurch happened about four times a second across the full width of the
    screen, which was most of what read as jerkiness.  Slower does not make
    the jump smaller, but it makes it rare enough to read as the floor
    arriving rather than as the picture stumbling. }
  Inc(ZAcc, Word(Speed) * 3);
  ZPhase := (ZAcc shr 3) and ((1 shl ZSHIFT) - 1);
end;

{ ================================================================= output }

procedure GrabShot;
var
  R, C, X, Y, L: Integer;
  Line: ShortString;
begin
  { Nothing drawn to A000 comes back over the bridge, so without this a run
    from Windows returns a frame count and no evidence there was a picture at
    all.  Both regions have to be sampled in their own coordinates: above the
    split that is the far layer's world column at the current scroll, below
    it the band's own rows, which is exactly the split the hardware is
    making. }
  for R := 0 to SHOT_H - 1 do
  begin
    Y := (R * VH) div SHOT_H;
    Line := '';
    for C := 0 to SHOT_W - 1 do
    begin
      X := (C * DISP_W) div SHOT_W;
      if Y < SPLIT then
        L := Lum[PeekPix(Word(SkyPix + X), Word(FARROW + Y))]
      else
        L := Lum[PeekPix(Word(X), Word(Y - SPLIT))];
      Line := Line + Shades[1 + Clamp((L * 9) div 63, 0, 9)];
    end;
    Shot[R] := Line;
  end;
end;

procedure PrintShot;
var
  R: Integer;
begin
  WriteLn;
  WriteLn('the screen as it stood at the end  (', NumStr(SHOT_W), 'x',
          NumStr(SHOT_H), ' of 320x200, sampled; the split is at row ',
          NumStr((SPLIT * SHOT_H) div VH), ')');
  for R := 0 to SHOT_H - 1 do WriteLn('  |', Shot[R], '|');
end;

function YesNo(B: Boolean): ShortString;
begin
  if B then YesNo := 'yes' else YesNo := 'no';
end;

function PalWord: ShortString;
begin
  if Forced <> '' then PalWord := Forced + ' (forced on the command line)'
  else if Colour then PalWord := 'colour (probed at run time)'
  else PalWord := 'mono (probed at run time)';
end;

{ Microseconds as milliseconds with three decimals, because the two numbers
  that matter most here -- the two table builds -- differ by a factor the
  BIOS tick could not have resolved, and printing them rounded to
  milliseconds would throw away the evidence for the choice. }
function MsStr(Us: LongInt): ShortString;
var
  S: ShortString;
begin
  S := NumStr(Us mod 1000);
  while Length(S) < 3 do S := '0' + S;
  MsStr := NumStr(Us div 1000) + '.' + S + ' ms';
end;

{ ---- the information dump ------------------------------------------------
  Printed before a single video register is touched, so it survives whatever
  the graphics do afterwards, and printed through DOS so it comes back over
  the bridge -- nothing written to video memory ever does. }

procedure DumpSystem;
var
  Sup : Boolean;
  Code: Byte;
begin
  WriteLn('=== NEON DRIFT  --  mode X parallax with OPL2 sound ===');
  WriteLn;
  WriteLn('--- the machine ---');
  WriteLn('  CPU            : ', CpuName);
  WriteLn('  186 opcodes    : ', YesNo(Has186));
  if HasFpu then
    WriteLn('  coprocessor    : ', FpuName, '   (control ', HexStr(FpuCw),
            ', status ', HexStr(FpuSw), ')')
  else
    WriteLn('  coprocessor    : none fitted');
  WriteLn('  conventional   : ', NumStr(MemW[$0040:$0013]), ' KB');
  Code := DisplayCode(Sup);
  if Sup then
    WriteLn('  display combo  : ', NumStr(Code))
  else
    WriteLn('  display combo  : the BIOS has no opinion');
  WriteLn('  text mode was  : ', NumStr(OldMode));
  WriteLn('  palette        : ', PalWord);
end;

procedure DumpPicoMem;
begin
  WriteLn;
  WriteLn('--- the PicoMEM ---');
  if not PmProbe then
  begin
    WriteLn('  no PicoMEM: INT 13h AH=60h did not answer AA55h.');
    WriteLn('  Nothing here depends on one -- it is reported because on the');
    WriteLn('  machine this was written for the OPL2 at 388h IS the card.');
    Exit;
  end;
  WriteLn('  card BIOS      : answered -- base ', HexStr(PmBase),
          ', ROM ', HexStr(PmRomSeg), ', devices ', HexStr(PmMask));
  WriteLn('  port check     : ', NumStr(PmSeq), ' of ', NumStr(PM_READS),
          ' reads of base+3 followed on from the one before');
  WriteLn('  status byte    : ', HexStr(PmStatus));
  if PmRomName <> '' then
    WriteLn('  ROM signature  : "', PmRomName, '"');
  if PmDate <> '' then
    WriteLn('  BIOS date      : ', PmDate, '  (read out of the ROM itself)')
  else
    WriteLn('  BIOS date      : not found in the first 1 KB of the ROM');
  if PmShared then
  begin
    WriteLn('  shared memory  : answering at ', HexStr(PmRomSeg), ':4000');
    WriteLn('  board          : id ', NumStr(PmBoard), ' (', PmBoardName, ')');
    WriteLn('  card IRQ       : ', NumStr(PmIrq));
  end
  else
    WriteLn('  shared memory  : NOT answering -- board id unavailable');
  WriteLn('  (read-only: this demo never writes the card a command byte,');
  WriteLn('   because on these machines the card is the boot disk)');
end;

procedure DumpSound;
begin
  WriteLn;
  WriteLn('--- sound ---');
  if not WantMusic then
  begin
    WriteLn('  OPL2           : not probed (NOMUSIC on the command line)');
    Exit;
  end;
  if OplDetect then
    WriteLn('  OPL2 at 388h   : ANSWERED -- status ', HexStr(OplIdle),
            ' then ', HexStr(OplTimer), ', which is the timer handshake')
  else
  begin
    WriteLn('  OPL2 at 388h   : nothing there -- status ', HexStr(OplIdle),
            ' then ', HexStr(OplTimer), ', wanted 00h then C0h');
    WriteLn('  the demo runs silently.  There is no second code path for');
    WriteLn('  this: MusicTick and MusicStop simply do nothing.');
  end;
end;

procedure DumpFpuRace;
begin
  WriteLn;
  WriteLn('--- the perspective tables, built both ways ---');
  WriteLn('  ', NumStr(BANDH), ' rows of grid spacing and depth, plus ',
          NumStr(2 * SUNR + 1), ' square roots for the sun,');
  WriteLn('  built ', NumStr(BENCH_REPS), ' times each so the PIT can separate them:');
  WriteLn('    integer (32-bit, software)  : ', MsStr(UsIntBuild));
  if FpuFitted and WantFpu then
  begin
    WriteLn('    coprocessor (', FpuName, ')      : ', MsStr(UsFpuBuild));
    WriteLn('    the two tables agreed on     : ',
            NumStr(2 * BANDH + 2 * SUNR + 1 - FpuDiffs), ' of ',
            NumStr(2 * BANDH + 2 * SUNR + 1), ' entries');
  end;
  if FpuUsed then
    WriteLn('  USING the coprocessor -- ', FpuWhy)
  else
    WriteLn('  using the integer path -- ', FpuWhy);
end;

procedure Report(ModeOk: Boolean);
var
  Fps10, FrameUs, Refr: LongInt;
begin
  WriteLn;
  WriteLn('--- the run ---');
  if not ModeOk then
  begin
    WriteLn('  mode X         : REFUSED -- the registers did not read back');
    Exit;
  end;
  WriteLn('  mode X         : 320x200x256 unchained, virtual ', NumStr(VW),
          'x', NumStr(VH));
  WriteLn('  CRTC / status  : ', HexStr(CrtcBase), ' / ', HexStr(StatBase));
  if SplitOk then
    WriteLn('  split screen   : line compare ', NumStr(LCVAL),
            ' = display row ', NumStr(SPLIT),
            '; AC mode control reads ', HexStr(AcMode),
            ' (8-bit colour and pan compatibility both set)')
  else
    WriteLn('  split screen   : the CRTC did NOT take it -- the floor is',
            ' showing the wrong memory');
  WriteLn('  far layer      : rows 0..', NumStr(SPLIT - 1), ' at VRAM row ',
          NumStr(FARROW), ', ', NumStr(PERIOD), ' px of world, last ',
          NumStr(DUPW), ' duplicate the first');
  WriteLn('  pinned band    : rows ', NumStr(SPLIT), '..', NumStr(VH - 1),
          ' = ', NumStr(BANDH), ' rows, repainted every frame');
  WriteLn('  video used     : ', NumStr(LongInt(PGSZ) * 4), ' of 262144 bytes');
  WriteLn('  world paint    : ', NumStr(PaintMs), ' ms (once, at startup)');
  WriteLn('  band repaint   : ', MsStr(UsBand), ' measured, for ',
          NumStr(BANDH), ' rows -- that is the frame budget');
  WriteLn('                   row fills    ', MsStr(UsFill), '  (',
          NumStr(BANDH * (DISP_W div 8)), ' words through REP STOSW)');
  WriteLn('                   row loop     ', MsStr(UsLoop),
          '  (Pascal, no drawing at all)');
  WriteLn('                   lines + cars ', MsStr(UsBand - UsFill - UsLoop),
          '  (the rest)');
  WriteLn('  haze rows      : 0..', NumStr(NHaze - 1),
          ' carry no grid lines and are repainted only when a depth');
  WriteLn('                   line crosses them.  Lowest row a car reaches: ',
          NumStr(CarLane[0] - 2), ' -- must be ', NumStr(NHaze),
          ' or more, or a car would leave a trail.');
  WriteLn('  speed          : ', NumStr(Speed),
          '  -- floor 0.70 to 8.0 px/frame across the band at speed 7,');
  WriteLn('                   far layer ', NumStr(SkyStep),
          ' px/frame (whole pixels: mode X pans no');
  WriteLn('                   finer, so anything slower stutters).  Every row');
  WriteLn('                   of the floor moves at its own rate -- that is');
  WriteLn('                   the parallax, and it is geometry, not an effect.');
  WriteLn('  sweep          : +/-', NumStr(SweepHalf), ' about world x ',
          NumStr(SWEEP_MID), ' -- covered ', NumStr(SkyLo), '..', NumStr(SkyHi),
          ' of ', NumStr(PERIOD), ', turning round ', NumStr(Sweeps), ' time(s)');
  WriteLn('                   city under the window: ', NumStr(CityAtLo),
          ' of ', NumStr(DISP_W), ' columns at the left end, ',
          NumStr(CityAtHi), ' at the right');
  WriteLn('                   -- these two must be COMPARABLE.  When the towers');
  WriteLn('                   stopped at world column 384 of 704 it was 288');
  WriteLn('                   against 96, and sweeping right simply ran out of');
  WriteLn('                   city.  That is what read as scrolling further one');
  WriteLn('                   way than the other.');
  WriteLn('                   Starts in the MIDDLE of that range, so the');
  WriteLn('                   travel is balanced either side of where it');
  WriteLn('                   began rather than running to one end first.');
  WriteLn('                   It reverses rather than wrapping, so the sun and');
  WriteLn('                   the skyline never come round a second time --');
  WriteLn('                   the window never reaches the seam at all.');
  WriteLn('  cars           : ', NumStr(NSprites), ' of ', NumStr(NSPR),
          ', ', NumStr(SPR_W), 'x', NumStr(SPR_H), ', drawn into the band');
  WriteLn('                   No save, no restore, no backing store: the band');
  WriteLn('                   is repainted every frame, so the erase has');
  WriteLn('                   already happened.  Draw only.');
  if SprHoles = 0 then
    WriteLn('  sprite art     : clean -- no transparent pixel falls inside a',
            ' blitted run')
  else
    WriteLn('  sprite art     : ', NumStr(SprHoles), ' transparent pixels are',
            ' inside a run and will blit BLACK');

  if not WantMusic then
    WriteLn('  music          : off (NOMUSIC)')
  else if MusicOn or (MusicNotes > 0) then
    WriteLn('  music          : OPL2 at 388h, 4 voices, ', NumStr(MusicNotes),
            ' notes, ', NumStr(MusicLoops), ' times round the 8 bars')
  else
    WriteLn('  music          : silent -- no OPL2 answered at 388h');

  WriteLn('  frames         : ', NumStr(Frames));
  WriteLn('  elapsed        : ', NumStr((Elapsed * 10000) div TICKS10),
          ' ms (', NumStr(Elapsed), ' ticks), asked for ',
          NumStr(RunSecs), ' s');
  if Elapsed > 0 then
  begin
    Fps10 := (Frames * TICKS10) div Elapsed;
    WriteLn('  frame rate     : ', NumStr(Fps10 div 10), '.',
            NumStr(Fps10 mod 10), ' fps');
  end;
  if (Elapsed > 0) and (Frames > 0) then
  begin
    FrameUs := (Elapsed * USPERTICK) div Frames;
    Refr    := (FrameUs + (USPERREFR div 2)) div USPERREFR;
    if Refr < 1 then Refr := 1;
    WriteLn('  frame          : ', NumStr(FrameUs), ' us = ', NumStr(Refr),
            ' vertical refresh(es)');
    WriteLn('                   ShowFar blocks on the retrace, so the rate');
    WriteLn('                   can only be 70.1/N.  A frame time that lands');
    WriteLn('                   BETWEEN two multiples of 14.27ms averages out');
    WriteLn('                   respectably and judders; the number to watch');
    WriteLn('                   is the next line, not the rate.');
  end;
  WriteLn('  paint vs beam  : the band is repainted top to bottom while the');
  WriteLn('                   beam reads it top to bottom, so the repaint must');
  WriteLn('                   stay ahead or the lowest rows show the previous');
  WriteLn('                   frame.  NOT measured here -- see the note on PIT');
  WriteLn('                   mode 3 at MicRead: sub-tick timing on this');
  WriteLn('                   machine is ambiguous by half a tick, which is');
  WriteLn('                   twice a whole frame.  Verified off the capture');
  WriteLn('                   card instead: quartering the band and');
  WriteLn('                   differencing successive frames shows all four');
  WriteLn('                   quarters moving together with the lowest');
  WriteLn('                   changing most, and both cars present in every');
  WriteLn('                   one of 34 consecutive frames.');
  WriteLn('  late frames    : ', NumStr(FlipLate), ' of ', NumStr(Frames),
          '  (arrived after the retrace had started -- these are the judder)');
  WriteLn('  flip timeouts  : ', NumStr(FlipTimeouts),
          '  (retrace waits that gave up; 0 is healthy)');
  if BadArg <> '' then
    WriteLn('  NOTE           : ignored argument "', BadArg, '"');
end;

{ =================================================================== main }

var
  I, WY : Integer;
  WX    : Word;
  T0    : LongInt;
  Limit : LongInt;
  ModeOk: Boolean;
  Quit  : Boolean;

function KeyWaiting: Boolean; assembler;
asm
  mov  ah, 1
  int  16h
  mov  al, 0
  jz   @@none
  mov  al, 1
@@none:
end;

procedure DrainKeys;
begin
  while KeyWaiting do
    asm
      mov ah, 0
      int 16h
    end;
end;

{ Hold the dump on the screen long enough to read it at the keyboard.  Driven
  by the BIOS tick and bounded, because a wait that can only end on a key
  press is a machine somebody has to walk over to -- and over the bridge that
  is indistinguishable from a hang. }
procedure HoldForReading(Secs: Integer);
var
  T, L: LongInt;
begin
  T := Ticks;
  L := (LongInt(Secs) * TICKS10) div 10;
  while (Ticks - T >= 0) and (Ticks - T < L) and not KeyWaiting do ;
  DrainKeys;
end;

{ Where the cars are this frame.  Separated from drawing them because the
  drawing now happens INSIDE the band repaint, and the band has to know which
  row each car ends on before it starts. }
procedure PlaceCars;
var
  J, X, Y: Integer;
begin
  for J := 0 to NSprites - 1 do
  begin
    SprPh[J]  := (SprPh[J] + CarRate[J]) and 255;
    SprBob[J] := (SprBob[J] + CarBobR[J]) and 255;

    X := CarCx[J] + (Sine(SprPh[J]) * CarAmp[J]) div 64;
    Y := CarLane[J] + (Sine(SprBob[J]) * 2) div 64;

    CarX[J] := Word(Clamp(X, 0, CAR_XMAX));
    CarY[J] := Word(Clamp(Y, 0, BANDH - SPR_H));
    { The last band row this car touches.  The band draws it the moment that
      row is painted, which is the whole point -- see PaintBand. }
    CarBot[J] := CarY[J] + SprR0[J] + SprRH[J] - 1;
  end;
end;

begin
  ParseArgs;
  DrainKeys;
  OldMode := GetMode;

  DumpSystem;
  DumpPicoMem;
  DumpSound;

  { The coprocessor race, and the tables it decides.  Before the world is
    painted and before the mode is set, so nothing it does can cost a frame
    however it comes out. }
  ChooseAndBuild;
  DumpFpuRace;

  WriteLn;
  WriteLn('--- starting: ', NumStr(RunSecs),
          ' seconds, any key stops it early ---');
  if WantPause then HoldForReading(3);

  BuildSkylines;
  BuildSprites;
  InitSprites;

  { How much skyline is actually under the window at each end of the travel.
    Counted rather than assumed: this is the exact quantity that was wrong,
    and it is cheap and deterministic to check. }
  CityAtLo := 0;
  CityAtHi := 0;
  for I := 0 to DISP_W - 1 do
  begin
    if CityTop[(Integer(SweepLo) + I) mod PERIOD] < SPLIT then Inc(CityAtLo);
    if CityTop[(Integer(SweepHi) + I) mod PERIOD] < SPLIT then Inc(CityAtHi);
  end;

  ModeOk := Enter;
  if not ModeOk then
  begin
    SetMode(OldMode);
    Report(False);
    Halt(1);
  end;

  { Dark from here until the whole scene is staged and the first frame is
    ready to show.  See ScreenOff. }
  ScreenOff;

  SplitOk := SetSplit(LCVAL);
  LoadPalette;
  if WantMusic then MusicStart;

  T0 := Ticks;
  PaintWorld;
  PaintMs := ((Ticks - T0) * 10000) div TICKS10;

  { What the band actually costs, measured here rather than reasoned about.
    Twenty repaints at PIT resolution, before the frame loop starts and with
    nothing else running -- so the figure in the report is the real one for
    whatever machine this is, and the next person to wonder where the frame
    goes does not have to find out the hard way.  It leaves the band in a
    valid state, so the loop can start straight from it. }
  MicReset;
  for I := 1 to 20 do PaintBand;
  UsBand := MicRead div 20;

  MicReset;
  for I := 1 to 20 do BandFillOnly;
  UsFill := MicRead div 20;

  MicReset;
  for I := 1 to 20 do BandLoopOnly;
  UsLoop := MicRead div 20;

  { START IN THE MIDDLE OF THE SWEEP, not at one end.

    Starting at an end means the first thing the demo does is travel the
    entire sweep in one direction before it ever comes back -- which reads,
    correctly, as scrolling further one way than the other.  From the middle
    the motion is balanced about where it began. }
  SweepLo  := Word(SWEEP_MID - SweepHalf);
  SweepHi  := Word(SWEEP_MID + SweepHalf);
  SkyPix   := SWEEP_MID;
  SweepDir := 1;
  Sweeps   := 0;
  SkyLo    := PERIOD;
  SkyHi    := 0;
  SkyStep  := Word(Speed) div 7;
  if SkyStep < 1 then SkyStep := 1;
  ZAcc      := 0;
  CamFp     := 0;
  ForceFill := True;
  FillChar(WasH, SizeOf(WasH), 0);
  ZPhase := 0;
  Frames := 0;
  BandUsMax := 0;
  BandUsSum := 0;
  BandLate  := 0;
  BandLateFrames := 0;
  Quit   := False;
  { One complete frame, built while the screen is still dark: the floor with
    its grid lines, both cars, and the start address and pan for the far
    layer.  Then the display comes on at a retrace boundary showing a
    finished picture rather than a half-assembled one. }
  ForceFill := True;
  PlaceCars;
  PaintBand;
  ShowFar(SkyPix);
  ScreenOn;

  if Profiling then ProfStart;
  StartTick := Ticks;
  Limit     := (LongInt(RunSecs) * TICKS10) div 10;

  repeat
    { Latch the frame the CRT is about to draw.  This returns just inside the
      vertical blank, so everything below runs while the beam is sweeping. }
    ShowFar(SkyPix);
    if Profiling then Mark('flip/idle');
    Inc(Frames);

    { The band FIRST, and that ordering is deliberate.  The beam does not
      reach display row 136 for about nine milliseconds after the retrace,
      and the band repaint takes rather less than that -- so it lands
      complete.  Put the sprites first instead and the fastest, widest,
      full-width layer on the screen is the one that gets torn, which is far
      more visible than a sprite shimmering.  There is no back buffer and
      there cannot be: the picture already uses 204800 of the VGA's 262144
      bytes. }
    { TIME THE RACE, every frame, in situ.

      The bench figure above is measured with nothing else going on; this is
      the one that decides whether the picture judders.  The beam reaches the
      bottom of the screen about 14270us after the retrace, and ShowFar
      returns at the start of the vertical blank -- so if the band and its
      cars are not finished by then, the lowest rows are read by the beam
      before they are written and show the previous frame for one refresh in
      two.  Two PIT reads a frame cost about 60us, which is a twentieth of
      the margin being measured; worth it to stop guessing. }
    MicReset;
    PlaceCars;
    PaintBand;
    BandUs := MicRead;
    if BandUs > BandUsMax then BandUsMax := BandUs;
    Inc(BandUsSum, BandUs);
    { Count ROWS read before they were written, not frames that went over.
      A frame that overshoots by 30us has half a row stale and looks perfect;
      one that overshoots by 2ms has thirty rows stale and judders. The
      binary count cannot tell those apart and spent an evening saying
      "LOST" to both. }
    if BandUs > BEAM_US then Inc(BandLateFrames);
    if BandUs > 2 * BEAM_US then Inc(BandLate);
    if Profiling then Mark('band+cars');

    { In the vertical blank, ahead of the expensive sprites.  Worst case is
      four voices turning over on one step, about a millisecond. }
    MusicTick(Ticks - StartTick);
    if Profiling then Mark('music');

    { The far layer, one whole pixel a frame, sweeping back and forth.

      It used to creep at 0.22 of a pixel, accumulated in 64ths, which is the
      obvious way to make a distant layer slow.  It also means the picture
      holds still for four frames and then jumps a pixel, about eight times a
      second -- and a 320x136 bitmap stepping like that is visible as a
      stutter even though the frame rate is perfectly steady.  Mode X pans at
      one-pixel granularity and no finer, so the smoothest slow speed
      available is exactly one pixel a frame, not less.  At 35 fps that is 35
      px/s against the floor's 280, so there is still eight to one of
      parallax between them.

      AND IT REVERSES.  Scrolling one way forever means the world has to wrap,
      and a wrap means the sun and the skyline come round again -- which reads
      as the scenery repeating rather than as travel, because it is.  Sweeping
      between the two ends of the world instead means the window never reaches
      the seam at all, so nothing ever repeats.  The turn is abrupt, at full
      speed, on purpose: easing through it would take the layer below one pixel
      a frame, which is exactly the sub-pixel crawl that stutters. }
    if SweepDir > 0 then
    begin
      Inc(SkyPix, SkyStep);
      if SkyPix >= SweepHi then
      begin
        SkyPix := SweepHi;
        SweepDir := -1;
        Inc(Sweeps);
      end;
    end
    else
    begin
      if SkyPix <= SweepLo + SkyStep then
      begin
        SkyPix := SweepLo;
        SweepDir := 1;
        Inc(Sweeps);
      end
      else
        Dec(SkyPix, SkyStep);
    end;

    if SkyPix < SkyLo then SkyLo := SkyPix;
    if SkyPix > SkyHi then SkyHi := SkyPix;

    { HOLD THE FRAME TO A WHOLE NUMBER OF REFRESHES.

      The work here is about 15ms against a 14.27ms refresh -- just over, and
      not by a reliable margin.  Left alone a frame takes one refresh when it
      comes in under and two when it does not, and the measured result was
      38.4 fps: a mixture of 14.3ms and 28.5ms frames.  That averages to a
      respectable number and judders, because consecutive frames are held on
      screen for different lengths of time and the far layer's one-pixel step
      lands at uneven intervals.  CLAUDE.md records the same lesson from the
      scroller, where 56 fps looked worse than a steady 35.

      So the frame is padded up to REFRESH_LOCK refreshes before ShowFar is
      allowed to wait for the retrace.  A frame that was going to be short
      spins here instead; one that already overran does not wait at all.
      Every frame then lasts the same 28.5ms and the step spacing is even.

      This is padding, not throttling: the budget it pads to is the one the
      beam already imposes on the band repaint. }
    while MicRead < PACE_US do ;

    if (Frames and 15) = 0 then
    begin
      Elapsed := Ticks - StartTick;
      if Elapsed < 0 then Inc(Elapsed, TICKDAY);      { past midnight }
      if Elapsed >= Limit then Quit := True;
      if KeyWaiting then Quit := True;
    end;
  until Quit;

  { Before anything else, including the screen grab: a voice left ringing is
    the one failure here that needs somebody to walk over to the machine. }
  MusicStop;

  Elapsed := Ticks - StartTick;
  if Elapsed < 0 then Inc(Elapsed, TICKDAY);

  { Capture before restoring text mode -- setting a mode clears video memory,
    which is why a demo that tidies up after itself leaves nothing to
    photograph. }
  if WantShot then GrabShot;
  SetMode(OldMode);

  Report(True);
  if Profiling then
  begin
    WriteLn;
    ProfReport;
  end;
  if WantShot then PrintShot;

  DrainKeys;
  Halt(0);
end.
