program CrcTest;
{ DOS Bridge  --  StevenC & Claude }
{ crctest.pas -- the assembly CRC-32 (crc32.inc, what UGET checks downloads
  with) against a bit-by-bit reference: the standard check value, then
  random data of every length 0..300 in every split into two calls, and a
  16 KB block.  Then its speed.

    CRCTEST            exit 0 if every case agrees, 1 if any differs }

{$MODE OBJFPC}{$H-}
{$ASMMODE INTEL}

uses About;

{$I crc32.inc}

type
  TBuf = array[0 .. 16383] of Byte;

var
  B: ^TBuf;
  Bad, Cases, N: LongInt;
  L, K, I: Word;
  A, R: LongInt;
  T0: LongInt;

function Ref(var P: TBuf; Len: Word): LongInt;
var
  C: LongInt;
  I, J: Word;
begin
  C := LongInt($FFFFFFFF);
  for I := 0 to Len - 1 do
  begin
    C := C xor P[I];
    for J := 1 to 8 do
      if (C and 1) <> 0 then C := (C shr 1) xor LongInt($EDB88320)
      else C := C shr 1;
  end;
  Ref := C xor LongInt($FFFFFFFF);
end;

function Fast(var P: TBuf; Len, Split: Word): LongInt;
var
  C: LongInt;
begin
  C := LongInt($FFFFFFFF);
  Crc32Upd(C, P[0], Split);
  Crc32Upd(C, P[Split], Len - Split);
  Fast := C xor LongInt($FFFFFFFF);
end;

function Ticks: LongInt;
begin
  Ticks := MemL[$40:$6C];
end;

begin
  Crc32Init;
  New(B);
  Bad := 0; Cases := 0;
  { the check value: CRC-32 of "123456789" is CBF43926 }
  for I := 0 to 8 do B^[I] := Ord('1') + I;
  A := Fast(B^, 9, 4);
  Inc(Cases);
  if A <> LongInt($CBF43926) then
  begin
    Inc(Bad);
    WriteLn('check value wrong: ', A);
  end;
  RandSeed := 42;
  for I := 0 to 16383 do B^[I] := Random(256);
  for L := 1 to 300 do
  begin
    R := Ref(B^, L);
    for K := 0 to L do
    begin
      A := Fast(B^, L, K);
      Inc(Cases);
      if A <> R then
      begin
        Inc(Bad);
        if Bad <= 5 then WriteLn('DIFFERS length ', L, ' split ', K);
      end;
    end;
  end;
  Write(StdErr, '.');
  A := Fast(B^, 16384, 5000); R := Ref(B^, 16384);
  Inc(Cases);
  if A <> R then begin Inc(Bad); WriteLn('DIFFERS on 16 KB'); end;
  WriteLn(Cases, ' cases, ', Bad, ' differ');
  N := 0; T0 := Ticks;
  repeat
    A := -1; Crc32Upd(A, B^[0], 16384); Inc(N);
  until Ticks - T0 >= 36;
  WriteLn('CRC-32 speed: ', N * 16 * 182 div ((Ticks - T0) * 10), ' KB/s');
  if Bad > 0 then Halt(1);
end.
