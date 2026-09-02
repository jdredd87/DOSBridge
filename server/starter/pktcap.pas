program PktCap;
{ DOS Bridge  --  StevenC }
{ Capture Ethernet frames straight from the packet driver, in Pascal.

  Usage:  PKTCAP                 5 seconds of ARP (ethertype 0806h)
          PKTCAP 10              10 seconds of ARP
          PKTCAP 10 0800         10 seconds of IPv4
          PKTCAP 10 ALL          every frame the card passes up -- see below

  Exit code: 0 if at least one frame arrived, 1 if none, 2 if the driver
  refused the handle, 3 if no packet driver is installed.

  ------------------------------------------------------------------------
  READ THIS BEFORE CHANGING ANYTHING

  This is the only program here that calls access_type (AH=02h), and that call
  is different in kind from everything else in the toolset. It hands the packet
  driver a far pointer to PktRecv below, which the driver then calls at
  interrupt time for every matching frame. Two consequences:

  1. Exit without release_type (AH=03h) and the driver keeps calling a pointer
     into memory DOS has since handed to something else -- the next matching
     frame jumps into whatever is there. The result is a machine with no
     network, and the bridge runs over that network, so recovering needs
     someone physically at the keyboard.

     Everything between Acquire and Release is therefore straight-line code
     with no DOS calls, no file I/O and no WriteLn. Nothing is printed until
     the handle is back. There is one path in and one path out.

  2. A frame delivered to our handle is NOT delivered to mTCP's. Capturing ALL
     takes every frame away from the stack this bridge is using. For a few
     seconds that is survivable -- TCP retransmits, and the job's own reply is
     sent long after we have released -- but it is not free. Hence ALL is
     opt-in and the default is ARP, which is broadcast, frequent, and not
     something an established connection depends on moment to moment.

  The receiver runs at interrupt time: no DOS, no assumptions about the stack,
  and as short as possible. It notes the length, bumps a counter, sets a flag.
  The main loop does everything else. }

{$MODE OBJFPC}{$H-}
{$ASMMODE INTEL}


uses About;

const
  MAXPKT   = 1520;
  SNAPMAX  = 64;

type
  { One record, so the handler needs a single patched offset rather than one
    per field. The displacements below are hand-coded into the handler --
    change this layout and you must change those too. }
  TShared = packed record
    Busy     : Word;                             { +0  1 = frame waiting }
    PktLen   : Word;                             { +2 }
    PktCount : Word;                             { +4 }
    Dropped  : Word;                             { +6  arrived while Busy }
    BytesLo  : Word;                             { +8 }
    BytesHi  : Word;                             { +10 }
    Buf      : array[0 .. MAXPKT - 1] of Byte;   { +12 }
  end;

var
  Shared  : TShared;
  Filt    : packed array[0..1] of Byte;   { global: Seg() must be our DS }
  Handler : packed record O, S: Word; end;
  PktVec  : Byte;
  Handle  : Word;
  CarryB  : Byte;
  ErrDH   : Byte;

  Snap    : array[0 .. SNAPMAX - 1] of Byte;
  SnapN   : Word;
  HaveSnap: Boolean;

{ ------------------------------------------------------------------------
  The receiver. Called by the driver as a far CALL, twice per frame:

    AX=0  "a frame of CX bytes has arrived" -> return ES:DI = a buffer of that
          size, or ES:DI = 0:0 to make the driver drop it.
    AX=1  "it is copied in"                 -> DS:SI = that buffer, CX = length.

  The first fourteen bytes are raw db/dw on purpose. Two of the words are
  patched at run time with our data segment and the offset of Shared, because
  on entry DS belongs to the driver and nothing of ours is reachable until it
  is replaced. Hand-writing the bytes is what makes the patch offsets (+7 and
  +12) knowable from Pascal; let the assembler pick the encoding and they are
  not.

  ES, DI and AX are return values on the first call and dead on the second, so
  they are deliberately never preserved.
  ------------------------------------------------------------------------ }
procedure PktRecv; assembler; nostackframe;
asm
  db  01Eh              { push ds                                    +0 }
  db  053h              { push bx                                    +1 }
  db  051h              { push cx                                    +2 }
  db  056h              { push si                                    +3 }
  db  08Bh, 0F0h        { mov si, ax   -- keep the call type       +4,+5 }
  db  0B8h              { mov ax, imm16                              +6 }
  dw  0                 {   patched: our data segment                +7 }
  db  08Eh, 0D8h        { mov ds, ax                              +9,+10 }
  db  0BBh              { mov bx, imm16                             +11 }
  dw  0                 {   patched: Ofs(Shared)                    +12 }

  cmp  si, 0
  jne  @@second

  { --- first call: hand back a buffer, or refuse ---------------------- }
  cmp  word ptr [bx], 0         { Busy: the main loop still holds the last }
  jne  @@refuse
  cmp  cx, MAXPKT
  ja   @@refuse
  mov  ax, ds
  mov  es, ax
  mov  di, bx
  add  di, 12                   { ES:DI -> Shared.Buf }
  jmp  @@out

