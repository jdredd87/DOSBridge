program Balls;
{ DOS Bridge  --  StevenC }
{ Bouncing balls in VGA mode 13h for ten seconds, then quit.

  The mode 13h plumbing -- retrace sync, DAC writes, span fill, the mono/colour
  probe -- lives in the VGA unit. What is left here is the demo itself.

  Notes for the 8086-class baseline this targets:

  * Positions are 12.4 fixed point (16 units per pixel). Whole-pixel positions
    would visibly stair-step at these speeds, and 8.8 would overflow: 319*256
    is 81664, well past a 16-bit Integer. 12.4 tops out at 5104 and keeps the
    physics in fast 16-bit arithmetic.
  * The screen is never cleared per frame. Clearing 64000 bytes costs more than
    the whole frame budget, so each ball erases just its own bounding box.
  * It reports what it did with WriteLn. Direct writes to A000 never make it
    back over the bridge, so a program that only draws returns an empty log.
    Run VSHOT in the same job if you want to see the picture. }

{$MODE OBJFPC}{$H-}

uses VGA, About;

const
  RUN_TICKS = 182;         { BIOS ticks at 18.2 Hz, so about ten seconds }

  NBALLS    = 6;
  R         = 8;           { ball radius in pixels }
  FP        = 16;          { fixed-point units per pixel (12.4) }

  { Play area, inset so a ball never overwrites the border. }
  MINX = R + 2;   MAXX = SCR_W - 1 - R - 2;
  MINY = R + 2;   MAXY = SCR_H - 1 - R - 2;

  BORDER_COL = 7;

  { Ball colours, and the grey levels used instead on a mono display. }
  BallRGB: array[1..NBALLS, 0..2] of Byte = (
    (63, 16, 16),   (16, 63, 16),   (32, 32, 63),
    (63, 63, 16),   (63, 32, 63),   (16, 63, 63));
  BallGrey: array[1..NBALLS] of Byte = (20, 27, 34, 42, 50, 60);

var
  OldMode    : Byte;
  StartTick  : LongInt;
  Elapsed    : LongInt;
  Frames     : LongInt;
  Bounces    : LongInt;
  UsedColour : Boolean;
  Forced     : ShortString;

  { Per ball: position and velocity in 12.4, plus the pixel position it was
    last drawn at, so the erase covers exactly what the draw covered. }
  BX, BY, BVX, BVY : array[1..NBALLS] of Integer;
  PrevX, PrevY     : array[1..NBALLS] of Integer;

  { Half-width of the ball on each row, so drawing is a span fill rather than a
    distance test per pixel. }
  Span : array[-R..R] of Integer;

  I : Integer;

procedure LoadBallPalette(Colour: Boolean);
var
  K: Integer;
begin
  DacSeek(0);
  DacGrey(0);                            { 0 = black background }
  for K := 1 to NBALLS do
    if Colour then
      DacRGB(BallRGB[K, 0], BallRGB[K, 1], BallRGB[K, 2])
    else
      DacGrey(BallGrey[K]);
  DacGrey(26);                           { BORDER_COL, just past the balls }
end;

function ISqrt(N: Integer): Integer;
var
  K: Integer;
begin
  K := 0;
  while ((K + 1) * (K + 1)) <= N do Inc(K);
  ISqrt := K;
end;

procedure BuildSpans;
var
  Dy: Integer;
begin
  for Dy := -R to R do
    Span[Dy] := ISqrt(R * R - Dy * Dy);
end;

procedure DrawBall(BallX, BallY: Integer; Col: Byte);
var
  Dy, W: Integer;
  Base: Word;
begin
  for Dy := -R to R do
  begin
    W := Span[Dy];
    Base := Word(BallY + Dy) * SCR_W + Word(BallX - W);
    FillSpan(Base, Word(2 * W + 1), Col);
  end;
end;

procedure DrawBorder;
var
  K: Integer;
begin
  FillSpan(0, SCR_W, BORDER_COL);
  FillSpan(Word(SCR_H - 1) * SCR_W, SCR_W, BORDER_COL);
  for K := 0 to SCR_H - 1 do
  begin
    FillSpan(Word(K) * SCR_W, 1, BORDER_COL);
    FillSpan(Word(K) * SCR_W + Word(SCR_W - 1), 1, BORDER_COL);
  end;
