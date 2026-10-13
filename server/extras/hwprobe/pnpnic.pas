{ PNPNIC -- wake a Plug-and-Play ISA network card in plain DOS, at a fixed
  I/O address and IRQ, for an NE2000-style packet driver.
  Written by StevenC and Claude (Anthropic), 2026-10-13.

    PNPNIC [/L] [/C:id] [/D:n] [/P:hhh] [/I:n] [/Q]

    /L      list only: every Plug-and-Play card, its ID and its logical
            devices; nothing changed
    /C:id   the card to wake: its ID, or the start of it (DLK, DLK0219 ...).
            Without it: the one card that is not a Creative sound card
    /D:n    its logical device (0, the default)
    /P:hhh  the I/O address, hex (300 by default)
    /I:n    the IRQ (10 by default)
    /Q      quiet: one line, for AUTOEXEC.BAT

  Made for p3box's D-Link DE-220PCT rev D2 (DLT-2518, NE2000-style): no
  jumpers, and in Plug-and-Play mode it stays switched off until something
  configures it -- here, nothing does, so D-Link's SETUP and its packet
  driver both said the card was not there.  The wake-up is PNPSB's (the
  486's AWE64, projects/pnpsb): the initiation key, isolation, a card select
  number, then the card's registers through 279h/A79h.  Afterwards every
  card goes back to Wait-for-Key, and the NE2000's reset is tried at the new
  address to prove it answers.  Every wait is bounded: it runs from
  AUTOEXEC.BAT, before the DOS Bridge agent.

  Exit code: 0 woken and the NE2000 answered; 1 no such card; 2 woken but
  nothing answered at the address; 3 more than one card could be it (/C). }

program PnpNic;

{$MODE OBJFPC}{$H-}

uses About, Dos;

const
  PNP_ADDR  = $279;
  PNP_WRITE = $A79;
  MAXCARDS  = 8;

var
  NicBase: Word = $300;
  NicIrq: Integer = 10;
  Want: ShortString = '';
  Dev: Integer = 0;
  ReadPort: Word;
  Quiet, ListOnly: Boolean;
  Cards: Integer;
  Ids: array[1..MAXCARDS, 0..8] of Byte;
  Res: array[0..1023] of Byte;
  ResLen: Integer;

procedure Say(const S: ShortString);
begin
  if not Quiet then WriteLn(S);
end;

function Hex(V: LongInt; N: Integer): ShortString;
begin
  Hex := HexStr(V, N);
end;

{ about one microsecond an ISA read, on any machine: the bus is the clock }
procedure Wait(Us: LongInt);
var
  B: Byte;
begin
  while Us > 0 do
  begin
    B := Port[$61];
    Dec(Us);
  end;
end;

procedure WReg(R, V: Byte);
begin
  Port[PNP_ADDR] := R;
  Port[PNP_WRITE] := V;
end;

function RReg(R: Byte): Byte;
begin
  Port[PNP_ADDR] := R;
  RReg := Port[ReadPort];
end;

procedure Key;
var
  K: Byte;
  I: Integer;
begin
  Port[PNP_ADDR] := 0;
  Port[PNP_ADDR] := 0;
  K := $6A;
  for I := 1 to 32 do
  begin
    Port[PNP_ADDR] := K;
    K := (K shr 1) or (((K xor (K shr 1)) and 1) shl 7);
  end;
end;

{ one card out of isolation into Ids[N]; False when none is left }
function Isolate(N: Integer): Boolean;
var
  Bit, I, J: Integer;
  B1, B2, Chk, Got: Byte;
  Id: array[0..8] of Byte;
  Any: Boolean;
