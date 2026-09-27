unit Mystery;
{ DOS Bridge  --  StevenC & Claude }
{ A mystery theme for the raycaster, on an AdLib / OPL2, driven from a frame
  loop.

  Same shape as music.pas -- MusicStart / MusicTick / MusicStop -- but a
  separate unit rather than a second tune inside that one. music.pas belongs
  to the scroller, ships in the kit, and is verified at 70 fps; bolting a
  second song into it would put the scroller's timing at the mercy of edits
  made for a demo that runs at four.

  WHAT MAKES IT SOUND LIKE A MYSTERY

  Three things, and they are all intervals rather than instruments:

  * A CHROMATIC DESCENDING BASS. A2, G#2, G2, F#2, F2, E2 ... every step a
    semitone. Nothing in a major or minor scale moves like that, so the ear
    cannot place a key and keeps waiting to find out. It is the oldest trick
    in the film-noir book.
  * A TRITONE IN THE MELODY. Eb against a bass walking through A: the interval
    medieval theorists called diabolus in musica. It is the single most
    unresolved sound in twelve-tone equal temperament.
  * IT NEVER RESOLVES. The phrase ends on G#, the leading tone, and then rests.
    The ear expects A and does not get it, so the loop point feels like a
    question rather than a full stop.

  Under all of it a low A drone, re-struck every two bars, so the harmony has
  a floor to be ambiguous against.

  TEMPO COMES FROM THE BIOS TICK, NOT THE FRAME COUNT

  The same rule the scroller's music has to follow, and for a stronger reason
  here: the raycaster's frame rate depends on what it is looking at -- a
  corridor is cheaper to draw than an open room -- so a tune sequenced per
  frame would speed up and slow down as the camera turned. Every timing below
  is in BIOS ticks at 18.2 Hz.

  MusicTick is cheap on the calls that do nothing: two compares. The calls
  that do something cost about half a millisecond in register writes, which
  against a 240 ms frame is nothing. That is not true at 70 fps, which is why
  the scroller had to count the cost of every write; here it genuinely does
  not matter, and saying so is more useful than pretending to optimise it. }

{$MODE OBJFPC}{$H-}

interface

type
  { What is actually making the noise. }
  TMusicDev = (mdSilent, mdOpl2, mdSpeaker);

{ Pick a device and start. WantSpk forces the PC speaker even where an OPL2
  answers; otherwise the OPL2 is preferred and the speaker is the fallback.
  False means neither was available -- MusicTick and MusicStop then do nothing
  at all, so the caller never special-cases silence.

  THE SPEAKER IS ABOUT AVAILABILITY, NOT SPEED. Measured on the raycaster:
  the AdLib costs 0.1 fps out of 11.2, under 1%, because a note event is
  about 0.8 ms of register writes against an 87 ms frame and there are only
  a couple of note events a second. The speaker is roughly a hundred times
  cheaper per note -- four OUTs with no mandated delay against nine register
  writes each needing a documented settling wait -- and none of that matters
  here. What matters is that most 8086-class machines have no AdLib fitted
  and were getting silence.

  The catch is real though: the PC speaker is ONE voice. This theme is three,
  and the tritone that makes it sound like a mystery is an interval BETWEEN
  two of them -- an interval a monophonic device cannot state. What the
  speaker plays is the reduction below: the melody where there is one, the
  chromatic walk where there is not. It is recognisably the same tune and it
  is not the same effect. }
function  MusicStart(WantSpk: Boolean): Boolean;

{ Bring the music up to date. El is ticks elapsed since the demo started.
  Call it once a frame; most calls do nothing but a compare. }
procedure MusicTick(El: LongInt);

{ Key everything off. Must be called on EVERY exit path -- a program that
  quits with a voice still ringing leaves the machine droning, and over the
  bridge nobody can hear that it happened. }
procedure MusicStop;

var
  MusicDev   : TMusicDev;    { what answered }
  MusicOn    : Boolean;      { something answered and is ready to play }
  MusicNotes : LongInt;      { notes keyed on, so a run can prove it played }
  MusicLoops : LongInt;      { times round the four bars }

implementation

uses Opl2;

