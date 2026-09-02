program Scroller;
{ DOS Bridge  --  StevenC }
{ A thirty-second side-scrolling landscape with sprites and AdLib music.
  Measured on the NEC V30 box on 2026-09-01: 70.4 fps, one vertical refresh
  per frame, ZERO late frames -- which is as fast as a 320x200 VGA goes.

  The whole demo rests on one decision: the background is never redrawn.  It
  is painted once, 1024 pixels wide, into a mode X virtual screen, and then
  scrolled by moving the CRTC start address.  Per frame that is five OUTs.
  Repainting it instead would be 64000 bytes, which BENCH puts at 73ms, so
  13 fps with no time left over to decide what to draw -- see the header of
  modex.pas for the arithmetic.

  So the scroll is free and the sprites are the entire frame budget, because
  they do have to be erased and redrawn.  Four of them cost about 11.5ms, and
  the music about 0.8ms on the frames where a note changes.

  THE FRAME RATE IS QUANTISED, which is the thing to understand before
  touching any of this.  ShowAt blocks on the vertical retrace, so a frame
  takes a whole number of refreshes and the only rates available are
  70.1 / N: 70.1, 35.0, 23.4, 17.5.  Shaving 10% off the work usually buys
  nothing at all, and then one more percent doubles the rate.  The whole
  history of this file, measured on hardware:

      6 sprites, blitter as a hand pixel loop   36ms   N=3   23.4 fps
      6 sprites, blitter as REP MOVSB           24ms   N=2   35.1 fps
      6 sprites + music                         19ms   N=2/3 33 fps, juddering
      5 sprites + music                       14.5ms   N=1/2 56 fps, juddering
      4 sprites + music                       11.5ms   N=1   70.4 fps, steady

  Note the two juddering rows.  A frame time that lands *between* two
  multiples of 14.27ms gives an average that looks respectable and a picture
  that stutters, because consecutive frames are held for different lengths of
  time.  56 fps is worse than 35 fps.  That is what FlipLate counts, and it is
  the number to check after any change -- not the frame rate.

  Three things here are worth copying and three are worth knowing about.

  * The world wraps with no seam and no repainting.  The virtual screen is
    1024 wide; the world is the first 704 pixels of it, and the last 320 are
    a copy of the first 320.  The window is 320 wide, so at scroll 703 it
    shows columns 703..1022 -- which is the end of the world followed by the
    beginning of it.  Scroll then resets to 0 and the picture is identical,
    so nothing has to be drawn as it comes on screen.  704 + 320 = 1024 is
    the whole trick.

  * Sprites live in world coordinates, so save-and-restore just works across
    the wrap.  Each sprite stores the address it saved from and restores to
    that same address, never to a recomputed one.

  * Sprites are given non-overlapping horizontal lanes.  That is not a visual
    choice, it is what makes restore-save-draw safe to do one sprite at a
    time -- and doing it one at a time, top to bottom, immediately after the
    retrace, keeps the work ahead of the beam so the erase is not seen.

  * There is no double buffer, and there cannot be.  The picture already uses
    204800 of the VGA 262144 bytes; a second page would need another 64000.
    Hardware scrolling and page flipping are competing for the same memory,
    and on a wide world the scroll wins easily.

  * Parallax is fake.  One start address moves the entire screen, so the
    landscape can only scroll at one rate.  The depth you see comes from the
    sprites, which are drawn per frame and can therefore drift at any speed
    they like relative to the ground.

  * Sprites may shimmer occasionally, and that is the honest cost of having
    no back buffer.  A sprite is erased and redrawn over about 4ms while the
    beam crosses it in 1ms, so if the beam arrives mid-update it shows a
    half-drawn sprite for one refresh.  With six sprites and a 28.5ms frame
    that works out at a few brief flickers a second.  Curing it means either
    a back buffer (no memory for one) or getting each sprite done before the
    beam reaches its lane (needs the 1.9x above).  The *scrolling* is never
    affected -- that is the CRTC, and it cannot tear.

  Arguments, in any order:

    SECS n     how long to run (default 30)
    SPEED n    pixels of scroll per frame, 1..8 (default 2).  The frame
               rate is set by the hardware, not by this: see below
    MONO       force the grey ramp
    COLOUR     force the colour ramp
    NOSHOT     skip the ASCII thumbnail at the end
    NOMUSIC    stay silent even if an AdLib is fitted
    PROF       time the frame at PIT resolution and print the breakdown

  Sound is an AdLib / OPL2 three-voice space theme, and it is optional in the
  strict sense: the chip is probed at run time and if nothing answers the demo
  runs exactly as it did before.  The sequencer is driven one step per frame
  from the same retrace the scroll is paced by -- see music.pas for why it
  cannot be allowed to wait for anything.

  With no MONO or COLOUR the display is probed at run time, because this card
  boots mono on some resets and colour on others.  A colour ramp is not safe
  on a mono monitor: it sums R+G+B, so two different colours can land on the
  same grey.  The two ramps here are built separately for that reason. }

