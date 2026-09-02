program VModes;
{ DOS Bridge  --  StevenC }
{ Every video mode this card offers, and -- optionally -- whether each one
  actually works when you set it.

  Usage:  VMODES            list only. Sets nothing, changes nothing.
          VMODES -t         SET each mode, verify it, restore text. Fast:
                            nothing is drawn and nothing is held, so this
                            proves the BIOS accepted the mode and no more.
          VMODES -t -d 3    ...and DISPLAY a test pattern in each mode for
                            three seconds, so a human at the monitor can see
                            whether it actually syncs and looks right.
          VMODES -t 13      one standard BIOS mode only (decimal 0..19)
          VMODES -t 257     one VESA mode only (decimal; 257 = 101h)

  -d needs someone watching the screen. Nothing about a picture being wrong
  can come back over the bridge -- the log will happily say OK for a mode the
  monitor cannot display. Run it with BEEP so you know when to look:

      dosexec "BEEP ALERT" "VMODES -t -d 3" "BEEP DONE"

  Why this exists alongside VESACHK: VESACHK asks the card what it offers and
  believes the answer. On the box this was written for that answer is "0 modes"
  while the card is plainly capable of more -- it lists seven mode numbers and
  every one of them fails the supported/graphics attribute test. Enumeration
  alone therefore cannot tell you what works. Setting a mode and looking at
  what came back can.

  Two things make this safe to run over the bridge:

  * Every line is flushed as it is printed. DOS buffers output to a redirected
    file and loses the buffer if the machine wedges, so an unflushed log would
    end before the mode that caused the problem. Flushed, the last line names
    the culprit.
  * Text mode is restored after every single mode, not once at the end. A hang
    partway through therefore leaves the machine on a usable screen, and the
    modes already tested stay tested.

  Nothing here needs the screen: results go back through DOS. }

{$MODE OBJFPC}{$H-}
{$ASMMODE INTEL}

uses VGA, About;

type
  TStd = record
    M    : Byte;
    Gfx  : Boolean;
    Sg   : Word;          { framebuffer segment, 0 = do not probe }
    W, H : Word;          { pixels for graphics, characters for text }
    Desc : String[26];
  end;

const
  { The modes an IBM-compatible BIOS is expected to know. Text modes are
    listed too: they are the ones you have to be able to get *back* to. }
  NSTD = 15;
  Std: array[1 .. NSTD] of TStd = (
    (M:$00; Gfx:False; Sg:$B800; W:40;  H:25;  Desc:'40x25 text, 16 grey'),
    (M:$01; Gfx:False; Sg:$B800; W:40;  H:25;  Desc:'40x25 text, 16 colour'),
    (M:$02; Gfx:False; Sg:$B800; W:80;  H:25;  Desc:'80x25 text, 16 grey'),
    (M:$03; Gfx:False; Sg:$B800; W:80;  H:25;  Desc:'80x25 text, 16 colour'),
    (M:$04; Gfx:True;  Sg:$B800; W:320; H:200; Desc:'320x200 CGA, 4 colour'),
    (M:$05; Gfx:True;  Sg:$B800; W:320; H:200; Desc:'320x200 CGA, 4 grey'),
    (M:$06; Gfx:True;  Sg:$B800; W:640; H:200; Desc:'640x200 CGA, mono'),
    (M:$07; Gfx:False; Sg:$B000; W:80;  H:25;  Desc:'80x25 text, MDA mono'),
    (M:$0D; Gfx:True;  Sg:$A000; W:320; H:200; Desc:'320x200 EGA, 16 colour'),
    (M:$0E; Gfx:True;  Sg:$A000; W:640; H:200; Desc:'640x200 EGA, 16 colour'),
    (M:$0F; Gfx:True;  Sg:$A000; W:640; H:350; Desc:'640x350 EGA, mono'),
    (M:$10; Gfx:True;  Sg:$A000; W:640; H:350; Desc:'640x350 EGA, 16 colour'),
    (M:$11; Gfx:True;  Sg:$A000; W:640; H:480; Desc:'640x480 VGA, 2 colour'),
    (M:$12; Gfx:True;  Sg:$A000; W:640; H:480; Desc:'640x480 VGA, 16 colour'),
    (M:$13; Gfx:True;  Sg:$A000; W:320; H:200; Desc:'320x200 VGA, 256 colour'));

