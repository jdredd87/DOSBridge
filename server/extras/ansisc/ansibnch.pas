program ansibnch;
{ ANSIBNCH -- how fast does the console driver put text on the screen?
  DOS Bridge tools, StevenC & Claude.

    ANSIBNCH [ticks]         default 36 ticks (two seconds) per test

  Every test writes to the SCREEN, not to standard output: a job's stdout
  is redirected to a file, and a redirected write never reaches the
  console driver.  So the text goes to a handle opened on the device CON
  (the path DOS takes for TYPE, DIR and ECHO), through DOS function 02h
  (a character at a time), and through INT 29h, which is what DOS calls
  underneath for a console with the fast-output bit.  Two references are
  measured the same way and do not involve the driver at all: the video
  BIOS teletype (INT 10h AH=0Eh), and writing straight into video memory.

  The screen is left cleared, with the attribute reset, at the end.  The
  results are printed on standard output, so they come back to the job.

  Exit code 0. }

{$MODE OBJFPC}{$H-}

uses About;

const
  VER = '1.0.0';

var
  TK: Word;
  ConH: Word;
  Line: array[0..81] of Char;       { 78 characters, CR, LF }
  Esc: array[0..511] of Char;      { ~270 bytes are built into it }
  EscLen: Word;
  Buf: array[0..2047] of Char;
  BufLen: Word;

function Ticks: Word;
begin Ticks := MemW[$40:$6C]; end;

procedure ConWrite(p: Pointer; n: Word);
var h, s, o: Word;
begin
  h := ConH; s := Seg(p^); o := Ofs(p^);
  asm
    push ds
    mov  bx, h
    mov  cx, n
    mov  dx, o
    mov  ax, s
    mov  ds, ax
    mov  ah, 40h
    int  21h
    pop  ds
  end;
end;

procedure ConStr(const s: string);
begin ConWrite(@s[1], Length(s)); end;

{ Run 'body' until TK ticks pass; return units per second. }
type TBody = function: LongInt;

function Rate(b: TBody): LongInt;
var t0, t: Word; n: LongInt;
begin
  n := 0;
  t0 := Ticks;
  repeat t := Ticks until t <> t0;
  t0 := t;
  repeat
    Inc(n, b());
    t := Ticks;
  until Word(t - t0) >= TK;
  Rate := n * 182 div (LongInt(Word(t - t0)) * 10);
end;

{ ---- the tests: each returns the number of characters it sent }

function TLines: LongInt;       { 20 full lines through a CON handle: scrolls }
var i: Integer;
begin
  for i := 1 to 20 do ConWrite(@Line, 80);
  TLines := 20 * 80;
end;

function TBlock: LongInt;       { one 1600-byte write through a CON handle }
begin
  ConWrite(@Buf, BufLen);
  TBlock := BufLen;
end;