{$MODE OBJFPC}{$H-}
{$ASMMODE INTEL}

uses VGA, ModeX, Music, Opl2, Cpu, Prof, About;

const
  PERIOD  = 704;              { the world repeats every this many pixels }
  DUPW    = DISP_W;           { and the last DISP_W columns duplicate the first }

  SKY_ROWS = 88;              { gradient band, painted full width before terrain }

  { Four, and the count is a timing decision rather than a visual one.  The
    sprites are the entire frame budget, so their number is the one knob that
    moves it linearly, and the budget has hard cliffs at every 14.27ms.  What
    the hardware actually said, at 3 px/frame with the music playing:

        6 sprites   ~19ms   straddles 14.27 badly   33 fps, juddering
        5 sprites   ~14.5ms straddles 14.27         56 fps, still juddering
        4 sprites   ~11.5ms clear of it             70 fps, steady

    56 fps sounds better than 35 and is worse: it is a mixture of one- and
    two-refresh frames, which is precisely the judder this demo exists to
    avoid.  FlipLate counts those, and it is the number to watch. }
  NSPR   = 4;
  SPR_W  = 16;
  SPR_H  = 16;
  SPR_AW = 5;                 { addresses a 16-pixel sprite can touch: 5 }
  SPR_SV = SPR_AW * SPR_H;    { bytes of backing store per sprite, per plane }

  { Screen-space travel allowed to a sprite, in whole pixels.  Bounded so that
    world x = scroll + sx stays inside the virtual screen with room for the
    five-address save rectangle: 703 + 300 = 1003, and 1003 div 4 + 5 = 255. }
  SPRX_MAX = 300;
  FP       = 16;              { sprite positions are 12.4 fixed point }
  SPRX_RNG = (SPRX_MAX + 1) * FP;

  { The BIOS tick is 18.2 Hz -- 182 per ten seconds, which is exactly the trap
    to avoid writing as "182 per second". }
  TICKS10 = 182;              { ticks in ten seconds }
  TICKDAY = 1573040;          { ticks in a day, for the midnight wrap }
  USPERTICK = 54945;          { microseconds in one BIOS tick }
  USPERREFR = 14268;          { ...and in one 70.1 Hz vertical refresh }

  { Palette slots.  Background is 1..28 so index 0 stays black; sprites start
    at 64 to leave room to add scenery without renumbering anything. }
  C_SKY   = 1;    { 8 shades, top to horizon }
  C_MTN   = 9;    { 4 }
  C_HILL  = 13;   { 4 }
  C_GND   = 17;   { 4 }
  C_GRASS = 22;
  C_ROCK  = 23;
  C_DARK  = 24;
  C_LINE  = 21;
  C_WHITE = 25;   { 4 shades, brightest first }
  C_SPR   = 64;   { 6 sets of 4 }

  { Quarter sine, 0..90 degrees in 64 steps, scaled to +-64.  Generated once
    and pasted in rather than computed: there is no FPU here to rely on, and
    the four coprocessor rows of BENCH print "skipped" on this box. }
  SinQ: array[0..64] of Integer = (
      0,   2,   3,   5,   6,   8,   9,  11,  12,  14,  16,  17,  19,
     20,  22,  23,  24,  26,  27,  29,  30,  32,  33,  34,  36,  37,
     38,  39,  41,  42,  43,  44,  45,  46,  47,  48,  49,  50,  51,
     52,  53,  54,  55,  56,  56,  57,  58,  59,  59,  60,  60,  61,
     61,  62,  62,  62,  63,  63,  63,  64,  64,  64,  64,  64,  64);

  { Background palette.  The two ramps are independent on purpose; the mono
    one is evenly spaced by depth so the layers separate by brightness alone. }
  BgRGB: array[1..28, 0..2] of Byte = (
    ( 0, 0,16), ( 2, 3,20), ( 4, 7,25), ( 8,12,30),          { sky }
    (13,18,36), (19,25,42), (26,33,48), (34,41,54),
    (30,28,44), (26,24,40), (22,20,36), (18,16,32),          { far mountains }
    (12,34,24), (10,28,20), ( 8,23,16), ( 6,18,13),          { hills }
    (40,28,14), (34,23,11), (28,18, 9), (22,14, 7),          { ground }
    (52,44,20), (16,42,20), (30,30,30), (12,10, 8),          { line/grass/rock/shadow }
    (63,63,63), (52,52,56), (44,44,50), (36,36,44));         { snow, cloud, stars }

  BgGrey: array[1..28] of Byte = (
     2,  3,  5,  6,  8,  9, 11, 12,                          { sky }
    20, 18, 16, 14,                                          { far mountains }
    30, 27, 24, 21,                                          { hills }
    40, 37, 34, 31,                                          { ground }
    46, 43, 28, 12,                                          { line/grass/rock/shadow }
    58, 52, 48, 44);                                         { snow, cloud, stars }

  { Six sprite ramps, brightest shade first. }
  SprRGB: array[0..5, 0..3, 0..2] of Byte = (
    ((63,24,20), (50,15,12), (36, 9, 8), (20, 5, 4)),
    ((63,58,16), (52,46,10), (40,34, 6), (26,22, 4)),
    ((20,58,63), (14,46,52), (10,34,40), ( 6,22,26)),
    ((63,26,58), (50,18,46), (38,12,34), (24, 8,22)),
    ((60,60,60), (48,48,48), (36,36,36), (24,24,24)),
    ((30,63,24), (22,50,18), (16,38,12), (10,24, 8)));

  { On mono every sprite has to out-brighten the ground (46 at most), so the
    ramps all live at the top of the range and differ only slightly. }
  SprGrey: array[0..5, 0..3] of Byte = (
    (63, 57, 51, 45), (62, 56, 50, 44), (61, 55, 49, 43),
    (60, 54, 48, 42), (59, 53, 47, 41), (58, 52, 46, 40));

  Shades = ' .:-=+*#%@';
  SHOT_W = 64;
  SHOT_H = 25;

