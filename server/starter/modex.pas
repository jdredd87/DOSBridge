unit ModeX;
{ DOS Bridge  --  StevenC }
{ Unchained 320x200x256 ("mode X"), with a virtual screen wider than the
  display, so scrolling costs two register writes instead of a screenful of
  pixels.

  Why not just mode 13h?  Because on this class of machine you cannot afford
  to redraw.  BENCH measures REP STOSW to video at 439821 words/sec, so one
  64000-byte frame is 73ms -- 13 fps before a single pixel has been *decided*,
  let alone drawn.  Nothing built that way is going to look smooth.

  Mode X moves the work to the CRTC.  The card is told the picture is 1024
  pixels wide while the monitor shows 320 of them, and the visible window is
  moved by writing the Start Address (CRTC 0Ch/0Dh) and the Attribute
  Controller pixel pan (index 13h).  Start address steps four pixels at a
  time, pixel pan supplies the remaining nought-to-three, and between them you
  get one-pixel granularity for the price of five OUTs a frame.

  The other half of the bargain is that solid fills get *cheaper*: with all
  four planes enabled one byte write sets four horizontal pixels, so a span is
  a quarter of the STOSBs mode 13h would need.  What gets dearer is anything
  vertical or unaligned, which has to be done a plane at a time.

  Memory, per plane, at 1024 virtual pixels wide:

      1024 / 4 planes = 256 bytes per row, x 200 rows = 51200 bytes

  which leaves 14336 bytes per plane above the picture for sprite backing
  store, and needs no bank switching -- a whole plane fits inside the 64K
  window at A000.  All four planes together are 204800 of the VGA 262144.

  Everything here is plain 8086.  No 32-bit arithmetic anywhere on a path that
  runs per frame. }

{$MODE OBJFPC}{$H-}
{$ASMMODE INTEL}

interface

uses VGA;

const
  VW    = 1024;             { virtual screen width, pixels }
  VWB   = VW div 4;         { = 256 bytes per plane per row }
  VH    = 200;              { virtual screen height, rows }
  PGSZ  = VWB * VH;         { = 51200 bytes per plane for the picture }

  DISP_W = 320;             { what the monitor actually shows }
  DISP_H = 200;

var
  { Set by Enter, because a VGA driving a mono monitor answers on 3Bx and one
    driving a colour monitor on 3Dx.  Mode 13h forces the colour addresses, so
    in practice these are always 3D4/3DA here -- but reading Misc Output costs
    one IN and removes an assumption, and this box has already proved it will
    boot either way. }
  CrtcBase : Word;
  StatBase : Word;

  { Bumped when a bounded wait gives up rather than spinning forever.  An
    unbounded `repeat until port` is a machine somebody has to walk over to. }
  FlipTimeouts : LongInt;

  { Frames that arrived at ShowAt with the retrace already under way -- i.e.
    the caller overran its budget and this frame will be shown a refresh late.
    This is the only direct evidence of the frame straddling a refresh
    boundary, which is what judder actually is, and it is much more use than
    an average frame rate: 56 fps looks like a healthy number right up until
    you notice it is a mixture of 70 and 35. }
  FlipLate : LongInt;

{ Set mode 13h, then unchain it.  Returns False if the registers did not read
  back the way they were written, in which case the caller should restore text
  mode and say so rather than drawing into a mode that is not there. }
function  Enter: Boolean;

{ Sequencer Map Mask: which of the four planes a CPU write lands in.
  $0F = all four, i.e. one byte write paints four adjacent pixels. }
procedure MapMask(M: Byte);

{ Graphics Controller Read Map Select: which plane a CPU read comes from. }
procedure ReadMap(P: Byte);

{ Graphics Controller write mode.  0 is normal; 1 copies the latches, which is
  how a VRAM-to-VRAM block move shifts four planes per byte. }
procedure WriteMode(M: Byte);

{ Address of a pixel within a plane, and which plane it is in. }
function  PixOfs(X, Y: Word): Word;
function  PixPlane(X: Word): Byte;

{ Horizontal run, all four planes, four pixels per byte written.  Ofs and
  Count are in *addresses*, so Count = pixels div 4 and the run must start on
  a four-pixel boundary.  This is the cheap one. }
procedure HSpan(Ofs, Count: Word; Col: Byte);

