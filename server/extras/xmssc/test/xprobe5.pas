program XProbe5;
{ XMSSC  --  StevenC & Claude.  Public domain (the Unlicense). }
{ xprobe2.pas -- what does CHANGING a PicoMEM EMS page register cost?

  xprobe timed OUTs that wrote the same page number over and over.  An XMS
  move borrows a window and gives it back, so it changes the register twice
  per slice -- and if the card does real work on a change (its RAM behind
  the window is PSRAM, perhaps cached), that is where the time goes.

  Rows: OUT of the same number; OUT alternating two pages; alternating and
  then touching the window (one word, 512 bytes read, 512 written); and
  REP MOVSW of 512 bytes with no remap, for comparison.  Everything is put
  back through EMS 4Eh at the end. }

{$MODE OBJFPC}{$H-}
{$ASMMODE INTEL}

uses About;

var
  Port, Frame, Handle: Word;
  G: array[0 .. 15] of Byte;
  NP: Integer;
  Cur: Integer;
  Old: array[0 .. 3] of Byte;
  MapBuf: array[0 .. 63] of Byte;
  Buf: array[0 .. 16383] of Byte;
  RAX, RBX, RCX, RDX: Word;
  I: Integer;
  PA, PB: Byte;

function Hex(W: Word; N: Integer): ShortString;
const D: array[0 .. 15] of Char = '0123456789ABCDEF';
var S: ShortString; K: Integer;
begin
  S := '';
  for K := 1 to N do begin S := D[W and 15] + S; W := W shr 4; end;
  Hex := S;
end;

procedure OutB(P: Word; B: Byte); assembler;
asm
  mov dx, P
  mov al, B
  out dx, al
end;

function InB(P: Word): Byte; assembler;
asm
  mov dx, P
  in al, dx
end;

procedure Ems67; assembler;
asm
  mov ax, RAX
  mov bx, RBX
  mov dx, RDX
  int 67h
  mov RAX, ax
  mov RBX, bx
  mov RDX, dx
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

{ 100 times: the same page }
procedure OSame; assembler;
asm
  mov dx, Port
  inc dx
  mov al, PA
  mov cx, 100
@@l:
  out dx, al
  loop @@l
end;

{ 100 times: two pages in turn }
procedure OAlt; assembler;
asm
  mov dx, Port
  inc dx
  mov bl, PA
  mov bh, PB
  mov cx, 50
@@l:
  mov al, bl
  out dx, al
  mov al, bh
  out dx, al
  loop @@l
end;

{ 100 times: two pages in turn, reading one word of the window after each }
procedure OAltTouch; assembler;
asm
  push es
  mov es, Frame
  mov dx, Port
  inc dx
  mov bl, PA
  mov bh, PB
  mov cx, 50
@@l:
  mov al, bl
  out dx, al
  mov ax, es:[4000h]
  mov al, bh
  out dx, al
  mov ax, es:[4000h]
  loop @@l
  pop es
end;

{ 16 times: the next of NP pages into window 1, then read 512 bytes }
procedure Cycle;
var K: Integer;
begin
  for K := 1 to 16 do
  begin
    Cur := (Cur + 1) mod NP;
    OutB(Port + 1, G[Cur]);
    asm
      push ds
      push es
      push si
      push di
      mov ax, ds
      mov es, ax
      mov ds, Frame
      mov si, 4000h
      mov di, offset Buf
      mov cx, 256
      rep movsw
      pop di
      pop si
      pop es
      pop ds
    end;
  end;
end;

var CliOn: Boolean; SrcSeg, SrcOff, DstSeg, DstOff: Word;
{ 16 KB, with or without interrupts }
procedure Copy16;
begin
  asm
    push ds
    push es
    push si
    push di
    mov bl, CliOn
    mov ax, SrcSeg
    mov si, SrcOff
    mov es, DstSeg
    mov di, DstOff
    mov ds, ax
    mov cx, 2048
    pushf
    test bl, bl
    jz @@go
    cli
  @@go:
    rep movsw
    popf
    pop di
    pop si
    pop es
    pop ds
  end;
end;