var
  { --- options --- }
  RunSecs   : Integer;
  Speed     : Integer;
  WantShot  : Boolean;
  Profiling : Boolean;
  WantMusic : Boolean;
  Colour    : Boolean;
  Forced    : ShortString;
  BadArg    : ShortString;

  { --- state --- }
  OldMode   : Byte;
  Scroll    : Word;
  Frames    : LongInt;
  StartTick : LongInt;
  Elapsed   : LongInt;
  PaintMs   : LongInt;
  Lum       : array[0..255] of Byte;
  Shot      : array[0..SHOT_H - 1] of ShortString;
  ShotAt    : Word;

  { Terrain skylines, one entry per world column. }
  MtnTop  : array[0..PERIOD - 1] of Integer;
  HillTop : array[0..PERIOD - 1] of Integer;
  GndTop  : array[0..PERIOD - 1] of Integer;

  { --- sprites --- }
  { Shape as authored: one byte per pixel, 0 transparent. Only ever read by
    BuildSprites. }
  Shape   : array[0..SPR_H - 1, 0..SPR_W - 1] of Byte;

  { Shape as blitted.  Deinterleaved into the four column groups c mod 4,
    because within one group the four columns land on four *consecutive*
    addresses in one plane -- which is what turns the inner loop into a
    REP MOVSB instead of four test-and-store sequences.

    Which plane a group goes to depends on the sprite x, but the grouping does
    not, so this is built once and works at every position. }
  SprDI   : array[0..NSPR - 1, 0..3, 0..SPR_H - 1, 0..3] of Byte;

  { (first, count) of the opaque run in each group-row, so transparent edges
    cost nothing.  All three shapes are convex, so a row of one group is a
    single run with no interior hole to punch through. }
  SprSpan : array[0..NSPR - 1, 0..3, 0..SPR_H - 1, 0..1] of Byte;

  { Which of the 16 rows hold anything at all.  The blimp uses seven. }
  SprR0   : array[0..NSPR - 1] of Word;
  SprRH   : array[0..NSPR - 1] of Word;

  SprX    : array[0..NSPR - 1] of Integer;   { screen x, 12.4 }
  SprVX   : array[0..NSPR - 1] of Integer;   { screen dx/frame, 12.4 }
  SprYC   : array[0..NSPR - 1] of Integer;   { lane centre row }
  SprPh   : array[0..NSPR - 1] of Word;      { bob phase }
  SprPr   : array[0..NSPR - 1] of Word;      { bob rate }
  SprSave : array[0..NSPR - 1] of Word;      { where its backing store lives }
  SprAt   : array[0..NSPR - 1] of Word;      { the address it was saved from }
  SprLive : array[0..NSPR - 1] of Boolean;

  Rnd: Word;

