program Devs;
{ DOS Bridge  --  StevenC }
{ List the installed DOS device drivers by walking the device chain.

  Usage:  DEVS                list every device in the chain
          DEVS NAME           exit 0 if character device NAME is present,
                              1 if it is not -- scriptable driver check

  Why this exists: when TESTDEV.SYS was loaded through dosdrv, the crash guard
  reported ##BOOTOK and the machine came back, but the driver had silently
  failed to install. Proving that took MEM /C plus an IF EXIST guess. MEM /C
  only shows drivers that own a memory block, and IF EXIST on a device name is
  a folk trick rather than a real query. This walks the actual chain DOS keeps,
  which is the authoritative answer.

  The chain starts at the NUL device, which lives inside the DOS "list of
  lists" returned by the undocumented INT 21h AH=52h. Each header points at the
  next; an offset of FFFF ends it. }

{$MODE OBJFPC}{$H-}
{$ASMMODE INTEL}


uses About;

const
  MAXDEV  = 120;           { guard against a corrupt, looping chain }
  NUL_OFS = $22;           { NUL device header inside the list of lists }

var
  LolSeg, LolOfs : Word;
  DSeg, DOfs     : Word;
  NSeg, NOfs     : Word;
  Attr           : Word;
  Count          : Integer;
  Name           : ShortString;
  Want           : ShortString;
  Found          : Boolean;
  I              : Integer;
  Ch             : Char;
  IsChar         : Boolean;

{ Writes straight into the globals. A `var` parameter cannot be used here: in
  inline asm the parameter name refers to the pointer itself, not the variable
  it points at, so `mov S, es` overwrites the pointer and the caller gets
  nothing. That is what made the first version report 0000:0000 and then walk
  garbage. }
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

function UpStr(const X: ShortString): ShortString;
var
  R: ShortString;
  K: Integer;
begin
  R := X;
  for K := 1 to Length(R) do
    if (R[K] >= 'a') and (R[K] <= 'z') then
      R[K] := Chr(Ord(R[K]) - 32);
  UpStr := R;
end;

{ Decode the attribute word into something readable. Bit 15 is the one that
  matters most: set means character device, clear means block device. }
function AttrText(A: Word): ShortString;
var
  R: ShortString;
begin
  R := '';
  if (A and $8000) <> 0 then R := R + 'char ' else R := R + 'block ';
  if (A and $4000) <> 0 then R := R + 'ioctl ';
  if (A and $2000) <> 0 then R := R + 'busy ';
  if (A and $0800) <> 0 then R := R + 'removable ';
  if (A and $0040) <> 0 then R := R + 'genioctl ';
  if (A and $0008) <> 0 then R := R + 'CLOCK ';
  if (A and $0004) <> 0 then R := R + 'NUL ';
  if (A and $0002) <> 0 then R := R + 'stdout ';
  if (A and $0001) <> 0 then R := R + 'stdin ';
  AttrText := R;
end;

function Hex4(W: Word): ShortString;
const
  D: array[0..15] of Char = '0123456789ABCDEF';
begin
  Hex4 := D[(W shr 12) and 15] + D[(W shr 8) and 15] +
          D[(W shr 4) and 15] + D[W and 15];
end;

begin
  Want := '';
  if ParamCount >= 1 then Want := UpStr(ParamStr(1));

  GetListOfLists;

  if Want = '' then
  begin
    WriteLn('=== devs: DOS device chain ===');
    WriteLn('  list of lists at : ', Hex4(LolSeg), ':', Hex4(LolOfs));
    WriteLn;
    WriteLn('  #  header      name      attr  flags');
  end;

  DSeg  := LolSeg;
  DOfs  := LolOfs + NUL_OFS;
  Count := 0;
  Found := False;

  while Count < MAXDEV do
  begin
    Inc(Count);

    NOfs := MemW[DSeg : DOfs];
    NSeg := MemW[DSeg : DOfs + 2];
    Attr := MemW[DSeg : DOfs + 4];
    IsChar := (Attr and $8000) <> 0;

    { Character devices carry an 8-byte name here. Block devices put a unit
      count in the first byte instead, so the bytes are not a name at all. }
    Name := '';
    if IsChar then
    begin
      for I := 0 to 7 do
      begin
        Ch := Chr(Mem[DSeg : DOfs + 10 + Word(I)]);
        if Ch = ' ' then Ch := ' ';
        Name := Name + Ch;
      end;
      while (Length(Name) > 0) and (Name[Length(Name)] = ' ') do
        Name := Copy(Name, 1, Length(Name) - 1);
    end
    else
      Name := '<' + Chr(Ord('0') + (Mem[DSeg : DOfs + 10] mod 10)) + ' units>';

    if Want = '' then
      WriteLn('  ', Count:2, '  ', Hex4(DSeg), ':', Hex4(DOfs), '  ',
              Name, '':(10 - Length(Name)), Hex4(Attr), '  ', AttrText(Attr))
    else
      if IsChar and (UpStr(Name) = Want) then Found := True;

    if NOfs = $FFFF then Break;
    DSeg := NSeg;
    DOfs := NOfs;
  end;

  if Want = '' then
  begin
    WriteLn;
    WriteLn('  devices in chain : ', Count);
    if Count >= MAXDEV then
      WriteLn('  WARNING          : hit the ', MAXDEV,
              ' device guard; chain may be corrupt');
  end
  else
  begin
    if Found then
    begin
      WriteLn('DEVICE PRESENT: ', Want);
      Halt(0);
    end
    else
    begin
      WriteLn('DEVICE ABSENT: ', Want, ' (walked ', Count, ' devices)');
      Halt(1);
    end;
  end;
end.
