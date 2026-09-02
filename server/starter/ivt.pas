program Ivt;
{ DOS Bridge  --  StevenC }
{ Interrupt vector table dump, with each hooked vector attributed to its owner.

  Usage:  IVT              well-known vectors plus everything hooked in RAM
          IVT /A           all 256 vectors
          IVT nn           one vector, in hex (e.g. IVT 33)

  Why this exists: DEVS shows which drivers registered as devices and MEMMAP
  shows who owns which memory, but neither answers "what grabbed INT 9?". A TSR
  that hooks an interrupt without registering a device is invisible to both.
  This reads the table at 0000:0000 and, for every vector that points into
  ordinary RAM, walks the MCB chain to find which allocation contains the
  target -- which is usually enough to name the culprit.

  A vector pointing into F000 is the ROM BIOS and normal. One pointing into
  conventional memory means something resident is in the path. }

{$MODE OBJFPC}{$H-}
{$ASMMODE INTEL}


uses About;

const
  MAXMCB = 200;

type
  TKnown = record
    N: Byte;
    S: String[26];
  end;

const
  { The vectors worth naming. Anything else interesting will show up anyway
    because it points into RAM. }
  NKNOWN = 24;
  Known: array[1..NKNOWN] of TKnown = (
    (N: $00; S: 'divide by zero'),
    (N: $02; S: 'NMI'),
    (N: $08; S: 'timer IRQ0'),
    (N: $09; S: 'keyboard IRQ1'),
    (N: $0B; S: 'COM2 IRQ3'),
    (N: $0C; S: 'COM1 IRQ4'),
    (N: $0D; S: 'LPT2 IRQ5'),
    (N: $0E; S: 'floppy IRQ6'),
    (N: $0F; S: 'LPT1 IRQ7'),
    (N: $10; S: 'video BIOS'),
    (N: $11; S: 'equipment list'),
    (N: $12; S: 'memory size'),
    (N: $13; S: 'disk BIOS'),
    (N: $14; S: 'serial BIOS'),
    (N: $15; S: 'system services'),
    (N: $16; S: 'keyboard BIOS'),
    (N: $17; S: 'printer BIOS'),
    (N: $1A; S: 'clock BIOS'),
    (N: $1C; S: 'user timer tick'),
    (N: $21; S: 'DOS services'),
    (N: $24; S: 'critical error'),
    (N: $28; S: 'DOS idle'),
    (N: $2F; S: 'multiplex'),
    (N: $33; S: 'mouse'));

var
  LolSeg, LolOfs : Word;
  VSeg, VOfs     : Word;
  I, K           : Integer;
  ShowAll        : Boolean;
  OneVec         : Integer;
  Code           : Integer;
  A              : ShortString;
  Nm             : ShortString;
  Owner          : ShortString;
  HookedRam      : Integer;
  InRom          : Integer;
  Null           : Integer;

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

function Hex2(B: Byte): ShortString;
begin
  Hex2 := HexD[(B shr 4) and 15] + HexD[B and 15];
end;

function Hex4(W: Word): ShortString;
begin
  Hex4 := Hex2((W shr 8) and $FF) + Hex2(W and $FF);
end;

function KnownName(V: Byte): ShortString;
var
  J: Integer;
begin
  KnownName := '';
  for J := 1 to NKNOWN do
    if Known[J].N = V then
    begin
      KnownName := Known[J].S;
      Exit;
    end;
end;

{ Find which memory block contains this segment, and name its owner. Walking
  the chain per vector is wasteful but there are only 256 of them and the chain
  is a dozen entries; clarity wins over speed here. }
function OwnerOf(Sg: Word): ShortString;
var
  McbSeg, Own, Paras, Lo, Hi: Word;
  Sig  : Byte;
  Cnt  : Integer;
  Name : ShortString;
  J    : Integer;
  Ch   : Char;
