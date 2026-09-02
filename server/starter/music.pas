unit Music;
{ DOS Bridge  --  StevenC }
{ The scroller's soundtrack: a three-voice space theme on the AdLib / OPL2.

  The one constraint that shapes all of this is that IT MUST NOT BLOCK.  The
  demo is paced by the vertical retrace and has under 3ms of slack in a
  14.27ms frame, so the usual way to write a tune -- key a note, wait, key the
  next -- would stall the scroll dead.  Instead MusicTick is called once per
  frame and returns immediately, and the whole sequencer is a step counter
  plus three small pieces of per-voice state.

  Even so, adding this cost a sprite.  Three voices changing on the same step
  is nine OPL register writes, and the register writer spends its time waiting
  for the chip -- about 0.8ms all told, which was enough to push the frame
  over a refresh boundary.  See the table in scroller.pas.

  Timing comes from the BIOS tick and NOT from the frame count, which was the
  first thing tried and was wrong:

      1 step = 2 ticks  = 109.9ms = one sixteenth note
      1 bar  = 16 steps = 1.76s
      song   = 8 bars   = 14.1s, so it goes round twice in a 30-second run
      tempo  = 136 BPM

  Counting frames looks natural when the caller already has a frame loop, but
  it ties the tempo to the frame rate -- and the frame rate here is quantised
  to 70.1/N, so one sprite more or less does not slow the demo down by 10%, it
  halves the speed of the music.  The tick is 18.2 Hz whatever the picture is
  doing.

  MusicTick therefore takes the elapsed tick count and catches up to it, so a
  step is at worst one frame late (14ms, inaudible) and the tempo never drifts
  however the frame budget moves around.

  Three voices on channels 0..2 of the nine the chip has:

      0  lead   long soaring notes with vibrato -- the tune
      1  bass   eighth-note pulse on the chord root, with octave jumps
      2  arp    sixteenth-note arpeggio, quiet, and the reason it moves

  Harmony is a D minor loop:  Dm Dm Bb C | Dm F Bb A

  The bass and the arpeggio are generated from that chord table rather than
  written out as events, because 64 and 128 hand-typed notes would be a lot of
  data to get subtly wrong.  Only the lead is an event list, since it is the
  part that has to be *composed*. }

{$MODE OBJFPC}{$H-}

interface

{ Detect the chip and load the patches.  False means no OPL2 answered, and
  then MusicTick and MusicStop do nothing at all -- so the caller can run the
  demo silently without special-casing anything. }
function  MusicStart: Boolean;

{ Bring the music up to date.  El is ticks elapsed since the demo started.
  Call it once a frame; most calls do nothing but a compare. }
procedure MusicTick(El: LongInt);

{ Key everything off.  Must be called on EVERY exit path -- a program that
  quits with a voice still ringing leaves the machine droning, and over the
  bridge nobody can hear that it happened. }
procedure MusicStop;

var
  MusicOn    : Boolean;      { an OPL2 answered and the patches are loaded }
  MusicNotes : LongInt;      { notes keyed on, so the run can prove it played }
  MusicLoops : LongInt;      { times round the eight bars }

implementation

uses Opl2;

