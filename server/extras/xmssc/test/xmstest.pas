program XmsTest;
{ XMSSC  --  StevenC & Claude.  Public domain (the Unlicense). }
{ xmstest.pas -- the XMS driver that is loaded, on the real machine: does
  it behave, and how fast is it?

    XMSTEST          behaviour, then the benchmark
    XMSTEST /B       the benchmark only
    XMSTEST /T       the behaviour test only

  Behaviour: version, free memory, blocks of awkward sizes, moves of every
  shape checked by reading them back (conventional <-> block, block <->
  block, overlapping both ways, odd offsets, across 16 KB pages, through
  the EMS page frame), reallocation keeping contents, the error codes --
  and after every call, the EMS page registers and the EMS driver's page
  map exactly as they were.  The lines go into a transcript whose CRC is
  printed, so two drivers (or two builds) can be compared at a glance.

  Benchmark: moves per second at the sizes programs use, both directions,
  with the EMS driver's own move (INT 67h 57h) alongside for comparison.

  Exit 0 if every check passed, 1 if any failed, 2 if no XMS driver. }

{$MODE OBJFPC}{$H-}
{$ASMMODE INTEL}

uses About;

type
  TBuf = array[0 .. 32767] of Byte;
  TXMove = packed record
    Len: LongInt;
    SH: Word; SO: LongInt;
    DH: Word; DO_: LongInt;
  end;
  TEMove = packed record
    Len: LongInt;
    SType: Byte; SHandle, SOff, SSeg: Word;
    DType: Byte; DHandle, DOff, DSeg: Word;
  end;

var
  XmsEntry: Pointer;
  XAX, XBX, XDX: Word;
  MV: TXMove;
  EM: TEMove;
  A, B: ^TBuf;
  Fails: Integer;
  Crc: LongInt;
  Port, Frame: Word;
  HavePort: Boolean;
  Regs0: array[0 .. 3] of Byte;
  Map0, Map1: array[0 .. 63] of Byte;
  MapSz: Word;
  DoTest, DoBench: Boolean;

{ ---------------------------------------------------------------- output }
function Hex(W: LongInt; N: Integer): ShortString;
const D: array[0 .. 15] of Char = '0123456789ABCDEF';
var S: ShortString; K: Integer;
begin
  S := '';
  for K := 1 to N do begin S := D[W and 15] + S; W := W shr 4; end;
  Hex := S;
end;

function Str(L: LongInt): ShortString;
var S: ShortString;
begin
  System.Str(L, S);
  Str := S;
end;

function Pad(const S: ShortString): ShortString;
var R: ShortString;
begin
  R := S;
  while Length(R) < 14 do R := R + ' ';
  Pad := R;
end;

procedure CrcAdd(const S: ShortString);
var I, J: Integer; C: LongInt;
begin
  C := Crc;
  for I := 1 to Length(S) + 1 do
  begin
    if I <= Length(S) then C := C xor Ord(S[I]) else C := C xor 10;
    for J := 1 to 8 do
      if (C and 1) <> 0 then C := (C shr 1) xor LongInt($EDB88320) else C := C shr 1;
  end;
  Crc := C;
end;

procedure T(const S: ShortString);
begin
  WriteLn(S);
  CrcAdd(S);
end;

procedure Must(Ok: Boolean; const What: ShortString);
begin
  if not Ok then
  begin
    Inc(Fails);
    WriteLn('  ** FAILED: ', What);
  end;
end;

{ progress on the screen, not in the captured output }
procedure Step(const S: ShortString);
begin
  WriteLn(StdErr, 'xmstest: ', S);
end;

{ ---------------------------------------------------------------- calls }
procedure XmsCall; assembler;
asm
  push si
  push di
  mov ax, XAX
  mov bx, XBX
  mov dx, XDX
  mov si, offset MV
  call dword ptr [XmsEntry]
  mov XAX, ax
  mov XBX, bx
  mov XDX, dx
  pop di
  pop si
end;

function X(AX, BX, DX: Word): Boolean;
begin
  XAX := AX; XBX := BX; XDX := DX;
  XmsCall;
  X := XAX = 1;
end;

function Err: ShortString;
begin
  Err := 'AX=' + Str(XAX) + ' BL=' + Hex(Lo(XBX), 2);
end;

function Move(Len: LongInt; SH: Word; SO: LongInt; DH: Word; DO_: LongInt): Boolean;
begin
  MV.Len := Len; MV.SH := SH; MV.SO := SO; MV.DH := DH; MV.DO_ := DO_;
  Move := X($0B00, 0, 0);
