program HwInfo;
{ DOS Bridge  --  StevenC }
{ Everything the machine will tell us about itself, in one call.

  Usage:  HWINFO

  sysinfo.pas answers three questions; this one sweeps the BIOS data area, the
  equipment word, the ROM signature, every drive, and the EMS/XMS/VESA probes,
  so a hardware question costs one round trip instead of five.

  Every probe here is read-only. Nothing changes a mode, allocates, or writes. }

{$MODE OBJFPC}{$H-}
{$ASMMODE INTEL}

uses Dos, Cpu, About;

type
  TVbe = packed record
    Sig    : array[0..3] of Char;
    Ver    : Word;
    Oem    : LongInt;
    Caps   : LongInt;
    Modes  : LongInt;
    Mem64K : Word;
    Pad    : array[0..491] of Byte;
  end;

var
  B       : TVbe;
  VesaOK  : Boolean;
  VesaMem : Word;

  { asm results land in globals: a var parameter in an inline asm block refers
    to the pointer, not the variable it points at. }
  RAX, RBX, RCX, RDX : Word;
  RES_               : Word;

  Equip     : Word;
  ConvKB    : Word;
  VMode     : Byte;
  Cols      : Word;
  DccOK     : Boolean;
  Dcc       : Byte;
  I         : Integer;
  S         : ShortString;
  BiosDate  : ShortString;
  ModelByte : Byte;
  Drv       : Char;
  SecPerClu : Word;
  FreeClu   : Word;
  BytPerSec : Word;
  TotClu    : Word;
  FreeBytes : LongInt;
  TotBytes  : LongInt;
  NDrives   : Integer;
  HasXMS    : Boolean;
  HasEMS    : Boolean;
  EmsSeg    : Word;
  Ch        : Char;

const
  HexD: array[0..15] of Char = '0123456789ABCDEF';

function Hex4(W: Word): ShortString;
begin
  Hex4 := HexD[(W shr 12) and 15] + HexD[(W shr 8) and 15] +
          HexD[(W shr 4) and 15] + HexD[W and 15];
end;

procedure GetVideoMode;
begin
  asm
    mov ah, 0Fh
    int 10h
    mov RAX, ax
  end;
end;

procedure GetDcc;
begin
  asm
    mov ax, 1A00h
    int 10h
    mov RAX, ax
    mov RBX, bx
  end;
end;

{ The 512-byte VBE buffer is a global on purpose. As a local it sits on the
  stack, and the BIOS writes 512 bytes into it through a pointer we hand over --
  a lot of trust to place in the stack having that much room to spare. }
procedure GetVesa;
var
  Sg, O: Word;
begin
  B.Sig[0] := 'V'; B.Sig[1] := 'B'; B.Sig[2] := 'E'; B.Sig[3] := '2';
  Sg := Seg(B); O := Ofs(B);
  asm
    push es
    mov  ax, Sg
    mov  es, ax
    mov  di, O
    mov  ax, 4F00h
    int  10h
    pop  es
    mov  RES_, ax
  end;
  VesaOK := (RES_ = $004F) and (B.Sig[0] = 'V') and (B.Sig[1] = 'E')
            and (B.Sig[2] = 'S') and (B.Sig[3] = 'A');
  if VesaOK then VesaMem := B.Mem64K else VesaMem := 0;
end;

procedure GetDiskSpace(D: Byte);
begin
  asm
    mov ah, 36h
    mov dl, D
    int 21h
    mov RAX, ax
    mov RBX, bx
    mov RCX, cx
    mov RDX, dx
  end;
end;

procedure CheckXms;
begin
  asm
    mov ax, 4300h
    int 2Fh
    mov RAX, ax
  end;
end;

