unit Retro;
{ DOS Bridge  --  StevenC & Claude }
{ The demo's soundtrack: a four-voice retro chiptune on the AdLib / OPL2 --
  which on the machine this was written for is not an AdLib at all but the
  one a PicoMEM emulates at 388h.  Nothing here knows the difference, and
  that is the point: the chip is detected by its own timers, so a real card,
  an emulated one and no card at all are three cases of the same code path.

  IT MUST NOT BLOCK.  The demo is paced by the vertical retrace and repaints
  a 64-row band every frame, so the usual way to write a tune -- key a note,
  wait, key the next -- would stall the scroll dead.  MusicTick is called
  once per frame and returns immediately; the whole sequencer is a step
  counter and four small pieces of per-voice state.  This is the same rule
  starter/demos/music.pas is built on and for the same reason.

  TIMING COMES FROM THE BIOS TICK, NOT THE FRAME COUNT.  Counting frames
  looks natural when the caller already has a frame loop, and it is wrong:
  the frame rate here is quantised to 70.1/N, so one sprite more or less does
  not slow the music by a few percent, it halves the tempo.  The tick is
  18.2 Hz whatever the picture is doing.

      1 step = 2 ticks  = 109.9ms = one sixteenth note
      1 bar  = 16 steps = 1.76s
      song   = 8 bars   = 14.1s, so it goes round twice in a 30-second run
      tempo  = 136 BPM

  MusicTick takes the elapsed tick count and catches up to it, so a step is
  at worst one frame late and the tempo never drifts however the frame budget
  moves around.

  Four voices on channels 0..3 of the nine the chip has:

      0  lead   the hook -- a buzzy pulse-wave line
      1  bass   eighth-note root pulse with octave jumps
      2  arp    sixteenth-note arpeggio, quiet, and the reason it moves
      3  drum   one percussive voice doing both kick and snare

  Four and not five.  Every voice that changes on a step is three OPL
  register writes (frequency, key off, key on) and the register writer spends
  its time waiting for the chip -- about 90us each, so a step where all four
  turn over costs a millisecond.  That fits the budget; a fifth voice did not
  reliably, and a drum machine is not what this demo is for.

  Harmony is the four-chord loop everything retro is built on, twice, with
  the second half bent:  Am F C G | Am F Dm E

  The bass and the arpeggio are GENERATED from that chord table rather than
  written out as events, because 64 and 128 hand-typed notes would be a lot
  of data to get subtly wrong.  Only the lead is an event list, because it is
  the part that has to be composed. }

{$MODE OBJFPC}{$H-}

interface

{ Detect the chip and load the patches.  False means no OPL2 answered, and
  then MusicTick and MusicStop do nothing at all -- so the caller runs the
  demo silently without special-casing anything.  That is the whole of the
  "disable sound if no sound card is found" requirement: there is no flag to
  set and no second code path. }
function  MusicStart: Boolean;

{ Bring the music up to date.  El is ticks elapsed since the demo started.
  Call once a frame; most calls do nothing but a compare. }
procedure MusicTick(El: LongInt);

{ Key everything off AND drive every operator to silence.  Must be called on
  EVERY exit path -- a program that quits with a voice still ringing leaves
  the machine droning, and over the bridge nobody can hear that it happened. }
procedure MusicStop;

var
  MusicOn    : Boolean;      { an OPL2 answered and the patches are loaded }
  MusicNotes : LongInt;      { notes keyed on, so a run can prove it played }
  MusicLoops : LongInt;      { times round the eight bars }
  MusicStep  : Integer;      { where the sequencer is, for the report }

implementation

uses Opl2;

