program XProbe;
{ XMSSC  --  StevenC & Claude }
{ xprobe.pas -- before an XMS driver is written for the PicoMEM: does the
  card's EMS hardware do what the direct path will rely on, and how fast is
  the memory it would be copying?

    1. PicoMEM's own report (INT 13h 6000h/6001h): EMS port and page frame.
    2. The EMS driver: frame, pages, version, page map size.
    3. The page registers READ BACK: map a page through INT 67h, IN the
       port, and check that an OUT of that number to another window shows
       the same memory.  The page map is restored at the end, through EMS.
    4. The ceiling: REP MOVSW between conventional memory and the frame,
       16 KB and 1 KB, aligned and not; OUT and IN; EMS 44h and 57h for
       comparison; and an 8087 FILD/FISTP qword copy if one is fitted.

    XPROBE           exit 0 if the readback checks pass, 1 if not }

{$MODE OBJFPC}{$H-}
{$ASMMODE INTEL}

uses About, Cpu;

type
  TBuf = array[0 .. 16399] of Byte;
  TMove = packed record
    Len: LongInt;
    SType: Byte; SHandle, SOff, SSeg: Word;
    DType: Byte; DHandle, DOff, DSeg: Word;
  end;

var
  Port, Frame, EFrame, Pages, FreeP, Handle: Word;
  G: array[0 .. 3] of Byte;
  Old: array[0 .. 3] of Byte;
  V: Byte;
  MapBuf: array[0 .. 63] of Byte;
  A, B: ^TBuf;
  Bad: Integer;
  I: Integer;
  MV: TMove;
  Ok: Boolean;

function Hex(W: Word; N: Integer): ShortString;
const D: array[0 .. 15] of Char = '0123456789ABCDEF';
var S: ShortString; K: Integer;
begin
  S := '';
  for K := 1 to N do begin S := D[W and 15] + S; W := W shr 4; end;
  Hex := S;
end;

procedure Step(const S: ShortString);
begin
  WriteLn(StdErr, 'xprobe: ', S);
  Flush(Output);
end;

function Ticks: LongInt;
begin
  Ticks := MemL[$40 : $6C];
end;

{ ---------------------------------------------------------------- hardware }
procedure OutB(P: Word; B: Byte); assembler;
asm
  mov dx, P
  mov al, B
  out dx, al
end;

function InB(P: Word): Byte; assembler;
asm
  mov dx, P
  in  al, dx
end;

{ AX in, AX out; BX, DX in and out -- enough for the EMS calls used here }
var RAX, RBX, RDX, RCX: Word;
procedure Ems67; assembler;
asm
  mov ax, RAX
  mov bx, RBX
  mov dx, RDX
  mov cx, RCX
  int 67h
  mov RAX, ax
  mov RBX, bx
  mov RDX, dx
  mov RCX, cx
end;

function Ems(AX, BX, DX: Word): Byte;
begin
  RAX := AX; RBX := BX; RDX := DX; RCX := 0;
  Ems67;
  Ems := Hi(RAX);
end;

procedure EmsPtr(Fn: Word; P: Pointer; UseES: Boolean); assembler;
asm
  push ds
  push si
  push di
  mov ax, Fn
  mov bl, UseES
  les di, P
  test bl, bl
  jnz @@es
  push es
  pop ds
  mov si, di
@@es:
  int 67h
  pop di
  pop si
  pop ds
  mov RAX, ax
end;

{ ---------------------------------------------------------------- copying }
procedure MovW(Src, Dst: Pointer; Words: Word); assembler;
asm
  push ds
  push si
  push di
  lds si, Src
  les di, Dst
  mov cx, Words
  cld
  rep movsw
  pop di
  pop si
  pop ds
end;

procedure FpuMov(Src, Dst: Pointer; Quads: Word); assembler;
asm
  push ds
  push si
  push di
  lds si, Src
  les di, Dst
  mov cx, Quads
@@l:
  fild qword ptr [si]
  fistp qword ptr es:[di]
  add si, 8
  add di, 8
  loop @@l
  fwait
  pop di
  pop si
  pop ds
end;

procedure OutLoop(P: Word; B: Byte; N: Word); assembler;
asm
  mov dx, P
  mov al, B
  mov cx, N
@@l:
  out dx, al
  loop @@l
end;

