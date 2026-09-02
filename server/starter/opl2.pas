unit Opl2;
{ DOS Bridge  --  StevenC }
{ AdLib / OPL2 (Yamaha YM3812) plumbing: detection, register writes with the
  settling delays the chip needs, voice patches, and note on/off.

  Split out of amozart.pas when scroller.pas needed a second caller, and kept
  deliberately small -- what two FM programs share is the chip, not the music.

  Note amozart.pas has NOT been migrated onto this unit; it still carries its
  own copy of the detection and the register writer. It works and is verified
  on hardware, so it was left alone rather than changed for tidiness, but it
  is the obvious next thing to fold in here.

  Real-mode 8086 throughout. The only arithmetic is a table lookup and a
  divide by twelve. }

{$MODE OBJFPC}{$H-}
{$ASMMODE INTEL}

interface

const
  OPL_ADDR = $388;          { address, and status on read }
  OPL_DATA = $389;

type
  { One of the two operators of a 2-op voice: the five registers that shape
    it, named for what they hold rather than their addresses. }
  TOplOp = record
    Flags : Byte;   { 20h: AM(80) VIB(40) EG-sustain(20) KSR(10) MULT(0F) }
    Level : Byte;   { 40h: key-scale level (C0) and attenuation (3F) }
    AtkDec: Byte;   { 60h: attack (F0), decay (0F) }
    SusRel: Byte;   { 80h: sustain level (F0), release (0F) }
    Wave  : Byte;   { E0h: 0 sine, 1 half, 2 abs, 3 pulse }
  end;

  TOplVoice = record
    M, C : TOplOp;  { modulator, carrier }
    Fb   : Byte;    { C0h: feedback (0E) and connection bit (01) }
  end;

var
  { The two status reads the probe is built on, kept so a caller can print
    them: only 00h followed by C0h proves a chip answered. }
  OplIdle, OplTimer: Byte;

{ True if an FM chip really is at 388h. Safe to call with nothing there -- an
  absent port floats and simply fails the test. }
function  OplDetect: Boolean;

procedure OplWrite(Reg, Val: Byte);

{ Waveform-select enabled, melodic mode, no rhythm, everything keyed off. }
procedure OplInitChip;

{ Load a patch into one of channels 0..8. }
procedure OplVoice(Ch: Byte; const V: TOplVoice);

{ Note numbers are semitones with C0 = 0, so A4 (440 Hz) is 57 and the usable
  range is 0..95. See the implementation for why the octave is free. }
procedure OplNoteOn(Ch, Note: Byte);
procedure OplNoteOff(Ch: Byte);

{ Key everything off AND drive every operator to full attenuation. Belt and
  braces, because a program that exits with a voice still ringing leaves a
  machine droning until somebody power-cycles it. }
procedure OplSilence;

implementation

const
  { F-numbers for the twelve semitones of octave 0, from
    fnum = freq * 2^20 / 49716, with 49716 the OPL2 sample rate.

    Octave 0 is the useful one to tabulate because every semitone of it fits
    under 1024 -- and since raising the block by one doubles the pitch for the
    same F-number, ONE table covers all eight octaves. Note number 57 (A4)
    gives block 4, fnum 580, which reads back as 580 * 49716 / 65536 = 440.0
    Hz exactly. }
  FN: array[0..11] of Word = (
    345, 365, 387, 410, 435, 460, 488, 517, 548, 580, 615, 651);

procedure OutB(P: Word; V: Byte);
begin
  asm
    mov dx, P
    mov al, V
    out dx, al
  end;
end;

function InB(P: Word): Byte;
var
  V: Byte;
begin
  asm
    mov dx, P
    in  al, dx
    mov V, al
  end;
  InB := V;
end;