{ Local port helpers. opl2.pas keeps its own in its implementation section,
  and a unit this small is not worth widening that unit's interface for. }
procedure OutB(P: Word; V: Byte); assembler;
asm
  mov dx, P
  mov al, V
  out dx, al
end;

function InB(P: Word): Byte; assembler;
asm
  mov dx, P
  in  al, dx
end;

const
  { 3 ticks to a sixteenth is 0.165 s, so a quarter note is 0.66 s: about 91
    to the minute, which is slow enough to brood without dragging. Four bars
    is 192 ticks, near enough eleven seconds -- so the default ten-second run
    hears the whole phrase once and a longer one hears it turn over. }
  STEP_TICKS  = 3;
  MAX_CATCHUP = 4;                 { steps a single call may play at once }
  SPB         = 16;                { steps per bar }
  BARS        = 4;
  SONG        = BARS * SPB;        { 64 steps }

  CH_DRONE = 0;
  CH_BASS  = 1;
  CH_LEAD  = 2;

  { Note numbers are semitones with C0 = 0, so A4 (440 Hz) is 57. }
  DRONE_NOTE = 21;                 { A1, two octaves under the walk }

  { The chromatic walk, one note per quarter, sixteen quarters over four bars.
    A G# G F# | F E Eb D | C# D E F | E Eb D E
    Down six semitones, a turn at the bottom, then a climb that stops one step
    short of home. }
  BassWalk: array[0 .. 15] of Byte = (
    33, 32, 31, 30,
    29, 28, 27, 26,
    25, 26, 28, 29,
    28, 27, 26, 28);

type
  TEv = record
    N: Byte;      { note, 0 = rest }
    D: Byte;      { length in steps }
  end;

const
  NLEAD = 9;
  { The melody. Mostly air: five notes in eleven seconds, and the rests are
    doing as much work as the notes. Durations sum to SONG. }
  Lead: array[0 .. NLEAD - 1] of TEv = (
    (N:  0; D:  8),      { let the walk establish itself first }
    (N: 60; D: 12),      { C5  -- the minor third }
    (N: 63; D:  6),      { Eb5 -- the tritone against A. This is the hook. }
    (N: 59; D:  6),      { B4  -- leans down }
    (N:  0; D:  4),
    (N: 57; D: 10),      { A4  -- home, briefly }
    (N: 56; D:  8),      { G#4 -- the leading tone }
    (N:  0; D:  4),      { ...and nothing after it }
    (N: 64; D:  6));     { E5  -- a question on the way round }

  { --- patches ---------------------------------------------------------- }

  { Drone: slow attack, full sustain, no brightness. Modulator almost silent
    so it is nearly a pure low sine -- felt more than heard. }
  VDrone: TOplVoice = (
    M: (Flags: $21; Level: $3F; AtkDec: $31; SusRel: $04; Wave: $00);
    C: (Flags: $21; Level: $10; AtkDec: $21; SusRel: $03; Wave: $00);
    Fb: $00);

  { Bass: plucked. Carrier NON-sustaining (bit 5 of Flags clear) so every step
    of the walk decays instead of holding -- that is what makes it a footstep
    rather than a chord. }
  VBass: TOplVoice = (
    M: (Flags: $21; Level: $17; AtkDec: $F3; SusRel: $63; Wave: $00);
    C: (Flags: $01; Level: $07; AtkDec: $F2; SusRel: $75; Wave: $00);
    Fb: $06);

  { Lead: vibrato on both operators and a soft attack, so notes arrive rather
    than start. Half-sine on the carrier thins it out and takes the warmth
    off, which is what stops it sounding like a ballad. }
  VLead: TOplVoice = (
    M: (Flags: $61; Level: $22; AtkDec: $63; SusRel: $37; Wave: $00);
    C: (Flags: $61; Level: $0C; AtkDec: $53; SusRel: $28; Wave: $01);
    Fb: $0A);

const
  { PIT channel 2 divisors for C5..B5. 1193182 / frequency, rounded. Every
    other octave comes from shifting: dropping an octave halves the frequency
    and so doubles the divisor. The lowest note here is A1, four octaves
    down, giving 1356 shl 4 = 21696 -- comfortably inside a Word. }
  Div5: array[0 .. 11] of Word = (
    2280, 2152, 2032, 1917, 1810, 1708,
    1612, 1522, 1436, 1356, 1280, 1208);

var
  SpkNote  : Byte;      { note currently sounding, 0 = silent }
  Step     : Word;      { 0 .. SONG-1 }
  Played   : LongInt;   { steps played, to compare against elapsed time }
  LeadIx   : Integer;
  LeadLeft : Word;

{ Sound one note on the PC speaker, or silence it when Note is 0. Ports
    43h/42h/61h directly, the way beep.pas does it -- never Crt, whose unit
    initialisation replaces the Output driver with one that writes straight to
    video memory and takes every WriteLn after it out of the captured job. }
procedure SpkNoteOn(Note: Byte);
var
  M   : Byte;
  Oct : Byte;
  D   : Word;
begin
  if Note = SpkNote then Exit;
  SpkNote := Note;
  if Note = 0 then
  begin
    OutB($61, InB($61) and $FC);
    Exit;
  end;
  M   := Note;
  Oct := 0;
  while M < 60 do
  begin
    Inc(M, 12);
    Inc(Oct);
  end;
  D := Div5[M - 60] shl Oct;
  OutB($43, $B6);                    { channel 2, square wave }
  OutB($42, Lo(D));
  OutB($42, Hi(D));
  OutB($61, InB($61) or 3);          { gate and speaker on }
  Inc(MusicNotes);
end;

function MusicStart(WantSpk: Boolean): Boolean;
begin
  MusicOn    := False;
  MusicDev   := mdSilent;
  MusicNotes := 0;
  MusicLoops := 0;
  SpkNote    := 0;

  if WantSpk then
    MusicDev := mdSpeaker
  else if OplDetect then
    MusicDev := mdOpl2
  else
    MusicDev := mdSpeaker;           { no chip answered; the speaker is there }

  if MusicDev = mdOpl2 then
  begin
    OplInitChip;
    OplVoice(CH_DRONE, VDrone);
    OplVoice(CH_BASS,  VBass);
    OplVoice(CH_LEAD,  VLead);
  end;

  Step   := 0;
  Played := 0;
  { One past the end with a single step to run, so the first boundary lands on
    event 0 rather than skipping it. }
  LeadIx   := NLEAD - 1;
  LeadLeft := 1;

  MusicOn    := True;
  MusicStart := True;
end;

procedure PlayStep;
var
  W: Word;
begin
  { --- the monophonic reduction ---------------------------------------- }
  if MusicDev = mdSpeaker then
  begin
    Dec(LeadLeft);
    if LeadLeft = 0 then
    begin
      Inc(LeadIx);
      if LeadIx >= NLEAD then LeadIx := 0;
      LeadLeft := Lead[LeadIx].D;
    end;
    { Melody where there is one, the chromatic walk where there is not. The
      walk is what carries the piece when the lead rests, and on one voice
      leaving those bars silent would just sound like the tune had stopped. }
    if Lead[LeadIx].N <> 0 then
      SpkNoteOn(Lead[LeadIx].N)
    else
      SpkNoteOn(BassWalk[Step div 4]);
    Inc(Step);
    if Step >= SONG then
    begin
      Step := 0;
      Inc(MusicLoops);
    end;
    Exit;
  end;

  { Drone, re-struck every two bars. Keyed off first: re-keying a channel
    without an off does not retrigger the envelope, so the swell would only
    ever happen once. }
  if (Step = 0) or (Step = 2 * SPB) then
  begin
    OplNoteOff(CH_DRONE);
    OplNoteOn(CH_DRONE, DRONE_NOTE);
    Inc(MusicNotes);
  end;

  { The walk: one note every quarter, i.e. every fourth step. }
  if (Step and 3) = 0 then
  begin
    W := Step div 4;
    OplNoteOff(CH_BASS);
    OplNoteOn(CH_BASS, BassWalk[W]);
    Inc(MusicNotes);
  end;

  { The melody, as a run-length list. }
  Dec(LeadLeft);
  if LeadLeft = 0 then
  begin
    Inc(LeadIx);
    if LeadIx >= NLEAD then LeadIx := 0;
    LeadLeft := Lead[LeadIx].D;
    OplNoteOff(CH_LEAD);
    if Lead[LeadIx].N <> 0 then
    begin
      OplNoteOn(CH_LEAD, Lead[LeadIx].N);
      Inc(MusicNotes);
    end;
  end;

  Inc(Step);
  if Step >= SONG then
  begin
    Step := 0;
    Inc(MusicLoops);
  end;
end;

procedure MusicTick(El: LongInt);
var
  Want, N: LongInt;
begin
  if not MusicOn then Exit;

  { How many steps SHOULD have played by now. Derived from elapsed ticks, so
    the tune keeps wall-clock time no matter what the frame rate does. }
  Want := El div STEP_TICKS;
  if Want <= Played then Exit;

  N := Want - Played;
  { A long stall must not machine-gun the whole phrase to catch up. Skip the
    backlog and carry on in time rather than replaying it out of time. }
  if N > MAX_CATCHUP then
  begin
    Played := Want - 1;
    N := 1;
  end;

  while N > 0 do
  begin
    PlayStep;
    Inc(Played);
    Dec(N);
  end;
end;

procedure MusicStop;
begin
  if not MusicOn then Exit;
  { Every exit path, including the error ones. A program that quits with a
    voice still ringing leaves the machine droning, and over the bridge
    nobody can hear that it happened. }
  if MusicDev = mdSpeaker then
    OutB($61, InB($61) and $FC)
  else
    OplSilence;
  SpkNote := 0;
  MusicOn := False;
end;

end.