procedure InLoop(P: Word; N: Word); assembler;
asm
  mov dx, P
  mov cx, N
@@l:
  in al, dx
  loop @@l
end;

{ run Body for about a second; report Bytes per call as KB/s, or calls/s }
type TBody = procedure;
var S, D: Pointer; W: Word;
procedure BMov; begin MovW(S, D, W); end;
procedure BFpu; begin FpuMov(S, D, W); end;
procedure BOut; begin OutLoop(Port + 1, G[0], 1000); end;
procedure BIn;  begin InLoop(Port + 1, 1000); end;
procedure B44;  begin RAX := $4401; RBX := 0; RDX := Handle; Ems67; end;
procedure B57;  begin EmsPtr($5700, @MV, False); end;

procedure Time(const Name: ShortString; Body: TBody; Bytes: LongInt);
var T0, T1, N: LongInt; R: LongInt;
begin
  Step(Name);
  T0 := Ticks;
  repeat T1 := Ticks until T1 <> T0;
  N := 0;
  repeat
    Body;
    Inc(N);
    T0 := Ticks;
  until T0 - T1 >= 18;
  { rate = N * 18.2065 / (T0-T1) }
  if Bytes > 0 then
  begin
    R := Round(N * Bytes * 18.2065 / (T0 - T1) / 1024);
    WriteLn(Name, R: 8, ' KB/s');
  end
  else
  begin
    R := Round(N * -Bytes * 18.2065 / (T0 - T1));
    WriteLn(Name, R: 8, ' /s');
  end;
end;