@@refuse:
  inc  word ptr [bx + 6]        { Dropped }
  xor  ax, ax
  mov  es, ax
  xor  di, di                   { 0:0 = discard it }
  jmp  @@out

  { --- second call: the frame is in our buffer ------------------------ }
@@second:
  inc  word ptr [bx + 4]        { PktCount }
  mov  word ptr [bx + 2], cx    { PktLen }
  add  word ptr [bx + 8], cx    { BytesLo }
  adc  word ptr [bx + 10], 0    { BytesHi }
  mov  word ptr [bx], 1         { Busy -- main loop may read it now }

@@out:
  pop  si
  pop  cx
  pop  bx
  pop  ds
  retf
end;

{ ------------------------------------------------------------------------ }

const
  HexD: array[0..15] of Char = '0123456789ABCDEF';

function Hex2(B: Byte): ShortString;
begin
  Hex2 := HexD[(B shr 4) and 15] + HexD[B and 15];
end;

function Num(L: LongInt): ShortString;
var S: ShortString;
begin
  Str(L, S); Num := S;
end;

function Ticks: LongInt;
begin
  Ticks := MemL[$0040 : $006C];
end;

function FindDriver: Boolean;
const
  Sig = 'PKT DRVR';
var
  V, I: Integer;
  Sg, Of_: Word;
  Ok: Boolean;
begin
  FindDriver := False;
  for V := $60 to $80 do
  begin
    Of_ := MemW[0 : Word(V) * 4];
    Sg  := MemW[0 : Word(V) * 4 + 2];
    if Sg = 0 then Continue;
    Ok := True;
    for I := 1 to 8 do
      if Chr(Mem[Sg : Word(Of_ + 2 + I)]) <> Sig[I] then
      begin
        Ok := False;
        Break;
      end;
    if Ok then
    begin
      PktVec := Byte(V);
      Handler.O := Of_;
      Handler.S := Sg;
      FindDriver := True;
      Exit;
    end;
  end;
end;

{ access_type. AL=class, BX=interface type, DL=number, DS:SI=type filter,
  CX=filter length (0 = every type), ES:DI=receiver. Handle back in AX.

  DS stays ours throughout: Filt is a global for exactly that reason, because
  `call far [Handler]` resolves Handler through DS and a local filter buffer
  would have forced DS to SS first. }
procedure Acquire(FLen: Word);
var
  FOfs, RSeg, ROfs: Word;
begin
  FOfs := Ofs(Filt);
  RSeg := Seg(PktRecv);
  ROfs := Ofs(PktRecv);
  asm
    push ds
    push es
    push si
    push di
    mov  ax, RSeg
    mov  es, ax
    mov  di, ROfs
    mov  si, FOfs
    mov  cx, FLen
    mov  bx, 0FFFFh       { any interface type }
    mov  dl, 0            { first interface }
    mov  ah, 2
    mov  al, 1            { class 1 = DIX Ethernet }
    pushf
    call far [Handler]
    { MOV does not disturb the flags, so the driver's carry survives the
      unwind below and is still testable afterwards. }
    mov  cx, ax           { handle }
    mov  ax, dx           { DH = error code if carry is set }
    pop  di
    pop  si
    pop  es
    pop  ds
    jnc  @@ok
    mov  CarryB, 1
    jmp  @@fin
  @@ok:
    mov  CarryB, 0
  @@fin:
    mov  Handle, cx
    mov  ErrDH, ah
  end;
end;

procedure Release;
begin
  asm
    push ds
    mov  bx, Handle
    mov  ah, 3
    pushf
    call far [Handler]
    pop  ds
  end;
end;

function EtherName(T: Word): ShortString;
begin
  case T of
    $0800 : EtherName := 'IPv4';
    $0806 : EtherName := 'ARP';
    $8035 : EtherName := 'RARP';
    $8100 : EtherName := '802.1Q VLAN';
    $86DD : EtherName := 'IPv6';
    $888E : EtherName := '802.1X';
  else
    if T <= 1500 then EtherName := '802.3 length' else EtherName := 'unknown';
  end;
end;

function Mac(P: Word): ShortString;
var
  S: ShortString;
  I: Integer;
begin
  S := '';
  for I := 0 to 5 do
  begin
    if I > 0 then S := S + ':';
    S := S + Hex2(Snap[P + I]);
  end;
  Mac := S;
end;

var
  Secs    : LongInt;
  Limit   : LongInt;
  T0      : LongInt;
  I, N    : Integer;
  Code    : Integer;
  S       : ShortString;
  AllT    : Boolean;
  TypeW   : Word;
  Line    : ShortString;

