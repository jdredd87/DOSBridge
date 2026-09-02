program MatrixRain;
{ DOS Bridge  --  StevenC }
{ Matrix-style digital rain in 80x25 colour text mode.

  Usage:  matrix [seconds]        default 30, any key quits early

  Notes for the 8086-class baseline this targets:

  * Text mode 3 is forced rather than inherited. Some cards boot mono, where
    text lives at B000 with only two intensity levels; forcing mode 3
    guarantees B800 and the colour attributes below.
  * Cells are poked straight into video memory as 16-bit char+attribute pairs.
    80x25 is only 4000 bytes, so unlike the graphics demos there is no need to
    be clever -- a whole frame is cheaper than one ball was.
  * Fading a trail rewrites only the attribute byte, leaving the character
    alone. Re-randomising every cell every step looks like static, not rain.
  * It always returns. A screensaver would normally spin until a keypress, but
    over the bridge nobody can press anything, so a blocked program looks
    exactly like a hung machine. There is a time limit as well as a key check.
  * It reports what it did with WriteLn. Direct writes to B800 never make it
    back over the bridge, so a program that only draws returns an empty log. }

{$MODE OBJFPC}{$H-}
{$ASMMODE INTEL}


uses About;

const
  COLS     = 80;
  ROWS     = 25;
  VID_SEG  = $B800;        { colour text; mode 3 is forced below }
  TEXT_MODE = 3;

  DEF_SECS = 30;

  { Colour text attributes. Only three green-ish levels exist, which is exactly
    the classic look: white head, bright green just behind it, dark green tail. }
  ATTR_HEAD = $0F;         { bright white }
  ATTR_HOT  = $0A;         { bright green }
  ATTR_MID  = $02;         { dark green }
  ATTR_OFF  = $00;

  HOT_LEN = 2;             { cells behind the head that stay bright }

  { CP437 glyphs that read well as falling code. }
  GLYPHS = '0123456789ABCDEFGHJKLMNPQRSTUVWXYZ:.=*+-<>|/\[]{}$#@%&!?';

var
  OldMode    : Byte;
  StartTick  : LongInt;
  Elapsed    : LongInt;
  RunTicks   : LongInt;
  Steps      : LongInt;
  Respawns   : LongInt;
  CellsWrit  : LongInt;
  Interrupted: Boolean;
  RunSecs    : Integer;
  RndState   : Word;

  { One falling drop per column. Y is the head row and starts negative so the
    rain drips in from above the screen rather than appearing all at once. }
  DropY   : array[0..COLS - 1] of Integer;
  DropLen : array[0..COLS - 1] of Integer;
  DropSpd : array[0..COLS - 1] of Integer;
  DropCnt : array[0..COLS - 1] of Integer;

  C, Code : Integer;
  Arg     : ShortString;
  LastTick: LongInt;
  T       : LongInt;

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

{ CH bit 5 set hides the cursor. Restored to a normal underline on the way out. }
procedure HideCursor;
begin
  asm
    mov ah, 01h
    mov cx, 2000h
    int 10h
  end;
end;

procedure ShowCursor;
begin
  asm
    mov ah, 01h
    mov cx, 0607h
    int 10h
  end;
end;

{ INT 16h AH=01h peeks at the keyboard buffer without blocking. }
function KeyWaiting: Boolean;
var
  F: Word;
begin
  asm
    mov ah, 01h
    int 16h
    pushf
    pop  ax
    mov  F, ax
  end;
  KeyWaiting := (F and 64) = 0;      { ZF clear means a key is waiting }
end;

procedure FlushKey;
begin
  asm
    mov ah, 00h
    int 16h
  end;
end;

{ Plain 16-bit LCG. Random from the RTL would drag in more than this needs. }
function Rnd(N: Integer): Integer;
begin
  RndState := Word(RndState * 25173 + 13849);
  if N <= 0 then
    Rnd := 0
  else
    Rnd := (RndState shr 4) mod Word(N);
end;

function RandGlyph: Char;
begin
  RandGlyph := GLYPHS[1 + Rnd(Length(GLYPHS))];
end;

procedure PutCell(Col, Row: Integer; Ch: Char; Attr: Byte);
begin
  MemW[VID_SEG : Word((Row * COLS + Col) * 2)] :=
    Word(Ord(Ch)) or (Word(Attr) shl 8);
  Inc(CellsWrit);
end;

{ Fading touches the attribute byte only, so the glyph underneath survives. }
procedure PutAttr(Col, Row: Integer; Attr: Byte);
begin
  Mem[VID_SEG : Word((Row * COLS + Col) * 2 + 1)] := Attr;