begin
  Bad := 0;
  WriteLn('=== xprobe: PicoMEM EMS for an XMS driver ===');
  WriteLn('cpu ', CpuName, ', fpu ', FpuName);

  { 1. the card }
  Step('1 card');
  RAX := $6000; RDX := $1234;
  asm
    mov ax, RAX
    mov dx, RDX
    pushf               { the PicoMEM BIOS returns with IF=0 -- }
    int 13h             { keep the caller's flags, not its own }
    popf
    mov RDX, dx
  end;
  if RDX <> $AA55 then begin WriteLn('no PicoMEM (6000h DX=', Hex(RDX, 4), ')'); Halt(1); end;
  asm
    mov ax, 6001h
    mov dx, 1234h
    pushf
    int 13h
    popf
    mov RCX, cx
    mov RDX, dx
  end;
  Port := RCX; Frame := RDX;
  WriteLn('PicoMEM: EMS port ', Hex(Port, 3), 'h, frame ', Hex(Frame, 4), 'h');
  WriteLn(StdErr, 'xprobe: port ', Hex(Port, 3), 'h frame ', Hex(Frame, 4), 'h');

  { 2. the driver }
  Step('2 driver');
  WriteLn('40 status  AH=', Hex(Ems($4000, 0, 0), 2));
  Ems($4100, 0, 0); EFrame := RBX;
  WriteLn('41 frame   ', Hex(EFrame, 4));
  Ems($4200, 0, 0); Pages := RDX; FreeP := RBX;
  WriteLn('42 pages   total ', Pages, ' free ', FreeP);
  Ems($4600, 0, 0); WriteLn('46 version ', Hex(Lo(RAX), 2));
  Ems($4E03, 0, 0); WriteLn('4E/03 map size ', Lo(RAX), ' bytes');
  if EFrame <> Frame then begin WriteLn('frame disagrees'); Inc(Bad); end;

  { 3. readback }
  Step('3 readback');
  if Ems($4300, 4, 0) <> 0 then begin WriteLn('43 alloc 4 failed'); Halt(1); end;
  Handle := RDX;
  EmsPtr($4E00, @MapBuf, True);
  WriteLn('4E/00 get  AH=', Hex(Hi(RAX), 2));
  Write('registers before:');
  for I := 0 to 3 do Write(' ', Hex(InB(Port + I), 2));
  WriteLn;
  for I := 0 to 3 do Old[I] := InB(Port + I);
  for I := 0 to 3 do
  begin
    Ems($4400, I, Handle);
    G[I] := InB(Port);
    FillChar(Ptr(Frame, 0)^, 16384, $30 + I);
    Mem[Frame : 0] := G[I];
    Mem[Frame : 16383] := $A0 + I;
  end;
  Write('handle''s pages, read back from the port:');
  for I := 0 to 3 do Write(' ', Hex(G[I], 2));
  WriteLn;
  Ok := True;
  for I := 3 downto 0 do
  begin
    OutB(Port + 1, G[I]);
    V := InB(Port + 1);
    if (V <> G[I]) or (Mem[Frame : $4000] <> G[I]) or (Mem[Frame : $4000 + 5000] <> $30 + I)
       or (Mem[Frame : $4000 + 16383] <> $A0 + I) then Ok := False;
  end;
  { window 1 and window 0 on one page are one memory }
  OutB(Port + 1, G[3]);
  Ems($4400, 3, Handle);
  Mem[Frame : 100] := $5A;
  if Mem[Frame : $4000 + 100] <> $5A then Ok := False;
  if Ok then WriteLn('readback: OUT of a read-back number maps that page -- OK')
  else begin WriteLn('readback: FAILED'); Inc(Bad); end;

  { 4. the ceiling, window 1 mapped straight, window 2 another page }
  Step('4 ceiling');
  New(A); New(B);
  OutB(Port + 1, G[0]);
  OutB(Port + 2, G[1]);
  WriteLn('--- copies, REP MOVSW ---');
  S := A; D := B; W := 8192; Time('conv -> conv  16 KB         ', @BMov, 16384);
  S := Ptr(Seg(A^), Ofs(A^) + 1); D := B; W := 8192; Time('conv -> conv  16 KB, src odd', @BMov, 16384);
  S := A; D := Ptr(Frame, $4000); W := 8192; Time('conv -> frame 16 KB         ', @BMov, 16384);
  S := Ptr(Seg(A^), Ofs(A^) + 1); Time('conv -> frame 16 KB, src odd', @BMov, 16384);
  S := Ptr(Frame, $4000); D := A; Time('frame -> conv 16 KB         ', @BMov, 16384);
  D := Ptr(Seg(A^), Ofs(A^) + 1); Time('frame -> conv 16 KB, dst odd', @BMov, 16384);
  S := Ptr(Frame, $4000); D := Ptr(Frame, $8000); Time('frame -> frame 16 KB        ', @BMov, 16384);
  S := A; D := Ptr(Frame, $4000); W := 512; Time('conv -> frame  1 KB         ', @BMov, 1024);
  S := A; D := Ptr(Frame, $4000); W := 256; Time('conv -> frame 512 B         ', @BMov, 512);
  if HasFpu then
  begin
    WriteLn('--- copies, 8087 FILD/FISTP qword ---');
    S := A; D := B; W := 2048; Time('conv -> conv  16 KB         ', @BFpu, 16384);
    S := A; D := Ptr(Frame, $4000); Time('conv -> frame 16 KB         ', @BFpu, 16384);
    S := Ptr(Frame, $4000); D := A; Time('frame -> conv 16 KB         ', @BFpu, 16384);
  end;
  WriteLn('--- the page registers and EMS, for comparison ---');
  Time('OUT to a page register     ', @BOut, -1000);
  Time('IN from a page register    ', @BIn, -1000);
  Time('INT 67h 44h map            ', @B44, -1);
  MV.Len := 512; MV.SType := 0; MV.SHandle := 0; MV.SOff := Ofs(A^); MV.SSeg := Seg(A^);
  MV.DType := 1; MV.DHandle := Handle; MV.DOff := 0; MV.DSeg := 2;
  Time('INT 67h 57h 512 B c->e     ', @B57, 512);
  WriteLn('  57h AH=', Hex(Hi(RAX), 2));
  MV.Len := 16384; MV.DOff := 0;
  Time('INT 67h 57h 16 KB c->e     ', @B57, 16384);

  { put everything back: the hardware first, then the driver's own map }
  Step('5 restore');
  for I := 3 downto 0 do OutB(Port + I, Old[I]);
  EmsPtr($4E01, @MapBuf, False);
  WriteLn('4E/01 set  AH=', Hex(Hi(RAX), 2));
  Write('registers after: ');
  for I := 0 to 3 do Write(' ', Hex(InB(Port + I), 2));
  WriteLn;
  WriteLn('45 free    AH=', Hex(Ems($4500, 0, Handle), 2));
  if Bad = 0 then WriteLn('xprobe: all checks passed') else WriteLn('xprobe: ', Bad, ' FAILED');
  Halt(Ord(Bad <> 0));
end.
