{ PCILIST -- every PCI device, through the BIOS's PCI services (INT 1Ah,
  B101h then B109h), read-only: bus, device, function, vendor and device
  ID, class.  Written by StevenC and Claude (Anthropic), 2026-10-13, to
  find p3box's onboard sound.  Exit code: the number of devices (to 20). }

program PciList;

{$MODE OBJFPC}{$H-}

uses About, Dos;

function Hex(V: LongInt; N: Integer): ShortString;
begin
  Hex := HexStr(V, N);
end;

function CfgWord(Bus, DevFn: Byte; Reg: Word; var V: Word): Boolean;
var
  R: Registers;
begin
  R.AX := $B109;
  R.BX := (Bus shl 8) or DevFn;
  R.DI := Reg;
  Intr($1A, R);
  V := R.CX;
  CfgWord := (R.Flags and FCarry) = 0;
end;

function ClassName(C: Word): ShortString;
begin
  case C of
    $0100: ClassName := 'SCSI';
    $0101: ClassName := 'IDE';
    $0200: ClassName := 'Ethernet';
    $0300: ClassName := 'VGA';
    $0400: ClassName := 'video';
    $0401: ClassName := 'AUDIO';
    $0403: ClassName := 'AUDIO (HD)';
    $0480: ClassName := 'multimedia';
    $0600: ClassName := 'host bridge';
    $0601: ClassName := 'ISA bridge';
    $0604: ClassName := 'PCI bridge';
    $0680: ClassName := 'bridge (other)';
    $0C03: ClassName := 'USB';
    $0C05: ClassName := 'SMBus';
    $0703: ClassName := 'modem';
    $0780: ClassName := 'communications';
  else
    ClassName := '';
  end;
end;

var
  R: Registers;
  Bus, Dev, Fn, LastBus, Count: Integer;
  Vendor, Device, Cls, Hdr, Irq: Word;
begin
  R.AX := $B101;
  Intr($1A, R);
  if ((R.Flags and FCarry) <> 0) or (R.DX <> $4350) then   { 'PC' }
  begin
    WriteLn('no PCI BIOS');
    Halt(0);
  end;
  LastBus := R.CL;
  WriteLn('PCI BIOS ', Hex(R.BH, 1), '.', Hex(R.BL, 2), ', last bus ', LastBus);
  Count := 0;
  for Bus := 0 to LastBus do
    for Dev := 0 to 31 do
    begin
      Fn := 0;
      while Fn < 8 do
      begin
        if CfgWord(Bus, (Dev shl 3) or Fn, 0, Vendor) and (Vendor <> $FFFF) and (Vendor <> 0) then
        begin
          CfgWord(Bus, (Dev shl 3) or Fn, 2, Device);
          CfgWord(Bus, (Dev shl 3) or Fn, $0A, Cls);
          CfgWord(Bus, (Dev shl 3) or Fn, $3C, Irq);
          Write('  ', Bus, ':', Dev, '.', Fn, '  ', Hex(Vendor, 4), ':', Hex(Device, 4),
                '  class ', Hex(Cls, 4), '  ', ClassName(Cls));
          if Hi(Irq) <> 0 then                    { it has an interrupt pin: INTA#..INTD# }
            if (Lo(Irq) > 0) and (Lo(Irq) < 16) then
              Write('  INT', Chr(64 + Hi(Irq)), '# -> IRQ ', Lo(Irq))
            else
              Write('  INT', Chr(64 + Hi(Irq)), '# -> no IRQ');
          WriteLn;
          Inc(Count);
          if Fn = 0 then
          begin
            CfgWord(Bus, Dev shl 3, $0E, Hdr);   { the header type: bit 7, more functions }
            if (Hdr and $80) = 0 then Fn := 8;
          end;
        end
        else if Fn = 0 then Fn := 8;
        Inc(Fn);
      end;
    end;
  if Count > 20 then Count := 20;
  Halt(Count);
end.
