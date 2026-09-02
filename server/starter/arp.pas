program Arp;
{ DOS Bridge  --  StevenC }
{ Ask "who has this IP?" on the wire, and listen for the answer.

  Usage:  ARP 192.168.50.1          resolve one address
          ARP 192.168.50.1 -w 3     wait up to 3 seconds for the reply
          ARP -scan 192.168.50      sweep .1 to .254 and list what answers
          ARP -scan 192.168.50 -w 4 give the sweep a longer listening window
          ARP 192.168.50.1 -ip 192.168.50.66    force our sender address

  Our own IP comes from IPADDR in the file %MTCPCFG% points at -- the same
  place every mTCP tool reads it. That matters more than it sounds: the first
  version of this program guessed the sender address as .0 of the target's
  range, and got no replies at all, because .0 is a network address and hosts
  are right to ignore an ARP request that claims to come from it.

  Exit code: number of hosts that answered, capped at 20. 0 means silence.

  This is the first program here that TRANSMITS. Worth knowing how much
  easier that is than receiving: send_pkt (AH=04h) takes DS:SI and CX and
  nothing else -- no handle, no callback, no interrupt-time code, nothing to
  release. All the care in pktcap.pas is about the receive path, and this
  program reuses exactly that pattern for the replies while the sending half
  is a dozen lines.

  ARP is worth doing first because it is complete in 42 bytes and needs no IP
  stack at all: an Ethernet header, a fixed 8-byte preamble, and four
  addresses. Getting a reply proves both directions of the packet driver work.

  THE SAME HAZARD AS PKTCAP APPLIES. access_type hands the driver a pointer to
  our receive routine, and exiting without release_type leaves it calling into
  freed memory -- a machine with no network, recovered only at the keyboard.
  Everything between Acquire and Release is straight-line, with no DOS calls
  and nothing printed. Results are collected silently and reported afterwards. }

{$MODE OBJFPC}{$H-}
{$ASMMODE INTEL}

uses Dos, About;

const
  MAXPKT  = 1520;
  MAXHOST = 254;
  ETH_ARP = $0806;

type
  TShared = packed record
    Busy     : Word;                             { +0 }
    PktLen   : Word;                             { +2 }
    PktCount : Word;                             { +4 }
    Dropped  : Word;                             { +6 }
    BytesLo  : Word;                             { +8 }
    BytesHi  : Word;                             { +10 }
    Buf      : array[0 .. MAXPKT - 1] of Byte;   { +12 }
  end;

  TIP  = packed array[0..3] of Byte;
  TMac = packed array[0..5] of Byte;

var
  Shared  : TShared;
  Filt    : packed array[0..1] of Byte;
  Handler : packed record O, S: Word; end;
  Frame   : packed array[0..59] of Byte;   { 42 used, padded to the 60-byte min }
  PktVec  : Byte;
  Handle  : Word;
  CarryB  : Byte;
  ErrDH   : Byte;
  MyMac   : TMac;
  MyIP    : TIP;

  FoundIP  : array[1 .. MAXHOST] of TIP;
  FoundMac : array[1 .. MAXHOST] of TMac;
  NFound   : Integer;

{ Pull IPADDR out of the mTCP config. Reading a file is a DOS operation, so
  this must happen -- and does -- before the packet handle is ever opened. }
function ReadCfgIP(var A: TIP): Boolean;
var
  F    : Text;
  Line : ShortString;
  Cfg  : ShortString;
  I, J : Integer;
  Key  : ShortString;
  Rest : ShortString;
  Part : LongInt;
  Code : Integer;
  Cur  : ShortString;
  N    : Integer;
begin
  ReadCfgIP := False;
  Cfg := GetEnv('MTCPCFG');
  if Cfg = '' then Exit;
  {$I-}
  Assign(F, Cfg);
  Reset(F);
  {$I+}
  if IOResult <> 0 then Exit;

  while not Eof(F) do
  begin
    {$I-}
    ReadLn(F, Line);
    {$I+}
    if IOResult <> 0 then Break;

    { Split off the first word and upper-case it. }
    I := 1;
    while (I <= Length(Line)) and (Line[I] = ' ') do Inc(I);
    Key := '';
    while (I <= Length(Line)) and (Line[I] <> ' ') do
    begin
      if (Line[I] >= 'a') and (Line[I] <= 'z') then
        Key := Key + Chr(Ord(Line[I]) - 32)
      else
        Key := Key + Line[I];
      Inc(I);
    end;
    if Key <> 'IPADDR' then Continue;

    while (I <= Length(Line)) and (Line[I] = ' ') do Inc(I);
    Rest := '';
    while (I <= Length(Line)) and (Line[I] <> ' ') do
    begin
      Rest := Rest + Line[I];
      Inc(I);
    end;

    N := 0; Cur := '';
    for J := 1 to Length(Rest) + 1 do
    begin
      if (J <= Length(Rest)) and (Rest[J] <> '.') then
        Cur := Cur + Rest[J]
      else
      begin
        Val(Cur, Part, Code);
        if (Code <> 0) or (Part < 0) or (Part > 255) or (N > 3) then
        begin
          Close(F);
          Exit;
        end;
        A[N] := Byte(Part);
        Inc(N);
        Cur := '';
      end;
    end;
    if N = 4 then
    begin
      Close(F);
      ReadCfgIP := True;
      Exit;
    end;
  end;
  Close(F);