begin
  Secs  := 5;
  AllT  := False;
  TypeW := $0806;

  if ParamCount >= 1 then
  begin
    Val(ParamStr(1), Secs, Code);
    if (Code <> 0) or (Secs < 1) then Secs := 5;
    if Secs > 60 then Secs := 60;
  end;
  if ParamCount >= 2 then
  begin
    S := ParamStr(2);
    for I := 1 to Length(S) do
      if (S[I] >= 'a') and (S[I] <= 'z') then S[I] := Chr(Ord(S[I]) - 32);
    if S = 'ALL' then
      AllT := True
    else
    begin
      TypeW := 0;
      for I := 1 to Length(S) do
      begin
        N := -1;
        if (S[I] >= '0') and (S[I] <= '9') then N := Ord(S[I]) - 48
        else if (S[I] >= 'A') and (S[I] <= 'F') then N := Ord(S[I]) - 55;
        if N >= 0 then TypeW := (TypeW shl 4) or Word(N);
      end;
      if TypeW = 0 then TypeW := $0806;
    end;
  end;

  WriteLn('=== pktcap: Ethernet capture from the packet driver ===');

  if not FindDriver then
  begin
    WriteLn('  No packet driver in 60h..80h. Nothing to attach to.');
    Halt(3);
  end;
  WriteLn('  driver         : INT ', Hex2(PktVec), 'h');

  if AllT then
  begin
    WriteLn('  capturing      : EVERY ethertype, for ', Secs, ' second(s)');
    WriteLn('  WARNING        : frames delivered here are NOT delivered to');
    WriteLn('                   mTCP. This bridge runs over mTCP, so it is');
    WriteLn('                   deaf for the duration. Keep it short.');
  end
  else
    WriteLn('  capturing      : ethertype ', Hex2(Hi(TypeW)), Hex2(Lo(TypeW)),
            ' (', EtherName(TypeW), ') for ', Secs, ' second(s)');

  { Network byte order: 08 06, not 06 08. }
  Filt[0] := Hi(TypeW);
  Filt[1] := Lo(TypeW);

  { Teach the handler where our data lives. Writing into the code segment is
    legal in real mode and is the only way to give an interrupt-time routine a
    data segment it can reach. }
  MemW[Seg(PktRecv) : Word(Ofs(PktRecv) + 7)]  := Seg(Shared);
  MemW[Seg(PktRecv) : Word(Ofs(PktRecv) + 12)] := Ofs(Shared);

  Shared.Busy := 0;
  Shared.PktLen := 0;
  Shared.PktCount := 0;
  Shared.Dropped := 0;
  Shared.BytesLo := 0;
  Shared.BytesHi := 0;
  HaveSnap := False;
  SnapN := 0;

  { ---- nothing below here may call DOS until Release has run ---------- }
  if AllT then Acquire(0) else Acquire(2);

  if CarryB <> 0 then
  begin
    WriteLn;
    WriteLn('  access_type refused the handle (error ', ErrDH, ').');
    WriteLn('  Nothing was registered, so nothing needs releasing.');
    Halt(2);
  end;

  T0 := Ticks;
  Limit := (Secs * 182) div 10;
  while (Ticks - T0) < Limit do
  begin
    if Shared.Busy <> 0 then
    begin
      if not HaveSnap then
      begin
        SnapN := Shared.PktLen;
        if SnapN > SNAPMAX then N := SNAPMAX else N := SnapN;
        for I := 0 to N - 1 do Snap[I] := Shared.Buf[I];
        HaveSnap := True;
      end;
      Shared.Busy := 0;      { let the handler take the next one }
    end;
  end;

  Release;
  { ---- handle is back; DOS is safe again ------------------------------ }

  WriteLn;
  WriteLn('  frames captured: ', Shared.PktCount);
  WriteLn('  bytes          : ', (LongInt(Shared.BytesHi) shl 16)
                                 or LongInt(Shared.BytesLo));
  WriteLn('  dropped (busy) : ', Shared.Dropped);

  if HaveSnap then
  begin
    WriteLn;
    WriteLn('  first frame    : ', SnapN, ' bytes');
    WriteLn('    destination  : ', Mac(0));
    WriteLn('    source       : ', Mac(6));
    TypeW := (Word(Snap[12]) shl 8) or Word(Snap[13]);
    WriteLn('    ethertype    : ', Hex2(Snap[12]), Hex2(Snap[13]),
            '  (', EtherName(TypeW), ')');
    WriteLn;
    WriteLn('    first ', SnapN, ' bytes:');
    if SnapN > SNAPMAX then N := SNAPMAX else N := SnapN;
    I := 0;
    while I < N do
    begin
      Line := '      ' + Hex2(Hi(Word(I))) + Hex2(Lo(Word(I))) + '  ';
      Code := 0;
      while (Code < 16) and (I + Code < N) do
      begin
        Line := Line + Hex2(Snap[I + Code]) + ' ';
        Inc(Code);
      end;
      WriteLn(Line);
      Inc(I, 16);
    end;
  end
  else
  begin
    WriteLn;
    WriteLn('  Nothing arrived. On a quiet LAN that is normal for ARP --');
    WriteLn('  try a longer window, or 0800 for IPv4, or ALL.');
  end;

  WriteLn;
  WriteLn('  handle released. The driver is no longer calling into this');
  WriteLn('  program, which is the only state it is safe to exit in.');

  if Shared.PktCount > 0 then Halt(0);
  Halt(1);
end.
