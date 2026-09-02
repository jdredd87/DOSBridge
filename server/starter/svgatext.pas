program SvgaText;
{ DOS Bridge  --  StevenC }
{ Rotating text for thirty seconds, in SVGA if the card can do it and mode 13h
  if it cannot.

  Usage:  SVGATEXT                     the default message
          SVGATEXT Hello there!        anything you like, up to 30 characters

  The message comes from the raw DOS command tail, not ParamStr, so spacing
  and punctuation survive exactly as typed.

  Notes for the 8086-class baseline this targets:

  * 640x480x256 is 307200 bytes, which does not fit the 64K window at A000.
    The card reports 64K granularity, so the screen spans five banks and every
    write needs the right one selected. Bank switches go through INT 10h and
    are far too slow to do per pixel, so points are bucketed by bank first and
    the frame is drawn in five passes -- five switches per frame, not thousands.
  * Erase is a replay of last frame's points in colour 0, not a screen clear.
    Clearing 307200 bytes per frame would cost more than the entire budget.
  * Rotation is Q7 fixed point (128 = 1.0) from a quarter-wave sine table. Q8
    would overflow: 240*256 is past a 16-bit Integer. (Fixed point rather than
    FPU because the suite targets machines that may have no coprocessor.)
  * The glyphs come from the ROM 8x8 font. INT 10h AH=11h returns its address
    in ES:BP, which clobbers the frame pointer -- hence the push/pop bp and the
    globals to catch the result.
  * This card boots mono or colour unpredictably, so the text colour is chosen
    at run time. MONO / COLOUR on the command line overrides the probe.
  * It reports what it did with WriteLn. Direct writes to A000 never make it
    back over the bridge, so a program that only draws returns an empty log. }

{$MODE OBJFPC}{$H-}
{$ASMMODE INTEL}


uses About;

const
  { 640x480x256, which needs 300 KB of video memory.

    Whether that is available is not a fixed property of the machine. The card
    this was developed against reports 256 KB on some boots and 1024 KB on
    others, with an entirely different mode list each way -- 2 graphics modes
    against 18 -- and nothing reconfigured in between. So this mode set fine
    one day and was refused outright the next.

    Hence the fallback below rather than an error message. Ask for the good
    mode, take mode 13h when it is not there, and never assume which boot you
    are on. }
  SVGA_MODE = $101;
  MODE13    = $13;

  { Array bounds, not the live geometry. ScrW/ScrH below hold whichever mode
    actually came up. }
  MAX_W     = 640;
  MAX_H     = 480;
  VGA_SEG   = $A000;
  RUN_TICKS = 546;         { BIOS ticks at 18.2 Hz, so about thirty seconds }

  MSG    = 'DOS + Claude = DOS Bridge!';
  MAXMSG = 30;             { longer than this will not fit across 320 pixels }

  MAXBANK = 5;
  MAXPT   = 1600;          { per bank, per frame -- must be at least as big
                             as the source point count, because in a
                             single-bank mode (13h) every point lands in
                             bank 0 and anything over this is dropped }

  { sin(i * 90/64 degrees) * 128, one quarter wave. }
  SinQ: array[0..64] of Integer = (
       0,    3,    6,    9,   13,   16,   19,   22,
      25,   28,   31,   34,   37,   40,   43,   46,
      49,   52,   55,   58,   60,   63,   66,   68,
      71,   74,   76,   79,   81,   84,   86,   88,
      91,   93,   95,   97,   99,  101,  103,  105,
     106,  108,  110,  111,  113,  114,  116,  117,
     118,  119,  121,  122,  122,  123,  124,  125,
     126,  126,  127,  127,  127,  128,  128,  128,
     128);

type
  TModeInfo = packed record
    Attributes     : Word;    { +0 }
    WinAAttr       : Byte;    { +2 }
    WinBAttr       : Byte;    { +3 }
    WinGranularity : Word;    { +4 }
    WinSize        : Word;    { +6 }
    WinASeg        : Word;    { +8 }
    WinBSeg        : Word;    { +10 }
    WinFuncPtr     : LongInt; { +12  far ptr to the bank switcher }
    BytesPerLine   : Word;    { +16 }
    Filler         : array[0..237] of Byte;
  end;

