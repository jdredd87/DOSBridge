program ansitest;
{ ANSITEST -- load a console driver into this program's own memory, run
  it on the real screen, and measure it.  StevenC & Claude, 2026.

    ANSITEST driver.sys [driver2.sys ...] [/T=ticks] [-H]

  -H loads each driver into upper memory, where DEVICEHIGH puts it.

  For each driver file: its INIT is called exactly as DOS calls it (with
  "ANSI.SYS" as the command line), then it is driven directly -- through
  INT 29h, which its INIT hooks, and through its WRITE request -- and
  finally every interrupt vector it touched is put back.  The driver is
  never linked into DOS's device chain, so DOS's real console is not
  changed, and nothing outlives the program.

  Two things per driver:

    CHECK  a fixed script -- text, colours, cursor moves, erasing, wrapping,
           forty lines of scrolling, both output paths -- then a CRC-32 of
           the screen (characters and attributes) and the cursor.  Two
           drivers that behave alike print the same CRC.
    SPEED  characters per second: 80-character lines through INT 29h and
           through the WRITE request, both scrolling; the same without
           scrolling; and escape sequences.

  The screen is left cleared.  Exit code 0; 1 if a file cannot be loaded
  or a driver fails its INIT. }

{$MODE OBJFPC}{$H-}

uses About;

const
  VER = '1.0.0';

type
  TReq = packed record
    len, unitno, cmd: Byte;
    status: Word;
    res: array[0..7] of Byte;
    units: Byte;
    brkoff, brkseg: Word;
    cmdoff, cmdseg: Word;          { INIT: command line; WRITE: count, start }
    drive: Byte;
    msgflag: Word;
  end;

var
  Req: TReq;
  DrvSeg: Word;
  Strat, Intr: LongInt;            { far pointers, offset:segment }
  CmdLine: array[0..31] of Char;
  Saved: array[0..255] of LongInt;
  Buf: array[0..2047] of Char;
  Line: array[0..81] of Char;
  TK: Word;
  CrcTab: array[0..255] of LongWord;

function Ticks: Word;
begin Ticks := MemW[$40:$6C]; end;

procedure InitCrc;
var i, j: Integer; c: LongWord;
begin
  for i := 0 to 255 do begin
    c := i;
    for j := 1 to 8 do
      if (c and 1) <> 0 then c := (c shr 1) xor $EDB88320 else c := c shr 1;
    CrcTab[i] := c;
  end;
end;

function Hex(v: LongWord; d: Integer): string;
const H: string[16] = '0123456789ABCDEF';
var s: string;
begin
  s := '';
  while d > 0 do begin s := H[(v and 15) + 1] + s; v := v shr 4; Dec(d); end;
  Hex := s;
end;

procedure CallDriver;
var rs, ro: Word;
begin
  rs := Seg(Req); ro := Ofs(Req);
  asm
    push bp
    push ds
    push es
    mov  ax, rs
    mov  es, ax
    mov  bx, ro
    push ax
    push bx
    call dword ptr Strat
    pop  bx
    pop  ax
    mov  es, ax
    call dword ptr Intr
    pop  es
    pop  ds
    pop  bp
  end;
end;

procedure SaveVectors;
var i: Integer;
begin
  for i := 0 to 255 do Saved[i] := MemL[0:i * 4];
end;

procedure RestoreVectors;
var i: Integer;
begin
  asm cli end;
  for i := 0 to 255 do MemL[0:i * 4] := Saved[i];
  asm sti end;
end;

var
  High: Boolean;

{ A block of upper memory from DOS: link the UMBs, ask for high memory
  first, allocate, and put both settings back.  0 if there is none. }
function UmbAlloc(paras: Word): Word;
var r, oldstrat, oldlink: Word;
begin
  asm
    mov  ax, 5800h
    int  21h
    mov  oldstrat, ax
    mov  ax, 5802h
    int  21h
    xor  ah, ah
    mov  oldlink, ax
    mov  ax, 5803h
    mov  bx, 1
    int  21h
    mov  ax, 5801h
    mov  bx, 80h
    int  21h
    mov  ah, 48h
    mov  bx, paras
    int  21h
    jnc  @ok
    xor  ax, ax
  @ok:
    mov  r, ax
    mov  ax, 5801h
    mov  bx, oldstrat
    int  21h
    mov  ax, 5803h
    mov  bx, oldlink
    int  21h
  end;
  if r < $A000 then r := 0;       { it came from conventional memory }
  UmbAlloc := r;
