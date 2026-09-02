program AMozart;
{ DOS Bridge  --  StevenC }
{ Mozart's Eine kleine Nachtmusik (K.525, first movement opening), extended and
  in two voices, played on an AdLib / OPL2 (Yamaha YM3812) card.

  Two halves to this program:

  1. DETECT the FM chip at I/O 388h (address+status) / 389h (data), by the timer
     method from the AdLib manual:
       - write 60h to register 04h  : mask timer 1 and timer 2
       - write 80h to register 04h  : reset the IRQ and the status flags
       - read 388h                  : top three bits must be 0
       - write FFh to register 02h  : preset timer 1 so it overflows in ~80 us
       - write 21h to register 04h  : unmask and start timer 1
       - wait well past 80 us
       - read 388h                  : top two bits must now be set  -> C0h
     Only that specific 00h -> C0h transition proves a real FM chip answered;
     an empty port floats and does neither.

  2. If it is there, PLAY. The PC-speaker version (mozart.pas) was one voice
     because the speaker has one. The OPL2 has nine channels, so this puts the
     first-violin line on channel 0 and a root-note bass on channel 1, and
     plays the sentence twice (the second time an octave up, the way the piece
     restates it) before a closing cadence.

  OPL2 register writes need settling time after each OUT -- a few port reads
  after the address, a few dozen after the data -- or an 8 MHz machine gets
  ahead of the chip and writes land in the wrong register. Everything is keyed
  off and every operator silenced at the end, on the single exit path, so the
  card is never left droning.

  Nothing audible survives the bridge, so it WriteLn's the melody and both
  status-register reads. Exit code is the Tester failure count. }

{$MODE OBJFPC}{$H-}
{$ASMMODE INTEL}

uses Tester, About;

const
  OPL_ADDR = $388;          { address / status port }
  OPL_DATA = $389;          { data port }

  { first-violin line, equal temperament A4 = 440, octave 4-5 }
  G4  = 392;  D4  = 294;  B4  = 494;  D5  = 587;
  C5  = 523;  A4  = 440;  FS4 = 370;
  { bass, octave 2 }
  G2  = 98;   D2  = 73;

type
  TNote = record
    Nm : String[3];         { for the printed melody line }
    F  : Word;              { melody Hz, 0 = rest }
    D  : Byte;              { length in eighth notes }
    B  : Word;              { bass root to start here, 0 = let the last one ring }
  end;

const
  { The first sentence: rocket x2, the answer, a scale down to the tonic. }
  NA = 29;
  SongA: array[1 .. NA] of TNote = (
    (Nm:'G4 '; F:G4;  D:1; B:G2), (Nm:'D4 '; F:D4;  D:1; B:0),
    (Nm:'G4 '; F:G4;  D:1; B:0),  (Nm:'D4 '; F:D4;  D:1; B:0),
    (Nm:'G4 '; F:G4;  D:1; B:G2), (Nm:'B4 '; F:B4;  D:1; B:0),
    (Nm:'D5 '; F:D5;  D:1; B:D2), (Nm:'B4 '; F:B4;  D:1; B:0),

    (Nm:'G4 '; F:G4;  D:1; B:G2), (Nm:'D4 '; F:D4;  D:1; B:0),
    (Nm:'G4 '; F:G4;  D:1; B:0),  (Nm:'D4 '; F:D4;  D:1; B:0),
    (Nm:'G4 '; F:G4;  D:1; B:G2), (Nm:'B4 '; F:B4;  D:1; B:0),
    (Nm:'D5 '; F:D5;  D:1; B:D2), (Nm:'B4 '; F:B4;  D:1; B:0),

    (Nm:'C5 '; F:C5;  D:1; B:G2), (Nm:'A4 '; F:A4;  D:1; B:0),
    (Nm:'C5 '; F:C5;  D:1; B:G2), (Nm:'A4 '; F:A4;  D:1; B:0),
    (Nm:'C5 '; F:C5;  D:1; B:G2), (Nm:'A4 '; F:A4;  D:1; B:0),
    (Nm:'F#4'; F:FS4; D:1; B:D2), (Nm:'A4 '; F:A4;  D:1; B:0),

    (Nm:'D5 '; F:D5;  D:2; B:D2), (Nm:'C5 '; F:C5;  D:1; B:0),
    (Nm:'B4 '; F:B4;  D:1; B:0),  (Nm:'A4 '; F:A4;  D:1; B:D2),
    (Nm:'G4 '; F:G4;  D:4; B:G2));

  { The button on the end: dominant, dominant, tonic. }
  NT = 5;
  SongTag: array[1 .. NT] of TNote = (
    (Nm:'A4 '; F:A4; D:2; B:D2), (Nm:'A4 '; F:A4; D:2; B:D2),
    (Nm:'D5 '; F:D5; D:2; B:D2), (Nm:'D5 '; F:D5; D:2; B:D2),
    (Nm:'G4 '; F:G4; D:4; B:G2));