var
  MInfo       : TModeInfo;
  WinFunc     : LongInt;      { seg:ofs of the VBE bank switcher }
  UseFastBank : Boolean;
  BankSwitches: LongInt;

  { INT 10h AH=11h returns the font address in ES:BP. BP is the frame pointer,
    so these must be globals -- a local would be addressed through the very
    register the BIOS is overwriting. }
  FontSeg, FontOfs : Word;

  OldMode      : Byte;
  StartTick    : LongInt;
  Elapsed      : LongInt;
  Frames       : LongInt;
  PointsDrawn  : LongInt;
  Clipped      : LongInt;
  UsedColour   : Boolean;
  Forced       : ShortString;
  ModeOK       : Boolean;

  { Screen row -> bank and within-bank offset, worked out once. }
  RowBank : array[0..MAX_H - 1] of Byte;
  RowOfs  : array[0..MAX_H - 1] of Word;

  { The text bitmap, expanded once at startup into rotation-ready source
    points. It never changes -- only the angle does -- so none of the glyph
    reading or bit testing belongs in the frame loop. }
  SrcU, SrcV : array[0..1599] of Integer;
  NSrc       : Integer;
  NTrunc     : Integer;
  MsgS       : ShortString;

  { Live geometry. Set once the mode is known, because this now runs in either
    640x480 VESA or 320x200 mode 13h and the two differ in every dimension. }
  ScrW, ScrH : Integer;
  Scale      : Integer;      { font pixel -> Scale x Scale screen pixels }
  CX0, CY0   : Integer;
  NBank      : Integer;      { 5 for 640x480x256, 1 for mode 13h }
  ModeUsed   : Word;
  FellBack   : Boolean;

  { Points bucketed by bank. Two sets: one being drawn, one to erase. }
  PtOfs : array[0..1, 0..MAXBANK - 1, 0..MAXPT - 1] of Word;
  PtCnt : array[0..1, 0..MAXBANK - 1] of Integer;
  Cur   : Integer;

  CurBank : Integer;
  Angle   : Integer;
  I       : Integer;

function Ticks: LongInt;
begin
  Ticks := MemL[$0040:$006C];
end;

function GetMode: Byte;
var A: Word;
begin
  asm
    mov ah, 0Fh
    int 10h
    mov A, ax
  end;
  GetMode := A and $FF;
end;

procedure SetTextMode(M: Byte);
begin
  asm
    mov al, M
    xor ah, ah
    int 10h
  end;
end;

{ VBE function 02h. Returns AX; $004F means it worked. }
function SetSvgaMode(M: Word): Word;
var R: Word;
begin
  asm
    mov ax, 4F02h
    mov bx, M
    int 10h
    mov R, ax
  end;
  SetSvgaMode := R;
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

{ Select a 64K window. Granularity is 64K on this card, so the window position
  in granularity units is just the bank number.

  VBE publishes a far pointer to the bank switcher so callers can skip INT 10h.
  Kept because it is the correct way to do this, but measured honestly it
  changed nothing here: frame count was identical either way. Only about three
  switches happen per frame, and this card's BIOS handles them cheaply. The
  frame cost is in BuildFrame, not here. Same register contract as function
  4F05h, minus AX; falls back to INT 10h if no pointer is offered. }
procedure SetBank(B: Word);
begin
  { Mode 13h is 64000 bytes: one window, no banking, and calling INT 10h 4F05h
    on a card that is not in a VESA mode is asking for trouble. }
  if NBank <= 1 then Exit;
  Inc(BankSwitches);
  if UseFastBank then
    asm
      push bx
      push dx
      xor  bx, bx          { BH=0 = set, BL=0 = window A }
      mov  dx, B
      call far [WinFunc]
      pop  dx
      pop  bx
    end
  else
    asm
      mov ax, 4F05h
      xor bx, bx
      mov dx, B
      int 10h
    end;
end;

procedure OutB(P: Word; V: Byte);
begin
  asm
    mov dx, P
    mov al, V
    out dx, al
  end;
end;

function IsColourDisplay: Boolean;
var A, B: Word;
begin
  asm
    mov ax, 1A00h
    int 10h
    mov A, ax
    mov B, bx
  end;
  if (A and $FF) <> $1A then
    IsColourDisplay := True
  else
    case (B and $FF) of
      1, 5, 7, $0B: IsColourDisplay := False;
    else
      IsColourDisplay := True;
    end;
end;

