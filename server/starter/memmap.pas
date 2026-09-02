program MemMap;
{ DOS Bridge  --  StevenC }
{ Walk the DOS memory control block chain and show every allocation.

  Usage:  MEMMAP            list every MCB
          MEMMAP /F         only free blocks
          MEMMAP /S         summary only

  Why this exists: MEM /C summarises, and it only lists blocks it can attribute
  to a named program. This shows the raw chain DOS actually maintains -- every
  block, its owner PSP, its size, and whether it is free -- which is what you
  need to see a TSR that did not release its environment, a driver that grabbed
  more than it should, or why the largest free block is smaller than the free
  total suggests.

  The chain head lives one word before the DOS "list of lists" returned by the
  undocumented INT 21h AH=52h. Each MCB is a 16-byte header immediately below
  the memory it owns:

    +0  'M' if another block follows, 'Z' if this is the last
    +1  owner PSP segment; 0 means free, 8 means DOS itself
    +3  size of the owned block, in 16-byte paragraphs
    +8  program name, DOS 4 and later }

{$MODE OBJFPC}{$H-}
{$ASMMODE INTEL}


uses About;

const
  MAXMCB = 200;            { guard against a corrupt chain looping forever }

var
  LolSeg, LolOfs : Word;
  McbSeg         : Word;
  Sig            : Byte;
  Owner          : Word;
  Paras          : Word;
  Name           : ShortString;
  Count          : Integer;
  TotUsed        : LongInt;
  TotFree        : LongInt;
  Largest        : LongInt;
  BlkBytes       : LongInt;
  OnlyFree       : Boolean;
  SummaryOnly    : Boolean;
  Kind           : ShortString;
  I, K           : Integer;
  A              : ShortString;
  Ch             : Char;
  ConvKB         : Word;

const
  HexD: array[0..15] of Char = '0123456789ABCDEF';

procedure GetListOfLists;
begin
  asm
    push es
    push bx
    mov  ah, 52h
    int  21h
    mov  LolSeg, es
    mov  LolOfs, bx
    pop  bx
    pop  es
  end;
end;

function Hex4(W: Word): ShortString;
begin
  Hex4 := HexD[(W shr 12) and 15] + HexD[(W shr 8) and 15] +
          HexD[(W shr 4) and 15] + HexD[W and 15];
end;

begin
  OnlyFree    := False;
  SummaryOnly := False;
  for K := 1 to ParamCount do
  begin
    A := ParamStr(K);
    if (A = '/F') or (A = '/f') then OnlyFree := True;
    if (A = '/S') or (A = '/s') then SummaryOnly := True;
  end;

  GetListOfLists;

  { The first MCB segment is stored in the word immediately before the list of
    lists. }
  McbSeg := MemW[LolSeg : LolOfs - 2];
  ConvKB := MemW[$0040:$0013];

  WriteLn('=== memmap: DOS memory control blocks ===');
  WriteLn('  list of lists    : ', Hex4(LolSeg), ':', Hex4(LolOfs));
  WriteLn('  first MCB at     : ', Hex4(McbSeg));
  WriteLn('  conventional RAM : ', ConvKB, ' KB');
  WriteLn;
  if not SummaryOnly then
    WriteLn('  seg   owner  paras      bytes  name      kind');

  Count   := 0;
  TotUsed := 0;
  TotFree := 0;
  Largest := 0;

  while Count < MAXMCB do
  begin
    Inc(Count);

    Sig   := Mem[McbSeg : 0];
    Owner := MemW[McbSeg : 1];
    Paras := MemW[McbSeg : 3];
    BlkBytes := LongInt(Paras) * 16;

    if (Sig <> Ord('M')) and (Sig <> Ord('Z')) then
    begin
      WriteLn('  CHAIN BROKEN at ', Hex4(McbSeg),
              ': signature is ', Sig, ', expected M or Z');
      Break;
    end;

    Name := '';
    for I := 0 to 7 do
    begin
      Ch := Chr(Mem[McbSeg : 8 + Word(I)]);
      if (Ch < ' ') or (Ch > '~') then Ch := ' ';
      Name := Name + Ch;
    end;
    while (Length(Name) > 0) and (Name[Length(Name)] = ' ') do
      Name := Copy(Name, 1, Length(Name) - 1);

    if Owner = 0 then
    begin
      Kind := 'FREE';
      Inc(TotFree, BlkBytes);
      if BlkBytes > Largest then Largest := BlkBytes;
      Name := '';
    end
    else if Owner = 8 then
    begin
      Kind := 'DOS';
      Inc(TotUsed, BlkBytes);
    end
    else if Owner = McbSeg + 1 then
    begin
      Kind := 'program';
      Inc(TotUsed, BlkBytes);
    end
    else
    begin
      Kind := 'data/env';
      Inc(TotUsed, BlkBytes);
    end;

    if (not SummaryOnly) and ((not OnlyFree) or (Owner = 0)) then
      WriteLn('  ', Hex4(McbSeg), '  ', Hex4(Owner), '  ', Paras:5, ' ',
              BlkBytes:10, '  ', Name, '':(10 - Length(Name)), Kind);

    if Sig = Ord('Z') then Break;
    McbSeg := McbSeg + Paras + 1;
  end;

  WriteLn;
  WriteLn('  blocks           : ', Count);
  WriteLn('  allocated        : ', TotUsed, ' bytes');
  WriteLn('  free             : ', TotFree, ' bytes');
  WriteLn('  largest free blk : ', Largest, ' bytes');
  if TotFree > Largest then
    WriteLn('  NOTE             : free memory is fragmented; no single block',
            ' is bigger than ', Largest, ' bytes');
  WriteLn('  NOTE             : the last "program" block is MEMMAP itself.');
  WriteLn('                     DOS gives a running program every free',
          ' paragraph, so');
  WriteLn('                     "free" here means what was left over',
          ' around it.');
  if Count >= MAXMCB then
    WriteLn('  WARNING          : hit the ', MAXMCB, ' block guard');
end.
