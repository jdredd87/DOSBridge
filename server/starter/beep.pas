program Beep;
{ DOS Bridge  --  StevenC }
{ Make the DOS machine ask for a human.

  Usage:  BEEP                    one 880 Hz note
          BEEP freq ticks         one note: Hz, and length in 55ms ticks
          BEEP freq ticks count   repeat it
          BEEP ALERT              distinctive rising three-note "look at me"
          BEEP DONE               falling two-note "finished"

  Why this exists: several tools need somebody at the keyboard at a specific
  moment -- move the mouse, press a key -- and a message on the Windows side is
  useless if nobody is watching that window. The machine that needs the human is
  the one that should do the asking.

  Compose it around anything:
      dosexec "BEEP ALERT" "MOUSE 15" "BEEP DONE"

  Speaker programming is PIT channel 2 gated onto port 61h: write the mode to
  43h, the divisor to 42h, then set the low two bits of 61h to connect the
  timer output to the speaker. Clearing those bits silences it -- and it must
  be cleared on every exit path, or the machine is left screaming. }

{$MODE OBJFPC}{$H-}
{$ASMMODE INTEL}


uses About;

const
  PIT_FREQ = 1193180;      { the 8253/8254 input clock }

var
  Freq, Ticks_, Count : LongInt;
  Code                : Integer;
  A                   : ShortString;
  I                   : Integer;

function Now_: LongInt;
begin
  Now_ := MemL[$0040:$006C];
end;

procedure OutB(P: Word; V: Byte);
begin
  asm
    mov dx, P
    mov al, V
    out dx, al
  end;
end;

function InB(P: Word): Byte;
var V: Byte;
begin
  asm
    mov dx, P
    in  al, dx
    mov V, al
  end;
  InB := V;
end;

procedure SpeakerOn(F: LongInt);
var
  Divisor: Word;
  P61: Byte;
begin
  if F < 20 then F := 20;
  if F > 20000 then F := 20000;
  Divisor := Word(PIT_FREQ div F);

  OutB($43, $B6);                        { channel 2, mode 3, square wave }
  OutB($42, Byte(Divisor and $FF));
  OutB($42, Byte((Divisor shr 8) and $FF));

  P61 := InB($61);
  OutB($61, P61 or 3);                   { gate the timer, connect the speaker }
end;

procedure SpeakerOff;
var
  P61: Byte;
begin
  P61 := InB($61);
  OutB($61, P61 and $FC);
end;

procedure Wait(T: LongInt);
var
  T0: LongInt;
begin
  T0 := Now_;
  while (Now_ - T0) < T do ;
end;

procedure Note(F, T: LongInt);
begin
  SpeakerOn(F);
  Wait(T);
  SpeakerOff;
end;

begin
  Freq   := 880;
  Ticks_ := 3;
  Count  := 1;

  if ParamCount >= 1 then
  begin
    A := ParamStr(1);
    if (A = 'ALERT') or (A = 'alert') then
    begin
      { A siren, not a chirp. The first version was a 440ms rising triad and
        went unnoticed by someone not already watching -- which is precisely
        the case this exists for. Six alternations plus a held note runs about
        a second and a half and is hard to miss. }
      for I := 1 to 6 do
      begin
        Note(660, 2);
        Note(1320, 2);
      end;
      Note(1760, 5);
      SpeakerOff;
      WriteLn('BEEP: alert');
      Halt(0);
    end;
    if (A = 'DONE') or (A = 'done') then
    begin
      Note(1320, 3); Note(990, 3); Note(660, 5);
      SpeakerOff;
      WriteLn('BEEP: done');
      Halt(0);
    end;
    if (A = '/D') or (A = '/d') then
    begin
      WriteLn('=== beep diagnostic ===');
      WriteLn('  port 61h before  : ', InB($61));
      SpeakerOn(880);
      WriteLn('  port 61h during  : ', InB($61),
              '   (low two bits must be set)');
      WriteLn('  holding 880 Hz for about 2 seconds...');
      Wait(36);
      SpeakerOff;
      WriteLn('  port 61h after   : ', InB($61));
      WriteLn;
      WriteLn('  now three BIOS beeps via INT 10h AH=0Eh, AL=7.');
      WriteLn('  That path goes through the ROM rather than the ports,');
      WriteLn('  so if these sound and the tone above did not, the fault');
      WriteLn('  is in this program. If neither sounds, the speaker is');
      WriteLn('  not connected.');
      for I := 1 to 3 do
      begin
        asm
          mov ah, 0Eh
          mov al, 7
          xor bx, bx
          int 10h
        end;
        Wait(6);
      end;
      SpeakerOff;
      WriteLn('  done');
      Halt(0);
    end;
    Val(A, Freq, Code);
    if (Code <> 0) or (Freq < 20) or (Freq > 20000) then Freq := 880;
  end;

  if ParamCount >= 2 then
  begin
    Val(ParamStr(2), Ticks_, Code);
    if (Code <> 0) or (Ticks_ < 1) or (Ticks_ > 90) then Ticks_ := 3;
  end;

  if ParamCount >= 3 then
  begin
    Val(ParamStr(3), Count, Code);
    if (Code <> 0) or (Count < 1) or (Count > 20) then Count := 1;
  end;

  for I := 1 to Count do
  begin
    Note(Freq, Ticks_);
    if I < Count then Wait(2);
  end;

  { Belt and braces: never leave the speaker running. }
  SpeakerOff;

  WriteLn('BEEP: ', Freq, ' Hz, ', Ticks_, ' ticks, x', Count);
end.