type
  TVbeInfo = packed record
    Signature  : array[0..3] of Char;
    Version    : Word;
    OemPtr     : LongInt;
    Caps       : LongInt;
    ModesPtr   : LongInt;
    Memory64K  : Word;
    Filler     : array[0..491] of Byte;
  end;

  TModeInfo = packed record
    Attributes     : Word;    { bit 0 supported, bit 3 colour, bit 4 graphics }
    WinAAttr       : Byte;
    WinBAttr       : Byte;
    WinGranularity : Word;
    WinSize        : Word;
    WinASeg        : Word;
    WinBSeg        : Word;
    WinFuncPtr     : LongInt;
    BytesPerLine   : Word;
    XRes           : Word;
    YRes           : Word;
    Pad2           : array[0..5] of Byte;
    Planes         : Byte;
    BitsPerPixel   : Byte;
    Rest           : array[0..231] of Byte;
  end;

var
  DwellTicks : LongInt;     { 0 = do not draw or hold, just set and check }
  Info      : TVbeInfo;
  MInfo     : TModeInfo;
  RAX, RBX  : Word;
  TextMode  : Byte;
  DoTest    : Boolean;
  Only      : LongInt;      { -1 = all }
  Tried, Worked, Failed : Integer;

const
  HexD: array[0..15] of Char = '0123456789ABCDEF';

function Hex2(B: Byte): ShortString;
begin
  Hex2 := HexD[(B shr 4) and 15] + HexD[B and 15];
end;

function Hex3(W: Word): ShortString;
begin
  Hex3 := HexD[(W shr 8) and 15] + HexD[(W shr 4) and 15] + HexD[W and 15];
end;

{ Every report line goes through here. The Flush is the whole point: DOS holds
  redirected output in a buffer and drops it if the machine stops, so without
  this the log would end *before* whichever mode caused the trouble. }
procedure Say(const S: ShortString);
begin
  WriteLn(S);
  Flush(Output);
end;

function Pad(const S: ShortString; N: Integer): ShortString;
var
  T: ShortString;
begin
  T := S;
  while Length(T) < N do T := T + ' ';
  Pad := T;
end;

{ How many colours a standard mode shows. Used only to keep the test bars
  inside the palette -- drawing colour 9 in a 4-colour mode just wraps. }
function StdColours(M: Byte): Word;
begin
  case M of
    $04, $05 : StdColours := 4;
    $06, $0F, $11 : StdColours := 2;
    $13 : StdColours := 256;
  else
    StdColours := 16;
  end;
end;

function Num(L: LongInt): ShortString;
var
  S: ShortString;
begin
  Str(L, S);
  Num := S;
end;

{ --- VESA calls -------------------------------------------------------- }

procedure VbeInfoCall;
var
  Sg, O: Word;
begin
  Info.Signature[0] := 'V'; Info.Signature[1] := 'B';
  Info.Signature[2] := 'E'; Info.Signature[3] := '2';
  Sg := Seg(Info); O := Ofs(Info);
  asm
    push es
    mov  ax, Sg
    mov  es, ax
    mov  di, O
    mov  ax, 4F00h
    int  10h
    pop  es
    mov  RAX, ax
  end;
end;

procedure VbeModeInfo(Mode: Word);
var
  Sg, O: Word;
begin
  Sg := Seg(MInfo); O := Ofs(MInfo);
  asm
    push es
    mov  ax, Sg
    mov  es, ax
    mov  di, O
    mov  cx, Mode
    mov  ax, 4F01h
    int  10h
    pop  es
    mov  RAX, ax
  end;
end;

procedure VbeSet(Mode: Word);
begin
  asm
    mov ax, 4F02h
    mov bx, Mode
    int 10h
    mov RAX, ax
  end;
end;

procedure VbeGet;
begin
  asm
    mov ax, 4F03h
    int 10h
    mov RAX, ax
    mov RBX, bx
  end;
