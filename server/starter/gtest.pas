program GTest;
{ DOS Bridge  --  StevenC }
{ Draw a known test pattern in mode 13h and leave the mode set.

  Usage:  GTEST

  This exists to verify VSHOT. Because setting a video mode clears video
  memory, a program that tidily restores text mode on exit leaves nothing to
  capture -- so this one deliberately does not restore. Pair them:

      dosexec "GTEST" "VSHOT"

  The pattern is chosen so the ASCII capture can be checked by eye rather than
  taken on trust:

    * top third   - horizontal gradient, black at the left to white at the right
    * middle      - a solid mid-grey box with a black hole in its centre
    * bottom      - a diagonal line from bottom-left to top-right
    * a one-pixel white border around the whole screen

  The palette is set to a linear grey ramp so index N really is brightness N,
  which makes the expected output predictable. }

{$MODE OBJFPC}{$H-}
{$ASMMODE INTEL}


uses About;

const
  SCR_W = 320;
  SCR_H = 200;
  VGA   = $A000;

var
  X, Y : Integer;

procedure SetMode(M: Byte);
begin
  asm
    mov al, M
    xor ah, ah
    int 10h
  end;
end;

procedure OutB(P: Word; V: Byte);
begin
  asm
    mov dx, P
    mov al, V
    out dx, al
  end;
end;

procedure Plot(Px, Py: Integer; C: Byte);
begin
  if (Px >= 0) and (Px < SCR_W) and (Py >= 0) and (Py < SCR_H) then
    Mem[VGA : Word(Py) * SCR_W + Word(Px)] := C;
end;

procedure GreyRamp;
var
  I, L: Integer;
begin
  OutB($3C8, 0);
  for I := 0 to 255 do
  begin
    L := I shr 2;                { DAC is 6 bits per channel }
    OutB($3C9, L);
    OutB($3C9, L);
    OutB($3C9, L);
  end;
end;

begin
  SetMode($13);
  GreyRamp;

  { Top third: left-to-right gradient. }
  for Y := 0 to 65 do
    for X := 0 to SCR_W - 1 do
      { LongInt is required: X*255 reaches 81345, which wraps a 16-bit
        Integer past X=128 and folded the right half of the gradient
        back to black. VSHOT is what made that visible. }
      Plot(X, Y, Byte((LongInt(X) * 255) div (SCR_W - 1)));

  { Middle: a solid mid-grey box with a black hole in the middle of it. }
  for Y := 80 to 130 do
    for X := 100 to 220 do
      Plot(X, Y, 128);
  for Y := 98 to 112 do
    for X := 140 to 180 do
      Plot(X, Y, 0);

  { Bottom: a bright diagonal, drawn thick so downsampling cannot lose it. }
  for X := 0 to SCR_W - 1 do
  begin
    Y := SCR_H - 1 - ((X * 45) div SCR_W);
    Plot(X, Y,     255);
    Plot(X, Y - 1, 255);
    Plot(X, Y - 2, 255);
  end;

  { One-pixel white border, so the capture's extent is unambiguous. }
  for X := 0 to SCR_W - 1 do
  begin
    Plot(X, 0, 255);
    Plot(X, SCR_H - 1, 255);
  end;
  for Y := 0 to SCR_H - 1 do
  begin
    Plot(0, Y, 255);
    Plot(SCR_W - 1, Y, 255);
  end;

  { Deliberately no mode restore -- VSHOT needs the framebuffer intact. }
  WriteLn('GTEST: pattern drawn in mode 13h, mode left set for VSHOT');
end.
