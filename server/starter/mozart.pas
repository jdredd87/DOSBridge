program Mozart;
{ DOS Bridge  --  StevenC }
{ The opening of Mozart's Eine kleine Nachtmusik (K. 525, first movement)
  played on the PC speaker.

  Speaker programming, same as beep.pas: write mode $B6 to port $43 (PIT
  channel 2, mode 3, square wave), the frequency divisor to $42, then set the
  low two bits of port $61 to gate the timer onto the speaker. Clearing those
  bits silences it -- and that MUST happen on every exit path or the machine is
  left screaming.

  Timing is in BIOS ticks (18.2 Hz, ~55 ms). An eighth note is TPE ticks;
  TPE = 4 gives quarter = 220 ms, about crotchet = 136, a fair Allegro. Pass a
  different TPE as the first argument (2..16) to slow it down or speed it up.

  The melody is monophonic -- the PC speaker can only sound one frequency at a
  time -- so this is the first violin line only:

    G D G D  G B D B   (x2, the "rocket")
    C A C A  C A F# A   (the answer)
    D C B A  G           (a scale down to the tonic to round it off)

  It reports what it played with WriteLn -- nothing draws to the screen -- and
  the exit code is the Tester failure count: 0 means the speaker gate bits were
  seen to toggle on during a note and off again at the end. }

{$MODE OBJFPC}{$H-}
{$ASMMODE INTEL}

uses Tester, About;

const
  PIT_FREQ = 1193180;        { the 8253/8254 input clock }

  { Equal temperament, A4 = 440. Octave 4-5, the register Mozart wrote it in. }
  D4  = 294;
  FS4 = 370;
  G4  = 392;
  A4  = 440;
  B4  = 494;
  C5  = 523;
  D5  = 587;

type
  TNote = record
    Nm : String[3];          { for the printed melody line }
    F  : Word;               { Hz, or 0 for a rest }
    D  : Byte;               { length in eighth notes }
  end;

const
  NN = 29;
  Song: array[1 .. NN] of TNote = (
    { rocket, bars 1-2 }
    (Nm:'G4 '; F:G4;  D:1), (Nm:'D4 '; F:D4;  D:1),
    (Nm:'G4 '; F:G4;  D:1), (Nm:'D4 '; F:D4;  D:1),
    (Nm:'G4 '; F:G4;  D:1), (Nm:'B4 '; F:B4;  D:1),
    (Nm:'D5 '; F:D5;  D:1), (Nm:'B4 '; F:B4;  D:1),
    { rocket again, bars 3-4 }
    (Nm:'G4 '; F:G4;  D:1), (Nm:'D4 '; F:D4;  D:1),
    (Nm:'G4 '; F:G4;  D:1), (Nm:'D4 '; F:D4;  D:1),
    (Nm:'G4 '; F:G4;  D:1), (Nm:'B4 '; F:B4;  D:1),
    (Nm:'D5 '; F:D5;  D:1), (Nm:'B4 '; F:B4;  D:1),
    { the answer, bars 5-6 }
    (Nm:'C5 '; F:C5;  D:1), (Nm:'A4 '; F:A4;  D:1),
    (Nm:'C5 '; F:C5;  D:1), (Nm:'A4 '; F:A4;  D:1),
    (Nm:'C5 '; F:C5;  D:1), (Nm:'A4 '; F:A4;  D:1),
    (Nm:'F#4'; F:FS4; D:1), (Nm:'A4 '; F:A4;  D:1),
    { scale down to the tonic }
    (Nm:'D5 '; F:D5;  D:2), (Nm:'C5 '; F:C5;  D:1),
    (Nm:'B4 '; F:B4;  D:1), (Nm:'A4 '; F:A4;  D:1),
    (Nm:'G4 '; F:G4;  D:4));

var
  TPE       : LongInt;       { ticks per eighth note }
  Code      : Integer;
  I         : Integer;
  Ticks_    : LongInt;
  P61Idle   : Byte;
  P61Note   : Byte;
  P61End    : Byte;
  Melody    : String;

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

procedure SpeakerOn(Freq: LongInt);
var
  Divisor: Word;
  P61: Byte;
begin
  if Freq < 20 then Freq := 20;
  if Freq > 20000 then Freq := 20000;
  Divisor := Word(PIT_FREQ div Freq);

  OutB($43, $B6);
  OutB($42, Byte(Divisor and $FF));
  OutB($42, Byte((Divisor shr 8) and $FF));

  P61 := InB($61);
  OutB($61, P61 or 3);
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

{ A short silence between notes so a phrase is detached, not slurred. Busy loop
  rather than a BIOS tick because one tick (55 ms) would be most of an eighth. }
procedure Gap;
begin
  asm
    mov cx, 30000
  @@l:
    dec cx
    jnz @@l
  end;
end;

begin
  TPE := 4;
  if ParamCount >= 1 then
  begin
    Val(ParamStr(1), TPE, Code);
    if (Code <> 0) or (TPE < 2) or (TPE > 16) then TPE := 4;
  end;

  WriteLn('=== Mozart, Eine kleine Nachtmusik K.525 (opening) -- PC speaker ===');
  WriteLn('  voice   : first violin line only (the speaker is monophonic)');
  WriteLn('  tempo   : ', TPE, ' ticks/eighth  (quarter ~= ', (TPE * 2 * 55), ' ms)');

  P61Idle := InB($61);

  Melody := '';
  for I := 1 to NN do
  begin
    Ticks_ := Song[I].D * TPE;

    if Song[I].F = 0 then
    begin
      SpeakerOff;
      Wait(Ticks_);
    end
    else
    begin
      SpeakerOn(Song[I].F);
      if I = 1 then P61Note := InB($61);   { proof the gate bits went high }
      Wait(Ticks_);
      SpeakerOff;
    end;

    Gap;

    Melody := Melody + Song[I].Nm + ' ';
    if (I = 8) or (I = 16) or (I = 24) then Melody := Melody + '| ';
  end;

  { Belt and braces: never leave the speaker running. }
  SpeakerOff;
  P61End := InB($61);

  WriteLn('  melody  : ', Melody);
  WriteLn('  notes   : ', NN);
  WriteLn('  port 61h: idle ', P61Idle, ', during note ', P61Note,
          ', after ', P61End);
  WriteLn;

  Check('speaker gate bits set during a note', (P61Note and 3) = 3);
  Check('speaker gate bits clear at the end',  (P61End and 3) = 0);
  Check('played every note', NN = 29);
  Finish;
end.