end;

{ Prove the framebuffer is really there: write a byte, read it back, put the
  original back. Reported rather than judged -- the planar EGA modes go through
  the VGA's latches, where a plain write/read pair legitimately returns
  something else. A mode that sets correctly but reads back oddly is working;
  a mode that will not set at all is not. }
function ProbeFB(Sg: Word): ShortString;
var
  Old, Got: Byte;
begin
  if Sg = 0 then
  begin
    ProbeFB := '';
    Exit;
  end;
  Old := Mem[Sg : 0];
  Mem[Sg : 0] := $A5;
  Got := Mem[Sg : 0];
  Mem[Sg : 0] := Old;
  if Got = $A5 then ProbeFB := ' fb:ok'
  else ProbeFB := ' fb:read ' + Hex2(Got);
end;

{ --- the visible part -------------------------------------------------- }

{ One pixel through the BIOS rather than through the framebuffer.
  INT 10h AH=0Ch works in *every* graphics mode -- CGA's interleaved pairs,
  EGA/VGA's four bit planes, and VESA's banked windows alike -- because the
  BIOS knows the layout and we do not. It is far too slow for a real demo, at
  roughly a millisecond a pixel here, which is exactly why the pattern below
  is drawn sparsely rather than filled. }
procedure PutPix(X, Y, C: Word);
begin
  asm
    mov ah, 0Ch
    mov al, byte ptr C
    mov bh, 0
    mov cx, X
    mov dx, Y
    int 10h
  end;
end;

{ A frame, colour bars, and two diagonals. Enough to show at a glance whether
  the mode syncs, whether the geometry is right, and how many distinct colours
  actually appear -- a 2-colour mode draws the bars in alternating black and
  white, which still proves the mode is live. }
procedure DrawPattern(W, H, Colours: Word);
var
  X, Y, I, C, BarW: Word;
begin
  if (W = 0) or (H = 0) then Exit;
  if Colours < 2 then Colours := 2;

  { Border, every other pixel: the corners tell you the visible area. }
  X := 0;
  while X < W do
  begin
    PutPix(X, 0, Colours - 1);
    PutPix(X, H - 1, Colours - 1);
    Inc(X, 2);
  end;
  Y := 0;
  while Y < H do
  begin
    PutPix(0, Y, Colours - 1);
    PutPix(W - 1, Y, Colours - 1);
    Inc(Y, 2);
  end;

  { Sixteen vertical bars, sampled every fourth row so this stays quick. }
  BarW := W div 16;
  if BarW = 0 then BarW := 1;
  for I := 0 to 15 do
  begin
    C := I;
    if C >= Colours then C := C mod Colours;
    X := I * BarW + (BarW div 2);
    if X >= W then Continue;
    Y := H div 4;
    while Y < (H * 3) div 4 do
    begin
      PutPix(X, Y, C);
      Inc(Y, 4);
    end;
  end;

  { Diagonals, so a squashed or offset picture is obvious. }
  I := 0;
  while (I < W) and (I < H) do
  begin
    PutPix(I, (LongInt(I) * H) div W, Colours - 1);
    PutPix(W - 1 - I, (LongInt(I) * H) div W, Colours - 1);
    Inc(I, 3);
  end;
end;

{ Text modes get characters, not pixels: cycling attributes across the whole
  screen so wrong geometry (a 132-column mode showing 80) is immediately
  visible. Written straight to the buffer -- in text mode that is the fast
  path and the mode is already known good by the time we get here. }
procedure DrawText(Sg, Cols, Rows: Word);
var
  R, C: Word;
  Ch, At: Byte;
begin
  if (Cols = 0) or (Rows = 0) then Exit;
  if Cols > 200 then Cols := 200;
  if Rows > 80 then Rows := 80;
  for R := 0 to Rows - 1 do
    for C := 0 to Cols - 1 do
    begin
      Ch := Byte(48 + (C mod 10));
      At := Byte(((R mod 8) shl 4) or (1 + (C mod 15)));
      MemW[Sg : (R * Cols + C) * 2] := (Word(At) shl 8) or Ch;
    end;
end;