{ ------------------------------------------------------------------ helpers }

function Random16: Word;
begin
  { Plain LCG. The scenery only needs to be unrepeatable-looking, not random,
    and this keeps the world identical between runs -- which matters when you
    are comparing two frame-rate measurements. }
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

{ Phase for N whole cycles across the 704-column world.  x*8 div 22 is
  x*256/704 without a 32-bit divide: 703*8*11 is 61864, still a Word.  Whole
  cycles are what makes the world join up to itself at the wrap. }
function Phase(X, N: Word): Word;
begin
  Phase := ((X * 8 * N) div 22) and 255;
end;

function Clamp(V, Lo, Hi: Integer): Integer;
begin
  if V < Lo then Clamp := Lo
  else if V > Hi then Clamp := Hi
  else Clamp := V;
end;

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

{ ------------------------------------------------------------- command line }

procedure ParseArgs;
var
  I, V : Integer;
  A    : ShortString;
begin
  RunSecs  := 30;
  Speed    := 2;
  WantShot := True;
  Profiling := False;
  WantMusic := True;
  Forced   := '';
  BadArg   := '';
  Colour   := IsColourDisplay;

  I := 1;
  while I <= ParamCount do
  begin
    A := Upper(ParamStr(I));
    if A = 'MONO' then begin Colour := False; Forced := 'MONO'; end
    else if (A = 'COLOUR') or (A = 'COLOR') then
      begin Colour := True; Forced := A; end
    else if A = 'NOSHOT' then WantShot := False
    else if A = 'PROF' then Profiling := True
    else if A = 'NOMUSIC' then WantMusic := False
    else if (A = 'SECS') and (I < ParamCount) then
    begin
      Inc(I);
      if ParseInt(ParamStr(I), V) then RunSecs := Clamp(V, 1, 600)
      else BadArg := 'SECS ' + ParamStr(I);
    end
    else if (A = 'SPEED') and (I < ParamCount) then
    begin
      Inc(I);
      if ParseInt(ParamStr(I), V) then Speed := Clamp(V, 1, 8)
      else BadArg := 'SPEED ' + ParamStr(I);
    end
    else
      BadArg := ParamStr(I);
    Inc(I);
  end;
end;

{ ----------------------------------------------------------------- palette }

procedure LoadPalette;
var
  I, S, K: Integer;
  R, G, B: Byte;
begin
  for I := 0 to 255 do Lum[I] := 0;

  DacSeek(0);
  DacGrey(0);

  for I := 1 to 28 do
  begin
    if Colour then
    begin
      R := BgRGB[I, 0];  G := BgRGB[I, 1];  B := BgRGB[I, 2];
      DacSeek(I);
      DacRGB(R, G, B);
    end
    else
    begin
      DacSeek(I);
      DacGrey(BgGrey[I]);
    end;
    { Lum drives the ASCII thumbnail only, and it is taken from the GREY ramp
      whichever palette is loaded.  The colour ramp is chosen for hue, not
      brightness -- the sky at the horizon is lighter than the ground -- so
      ranking the thumbnail by true luminance turns a legible landscape into
      noise.  The grey ramp is ordered by depth, which is what the thumbnail
      is there to show. }
    Lum[I] := BgGrey[I];
  end;

  for S := 0 to 5 do
    for K := 0 to 3 do
    begin
      I := C_SPR + S * 4 + K;
      if Colour then
      begin
        R := SprRGB[S, K, 0];  G := SprRGB[S, K, 1];  B := SprRGB[S, K, 2];
        DacSeek(I);
        DacRGB(R, G, B);
      end
      else
      begin
        DacSeek(I);
        DacGrey(SprGrey[S, K]);
      end;
      Lum[I] := SprGrey[S, K];
    end;
end;

{ ------------------------------------------------------------------- world }

procedure BuildSkylines;
var
  X: Integer;
begin
  for X := 0 to PERIOD - 1 do
  begin
    { Three frequencies for the mountains, two for the hills, two for the
      ground.  All whole cycles across 704, so column 703 runs into column 0
      without a step. }
    MtnTop[X]  := 70 + (Sine(Phase(X, 1)) * 10) div 64
                     + (Sine(Phase(X, 3)) *  5) div 64
                     + (Sine(Phase(X, 7)) *  3) div 64;
    HillTop[X] := 118 + (Sine(Phase(X, 2)) * 14) div 64
                      + (Sine(Phase(X, 5)) *  7) div 64;
    GndTop[X]  := 152 + (Sine(Phase(X, 3) + 64) * 8) div 64
                      + (Sine(Phase(X, 11))     * 4) div 64;
  end;