{ The settling delay, as N reads of the status port.

  The chip needs >3.3us after an address byte and >23us after a data byte, and
  the delay is spent reading 388h because an ISA I/O cycle cannot go faster
  than the bus -- so the count of reads is the guarantee, whatever the CPU
  speed.

  It is an assembler loop and not a Pascal one on purpose. BENCH puts a Pascal
  loop iteration at about 11us, so amozart.pas spends roughly 480us on every
  register write; that is fine when the program is doing nothing else, and far
  too much for a caller with a frame to finish. Same number of bus cycles,
  about a sixth of the wall clock. }
procedure OplDelay(N: Word); assembler;
asm
  mov  cx, N
  jcxz @@done
  mov  dx, OPL_ADDR
@@l:
  in   al, dx
  loop @@l
@@done:
end;

procedure OplWrite(Reg, Val: Byte);
begin
  OutB(OPL_ADDR, Reg);
  OplDelay(8);
  OutB(OPL_DATA, Val);
  OplDelay(36);
end;

function OplDetect: Boolean;
begin
  { The timer method from the AdLib manual. Mask both timers, reset the flags,
    and the top three status bits must read 0. Then preset timer 1 so it
    overflows in about 80us, start it, wait well past that, and the top two
    bits must now be set. Only that 00h -> C0h transition is proof; a floating
    port does neither. }
  OplWrite($04, $60);
  OplWrite($04, $80);
  OplIdle := InB(OPL_ADDR) and $E0;
  OplWrite($02, $FF);
  OplWrite($04, $21);
  OplDelay(240);
  OplTimer := InB(OPL_ADDR) and $E0;
  OplWrite($04, $60);
  OplWrite($04, $80);
  OplDetect := (OplIdle = $00) and (OplTimer = $C0);
end;

procedure OplInitChip;
var
  R: Byte;
begin
  OplWrite($01, $20);          { waveform-select registers enabled }
  OplWrite($08, $00);          { no NOTE-SEL, no composite sine }
  OplWrite($BD, $00);          { melodic mode, no deep vibrato or tremolo }
  for R := 0 to 8 do OplWrite(Byte($B0 + R), $00);
end;

{ Operator register offsets. Channels 0..8 take their modulator and carrier
  from slots laid out in threes, which is why this is a table and not
  arithmetic. }
const
  ModOfs: array[0..8] of Byte = ($00, $01, $02, $08, $09, $0A, $10, $11, $12);
  CarOfs: array[0..8] of Byte = ($03, $04, $05, $0B, $0C, $0D, $13, $14, $15);

procedure OplOp(Ofs: Byte; const O: TOplOp);
begin
  OplWrite(Byte($20 + Ofs), O.Flags);
  OplWrite(Byte($40 + Ofs), O.Level);
  OplWrite(Byte($60 + Ofs), O.AtkDec);
  OplWrite(Byte($80 + Ofs), O.SusRel);
  OplWrite(Byte($E0 + Ofs), O.Wave);
end;

procedure OplVoice(Ch: Byte; const V: TOplVoice);
begin
  if Ch > 8 then Exit;
  OplOp(ModOfs[Ch], V.M);
  OplOp(CarOfs[Ch], V.C);
  OplWrite(Byte($C0 + Ch), V.Fb);
end;

procedure OplNoteOn(Ch, Note: Byte);
var
  Blk : Byte;
  Fnum: Word;
begin
  if Ch > 8 then Exit;
  if Note > 95 then Note := 95;
  Blk  := Note div 12;
  Fnum := FN[Note mod 12];
  OplWrite(Byte($A0 + Ch), Byte(Fnum and $FF));
  OplWrite(Byte($B0 + Ch), Byte($20 or (Blk shl 2) or ((Fnum shr 8) and $03)));
end;

procedure OplNoteOff(Ch: Byte);
begin
  if Ch > 8 then Exit;
  OplWrite(Byte($B0 + Ch), $00);
end;

procedure OplSilence;
var
  R: Byte;
begin
  for R := 0 to 8 do OplWrite(Byte($B0 + R), $00);
  for R := $40 to $55 do OplWrite(R, $3F);
  OplWrite($BD, $00);
end;

begin
  OplIdle  := 0;
  OplTimer := 0;
end.