{ Hold the picture. BIOS ticks, so no calibration and no busy-loop that would
  run at a different speed on a different machine. }
procedure Hold;
var
  T0: LongInt;
begin
  if DwellTicks <= 0 then Exit;
  T0 := Ticks;
  while (Ticks - T0) < DwellTicks do ;
end;

{ --- the actual test ---------------------------------------------------- }

procedure TestStd(const E: TStd);
var
  Got: Byte;
  FB : ShortString;
begin
  Say('  trying ' + Hex2(E.M) + 'h  ' + Pad(E.Desc, 26) + ' ...');
  Inc(Tried);

  SetMode(E.M);
  Got := GetMode;
  if E.Gfx then FB := ProbeFB(E.Sg) else FB := '';

  if (DwellTicks > 0) and (Got = E.M) then
  begin
    if E.Gfx then DrawPattern(E.W, E.H, StdColours(E.M))
    else DrawText(E.Sg, E.W, E.H);
    Hold;
  end;

  { Back to something readable before reporting, every single time. }
  SetMode(TextMode);

  if Got = E.M then
  begin
    Inc(Worked);
    Say('    OK       set and confirmed' + FB);
  end
  else
  begin
    Inc(Failed);
    Say('    NO       asked for ' + Hex2(E.M) + 'h, card reports '
        + Hex2(Got) + 'h');
  end;
end;

procedure TestVesa(Mode: Word);
var
  FB   : ShortString;
  Cur  : Word;
  W, H, B: Word;
begin
  VbeModeInfo(Mode);
  if (RAX and $FF) <> $4F then
  begin
    Say('  ' + Hex3(Mode) + 'h   no mode information available');
    Exit;
  end;
  W := MInfo.XRes; H := MInfo.YRes; B := MInfo.BitsPerPixel;

  Say('  trying ' + Hex3(Mode) + 'h  ' +
      Pad(Num(W) + 'x' + Num(H) + 'x' + Num(B), 26) + ' ...');
  Inc(Tried);

  VbeSet(Mode);
  if (RAX and $FF00) <> 0 then
  begin
    Inc(Failed);
    SetMode(TextMode);
    Say('    NO       4F02h refused it (AH=' + Hex2(RAX shr 8) + ')');
    Exit;
  end;

  VbeGet;
  Cur := RBX and $3FFF;
  FB := ProbeFB(MInfo.WinASeg);

  if DwellTicks > 0 then
  begin
    { Attribute bit 4 separates a graphics mode from a text one; the same
      field VESACHK filters on, used here to pick how to draw rather than to
      decide whether to bother. }
    if (MInfo.Attributes and 16) <> 0 then
      DrawPattern(W, H, 1 shl B)
    else
      DrawText(MInfo.WinASeg, W, H);
    Hold;
  end;

  SetMode(TextMode);

  if Cur = Mode then
  begin
    Inc(Worked);
    Say('    OK       set and confirmed' + FB);
  end
  else
  begin
    Inc(Worked);
    Say('    OK?      set, but 4F03h reports ' + Hex3(Cur) + 'h' + FB);
  end;
end;

{ --- main -------------------------------------------------------------- }

var
  I, Idx : Integer;
  S      : ShortString;
  Code   : Integer;
  Mode   : Word;
  MSeg, MOfs : Word;
  Listed : Integer;
  DispOk : Boolean;
  WantDwell : Boolean;
  N      : LongInt;
  DispCode : Byte;
  Supp   : ShortString;

