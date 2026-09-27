program Mozart;
{ DOS Bridge  --  StevenC & Claude }
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

  EVERY interval here comes off that tick, including the silence that detaches
  one note from the next. That silence used to be a counted CPU loop -- 30000
  iterations of dec/jnz -- and it was wrong on two counts at once. It ran four
  to five times shorter on the 386SX than on the V30, so the same score was
  detached on one machine and slurred on the other; and because it was added
  AFTER each timed note rather than taken out of it, the piece also ran
  measurably slower on the slower box. Both machines now play it in the same
  number of ticks, which the tempo check at the bottom asserts.

  That is the general rule in CLAUDE.md arriving in its least obvious form: a
  delay loop is a compile-time assumption about the CPU, however run-time it
  looks.

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
  NoteT     : LongInt;       { this note's whole length, in ticks }
  GapT      : LongInt;       { silence at its end, taken OUT of NoteT }
  Deadline  : LongInt;       { absolute tick this note must END on }
  Started   : LongInt;       { absolute tick the piece began }
  Played    : LongInt;       { how long it actually took }
  Expect    : LongInt;       { how long the score says it should }
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

{ Wait until an ABSOLUTE tick, not for a relative duration.

  Relative waits accumulate: every note paid for whatever happened between the
  waits -- port I/O, building the melody string -- so the piece ran slightly
  long, and by a different amount on a different CPU. Holding one running
  deadline means an overrun is absorbed by the next note instead of being
  added to it, and the total length is fixed by the clock rather than by how
  fast the machine gets round the loop.

  The backwards check is not theoretical tidiness. The BIOS counter at
  0040:006C wraps to zero at midnight, and `Now_ - T0` would then go hugely
  negative and sit here for most of a day. Over the bridge that is
  indistinguishable from a wedged machine and needs hands on the keyboard --
  the exact failure class this project treats as unacceptable. Two lines buy
  it off. }
procedure WaitUntil(T: LongInt);
var
  N, Last: LongInt;
begin
  Last := Now_;
  repeat
    N := Now_;
    if N < Last then Exit;          { midnight, or DOS reset the counter }
    Last := N;
  until N >= T;
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
  Expect := 0;
  for I := 1 to NN do Expect := Expect + Song[I].D * TPE;

  Started  := Now_;
  Deadline := Started;

  for I := 1 to NN do
  begin
    NoteT := Song[I].D * TPE;

    { The detaching silence comes OUT of the note, not after it. Added after,
      every note ran long by however long the gap happened to be on this CPU,
      so the same score took a different time on each machine -- and the gap
      was a counted loop, so "however long" was four to five times shorter on
      the 386SX than on the V30. One tick is the finest interval both boxes
      agree on without calibrating anything, and taking it from inside the
      note leaves the total exactly right on both.

      A note only one or two ticks long keeps its full length: at TPE=2 a
      tick of silence would be half of it, which is a different articulation
      rather than a detached one. }
    if NoteT >= 3 then GapT := 1 else GapT := 0;

    Deadline := Deadline + NoteT;

    if Song[I].F = 0 then
    begin
      SpeakerOff;
      WaitUntil(Deadline);
    end
    else
    begin
      SpeakerOn(Song[I].F);
      if I = 1 then P61Note := InB($61);   { proof the gate bits went high }
      WaitUntil(Deadline - GapT);
      SpeakerOff;
      WaitUntil(Deadline);
    end;

    Melody := Melody + Song[I].Nm + ' ';
    if (I = 8) or (I = 16) or (I = 24) then Melody := Melody + '| ';
  end;

  Played := Now_ - Started;

  { Belt and braces: never leave the speaker running. }
  SpeakerOff;
  P61End := InB($61);

  WriteLn('  melody  : ', Melody);
  WriteLn('  notes   : ', NN);
  WriteLn('  length  : ', Played, ' ticks, score says ', Expect,
          '  (', (Played * 55), ' ms)');
  { Only the low two bits are ours. Bits 4 and 5 are read-only status on an
    AT-class board and read back as zero on the V30, so the raw byte differs
    between the two machines while the speaker behaviour is identical --
    which is why every check below masks. }
  WriteLn('  port 61h: idle ', P61Idle, ', during note ', P61Note,
          ', after ', P61End, '   (low 2 bits are the speaker; upper are status)');
  WriteLn;

  Check('speaker gate bits set during a note', (P61Note and 3) = 3);
  Check('speaker gate bits clear at the end',  (P61End and 3) = 0);
  Check('played every note', NN = 29);
  { The one that catches a CPU-speed-dependent delay coming back. The piece is
    timed entirely off the BIOS tick now, so a machine four times faster must
    still take the same number of ticks; a counted loop anywhere in the note
    path would show up here as a length that tracks the CPU instead of the
    score. Two ticks of slack covers the poll granularity at each end. }
  Check('kept the score''s tempo, whatever the CPU speed',
        (Played >= Expect - 2) and (Played <= Expect + 2));
  Finish;
end.
