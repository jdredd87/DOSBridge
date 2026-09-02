unit Prof;
{ DOS Bridge  --  StevenC }
{ Section timing and stack high-water marking for programs on the DOS machine.

  Add `uses Prof;` then:

      ProfStart;
      ... work ...            Mark('build');
      ... more work ...       Mark('paint');
      ProfReport;

  Why this exists: finding the slow part of the SVGA demo meant compiling two
  cut-down copies of the whole program and running each for five seconds, twice,
  because BIOS ticks at 18.2 Hz cannot resolve anything finer than 55ms. That is
  a lot of ceremony to learn one fact.

  Resolution comes from reading PIT channel 0 directly. It counts down from
  65536 at 1193180 Hz, so latching it and combining with the BIOS tick gives a
  timestamp good to about 0.84 microseconds -- roughly 65000 times finer than
  the tick alone.

  The stack watermark exists because a recursive walker with a 12KB stack frame
  silently overflowed and hung the machine. DOS has no stack guard and gives no
  warning; the only signal is the machine stopping. Mark() records the stack
  pointer each time it is called, so a run that survives still reports how close
  it came. }

{$MODE OBJFPC}{$H-}
{$ASMMODE INTEL}

interface

procedure ProfStart;
procedure Mark(const Name: ShortString);
procedure ProfReport;

implementation

const
  MAXMARK = 24;

type
  TSlot = record
    Name  : String[16];
    Total : LongInt;      { accumulated PIT units }
    Hits  : LongInt;
    MinSP : Word;
  end;

var
  Slots   : array[1..MAXMARK] of TSlot;
  NSlots  : Integer;
  LastT   : LongInt;
  StartT  : LongInt;
  StartSP : Word;
  Active  : Boolean;

function GetSP: Word;
var
  V: Word;
begin
  asm
    mov V, sp
  end;
  GetSP := V;
end;

{ Latch and read PIT channel 0, then fold in the BIOS tick.

  The counter runs down, so it is inverted to make time increase. The tick is
  re-read after the latch and the result recomputed if it moved, because a tick
  landing between the two reads would otherwise pair a new tick with an old
  counter and jump the clock by a whole 55ms. }
function HiRes: LongInt;
var
  Lo, Hi   : Byte;
  Cnt      : Word;
  T1, T2   : LongInt;
begin
  { Retry until no tick boundary falls between the two tick reads. Taking one
    reading and patching it up afterwards is not enough: the counter runs down
    and wraps, so pairing a post-wrap counter with a pre-wrap tick makes time
    run backwards. That produced a negative section time on the first run. }
  repeat
    T1 := MemL[$0040:$006C];
    asm
      cli
      mov al, 0            { latch counter 0 }
      out 43h, al
      in  al, 40h
      mov Lo, al
      in  al, 40h
      mov Hi, al
      sti
    end;
    T2 := MemL[$0040:$006C];
  until T1 = T2;
  Cnt := (Word(Hi) shl 8) or Lo;
  HiRes := (T1 shl 16) or LongInt(65535 - Cnt);
end;

procedure ProfStart;
var
  I: Integer;
begin
  NSlots := 0;
  for I := 1 to MAXMARK do
  begin
    Slots[I].Name  := '';
    Slots[I].Total := 0;
    Slots[I].Hits  := 0;
    Slots[I].MinSP := $FFFF;
  end;
  StartSP := GetSP;
  StartT  := HiRes;
  LastT   := StartT;
  Active  := True;
end;

procedure Mark(const Name: ShortString);
var
  I, Slot: Integer;
  Now_   : LongInt;
  Delta  : LongInt;
  SP     : Word;
begin
  if not Active then Exit;
  Now_ := HiRes;
  SP   := GetSP;

  Slot := 0;
  for I := 1 to NSlots do
    if Slots[I].Name = Name then
    begin
      Slot := I;
      Break;
    end;

  if Slot = 0 then
  begin
    if NSlots >= MAXMARK then
    begin
      LastT := Now_;
      Exit;
    end;
    Inc(NSlots);
    Slot := NSlots;
    Slots[Slot].Name := Copy(Name, 1, 16);
  end;

  { The counter can wrap fractionally before the BIOS ISR bumps the tick, so a
    delta may still come out slightly negative. The error is at most one tick,
    so that is exactly what gets added back. }
  Delta := Now_ - LastT;
  if Delta < 0 then Inc(Delta, 65536);
  Inc(Slots[Slot].Total, Delta);
  Inc(Slots[Slot].Hits);
  if SP < Slots[Slot].MinSP then Slots[Slot].MinSP := SP;

  LastT := Now_;
end;

procedure ProfReport;
var
  I      : Integer;
  Total  : LongInt;
  Us     : LongInt;
  Pct    : LongInt;
  Deepest: Word;
begin
  Total := HiRes - StartT;
  if Total <= 0 then Total := 1;

  WriteLn;
  WriteLn('=== prof ===');
  WriteLn('  section            calls        usec     %   deepest stack');

  Deepest := StartSP;
  for I := 1 to NSlots do
  begin
    { PIT units are 1/1193180 sec. Multiplying by 1000000 would overflow, so
      scale down first: one unit is very close to 0.838 usec, and 27/32 is
      0.84375 -- close enough for apportioning blame, and it cannot overflow. }
    Us  := (Slots[I].Total div 32) * 27;
    Pct := (Slots[I].Total div (Total div 100 + 1));
    if Slots[I].MinSP < Deepest then Deepest := Slots[I].MinSP;
    WriteLn('  ', Slots[I].Name, '':(18 - Length(Slots[I].Name)),
            Slots[I].Hits:6, Us:12, Pct:6, '   ',
            (StartSP - Slots[I].MinSP):6, ' bytes');
  end;

  WriteLn;
  WriteLn('  total elapsed    : ', (Total div 32) * 27, ' usec');
  WriteLn('  stack used       : ', StartSP - Deepest,
          ' bytes below entry SP (', StartSP, ' -> ', Deepest, ')');
  WriteLn('  NOTE: stack figures are sampled at Mark() only, so a deeper');
  WriteLn('        excursion between marks will not appear here.');
end;

end.