begin
  WriteLn('=== hwinfo ===');

  { --- CPU and DOS --- }
  { cpu.pas probes at run time and covers 8086 through 386+, so this stays
    correct on whatever machine the bridge is pointed at. }
  WriteLn('  CPU              : ', CpuName);
  if Has186 then S := 'yes' else S := 'no (plain 8086)';
  WriteLn('  186 instructions : ', S);
  WriteLn('  coprocessor      : ', FpuName);
  WriteLn('  DOS version      : ', Lo(DosVersion), '.', Hi(DosVersion));

  { --- ROM BIOS signature --- }
  BiosDate := '';
  for I := 0 to 7 do
  begin
    Ch := Chr(Mem[$F000 : $FFF5 + Word(I)]);
    if (Ch < ' ') or (Ch > '~') then Ch := '?';
    BiosDate := BiosDate + Ch;
  end;
  ModelByte := Mem[$F000 : $FFFE];
  WriteLn('  BIOS date        : ', BiosDate);
  WriteLn('  BIOS model byte  : ', Hex4(ModelByte));

  { --- memory --- }
  ConvKB := MemW[$0040:$0013];
  WriteLn('  conventional RAM : ', ConvKB, ' KB');
  WriteLn('  free heap (this) : ', MemAvail, ' bytes');

  CheckXms;
  HasXMS := ((RAX shr 8) and $FF) = $80;
  WriteLn('  XMS driver       : ', HasXMS);

  { EMS announces itself as a character device called EMMXXXX0, so read the
    name out of the header the INT 67h vector points at. }
  EmsSeg := MemW[$0000 : $67 * 4 + 2];
  S := '';
  for I := 0 to 7 do
  begin
    Ch := Chr(Mem[EmsSeg : 10 + Word(I)]);
    if (Ch < ' ') or (Ch > '~') then Ch := ' ';
    S := S + Ch;
  end;
  HasEMS := S = 'EMMXXXX0';
  WriteLn('  EMS driver       : ', HasEMS, '  (INT 67h -> ', Hex4(EmsSeg),
          ', name "', S, '")');

  { --- equipment word --- }
  Equip := MemW[$0040:$0010];
  WriteLn('  equipment word   : ', Hex4(Equip));
  WriteLn('    floppy drives  : ', ((Equip shr 6) and 3) + 1);
  WriteLn('    serial ports   : ', (Equip shr 9) and 7);
  WriteLn('    parallel ports : ', (Equip shr 14) and 3);
  case (Equip shr 4) and 3 of
    0: S := 'EGA/VGA or better';
    1: S := '40x25 colour';
    2: S := '80x25 colour';
    3: S := '80x25 mono';
  end;
  WriteLn('    initial video  : ', S);
  { Bit 1 is the BIOS's coprocessor flag. It is set by POST from a jumper or a
    probe of its own and is not always right -- on some clones it is hardwired,
    and on PS/2/AT-class machines the bit was redefined. The FNINIT probe in
    cpu.pas asks the coprocessor directly, so where the two disagree, believe
    the probe. Printing both is the point: a mismatch is a real finding. }
  if (Equip and 2) <> 0 then S := 'yes' else S := 'no';
  WriteLn('    coproc bit     : ', S, '   (BIOS opinion; probe says ',
          FpuName, ')');
  if ((Equip and 2) <> 0) <> HasFpu then
    WriteLn('    ** MISMATCH    : equipment word and FNINIT probe disagree');

  { --- port base addresses --- }
  S := '';
  for I := 0 to 3 do
    if MemW[$0040 : Word(I * 2)] <> 0 then
      S := S + Hex4(MemW[$0040 : Word(I * 2)]) + ' ';
  if S = '' then S := '(none)';
  WriteLn('  COM base ports   : ', S);
  S := '';
  for I := 0 to 2 do
    if MemW[$0040 : Word(8 + I * 2)] <> 0 then
      S := S + Hex4(MemW[$0040 : Word(8 + I * 2)]) + ' ';
  if S = '' then S := '(none)';
  WriteLn('  LPT base ports   : ', S);

  { --- video --- }
  GetVideoMode;
  VMode := RAX and $FF;
  Cols  := (RAX shr 8) and $FF;
  WriteLn('  video mode       : ', VMode, ' (', Cols, ' columns)');

  GetDcc;
  DccOK := (RAX and $FF) = $1A;
  if DccOK then
  begin
    Dcc := RBX and $FF;
    case Dcc of
      1:    S := 'MDA mono';
      2:    S := 'CGA colour';
      4:    S := 'EGA colour';
      5:    S := 'EGA mono';
      7:    S := 'VGA mono';
      8:    S := 'VGA colour';
      $0A:  S := 'MCGA colour';
    else
      S := 'code ' + Chr(Ord('0') + (Dcc mod 10));
    end;
    WriteLn('  display combo    : ', Dcc, ' = ', S);
  end
  else
    WriteLn('  display combo    : not reported (pre-VGA BIOS)');

  GetVesa;
  if VesaOK then
    WriteLn('  VESA VBE         : yes, ', LongInt(VesaMem) * 64, ' KB video RAM')
  else
    WriteLn('  VESA VBE         : no');

  { --- drives --- }
  WriteLn;
  WriteLn('  drive  cluster    total KB     free KB');
  NDrives := 0;
  { Start at C:. INT 21h AH=36h against a floppy with no disk in it raises a
    critical error, and DOS then waits at an Abort/Retry/Fail prompt nobody is
    here to answer -- which over the bridge is indistinguishable from a hang. }
  for I := 3 to 26 do
  begin
    GetDiskSpace(Byte(I));
    SecPerClu := RAX;
    FreeClu   := RBX;
    BytPerSec := RCX;
    TotClu    := RDX;
    if SecPerClu <> $FFFF then
    begin
      Inc(NDrives);
      Drv := Chr(Ord('A') + I - 1);
      TotBytes  := (LongInt(TotClu)  * SecPerClu) * BytPerSec;
      FreeBytes := (LongInt(FreeClu) * SecPerClu) * BytPerSec;
      WriteLn('    ', Drv, ':    ', (LongInt(SecPerClu) * BytPerSec):6,
              '  ', (TotBytes div 1024):10, '  ', (FreeBytes div 1024):10);
    end;
  end;
  WriteLn('  drives found     : ', NDrives, '   (A: and B: skipped on purpose)');
end.