begin
  DoTest := False;
  WantDwell := False;
  DwellTicks := 0;
  Only := -1;
  for I := 1 to ParamCount do
  begin
    S := ParamStr(I);
    if (S = '/T') or (S = '/t') or (S = '-t') then
      DoTest := True
    else if (S = '/D') or (S = '/d') or (S = '-d') then
      WantDwell := True
    else
    begin
      Val(S, N, Code);
      if Code = 0 then
      begin
        if WantDwell then
        begin
          { The number after -d is seconds, not a mode. }
          if N < 1 then N := 1;
          if N > 30 then N := 30;
          DwellTicks := (N * 182) div 10;
          WantDwell := False;
        end
        else
          Only := N;
      end;
    end;
  end;

  { Whatever text mode this machine came up in is the one to go back to. The
    card here boots mono or colour at random, so this is read, never assumed. }
  TextMode := GetMode;
  DispCode := DisplayCode(DispOk);
  if DispOk then Supp := '' else Supp := ' (no BIOS opinion)';
  if (TextMode <> 3) and (TextMode <> 7) then
  begin
    if IsColourDisplay then TextMode := 3 else TextMode := 7;
  end;

  Say('=== vmodes: video modes on this card ===');
  Say('  display        : code ' + Num(DispCode) + Supp + ',  text mode '
      + Hex2(TextMode) + 'h');
  if DoTest and (DwellTicks > 0) then
  begin
    Say('  mode           : TEST + DISPLAY -- a pattern is drawn in each mode');
    Say('                   and held for ' + Num((DwellTicks * 10) div 182)
        + ' second(s). SOMEBODY HAS TO BE WATCHING:');
    Say('                   a monitor that cannot sync still logs as OK.');
  end
  else if DoTest then
    Say('  mode           : TEST -- set and checked only, nothing is drawn '
        + 'or held')
  else
    Say('  mode           : LIST only -- nothing is set (add /T to test)');
  Say('');

  { --- standard BIOS modes --------------------------------------------- }
  Say('--- standard BIOS modes ---');
  for I := 1 to NSTD do
  begin
    if (Only >= 0) and (Only < $100) and (Std[I].M <> Byte(Only)) then Continue;
    if DoTest then
      TestStd(Std[I])
    else
      Say('  ' + Hex2(Std[I].M) + 'h   ' + Std[I].Desc);
  end;

  { --- VESA modes ------------------------------------------------------- }
  Say('');
  Say('--- VESA / VBE modes ---');
  VbeInfoCall;
  if ((RAX and $FF) <> $4F) or (Info.Signature[0] <> 'V')
     or (Info.Signature[1] <> 'E') then
  begin
    Say('  no VESA BIOS on this card.');
  end
  else
  begin
    Say('  VBE version    : ' + Num(Info.Version shr 8) + '.'
        + Num(Info.Version and $FF));
    Say('  video memory   : ' + Num(LongInt(Info.Memory64K) * 64) + ' KB');
    MSeg := Word(Info.ModesPtr shr 16);
    MOfs := Word(Info.ModesPtr and $FFFF);
    Say('');

    Listed := 0;
    Idx := 0;
    while Idx < 128 do
    begin
      Mode := MemW[MSeg : MOfs + Word(Idx * 2)];
      if Mode = $FFFF then Break;
      Inc(Listed);

      if (Only >= 0) and (LongInt(Mode) <> Only) then
      begin
        Inc(Idx);
        Continue;
      end;

      if DoTest then
        TestVesa(Mode)
      else
      begin
        VbeModeInfo(Mode);
        if (RAX and $FF) <> $4F then
          Say('  ' + Hex3(Mode) + 'h   (no mode info)')
        else
          { Attributes are printed rather than used as a filter. VESACHK
            filters on them and reports nothing at all on this card; showing
            the raw word is what makes it obvious why. }
          Say('  ' + Hex3(Mode) + 'h   '
              + Pad(Num(MInfo.XRes) + 'x' + Num(MInfo.YRes)
                    + 'x' + Num(MInfo.BitsPerPixel), 16)
              + ' attr=' + Hex2(MInfo.Attributes shr 8)
              + Hex2(MInfo.Attributes and $FF)
              + '  win=' + Hex2(MInfo.WinASeg shr 8) + '00');
      end;
      Inc(Idx);
    end;
    Say('');
    Say('  modes advertised: ' + Num(Listed));
  end;

  { Belt and braces: whatever happened above, leave a usable screen. }
  SetMode(TextMode);

  Say('');
  if DoTest then
  begin
    Say('  tried ' + Num(Tried) + ', worked ' + Num(Worked)
        + ', failed ' + Num(Failed));
    if Failed > 20 then Halt(20);
    Halt(Failed);
  end;
  Halt(0);
end.
