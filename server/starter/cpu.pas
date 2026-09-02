unit Cpu;
{ DOS Bridge  --  StevenC }
{ Work out what processor this actually is, at run time.

  Everything in starter/ is built with -Pi8086 and sticks to the plain 8086
  instruction set, so it runs on any DOS machine from an original PC upwards.
  That is deliberate: the bridge is not tied to one box, and a program that
  will not load is a much worse outcome than one that runs a little slower.

  But some machines can do better than the baseline, and this unit is how you
  find out without giving up the ability to run on the baseline. The NEC
  V20/V30 and the 80186 both add instructions the 8086 lacks -- shifts by an
  immediate count, IMUL with an immediate, PUSHA/POPA, ENTER/LEAVE, the string
  I/O instructions. `Has186` is true exactly when those are safe to execute.

  The rule for using it: never assemble a 186-class instruction on a path the
  8086 can reach. Write both versions, pick between them with `if Has186`, and
  keep the 8086 version working -- it is the one that gets tested everywhere.
  BENCH does this for immediate shifts and prints both numbers.

  Detection, in the order it has to happen:

    1. FLAGS bits 12-15. On the 8086/88, the V20/V30 and the 186 those bits
       always read back as 1 no matter what you push. A 286 in real mode reads
       them back as 0 and will not let you set them; a 386 or later reads bit
       15 back as 0 but does allow NT and IOPL to be set. Two POPF/PUSHF
       round trips separate the three groups.

    2. Within the first group, the undocumented AAD opcode (D5h) settles NEC
       against Intel. AAD takes a base operand: Intel honours it, NEC's parts
       ignore it and always use base 10. With AH=1, AL=0 and base 11 an Intel
       part answers 11 and a V20/V30 answers 10.

    3. Only if step 2 said Intel, the shift-count test splits 8086 from 186.
       The 8086 shifts the full count in CL; the 186 masks it to five bits, so
       a shift of 32 moves nothing there and clears the register here.

  Step 3 comes last on purpose. Sources disagree about whether the V20/V30
  masks shift counts, so this never asks it that question -- by the time the
  shift test runs, AAD has already ruled NEC out. }

{$MODE OBJFPC}{$H-}
{$ASMMODE INTEL}

interface

const
  cpuUnknown = 0;
  cpu8086    = 1;      { Intel 8086 / 8088 }
  cpuNecV    = 2;      { NEC V20 / V30 (also V40 / V50) }
  cpu186     = 3;      { Intel 80186 / 80188 }
  cpu286     = 4;      { Intel 80286 }
  cpu386     = 5;      { 80386 or later -- not narrowed further }

{ Which of the above this machine is. Probed once, then cached. }
function CpuClass: Integer;

{ Printable form of the same thing, e.g. 'NEC V20/V30'. }
function CpuName: ShortString;

{ True when the 80186 instruction-set extensions are available. False only on
  a genuine 8086/8088. Gate any non-baseline code path on this. }
function Has186: Boolean;

{ --- math coprocessor ---------------------------------------------------

  Same rule as Has186, and it matters more here: an x87 instruction on a
  machine with no coprocessor does not fault on an 8086, it is simply ignored,
  so the code runs and quietly produces garbage. That is worse than a crash.
  Never execute an ESC opcode without checking HasFpu first. }

