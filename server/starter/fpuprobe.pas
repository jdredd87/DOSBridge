program FpuProbe;
{ DOS Bridge  --  StevenC }
{ A diagnostic for one question: is a coprocessor answering, and how long does
  it take to answer?

  The shared probe in cpu.pas reported "none" on a machine that has an 8087
  fitted, and the raw words it left behind were odd -- FNSTSW had written a
  value while FNSTCW had not written at all. That is not what either a present
  or an absent coprocessor should look like, so this walks the delay length
  instead of guessing at one.

  Every store here is a NO-WAIT form and there is no FWAIT anywhere, so this is
  safe to run whether or not a coprocessor is fitted. That property is the
  whole reason this is a separate program: the moment a WAIT appears, a machine
  with no coprocessor stops dead and needs someone at the keyboard.

  Usage:  FPUPROBE            walk the delays and report
  Exit code: 0 always -- this measures, it does not judge. }

{$MODE OBJFPC}{$H-}
{$ASMMODE INTEL}

uses About;

var
  Sw, Cw : Word;
  Spin   : Word;

const
  HexD: array[0..15] of Char = '0123456789ABCDEF';

function Hex4(W: Word): ShortString;
begin
  Hex4 := HexD[(W shr 12) and 15] + HexD[(W shr 8) and 15] +
          HexD[(W shr 4) and 15] + HexD[W and 15];
end;

function Num(L: LongInt): ShortString;
var S: ShortString;
begin
  Str(L, S); Num := S;
end;

{ FNINIT, wait `Spin` loops, store both words, wait `Spin` loops again.
  Seeded with 5A5A so an untouched word is obvious. }
procedure Attempt;
begin
  Sw := $5A5A;
  Cw := $5A5A;
  asm
    fninit
    mov  cx, Spin
    or   cx, cx
    jz   @@s1
  @@d1:
    dec  cx
    jnz  @@d1
  @@s1:
    fnstsw Sw
    fnstcw Cw
    mov  cx, Spin
    or   cx, cx
    jz   @@s2
  @@d2:
    dec  cx
    jnz  @@d2
  @@s2:
  end;
end;

{ The control word on its own, with FNINIT well out of the way. If FNSTCW only
  fails when it follows FNSTSW closely, that points at the coprocessor still
  being busy with the first store rather than at it being absent. }
procedure CwOnly;
begin
  Cw := $5A5A;
  asm
    fninit
    mov  cx, 4000
  @@d:
    dec  cx
    jnz  @@d
    fnstcw Cw
    mov  cx, 4000
  @@e:
    dec  cx
    jnz  @@e
  end;
end;

var
  Trials : array[1..7] of Word;
  I      : Integer;

begin
  Trials[1] := 0;
  Trials[2] := 20;
  Trials[3] := 60;
  Trials[4] := 200;
  Trials[5] := 1000;
  Trials[6] := 5000;
  Trials[7] := 20000;

  WriteLn('=== fpuprobe: how long does the coprocessor take to answer? ===');
  WriteLn('  No FWAIT anywhere -- safe with or without a coprocessor fitted.');
  WriteLn('  Both words are seeded 5A5A; 5A5A means nothing wrote to them.');
  WriteLn;
  WriteLn('    spin   status   control');
  WriteLn('    ----   ------   -------');

  for I := 1 to 7 do
  begin
    Spin := Trials[I];
    Attempt;
    WriteLn('   ', Num(Spin):6, '     ', Hex4(Sw), '     ', Hex4(Cw));
  end;

  WriteLn;
  CwOnly;
  WriteLn('  FNSTCW alone, long delay either side : ', Hex4(Cw));

  WriteLn;
  WriteLn('  What the numbers mean:');
  WriteLn('    both 5A5A          nothing answered -- no coprocessor');
  WriteLn('    status 0000        FNINIT completed and the store landed');
  WriteLn('    control 03FF       an 8087 (bit 7 is its interrupt enable mask)');
  WriteLn('    control 037F       an 80287 or later');
  WriteLn('    anything else      something is answering but not as expected');
  Halt(0);
end.
