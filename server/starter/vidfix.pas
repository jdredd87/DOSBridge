unit VidFix;
{ DOS Bridge  --  StevenC & Claude }
{ Put INT 10h back when the runtime has hooked it with a coprocessor stub.

  WHAT GOES WRONG.  Free Pascal's i8086 runtime installs a coprocessor-error
  handler at startup and, on a machine where it believes an x87 is present,
  puts it on **INT 10h** -- the video BIOS vector -- as well as on INT 75h
  (IRQ13) and INT 00h. The handler begins with FNSTSW: it reads the x87
  status word and, when bit 7 says an exception is pending, raises a runtime
  error instead of chaining to the video BIOS.

  On a machine with no coprocessor that read is meaningless, and what it
  returns is not the same everywhere:

  | 8086/V30, no 8087 | nothing drives the bus, the word stays 0 -> chains, all well |
  | 386, no 387       | the word reads back with bit 7 set -> the error path is taken |

  So on a 386 with no 387 the FIRST video BIOS call from any FPC program
  never reaches the video BIOS and the machine stops dead. Measured
  2026-09-19: a 35-byte hand-assembled .COM ran INT 10h AH=0Fh on that
  machine and returned mode 3 correctly, while every FPC tool that called it
  froze -- HWINFO, VMODES, VSHOT, and anything else that asks the BIOS about
  the screen. VECX printed the vector: INT 10h pointing inside the running
  program, at a handler starting DD 3E, which is FNSTSW.

  WHAT THIS DOES.  In its initialization -- which FPC runs before the main
  program body, and therefore before any video call -- it acts only when ALL
  of these hold:

    * the CPU probe says there is no coprocessor, so the handler cannot have
      anything real to do;
    * INT 10h points into RAM rather than ROM, which the real video BIOS
      never does -- it lives at C000 or F000.  (The first version tested
      "inside this program's own code segment" and was WRONG: a
      large-model program has several code segments, and in a big binary
      the runtime's stub sits in a different one from this unit.  CAMLIVE
      found INT 10h at 5238:0202, decided nothing had hooked it, and
      froze on its first video call anyway.)
    * the bytes there are the stub's prologue AND begin the body with FNSTSW;
    * the address the runtime saved can be read back out of the stub, and it
      is in ROM (C000 or above).

  Then it puts that saved address back into INT 10h.

  If any test fails it does nothing at all and says why in `VidFixWhy`. On
  the V30 the runtime does not hook INT 10h, so the second test fails and
  this unit is inert -- the same binary is correct on both machines, which
  is the point.

  HOW THE SAVED ADDRESS IS RECOVERED.  The stub does not hold it inline. Its
  chain path copies two words out of the runtime's data segment over the
  return address and IRETs to them:

      BD lo hi        mov bp,<runtime data segment>   (in the prologue)
      DD 3E lo hi     fnstsw [status]
      F6 06 lo hi 80  test byte [status],80h
      74 xx           jz chain
      ...             error path: pushes the vector number and jumps away
      8B 0E lo hi     mov cx,[saved offset]
      89 4E 06        mov [bp+6],cx
      8B 0E lo hi     mov cx,[saved segment]
      89 4E 08        mov [bp+8],cx
      5D 1F 59 CF     pop bp / pop ds / pop cx / iret

  So the data segment comes from the prologue and the two offsets from that
  pattern; reading them gives the original vector.

  INT 75h is left alone deliberately: it is IRQ13, nothing else calls it, and
  a machine with no coprocessor never raises it. }

{$MODE OBJFPC}{$H-}{$ASMMODE INTEL}

interface

var
  { True when INT 10h was hooked and has been put back. }
  VidFixDone : Boolean = False;

  { What happened, for a tool that wants to report it. }
  VidFixWhy  : ShortString = '';

  { What INT 10h pointed at, and what it points at now, as seg:ofs. }
  VidFixFrom : LongInt = 0;
  VidFixTo   : LongInt = 0;

function VidFixReport: ShortString;

implementation

{ A coprocessor probe of its own, rather than `uses Cpu`, so this unit is one
  drop-in file in any project -- the CH375 collection has no Cpu unit. The
  sequence is the same one cpu.pas uses and every part of it is load-bearing:
  FNINIT and FNSTSW, never FINIT/FSTSW, because the un-prefixed forms
  assemble a WAIT in front and WAIT with nothing answering hangs the machine;
  and the status word is seeded with a value FNINIT cannot produce, so a
  machine where nothing writes it back is recognised by the seed surviving. }

