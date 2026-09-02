program Bench;
{ DOS Bridge  --  StevenC }
{ Measure what this machine is actually fast and slow at.

  Usage:  BENCH [ticks-per-test]     default 18, about one second each

  Why this exists: optimising the graphics demos meant guessing which operation
  was expensive, and the guesses were wrong twice -- once blaming VBE bank
  switching that turned out to be free, once blaming call overhead that was
  not the bottleneck. Each wrong guess cost a compile, a deploy and a thirty
  second run. These numbers answer the question directly.

  Method: run a batch of work, check the BIOS tick counter, repeat until the
  requested number of ticks has passed, then divide. Batches keep the clock
  reads from dominating. Everything accumulates into a global so the optimiser
  cannot delete the work being measured. }

{$MODE OBJFPC}{$H-}
{$ASMMODE INTEL}

uses Cpu, About;

const
  BATCH = 2000;

var
  TestTicks : LongInt;
  Sink      : LongInt;      { global, so nothing here can be optimised away }
  SinkW     : Word;
  Code      : Integer;

  A16, B16  : Integer;
  A32, B32  : LongInt;

  { Operands for the coprocessor section. Multiplying and dividing by 1.0 keeps
    the value from drifting to infinity over a long run without changing what
    is being timed. }
  FA        : Double;
  FB        : Double;
  Buf       : array[0..1023] of Word;

function Ticks: LongInt;
begin
  Ticks := MemL[$0040:$006C];
end;

{ Runs Op for TestTicks worth of time and reports the rate. Count is returned
  in whole operations; the caller says how many ops one batch performs. }
procedure Report(const Name: ShortString; Ops: LongInt; Elapsed: LongInt);
var
  PerSec: LongInt;
begin
  if Elapsed <= 0 then Elapsed := 1;
  { Ops can be large, so scale by ticks-per-second as 182/10 to stay in range. }
  PerSec := (Ops div Elapsed) * 18 + ((Ops div Elapsed) * 2) div 10;
  WriteLn('  ', Name, '':(22 - Length(Name)), PerSec:10, ' /sec');
end;

procedure BenchEmptyLoop;
var
  T0, N: LongInt;
  I: Integer;
begin
  N := 0;
  T0 := Ticks;
  while (Ticks - T0) < TestTicks do
  begin
    for I := 1 to BATCH do
      Inc(SinkW);
    Inc(N, BATCH);
  end;
  Report('loop + increment', N, Ticks - T0);
end;

procedure BenchAdd16;
var
  T0, N: LongInt;
  I: Integer;
begin
  N := 0; A16 := 3; B16 := 7;
  T0 := Ticks;
  while (Ticks - T0) < TestTicks do
  begin
    for I := 1 to BATCH do
      SinkW := Word(A16 + B16);
    Inc(N, BATCH);
  end;
  Report('16-bit add', N, Ticks - T0);
end;

procedure BenchMul16;
var
  T0, N: LongInt;
  I: Integer;
begin
  N := 0; A16 := 123; B16 := 45;
  T0 := Ticks;
  while (Ticks - T0) < TestTicks do
  begin
    for I := 1 to BATCH do
      SinkW := Word(A16 * B16);
    Inc(N, BATCH);
  end;
  Report('16-bit multiply', N, Ticks - T0);
end;

procedure BenchMul32;
var
  T0, N: LongInt;
  I: Integer;
begin
  N := 0; A32 := 123456; B32 := 45;
  T0 := Ticks;
  while (Ticks - T0) < TestTicks do
  begin
    for I := 1 to BATCH do
      Sink := A32 * B32;
    Inc(N, BATCH);
  end;
  Report('32-bit multiply', N, Ticks - T0);
end;

procedure BenchDiv16;
var
  T0, N: LongInt;
  I: Integer;
begin
  N := 0; A16 := 30000; B16 := 7;
  T0 := Ticks;
  while (Ticks - T0) < TestTicks do
  begin
    for I := 1 to BATCH do
      SinkW := Word(A16 div B16);
    Inc(N, BATCH);
  end;
  Report('16-bit divide', N, Ticks - T0);