end;

function LoadDriver(const name: string): Boolean;
var f: file; size: LongInt; p: Pointer; n: Word;
begin
  LoadDriver := False;
  Assign(f, name);
  {$I-} Reset(f, 1); {$I+}
  if IOResult <> 0 then begin WriteLn('  cannot open ', name); Exit; end;
  size := FileSize(f);
  if size > 40000 then begin WriteLn('  too big'); Close(f); Exit; end;
  if High then begin
    DrvSeg := UmbAlloc((size + 15) shr 4);
    if DrvSeg = 0 then begin WriteLn('  no upper memory block free'); Close(f); Exit; end;
    WriteLn('  loaded high, at ', Hex(DrvSeg, 4), 'h');
  end else begin
    GetMem(p, size + 16);
    DrvSeg := Seg(p^) + (Ofs(p^) + 15) shr 4;
  end;
  BlockRead(f, Mem[DrvSeg:0], size, n);
  Close(f);
  MemL[DrvSeg:0] := LongInt($FFFFFFFF);             { no next device }
  Strat := LongInt(DrvSeg) shl 16 + MemW[DrvSeg:6];
  Intr := LongInt(DrvSeg) shl 16 + MemW[DrvSeg:8];
  { INIT, as DOS does it }
  FillChar(Req, SizeOf(Req), 0);
  Req.len := SizeOf(Req); Req.cmd := 0;
  CmdLine := 'ANSI.SYS'#13#10;
  Req.cmdoff := Ofs(CmdLine); Req.cmdseg := Seg(CmdLine);
  CallDriver;
  WriteLn('  init status ', Hex(Req.status, 4), ', resident ',
          LongInt(Req.brkseg - DrvSeg) * 16 + Req.brkoff, ' bytes');
  LoadDriver := (Req.status and $8000) = 0;
end;

procedure DrvWrite(p: Pointer; n: Word);
begin
  FillChar(Req, SizeOf(Req), 0);
  Req.len := SizeOf(Req); Req.cmd := 8;
  Req.brkoff := Ofs(p^); Req.brkseg := Seg(p^);     { transfer address at +14 }
  Req.cmdoff := n;                                    { count at +18 }
  CallDriver;
end;

procedure Out29(const s: string);
var i: Integer; c: Char;
begin
  for i := 1 to Length(s) do begin
    c := s[i];
    asm
      mov  al, c
      int  29h
    end;
  end;
end;

procedure OutReq(const s: string);
begin
  Move(s[1], Buf, Length(s));
  DrvWrite(@Buf, Length(s));
end;

{ ---- CHECK }

function ScreenCrc: LongWord;
var c: LongWord; vseg, n, i, cols, rows: Word; b: Byte; pg: Byte;
begin
  if Mem[$40:$49] = 7 then vseg := $B000 else vseg := $B800;
  cols := MemW[$40:$4A];
  rows := Mem[$40:$84] + 1;
  if rows = 1 then rows := 25;
  n := cols * rows * 2;
  c := $FFFFFFFF;
  for i := 0 to n - 1 do begin
    b := Mem[vseg:MemW[$40:$4E] + i];
    c := CrcTab[(c xor b) and $FF] xor (c shr 8);
  end;
  pg := Mem[$40:$62];
  for i := 0 to 1 do begin
    b := Mem[$40:$50 + pg * 2 + i];
    c := CrcTab[(c xor b) and $FF] xor (c shr 8);
  end;
  ScreenCrc := not c;
end;

procedure Script(useReq: Boolean);
var i: Integer; s: string;
  procedure O(const t: string);
  begin if useReq then OutReq(t) else Out29(t); end;