{ Vertical run of Count pixels down one plane from Ofs.  The caller sets the
  map mask.  One write per pixel -- there is no string instruction with a
  stride, so this is the dear one and belongs in setup code, not in a frame. }
procedure VRun(Ofs, Count: Word; Col: Byte);

{ Single pixel, map mask set here.  Convenience for scattered detail; never
  use it for anything bulk. }
procedure PlotPix(X, Y: Word; Col: Byte);

{ Read one pixel back out of video memory.  The only way to prove over the
  bridge that a picture exists at all -- nothing drawn to A000 is captured. }
function  PeekPix(X, Y: Word): Byte;

{ VRAM-to-VRAM rectangle move through the latches: one byte moved carries four
  pixels across all four planes at once.  W is in addresses, strides in bytes.
  Sets write mode 1 for the duration and puts it back to 0 afterwards. }
procedure CopyRect(Src, SrcStride, Dst, DstStride, W, H: Word);

{ Show the window whose left edge is at virtual pixel PixX.  Waits for the
  display, sets the start address, waits for the vertical retrace, then sets
  the pixel pan -- that order matters, because the CRTC latches the start
  address at the top of the retrace and the Attribute Controller latches the
  pan at the start of the frame.  Written the other way round the two halves
  land in different frames and the picture jitters by up to three pixels.

  One call per displayed frame, so this is also the frame clock: 70 Hz. }
procedure ShowAt(PixX: Word);

implementation

const
  SC_INDEX = $3C4;   SC_DATA = $3C5;
  GC_INDEX = $3CE;   GC_DATA = $3CF;
  AC_INDEX = $3C0;
  MISC_IN  = $3CC;

procedure MapMask(M: Byte);
begin
  OutB(SC_INDEX, 2);
  OutB(SC_DATA, M);
end;

procedure ReadMap(P: Byte);
begin
  OutB(GC_INDEX, 4);
  OutB(GC_DATA, P);
end;

procedure WriteMode(M: Byte);
var
  V: Byte;
begin
  OutB(GC_INDEX, 5);
  V := InB(GC_DATA);
  OutB(GC_DATA, (V and $FC) or (M and 3));
end;

procedure CrtcW(Idx, Val: Byte);
begin
  OutB(CrtcBase, Idx);
  OutB(CrtcBase + 1, Val);
end;

function CrtcR(Idx: Byte): Byte;
begin
  OutB(CrtcBase, Idx);
  CrtcR := InB(CrtcBase + 1);
end;

procedure HSpan(Ofs, Count: Word; Col: Byte); assembler;
asm
  push es
  push di
  mov  ax, VGA_SEG
  mov  es, ax
  mov  di, Ofs
  mov  cx, Count
  mov  al, Col
  cld
  rep  stosb
  pop  di
  pop  es
end;

procedure VRun(Ofs, Count: Word; Col: Byte); assembler;
asm
  push es
  push di
  push bx
  mov  cx, Count
  jcxz @@done
  mov  ax, VGA_SEG
  mov  es, ax
  mov  di, Ofs
  mov  al, Col
  mov  bx, VWB
@@l:
  mov  es:[di], al
  add  di, bx
  loop @@l
@@done:
  pop  bx
  pop  di
  pop  es
end;

function Enter: Boolean;
var
  Ok: Boolean;
begin
  SetMode(MODE13);

  { Mode 13h always selects the colour I/O addresses, but ask rather than
    assume: bit 0 of Misc Output is the I/O Address Select. }
  if (InB(MISC_IN) and 1) <> 0 then
  begin
    CrtcBase := $3D4;
    StatBase := $3DA;
  end
  else
  begin
    CrtcBase := $3B4;
    StatBase := $3BA;
  end;

  { Sequencer Memory Mode: keep Extended Memory (bit 1) and sequential host
    addressing (bit 2), drop Chain-4 (bit 3).  Mode 13h leaves this at $0E. }
  OutB(SC_INDEX, 4);
  OutB(SC_DATA, $06);

  { With the chain broken the four planes still hold whatever mode 13h wrote
    into them, which is a quarter of the old picture repeated four times.
    Clear it before anyone sees it. }
  MapMask($0F);
  HSpan(0, PGSZ, 0);

  { CRTC Underline Location: clear the doubleword bit (6).  Mode 13h sets it,
    and left set the address counter advances four times too slowly. }
  CrtcW($14, CrtcR($14) and $BF);

  { CRTC Mode Control: set byte mode (bit 6).  Mode 13h uses doubleword. }
  CrtcW($17, CrtcR($17) or $40);

  { Offset: how far the address counter advances per scan line, in units of
    two addresses.  A 1024-pixel row is 256 addresses, so 128. }
  CrtcW($13, VW div 8);

  { Read it all back.  A card that quietly ignored one of these leaves a
    picture that is skewed rather than absent, which is a confusing way to
    spend an afternoon; better to refuse up front. }
  OutB(SC_INDEX, 4);
  Ok := (InB(SC_DATA) and $08) = 0;
  Ok := Ok and ((CrtcR($14) and $40) = 0);
  Ok := Ok and ((CrtcR($17) and $40) <> 0);
  Ok := Ok and (CrtcR($13) = VW div 8);

  Enter := Ok;