end;

procedure BenchDiv32;
var
  T0, N: LongInt;
  I: Integer;
begin
  N := 0; A32 := 123456789; B32 := 37;
  T0 := Ticks;
  while (Ticks - T0) < TestTicks do
  begin
    for I := 1 to BATCH do
      Sink := A32 div B32;
    Inc(N, BATCH);
  end;
  Report('32-bit divide', N, Ticks - T0);
end;

{ Pascal-level array store, the pattern the demos actually used. }
procedure BenchArrayStore;
var
  T0, N: LongInt;
  I: Integer;
begin
  N := 0;
  T0 := Ticks;
  while (Ticks - T0) < TestTicks do
  begin
    for I := 0 to 1023 do
      Buf[I] := Word(I);
    Inc(N, 1024);
  end;
  Report('array[] store', N, Ticks - T0);
end;

{ Far pointer store into video memory, one word at a time, the way Mem[] does
  it. This is the thing that held the bouncing balls to 17 fps. }
procedure BenchVideoWord;
var
  T0, N: LongInt;
  I: Integer;
begin
  N := 0;
  T0 := Ticks;
  while (Ticks - T0) < TestTicks do
  begin
    for I := 0 to 999 do
      MemW[$B800 : Word(I * 2)] := $0720;
    Inc(N, 1000);
  end;
  Report('MemW[] to B800', N, Ticks - T0);
end;

{ The same bytes moved with REP STOSW instead. }
procedure BenchVideoRep;
var
  T0, N: LongInt;
begin
  N := 0;
  T0 := Ticks;
  while (Ticks - T0) < TestTicks do
  begin
    asm
      push es
      push di
      mov  ax, 0B800h
      mov  es, ax
      xor  di, di
      mov  cx, 1000
      mov  ax, 0720h
      cld
      rep  stosw
      pop  di
      pop  es
    end;
    Inc(N, 1000);
  end;
  Report('REP STOSW to B800', N, Ticks - T0);
end;

{ --- the one place a non-baseline instruction is allowed --------------------

  Shifting by more than one bit. The 8086 has no immediate-count form, so the
  count has to be loaded into CL first and the CPU then walks it a bit at a
  time. The NEC V20/V30 and the 80186 added `SHL reg, imm8`, which does it in
  one instruction.

  Both versions are here on purpose. This is the pattern for anything faster
  than the 8086 baseline: write the portable version, write the fast version,
  and let Has186 decide at run time which one executes. The 8086 path is never
  removed, because it is the one that has to work on an unknown machine.

  The fast form is emitted as raw bytes rather than written as `shl ax, 4`,
  because the assembler is targeting the 8086 and would be right to reject it.
  C1 E0 ib is SHL AX, imm8. }

procedure BenchShiftCl;
var
  T0, N: LongInt;
begin
  N := 0;
  T0 := Ticks;
  while (Ticks - T0) < TestTicks do
  begin
    asm
      push si
      mov  si, 1000
    @@lp:
      mov  ax, 1234h
      mov  cl, 4
      shl  ax, cl
      dec  si
      jnz  @@lp
      mov  SinkW, ax
      pop  si
    end;
    Inc(N, 1000);
  end;
  Report('shl by CL (8086)', N, Ticks - T0);
end;

procedure BenchShiftImm;
var
  T0, N: LongInt;
begin
  if not Has186 then
  begin
    WriteLn('  shl by imm (186)  : not available on this CPU, skipped');
    Exit;
  end;
  N := 0;
  T0 := Ticks;
  while (Ticks - T0) < TestTicks do
  begin
    asm
      push si
      mov  si, 1000
    @@lp:
      mov  ax, 1234h
      db   0C1h, 0E0h, 004h     { shl ax, 4 }
      dec  si
      jnz  @@lp
      mov  SinkW, ax
      pop  si
    end;
    Inc(N, 1000);
  end;
  Report('shl by imm (186)', N, Ticks - T0);
