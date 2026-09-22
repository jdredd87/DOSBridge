unit PmDet;
{ DOS Bridge  --  StevenC }
{ Is there a PicoMEM in this machine, and what is it?

  STRICTLY READ-ONLY.  It asks the card BIOS one question through INT 13h and
  then does nothing but read -- the I/O port for its status byte, and the
  card's own ROM and shared memory for everything else.  Not one command byte
  is ever written to the card's command port.

  That is not tidiness.  On both development machines the PicoMEM IS the boot
  disk, so a stray command reaches the disk the system is running from.  The
  full toolset in CH375USBTools/PicoMEM sends a short whitelist of queries and
  argues for each one in its own README; a graphics demo has no business on
  that list, so this unit does not have a write path at all.

  What it knows is taken from that project rather than rediscovered:

    INT 13h AH=60h, DX=1234h   the card BIOS answers DX=AA55h and hands back
                               its I/O base in AX, its ROM segment in BX and
                               a device mask in CX
    base+3                     a counter that increments on every read, which
                               is how you tell a PicoMEM from a floating bus
    ROM+0..1023                carries "(Date yyyy-mm-dd)"; the offset moves
                               between builds, so it is searched for
    ROM:4000h                  8 KB of shared memory, +0 reads 12h when it is
                               really there

  Board id 11 is a PicoMEM 2 later than the published model list -- which is
  what is in the machine this was written on. }

{$MODE OBJFPC}{$H-}
{$ASMMODE INTEL}

interface

var
  PmFound   : Boolean;    { the card BIOS answered AA55h }
  PmBase    : Word;       { I/O base, typically 02A0h }
  PmRomSeg  : Word;       { segment its 16 KB option ROM is at }
  PmMask    : Word;       { device mask the BIOS returned }
  PmSeq     : Word;       { of PM_READS reads of base+3, how many followed on }
  PmStatus  : Byte;       { the status byte, read once }
  PmBoard   : Byte;       { board id out of shared memory }
  PmIrq     : Byte;
  PmDate    : ShortString;{ the ROM's own build date, or '' }
  PmRomName : ShortString;{ "PMBIOSP" }
  PmShared  : Boolean;    { shared memory really answered }

const
  PM_READS = 64;          { reads used to confirm the counter is a counter }

{ Probe.  Safe to call with no card fitted: INT 13h AH=60h is not a defined
  BIOS function, so a machine without one leaves DX alone and the check fails.
  Everything after that is gated on it. }
function PmProbe: Boolean;

{ One-line description of the board, for the information dump. }
function PmBoardName: ShortString;

implementation

uses Dos;

function InB(P: Word): Byte; assembler;
asm
  mov dx, P
  in  al, dx
end;

function GetFlags: Word; assembler;
asm
  pushf
  pop ax
end;

{ FPC's Intr loads the whole register record into the CPU, Flags included, so
  a FillChar'd record clears IF and the BIOS tick stops -- which shows up
  later as a demo that thinks no time has passed.  Carry the real flags in,
  and put interrupts back on afterwards in case the card BIOS returned with
  them off. }
function AskBios: Boolean;
var
  R: Registers;
  F: Word;
begin
  F := GetFlags;
  FillChar(R, SizeOf(R), 0);
  R.Flags := F;
  R.AH := $60;
  R.AL := 0;
  R.DX := $1234;
  Intr($13, R);
  if (F and $0200) <> 0 then asm sti end;
  AskBios := R.DX = $AA55;
  if AskBios then
  begin
    PmBase   := R.AX;
    PmRomSeg := R.BX;
    PmMask   := R.CX;
  end;
end;

{ base+3 increments on every read.  Counting how many of N reads carried on
  from the one before separates a real card from a floating bus, which
  answers FF to everything, and from some other device that happens to live
  at that address. }
function SeqReads(N: Word): Word;
var
  Prev, Cur: Byte;
  I, Good  : Word;
begin
  Good := 0;
  Prev := InB(PmBase + 3);
  for I := 1 to N do
  begin
    Cur := InB(PmBase + 3);
    if Cur = Byte(Prev + 1) then Inc(Good);
    Prev := Cur;
  end;
  SeqReads := Good;
end;

function RomDate: ShortString;
var
  I, J: Word;
  S   : ShortString;
  C   : Char;
begin
  RomDate := '';
  if PmRomSeg = 0 then Exit;
  for I := 0 to 1023 do
    if (Mem[PmRomSeg : I] = Ord('(')) and (Mem[PmRomSeg : I + 1] = Ord('D')) and
       (Mem[PmRomSeg : I + 2] = Ord('a')) and (Mem[PmRomSeg : I + 3] = Ord('t')) and
       (Mem[PmRomSeg : I + 4] = Ord('e')) then
    begin
      S := '';
      for J := I + 6 to I + 15 do
      begin
        C := Chr(Mem[PmRomSeg : J]);
        if (C < ' ') or (C > '~') or (C = ')') then Break;
        S := S + C;
      end;
      RomDate := S;
      Exit;
    end;
end;

function RomName: ShortString;
var
  I: Word;
  S: ShortString;
  C: Char;
begin
  S := '';
  if PmRomSeg <> 0 then
    for I := 4 to 20 do
    begin
      C := Chr(Mem[PmRomSeg : I]);
      if (C >= 'A') and (C <= 'Z') then S := S + C
      else if S <> '' then Break;
    end;
  RomName := S;
end;

function PmProbe: Boolean;
begin
  PmFound   := False;
  PmBase    := 0;
  PmRomSeg  := 0;
  PmMask    := 0;
  PmSeq     := 0;
  PmStatus  := $FF;
  PmBoard   := 0;
  PmIrq     := 0;
  PmDate    := '';
  PmRomName := '';
  PmShared  := False;

  if not AskBios then
  begin
    PmProbe := False;
    Exit;
  end;

  PmFound   := True;
  PmSeq     := SeqReads(PM_READS);
  PmStatus  := InB(PmBase);
  PmDate    := RomDate;
  PmRomName := RomName;

  { +0 of the shared memory reads 12h when the card is really mapping it.
    Everything below that byte would otherwise be whatever is at D000:4000. }
  if PmRomSeg <> 0 then
    PmShared := Mem[PmRomSeg : $4000] = $12;

  if PmShared then
  begin
    PmBoard := Mem[PmRomSeg : $4000 + 27];
    PmIrq   := Mem[PmRomSeg : $4000 + 11];
  end;

  PmProbe := True;
end;

function PmBoardName: ShortString;
begin
  case PmBoard of
    0 : PmBoardName := 'prototype';
    1 : PmBoardName := 'PicoMEM 1';
    2 : PmBoardName := 'PicoMEM 1.0 to 1.14';
    3 : PmBoardName := 'PicoMEM 1.3';
    4 : PmBoardName := 'PicoMEM 1.4';
    9 : PmBoardName := 'PicoMEM 1.5';
   10 : PmBoardName := 'PicoMEM 2';
   11 : PmBoardName := 'PicoMEM 2, later than the published model list';
  else
    PmBoardName := 'unrecognised board id';
  end;
end;

end.