procedure GetRomFont;
begin
  asm
    push es
    push bp
    mov  ax, 1130h
    mov  bh, 03h        { 03h = the 8x8 ROM font }
    int  10h
    mov  FontSeg, es
    mov  FontOfs, bp
    pop  bp
    pop  es
  end;
end;

{ Full-circle sine on a 256-step angle, Q7. Built from the quarter wave by
  symmetry so only 65 constants are needed. }
function Sin256(A: Integer): Integer;
begin
  A := A and 255;
  if A < 64 then
    Sin256 := SinQ[A]
  else if A < 128 then
    Sin256 := SinQ[128 - A]
  else if A < 192 then
    Sin256 := -SinQ[A - 128]
  else
    Sin256 := -SinQ[256 - A];
end;

function Cos256(A: Integer): Integer;
begin
  Cos256 := Sin256(A + 64);
end;

procedure BuildRowTables;
var
  Y: Integer;
  T: LongInt;
begin
  for Y := 0 to ScrH - 1 do
  begin
    T := LongInt(Y) * ScrW;
    RowBank[Y] := Byte(T shr 16);
    RowOfs[Y]  := Word(T and $FFFF);
  end;
end;

{ Write a whole bank's worth of pixel pairs in one call.

  This replaced a per-point PlotPair, which cost a far call each and ran about
  1292 times a frame. Parameters stay reachable while DS is redirected at the
  point list, because [BP+n] addressing defaults to SS, not DS. }
procedure PlotList(var Arr; Count: Word; Col: Word); assembler;
asm
  push ds
  push es
  push si
  push di
  push bx
  mov  cx, Count
  mov  bx, Col
  mov  ax, VGA_SEG
  mov  es, ax
  lds  si, Arr
  jcxz @@done
  cld
@@loop:
  lodsw                  { AX = next offset within the bank }
  mov  di, ax
  mov  es:[di], bx
  loop @@loop
@@done:
  pop  bx
  pop  di
  pop  si
  pop  es
  pop  ds
end;

{ The message, taken from the raw DOS command tail rather than from ParamStr.

  ParamStr would work for a single word, but the interesting messages are
  sentences, and DOS argument splitting eats the spacing -- and depending on
  the parser, '=' and ',' as well. The tail at PSP:0080 is exactly what was
  typed, punctuation and all, which matters when the default is

      DOS + Claude = DOS Bridge!

  Non-printable bytes are dropped: this is going through an 8x8 ROM font, and
  a control character there is a glyph nobody wants to see rotating. }
function CmdTail: ShortString;
var
  L, I : Byte;
  C    : Char;
  S    : ShortString;
begin
  S := '';
  L := Mem[PrefixSeg : $80];
  for I := 1 to L do
  begin
    C := Chr(Mem[PrefixSeg : Word($80 + I)]);
    if (C >= ' ') and (C <= '~') then S := S + C;
    if Length(S) >= MAXMSG then Break;
  end;
  while (Length(S) > 0) and (S[1] = ' ') do Delete(S, 1, 1);
  while (Length(S) > 0) and (S[Length(S)] = ' ') do Delete(S, Length(S), 1);
  CmdTail := S;
end;

{ Expand the message into source points once. Every set font pixel becomes
  SCALE points, one per sub-row, each carrying its offset from the centre of
  the string. }
procedure BuildSource;
var
  Ch, Row, Bit, Sy : Integer;
  Glyph, Mask      : Byte;
begin
  { Character outer, row inner -- and that order is deliberate.

    It used to be the other way round, filling row band 0 across the whole
    string, then band 1, and so on. That works until the point array fills up,
    at which point generation stops mid-band and the BOTTOM OF EVERY CHARACTER
    is silently missing. It looked like a rendering bug and was really an
    overflow.

    This way an overflow drops trailing characters instead, which is both
    obvious and far less ugly. NTrunc records it so the log says so rather than
    leaving you to notice. }
  NSrc := 0;
  NTrunc := 0;
  for Ch := 1 to Length(MsgS) do
    for Row := 0 to 7 do
    begin
      Glyph := Mem[FontSeg : FontOfs + Word(Ord(MsgS[Ch])) * 8 + Word(Row)];
      if Glyph <> 0 then
      begin
        Mask := 128;
        for Bit := 0 to 7 do
        begin
          if (Glyph and Mask) <> 0 then
            for Sy := 0 to Scale - 1 do
              if NSrc > High(SrcU) then
                Inc(NTrunc)
              else
              begin
                { Centred on the real string length, not a hardcoded one -- the
                  message is a command-line argument now. }
                SrcU[NSrc] := ((Ch - 1) * 8 + Bit) * Scale
                              - (Length(MsgS) * 8 * Scale) div 2;
                SrcV[NSrc] := Row * Scale + Sy - (8 * Scale) div 2;
                Inc(NSrc);
              end;
          Mask := Mask shr 1;
        end;
      end;
    end;