end;

{ The receiver, byte-identical in shape to pktcap.pas. See the long comment
  there: the first fourteen bytes are hand-written so the two words patched at
  run time sit at known offsets +7 (data segment) and +12 (Ofs(Shared)). }
procedure PktRecv; assembler; nostackframe;
asm
  db  01Eh              { push ds                       +0 }
  db  053h              { push bx                       +1 }
  db  051h              { push cx                       +2 }
  db  056h              { push si                       +3 }
  db  08Bh, 0F0h        { mov si, ax                 +4,+5 }
  db  0B8h              { mov ax, imm16                 +6 }
  dw  0                 {   patched: data segment       +7 }
  db  08Eh, 0D8h        { mov ds, ax                 +9,+10 }
  db  0BBh              { mov bx, imm16                +11 }
  dw  0                 {   patched: Ofs(Shared)       +12 }

  cmp  si, 0
  jne  @@second

  cmp  word ptr [bx], 0
  jne  @@refuse
  cmp  cx, MAXPKT
  ja   @@refuse
  mov  ax, ds
  mov  es, ax
  mov  di, bx
  add  di, 12
  jmp  @@out

@@refuse:
  inc  word ptr [bx + 6]
  xor  ax, ax
  mov  es, ax
  xor  di, di
  jmp  @@out

@@second:
  inc  word ptr [bx + 4]
  mov  word ptr [bx + 2], cx
  add  word ptr [bx + 8], cx
  adc  word ptr [bx + 10], 0
  mov  word ptr [bx], 1

@@out:
  pop  si
  pop  cx
  pop  bx
  pop  ds
  retf
end;

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

function IPStr(const A: TIP): ShortString;
begin
  IPStr := Num(A[0]) + '.' + Num(A[1]) + '.' + Num(A[2]) + '.' + Num(A[3]);
end;

function MacStr(const M: TMac): ShortString;
var
  S: ShortString;
  I: Integer;
begin
  S := '';
  for I := 0 to 5 do
  begin
    if I > 0 then S := S + ':';
    S := S + Hex2(M[I]);
  end;
  MacStr := S;
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
        Ok := False; Break;
      end;
    if Ok then
    begin
      PktVec := Byte(V);
      Handler.O := Of_; Handler.S := Sg;
      FindDriver := True;
      Exit;
    end;
  end;
end;

procedure Acquire;
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
    mov  cx, 2
    mov  bx, 0FFFFh
    mov  dl, 0
    mov  ah, 2
    mov  al, 1
    pushf
    call far [Handler]
    mov  cx, ax
    mov  ax, dx
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

{ get_address (AH=06h): our own MAC, into ES:DI, CX = buffer size.
  Needs the handle, so it only works between Acquire and Release. }
procedure GetMyMac;
var
  MSeg, MOfs: Word;
begin
  MSeg := Seg(MyMac); MOfs := Ofs(MyMac);
  asm
    push ds
    push es
    push di
    mov  ax, MSeg
    mov  es, ax
    mov  di, MOfs
    mov  cx, 6
    mov  bx, Handle
    mov  ah, 6
    pushf
    call far [Handler]
    pop  di
    pop  es
    pop  ds
  end;
end;

{ send_pkt (AH=04h): DS:SI = frame, CX = length. No handle, no callback,
  nothing to clean up -- the whole reason transmitting is the easy half. }
procedure SendFrame(Len: Word);
var
  FOfs: Word;
begin
  FOfs := Ofs(Frame);
  asm
    push ds
    push si
    mov  si, FOfs
    mov  cx, Len
    mov  ah, 4
    pushf
    call far [Handler]
    pop  si
    pop  ds
  end;
end;