end;

procedure InitBalls;
var
  K: Integer;
begin
  for K := 1 to NBALLS do
  begin
    BX[K]  := (40 + K * 38) * FP;
    BY[K]  := (30 + K * 21) * FP;
    { Tuned for the ~34 fps this actually achieves. Speeds share no common
      factor so the balls do not drift into lockstep and start reading as one
      rigid object. Peak is about 4.4 px/frame, well under the 8px radius, so
      nothing tunnels through a wall between frames. }
    BVX[K] := 17 + K * 9;
    BVY[K] := 41 - K * 6;
    if (K and 1) = 0 then BVX[K] := -BVX[K];
    if (K mod 3) = 0 then BVY[K] := -BVY[K];
    PrevX[K] := BX[K] div FP;
    PrevY[K] := BY[K] div FP;
  end;
end;

procedure Step;
var
  K: Integer;
begin
  for K := 1 to NBALLS do
  begin
    BX[K] := BX[K] + BVX[K];
    BY[K] := BY[K] + BVY[K];

    if BX[K] < (MINX * FP) then
    begin
      BX[K] := MINX * FP; BVX[K] := -BVX[K]; Inc(Bounces);
    end
    else if BX[K] > (MAXX * FP) then
    begin
      BX[K] := MAXX * FP; BVX[K] := -BVX[K]; Inc(Bounces);
    end;

    if BY[K] < (MINY * FP) then
    begin
      BY[K] := MINY * FP; BVY[K] := -BVY[K]; Inc(Bounces);
    end
    else if BY[K] > (MAXY * FP) then
    begin
      BY[K] := MAXY * FP; BVY[K] := -BVY[K]; Inc(Bounces);
    end;
  end;
end;

begin
  OldMode := GetMode;
  UsedColour := ChoosePalette(Forced);

  Frames := 0;
  Bounces := 0;

  BuildSpans;
  InitBalls;

  StartTick := Ticks;
  SetMode(MODE13);
  LoadBallPalette(UsedColour);
  DrawBorder;

  { Erase every ball, then move, then draw every ball. Doing it one ball at a
    time would let one ball's erase punch a hole in another that had already
    been redrawn this frame. }
  while (Ticks - StartTick) < RUN_TICKS do
  begin
    WaitRetrace;

    for I := 1 to NBALLS do
      DrawBall(PrevX[I], PrevY[I], 0);

    Step;

    for I := 1 to NBALLS do
    begin
      PrevX[I] := BX[I] div FP;
      PrevY[I] := BY[I] div FP;
      DrawBall(PrevX[I], PrevY[I], Byte(I));
    end;

    Inc(Frames);
  end;

  Elapsed := Ticks - StartTick;
  SetMode(OldMode);

  WriteLn('=== bouncing balls, VGA mode 13h ===');
  WriteLn('  entry video mode   : ', OldMode);
  WriteLn('  balls              : ', NBALLS, ', radius ', R);
  if UsedColour then
    WriteLn('  palette            : ', NBALLS, ' colours + grey border')
  else
    WriteLn('  palette            : ', NBALLS, ' grey levels + grey border');
  if Forced <> '' then
    WriteLn('  palette choice     : forced by argument ', Forced)
  else
    WriteLn('  palette choice     : auto-detected from display code');
  WriteLn('  frames drawn       : ', Frames);
  WriteLn('  wall bounces       : ', Bounces);
  WriteLn('  elapsed ticks      : ', Elapsed, ' (18.2/sec)');
  if Elapsed > 0 then
    WriteLn('  frames per sec x10 : ', (Frames * 182) div Elapsed);
  WriteLn('  retrace timeouts   : ', RetraceTimeouts);
  Write('  final positions    : ');
  for I := 1 to NBALLS do
    Write('(', BX[I] div FP, ',', BY[I] div FP, ') ');
  WriteLn;
  WriteLn('  video mode restored to ', GetMode);
end.
