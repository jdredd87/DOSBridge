program VShot;
{ DOS Bridge  --  StevenC }
{ Capture a mode 13h graphics screen and print it as ASCII art.

  Usage:  VSHOT             capture, then restore text mode
          VSHOT /K          capture and keep the graphics mode set

  Why this exists: graphics output is completely invisible over the bridge.
  A program that draws to A000 returns an empty log, so the only evidence a
  fractal or a bouncing ball ever appeared was the statistics it printed about
  itself. This downsamples the framebuffer to characters and sends that back,
  which turns "trust the counters" into actually looking at the picture.

  Brightness comes from the DAC, not the palette index. Index order means
  nothing -- index 1 may be brighter than index 200 -- so each entry's real RGB
  is read back from the hardware and converted to luma.

  Setting a video mode clears video memory, so the program under test must NOT
  restore text mode on exit or there will be nothing left to capture. Run it as:
      dosexec "MYPROG" "VSHOT" }

{$MODE OBJFPC}{$H-}
{$ASMMODE INTEL}


uses About;

const
  SCR_W  = 320;
  SCR_H  = 200;
  VGA    = $A000;

  OUT_W  = 76;             { fits inside an 80 column capture with a border }
  OUT_H  = 22;
  SAMP   = 3;              { SAMP x SAMP samples averaged per output cell }

  RAMP   = ' .:-=+*#%@';   { 10 levels, dark to light }

var
  Mode    : Byte;
  Luma    : array[0..255] of Byte;
  Keep    : Boolean;
  X, Y    : Integer;
  Cx, Cy  : Integer;
  Sx, Sy  : Integer;
  Sum     : LongInt;
  N       : Integer;
  V       : Integer;
  Line    : ShortString;
  K       : Integer;
  A       : ShortString;
  MinL    : Integer;
  MaxL    : Integer;
  Painted : LongInt;

function GetMode: Byte;
var W: Word;
begin
  asm
    mov ah, 0Fh
    int 10h
    mov W, ax
  end;
  GetMode := W and $FF;
end;

procedure SetMode(M: Byte);
begin
  asm
    mov al, M
    xor ah, ah
    int 10h
  end;
end;

procedure OutB(P: Word; Vl: Byte);
begin
  asm
    mov dx, P
    mov al, Vl
    out dx, al
  end;
end;

function InB(P: Word): Byte;
var Vl: Byte;
begin
  asm
    mov dx, P
    in  al, dx
    mov Vl, al
  end;
  InB := Vl;
end;

{ Read all 256 DAC entries and reduce each to a luma value 0..63. Port 3C7 sets
  the read index; three reads from 3C9 then give R, G and B, each 0..63. }
procedure ReadPaletteLuma;
var
  I, R, G, B: Integer;
begin
  for I := 0 to 255 do
  begin
    OutB($3C7, Byte(I));
    R := InB($3C9);
    G := InB($3C9);
    B := InB($3C9);
    Luma[I] := Byte((R * 30 + G * 59 + B * 11) div 100);
  end;
end;

begin
  Keep := False;
  for K := 1 to ParamCount do
  begin
    A := ParamStr(K);
    if (A = '/K') or (A = '/k') then Keep := True;
  end;

  Mode := GetMode;
  if Mode <> $13 then
  begin
    WriteLn('VSHOT: video mode is ', Mode, ', not 13h.');
    if (Mode <= 3) or (Mode = 7) then
      WriteLn('       That is a text mode -- use SCRAPE instead.')
    else
      WriteLn('       Only mode 13h (320x200x256) is supported.');
    Halt(1);
  end;

  ReadPaletteLuma;

  MinL := 999;
  MaxL := -1;
  Painted := 0;

  WriteLn('=== vshot: mode 13h, ', SCR_W, 'x', SCR_H, ' -> ',
          OUT_W, 'x', OUT_H, ' ===');
  WriteLn('   +', '':OUT_W, '+');

  for Cy := 0 to OUT_H - 1 do
  begin
    Line := '';
    for Cx := 0 to OUT_W - 1 do
    begin
      Sum := 0;
      N   := 0;
      { Average a small grid inside the cell rather than point sampling, so a
        one-pixel line does not vanish between samples. }
      for Sy := 0 to SAMP - 1 do
        for Sx := 0 to SAMP - 1 do
        begin
          X := ((Cx * SCR_W) div OUT_W) + (Sx * (SCR_W div OUT_W)) div SAMP;
          Y := ((Cy * SCR_H) div OUT_H) + (Sy * (SCR_H div OUT_H)) div SAMP;
          if X >= SCR_W then X := SCR_W - 1;
          if Y >= SCR_H then Y := SCR_H - 1;
          Sum := Sum + Luma[Mem[VGA : Word(Y) * SCR_W + Word(X)]];
          Inc(N);
        end;

      V := Sum div N;                     { 0..63 }
      if V < MinL then MinL := V;
      if V > MaxL then MaxL := V;
      if V > 0 then Inc(Painted);

      K := (V * (Length(RAMP) - 1)) div 63;
      if K < 0 then K := 0;
      if K > Length(RAMP) - 1 then K := Length(RAMP) - 1;
      Line := Line + RAMP[K + 1];
    end;
    WriteLn('   |', Line, '|');
  end;

  WriteLn('   +', '':OUT_W, '+');
  WriteLn;
  WriteLn('  cell luma range  : ', MinL, ' .. ', MaxL, ' (of 63)');
  WriteLn('  non-black cells  : ', Painted, ' of ', OUT_W * OUT_H);
  WriteLn('  ramp             : "', RAMP, '"');

  if not Keep then
  begin
    SetMode(3);
    WriteLn('  text mode restored');
  end
  else
    WriteLn('  graphics mode left set (/K)');
end.
