program HexDump;
{ DOS Bridge  --  StevenC }
{ Hex dump a file, on the DOS side.

  Usage:  HD file [offset] [count]      default: first 256 bytes

  Why this exists: TYPE stops dead at the first 0x1A, so there is no stock way
  to look at a binary on this machine. The alternative was pulling the whole
  file over the bridge just to read a header. This shows any window of any file
  in about as many lines as you ask for.

  Also prints the file size and a CRC-32, so a deployed file can be checked
  against the Windows-side copy without transferring it at all. }

{$MODE OBJFPC}{$H-}


uses About;

const
  PERLINE  = 16;
  DEFCOUNT = 256;
  BUFSZ    = 512;

var
  F        : file;
  Buf      : array[0..BUFSZ - 1] of Byte;
  Name     : ShortString;
  Ofs      : LongInt;
  Count    : LongInt;
  FSize    : LongInt;
  Got      : Word;
  Code     : Integer;
  CrcTab   : array[0..255] of LongInt;
  Crc      : LongInt;
  Shown    : LongInt;
  LineBuf  : array[0..PERLINE - 1] of Byte;
  NLine    : Integer;
  LineAt   : LongInt;
  I        : Integer;

const
  HexD: array[0..15] of Char = '0123456789ABCDEF';

function Hex2(B: Byte): ShortString;
begin
  Hex2 := HexD[(B shr 4) and 15] + HexD[B and 15];
end;

function Hex8(L: LongInt): ShortString;
var
  R: ShortString;
  K: Integer;
begin
  R := '';
  for K := 7 downto 0 do
    R := R + HexD[(L shr (K * 4)) and 15];
  Hex8 := R;
end;

procedure BuildCrcTable;
var
  N, K: Integer;
  C   : LongInt;
begin
  for N := 0 to 255 do
  begin
    C := N;
    for K := 0 to 7 do
      if (C and 1) <> 0 then
        C := LongInt($EDB88320) xor ((C shr 1) and $7FFFFFFF)
      else
        C := (C shr 1) and $7FFFFFFF;
    CrcTab[N] := C;
  end;
end;

procedure CrcUpdate(const B: array of Byte; N: Integer);
var
  K: Integer;
begin
  for K := 0 to N - 1 do
    Crc := CrcTab[(Crc xor LongInt(B[K])) and $FF] xor
           ((Crc shr 8) and $00FFFFFF);
end;

procedure FlushLine;
var
  K: Integer;
  S: ShortString;
begin
  if NLine = 0 then Exit;
  S := Hex8(LineAt) + '  ';
  for K := 0 to PERLINE - 1 do
    if K < NLine then S := S + Hex2(LineBuf[K]) + ' '
                 else S := S + '   ';
  S := S + ' ';
  for K := 0 to NLine - 1 do
    if (LineBuf[K] >= 32) and (LineBuf[K] < 127) then
      S := S + Chr(LineBuf[K])
    else
      S := S + '.';
  WriteLn(S);
  NLine := 0;
end;

begin
  if ParamCount < 1 then
  begin
    WriteLn('usage: HD file [offset] [count]');
    Halt(2);
  end;

  Name := ParamStr(1);
  Ofs := 0;
  Count := DEFCOUNT;
  if ParamCount >= 2 then
  begin
    Val(ParamStr(2), Ofs, Code);
    if Code <> 0 then Ofs := 0;
  end;
  if ParamCount >= 3 then
  begin
    Val(ParamStr(3), Count, Code);
    if Code <> 0 then Count := DEFCOUNT;
  end;

  Assign(F, Name);
  {$I-} Reset(F, 1); {$I+}
  if IOResult <> 0 then
  begin
    WriteLn('HD: cannot open ', Name);
    Halt(1);
  end;

  FSize := FileSize(F);
  WriteLn('=== hd: ', Name, ' ===');
  WriteLn('  size  : ', FSize, ' bytes');

  { CRC the whole file first, then rewind for the dump. Two passes keeps the
    checksum honest regardless of which window was asked for. }
  BuildCrcTable;
  Crc := -1;
  Seek(F, 0);
  while not Eof(F) do
  begin
    BlockRead(F, Buf, BUFSZ, Got);
    if Got = 0 then Break;
    CrcUpdate(Buf, Got);
  end;
  Crc := Crc xor -1;
  WriteLn('  crc32 : ', Hex8(Crc));

  if Ofs >= FSize then
  begin
    WriteLn('  (offset ', Ofs, ' is past end of file)');
    Close(F);
    Halt(0);
  end;
  if (Ofs + Count) > FSize then Count := FSize - Ofs;

  WriteLn('  dump  : ', Count, ' bytes from ', Ofs);
  WriteLn;

  Seek(F, Ofs);
  Shown  := 0;
  NLine  := 0;
  LineAt := Ofs;

  while Shown < Count do
  begin
    BlockRead(F, Buf, BUFSZ, Got);
    if Got = 0 then Break;
    for I := 0 to Got - 1 do
    begin
      if Shown >= Count then Break;
      if NLine = 0 then LineAt := Ofs + Shown;
      LineBuf[NLine] := Buf[I];
      Inc(NLine);
      Inc(Shown);
      if NLine = PERLINE then FlushLine;
    end;
  end;
  FlushLine;

  Close(F);
end.