end;

procedure PaintSky;
var
  Y, Band: Integer;
begin
  MapMask($0F);
  for Y := 0 to SKY_ROWS - 1 do
  begin
    Band := (Y * 8) div SKY_ROWS;
    HSpan(Word(Y) * VWB, VWB, C_SKY + Band);
  end;
end;

procedure PaintStars;
var
  K, X, Y: Integer;
begin
  for K := 1 to 260 do
  begin
    X := Random16 mod PERIOD;
    Y := 2 + (Random16 mod 56);
    { Only the brightest few, or it reads as noise rather than sky. }
    if (K and 7) = 0 then PlotPix(X, Y, C_WHITE)
    else PlotPix(X, Y, C_WHITE + 2 + (K and 1));
  end;
end;

procedure PaintClouds;
var
  K, X, Y, W, I, Row: Integer;
begin
  { Flat-bottomed blobs, drawn on four-pixel boundaries so each row is one
    HSpan rather than a pixel loop.  They are part of the background, so they
    scroll with it -- the drifting ones are sprites. }
  MapMask($0F);
  for K := 0 to 8 do
  begin
    X := (Random16 mod (PERIOD - 120)) and $FFFC;
    Y := 18 + (Random16 mod 44);
    W := 12 + (Random16 mod 12);          { in addresses, so 48..92 pixels }
    for Row := 0 to 3 do
    begin
      I := (W * (3 - Row)) div 4;
      if I < 1 then I := 1;
      HSpan(Word(Y + Row) * VWB + Word(X shr 2) + Word((W - I) div 2), I,
            C_WHITE + 1 + Row div 2);
    end;
  end;
end;

procedure PaintColumn(X: Integer);
var
  Mt, Hl, Gr, Base, Q, I, Top: Integer;
begin
  Mt := MtnTop[X];
  Hl := HillTop[X];
  Gr := GndTop[X];
  Base := X shr 2;

  MapMask(1 shl (X and 3));

  { Far mountains: four bands of equal depth, darkening downwards. }
  Q := (Hl - Mt) div 4;
  Top := Mt;
  for I := 0 to 3 do
  begin
    if I = 3 then VRun(Word(Top) * VWB + Word(Base), Hl - Top, C_MTN + 3)
    else VRun(Word(Top) * VWB + Word(Base), Q, C_MTN + I);
    Inc(Top, Q);
  end;

  { Hills. }
  Q := (Gr - Hl) div 4;
  Top := Hl;
  for I := 0 to 3 do
  begin
    if I = 3 then VRun(Word(Top) * VWB + Word(Base), Gr - Top, C_HILL + 3)
    else VRun(Word(Top) * VWB + Word(Base), Q, C_HILL + I);
    Inc(Top, Q);
  end;

  { Ground. }
  Q := (200 - Gr) div 4;
  Top := Gr;
  for I := 0 to 3 do
  begin
    if I = 3 then VRun(Word(Top) * VWB + Word(Base), 200 - Top, C_GND + 3)
    else VRun(Word(Top) * VWB + Word(Base), Q, C_GND + I);
    Inc(Top, Q);
  end;

  { --- detail, all of it there to make the motion readable --- }

  { A lit rim on the ridge, or snow where the peak is high enough. }
  if Mt <= 58 then VRun(Word(Mt) * VWB + Word(Base), 3, C_WHITE)
  else VRun(Word(Mt) * VWB + Word(Base), 1, C_WHITE + 2);

  { Trees on the hill line: two columns wide every thirteen. }
  if (X mod 13) < 2 then
  begin
    VRun(Word(Hl - 7) * VWB + Word(Base), 7, C_HILL + 3);
    VRun(Word(Hl) * VWB + Word(Base), 2, C_DARK);
  end;

  { Grass at the ground line, and rocks scattered just below it. }
  if (X mod 7) = 0 then VRun(Word(Gr - 1) * VWB + Word(Base), 2, C_GRASS);
  if (X mod 29) < 3 then VRun(Word(Gr + 2) * VWB + Word(Base), 4, C_ROCK);

  { Two dashed lines at different periods.  These are the strongest cue that
    the ground is moving, and having two of them at 12 and 7 columns keeps
    the eye from locking onto a single beat. }
  if ((X div 12) and 1) = 0 then
    VRun(Word(Gr + 10) * VWB + Word(Base), 3, C_LINE);
  if ((X div 7) and 1) = 0 then
    VRun(Word(Gr + 24) * VWB + Word(Base), 2, C_DARK);