end;

{ Rotate every source point by Angle and bucket the result by bank.

  This is the whole cost of a frame. Measured alone it ran at the same speed as
  the complete demo, while painting alone managed 174 fps -- so this is where
  any speed has to come from.

  Earlier versions rebuilt the glyph bitmap here every frame: 160 font reads,
  1280 bit tests and 160 indexes into a `const` string, all to reproduce a
  bitmap that never changes. BuildSource now does that once at startup and this
  loop is pure arithmetic. }
procedure BuildFrame;
var
  K, S, C        : Integer;
  U, V, Dx, Dy   : Integer;
  B              : Integer;
  O, Base        : Word;
begin
  for K := 0 to MAXBANK - 1 do
    PtCnt[Cur, K] := 0;

  S := Sin256(Angle);
  C := Cos256(Angle);

  for K := 0 to NSrc - 1 do
  begin
    U := SrcU[K];
    V := SrcV[K];

    Dx := CX0 + ((U * C - V * S) div 128);
    Dy := CY0 + ((U * S + V * C) div 128);

    if (Dx >= 0) and (Dx <= ScrW - 2) and (Dy >= 0) and (Dy <= ScrH - 1) then
    begin
      Base := RowOfs[Dy];
      O    := Word(Base + Word(Dx));
      B    := RowBank[Dy];
      { Word arithmetic wraps at 64K; if it did, we crossed into the next bank. }
      if O < Base then Inc(B);
      if (O <> $FFFF) and (B < NBank) and (PtCnt[Cur, B] < MAXPT) then
      begin
        PtOfs[Cur, B, PtCnt[Cur, B]] := O;
        Inc(PtCnt[Cur, B]);
      end;
    end
    else
      Inc(Clipped);
  end;
end;

{ One pass per bank: erase last frame's points, then draw this frame's. Doing
  both inside the same bank pass keeps it to five switches per frame. }
procedure PaintFrame(TextPair: Word);
var
  B, Prev: Integer;
begin
  Prev := 1 - Cur;
  for B := 0 to NBank - 1 do
  begin
    if (PtCnt[Prev, B] = 0) and (PtCnt[Cur, B] = 0) then Continue;
    SetBank(Word(B));
    CurBank := B;

    if PtCnt[Prev, B] > 0 then
      PlotList(PtOfs[Prev, B, 0], Word(PtCnt[Prev, B]), 0);

    if PtCnt[Cur, B] > 0 then
      PlotList(PtOfs[Cur, B, 0], Word(PtCnt[Cur, B]), TextPair);

    Inc(PointsDrawn, PtCnt[Cur, B]);
  end;
end;

var
  TextPair: Word;
  W1      : ShortString;