{ A 42-byte ARP request, padded to the 60-byte Ethernet minimum.

    0..5   destination MAC   FF:FF:FF:FF:FF:FF, broadcast
    6..11  source MAC        ours
   12..13  ethertype         0806
   14..15  hardware type     0001  Ethernet
   16..17  protocol type     0800  IPv4
   18      hardware length   6
   19      protocol length   4
   20..21  opcode            0001  request
   22..27  sender MAC        ours
   28..31  sender IP         ours
   32..37  target MAC        zero -- it is what we are asking for
   38..41  target IP         the one in question }
procedure BuildRequest(const Target: TIP);
var
  I: Integer;
begin
  for I := 0 to 59 do Frame[I] := 0;
  for I := 0 to 5 do Frame[I] := $FF;
  for I := 0 to 5 do Frame[6 + I] := MyMac[I];
  Frame[12] := $08; Frame[13] := $06;
  Frame[14] := $00; Frame[15] := $01;
  Frame[16] := $08; Frame[17] := $00;
  Frame[18] := 6;   Frame[19] := 4;
  Frame[20] := $00; Frame[21] := $01;
  for I := 0 to 5 do Frame[22 + I] := MyMac[I];
  for I := 0 to 3 do Frame[28 + I] := MyIP[I];
  for I := 0 to 3 do Frame[38 + I] := Target[I];
end;

{ Record a reply, ignoring duplicates and anything that is not a reply. }
procedure Harvest;
var
  I, J: Integer;
  IP: TIP;
  M : TMac;
  Dup: Boolean;
begin
  if Shared.Busy = 0 then Exit;
  if Shared.PktLen >= 42 then
    { opcode 2 = reply, at offset 20..21 }
    if (Shared.Buf[20] = 0) and (Shared.Buf[21] = 2) then
    begin
      for I := 0 to 5 do M[I] := Shared.Buf[22 + I];
      for I := 0 to 3 do IP[I] := Shared.Buf[28 + I];
      Dup := False;
      for J := 1 to NFound do
        if (FoundIP[J][0] = IP[0]) and (FoundIP[J][1] = IP[1]) and
           (FoundIP[J][2] = IP[2]) and (FoundIP[J][3] = IP[3]) then Dup := True;
      if (not Dup) and (NFound < MAXHOST) then
      begin
        Inc(NFound);
        FoundIP[NFound] := IP;
        FoundMac[NFound] := M;
      end;
    end;
  Shared.Busy := 0;
end;

procedure Settle(T: LongInt);
var
  T0: LongInt;
begin
  T0 := Ticks;
  while (Ticks - T0) < T do Harvest;
end;

var
  S, Arg  : ShortString;
  I, J    : Integer;
  Scan    : Boolean;
  WaitS   : LongInt;
  Target  : TIP;
  Base    : TIP;
  Parts   : array[0..3] of LongInt;
  NPart   : Integer;
  Code    : Integer;
  Cur     : ShortString;
  Tmp     : ShortString;
  HaveMyIP: Boolean;