end;

procedure PaintWorld;
var
  X: Integer;
begin
  Rnd := 31337;
  PaintSky;
  PaintClouds;
  PaintStars;
  for X := 0 to PERIOD - 1 do PaintColumn(X);

  { The seam is handled by making the last DISP_W columns a copy of the first
    DISP_W, so a window at scroll 703 shows the end of the world followed by
    its beginning.  Both edges are four-pixel aligned, so this is a straight
    address-range move and the latches shift all four planes at once. }
  CopyRect(0, VWB, PERIOD div 4, VWB, DUPW div 4, VH);
end;

{ ----------------------------------------------------------------- sprites }

procedure BuildSprites;
var
  S, C, R, G, K, Dx, Dy, Ld, Sh: Integer;
  First, Last, RFirst, RLast: Integer;
  Inside, Any: Boolean;
begin
  for S := 0 to NSPR - 1 do
  begin
    RFirst := SPR_H;
    RLast  := -1;

    for R := 0 to SPR_H - 1 do
    begin
      Any := False;
      for C := 0 to SPR_W - 1 do
      begin
        Dx := C - 7;
        Dy := R - 7;
        case S mod 3 of
          { Radii chosen for the row count as much as the look: every row a
            shape does not use is one fewer row in the blit AND in the
            save/restore, on all three of them.  Going from 15 rows to 13
            bought about 2.9ms a frame and costs two pixels of diameter. }
          0: Inside := (9 * Dx * Dx + 49 * Dy * Dy) <= 441;   { blimp, 7 rows }
          1: Inside := (Dx * Dx + Dy * Dy) <= 42;             { orb,  13 rows }
        else
          Inside := (Abs(Dx) + Abs(Dy)) <= 6;                 { kite, 13 rows }
        end;

        if not Inside then
          Shape[R, C] := 0
        else
        begin
          { Shade from a light source up and to the left, which is enough to
            stop a flat blob reading as a hole in the screen. }
          Ld := (C - 4) * (C - 4) + (R - 4) * (R - 4);
          Sh := Clamp(Ld div 24, 0, 3);
          Shape[R, C] := C_SPR + S * 4 + Sh;
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

    for G := 0 to 3 do
      for R := 0 to SPR_H - 1 do
      begin
        First := -1;
        Last  := -1;
        for K := 0 to 3 do
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
        end;
      end;
  end;
end;

procedure InitSprites;
var
  I: Integer;
const
  { Screen-space drift, 12.4 -- 16 units is one pixel per frame, so 70 pixels
    a second.  Mixed signs so some sprites overtake the ground and some fall
    behind it; that difference is the whole illusion of depth. }
  Vel: array[0..NSPR - 1] of Integer = (5, -3, 13, -9);
  Bob: array[0..NSPR - 1] of Word    = (3, 5, 2, 7);
begin
  for I := 0 to NSPR - 1 do
  begin
    SprX[I]   := (I * 47 * FP) mod SPRX_RNG;
    SprVX[I]  := Vel[I];
    { Lanes 42 rows apart.  A sprite is 16 tall and bobs 5 either way, so 26
      of those 42 are used and two lanes can never touch.  That is what lets
      restore-save-draw run one sprite at a time. }
    SprYC[I]  := 22 + I * 42;
    SprPh[I]  := I * 40;
    SprPr[I]  := Bob[I];
    SprSave[I] := PGSZ + Word(I) * SPR_SV;
    SprAt[I]   := 0;
    SprLive[I] := False;
  end;
end;

{ One column group of one sprite: Rows rows of up to four consecutive bytes,
  source stride four, destination stride VWB.

  The first version of this tested and stored one pixel at a time and cost
  about 3.6ms a sprite, which was 60% of the whole frame.  That is the penalty
  CLAUDE.md already records for hand loops against string instructions, and it
  is the reason the sprite data is deinterleaved: within a column group the
  four pixels are consecutive in one plane, so a row becomes one REP MOVSB.
  Transparency comes from the precomputed run rather than a test per pixel, so
  the fast path stays a string operation. }
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
  mov  al, [bx]        { first opaque pixel of this row, 0..3 }
  xor  ah, ah
  add  si, ax
  add  di, ax
  mov  cl, [bx + 1]    { how many of them }
  xor  ch, ch
  add  ax, cx          { total distance SI and DI are about to travel }
  jcxz @@empty
  rep  movsb