begin
  FillChar(Id, SizeOf(Id), 0);
  Chk := $6A;
  Any := False;
  Port[PNP_ADDR] := $01;                { serial isolation }
  Wait(1000);
  for I := 0 to 71 do
  begin
    B1 := Port[ReadPort];
    B2 := Port[ReadPort];
    Wait(250);
    if (B1 = $55) and (B2 = $AA) then Bit := 1 else Bit := 0;
    if Bit = 1 then Any := True;
    J := I div 8;
    if Bit = 1 then Id[J] := Id[J] or (1 shl (I mod 8));
    if I < 64 then
      Chk := (Chk shr 1) or ((((Chk xor (Chk shr 1)) xor Bit) and 1) shl 7);
  end;
  Got := Id[8];
  if not Any or (Got <> Chk) then
  begin
    Isolate := False;
    Exit;
  end;
  for I := 0 to 8 do Ids[N, I] := Id[I];
  Isolate := True;
end;

{ the vendor ID's 3 letters and 4 hex digits, as Windows prints it }
function Vendor(N: Integer): ShortString;
var
  V: Word;
begin
  V := (Ids[N, 0] shl 8) or Ids[N, 1];
  Vendor := Chr(((V shr 10) and 31) + 64) + Chr(((V shr 5) and 31) + 64) + Chr((V and 31) + 64) +
            Hex(Ids[N, 2], 2) + Hex(Ids[N, 3], 2);
end;

{ the card's resource data (after a Wake into Config state) }
procedure ReadResources;
var
  I: Integer;
  T: LongInt;
begin
  I := 0;
  while I < 1024 do
  begin
    T := 20000;
    while ((RReg($05) and 1) = 0) and (T > 0) do Dec(T);
    if T = 0 then Break;
    Res[I] := RReg($04);
    Inc(I);
  end;
  ResLen := I;
end;

procedure ListDevices;
var
  P, L, Tag, Ldn: Integer;
  V: Word;
begin
  P := 9;
  Ldn := -1;
  while P < ResLen do
  begin
    Tag := Res[P];
    if (Tag and $80) = 0 then
    begin
      L := Tag and 7;
      case (Tag shr 3) and 15 of
        2: begin                          { logical device ID }
             Inc(Ldn);
             V := (Res[P + 1] shl 8) or Res[P + 2];
             Say('    logical device ' + Chr(48 + Ldn) + ': ' +
                 Chr(((V shr 10) and 31) + 64) + Chr(((V shr 5) and 31) + 64) + Chr((V and 31) + 64) +
                 Hex(Res[P + 3], 2) + Hex(Res[P + 4], 2));
           end;
        15: Break;                        { End }
      end;
      Inc(P, L + 1);
    end
    else
      Inc(P, 3 + (Res[P + 1] or (Res[P + 2] shl 8)));
  end;
end;

{ an NE2000 at Base: its reset port, then the reset bit in its interrupt
  status register -- the test every NE2000 packet driver makes }
function Ne2000(Base: Word): Boolean;
var
  B: Byte;
  T: LongInt;
begin
  Ne2000 := False;
  if Port[Base] = $FF then Exit;        { nothing at all on the bus there }
  B := Port[Base + $1F];                { reset: read the reset port ... }
  Port[Base + $1F] := B;                { ... and write it back }
  T := 20000;
  while ((Port[Base + $07] and $80) = 0) and (T > 0) do Dec(T);
  if T = 0 then Exit;
  Port[Base + $07] := $FF;              { acknowledge every interrupt }
  Port[Base] := $21;                    { page 0, stop, no DMA }
  Ne2000 := (Port[Base] and $3F) = $21;
end;

var
  I, N, Pick, Count: Integer;
  S: ShortString;
  Code: Integer;
  Ports: array[0..3] of Word = ($20B, $273, $2BB, $3E3);
begin
  { FPC 3.2.2's i8086-msdos runtime: ParamStr is '' until ParamCount runs }
  for I := 1 to ParamCount do
  begin
    S := ParamStr(I);
    for N := 1 to Length(S) do S[N] := UpCase(S[N]);
    if S = '/L' then ListOnly := True
    else if S = '/Q' then Quiet := True
    else if Copy(S, 1, 3) = '/C:' then Want := Copy(S, 4, 7)
    else if Copy(S, 1, 3) = '/D:' then Val(Copy(S, 4, 1), Dev, Code)
    else if Copy(S, 1, 3) = '/I:' then
    begin
      Val(Copy(S, 4, 2), NicIrq, Code);
      if not (NicIrq in [2..7, 9..12, 14, 15]) then NicIrq := 10;
      if NicIrq = 2 then NicIrq := 9;
    end
    else if Copy(S, 1, 3) = '/P:' then
    begin
      Val('$' + Copy(S, 4, 4), NicBase, Code);
      if (Code <> 0) or (NicBase < $200) or (NicBase > $3E0) then NicBase := $300;
    end;
  end;

  { isolate every card, trying READ_DATA ports until one works }
  Cards := 0;
  for N := 0 to 3 do
  begin
    ReadPort := Ports[N];
    Key;
    WReg($02, $04);                     { reset every CSN }
    Wait(2000);
    Key;
    Cards := 0;
    while Cards < MAXCARDS do
    begin
      WReg($03, 0);                     { Wake[0]: cards with no CSN isolate }
      WReg($00, ReadPort shr 2);        { the READ_DATA port }
      if not Isolate(Cards + 1) then Break;
      Inc(Cards);
      WReg($06, Cards);                 { its card select number }
    end;
    if Cards > 0 then Break;
  end;

  Pick := 0;
  Count := 0;
  for N := 1 to Cards do
  begin
    Say('PnP card ' + Chr(48 + N) + ': ' + Vendor(N) + '  serial ' +
        Hex(Ids[N, 7], 2) + Hex(Ids[N, 6], 2) + Hex(Ids[N, 5], 2) + Hex(Ids[N, 4], 2) +
        '  (READ_DATA ' + Hex(ReadPort, 3) + 'h)');
    WReg($03, N);                       { Wake[N]: into Config state }
    ReadResources;
    ListDevices;
    if Want <> '' then
    begin
      if Copy(Vendor(N), 1, Length(Want)) = Want then
      begin
        Inc(Count);
        if Pick = 0 then Pick := N;
      end;
    end
    else if Copy(Vendor(N), 1, 3) <> 'CTL' then
    begin
      Inc(Count);
      if Pick = 0 then Pick := N;
    end;
  end;
  if Cards = 0 then Say('no Plug-and-Play card answered isolation');

  if ListOnly then
  begin
    WReg($02, $02);                     { everyone back to Wait-for-Key }
    Halt(0);
  end;
  if Pick = 0 then
  begin
    WReg($02, $02);
    WriteLn('PNPNIC: no Plug-and-Play network card found (PNPNIC /L lists them)');
    Halt(1);
  end;
  if Count > 1 then
  begin
    WReg($02, $02);
    WriteLn('PNPNIC: more than one card could be it -- name one with /C:id (PNPNIC /L)');
    Halt(3);
  end;

  WReg($03, Pick);                      { Wake: Config state }
  WReg($07, Dev);                       { the logical device }
  WReg($30, 0);                         { off while it changes }
  WReg($60, Hi(NicBase));               { I/O descriptor 0 }
  WReg($61, Lo(NicBase));
  WReg($70, NicIrq);                    { IRQ descriptor 0 }
  WReg($71, 2);                         { edge, high: an ISA card's }
  WReg($30, 1);                         { on }
  WReg($02, $02);                       { Wait-for-Key }
  Wait(2000);

  if not Ne2000(NicBase) then
  begin
    WriteLn('PNPNIC: ', Vendor(Pick), ' set to ', Hex(NicBase, 3), 'h IRQ ', NicIrq,
            ', but no NE2000 answers there');
    Halt(2);
  end;
  if Quiet then
    WriteLn('PNPNIC: ', Vendor(Pick), ' at ', Hex(NicBase, 3), 'h IRQ ', NicIrq, ', NE2000 answers')
  else
  begin
    WriteLn('woke ', Vendor(Pick), ' (logical device ', Dev, ') at ', Hex(NicBase, 3), 'h IRQ ', NicIrq,
            ': the NE2000 answers');
    WriteLn('the packet driver line:  C:\DRIVERS\DE22XPD.COM 0x60 0x', Hex(NicBase, 3), ' ', NicIrq);
  end;
end.
