{ SNDPROBE -- is there a Sound Blaster, and an OPL (AdLib) FM chip, without
  touching the network card.  Written by StevenC and Claude (Anthropic),
  2026-10-13, for p3box's onboard sound.

    SNDPROBE [/P:hhh]

  The Sound Blaster DSP's reset (base+6: 1, wait, 0; then AAh at base+Ah)
  at 220h, 260h and 280h -- NOT 240h, p3box's D-Link card -- or only at
  /P:hhh; its version (DSP command E1h) if one answers.  Then the AdLib
  test at 388h: the two timers stopped and reset, timer 1 started, its
  overflow bit seen in the status register.  And the BLASTER variable.
  Every wait is bounded.  Exit code: 1 a DSP answered, 2 the OPL answered,
  3 both, 0 neither. }

program SndProbe;

{$MODE OBJFPC}{$H-}

uses About, Dos;

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

function DspReset(Base: Word): Boolean;
var
  T: LongInt;
begin
  DspReset := False;
  Port[Base + 6] := 1;
  Wait(10);
  Port[Base + 6] := 0;
  T := 2000;
  while ((Port[Base + $E] and $80) = 0) and (T > 0) do Dec(T);
  if T = 0 then Exit;
  DspReset := Port[Base + $A] = $AA;
end;

procedure DspWrite(Base: Word; V: Byte);
var
  T: LongInt;
begin
  T := 20000;
  while ((Port[Base + $C] and $80) <> 0) and (T > 0) do Dec(T);
  Port[Base + $C] := V;
end;

function DspRead(Base: Word): Integer;
var
  T: LongInt;
begin
  T := 20000;
  while ((Port[Base + $E] and $80) = 0) and (T > 0) do Dec(T);
  if T = 0 then DspRead := -1 else DspRead := Port[Base + $A];
end;

procedure Opl(R, V: Byte);
begin
  Port[$388] := R; Wait(6);
  Port[$389] := V; Wait(35);
end;

function OplThere: Boolean;
var
  S1, S2: Byte;
begin
  Opl($04, $60);                        { both timers off, flags reset }
  Opl($04, $80);
  S1 := Port[$388];
  Opl($02, $FF);                        { timer 1 to overflow at once }
  Opl($04, $21);                        { start timer 1 }
  Wait(200);
  S2 := Port[$388];
  Opl($04, $60);
  Opl($04, $80);
  OplThere := ((S1 and $E0) = 0) and ((S2 and $E0) = $C0);
end;

