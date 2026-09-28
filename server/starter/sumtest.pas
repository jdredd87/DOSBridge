program SumTest;
{ DOS Bridge  --  StevenC & Claude }
{ sumtest.pas -- the assembly checksum (sumbuf.inc, what net.pas sends with)
  against the Pascal it replaced, on random data: every length from 0 to
  1514, at even and odd offsets, starting from random running sums.  Then
  the time each takes over a 1400-byte datagram.

    SUMTEST            exit 0 if every case agrees, 1 if any differs }

{$MODE OBJFPC}{$H-}
{$ASMMODE INTEL}

uses About;

const
  NET_MAXPKT = 1536;

type
  TPkt = array[0 .. NET_MAXPKT - 1] of Byte;

var
  P: TPkt;
  Bad, Cases: LongInt;
  L, O, K: Word;
  A, B: Word;
  T0, N: LongInt;

{$I sumbuf.inc}

{ the Pascal it replaced, verbatim }
procedure AddW(var S: Word; W: Word);
begin
  S := S + W;
  if S < W then Inc(S);
end;

procedure SumOld(var S: Word; var P: TPkt; Ofs, Len: Word);
var I: Word;
begin
  I := 0;
  while (I + 1) < Len do
  begin
    AddW(S, (Word(P[Ofs + I]) shl 8) or P[Ofs + I + 1]);
    Inc(I, 2);
  end;
  if I < Len then AddW(S, Word(P[Ofs + I]) shl 8);
end;

function Ticks: LongInt;
begin
  Ticks := MemL[$40:$6C];
end;

begin
  RandSeed := 1234;
  Bad := 0; Cases := 0;
  for K := 1 to 3 do
  begin
    for L := 0 to NET_MAXPKT - 1 do
      case K of
        1: P[L] := Random(256);
        2: P[L] := $FF;                 { all carries }
        3: P[L] := 0;
      end;
    for L := 0 to 1514 do
      for O := 0 to 3 do
      begin
        if O + L > NET_MAXPKT then Continue;
        A := Random(65535); B := A;
        SumOld(A, P, O, L);
        SumBuf(B, P, O, L);
        Inc(Cases);
        if A <> B then
        begin
          Inc(Bad);
          if Bad <= 5 then
            WriteLn('DIFFERS: fill ', K, ' length ', L, ' offset ', O, ': old ', A, ' new ', B);
        end;
      end;
    Write(StdErr, '.');
  end;
  WriteLn(Cases, ' cases, ', Bad, ' differ');
  N := 0; T0 := Ticks;
  repeat A := 0; SumOld(A, P, 34, 1408); Inc(N); until Ticks - T0 >= 36;
  WriteLn('Pascal sum of 1408 bytes: ', (Ticks - T0) * 55000 div N, ' us');
  N := 0; T0 := Ticks;
  repeat A := 0; SumBuf(A, P, 34, 1408); Inc(N); until Ticks - T0 >= 36;
  WriteLn('asm sum of 1408 bytes:    ', (Ticks - T0) * 55000 div N, ' us');
  if Bad > 0 then Halt(1);
end.