var Mask: Byte;
{ PIT channel 0's count, latched }
function Pit: Word; assembler;
asm
  pushf
  cli
  mov al, 0
  out 43h, al
  in al, 40h
  mov ah, al
  in al, 40h
  xchg al, ah
  popf
end;

{ frame -> frame 4 KB copies for 110 half-ticks of PIT channel 0 (mode 3:
  it reloads twice a tick, 27.5 ms apart) -- a clock that runs whether or
  not IRQ 0 is masked.  Every loop has a bound. }
procedure Run(const Name: ShortString);
var P0, P1: Word; N, Guard: LongInt; Old: Byte; Halves: Integer;
begin
  WriteLn(StdErr, 'xprobe5: ', Name);
  Old := InB($21);
  OutB($21, Old or Mask);
  N := 0; Halves := 0; Guard := 0;
  P0 := Pit;
  repeat
    Copy16;
    Inc(N);
    P1 := Pit;
    if P1 > P0 then Inc(Halves);
    P0 := P1;
    Inc(Guard);
  until (Halves >= 110) or (Guard > 20000);
  OutB($21, Old);
  WriteLn(Name, Round(N * 4 / (Halves * 0.0274658)): 8, ' KB/s   (', N, ' copies)');
end;

{ 10 times: change the page, then read 512 bytes of it }
procedure OAltRead; assembler;
asm
  push ds
  push es
  push si
  push di
  mov bl, PA
  mov bh, PB
  mov dx, Port
  inc dx
  mov ax, ds
  mov es, ax
  mov ds, Frame
  mov cx, 10
@@l:
  push cx
  mov al, bl
  out dx, al
  xchg bl, bh
  mov si, 4000h
  mov di, offset Buf
  mov cx, 256
  rep movsw
  pop cx
  loop @@l
  pop di
  pop si
  pop es
  pop ds
end;

{ 10 times: the same page, read 512 bytes }
procedure SameRead; assembler;
asm
  push ds
  push es
  push si
  push di
  mov ax, ds
  mov es, ax
  mov ds, Frame
  mov cx, 10
@@l:
  push cx
  mov si, 4000h
  mov di, offset Buf
  mov cx, 256
  rep movsw
  pop cx
  loop @@l
  pop di
  pop si
  pop es
  pop ds
end;

{ 10 times: change the page, then write 512 bytes to it }
procedure OAltWrite; assembler;
asm
  push ds
  push es
  push si
  push di
  mov bl, PA
  mov bh, PB
  mov dx, Port
  inc dx
  mov es, Frame
  mov cx, 10
@@l:
  push cx
  mov al, bl
  out dx, al
  xchg bl, bh
  mov si, offset Buf
  mov di, 4000h
  mov cx, 256
  rep movsw
  pop cx
  loop @@l
  pop di
  pop si
  pop es
  pop ds
end;

type TBody = procedure;

procedure Time(const Name: ShortString; Body: TBody; PerCall: Word);
var T0, T1, N: LongInt; R: Real;
begin
  WriteLn(StdErr, 'xprobe2: ', Name);
  T0 := MemL[$40 : $6C];
  repeat T1 := MemL[$40 : $6C] until T1 <> T0;
  N := 0;
  repeat
    Body;
    Inc(N);
    T0 := MemL[$40 : $6C];
  until T0 - T1 >= 36;
  R := (T0 - T1) / 18.2065 * 1000000.0 / (N * PerCall);
  WriteLn(Name, R: 10: 1, ' us each');
end;

begin
  WriteLn('=== xprobe2: the cost of changing a PicoMEM page register ===');
  asm
    mov ax, 6000h
    mov dx, 1234h
    pushf
    int 13h
    popf
    mov RDX, dx
  end;
  if RDX <> $AA55 then begin WriteLn('no PicoMEM'); Halt(1); end;
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
  WriteLn('port ', Hex(Port, 3), 'h, frame ', Hex(Frame, 4), 'h');

  RAX := $4300; RBX := 16; Ems67;
  if Hi(RAX) <> 0 then begin WriteLn('no pages'); Halt(1); end;
  Handle := RDX;
  EmsPtr($4E00, @MapBuf, True);
  for I := 0 to 3 do Old[I] := InB(Port + I);
  for I := 0 to 15 do
  begin
    RAX := $4400; RBX := I; RDX := Handle; Ems67;
    G[I] := InB(Port);
  end;
  PA := G[0]; PB := G[1];
  WriteLn('pages ', Hex(PA, 2), ' and ', Hex(PB, 2), ' through window 1');

  OutB(Port + 0, G[0]);
  OutB(Port + 1, G[1]);
  SrcSeg := Frame; SrcOff := 0; DstSeg := Frame + $400; DstOff := 0;
  WriteLn('frame -> frame, 4 KB at a time, about 3 s each by PIT channel 0; PIC mask ', Hex(InB($21), 2));
  CliOn := False;
  Mask := 0;   Run('interrupts on                 ');
  Mask := 1;   Run('IRQ 0 (timer) masked          ');
  Mask := 8;   Run('IRQ 3 (packet driver) masked  ');
  Mask := 9;   Run('IRQ 0 and 3 masked            ');
  Mask := $FF; Run('every IRQ masked              ');
  CliOn := True; Mask := 0;
               Run('CLI during each copy          ');
  for I := 3 downto 0 do OutB(Port + I, Old[I]);
  EmsPtr($4E01, @MapBuf, False);
  for I := 3 downto 0 do OutB(Port + I, Old[I]);
  RAX := $4500; RDX := Handle; Ems67;
  WriteLn('registers put back: ', Hex(InB(Port), 2), ' ', Hex(InB(Port + 1), 2), ' ',
          Hex(InB(Port + 2), 2), ' ', Hex(InB(Port + 3), 2));
end.