var
  TPE      : LongInt;       { ticks per eighth note }
  Code     : Integer;
  St1, St2 : Byte;          { OPL status reads, idle and after the timer }
  Present  : Boolean;
  Played   : Integer;       { melody notes actually sounded }
  CurBass  : Word;          { bass note currently ringing, 0 = none }
  Melody   : String;
  I        : Integer;

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

procedure Wait(T: LongInt);
var T0: LongInt;
begin
  T0 := Now_;
  while (Now_ - T0) < T do ;
end;

{ A short detached silence between notes. Busy loop, not a BIOS tick: one tick
  (55 ms) would swallow most of an eighth. }
procedure Gap;
begin
  asm
    mov cx, 22000
  @@l:
    dec cx
    jnz @@l
  end;
end;

{ One OPL2 register write: address to 388h, settle, data to 389h, settle.
  The read-backs of 388h are the delay -- an ISA I/O read cannot go faster
  than the bus, so ~8 reads clear the >3.3 us the chip needs after an address
  and ~36 clear the >23 us it needs after data. }
procedure OplWrite(Reg, Val: Byte);
var K: Integer;
begin
  OutB(OPL_ADDR, Reg);
  for K := 1 to 8  do InB(OPL_ADDR);
  OutB(OPL_DATA, Val);
  for K := 1 to 36 do InB(OPL_ADDR);
end;

function DetectOpl: Boolean;
var K: Integer;
begin
  OplWrite($04, $60);                     { mask both timers }
  OplWrite($04, $80);                     { reset IRQ / flags }
  St1 := InB(OPL_ADDR) and $E0;
  OplWrite($02, $FF);                     { timer 1: overflow after one tick }
  OplWrite($04, $21);                     { unmask + start timer 1 }
  for K := 1 to 240 do InB(OPL_ADDR);     { comfortably past 80 us }
  St2 := InB(OPL_ADDR) and $E0;
  OplWrite($04, $60);                     { stop and mask again }
  OplWrite($04, $80);
  DetectOpl := (St1 = $00) and (St2 = $C0);
end;

{ Two 2-operator FM patches: a bright-ish lead on channel 0, a rounder bass on
  channel 1. Operator register offsets are 00h/03h for channel 0 and 01h/04h
  for channel 1 (modulator, then carrier). }
procedure OplInit;
begin
  OplWrite($01, $20);          { enable the waveform-select registers }
  OplWrite($08, $00);          { no NOTE-SEL / CSW }
  OplWrite($BD, $00);          { melodic mode, no deep vibrato/tremolo }

  { channel 0 -- first violin }
  OplWrite($20, $21); OplWrite($40, $12); OplWrite($60, $F2);
  OplWrite($80, $13); OplWrite($E0, $00);
  OplWrite($23, $21); OplWrite($43, $07); OplWrite($63, $F1);
  OplWrite($83, $13); OplWrite($E3, $00);
  OplWrite($C0, $06);          { feedback 3, FM connection }

  { channel 1 -- bass }
  OplWrite($21, $21); OplWrite($41, $1A); OplWrite($61, $F2);
  OplWrite($81, $05); OplWrite($E1, $00);
  OplWrite($24, $21); OplWrite($44, $05); OplWrite($64, $F1);
  OplWrite($84, $05); OplWrite($E4, $00);
  OplWrite($C1, $00);
end;

{ freq -> (block, F-number). Pick the lowest block that keeps F-number under
  1024, which also keeps it as large as possible for best pitch resolution.
  F-number = freq * 2^(20-block) / 49716 (49716 = the OPL2 sample rate). }