end;

procedure ClearScreen;
var
  I: Integer;
begin
  for I := 0 to COLS * ROWS - 1 do
    MemW[VID_SEG : Word(I * 2)] := Word(Ord(' ')) or (Word(ATTR_OFF) shl 8);
end;

procedure Respawn(Col: Integer);
begin
  DropY[Col]   := -Rnd(ROWS);        { stagger the restart above the screen }
  DropLen[Col] := 5 + Rnd(14);
  DropSpd[Col] := 1 + Rnd(4);        { ticks between steps; varies the speed }
  DropCnt[Col] := DropSpd[Col];
  Inc(Respawns);
end;

procedure StepColumn(Col: Integer);
var
  I, R: Integer;
begin
  Inc(DropY[Col]);

  { The head is a fresh glyph in white. }
  if (DropY[Col] >= 0) and (DropY[Col] < ROWS) then
    PutCell(Col, DropY[Col], RandGlyph, ATTR_HEAD);

  { Everything behind it fades, keeping whatever glyph it already had. }
  for I := 1 to DropLen[Col] - 1 do
  begin
    R := DropY[Col] - I;
    if (R >= 0) and (R < ROWS) then
      if I <= HOT_LEN then
        PutAttr(Col, R, ATTR_HOT)
      else
        PutAttr(Col, R, ATTR_MID);
  end;

  { One cell in the trail occasionally flickers to a different glyph. This is
    what stops the rain looking like rigid strings sliding down. }
  if Rnd(4) = 0 then
  begin
    R := DropY[Col] - 1 - Rnd(DropLen[Col]);
    if (R >= 0) and (R < ROWS) then
      PutCell(Col, R, RandGlyph, ATTR_MID);
  end;

  { Blank the cell that just fell off the tail. }
  R := DropY[Col] - DropLen[Col];
  if (R >= 0) and (R < ROWS) then
    PutCell(Col, R, ' ', ATTR_OFF);

  if R >= ROWS then
    Respawn(Col);
end;

begin
  RunSecs := DEF_SECS;
  if ParamCount >= 1 then
  begin
    Arg := ParamStr(1);
    Val(Arg, RunSecs, Code);
    if (Code <> 0) or (RunSecs < 1) or (RunSecs > 600) then
      RunSecs := DEF_SECS;
  end;
  RunTicks := (LongInt(RunSecs) * 182) div 10;

  OldMode := GetMode;
  RndState := Word(Ticks) or 1;

  Steps       := 0;
  Respawns    := 0;
  CellsWrit   := 0;
  Interrupted := False;

  SetMode(TEXT_MODE);
  HideCursor;
  ClearScreen;

  for C := 0 to COLS - 1 do
  begin
    Respawn(C);
    DropCnt[C] := 1 + Rnd(DropSpd[C]);
  end;
  Respawns := 0;                     { the initial seeding is not a respawn }

  StartTick := Ticks;
  LastTick  := StartTick;

  { One pass per BIOS tick, 18.2 Hz. Each column then advances only when its
    own counter fires, which is what gives the drops different speeds. }
  while (Ticks - StartTick) < RunTicks do
  begin
    if KeyWaiting then
    begin
      FlushKey;
      Interrupted := True;
      Break;
    end;

    T := Ticks;
    if T <> LastTick then
    begin
      LastTick := T;
      for C := 0 to COLS - 1 do
      begin
        Dec(DropCnt[C]);
        if DropCnt[C] <= 0 then
        begin
          DropCnt[C] := DropSpd[C];
          StepColumn(C);
        end;
      end;
      Inc(Steps);
    end;
  end;

  Elapsed := Ticks - StartTick;

  ShowCursor;
  SetMode(OldMode);

  WriteLn('=== matrix rain ===');
  WriteLn('  entry video mode   : ', OldMode);
  WriteLn('  ran in text mode   : ', TEXT_MODE, ' (', COLS, 'x', ROWS, ' at B800)');
  WriteLn('  requested seconds  : ', RunSecs);
  WriteLn('  update steps       : ', Steps);
  WriteLn('  column respawns    : ', Respawns);
  WriteLn('  cells written      : ', CellsWrit);
  if Interrupted then
    WriteLn('  ended by           : keypress')
  else
    WriteLn('  ended by           : time limit');
  WriteLn('  elapsed ticks      : ', Elapsed, ' (18.2/sec)');
  WriteLn('  video mode restored to ', GetMode);
end.
