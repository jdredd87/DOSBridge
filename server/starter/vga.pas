unit VGA;
{ DOS Bridge  --  StevenC }
{ Shared mode 13h plumbing for the graphics demos.

  This exists because fractal.pas and balls.pas had grown ~60 lines of
  identical helpers between them, and every fix -- the bounded retrace wait,
  the display probe, the six-bit DAC -- had to be made twice or silently drift.

  Everything here is real-mode 8086 safe. Nothing uses 32-bit arithmetic in a
  hot path; see the BENCH figures in CLAUDE.md for why that matters. }

{$MODE OBJFPC}{$H-}
{$ASMMODE INTEL}

interface

const
  SCR_W   = 320;
  SCR_H   = 200;
  VGA_SEG = $A000;
  MODE13  = $13;

var
  { Bumped whenever WaitRetrace gives up rather than blocking. Non-zero means
    the picture may tear; it never means the machine is stuck. }
  RetraceTimeouts: LongInt;

function  Ticks: LongInt;

function  GetMode: Byte;
procedure SetMode(M: Byte);

procedure OutB(P: Word; V: Byte);
function  InB(P: Word): Byte;

{ Raw display combination code from INT 10h AH=1Ah. Supported comes back False
  on a pre-VGA BIOS, which does not implement the call at all. }
function  DisplayCode(out Supported: Boolean): Byte;

{ True if the BIOS reports a colour display. This card boots mono or colour
  unpredictably, so callers must ask at run time rather than assume. }
function  IsColourDisplay: Boolean;

{ Command-line override for the probe. Returns True for colour. Forced comes
  back as the argument that decided it, or '' when the display was probed. }
function  ChoosePalette(out Forced: ShortString): Boolean;

{ DAC writes. Values are 0..63 -- the VGA DAC is six bits per channel, not
  eight, which is the classic way to get a washed-out palette. }
procedure DacSeek(Index: Byte);
procedure DacRGB(R, G, B: Byte);
procedure DacGrey(L: Byte);

{ Wait for the start of vertical retrace. Both loops are bounded: an unbounded
  `repeat until port` wedges the machine and needs a physical reset if that bit
  ever stops toggling. }
procedure WaitRetrace;

{ One horizontal run of pixels as a single REP STOSB. Per-pixel Mem[] writes
  reload a far pointer every time and measure ~7x slower; this is what doubled
  the bouncing-ball frame rate. }
procedure FillSpan(Ofs, Count: Word; Col: Byte);

implementation

function Ticks: LongInt;
begin
  Ticks := MemL[$0040:$006C];
end;

function GetMode: Byte;
var A: Word;
begin
  asm
    mov ah, 0Fh
    int 10h
    mov A, ax
  end;
  GetMode := A and $FF;
end;

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

function InB(P: Word): Byte;
var V: Byte;
begin
  asm
    mov dx, P
    in  al, dx
    mov V, al
  end;
  InB := V;
end;

function DisplayCode(out Supported: Boolean): Byte;
var A, B: Word;
begin
  asm
    mov ax, 1A00h
    int 10h
    mov A, ax
    mov B, bx
  end;
  { AL=1Ah means the BIOS understood the call and BL holds the display
    combination code. Anything else is a pre-VGA BIOS with no opinion. }
  Supported := (A and $FF) = $1A;
  DisplayCode := B and $FF;
end;

function IsColourDisplay: Boolean;
var
  Supported: Boolean;
  Code: Byte;
begin
  Code := DisplayCode(Supported);
  if not Supported then
    IsColourDisplay := True                    { pre-VGA: assume colour }
  else
    case Code of
      1, 5, 7, $0B: IsColourDisplay := False;  { MDA, EGAmono, VGAmono, MCGAmono }
    else
      IsColourDisplay := True;
    end;
end;

function ChoosePalette(out Forced: ShortString): Boolean;
var
  A: ShortString;
begin
  Forced := '';
  A := '';
  if ParamCount >= 1 then A := ParamStr(1);

  if (A = 'MONO') or (A = 'mono') then
  begin
    Forced := A;
    ChoosePalette := False;
  end
  else if (A = 'COLOUR') or (A = 'COLOR') or (A = 'colour') or (A = 'color') then
  begin
    Forced := A;
    ChoosePalette := True;
  end
  else
    ChoosePalette := IsColourDisplay;
end;

procedure DacSeek(Index: Byte);
begin
  OutB($3C8, Index);
end;

procedure DacRGB(R, G, B: Byte);
begin
  OutB($3C9, R);
  OutB($3C9, G);
  OutB($3C9, B);
end;

procedure DacGrey(L: Byte);
begin
  OutB($3C9, L);
  OutB($3C9, L);
  OutB($3C9, L);
end;

procedure WaitRetrace;
var
  Guard: Word;
begin
  Guard := 0;
  while ((InB($3DA) and 8) <> 0) and (Guard < 60000) do Inc(Guard);
  if Guard >= 60000 then
  begin
    Inc(RetraceTimeouts);
    Exit;
  end;

  Guard := 0;
  while ((InB($3DA) and 8) = 0) and (Guard < 60000) do Inc(Guard);
  if Guard >= 60000 then Inc(RetraceTimeouts);
end;

procedure FillSpan(Ofs, Count: Word; Col: Byte); assembler;
asm
  push es
  push di
  mov  ax, VGA_SEG
  mov  es, ax
  mov  di, Ofs
  mov  cx, Count
  mov  al, Col
  cld
  rep  stosb
  pop  di
  pop  es
end;

begin
  RetraceTimeouts := 0;
end.