const
  fpuNone  = 0;
  fpu8087  = 1;      { Intel 8087 }
  fpu287   = 2;      { Intel 80287 }
  fpu387   = 3;      { 80387 or later, including a 486DX's on-die unit }

function HasFpu: Boolean;
function FpuClass: Integer;
function FpuName: ShortString;

{ The control and status words as they read straight after FNINIT. Zero when
  there is no coprocessor. FPU.EXE prints these; they are the raw evidence
  behind FpuClass. }
function FpuCw: Word;
function FpuSw: Word;

implementation

var
  Known  : Boolean = False;
  Klass  : Integer = cpuUnknown;

{ Results come back through unit globals rather than locals. FPC's i8086 asm
  will address a local fine, but the surrounding code here pushes and pops the
  flags and it is one less thing to reason about. }
var
  RW : Word;
  RB : Byte;

var
  FpuKnown : Boolean = False;
  FpuKlass : Integer = fpuNone;
  CwAfter  : Word = 0;
  SwAfter  : Word = 0;

{$IFDEF CPUI8086}

{ Read FLAGS, apply AndMask then OrMask to it, write it back, and report which
  of bits 12-15 the CPU actually kept. The caller's flags are restored before
  returning -- this runs with interrupts on and must leave them that way.

  Masks rather than a boolean so the asm needs no branch: a conditional jump
  in here would have to be written around the very flags being tested. }
procedure FlagsAfter(AndMask, OrMask: Word);
var
  A, O: Word;
begin
  A := AndMask;
  O := OrMask;
  asm
    pushf                 { the caller's flags, to put back at the end }
    pushf
    pop   ax
    and   ax, A
    or    ax, O
    push  ax
    popf                  { try to make it so }
    pushf
    pop   ax              { and see what actually stuck }
    mov   RW, ax
    popf                  { caller's flags back }
  end;
  RW := RW and $F000;
end;

{ AAD with a base of 11. Intel computes AH*11 + AL = 11; NEC ignores the
  operand and computes AH*10 + AL = 10. }
procedure AadProbe;
begin
  asm
    mov ah, 1
    mov al, 0
    db  0D5h, 0Bh
    mov RB, al
  end;
end;

{ Shift 1 left by 32. The 8086 does it 32 times and lands on 0; the 186 and
  later mask the count to five bits, so 32 becomes 0 and the value survives. }
procedure ShiftProbe;
begin
  asm
    mov al, 1
    mov cl, 32
    shl al, cl
    mov RB, al
  end;
end;

procedure Probe;
begin
  { Can bits 12-15 be cleared? On 8086-class parts they cannot. }
  FlagsAfter($0FFF, $0000);
  if RW = $F000 then
  begin
    AadProbe;
    if RB = 10 then
      Klass := cpuNecV
    else
    begin
      ShiftProbe;
      if RB = 0 then Klass := cpu8086 else Klass := cpu186;
    end;
    Exit;
  end;

  { Not 8086-class. Can bits 12-15 be set? A 286 refuses outright; a 386 or
    later keeps NT and IOPL but always reads bit 15 back as 0. }
  FlagsAfter($FFFF, $F000);
  if RW = 0 then Klass := cpu286 else Klass := cpu386;
end;

{ --- coprocessor probe -------------------------------------------------

  The classic sequence, and every part of it is load-bearing.

  * FNINIT / FNSTSW / FNSTCW, not FINIT / FSTSW / FSTCW. The un-prefixed forms
    assemble a WAIT (9Bh) in front, and WAIT on a machine with no coprocessor
    waits on the TEST pin for a signal that is never coming -- which hangs the
    box, and over the bridge that is indistinguishable from any other hang.
    FPC emits the FN forms verbatim with no 9Bh; that has been checked in the
    linked binary, not assumed.

  * The status word is seeded with a value FNINIT cannot produce. With no
    coprocessor the 8086 still decodes ESC and runs a dummy *read* cycle for
    the operand, but nothing ever writes back, so the seed survives untouched.
    Seeing 0 there is the proof that something answered.

  * The NOPs matter on an 8086/8087 pair. The CPU does not interlock with the
    coprocessor, so it can reach the FNSTSW store before FNINIT has finished
    and read a stale word. A short delay loop removes the race.

  Safety on a 286 or 386: if the EM bit is set in MSW/CR0, ESC traps to INT 7
  instead. Under plain DOS that means an emulator is installed and handling it,
  in which case reporting "coprocessor present" is the useful answer anyway --
  floating point will work. There is no cheap way to tell emulation from
  silicon, and FPU.EXE says so rather than pretending otherwise. }

procedure FpuProbe;
begin
  { One store per ESC, with room either side. THIS is the thing that was wrong.
    An earlier version issued FNSTSW and FNSTCW back-to-back and concluded
    "no coprocessor" on a machine with an 8087 fitted -- because the second
    store is simply lost. The 8087 is still executing the first when the next
    ESC arrives, and no amount of delay *around* the pair helps: measured on
    real hardware, the control word stayed at its seed value for every spin
    count from 0 to 20000, while the same instruction issued on its own
    returned 03FF immediately.

    So the control word is fetched alone. It is also the better test of the
    two: FNSTSW on this machine returns 0340 rather than the 0000 the manuals
    predict, which is exactly the kind of ambiguity a presence check should not
    be built on, whereas the control word reads 03FF and decodes cleanly. }

  CwAfter := $5A5A;              { a value FNINIT can never leave behind }
  asm
    fninit
    mov  cx, 200                 { let FNINIT finish; the 8086 does not wait }
  @@d1:
    dec  cx
    jnz  @@d1

    fnstcw CwAfter               { alone: nothing else between the delays }

    mov  cx, 200                 { and let the store land before Pascal reads }
  @@d2:
    dec  cx
    jnz  @@d2
  end;

  if CwAfter = $5A5A then
  begin
    { Seed untouched: the ESC was ignored, so nothing is out there. }
    FpuKlass := fpuNone;
    SwAfter  := $5A5A;
    Exit;
  end;

  { After FNINIT every exception is masked and the low field reads 3Fh on
    every part from the 8087 onwards. Anything else is a bus artefact. }
  if (CwAfter and $103F) <> $003F then
  begin
    FpuKlass := fpuNone;
    SwAfter  := $5A5A;
    Exit;
  end;

  { Bit 7 is the 8087's Interrupt Enable Mask, which FNINIT sets. The 80287
    dropped the bit, so FNINIT leaves 03FFh on an 8087 and 037Fh on a 287 or
    later. Confirmed against real hardware: this box reads 03FF. }
  if (CwAfter and $0080) <> 0 then
    FpuKlass := fpu8087
  else if CpuClass >= cpu386 then
    FpuKlass := fpu387
  else
    FpuKlass := fpu287;

  { The status word, fetched separately for the same reason, and kept only for
    reporting -- nothing branches on it. }
  SwAfter := $5A5A;
  asm
    fnstsw SwAfter
    mov  cx, 200
  @@d3:
    dec  cx
    jnz  @@d3
  end;
end;

{$ELSE}

procedure FpuProbe;
begin
  FpuKlass := fpuNone;
end;

{ Host builds exist only so the unit can be syntax-checked with a normal
  compiler. Nothing here can answer the question. }
procedure Probe;
begin
  Klass := cpuUnknown;
end;

{$ENDIF}

function CpuClass: Integer;
begin
  if not Known then
  begin
    Probe;
    Known := True;
  end;
  CpuClass := Klass;
end;

function CpuName: ShortString;
begin
  case CpuClass of
    cpu8086 : CpuName := 'Intel 8086/8088';
    cpuNecV : CpuName := 'NEC V20/V30';
    cpu186  : CpuName := 'Intel 80186/80188';
    cpu286  : CpuName := 'Intel 80286';
    cpu386  : CpuName := '80386 or later';
  else
    CpuName := 'unknown (probe did not run)';
  end;
end;

function Has186: Boolean;
begin
  Has186 := CpuClass >= cpuNecV;
end;

function FpuClass: Integer;
begin
  if not FpuKnown then
  begin
    FpuProbe;
    FpuKnown := True;
  end;
  FpuClass := FpuKlass;
end;

function HasFpu: Boolean;
begin
  HasFpu := FpuClass <> fpuNone;
end;

function FpuName: ShortString;
begin
  case FpuClass of
    fpu8087 : FpuName := 'Intel 8087';
    fpu287  : FpuName := 'Intel 80287';
    fpu387  : FpuName := '80387 or later';
  else
    FpuName := 'none';
  end;
end;

function FpuCw: Word;
begin
  FpuClass;              { force the probe }
  FpuCw := CwAfter;
end;

function FpuSw: Word;
begin
  FpuClass;
  FpuSw := SwAfter;
end;

end.