const
  { pushf / sub sp,4 / push cx / push ds / push bp }
  Prologue : array[0..6] of Byte = ($9C, $83, $EC, $04, $51, $1E, $55);
  SCAN_MAX = 96;

function CoprocessorFitted: Boolean;
var Sw: Word;
begin
  Sw := $5A5A;
  asm
    fninit
    nop
    nop
    nop
    fnstsw Sw
  end;
  CoprocessorFitted := Sw = 0;
end;

function Pack(Sg, Of_: Word): LongInt;
begin
  Pack := (LongInt(Sg) shl 16) or Of_;
end;

function MyCS: Word; assembler;
asm
  mov ax, cs
end;

procedure SetVec10(Sg, Of_: Word);
begin
  asm
    pushf
    cli
  end;
  MemW[0 : $10 * 4]     := Of_;
  MemW[0 : $10 * 4 + 2] := Sg;
  asm
    popf
  end;
end;

function VidFixReport: ShortString;
begin
  if VidFixDone then VidFixReport := 'INT 10h un-hooked: ' + VidFixWhy
  else VidFixReport := 'INT 10h left alone: ' + VidFixWhy;
end;

function FindSaved(Sg, Of_: Word; out TSeg, TOfs: Word): Boolean;
var
  DSeg, I, V1, V2: Word;
begin
  FindSaved := False;
  TSeg := 0; TOfs := 0;
  if Mem[Sg : Of_ + 7] <> $BD then Exit;         { mov bp, imm16 }
  DSeg := MemW[Sg : Of_ + 8];

  I := 10;
  while I < SCAN_MAX do
  begin
    if (Mem[Sg : Of_ + I] = $8B) and (Mem[Sg : Of_ + I + 1] = $0E) and
       (Mem[Sg : Of_ + I + 4] = $89) and (Mem[Sg : Of_ + I + 5] = $4E) and
       (Mem[Sg : Of_ + I + 6] = $06) and
       (Mem[Sg : Of_ + I + 7] = $8B) and (Mem[Sg : Of_ + I + 8] = $0E) and
       (Mem[Sg : Of_ + I + 11] = $89) and (Mem[Sg : Of_ + I + 12] = $4E) and
       (Mem[Sg : Of_ + I + 13] = $08) then
    begin
      V1 := MemW[Sg : Of_ + I + 2];
      V2 := MemW[Sg : Of_ + I + 9];
      TOfs := MemW[DSeg : V1];
      TSeg := MemW[DSeg : V2];
      FindSaved := True;
      Exit;
    end;
    Inc(I);
  end;
end;

procedure Fix;
var
  Sg, Of_, I, TSeg, TOfs, Cs_: Word;
begin
  Cs_ := MyCS;
  Of_ := MemW[0 : $10 * 4];
  Sg  := MemW[0 : $10 * 4 + 2];
  VidFixFrom := Pack(Sg, Of_);

  if CoprocessorFitted then
  begin
    VidFixWhy := 'a coprocessor is fitted, so its handler is wanted';
    Exit;
  end;

  if Sg >= $C000 then
  begin
    VidFixWhy := 'it already points at ROM, so nothing has hooked it';
    Exit;
  end;

  for I := 0 to High(Prologue) do
    if Mem[Sg : Of_ + I] <> Prologue[I] then
    begin
      VidFixWhy := 'it points here but is not the runtime''s stub';
      Exit;
    end;

  if not ((Mem[Sg : Of_ + 12] = $DD) and (Mem[Sg : Of_ + 13] = $3E)) then
  begin
    VidFixWhy := 'the stub here does not begin with FNSTSW';
    Exit;
  end;

  if not FindSaved(Sg, Of_, TSeg, TOfs) then
  begin
    VidFixWhy := 'the saved vector could not be read out of the stub';
    Exit;
  end;

  VidFixTo := Pack(TSeg, TOfs);

  { The video BIOS is in ROM: C000 where the adapter has its own, F000 on a
    machine whose video BIOS is part of the system ROM. Anything else is not
    worth writing into the vector. }
  if TSeg < $C000 then
  begin
    VidFixWhy := 'the saved vector was not in ROM, so it was not trusted';
    Exit;
  end;

  SetVec10(TSeg, TOfs);
  VidFixDone := True;
  VidFixWhy  := 'no coprocessor, and the stub was on the video vector';
end;

initialization
  Fix;

end.