const
  STEP_TICKS  = 2;                 { BIOS ticks per sixteenth note }
  MAX_CATCHUP = 4;                 { steps a single call may play at once }
  SPB         = 16;                { steps per bar }
  BARS        = 8;
  SONG        = BARS * SPB;

  CH_LEAD = 0;
  CH_BASS = 1;
  CH_ARP  = 2;

  { Note numbers are semitones with C0 = 0, so D2 = 26 and A4 = 57. }

  { Bass root per bar: D2 D2 Bb1 C2 | D2 F2 Bb1 A1 }
  BassRoot: array[0..BARS - 1] of Byte = (26, 26, 22, 24, 26, 29, 22, 21);

  { The eighth-note pulse, as offsets from the root.  The octave jumps are
    what stop a root-note pulse sounding like a metronome, and the fifth on
    the last eighth leans into the next bar. }
  BassOfs: array[0..7] of Byte = (0, 0, 12, 0, 0, 12, 0, 7);

  { Arpeggio tones per bar -- root, third, fifth of the chord, all kept inside
    one octave of D4 so the figure does not wander away from the lead. }
  ArpTone: array[0..BARS - 1, 0..2] of Byte = (
    (50, 53, 57),    { Dm : D4  F4  A4  }
    (50, 53, 57),    { Dm }
    (46, 50, 53),    { Bb : Bb3 D4  F4  }
    (48, 52, 55),    { C  : C4  E4  G4  }
    (50, 53, 57),    { Dm }
    (53, 57, 60),    { F  : F4  A4  C5  }
    (46, 50, 53),    { Bb }
    (45, 49, 52));   { A  : A3  C#4 E4  -- major, so it pulls back to Dm }

  { Up, over, down, over.  Four steps, so it turns over four times a bar. }
  ArpSeq: array[0..3] of Byte = (0, 1, 2, 1);

type
  TEv = record
    N: Byte;      { note, 0 = rest }
    D: Byte;      { length in steps }
  end;

const
  NLEAD = 15;
  { The tune.  Long notes, wide leaps, and a rest at the end of the phrases --
    the space is the point.  Steps sum to 128, one time round the harmony. }
  Lead: array[0..NLEAD - 1] of TEv = (
    (N: 62; D: 12), (N:  0; D:  4),    { bar 1  Dm : D5, then air     }
    (N: 69; D:  8), (N: 65; D:  8),    { bar 2  Dm : A5 F5            }
    (N: 62; D: 16),                    { bar 3  Bb : D5, the third    }
    (N: 64; D:  8), (N: 67; D:  8),    { bar 4  C  : E5 G5            }
    (N: 65; D: 12), (N:  0; D:  4),    { bar 5  Dm : F5               }
    (N: 69; D:  8), (N: 72; D:  8),    { bar 6  F  : A5 C6, the peak  }
    (N: 70; D:  8), (N: 69; D:  8),    { bar 7  Bb : Bb5 A5           }
    (N: 64; D: 10), (N: 62; D:  6));   { bar 8  A  : E5 falling to D5 }

  { --- patches --- }

  { Lead: two sine operators in FM with heavy feedback, vibrato on both, and
    a slow-ish attack so long notes swell rather than stab. }
  VLead: TOplVoice = (
    M: (Flags: $61; Level: $1B; AtkDec: $53; SusRel: $25; Wave: $00);
    C: (Flags: $61; Level: $05; AtkDec: $52; SusRel: $15; Wave: $00);
    Fb: $0C);

  { Bass: modulator at mult 1, carrier NON-sustaining (bit 5 clear) so each
    pulse decays instead of holding -- that is what makes it a pulse. }
  VBass: TOplVoice = (
    M: (Flags: $21; Level: $14; AtkDec: $F4; SusRel: $73; Wave: $00);
    C: (Flags: $01; Level: $04; AtkDec: $F3; SusRel: $85; Wave: $00);
    Fb: $08);

  { Arp: half-sine on both operators for a brighter, thinner tone, fast attack
    and quick decay, and deliberately quiet -- it is texture, not tune. }
  VArp: TOplVoice = (
    M: (Flags: $21; Level: $2E; AtkDec: $F6; SusRel: $A8; Wave: $01);
    C: (Flags: $01; Level: $16; AtkDec: $F7; SusRel: $B8; Wave: $01);
    Fb: $02);

var
  Step     : Word;      { 0..SONG-1, where we are in the eight bars }
  Played   : LongInt;   { steps played since the start, to compare with time }
  LeadIx   : Integer;
  LeadLeft : Word;

function MusicStart: Boolean;
begin
  MusicOn    := False;
  MusicNotes := 0;
  MusicLoops := 0;

  if not OplDetect then
  begin
    MusicStart := False;
    Exit;
  end;

  OplInitChip;
  OplVoice(CH_LEAD, VLead);
  OplVoice(CH_BASS, VBass);
  OplVoice(CH_ARP,  VArp);

  Step     := 0;
  Played   := 0;
  { Point one past the end with one step to run, so the first boundary lands
    on event 0 rather than skipping it. }
  LeadIx   := NLEAD - 1;
  LeadLeft := 1;

  MusicOn    := True;
  MusicStart := True;
end;

procedure PlayStep;
var
  Bar, W: Word;
begin
  Bar := Step div SPB;
  W   := Step mod SPB;

  { Arpeggio: a new note every step.  Keyed off first, because re-keying the
    same channel without an off does not retrigger the envelope. }
  OplNoteOff(CH_ARP);
  OplNoteOn(CH_ARP, ArpTone[Bar, ArpSeq[Step and 3]]);
  Inc(MusicNotes);

  { Bass: every other step, i.e. eighth notes. }
  if (W and 1) = 0 then
  begin
    OplNoteOff(CH_BASS);
    OplNoteOn(CH_BASS, Byte(BassRoot[Bar] + BassOfs[W shr 1]));
    Inc(MusicNotes);
  end;

  { Lead: driven by the event list, so it changes only at note boundaries. }
  Dec(LeadLeft);
  if LeadLeft = 0 then
  begin
    Inc(LeadIx);
    if LeadIx >= NLEAD then LeadIx := 0;
    OplNoteOff(CH_LEAD);
    if Lead[LeadIx].N <> 0 then
    begin
      OplNoteOn(CH_LEAD, Lead[LeadIx].N);
      Inc(MusicNotes);
    end;
    LeadLeft := Lead[LeadIx].D;
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

  Want := El div STEP_TICKS;
  N    := 0;
  { Catch up rather than play one step per call, so a slow frame does not make
    the tune late for ever.  Capped, because a long stall -- the world being
    painted, say -- must not fire off a hundred notes at once. }
  while (Played < Want) and (N < MAX_CATCHUP) do
  begin
    PlayStep;
    Inc(Played);
    Inc(N);
  end;
  if Played < Want then Played := Want;
end;

procedure MusicStop;
begin
  if not MusicOn then Exit;
  OplSilence;
  MusicOn := False;
end;

begin
  MusicOn    := False;
  MusicNotes := 0;
  MusicLoops := 0;
end.