begin
  O(#27'[0m'#27'[2J');
  O('ANSITEST script'#13#10);
  O(#27'[1;33;44m bright yellow on blue '#27'[0m plain '#27'[7m inverse '#27'[0m'#13#10);
  O(#27'[10;20HAt 10,20'#27'[5Aup'#27'[3Bdown'#27'[10Cright'#27'[20Dleft');
  O(#27'[s'#27'[20;1Hsaved and moved'#27'[uback');
  O(#27'[12;1H'#27'[32mgreen line to erase'#27'[12;6H'#27'[K'#27'[0m');
  for i := 1 to 40 do begin
    Str(i, s);
    O(#27'[3' + Char(Ord('0') + i mod 8) + 'mscroll line ' + s + ' ' + Copy('ABCDEFGHIJKLMNOPQRSTUVWXYZ', 1, i mod 27) + #13#10);
  end;
  O(#27'[0m');
  for i := 1 to 3 do O('wrap-wrap-wrap-wrap-wrap-wrap-wrap-wrap-wrap-wrap-wrap-wrap-wrap-wrap-wrap-wrap-wrap-wrap-');
  O(#8#8#8'BS'#9'TAB'#13'CR');
  O(#27'[25;80HX'#27'[99BY'#27'[1;1H');
end;

{ ---- SPEED }

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

function S29: LongInt;
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
  S29 := 80;
end;

function S29NoScroll: LongInt;
begin
  Out29(#27'[1;1H');
  asm
    mov  dx, 20
  @r:
    mov  si, offset Line
    mov  cx, 80
  @l:
    lodsb
    push cx
    push si
    push dx
    int  29h
    pop  dx
    pop  si
    pop  cx
    loop @l
    dec  dx
    jnz  @r
  end;
  S29NoScroll := 6 + 1600;
end;

function SReq: LongInt;
begin
  DrvWrite(@Buf, 1600);
  SReq := 1600;
end;

var
  EscLen: Word;

function SEsc: LongInt;
begin
  DrvWrite(@Buf[1700], EscLen);
  SEsc := EscLen;
end;

procedure SetupSpeed;
var i, j, row: Integer; s: string; n: Word;
begin
  for i := 0 to 77 do Line[i] := Char(33 + (i mod 90));
  Line[78] := #13; Line[79] := #10;
  n := 0;
  for j := 1 to 20 do
    for i := 0 to 79 do begin Buf[n] := Line[i]; Inc(n); end;
  EscLen := 0;
  for row := 1 to 10 do begin
    Str(row + 2, s);
    s := #27'[' + s + ';5H'#27'[1;3' + Char(Ord('0') + row mod 8) + 'mANSI line'#27'[0m';
    for i := 1 to Length(s) do
      if EscLen < 340 then begin Buf[1700 + EscLen] := s[i]; Inc(EscLen); end;
  end;
end;

procedure TestDriver(const name: string);
var c1, c2: LongWord; r: array[1..5] of LongInt; i: Integer;
begin
  WriteLn(name, ':');
  SaveVectors;
  if not LoadDriver(name) then begin RestoreVectors; Halt(1); end;
  Script(False); c1 := ScreenCrc;
  Script(True);  c2 := ScreenCrc;
  WriteLn('  check: INT 29h script crc ', Hex(c1, 8), ', WRITE script crc ', Hex(c2, 8));
  SetupSpeed;
  OutReq(#27'[2J');
  r[1] := Rate(@S29);
  r[2] := Rate(@SReq);
  r[3] := Rate(@S29NoScroll);
  r[4] := Rate(@SEsc);
  OutReq(#27'[0m'#27'[2J');
  RestoreVectors;
  WriteLn('  speed, characters per second:');
  WriteLn('    INT 29h, 80-char lines, scrolling     ', r[1]:8);
  WriteLn('    WRITE request, 1600 bytes, scrolling  ', r[2]:8);
  WriteLn('    INT 29h, 20 lines, no scrolling       ', r[3]:8);
  WriteLn('    escape sequences, WRITE request       ', r[4]:8);
end;

var
  i, code: Integer; s: string;
begin
  WriteLn('ANSITEST ', VER, ' -- console drivers on the real screen');
  InitCrc;
  TK := 36;
  High := False;
  for i := 1 to ParamCount do begin
    s := ParamStr(i);
    if (s = '/H') or (s = '/h') or (s = '-h') or (s = '-H') then High := True;
    if (Length(s) > 3) and ((s[2] = 'T') or (s[2] = 't')) and (s[3] = '=') then
      Val(Copy(s, 4, 10), TK, code);
  end;
  WriteLn('video mode ', Mem[$40:$49], ', ', MemW[$40:$4A], ' columns, ', TK, ' ticks per speed test');
  for i := 1 to ParamCount do begin
    s := ParamStr(i);
    if (s[1] <> '/') and (s[1] <> '-') then TestDriver(s);
  end;
end.