begin
  OwnerOf := '';
  if Sg >= $A000 then
  begin
    if Sg >= $F000 then OwnerOf := '(ROM BIOS)'
    else OwnerOf := '(adapter ROM/video)';
    Exit;
  end;

  McbSeg := MemW[LolSeg : LolOfs - 2];
  Cnt := 0;
  while Cnt < MAXMCB do
  begin
    Inc(Cnt);
    Sig   := Mem[McbSeg : 0];
    Own   := MemW[McbSeg : 1];
    Paras := MemW[McbSeg : 3];
    if (Sig <> Ord('M')) and (Sig <> Ord('Z')) then Exit;

    Lo := McbSeg + 1;
    Hi := McbSeg + Paras;
    if (Sg >= Lo) and (Sg <= Hi) then
    begin
      if Own = 0 then
      begin
        OwnerOf := '(in FREE memory!)';
        Exit;
      end;
      if Own = 8 then
      begin
        OwnerOf := 'DOS';
        Exit;
      end;
      Name := '';
      for J := 0 to 7 do
      begin
        Ch := Chr(Mem[McbSeg : 8 + Word(J)]);
        if (Ch < ' ') or (Ch > '~') then Ch := ' ';
        Name := Name + Ch;
      end;
      while (Length(Name) > 0) and (Name[Length(Name)] = ' ') do
        Name := Copy(Name, 1, Length(Name) - 1);
      if Name = '' then Name := 'PSP ' + Hex4(Own);
      OwnerOf := Name;
      Exit;
    end;

    if Sig = Ord('Z') then Exit;
    McbSeg := McbSeg + Paras + 1;
  end;
end;

procedure ShowVec(V: Integer);
begin
  VOfs := MemW[$0000 : Word(V * 4)];
  VSeg := MemW[$0000 : Word(V * 4 + 2)];
  Nm    := KnownName(Byte(V));
  Owner := OwnerOf(VSeg);
  WriteLn('  ', Hex2(Byte(V)), '  ', Hex4(VSeg), ':', Hex4(VOfs), '  ',
          Nm, '':(20 - Length(Nm)), Owner);
end;

begin
  ShowAll := False;
  OneVec  := -1;
  for K := 1 to ParamCount do
  begin
    A := ParamStr(K);
    if (A = '/A') or (A = '/a') then ShowAll := True
    else
    begin
      { accept a hex vector number }
      OneVec := 0;
      Code := 0;
      for I := 1 to Length(A) do
      begin
        case A[I] of
          '0'..'9': OneVec := OneVec * 16 + (Ord(A[I]) - Ord('0'));
          'a'..'f': OneVec := OneVec * 16 + (Ord(A[I]) - Ord('a') + 10);
          'A'..'F': OneVec := OneVec * 16 + (Ord(A[I]) - Ord('A') + 10);
        else
          Code := 1;
        end;
      end;
      if (Code <> 0) or (OneVec < 0) or (OneVec > 255) then OneVec := -1;
    end;
  end;

  GetListOfLists;

  WriteLn('=== ivt: interrupt vector table ===');
  WriteLn('  vec  address     purpose             owner');

  if OneVec >= 0 then
  begin
    ShowVec(OneVec);
    Halt(0);
  end;

  HookedRam := 0;
  InRom     := 0;
  Null      := 0;

  for I := 0 to 255 do
  begin
    VOfs := MemW[$0000 : Word(I * 4)];
    VSeg := MemW[$0000 : Word(I * 4 + 2)];

    if (VSeg = 0) and (VOfs = 0) then Inc(Null)
    else if VSeg >= $A000 then Inc(InRom)
    else Inc(HookedRam);

    if ShowAll then
      ShowVec(I)
    else if (KnownName(Byte(I)) <> '') or
            ((VSeg < $A000) and not ((VSeg = 0) and (VOfs = 0))) then
      ShowVec(I);
  end;

  WriteLn;
  WriteLn('  pointing into RAM: ', HookedRam,
          '   (something resident is in the path)');
  WriteLn('  pointing into ROM: ', InRom);
  WriteLn('  null vectors     : ', Null);
end.