end;

{ --- math coprocessor ------------------------------------------------------

  Skipped entirely, not merely zero-scored, when there is no coprocessor: an
  x87 instruction on a machine without one is silently ignored rather than
  faulting, so an ungated benchmark would report a spectacular rate for work
  that never happened.

  These exist to answer a question nobody here has real numbers for yet: is an
  8087 actually faster than the Q8 fixed-point arithmetic the demos use? On an
  8086-class machine it is genuinely not obvious -- 8087 FMUL and a 16-bit IMUL
  are within a factor of two of each other, and the fixed-point code needs only
  one multiply per iteration. Compare "FPU multiply" against "16-bit multiply"
  above before converting anything. }

procedure BenchFpu(const Nm: ShortString; Op: Integer);
var
  T0, N: LongInt;
begin
  if not HasFpu then
  begin
    WriteLn('  ', Nm, ' : no coprocessor, skipped');
    Exit;
  end;
  N := 0;
  T0 := Ticks;
  while (Ticks - T0) < TestTicks do
  begin
    case Op of
      0: asm
           fninit
           fld  FA
           push si
           mov  si, 1000
         @@a:
           fadd FB
           dec  si
           jnz  @@a
           pop  si
           fstp FA
           fwait
         end;
      1: asm
           fninit
           fld  FA
           push si
           mov  si, 1000
         @@m:
           fmul FB
           dec  si
           jnz  @@m
           pop  si
           fstp FA
           fwait
         end;
      2: asm
           fninit
           fld  FA
           push si
           mov  si, 1000
         @@d:
           fdiv FB
           dec  si
           jnz  @@d
           pop  si
           fstp FA
           fwait
         end;
      3: asm
           fninit
           fld  FA
           push si
           mov  si, 1000
         @@s:
           fsqrt
           dec  si
           jnz  @@s
           pop  si
           fstp FA
           fwait
         end;
    end;
    Inc(N, 1000);
  end;
  Report(Nm, N, Ticks - T0);
end;

procedure Nothing; begin Inc(SinkW); end;

procedure BenchCall;
var
  T0, N: LongInt;
  I: Integer;
begin
  N := 0;
  T0 := Ticks;
  while (Ticks - T0) < TestTicks do
  begin
    for I := 1 to BATCH do
      Nothing;
    Inc(N, BATCH);
  end;
  Report('procedure call', N, Ticks - T0);
end;

begin
  TestTicks := 18;
  if ParamCount >= 1 then
  begin
    Val(ParamStr(1), TestTicks, Code);
    if (Code <> 0) or (TestTicks < 5) or (TestTicks > 180) then TestTicks := 18;
  end;

  Sink := 0; SinkW := 0;

  { 1.0 for both: FADD then walks up by one per iteration and the others hold
    steady, so nothing overflows or denormalises during a long run. }
  FA := 1.0;
  FB := 1.0;

  WriteLn('=== bench: what this machine is fast and slow at ===');
  WriteLn('  CPU: ', CpuName, '   coprocessor: ', FpuName);
  WriteLn('  ', TestTicks, ' ticks per test (', (TestTicks * 10) div 182,
          '.', ((TestTicks * 100) div 182) mod 10, ' sec each)');
  WriteLn;

  BenchEmptyLoop;
  BenchAdd16;
  BenchMul16;
  BenchDiv16;
  BenchMul32;
  BenchDiv32;
  BenchArrayStore;
  BenchCall;
  BenchShiftCl;
  BenchShiftImm;
  BenchVideoWord;
  BenchVideoRep;
  BenchFpu('FPU add          ', 0);
  BenchFpu('FPU multiply     ', 1);
  BenchFpu('FPU divide       ', 2);
  BenchFpu('FPU sqrt         ', 3);

  WriteLn;
  WriteLn('  (sink ', Sink, ' ', SinkW, ' -- printed so the work is not dead code)');
end.