@@empty:
  { Wind back by that distance rather than saving the row start on the stack.
    Two SUBs against four stack operations, 288 rows a frame -- worth about
    1.7ms, which here is the whole difference between 35 fps and 23. }
  sub  si, ax
  sub  di, ax
  add  bx, 2
  add  si, 4
  add  di, VWB
  dec  dx
  jnz  @@row
  pop  bx
  pop  di
  pop  si
  pop  es
  pop  ds
end;

procedure DrawSprite(I: Integer; WX, WY: Word);
var
  G, R0: Word;
begin
  R0 := SprR0[I];
  for G := 0 to 3 do
  begin
    { Group G holds sprite columns G, G+4, G+8, G+12.  All four land in plane
      (WX + G) mod 4 at consecutive addresses from (WX + G) div 4 -- so the
      sprite x supplies the phase and the group table itself never shifts. }
    MapMask(1 shl ((WX + G) and 3));
    SprGroup(Seg(SprDI[I, G, R0, 0]),
             Ofs(SprDI[I, G, R0, 0]),
             Ofs(SprSpan[I, G, R0, 0]),
             (WY + R0) * VWB + ((WX + G) shr 2),
             SprRH[I]);
  end;
end;

{ ------------------------------------------------------------------- output }

procedure GrabShot;
var
  R, C, X, Y, L: Integer;
  Line: ShortString;
begin
  { Nothing drawn to A000 comes back over the bridge, so without this a run
    from Windows returns a frame count and no evidence there was a picture.
    Reading a pixel back needs the Read Map Select register; in an unchained
    mode the CPU cannot see all four planes at one address.

    Captured now and printed later.  WriteLn while a graphics mode is set
    goes through the BIOS teletype and paints characters into the picture --
    harmless when the job has redirected stdout, ugly at the keyboard. }
  for R := 0 to SHOT_H - 1 do
  begin
    Y := R * 8;
    Line := '';
    for C := 0 to SHOT_W - 1 do
    begin
      X := Scroll + C * 5;
      L := Lum[PeekPix(X, Y)];
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
  WriteLn('screen at scroll ', NumStr(ShotAt), '  (', NumStr(SHOT_W), 'x',
          NumStr(SHOT_H), ' of 320x200, sampled)');
  for R := 0 to SHOT_H - 1 do WriteLn('  |', Shot[R], '|');
end;

procedure Report(ModeOk: Boolean);
var
  Fps10, FrameUs, Refr: LongInt;
begin
  WriteLn('=== scroller ===');
  WriteLn('CPU          : ', CpuName);
  if not ModeOk then
  begin
    WriteLn('mode X       : REFUSED -- registers did not read back');
    Exit;
  end;
  WriteLn('mode X       : 320x200x256 unchained, virtual ', NumStr(VW),
          'x', NumStr(VH));
  WriteLn('world        : ', NumStr(PERIOD), ' px, last ', NumStr(DUPW),
          ' columns duplicate the first (seamless wrap)');
  WriteLn('video used   : ', NumStr(LongInt(PGSZ) * 4), ' of 262144 bytes');
  WriteLn('CRTC / status: ', HexStr(CrtcBase), ' / ', HexStr(StatBase));
  if Forced <> '' then
    WriteLn('palette      : ', Forced, ' (forced)')
  else if Colour then
    WriteLn('palette      : colour (probed)')
  else
    WriteLn('palette      : mono (probed)');
  WriteLn('world paint  : ', NumStr(PaintMs), ' ms');
  WriteLn('scroll speed : ', NumStr(Speed), ' px/frame');
  WriteLn('sprites      : ', NumStr(NSPR), ' at 16x16, one lane each');
  WriteLn('lanes        : 42 rows apart, so no two can overlap');
  if not WantMusic then
    WriteLn('music        : off (NOMUSIC)')
  else if MusicOn or (MusicNotes > 0) then
    WriteLn('music        : OPL2 at 388h, 3 voices, ', NumStr(MusicNotes),
            ' notes, ', NumStr(MusicLoops), ' times round the 8 bars')
  else
    WriteLn('music        : no OPL2 answered at 388h (idle=', NumStr(OplIdle),
            ' timer=', NumStr(OplTimer), ', want 0 then 192)');
  WriteLn('frames       : ', NumStr(Frames));
  WriteLn('elapsed      : ', NumStr((Elapsed * 10000) div TICKS10), ' ms (',
          NumStr(Elapsed), ' ticks)');
  if Elapsed > 0 then
  begin
    Fps10 := (Frames * TICKS10) div Elapsed;
    WriteLn('frame rate   : ', NumStr(Fps10 div 10), '.', NumStr(Fps10 mod 10),
            ' fps');
    WriteLn('scrolled     : ', NumStr(Frames * Speed), ' px in ',
            NumStr(Frames * Speed div PERIOD), ' laps of the world');
  end;
  if (Elapsed > 0) and (Frames > 0) then
  begin
    FrameUs := (Elapsed * USPERTICK) div Frames;
    Refr    := (FrameUs + (USPERREFR div 2)) div USPERREFR;
    if Refr < 1 then Refr := 1;
    WriteLn('frame        : ', NumStr(FrameUs), ' us = ', NumStr(Refr),
            ' vertical refresh(es)');
    WriteLn('               ShowAt blocks on the retrace, so the rate can');
    WriteLn('               only be 70.1 / N.  N went 3 -> 2 when the blitter');
    WriteLn('               stopped being a hand loop, and 2 -> 1 at four');
    WriteLn('               sprites; 1 is as fast as the hardware goes.');
  end;
  WriteLn('late frames  : ', NumStr(FlipLate), ' of ', NumStr(Frames),
          '  (arrived after the retrace had started -- these are the judder)');
  WriteLn('flip timeouts: ', NumStr(FlipTimeouts),
          '  (retrace waits that gave up; 0 is healthy)');
  if BadArg <> '' then
    WriteLn('NOTE         : ignored argument "', BadArg, '"');