procedure CalcFB(Freq: Word; out Blk: Byte; out Fnum: Word);
var Bk: Integer; Fn: LongInt;
begin
  Bk := 0;
  Fn := 0;
  while Bk <= 7 do
  begin
    Fn := (LongInt(Freq) * (LongInt(1) shl (20 - Bk))) div 49716;
    if Fn < 1024 then Break;
    Inc(Bk);
  end;
  if Bk > 7  then Bk := 7;
  if Fn > 1023 then Fn := 1023;
  Blk  := Byte(Bk);
  Fnum := Word(Fn);
end;

procedure KeyOn(Ch: Byte; Freq: Word);
var Blk: Byte; Fnum: Word;
begin
  CalcFB(Freq, Blk, Fnum);
  OplWrite(Byte($A0 + Ch), Byte(Fnum and $FF));
  OplWrite(Byte($B0 + Ch), Byte($20 or (Blk shl 2) or ((Fnum shr 8) and $03)));
end;

procedure KeyOff(Ch: Byte);
begin
  OplWrite(Byte($B0 + Ch), $00);
end;

procedure PlayList(const List: array of TNote; OctaveUp: Boolean);
var
  J   : Integer;
  F   : LongInt;
  Dur : LongInt;
begin
  for J := 0 to High(List) do
  begin
    if List[J].B <> 0 then
    begin
      if CurBass <> 0 then KeyOff(1);
      KeyOn(1, List[J].B);
      CurBass := List[J].B;
    end;

    Dur := LongInt(List[J].D) * TPE;
    F   := List[J].F;
    if F <> 0 then
    begin
      if OctaveUp then F := F * 2;
      KeyOn(0, Word(F));
      Wait(Dur);
      KeyOff(0);
      Inc(Played);
    end
    else
      Wait(Dur);

    Gap;
  end;
end;

{ Belt and braces: key every channel off and drive every operator to full
  attenuation, so nothing is left sounding whatever state a patch was in. }
procedure Silence;
var R: Byte;
begin
  for R := 0 to 8 do OplWrite(Byte($B0 + R), $00);
  for R := $40 to $55 do OplWrite(R, $3F);
  OplWrite($BD, $00);
end;

begin
  TPE := 5;
  if ParamCount >= 1 then
  begin
    Val(ParamStr(1), TPE, Code);
    if (Code <> 0) or (TPE < 2) or (TPE > 16) then TPE := 5;
  end;

  WriteLn('=== Mozart, Eine kleine Nachtmusik K.525 -- AdLib / OPL2 ===');
  WriteLn('  probing FM chip at 388h/389h (timer method)...');

  Present := DetectOpl;

  WriteLn('  status 388h: idle=', St1, ' after-timer=', St2,
          '   (want 0 then 192)');
  if Present then
    WriteLn('  OPL2: PRESENT')
  else
    WriteLn('  OPL2: NOT DETECTED -- skipping playback');

  Played  := 0;
  CurBass := 0;

  Melody := '';
  for I := 1 to NA do Melody := Melody + SongA[I].Nm;
  Melody := Melody + '| ';
  for I := 1 to NT do Melody := Melody + SongTag[I].Nm;

  if Present then
  begin
    OplInit;
    Wait(2);

    PlayList(SongA,   False);      { first sentence }
    PlayList(SongA,   True);       { again, an octave up }
    PlayList(SongTag, False);      { closing cadence }

    if CurBass <> 0 then KeyOff(1);
    Silence;

    WriteLn('  voices : ch0 first violin, ch1 root bass');
    WriteLn('  form   : sentence, sentence (8va), cadence');
    WriteLn('  tempo  : ', TPE, ' ticks/eighth  (eighth ~= ', (TPE * 55), ' ms)');
    WriteLn('  melody : ', Melody);
    WriteLn('  notes  : ', Played);
  end;

  WriteLn;
  Check('OPL2 detected at 388h',                 Present);
  Check('status idle bits clear (0)',            St1 = $00);
  Check('status timer bits set after run (192)', St2 = $C0);
  Check('played the extended tune',              Played = (NA + NA + NT));
  Finish;
end.