begin
  Scan := False;
  HaveMyIP := False;
  WaitS := 2;
  S := '';
  NFound := 0;

  I := 1;
  while I <= ParamCount do
  begin
    Arg := ParamStr(I);
    if (Arg = '-scan') or (Arg = '-SCAN') or (Arg = '/scan') or (Arg = '/SCAN') then
      Scan := True
    else if (Arg = '-ip') or (Arg = '-IP') then
    begin
      Inc(I);
      if I <= ParamCount then
      begin
        Cur := ParamStr(I);
        NPart := 0; Tmp := '';
        for J := 1 to Length(Cur) + 1 do
        begin
          if (J <= Length(Cur)) and (Cur[J] <> '.') then
            Tmp := Tmp + Cur[J]
          else
          begin
            Val(Tmp, Parts[0], Code);
            if (Code = 0) and (Parts[0] >= 0) and (Parts[0] <= 255)
               and (NPart < 4) then
            begin
              MyIP[NPart] := Byte(Parts[0]);
              Inc(NPart);
            end;
            Tmp := '';
          end;
        end;
        HaveMyIP := NPart = 4;
      end;
    end
    else if (Arg = '-w') or (Arg = '-W') or (Arg = '/w') or (Arg = '/W') then
    begin
      Inc(I);
      if I <= ParamCount then
      begin
        Val(ParamStr(I), WaitS, Code);
        if (Code <> 0) or (WaitS < 1) then WaitS := 2;
        if WaitS > 30 then WaitS := 30;
      end;
    end
    else
      S := Arg;
    Inc(I);
  end;

  WriteLn('=== arp: who has this address? ===');

  if S = '' then
  begin
    WriteLn('  Nothing to ask about.');
    WriteLn('    ARP 192.168.50.1        one address');
    WriteLn('    ARP -scan 192.168.50    the whole /24');
    Halt(0);
  end;

  { Split the dotted string. A scan target has three parts, a single host four. }
  NPart := 0;
  Cur := '';
  for I := 1 to Length(S) + 1 do
  begin
    if (I <= Length(S)) and (S[I] <> '.') then
      Cur := Cur + S[I]
    else
    begin
      if NPart < 4 then
      begin
        Val(Cur, Parts[NPart], Code);
        if Code <> 0 then Parts[NPart] := -1;
        Inc(NPart);
      end;
      Cur := '';
    end;
  end;

  for I := 0 to NPart - 1 do
    if (Parts[I] < 0) or (Parts[I] > 255) then
    begin
      WriteLn('  "', S, '" is not a dotted address.');
      Halt(0);
    end;

  if Scan then
  begin
    if NPart <> 3 then
    begin
      WriteLn('  -scan wants the first three octets, e.g. -scan 192.168.50');
      Halt(0);
    end;
    Base[0] := Byte(Parts[0]); Base[1] := Byte(Parts[1]);
    Base[2] := Byte(Parts[2]); Base[3] := 0;
  end
  else
  begin
    if NPart <> 4 then
    begin
      WriteLn('  Give all four octets, e.g. 192.168.50.1');
      Halt(0);
    end;
    for I := 0 to 3 do Target[I] := Byte(Parts[I]);
  end;

  if not FindDriver then
  begin
    WriteLn('  No packet driver in 60h..80h.');
    Halt(0);
  end;
  WriteLn('  driver         : INT ', Hex2(PktVec), 'h');

  { Our own IP is not something the packet driver knows -- addresses are a
    concept one layer up, so it has to come from the config. A wrong sender
    address is not a cosmetic problem: ask from a network address like .0 and
    well-behaved hosts simply will not answer. }
  if not HaveMyIP then
    if not ReadCfgIP(MyIP) then
    begin
      WriteLn;
      WriteLn('  Could not read IPADDR from %MTCPCFG%, and no -ip was given.');
      WriteLn('  Without a real sender address the requests would go out');
      WriteLn('  claiming an address nothing will reply to, so stopping here.');
      Halt(0);
    end;
  WriteLn('  our IP         : ', IPStr(MyIP));

  Filt[0] := $08; Filt[1] := $06;      { ARP, network byte order }
  MemW[Seg(PktRecv) : Word(Ofs(PktRecv) + 7)]  := Seg(Shared);
  MemW[Seg(PktRecv) : Word(Ofs(PktRecv) + 12)] := Ofs(Shared);

  Shared.Busy := 0; Shared.PktLen := 0; Shared.PktCount := 0;
  Shared.Dropped := 0; Shared.BytesLo := 0; Shared.BytesHi := 0;

  { ---- no DOS calls from here until Release --------------------------- }
  Acquire;
  if CarryB <> 0 then
  begin
    WriteLn;
    WriteLn('  access_type refused the handle (error ', ErrDH, ').');
    WriteLn('  Nothing was registered, so nothing needs releasing.');
    Halt(0);
  end;

  GetMyMac;

  if Scan then
  begin
    for J := 1 to 254 do
    begin
      Target := Base;
      Target[3] := Byte(J);
      BuildRequest(Target);
      SendFrame(60);
      { A tick between sends: 254 back-to-back frames overrun the card's
        transmit ring on hardware this old, and the replies need somewhere to
        land anyway. }
      Settle(1);
    end;
  end
  else
  begin
    BuildRequest(Target);
    SendFrame(60);
  end;

  Settle((WaitS * 182) div 10);
  Release;
  { ---- handle is back -------------------------------------------------- }

  WriteLn('  our MAC        : ', MacStr(MyMac));
  if Scan then
    WriteLn('  swept          : ', IPStr(Base), '.1 - .254')
  else
    WriteLn('  asked about    : ', IPStr(Target));
  WriteLn('  ARP frames seen: ', Shared.PktCount, '   dropped: ', Shared.Dropped);
  WriteLn;

  if NFound = 0 then
  begin
    WriteLn('  No replies. Either nothing is there, or the window was too');
    WriteLn('  short -- try -w 5.');
    Halt(0);
  end;

  WriteLn('  replies (', NFound, '):');
  for I := 1 to NFound do
    WriteLn('    ', IPStr(FoundIP[I]), '   ', MacStr(FoundMac[I]));

  if NFound > 20 then Halt(20);
  Halt(NFound);
end.