begin
  OldMode := GetMode;

  { The whole tail is the message, except for a leading MONO or COLOUR, which
    stays supported as a palette override. Consuming it here is what keeps
    `SVGATEXT MONO hello there` from rotating the word MONO across the screen. }
  MsgS   := CmdTail;
  Forced := '';
  W1     := '';
  I      := 1;
  while (I <= Length(MsgS)) and (MsgS[I] <> ' ') do
  begin
    if (MsgS[I] >= 'a') and (MsgS[I] <= 'z') then
      W1 := W1 + Chr(Ord(MsgS[I]) - 32)
    else
      W1 := W1 + MsgS[I];
    Inc(I);
  end;

  if (W1 = 'MONO') or (W1 = 'COLOUR') or (W1 = 'COLOR') then
  begin
    Forced := W1;
    UsedColour := W1 <> 'MONO';
    Delete(MsgS, 1, Length(W1));
    while (Length(MsgS) > 0) and (MsgS[1] = ' ') do Delete(MsgS, 1, 1);
  end
  else
    UsedColour := IsColourDisplay;

  if MsgS = '' then MsgS := MSG;

  GetRomFont;

  Frames       := 0;
  BankSwitches := 0;
  UseFastBank  := False;
  WinFunc      := 0;
  if CallModeInfo(SVGA_MODE) = $004F then
  begin
    WinFunc := MInfo.WinFuncPtr;
    UseFastBank := WinFunc <> 0;
  end;
  PointsDrawn := 0;
  Clipped     := 0;
  Cur         := 0;
  Angle       := 0;

  StartTick := Ticks;

  { Try SVGA, fall back to mode 13h.

    640x480x256 needs 300 KB of video memory and plenty of cards do not have
    it -- the one this was developed on has 256 KB and refuses 4F02h outright,
    which used to make this demo exit with an error and draw nothing at all.
    Mode 13h is 320x200x256, guaranteed on any VGA, linear, and needs no bank
    switching. Half the resolution, so the font is drawn 1:1 instead of 2:2,
    and the same rotation code runs unchanged. }
  ModeOK   := SetSvgaMode(SVGA_MODE) = $004F;
  FellBack := False;
  if ModeOK then
  begin
    ModeUsed := SVGA_MODE;
    ScrW := 640; ScrH := 480; Scale := 2; NBank := 5;
  end
  else
  begin
    FellBack := True;
    SetTextMode(MODE13);   { SetTextMode is just INT 10h AH=0 -- works for any mode }
    if GetMode <> MODE13 then
    begin
      WriteLn('=== rotating text ===');
      WriteLn('  Neither VBE ', SVGA_MODE, ' nor mode 13h would set. This card');
      WriteLn('  offers neither; run VMODES to see what it does offer.');
      Halt(1);
    end;
    ModeUsed := MODE13;
    ScrW := 320; ScrH := 200; Scale := 1; NBank := 1;
  end;

  CX0 := ScrW div 2;
  CY0 := ScrH div 2;
  BuildRowTables;
  BuildSource;

  { Palette entry 1 is the text. 0 stays black for the background. }
  OutB($3C8, 1);
  if UsedColour then
  begin
    OutB($3C9, 63); OutB($3C9, 40); OutB($3C9, 10);
  end
  else
  begin
    OutB($3C9, 63); OutB($3C9, 63); OutB($3C9, 63);
  end;
  TextPair := $0101;

  while (Ticks - StartTick) < RUN_TICKS do
  begin
    Cur := 1 - Cur;
    BuildFrame;
    PaintFrame(TextPair);
    Inc(Frames);
    Angle := (Angle + 3) and 255;
  end;

  Elapsed := Ticks - StartTick;
  SetTextMode(OldMode);

  WriteLn('=== rotating text ===');
  WriteLn('  entry video mode   : ', OldMode);
  if FellBack then
    WriteLn('  video mode         : 13h, 320x200x256 (VBE ', SVGA_MODE,
            ' refused -- this card has too little video memory)')
  else
    WriteLn('  video mode         : VBE ', SVGA_MODE, ', 640x480x256');
  WriteLn('  message            : "', MsgS, '"');
  WriteLn('  source points      : ', NSrc, ' of ', High(SrcU) + 1, ' max');
  if NTrunc > 0 then
    WriteLn('  TRUNCATED          : ', NTrunc, ' points dropped -- message too',
            ' long for the buffer');
  if UsedColour then
    WriteLn('  text colour        : amber')
  else
    WriteLn('  text colour        : white (mono display)');
  if Forced <> '' then
    WriteLn('  colour choice      : forced by argument ', Forced)
  else
    WriteLn('  colour choice      : auto-detected from display code');
  if UseFastBank then
    WriteLn('  bank switching     : direct far call to the VBE window function')
  else
    WriteLn('  bank switching     : INT 10h AX=4F05h (no window function offered)');
  WriteLn('  bank switches      : ', BankSwitches);
  WriteLn('  frames drawn       : ', Frames);
  WriteLn('  pixel pairs drawn  : ', PointsDrawn);
  WriteLn('  clipped off-screen : ', Clipped);
  WriteLn('  final angle        : ', Angle, ' of 256');
  WriteLn('  elapsed ticks      : ', Elapsed, ' (18.2/sec)');
  if Elapsed > 0 then
    WriteLn('  frames per sec x10 : ', (Frames * 182) div Elapsed);
  WriteLn('  video mode restored to ', GetMode);
end.