const
  STEP_TICKS  = 2;                 { BIOS ticks per sixteenth note }
  MAX_CATCHUP = 4;                 { steps one call may play at once }
  SPB         = 16;                { steps per bar }
  BARS        = 8;
  SONG        = BARS * SPB;

  CH_LEAD = 0;
  CH_BASS = 1;
  CH_ARP  = 2;
  CH_DRUM = 3;

  { Note numbers are semitones with C0 = 0, so A4 (440 Hz) is 57. }

  { Bass root per bar: A1 F1 C2 G1 | A1 F1 D2 E1.  Kept inside one octave so
    the line never jumps out from under the arpeggio. }
  BassRoot: array[0..BARS - 1] of Byte = (21, 17, 24, 19, 21, 17, 26, 16);

  { The eighth-note pulse, as offsets from the root.  The octave jumps are
    what stop a root-note pulse sounding like a metronome, and the fifth on
    the last eighth leans into the next bar. }
  BassOfs: array[0..7] of Byte = (0, 0, 12, 0, 0, 12, 7, 7);

  { Arpeggio tones per bar -- root, third, fifth -- all kept inside one
    octave so the figure does not wander away from the lead. }
  ArpTone: array[0..BARS - 1, 0..2] of Byte = (
    (45, 48, 52),    { Am : A3  C4  E4  }
    (41, 45, 48),    { F  : F3  A3  C4  }
    (48, 52, 55),    { C  : C4  E4  G4  }
    (43, 47, 50),    { G  : G3  B3  D4  }
    (45, 48, 52),    { Am }
    (41, 45, 48),    { F  }
    (50, 53, 57),    { Dm : D4  F4  A4  }
    (52, 56, 59));   { E  : E4  G#4 B4  -- major, so it pulls back to Am }

  { Up, over, down, over.  Four steps, so it turns over four times a bar. }
  ArpSeq: array[0..3] of Byte = (0, 1, 2, 1);

  { Drum pattern over one bar of sixteenths.  0 nothing, 1 kick, 2 snare.
    Kick on the beat, snare on two and four: the oldest pattern there is, and
    the one that reads as "retro" without any thought at all. }
  DrumPat: array[0..SPB - 1] of Byte = (
    1, 0, 0, 0,  2, 0, 0, 1,  1, 0, 0, 0,  2, 0, 1, 0);

  DRUM_KICK  = 14;
  DRUM_SNARE = 42;

type
  TEv = record
    N: Byte;      { note, 0 = rest }
    D: Byte;      { length in steps }
  end;

const
  NLEAD = 38;
  { The hook.  Steps sum to 128, one time round the harmony.  Written bar by
    bar so the chord each phrase sits over is obvious from the layout. }
  Lead: array[0..NLEAD - 1] of TEv = (
    (N:64;D:2), (N:62;D:2), (N:60;D:4), (N:57;D:4), (N:60;D:4),   { Am }
    (N:62;D:4), (N:60;D:2), (N:57;D:2), (N:53;D:4), (N: 0;D:4),   { F  }
    (N:55;D:2), (N:57;D:2), (N:60;D:4), (N:64;D:4), (N:67;D:4),   { C  }
    (N:64;D:4), (N:62;D:4), (N:59;D:4), (N:62;D:4),               { G  }
    (N:57;D:2), (N:60;D:2), (N:64;D:4), (N:69;D:4), (N:67;D:4),   { Am }
    (N:64;D:4), (N:60;D:4), (N:57;D:4), (N:60;D:4),               { F  }
    (N:62;D:2), (N:65;D:2), (N:69;D:4), (N:65;D:4), (N:62;D:4),   { Dm }
    (N:64;D:4), (N:68;D:2), (N:71;D:2), (N:64;D:4), (N: 0;D:4));  { E  }

  { --- the patches ---------------------------------------------------------
    Written as records rather than as raw register bytes because the five
    numbers that shape an operator are not memorable as addresses, and the
    one thing certain about a demo soundtrack is that somebody will want to
    fiddle with it.  See opl2.pas for what each field is. }

  { Buzzy pulse lead.  Wave 3 on both operators is the half-pulse sine, which
    is as close as an OPL2 gets to the square wave everything from this era
    actually sounded like. }
  VLead: TOplVoice = (
    M: (Flags: $21; Level: $17; AtkDec: $F2; SusRel: $15; Wave: $03);
    C: (Flags: $21; Level: $06; AtkDec: $F1; SusRel: $16; Wave: $03);
    Fb: $0A);

  { Short punchy bass: fast attack, quick decay, little sustain -- so eighth
    notes stay separate instead of smearing into a drone. }
  VBass: TOplVoice = (
    M: (Flags: $01; Level: $12; AtkDec: $F7; SusRel: $56; Wave: $00);
    C: (Flags: $01; Level: $04; AtkDec: $F5; SusRel: $46; Wave: $00);
    Fb: $08);

  { Plucky and QUIET.  The arpeggio runs at four notes a bar's quarter and
    would dominate everything at lead level; the attenuation is doing as much
    work here as the envelope. }
  VArp: TOplVoice = (
    M: (Flags: $21; Level: $2A; AtkDec: $F6; SusRel: $B8; Wave: $02);
    C: (Flags: $21; Level: $1A; AtkDec: $F6; SusRel: $C8; Wave: $02);
    Fb: $06);

  { One voice for both drums.  High multipliers put the two operators far
    apart in frequency, which on an FM chip is how you get a clang rather
    than a tone; the envelope is all attack and release and no sustain, so
    what note it is keyed at decides whether it reads as a kick or a snare. }
  VDrum: TOplVoice = (
    M: (Flags: $0C; Level: $18; AtkDec: $F8; SusRel: $F8; Wave: $03);
    C: (Flags: $0F; Level: $00; AtkDec: $F9; SusRel: $F9; Wave: $03);
    Fb: $00);

var
  Step    : Integer;         { 0..SONG-1 }
  NextTick: LongInt;         { tick the next step is due at }
  LeadIx  : Integer;         { where in the event list }
  LeadLeft: Integer;         { steps the current lead note has left }

function MusicStart: Boolean;
begin
  MusicOn    := False;
  MusicNotes := 0;
  MusicLoops := 0;
  MusicStep  := 0;
  Step       := 0;
  NextTick   := 0;
  LeadIx     := 0;
  LeadLeft   := 0;

  if not OplDetect then
  begin
    MusicStart := False;
    Exit;
  end;

  OplInitChip;
  OplVoice(CH_LEAD, VLead);
  OplVoice(CH_BASS, VBass);
  OplVoice(CH_ARP,  VArp);
  OplVoice(CH_DRUM, VDrum);

  MusicOn    := True;
  MusicStart := True;
end;

{ One sixteenth note.  Everything that can be decided from the step number is
  decided here; nothing waits for anything. }
procedure PlayStep;
var
  Bar, InBar: Integer;
  D         : Byte;
begin
  Bar   := Step div SPB;
  InBar := Step mod SPB;

  { --- lead: an event list, so it advances on its own clock --- }
  if LeadLeft <= 0 then
  begin
    if LeadIx >= NLEAD then LeadIx := 0;
    OplNoteOff(CH_LEAD);
    if Lead[LeadIx].N <> 0 then
    begin
      OplNoteOn(CH_LEAD, Lead[LeadIx].N);
      Inc(MusicNotes);
    end;
    LeadLeft := Lead[LeadIx].D;
    Inc(LeadIx);
  end;
  Dec(LeadLeft);

  { --- bass: an eighth-note pulse, so every other step --- }
  if (InBar and 1) = 0 then
  begin
    OplNoteOff(CH_BASS);
    OplNoteOn(CH_BASS, Byte(BassRoot[Bar] + BassOfs[InBar shr 1]));
    Inc(MusicNotes);
  end;

  { --- arpeggio: every second step, four-step figure --- }
  if (InBar and 1) = 0 then
  begin
    OplNoteOff(CH_ARP);
    OplNoteOn(CH_ARP, ArpTone[Bar, ArpSeq[(InBar shr 1) and 3]]);
    Inc(MusicNotes);
  end;

  { --- drums --- }
  D := DrumPat[InBar];
  if D <> 0 then
  begin
    OplNoteOff(CH_DRUM);
    if D = 1 then OplNoteOn(CH_DRUM, DRUM_KICK)
             else OplNoteOn(CH_DRUM, DRUM_SNARE);
    Inc(MusicNotes);
  end;

  Inc(Step);
  if Step >= SONG then
  begin
    Step := 0;
    LeadIx := 0;
    LeadLeft := 0;
    Inc(MusicLoops);
  end;
  MusicStep := Step;
end;

procedure MusicTick(El: LongInt);
var
  N: Integer;
begin
  if not MusicOn then Exit;

  { Catch up to the clock, but never play more than MAX_CATCHUP steps in one
    call.  A frame that ran long -- the first one after the world is painted,
    say -- would otherwise dump a dozen steps into the chip at once, which is
    a burst of register writes exactly where the budget is already blown. }
  N := 0;
  while (El >= NextTick) and (N < MAX_CATCHUP) do
  begin
    PlayStep;
    Inc(NextTick, STEP_TICKS);
    Inc(N);
  end;

  { If it fell further behind than the catch-up allows, give up on the missed
    steps rather than accumulating a debt that can never be paid: resync the
    clock to now.  A tune that is a beat short once is better than one that
    spends the rest of the run sprinting. }
  if El >= NextTick + STEP_TICKS * MAX_CATCHUP then
    NextTick := El + STEP_TICKS;
end;

procedure MusicStop;
begin
  if not MusicOn then Exit;
  OplSilence;
  MusicOn := False;
end;

end.