end;

function Conv(P: Pointer): LongInt;
begin
  Conv := LongInt(Seg(P^)) shl 16 or Ofs(P^);
end;

var RAX: Word;
procedure Ems57; assembler;
asm
  push si
  mov ax, 5700h
  mov si, offset EM
  int 67h
  mov RAX, ax
  pop si
end;

procedure EmsMap(Fn: Word; P: Pointer); assembler;
asm
  push ds
  push si
  push di
  mov ax, Fn
  les di, P
  push es
  pop ds
  mov si, di
  int 67h
  pop di
  pop si
  pop ds
  mov RAX, ax
end;

function InB(P: Word): Byte; assembler;
asm
  mov dx, P
  in  al, dx
end;

{ the EMS state: page registers and the driver's own map }
procedure Snap;
var I: Integer;
begin
  if HavePort then for I := 0 to 3 do Regs0[I] := InB(Port + I);
  EmsMap($4E00, @Map0);
end;

procedure SameState(const What: ShortString);
var I: Integer; Ok: Boolean;
begin
  Ok := True;
  if HavePort then for I := 0 to 3 do if InB(Port + I) <> Regs0[I] then Ok := False;
  EmsMap($4E00, @Map1);
  for I := 0 to MapSz - 1 do if Map0[I] <> Map1[I] then Ok := False;
  Must(Ok, What + ': the EMS page map changed');
end;

{ ---------------------------------------------------------------- data }
procedure Fill(var P: TBuf; N: Word; Seed: LongInt);
var I: Word;
begin
  for I := 0 to N - 1 do
  begin
    Seed := Seed * 1103515245 + 12345;
    P[I] := Byte(Seed shr 16);
  end;
end;

function Same(var P, Q; N: Word): Boolean;
var I: Word; X: ^TBuf; Y: ^TBuf;
begin
  X := @P; Y := @Q;
  Same := True;
  for I := 0 to N - 1 do if X^[I] <> Y^[I] then begin Same := False; Exit; end;
end;

{ ================================================================ tests }
var H: array[0 .. 7] of Word;

procedure Behaviour;
var
  Ok: Boolean;
  I: Integer;
  Free0, N: Word;
  O: LongInt;
  EH, Save: Word;
begin
  Step('behaviour');
  X($0000, 0, 0);
  T('00 version ' + Hex(XAX, 4) + ' revision ' + Hex(XBX, 4) + ' HMA ' + Str(XDX));
  X($0100, 0, $FFFF); T('01 request HMA ' + Err);
  X($0700, 0, 0); T('07 query A20 AX=' + Str(XAX));
  X($0800, 0, 0); Free0 := XAX;
  T('08 free ' + Str(XAX) + ' KB, total ' + Str(XDX) + ' KB');
  Must(XAX > 256, 'at least 256 KB free');

  { blocks }
  Snap;
  Ok := X($0900, 0, 0); H[0] := XDX; T('09 alloc 0 KB ' + Err);
  Ok := X($0900, 0, 1) and Ok; H[1] := XDX;
  Ok := X($0900, 0, 17) and Ok; H[2] := XDX;
  Ok := X($0900, 0, 64) and Ok; H[3] := XDX;
  Ok := X($0900, 0, 200) and Ok; H[4] := XDX;
  Must(Ok, 'allocating 0, 1, 17, 64 and 200 KB');
  SameState('allocating');
  X($0E00, 0, H[3]);
  T('0E 64 KB block: size ' + Str(XDX) + ' locks ' + Str(Hi(XBX)) + ' free handles ' + Str(Lo(XBX)));
  Must(XDX = 64, '0E size');
  X($0800, 0, 0);
  T('08 after 282 KB of blocks: ' + Str(XAX) + ' KB free');
  Must(XAX = Free0 - 16 * (1 + 2 + 4 + 13), 'free memory down by whole 16 KB pages');

  { conventional <-> block, every shape }
  Step('moves');
  Ok := True;
  N := 0;
  for I := 0 to 11 do
  begin
    case I of
      0: begin O := 0; N := 2; end;
      1: begin O := 0; N := 512; end;
      2: begin O := 1; N := 1024; end;
      3: begin O := 16383; N := 16386; end;
      4: begin O := 16383; N := 32000; end;
      5: begin O := 8192; N := 16384; end;
      6: begin O := 65535; N := 20000; end;
      7: begin O := 100; N := 32768; end;
      8: begin O := 131071; N := 30002; end;
      9: begin O := 200 * 1024 - 32768; N := 32768; end;
      10: begin O := 3; N := 6; end;
      11: begin O := 49151; N := 2; end;
    end;
    Snap;
    Fill(A^, N, I);
    FillChar(B^, N + 2, $EE);
    if not Move(N, 0, Conv(A), H[4], O) then begin Ok := False; T('c->e ' + Str(N) + ' ' + Err); end;
    if not Move(N, H[4], O, 0, Conv(B)) then begin Ok := False; T('e->c ' + Str(N) + ' ' + Err); end;
    if not Same(A^, B^, N) or (B^[N] <> $EE) or (B^[N + 1] <> $EE) then
    begin
      Ok := False;
      T('round trip of ' + Str(N) + ' at ' + Str(O) + ' came back wrong');
    end;
    SameState('move ' + Str(N));
  end;
  T('conventional <-> block, 12 shapes: ' + Str(Ord(Ok)));
  Must(Ok, 'conventional <-> block');

  { odd conventional addresses: source odd, destination odd, both }
  Ok := True;
  for I := 0 to 3 do
  begin
    Fill(A^, 20000, 100 + I);
    Move(18000, 0, Conv(@A^[I and 1]), H[4], 7);
    Move(18000, H[4], 7, 0, Conv(@B^[I shr 1]));
    if not Same(A^[I and 1], B^[I shr 1], 18000) then Ok := False;
  end;
  T('odd conventional addresses: ' + Str(Ord(Ok)));
  Must(Ok, 'odd conventional addresses');

  { block <-> block, and within one block, overlapping both ways }
  Ok := True;
  Fill(A^, 30000, 7);
  Move(30000, 0, Conv(A), H[4], 1000);
  Move(30000, H[4], 1000, H[3], 5);                   { between blocks }
  Move(30000, H[3], 5, 0, Conv(B));
  if not Same(A^, B^, 30000) then Ok := False;
  Move(30000, H[4], 1000, H[4], 1002);                { overlap, upwards }
  Move(30000, H[4], 1002, 0, Conv(B));
  if not Same(A^, B^, 30000) then Ok := False;
  Move(30000, H[4], 1002, H[4], 999);                 { overlap, downwards }
  Move(30000, H[4], 999, 0, Conv(B));
  if not Same(A^, B^, 30000) then Ok := False;
  Move(20000, H[4], 999, H[4], 17383);                { across pages }
  Move(20000, H[4], 17383, 0, Conv(B));
  if not Same(A^, B^, 20000) then Ok := False;
  T('block <-> block and overlapping: ' + Str(Ord(Ok)));
  Must(Ok, 'block <-> block');

  { conventional overlapping (a memmove) }
  Fill(A^, 32000, 9);
  System.Move(A^, B^, 32000);
  Move(30000, 0, Conv(@A^[0]), 0, Conv(@A^[2]));
  Ok := Same(A^[2], B^[0], 30000);
  System.Move(B^, A^, 32000);
  Move(30000, 0, Conv(@A^[3]), 0, Conv(@A^[1]));
  Ok := Ok and Same(A^[1], B^[3], 30000);
  T('conventional overlapping: ' + Str(Ord(Ok)));
  Must(Ok, 'conventional overlapping');

  { through the page frame: a page of our own mapped there }
  Ok := True;
  RAX := 0;
  asm
    mov ah, 43h
    mov bx, 1
    int 67h
    mov RAX, ax
    mov EH, dx
  end;
  if Hi(RAX) = 0 then
  begin
    for I := 0 to 3 do
    begin
      asm
        mov ax, 4400h
        add ax, I
        xor bx, bx
        mov dx, EH
        int 67h
      end;
      Fill(A^, 16384, 50 + I);
      System.Move(A^, Ptr(Frame, I * $4000)^, 16384);
      Snap;
      if not Move(16384, 0, LongInt(Frame + I * $400) shl 16, H[4], 11) then Ok := False;
      Move(16384, H[4], 11, 0, Conv(B));
      if not Same(A^, B^, 16384) then Ok := False;
      Fill(A^, 8000, 60 + I);
      Move(8000, 0, Conv(A), H[4], 20000);
      Move(8000, H[4], 20000, 0, (LongInt(Frame + I * $400) shl 16) + 3000);
      if not Same(A^, Ptr(Frame, I * $4000 + 3000)^, 8000) then Ok := False;
      SameState('moves through window ' + Str(I));
      asm
        mov ax, 4400h
        add ax, I
        mov bx, 0FFFFh
        mov dx, EH
        int 67h
      end;
    end;
    asm
      mov ah, 45h
      mov dx, EH
      int 67h
    end;
  end;
  T('through the page frame: ' + Str(Ord(Ok)));
  Must(Ok, 'through the page frame');

  { reallocation keeps the contents }
  Ok := True;
  Fill(A^, 17 * 1024, 77);
  Move(17 * 1024, 0, Conv(A), H[2], 0);
  for I := 0 to 4 do
  begin
    case I of
      0: N := 100; 1: N := 33; 2: N := 17; 3: N := 300; 4: N := 20;
    end;
    Snap;
    if not X($0F00, N, H[2]) then begin Ok := False; T('0F to ' + Str(N) + ' ' + Err); end;
    SameState('reallocating');
    Move(17 * 1024, H[2], 0, 0, Conv(B));
    if not Same(A^, B^, 17 * 1024) then Ok := False;
  end;
  X($0E00, 0, H[2]);
  T('reallocate 17 -> 100 -> 33 -> 17 -> 300 -> 20 KB, contents kept: ' + Str(Ord(Ok)) + ', now ' + Str(XDX) + ' KB');
  Must(Ok and (XDX = 20), 'reallocation');

  { errors }
  Move(3, 0, Conv(A), H[4], 0); T('0B odd length ' + Err);
  Must(Lo(XBX) = $A7, 'odd length -> A7h');
  Move(2, $1234, 0, H[4], 0); T('0B bad source handle ' + Err);
  Must(Lo(XBX) = $A3, 'bad source -> A3h');
  Move(2, H[1], 1025, 0, Conv(A)); T('0B source offset past the end ' + Err);
  Must(Lo(XBX) = $A4, 'source offset -> A4h');
  Move(4, 0, Conv(A), H[1], 1022); T('0B runs past the end ' + Err);
  Must(Lo(XBX) = $A7, 'past the end -> A7h');
  Move(2, 0, Conv(A), $0001, 0); T('0B bad destination handle ' + Err);
  Must(Lo(XBX) = $A5, 'bad destination -> A5h');
  X($0C00, 0, H[1]); T('0C lock ' + Err);
  X($0A00, 0, $1234); T('0A free a bad handle ' + Err);
  Must(Lo(XBX) = $A2, 'bad handle -> A2h');
  X($0900, 0, 65535); T('09 alloc 65535 KB ' + Err);
  Must(Lo(XBX) = $A0, 'too big -> A0h');

  { give it all back }
  Ok := True;
  for I := 0 to 4 do if not X($0A00, 0, H[I]) then Ok := False;
  X($0800, 0, 0);
  T('freed everything: ' + Str(Ord(Ok)) + ', ' + Str(XAX) + ' KB free');
  Must(Ok and (XAX = Free0), 'everything given back');
end;

{ ================================================================ speed }
type TBody = procedure;
var BH: Word; BN: Word; BO: LongInt; BP_: Pointer;

procedure BCE; begin MV.Len := BN; MV.SH := 0; MV.SO := Conv(BP_); MV.DH := BH; MV.DO_ := BO; XAX := $0B00; XmsCall; end;
procedure BEC; begin MV.Len := BN; MV.SH := BH; MV.SO := BO; MV.DH := 0; MV.DO_ := Conv(BP_); XAX := $0B00; XmsCall; end;
procedure BEE; begin MV.Len := BN; MV.SH := BH; MV.SO := 0; MV.DH := BH; MV.DO_ := 65536; XAX := $0B00; XmsCall; end;
procedure BCC; begin MV.Len := BN; MV.SH := 0; MV.SO := Conv(A); MV.DH := 0; MV.DO_ := Conv(B); XAX := $0B00; XmsCall; end;
procedure B57; begin Ems57; end;
procedure BNUL; begin XAX := $0000; XmsCall; end;
procedure BAF; begin XAX := $0900; XDX := 16; XmsCall; XAX := $0A00; XmsCall; end;

procedure Rate(const Name: ShortString; Body: TBody; Bytes: LongInt);
var T0, T1, N: LongInt; R: LongInt;
begin
  Step(Name);
  T0 := MemL[$40 : $6C];
  repeat T1 := MemL[$40 : $6C] until T1 <> T0;
  N := 0;
  repeat
    Body;
    Inc(N);
    T0 := MemL[$40 : $6C];
  until T0 - T1 >= 36;
  R := Round(N * 18.2065 / (T0 - T1));
  if Bytes > 0 then
    WriteLn(Name, R: 7, ' /s', Round(R * Bytes / 1024.0): 7, ' KB/s')
  else
    WriteLn(Name, R: 7, ' /s');
end;

procedure Bench;
var I: Integer; EH: Word;
const Sizes: array[0 .. 4] of Word = (512, 1024, 4096, 16384, 32768);
begin
  WriteLn;
  WriteLn('benchmark: calls a second, 2 s each');
  if not X($0900, 0, 256) then begin WriteLn('cannot allocate 256 KB'); Exit; end;
  BH := XDX;
  BP_ := A;
  for I := 0 to 4 do
  begin
    BN := Sizes[I]; BO := 0;
    Rate('  conv -> XMS ' + Pad(Str(BN)), @BCE, BN);
    Rate('  XMS -> conv ' + Pad(Str(BN)), @BEC, BN);
  end;
  BN := 16384;
  BP_ := @A^[1]; BO := 1;
  Rate('  conv -> XMS 16384, both odd' , @BCE, BN);
  BP_ := @A^[1]; BO := 0;
  Rate('  conv -> XMS 16384, conv odd' , @BCE, BN);
  BP_ := A; BO := 1;
  Rate('  conv -> XMS 16384, XMS odd ' , @BCE, BN);
  BP_ := A; BO := 16384 - 256;
  Rate('  conv -> XMS 16384, 2 pages ' , @BCE, BN);
  BN := 16384; Rate('  XMS -> XMS 16384          ', @BEE, BN);
  BN := 16384; Rate('  conv -> conv 16384        ', @BCC, BN);
  Rate('  alloc + free 16 KB        ', @BAF, 0);
  Rate('  00h, the call alone       ', @BNUL, 0);
  X($0A00, 0, BH);

  { the EMS driver's own move, for comparison }
  asm
    mov ah, 43h
    mov bx, 16
    int 67h
    mov RAX, ax
    mov EH, dx
  end;
  if Hi(RAX) = 0 then
  begin
    for I := 0 to 4 do
    begin
      EM.Len := Sizes[I]; EM.SType := 0; EM.SHandle := 0; EM.SOff := Ofs(A^); EM.SSeg := Seg(A^);
      EM.DType := 1; EM.DHandle := EH; EM.DOff := 0; EM.DSeg := 0;
      Rate('  EMS 57h c->e ' + Pad(Str(EM.Len)), @B57, EM.Len);
      if Hi(RAX) <> 0 then WriteLn('    (57h answered AH=', Hex(Hi(RAX), 2), ': not a real rate)');
    end;
    asm
      mov ah, 45h
      mov dx, EH
      int 67h
    end;
  end;
end;

var S: ShortString; I: Integer;
begin
  Fails := 0;
  Crc := LongInt($FFFFFFFF);
  DoTest := True; DoBench := True;
  for I := 1 to ParamCount do
  begin
    S := ParamStr(I);
    if (S = '/B') or (S = '/b') then DoTest := False;
    if (S = '/T') or (S = '/t') then DoBench := False;
  end;
  WriteLn('XMSTEST 1.0 -- XMS behaviour and speed -- StevenC & Claude');
  asm
    mov ax, 4300h
    int 2Fh
    mov byte ptr RAX, al
  end;
  if Lo(RAX) <> $80 then begin WriteLn('no XMS driver'); Halt(2); end;
  asm
    push es
    mov ax, 4310h
    int 2Fh
    mov word ptr [XmsEntry], bx
    mov word ptr [XmsEntry + 2], es
    pop es
  end;
  WriteLn('XMS entry ', Hex(Seg(XmsEntry^), 4), ':', Hex(Ofs(XmsEntry^), 4));

  { the page frame, and the PicoMEM's page registers if there is one }
  asm
    mov ah, 41h
    int 67h
    mov Frame, bx
    mov ax, 4E03h
    int 67h
    xor ah, ah
    mov MapSz, ax
  end;
  HavePort := False;
  asm
    mov ax, 6000h
    mov dx, 1234h
    pushf
    int 13h
    popf
    cmp dx, 0AA55h
    jne @@no
    mov ax, 6001h
    mov dx, 1234h
    pushf
    int 13h
    popf
    mov Port, cx
    mov HavePort, 1
  @@no:
  end;
  if HavePort then WriteLn('PicoMEM page registers at ', Hex(Port, 3), 'h: checked after every call');
  New(A); New(B);

  if DoTest then
  begin
    Behaviour;
    WriteLn('--- ', Fails, ' checks failed, transcript crc ', Hex(Crc xor LongInt($FFFFFFFF), 8), ' ---');
  end;
  if DoBench then Bench;
  if Fails > 0 then Halt(1);
end.
