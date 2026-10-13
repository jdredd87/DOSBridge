{ NICSCAN -- find an NE2000-style ISA network card wherever its EEPROM put
  it: its I/O address, its station (MAC) address and its IRQ.
  Written by StevenC and Claude (Anthropic), 2026-10-13.

    NICSCAN [/Q]

  For p3box's D-Link DE-220PCT rev D2 (DLT-2518): not Plug and Play
  (PNPNIC found no card) and D-Link's SETUP said "not found or I/O
  conflict" -- so it is in jumperless mode, at an address and IRQ kept in
  its 93LC56 EEPROM.  This looks at every address an ISA network card can
  have, 200h to 3E0h in steps of 20h:

  * the NE2000 test Linux's ne.c makes: page 1's MAR5 written, page 0's
    tally counter read back -- an 8390 clears it on read, anything else
    does not -- and what it wrote is put back when the answer is no;
  * where it is an 8390: a reset, and the 32-byte station address PROM read
    through remote DMA (word mode, then byte mode) -- D-Link's start
    00 80 C8;
  * its IRQ: the card's remote-DMA-complete interrupt enabled for one
    zero-length transfer, with the PICs' request registers read before and
    after, interrupts off -- the line that went up is the card's;
  * any address that is not FFh but is not an 8390 is listed too: something
    else lives there, the "I/O conflict" D-Link's SETUP warns of.

  Every wait is bounded.  It prints the packet driver line to use.
  Exit code: the number of NE2000 cards found (0: none). }

program NicScan;

{$MODE OBJFPC}{$H-}

uses About, Dos;

var
  Quiet: Boolean;
  Found: Integer;

function Hex(V: LongInt; N: Integer): ShortString;
begin
  Hex := HexStr(V, N);
end;

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

{ Linux ne.c's test: an 8390's tally counter clears when read }
function Is8390(Base: Word): Boolean;
var
  Reg0, RegD: Byte;
begin
  Is8390 := False;
  Reg0 := Port[Base];
  if Reg0 = $FF then Exit;
  Port[Base] := $61;                    { page 1, no DMA, stop }
  RegD := Port[Base + $0D];
  Port[Base + $0D] := $FF;
  Port[Base] := $20;                    { page 0, no DMA }
  if Port[Base + $0D] = 0 then          { read once: it clears ... }
    ;
  if Port[Base + $0D] <> 0 then         { ... so now it must read 0 }
  begin
    Port[Base] := Reg0;                 { not ours: put back what we did }
    Port[Base + $0D] := RegD;
    Exit;
  end;
  Is8390 := True;
end;

procedure Reset8390(Base: Word);
var
  B: Byte;
  T: LongInt;
begin
  B := Port[Base + $1F];
  Port[Base + $1F] := B;
  T := 20000;
  while ((Port[Base + $07] and $80) = 0) and (T > 0) do Dec(T);
  Port[Base + $07] := $FF;
end;

{ the station address PROM, 32 bytes through remote DMA }
procedure ReadProm(Base: Word; WordMode: Boolean; var P: array of Byte);
var
  I: Integer;
  W: Word;
begin
  Port[Base] := $21;                    { page 0, no DMA, stop }
  if WordMode then Port[Base + $0E] := $49 else Port[Base + $0E] := $48;
  Port[Base + $0A] := 0; Port[Base + $0B] := 0;   { count 0 }
  Port[Base + $0F] := 0;                { mask every interrupt }
  Port[Base + $07] := $FF;
  Port[Base + $0C] := $20;              { monitor mode }
  Port[Base + $0D] := $02;              { loopback }
  Port[Base + $0A] := 32; Port[Base + $0B] := 0;  { 32 bytes }
  Port[Base + $08] := 0;  Port[Base + $09] := 0;  { from 0 }
  Port[Base] := $0A;                    { remote read, start }
  if WordMode then
    for I := 0 to 15 do
    begin
      W := PortW[Base + $10];
      P[2 * I] := Lo(W);
      P[2 * I + 1] := Hi(W);
    end
  else
    for I := 0 to 31 do P[I] := Port[Base + $10];
  Port[Base + $07] := $FF;
