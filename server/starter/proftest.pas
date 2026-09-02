program ProfTest;
{ DOS Bridge  --  StevenC }
{ Exercise the Prof unit on work whose relative cost is already known.

  BENCH measured 16-bit multiply at 58640/sec and 32-bit at 11484/sec on this
  machine. Running the same number of each here should therefore show the 32-bit
  section taking roughly five times as long. If it does, the profiler's clock is
  believable; if it does not, the clock is wrong and nothing it says can be
  trusted.

  The recursion section is there to give the stack watermark something real to
  measure. }

{$MODE OBJFPC}{$H-}

uses Prof, About;

const
  N = 4000;

var
  Sink16 : Word;
  Sink32 : LongInt;
  A16, B16 : Integer;
  A32, B32 : LongInt;
  I : Integer;
  Buf : array[0..999] of Word;

{ Deliberately fat frames, so the stack cost is visible rather than noise. }
function Deep(Level: Integer): LongInt;
var
  Pad: array[0..63] of Word;      { 128 bytes per level }
  K: Integer;
  S: LongInt;
begin
  for K := 0 to 63 do Pad[K] := Word(Level + K);
  S := Pad[Level and 63];
  if Level > 0 then S := S + Deep(Level - 1);
  Deep := S;
end;

{ Same 1000 writes, but with the loop counter as a procedure local instead of
  a global. In the large memory model a global is reached through a segment
  register; a local is a BP-relative access. This is here to find out whether
  that difference is what makes the global-loop version look twice as slow. }
procedure MemWLocal;
var
  J: Integer;
begin
  for J := 0 to 999 do
    MemW[$B800 : Word(J * 2)] := $0720;
end;

{ 10000 writes in one section. A single batch of 1000 is only about 36ms, and
  BENCH derives its figure from tens of batches, so this makes the two
  measurements comparable in size before concluding they disagree. }
procedure MemWBig;
var
  J, B: Integer;
begin
  for B := 1 to 10 do
    for J := 0 to 999 do
      MemW[$B800 : Word(J * 2)] := $0720;
end;

begin
  WriteLn('=== proftest ===');
  WriteLn('  ', N, ' iterations of each arithmetic section');

  ProfStart;

  A16 := 123; B16 := 45;
  for I := 1 to N do
    Sink16 := Word(A16 * B16);
  Mark('mul16');

  A32 := 123456; B32 := 45;
  for I := 1 to N do
    Sink32 := A32 * B32;
  Mark('mul32');

  A32 := 123456789; B32 := 37;
  for I := 1 to N do
    Sink32 := A32 div B32;
  Mark('div32');

  for I := 0 to 999 do
    Buf[I] := Word(I);
  Mark('array store');

  for I := 0 to 999 do
    MemW[$B800 : Word(I * 2)] := $0720;
  Mark('MemW B800');

  MemWLocal;
  Mark('MemW local I');

  MemWBig;
  Mark('MemW x10000');

  Sink32 := Deep(20);
  Mark('recurse x20');

  ProfReport;

  WriteLn;
  WriteLn('  (sinks ', Sink16, ' ', Sink32, ' ', Buf[999], ')');
  WriteLn('  expected: mul32 about 5x mul16, div32 about 8x, from BENCH');
end.