function TNoScroll: LongInt;    { home the cursor, then 20 lines: no scroll }
var i: Integer;
begin
  ConStr(#27'[H');
  for i := 1 to 20 do ConWrite(@Line, 80);
  TNoScroll := 3 + 20 * 80;
end;

function TFn02: LongInt;        { DOS function 02h, a character at a time }
begin
  asm
    mov  si, offset Line
    mov  cx, 80
  @l:
    lodsb
    mov  dl, al
    mov  ah, 2
    push cx
    push si
    int  21h
    pop  si
    pop  cx
    loop @l
  end;
  TFn02 := 80;
end;

function TInt29: LongInt;       { INT 29h, the driver's fast output entry }
begin
  asm
    mov  si, offset Line
    mov  cx, 80
  @l:
    lodsb
    push cx
    push si
    int  29h
    pop  si
    pop  cx
    loop @l
  end;
  TInt29 := 80;
end;

function TEsc: LongInt;         { cursor positioning and colour sequences }
begin
  ConWrite(@Esc, EscLen);
  TEsc := EscLen;
end;

function TBios: LongInt;        { reference: video BIOS teletype, no driver }
begin
  asm
    mov  si, offset Line
    mov  cx, 80
  @l:
    lodsb
    push cx
    push si
    mov  ah, 0Eh
    mov  bx, 0007h
    int  10h
    pop  si
    pop  cx
    loop @l
  end;
  TBios := 80;
end;

var
  VSeg: Word;

function TDirect: LongInt;      { reference: straight into video memory }
var s: Word;
begin
  s := VSeg;
  asm
    push es
    mov  es, s
    xor  di, di
    mov  si, offset Line
    mov  cx, 1600
    mov  ah, 07h
  @l:
    mov  bx, cx
    and  bx, 63
    mov  al, byte ptr Line[bx]
    stosw
    loop @l
    pop  es
  end;
  TDirect := 1600;
end;

procedure Setup;
var i, j: Integer; s: string; row: Integer;
begin
  for i := 0 to 77 do Line[i] := Char(33 + (i mod 90));
  Line[78] := #13; Line[79] := #10;
  BufLen := 0;
  for j := 1 to 20 do
    for i := 0 to 79 do begin Buf[BufLen] := Line[i]; Inc(BufLen); end;
  EscLen := 0;
  for row := 1 to 10 do begin
    Str(row + 2, s);
    s := #27'[' + s + ';5H'#27'[1;3' + Char(Ord('0') + row mod 8) + 'mANSI line'#27'[0m';
    for i := 1 to Length(s) do
      if EscLen <= High(Esc) then begin Esc[EscLen] := s[i]; Inc(EscLen); end;
  end;
end;

procedure OpenCon;
const Name: array[0..3] of Char = 'CON'#0;
var h: Word; bad: Boolean;
begin
  asm
    mov  dx, offset Name
    mov  ax, 3D01h
    int  21h
    mov  h, ax
    sbb  al, al
    mov  bad, al
  end;
  if bad then begin WriteLn('cannot open CON'); Halt(1); end;
  ConH := h;
end;

var
  code: Integer; r: LongInt; only: Integer;

function Want(n: Integer): Boolean;
begin Want := (only = 0) or (only = n); end;

begin
  WriteLn('ANSIBNCH ', VER, ' -- console output speed');
  TK := 36; only := 0;
  if ParamCount >= 1 then Val(ParamStr(1), TK, code);
  if ParamCount >= 2 then Val(ParamStr(2), only, code);
  if Mem[$40:$49] = 7 then VSeg := $B000 else VSeg := $B800;
  WriteLn('video mode ', Mem[$40:$49], ', ', Mem[$40:$4A], ' columns; ', TK, ' ticks per test');
  Setup;
  OpenCon;
  if Want(1) or Want(2) or Want(3) or Want(6) then ConStr(#27'[2J');

  WriteLn('characters per second:');
  if Want(1) then begin r := Rate(@TLines);    WriteLn('  1 CON handle, 80-char lines, scrolling  ', r:8); end;
  if Want(2) then begin r := Rate(@TBlock);    WriteLn('  2 CON handle, one 1600-byte write      ', r:8); end;
  if Want(3) then begin r := Rate(@TNoScroll); WriteLn('  3 CON handle, 20 lines, no scrolling   ', r:8); end;
  if Want(4) then begin r := Rate(@TFn02);     WriteLn('  4 DOS function 02h, char at a time     ', r:8); end;
  if Want(5) then begin r := Rate(@TInt29);    WriteLn('  5 INT 29h, char at a time              ', r:8); end;
  if Want(6) then begin r := Rate(@TEsc);      WriteLn('  6 escape sequences: position + colour  ', r:8); end;
  if Want(7) then begin r := Rate(@TBios);     WriteLn('  7 video BIOS teletype, INT 10h 0Eh     ', r:8); end;
  if Want(8) then begin r := Rate(@TDirect);   WriteLn('  8 straight into video memory           ', r:8); end;
  if Want(1) or Want(2) or Want(3) or Want(6) then ConStr(#27'[0m'#27'[2J');
end.