end;

function MacOf(const P: array of Byte; Doubled: Boolean): ShortString;
var
  I: Integer;
  S: ShortString;
begin
  S := '';
  for I := 0 to 5 do
  begin
    if Doubled then S := S + Hex(P[2 * I], 2) else S := S + Hex(P[I], 2);
    if I < 5 then S := S + '-';
  end;
  MacOf := S;
end;

{ the PICs' interrupt request registers, as one 16-bit mask }
function Irr: Word;
var
  A, B: Byte;
begin
  Port[$20] := $0A; A := Port[$20];
  Port[$A0] := $0A; B := Port[$A0];
  Irr := A or (B shl 8);
end;

{ the card's IRQ: one remote-DMA-complete interrupt, seen in the PICs }
function FindIrq(Base: Word): Integer;
var
  Before, After, New: Word;
  I: Integer;
  T: LongInt;
begin
  FindIrq := -1;
  asm cli end;
  Port[Base] := $22;                    { page 0, no DMA, start }
  Port[Base + $07] := $FF;
  Port[Base + $0F] := $40;              { only remote DMA complete }
  Before := Irr;
  Port[Base + $0A] := 0; Port[Base + $0B] := 0;
  Port[Base + $08] := 0; Port[Base + $09] := 0;
  Port[Base] := $0A;                    { remote read of 0 bytes: done at once }
  T := 5000;
  while ((Port[Base + $07] and $40) = 0) and (T > 0) do Dec(T);
  Wait(100);
  After := Irr;
  Port[Base + $0F] := 0;                { mask it again }
  Port[Base + $07] := $FF;              { and acknowledge it }
  Port[Base] := $21;                    { stop }
  asm sti end;
  New := After and not Before;
  New := New and not $0005;             { the timer and the cascade are not it }
  for I := 0 to 15 do
    if (New and (1 shl I)) <> 0 then
    begin
      FindIrq := I;
      Exit;
    end;
end;

var
  Base: Word;
  I, Irq: Integer;
  S: ShortString;
  P: array[0..31] of Byte;
  Others: ShortString;
  Doubled, Dlink: Boolean;
begin
  for I := 1 to ParamCount do
  begin
    S := ParamStr(I);
    if (S = '/Q') or (S = '/q') then Quiet := True;
  end;
  Found := 0;
  Others := '';
  Base := $200;
  while Base <= $3E0 do
  begin
    if Is8390(Base) then
    begin
      Inc(Found);
      Reset8390(Base);
      ReadProm(Base, True, P);
      Doubled := (P[0] = P[1]) and (P[2] = P[3]) and (P[4] = P[5]);
      if not Doubled and (P[0] = $FF) then  { an 8-bit card: byte mode }
      begin
        ReadProm(Base, False, P);
        Doubled := (P[0] = P[1]) and (P[2] = P[3]);
      end;
      Irq := FindIrq(Base);
      Dlink := Doubled and (P[0] = $00) and (P[2] = $80) and (P[4] = $C8);
      WriteLn('NE2000 at ', Hex(Base, 3), 'h  MAC ', MacOf(P, Doubled), '  IRQ ', Irq);
      if Dlink then WriteLn('  a D-Link card (00-80-C8)');
      if Irq < 0 then
        WriteLn('  its IRQ did not show: none set, or another card holds the line')
      else
        WriteLn('  packet driver:  C:\DRIVERS\DE22XPD.COM 0x60 0x', Hex(Base, 3), ' ', Irq);
    end
    else if Port[Base] <> $FF then
      Others := Others + ' ' + Hex(Base, 3) + 'h';
    Inc(Base, $20);
  end;
  if Found = 0 then WriteLn('no NE2000 card answered at 200h to 3E0h');
  if not Quiet and (Others <> '') then
    WriteLn('something else answers at:', Others);
  Halt(Found);
end.
