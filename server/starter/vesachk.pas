program VesaChk;
{ DOS Bridge  --  StevenC }
{ What SVGA (VESA VBE) modes, if any, does this card offer?

  Reports through DOS so the answer survives the trip back over the bridge.
  Nothing here changes the video mode -- it only asks questions. }

{$MODE OBJFPC}{$H-}
{$ASMMODE INTEL}


uses About;

type
  TVbeInfo = packed record
    Signature  : array[0..3] of Char;   { +0   'VESA' on the way out }
    Version    : Word;                  { +4   BCD, e.g. $0102 = 1.2 }
    OemPtr     : LongInt;               { +6 }
    Caps       : LongInt;               { +10 }
    ModesPtr   : LongInt;               { +14  far ptr to Word list }
    Memory64K  : Word;                  { +18  video RAM in 64K blocks }
    Filler     : array[0..491] of Byte;
  end;

  TModeInfo = packed record
    Attributes     : Word;    { +0  bit 0 = supported, bit 4 = graphics }
    WinAAttr       : Byte;    { +2 }
    WinBAttr       : Byte;    { +3 }
    WinGranularity : Word;    { +4  bank granularity in KB }
    WinSize        : Word;    { +6 }
    WinASeg        : Word;    { +8 }
    WinBSeg        : Word;    { +10 }
    WinFuncPtr     : LongInt; { +12 }
    BytesPerLine   : Word;    { +16 }
    XRes           : Word;    { +18 }
    YRes           : Word;    { +20 }
    XCharSize      : Byte;    { +22 }
    YCharSize      : Byte;    { +23 }
    NumberOfPlanes : Byte;    { +24 }
    BitsPerPixel   : Byte;    { +25 }
    NumberOfBanks  : Byte;    { +26 }
    MemoryModel    : Byte;    { +27 }
    BankSize       : Byte;    { +28 }
    NumImagePages  : Byte;    { +29 }
    Reserved1      : Byte;    { +30 }
    Filler         : array[0..224] of Byte;
  end;

var
  Info     : TVbeInfo;
  MInfo    : TModeInfo;
  Status   : Word;
  ModeSeg  : Word;
  ModeOfs  : Word;
  Mode     : Word;
  Idx      : Integer;
  Shown    : Integer;
  Deep     : Integer;

function CallVbeInfo: Word;
var
  S, O, R: Word;
begin
  S := Seg(Info);
  O := Ofs(Info);
  asm
    push es
    mov  ax, S
    mov  es, ax
    mov  di, O
    mov  ax, 4F00h
    int  10h
    pop  es
    mov  R, ax
  end;
  CallVbeInfo := R;
end;

function CallModeInfo(M: Word): Word;
var
  S, O, R: Word;
begin
  S := Seg(MInfo);
  O := Ofs(MInfo);
  asm
    push es
    mov  ax, S
    mov  es, ax
    mov  di, O
    mov  cx, M
    mov  ax, 4F01h
    int  10h
    pop  es
    mov  R, ax
  end;
  CallModeInfo := R;
end;

begin
  WriteLn('=== VESA / SVGA probe ===');

  { Asking for 'VBE2' makes a VBE 2.0+ BIOS fill in the extended fields. A 1.x
    BIOS ignores it, which is harmless. }
  Info.Signature[0] := 'V';
  Info.Signature[1] := 'B';
  Info.Signature[2] := 'E';
  Info.Signature[3] := '2';

  Status := CallVbeInfo;
  WriteLn('  INT 10h AX=4F00h returned: ', Status);

  if (Status and $FF) <> $4F then
  begin
    WriteLn('  VBE NOT SUPPORTED - this card has no VESA BIOS.');
    WriteLn('  (AL was not 4Fh, so function 4F00h is not implemented.)');
    Halt(1);
  end;

  if (Status shr 8) <> 0 then
  begin
    WriteLn('  VBE call failed, AH=', Status shr 8);
    Halt(2);
  end;

  if (Info.Signature[0] <> 'V') or (Info.Signature[1] <> 'E') or
     (Info.Signature[2] <> 'S') or (Info.Signature[3] <> 'A') then
  begin
    WriteLn('  Signature is not VESA - refusing to trust the rest.');
    Halt(3);
  end;

  WriteLn('  VESA signature   : OK');
  WriteLn('  VBE version      : ', Info.Version shr 8, '.', Info.Version and $FF);
  WriteLn('  video memory     : ', LongInt(Info.Memory64K) * 64, ' KB');

  ModeSeg := Word(Info.ModesPtr shr 16);
  ModeOfs := Word(Info.ModesPtr and $FFFF);
  WriteLn('  mode list at     : ', ModeSeg, ':', ModeOfs);
  WriteLn;
  WriteLn('  graphics modes (mode, WxH, bpp, granularity, bytes/line):');

  Idx := 0;
  Shown := 0;
  Deep := 0;
  repeat
    Mode := MemW[ModeSeg : ModeOfs + Word(Idx * 2)];
    if Mode = $FFFF then Break;

    if CallModeInfo(Mode) = $004F then
      { bit 0 = mode supported, bit 4 = graphics rather than text }
      if ((MInfo.Attributes and 1) <> 0) and ((MInfo.Attributes and 16) <> 0) then
      begin
        WriteLn('    ', Mode, '  ', MInfo.XRes, 'x', MInfo.YRes,
                '  ', MInfo.BitsPerPixel, 'bpp',
                '  gran=', MInfo.WinGranularity, 'KB',
                '  bpl=', MInfo.BytesPerLine,
                '  model=', MInfo.MemoryModel);
        Inc(Shown);
        if MInfo.BitsPerPixel >= 8 then Inc(Deep);
      end;

    Inc(Idx);
  until (Idx > 200) or (Shown > 40);

  WriteLn;
  WriteLn('  modes listed     : ', Shown, ' (scanned ', Idx, ' entries)');
  WriteLn('  of those, 8bpp+  : ', Deep);
  if (Shown > 0) and (Deep = 0) then
  begin
    WriteLn('  NOTE: every graphics mode here is planar (under 8 bits per');
    WriteLn('        pixel), so none of them is a linear 256-colour mode.');
    WriteLn('        This used to be filtered out silently and reported as');
    WriteLn('        "0 modes", which reads as "no SVGA at all" and is wrong.');
  end;
  WriteLn('  Run VMODES /T to find out which of these actually set.');
end.