end;

{ --------------------------------------------------------------------- main }

var
  I, WY   : Integer;
  WX      : Word;
  T0      : LongInt;
  Limit   : LongInt;
  ModeOk  : Boolean;
  Quit    : Boolean;

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

begin
  ParseArgs;
  DrainKeys;

  OldMode := GetMode;
  BuildSkylines;
  BuildSprites;
  InitSprites;

  ModeOk := Enter;
  if not ModeOk then
  begin
    SetMode(OldMode);
    MusicStop;
    Report(False);
    Halt(1);
  end;

  LoadPalette;

  { Probe and load the patches before the world is painted.  Nothing sounds
    until MusicTick is called, so this only has to happen before the loop. }
  if WantMusic then MusicStart;

  T0 := Ticks;
  PaintWorld;
  PaintMs := ((Ticks - T0) * 10000) div TICKS10;

  Scroll := 0;
  Frames := 0;
  if Profiling then ProfStart;
  Quit   := False;
  StartTick := Ticks;
  Limit     := (LongInt(RunSecs) * TICKS10) div 10;

  repeat
    { Latch the scroll for the frame that is about to be drawn by the CRT.
      This returns just inside the vertical blank, so everything below runs
      while the beam is sweeping -- and because the sprites are handled top
      lane first, the erase stays ahead of the beam and is not seen. }
    ShowAt(Scroll);
    if Profiling then Mark('flip/idle');
    Inc(Frames);

    { In the vertical blank, ahead of the sprites.  Worst case is nine OPL
      register writes when all three voices change on the same step, about
      700us of the 4ms of slack in the frame. }
    MusicTick(Ticks - StartTick);
    if Profiling then Mark('music');

    Inc(Scroll, Speed);
    if Scroll >= PERIOD then Dec(Scroll, PERIOD);

    for I := 0 to NSPR - 1 do
    begin
      { Restore to the address it was saved from, never to a recomputed one:
        the world wraps underneath the sprites and a recomputed address would
        be wrong for exactly one frame per lap. }
      if SprLive[I] then
        CopyRect(SprSave[I], SPR_AW, SprAt[I], VWB, SPR_AW, SprRH[I]);
      if Profiling then Mark('erase');

      Inc(SprX[I], SprVX[I]);
      if SprX[I] >= SPRX_RNG then Dec(SprX[I], SPRX_RNG);
      if SprX[I] < 0 then Inc(SprX[I], SPRX_RNG);
      SprPh[I] := (SprPh[I] + SprPr[I]) and 255;

      WX := Scroll + Word(SprX[I] div FP);
      WY := SprYC[I] + (Sine(SprPh[I]) * 5) div 64;

      SprAt[I] := Word(WY + Integer(SprR0[I])) * VWB + (WX shr 2);
      CopyRect(SprAt[I], VWB, SprSave[I], SPR_AW, SPR_AW, SprRH[I]);
      SprLive[I] := True;
      if Profiling then Mark('save');

      DrawSprite(I, WX, Word(WY));
      if Profiling then Mark('draw');
    end;

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

  { Capture before restoring text mode: setting a mode clears video memory,
    which is why a demo that tidies up after itself leaves VSHOT nothing to
    photograph. }
  ShotAt := Scroll;
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
