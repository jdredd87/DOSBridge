program FpuTest;
{ DOS Bridge  --  StevenC }
{ Math coprocessor: is one fitted, which one, and does it compute correctly.

  Usage:  FPU           detect and report. Runs NO arithmetic. Safe.
          FPU /T        also run the arithmetic tests -- SEE THE WARNING

  WHY THE TESTS ARE OPT-IN

  They used to run automatically whenever the probe said a coprocessor was
  present, and that wedged the machine. The arithmetic below is ordinary x87,
  which the assembler encodes with WAIT (9Bh) prefixes -- and WAIT on a machine
  with no coprocessor waits on the TEST pin for a signal that never comes. It
  hangs, hard, and over the bridge that needs someone at the keyboard.

  So the danger is not the arithmetic. It is trusting the probe: one false
  positive turns a diagnostic into a machine that has to be power-cycled. The
  detection path itself never executes a WAIT, so it is safe to run always;
  the arithmetic now requires you to ask for it.

  Exit codes, chosen so a batch file can branch on them the way VIDCHK does:

      0   coprocessor present (and, with /T, every test passed)
      1   no coprocessor (this is a result, not an error)
      2   coprocessor present but at least one test FAILED

  This is the one tool here that is *about* the coprocessor, so it is the one
  place allowed to execute x87 instructions -- and even here they only run
  after Cpu.HasFpu has said it is safe. Everything else in starter/ stays on
  the integer path whether a coprocessor is fitted or not.

  Why the results are printed as raw hex rather than as numbers: formatting a
  Double for WriteLn drags FPC's software floating point into a 16-bit binary,
  which is exactly the dead weight the rest of the suite avoids. Comparing the
  eight bytes is also a stricter test than comparing printed decimals -- it
  catches a wrong low bit that a printed value would round away.

  The expected values are compile-time typed constants, so the bit patterns
  come from FPC's own parser rather than from anything hand-computed here. }

{$MODE OBJFPC}{$H-}
{$ASMMODE INTEL}

uses Cpu, Tester, About;

type
  { Overlay for looking at a Double as four 16-bit words. W[3] holds the sign
    and exponent, W[0] the least significant end of the mantissa. }
  TDbl = record
    case Boolean of
      False: (D: Double);
      True:  (W: array[0..3] of Word);
  end;

const
  { Operands and expected results. All exact in binary except where noted. }
  Two      : Double = 2.0;
  OnePoint5: Double = 1.5;
  Three    : Double = 3.0;
  One      : Double = 1.0;
  Eight    : Double = 8.0;
  Four     : Double = 4.0;
  Zero     : Double = 0.0;

  Exp4     : Double = 4.0;
  Exp45    : Double = 4.5;
  ExpEighth: Double = 0.125;
  Exp2     : Double = 2.0;

  { The Pentium FDIV pair. On a flawed part the round trip comes back as
    4195579 instead. Harmless on an 8087, and free to check. }
  FdivA    : Double = 4195835.0;
  FdivB    : Double = 3145727.0;

var
  R        : TDbl;
  E        : TDbl;
  Sw       : Word;
  DetectOnly : Boolean;
  I        : Integer;
  S        : ShortString;

const
  HexD: array[0..15] of Char = '0123456789ABCDEF';

function Hex4(W: Word): ShortString;
begin
  Hex4 := HexD[(W shr 12) and 15] + HexD[(W shr 8) and 15] +
          HexD[(W shr 4) and 15] + HexD[W and 15];
end;

{ A Double printed most-significant word first, the way it would be written
  as a 64-bit hex constant. }
function HexD64(const V: TDbl): ShortString;
begin
  HexD64 := Hex4(V.W[3]) + Hex4(V.W[2]) + Hex4(V.W[1]) + Hex4(V.W[0]);
end;

function SameBits(const A, B: TDbl): Boolean;
begin
  SameBits := (A.W[0] = B.W[0]) and (A.W[1] = B.W[1]) and
              (A.W[2] = B.W[2]) and (A.W[3] = B.W[3]);
end;

{ Equal to within N units in the last place. Only meaningful for two positive
  normal numbers of the same magnitude, which is all it is used for: the top
  three words must match exactly and only the low word may drift. }
function CloseBits(const A, B: TDbl; N: Word): Boolean;
var
  D: Word;
begin
  if (A.W[3] <> B.W[3]) or (A.W[2] <> B.W[2]) or (A.W[1] <> B.W[1]) then
  begin
    CloseBits := False;
    Exit;
  end;
  if A.W[0] >= B.W[0] then D := A.W[0] - B.W[0] else D := B.W[0] - A.W[0];
  CloseBits := D <= N;
end;

{ --- the arithmetic tests ------------------------------------------------
  Each one loads its operands, does the work on the coprocessor stack, stores
  the result and leaves the stack empty. FNINIT first every time so a failure
  in one test cannot cascade into the next.

  Note `fstp R.D` and not `fstp R`. R is a variant record, so naming it bare
  leaves the assembler with no operand size and it does not have to pick the
  one you meant -- a 32-bit store here would write a Single into the low half
  and leave the exponent words holding whatever was there before, which reads
  as a plausible wrong answer rather than as an error. Naming the Double field
  makes it emit `fstp qword`. Checked in the generated assembly. }

procedure TAdd;
begin
  asm
    fninit
    fld  Two
    fadd Two
    fstp R.D
    fwait
  end;
end;

procedure TMul;
begin
  asm
    fninit
    fld  OnePoint5
    fmul Three
    fstp R.D
    fwait
  end;
end;

procedure TDiv;
begin
  asm
    fninit
    fld  One
    fdiv Eight
    fstp R.D
    fwait
  end;
end;

procedure TSqrt;
begin
  asm
    fninit
    fld  Four
    fsqrt
    fstp R.D
    fwait
  end;
end;

{ (a / b) * b, which must land back on a. }
procedure TFdiv;
begin
  asm
    fninit
    fld  FdivA
    fdiv FdivB
    fmul FdivB
    fstp R.D
    fwait
  end;
end;

{ Divide by zero with the exceptions still masked, as FNINIT leaves them.
  The result must be +infinity and the zero-divide flag must be set. }
procedure TInf;
begin
  asm
    fninit
    fld  One
    fdiv Zero
    fstp R.D
    fnstsw Sw
    fwait
  end;
end;

begin
  { Inverted deliberately: the default is now detect-only. Anything that can
    hang a machine you cannot reach has to be asked for, not opted out of. }
  DetectOnly := True;
  for I := 1 to ParamCount do
  begin
    S := ParamStr(I);
    if (S = '/T') or (S = '/t') or (S = '-t') then DetectOnly := False;
  end;

  WriteLn('=== fpu: math coprocessor ===');
  WriteLn('  CPU              : ', CpuName);

  { Print the raw probe result either way. When this reports "none" the two
    words below are the entire evidence, and they say which kind of "none" it
    is: 5A5A is the seed untouched, meaning nothing wrote back at all, while
    anything else means something answered and the decoding is at fault. }
  WriteLn('  probe words      : status=', Hex4(FpuSw), '  control=', Hex4(FpuCw),
          '   (seed 5A5A means nothing answered)');

  if not HasFpu then
  begin
    { Nothing below this point executes an ESC opcode. }
    WriteLn('  coprocessor      : none');
    WriteLn;
    WriteLn('  No x87 was executed. Every other tool and demo in starter/ runs');
    WriteLn('  on the integer path and is unaffected by this.');
    Halt(1);
  end;

  WriteLn('  coprocessor      : ', FpuName);
  WriteLn('  control word     : ', Hex4(FpuCw), '  (FNINIT leaves 03FF on an',
          ' 8087, 037F on a 287 or later)');
  WriteLn('  status word      : ', Hex4(FpuSw));
  WriteLn('  NOTE             : a software emulator hooking INT 7 answers this',
          ' probe identically');
  WriteLn('                     to real silicon. Presence means floating point',
          ' works, not');
  WriteLn('                     that a chip is socketed.');
  WriteLn;

  if DetectOnly then
  begin
    WriteLn;
    WriteLn('  Arithmetic tests NOT run. Pass /T to run them -- but only if you');
    WriteLn('  trust the detection above, because x87 arithmetic carries WAIT');
    WriteLn('  prefixes and WAIT with no coprocessor hangs the machine.');
    Halt(0);
  end;

  TAdd;   E.D := Exp4;
  WriteLn('  2.0 + 2.0        : ', HexD64(R), '  want ', HexD64(E));
  Check('2.0 + 2.0 = 4.0', SameBits(R, E));

  TMul;   E.D := Exp45;
  WriteLn('  1.5 * 3.0        : ', HexD64(R), '  want ', HexD64(E));
  Check('1.5 * 3.0 = 4.5', SameBits(R, E));

  TDiv;   E.D := ExpEighth;
  WriteLn('  1.0 / 8.0        : ', HexD64(R), '  want ', HexD64(E));
  Check('1.0 / 8.0 = 0.125', SameBits(R, E));

  TSqrt;  E.D := Exp2;
  WriteLn('  sqrt(4.0)        : ', HexD64(R), '  want ', HexD64(E));
  Check('sqrt(4.0) = 2.0', SameBits(R, E));

  TFdiv;  E.D := FdivA;
  WriteLn('  4195835/3145727',
          #13#10'    *3145727       : ', HexD64(R), '  want ', HexD64(E));
  Check('FDIV round trip within 2 ULP (the Pentium test)',
        CloseBits(R, E, 2));

  TInf;
  WriteLn('  1.0 / 0.0        : ', HexD64(R), '  status ', Hex4(Sw));
  { +infinity is sign 0, exponent all ones, mantissa zero: 7FF0 0000 0000 0000 }
  Check('1.0 / 0.0 = +infinity',
        (R.W[3] = $7FF0) and (R.W[2] = 0) and (R.W[1] = 0) and (R.W[0] = 0));
  Check('zero-divide flag raised', (Sw and $0004) <> 0);

  WriteLn;
  if Failures = 0 then
  begin
    WriteLn('--- ', Passed, ' passed, 0 failed ---');
    Halt(0);
  end;
  WriteLn('--- ', Passed, ' passed, ', Failures, ' FAILED ---');
  Halt(2);
end.