end;

function PixOfs(X, Y: Word): Word;
begin
  PixOfs := Y * VWB + (X shr 2);
end;

function PixPlane(X: Word): Byte;
begin
  PixPlane := X and 3;
end;

procedure PlotPix(X, Y: Word; Col: Byte);
begin
  MapMask(1 shl (X and 3));
  Mem[VGA_SEG : Y * VWB + (X shr 2)] := Col;
end;

function PeekPix(X, Y: Word): Byte;
begin
  ReadMap(X and 3);
  PeekPix := Mem[VGA_SEG : Y * VWB + (X shr 2)];
end;

procedure CopyRectRaw(Src, SrcStride, Dst, DstStride, W, H: Word); assembler;
asm
  push ds
  push es
  push si
  push di
  push bx
  mov  ax, VGA_SEG
  mov  es, ax
  mov  ds, ax
  mov  si, Src
  mov  di, Dst
  mov  dx, H
  { REP MOVSB leaves SI and DI W bytes further on, so the step to the next row
    is stride-minus-W and the row start never has to be saved.  Four stack
    operations a row is about 50 cycles on an 8086, which at 144 rows a frame
    was costing most of a millisecond -- and a millisecond is the difference
    between two vertical refreshes and three.  BP-relative operands are
    SS-relative, so the parameters are still reachable with DS pointing at
    video memory. }
  mov  bx, SrcStride
  sub  bx, W
  mov  ax, DstStride
  sub  ax, W
  cld
@@row:
  mov  cx, W
  rep  movsb
  add  si, bx
  add  di, ax
  dec  dx
  jnz  @@row
  pop  bx
  pop  di
  pop  si
  pop  es
  pop  ds
end;

procedure CopyRect(Src, SrcStride, Dst, DstStride, W, H: Word);
begin
  MapMask($0F);
  WriteMode(1);
  CopyRectRaw(Src, SrcStride, Dst, DstStride, W, H);
  WriteMode(0);
end;

procedure ShowAt(PixX: Word);
var
  Addr  : Word;
  Guard : Word;
begin
  Addr := PixX shr 2;

  if (InB(StatBase) and 8) <> 0 then Inc(FlipLate);

  { Wait for active display, so both halves of the start address are written
    well before the retrace latches them and the picture cannot be shown with
    one byte old and one byte new. }
  Guard := 0;
  while ((InB(StatBase) and 1) <> 0) and (Guard < 60000) do Inc(Guard);
  if Guard >= 60000 then Inc(FlipTimeouts);

  CrtcW($0C, Hi(Addr));
  CrtcW($0D, Lo(Addr));

  { Now the retrace itself.  This is what paces the whole demo at 70 Hz. }
  Guard := 0;
  while ((InB(StatBase) and 8) = 0) and (Guard < 60000) do Inc(Guard);
  if Guard >= 60000 then Inc(FlipTimeouts);

  { Pixel pan, 0..3 pixels.  In a 256-colour mode the Attribute Controller
    counts in half-pixels, hence the shift.  Bit 5 of the index keeps the
    palette addressable -- drop it and the screen goes black. }
  InB(StatBase);                       { reset the AC index/data flip-flop }
  OutB(AC_INDEX, $13 or $20);
  OutB(AC_INDEX, (PixX and 3) shl 1);
end;

begin
  CrtcBase := $3D4;
  StatBase := $3DA;
  FlipTimeouts := 0;
  FlipLate := 0;
end.