{ /T: a silent 8-bit single-cycle DMA transfer on DMA 1, which must end in
  the card's interrupt -- PNPSB's test (projects/pnpsb), for the IRQ and the
  DMA a game's digitized sound needs.  The handler counts and acknowledges }
var
  TestIrq: Integer = 5;
  IrqCount: Word;
  DspBase: Word;
  OldVec: FarPointer;
  DmaBuf: array[0..1023] of Byte;

procedure SbIsr; interrupt;
var
  B: Byte;
begin
  Inc(IrqCount);
  B := Port[DspBase + $E];              { acknowledge 8-bit }
  if TestIrq >= 8 then Port[$A0] := $20;
  Port[$20] := $20;
end;

function TestTransfer(Base: Word; var Left: Word): Boolean;
var
  Lin, T: LongInt;
  Page, Off, Len: Word;
  Mask, Mask2, Vec: Byte;
  P: PByte;
begin
  DspBase := Base;
  if TestIrq >= 8 then Vec := $70 + TestIrq - 8 else Vec := 8 + TestIrq;
  P := @DmaBuf[0];
  Lin := LongInt(Seg(P^)) * 16 + Ofs(P^);
  if ((Lin and $FFFF) + 256) > $10000 then Lin := Lin + 512;   { past a page edge }
  FillChar(DmaBuf, SizeOf(DmaBuf), $80);
  Page := Lin shr 16;
  Off := Lin and $FFFF;
  Len := 256 - 1;
  IrqCount := 0;
  GetIntVec(Vec, OldVec);
  SetIntVec(Vec, @SbIsr);
  Mask := Port[$21];
  Mask2 := Port[$A1];
  if TestIrq >= 8 then
  begin
    Port[$A1] := Mask2 and not (1 shl (TestIrq - 8));
    Port[$21] := Mask and not 4;
  end
  else
    Port[$21] := Mask and not (1 shl TestIrq);
  Port[$0A] := $05;                     { DMA 1: mask, flip-flop, mode, address, page, count }
  Port[$0C] := 0;
  Port[$0B] := $49;
  Port[$02] := Lo(Off); Port[$02] := Hi(Off);
  Port[$83] := Page;
  Port[$03] := Lo(Len); Port[$03] := Hi(Len);
  Port[$0A] := $01;
  DspWrite(Base, $D3);                  { speaker off: it is silence anyway }
  DspWrite(Base, $40); DspWrite(Base, 256 - 1000000 div 22050);
  DspWrite(Base, $14); DspWrite(Base, Lo(Len)); DspWrite(Base, Hi(Len));
  T := MemL[$40:$6C];
  while (IrqCount = 0) and (MemL[$40:$6C] - T < 10) do ;
  Port[$0C] := 0;
  Left := Port[$03];
  Left := Left or (Port[$03] shl 8);
  Port[$0A] := $05;
  Port[$21] := Mask;
  Port[$A1] := Mask2;
  SetIntVec(Vec, OldVec);
  TestTransfer := IrqCount > 0;
end;

var
  Bases: array[0..2] of Word = ($220, $260, $280);
  DoTest: Boolean;
  Left: Word;
  I, N, Code, Major, Minor, Result: Integer;
  Only: Word;
  S: ShortString;
begin
  Only := 0;
  for I := 1 to ParamCount do
  begin
    S := ParamStr(I);
    for N := 1 to Length(S) do S[N] := UpCase(S[N]);
    if Copy(S, 1, 3) = '/P:' then Val('$' + Copy(S, 4, 4), Only, Code)
    else if S = '/T' then DoTest := True
    else if Copy(S, 1, 3) = '/I:' then Val(Copy(S, 4, 2), TestIrq, Code);
  end;
  Result := 0;
  S := GetEnv('BLASTER');
  if S = '' then WriteLn('BLASTER: not set') else WriteLn('BLASTER=', S);
  for I := 0 to 2 do
  begin
    if (Only <> 0) and (Bases[I] <> Only) then Continue;
    if DspReset(Bases[I]) then
    begin
      DspWrite(Bases[I], $E1);
      Major := DspRead(Bases[I]);
      Minor := DspRead(Bases[I]);
      Write('Sound Blaster DSP at ', Hex(Bases[I], 3), 'h, version ', Major, '.', Minor);
      if Major >= 4 then WriteLn('  (Sound Blaster 16 class)')
      else if Major = 3 then WriteLn('  (Sound Blaster Pro class)')
      else if Major = 2 then WriteLn('  (Sound Blaster 2.0 class)')
      else WriteLn;
      Result := Result or 1;
      if DoTest then
        if TestTransfer(Bases[I], Left) then
          WriteLn('  IRQ ', TestIrq, ' and DMA 1 proven: a silent transfer ended in the interrupt')
        else
          WriteLn('  NO interrupt on IRQ ', TestIrq, '; DMA 1 count left ', Hex(Left, 4),
                  'h (FFFFh: all 256 moved -- the DMA works; 00FFh: none moved)');
    end
    else
      WriteLn('no DSP at ', Hex(Bases[I], 3), 'h');
  end;
  if OplThere then
  begin
    WriteLn('OPL FM (AdLib) answers at 388h');
    Result := Result or 2;
  end
  else
    WriteLn('no OPL FM chip at 388h');
  Halt(Result);
end.
