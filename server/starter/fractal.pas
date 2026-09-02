program Fractal;
{ DOS Bridge  --  StevenC }
{ Mandelbrot set in VGA mode 13h for ten seconds, then quit.

  The mode 13h plumbing lives in the VGA unit. What is left here is the maths.

  Colour only. The greyscale path this used to carry was dropped deliberately:
  if the card has booted mono, run HWINFO (or VIDCHK) and reboot rather than
  having every demo carry two palettes. Note a colour ramp is NOT automatically
  safe on a mono display -- the monitor sums R+G+B, and two different colours
  can land on the same grey -- so this will look muddy on a mono boot rather
  than merely desaturated.

  Usage:  FRACTAL              use the 8087 if there is one, else Q8 integer
          FRACTAL INT          force the integer path even with a coprocessor
          FRACTAL FPU          force the 8087 path (refuses if none is fitted)
          FRACTAL ZOOM 500     zoom 500x into the Feigenbaum point, needs an 8087
          FRACTAL ZOOM 500 SECS 40   ...and give it forty seconds to draw

  TWO INNER LOOPS, ONE PICTURE

  The Q8 fixed-point loop is the baseline and is never removed: this suite
  targets machines that may have no coprocessor at all, and x87 arithmetic
  carries WAIT prefixes that hang hard when nothing answers. Everything x87
  below is behind `if UseFpu`, and UseFpu can only be true when Cpu.HasFpu is.

  Which is faster? Neither, near enough -- measured 61661 8087 multiplies/sec
  against 60660 16-bit integer ones. The 8087 is 5-6x faster than 32-bit
  LongInt software arithmetic, but this loop was rewritten years ago to avoid
  exactly that, so there is nothing left for it to win back.

  What the 8087 does buy is PRECISION, and that is the point of the ZOOM
  argument. Q8 resolves 1/256 of a unit, so past about 100x the window is
  narrower than one fixed-point step and the picture collapses into flat
  blocks. Double precision has ~15 significant digits and keeps going long past
  anything you would wait for on an 8 MHz machine.

  Note the Pascal below never does floating point arithmetic itself. FPC
  compiles Double operations to *software* routines for this target unless the
  whole program is built -Cfx87, which would make the binary refuse to run on a
  machine without a coprocessor. So the x87 work is hand-written asm and the
  Doubles are only ever storage.

  Notes for the 8086-class baseline this targets:

  * Q8 fixed point (SCALE=256), with no 32-bit registers to fall back on.
    Signed division is `div`, never `shr` -- `shr` rounds the wrong way for
    negatives and warps the left half of the set.
  * It reports what it did with WriteLn. Direct writes to A000 never make it
    back over the bridge, so a program that only draws returns an empty log.
    Run VSHOT in the same job if you want to see the picture. }

{$MODE OBJFPC}{$H-}
{$ASMMODE INTEL}

uses VGA, Cpu, About;

const
  SCALE     = 256;         { Q8 -- see MulQ8 for why 8 and not 10 }
  MAXITER   = 16;
  RUN_TICKS = 182;         { BIOS ticks at 18.2 Hz, so about ten seconds }
  MAX_TICKS = 1092;        { SECS caps at 60 }
  CELL      = 2;           { compute one point per CELL*CELL block }

  { Window on the complex plane, pre-multiplied into Q8. }
  X_MIN = -563;            { -2.2 }
  X_MAX =  205;            {  0.8 }
  Y_MIN = -307;            { -1.2 }
  Y_MAX =  307;            {  1.2 }

  { One DAC entry per escape band, running deep blue -> violet -> red -> orange
    -> yellow -> white as points take longer to escape. MAXITER is 16, so there
    are only 16 distinct escape times and 16 colours loses nothing. Entry 0 is
    left black for points inside the set. }
  BANDS = 16;
  Palette: array[1..BANDS, 0..2] of Byte = (
    ( 0,  0, 20),   ( 0,  0, 32),   ( 4,  0, 44),   (12,  0, 52),
    (24,  0, 56),   (36,  0, 52),   (48,  0, 40),   (56,  4, 24),
    (63, 16,  8),   (63, 28,  0),   (63, 40,  0),   (63, 52,  4),
    (63, 60, 16),   (63, 63, 32),   (63, 63, 48),   (63, 63, 63));

{ --- the 8087 path ------------------------------------------------------

  All storage, no Pascal arithmetic. Every value below is read and written by
  the asm blocks; Pascal only ever copies whole Doubles around, which compiles
  to a memory move rather than a soft-float call. }
const
  F_ZERO   : Double = 0.0;
  F_TWO    : Double = 2.0;
  F_FOUR   : Double = 4.0;
  F_HALFW  : Double = 1.5;      { half-width of the unzoomed window }
  F_HALFH  : Double = 1.2;
  { Two windows, and they differ in more than magnification.

    At 1x the centre is the cusp at -0.75 on the real axis, which gives the
    familiar whole-set view and lets Render mirror the top half into the
    bottom -- exact, because the set is symmetric about the real axis.

    Zooming wants somewhere else entirely. Every point on the real axis is
    either solidly inside the set or solidly outside it, so magnifying one just
    fills the screen with a single colour: tried the cusp and the Feigenbaum
    point, and both rendered flat black at 200-400x. The interesting structure
    is on the boundary, and the boundary is off-axis -- so zoomed runs use
    seahorse valley and give up the mirror, drawing all 200 rows. Twice the
    work for a picture that is actually worth looking at. }
  F_CX0    : Double = -0.75;             { 1x: the cusp, whole-set view }
  F_CY0    : Double =  0.0;              { on-axis, so the mirror is exact }
  F_CX0Z   : Double = -0.743643887;      { zoomed: seahorse valley }
  F_CY0Z   : Double =  0.131825904;      { off-axis, so no mirror }
  F_SCRW   : Double = 320.0;
  F_SCRH   : Double = 200.0;

var
  FCx, FCy      : Double;       { the point being iterated }
  FZx, FZy      : Double;
  FZx2, FZy2    : Double;
  FTmp          : Double;
  FXMin, FYMin  : Double;
  FXStep, FYStep: Double;
  FHw, FHh      : Double;
  FZoomD        : Double;
  FCentre       : Double;
  FCentreY      : Double;
  RowLimit      : Integer;      { SCR_H div 2 when mirroring, else SCR_H }
  DoMirror      : Boolean;
  FSw           : Word;
  FPxI, FPyI    : Integer;      { FILD sources, hence Integer and not Word }
  FZoomI        : Integer;
  ItG           : Integer;
  MaxIt         : Integer;
  UseFpu        : Boolean;
  Zoom          : LongInt;
  Budget        : LongInt;      { render time limit in BIOS ticks }

var
  OldMode         : Byte;
  StartTick, Now_ : LongInt;
  Elapsed         : LongInt;
  RowsDone, InSet : Integer;
  Checksum        : LongInt;
  Completed       : Boolean;

{ (A*B) >> 8, signed, in one IMUL.

  This is why SCALE is 256 rather than 1024. IMUL leaves the 32-bit product in
  DX:AX, and a >>8 of that is just a byte shuffle -- AL takes AH, AH takes DL --
  where >>10 would need a ten-round shift loop. Products here peak around 2^18,
  well inside the 2^23 this stays exact for.

  The Pascal it replaces, `Integer((LongInt(zx) * zx) div SCALE)`, called FPC's
  software 32-bit multiply and divide on every iteration. That was the whole
  bottleneck: it managed 58 of 200 rows in ten seconds. }
function MulQ8(A, B: Integer): Integer; assembler;
asm
  mov ax, A
  imul word ptr B
  mov al, ah
  mov ah, dl
end;

{ Window geometry, computed once. Centre is fixed at (-0.75, 0): the y must
  stay zero because Render mirrors the top half into the bottom, and that is
  only exact when the window is symmetric about the real axis. }
procedure SetupFpuWindow;
begin
  FZoomI := Integer(Zoom);
  if Zoom > 1 then
  begin
    FCentre  := F_CX0Z;
    FCentreY := F_CY0Z;
  end
  else
  begin
    FCentre  := F_CX0;
    FCentreY := F_CY0;
  end;
  asm
    fild FZoomI
    fstp FZoomD

    fld  F_HALFW
    fdiv FZoomD
    fstp FHw
    fld  F_HALFH
    fdiv FZoomD
    fstp FHh

    fld  FCentre
    fsub FHw
    fstp FXMin
    fld  FHw
    fmul F_TWO
    fdiv F_SCRW
    fstp FXStep

    fld  FCentreY
    fsub FHh
    fstp FYMin
    fld  FHh
    fmul F_TWO
    fdiv F_SCRH
    fstp FYStep
  end;
end;

{ c for one pixel. FILD converts the 16-bit pixel index on the coprocessor, so
  no integer-to-float conversion happens in Pascal. }
procedure SetC(Px, Py: Integer);
begin
  FPxI := Px;
  FPyI := Py;
  asm
    fild FPxI
    fmul FXStep
    fadd FXMin
    fstp FCx

    fild FPyI
    fmul FYStep
    fadd FYMin
    fstp FCy
  end;
end;

{ The Mandelbrot iteration on the 8087, leaving the escape count in ItG.

  Values live in memory rather than on the coprocessor stack. Keeping zx/zy in
  st(n) across a loop would save the loads, but the 8087 has eight registers
  and a stack that is easy to leave unbalanced on an early exit -- and this is
  not the bottleneck, so the simple version wins.

  Instructions here are the ordinary WAIT-prefixed forms, which is correct:
  each waits for the coprocessor to go idle before issuing, so back-to-back
  operations synchronise properly. That is the opposite of the detection code
  in cpu.pas, which must use the FN (no-wait) forms precisely because it cannot
  assume anything is out there to answer -- and which lost a store by issuing
  two of them adjacently. Here a coprocessor is known present. }
procedure IterFpu;
begin
  asm
    fld  F_ZERO
    fstp FZx
    fld  F_ZERO
    fstp FZy
    mov  word ptr ItG, 0

  @@lp:
    mov  ax, ItG
    cmp  ax, MaxIt
    jge  @@fin

    fld  FZx
    fmul FZx
    fstp FZx2

    fld  FZy
    fmul FZy
    fstp FZy2

    { escape test: zx2 + zy2 > 4 }
    fld  FZx2
    fadd FZy2
    fcomp F_FOUR
    fstsw FSw
    fwait                    { the store must land before the CPU reads it }
    mov  ax, FSw
    and  ax, 4100h           { C3 (bit 14) and C0 (bit 8) }
    jz   @@fin               { both clear means st(0) > 4 -- escaped }

    { zy := 2*zx*zy + cy   -- computed before zx is overwritten }
    fld  FZx
    fmul FZy
    fmul F_TWO
    fadd FCy
    fstp FTmp

    { zx := zx2 - zy2 + cx }
    fld  FZx2
    fsub FZy2
    fadd FCx
    fstp FZx

    fld  FTmp
    fstp FZy

    inc  word ptr ItG
    jmp  @@lp

  @@fin:
  end;
end;

procedure LoadFractalPalette;
var
  I: Integer;
begin
  DacSeek(0);
  DacGrey(0);                        { index 0 = black, the set itself }
  for I := 1 to BANDS do
    DacRGB(Palette[I, 0], Palette[I, 1], Palette[I, 2]);
end;

procedure Render;
var
  Px, Py, Dy       : Integer;
  MirY             : Integer;
  cx, cy           : Integer;
  zx, zy, zx2, zy2 : Integer;
  It               : Integer;
  Col              : Byte;
  ColPair          : Word;
begin
  RowsDone := 0;
  InSet    := 0;
  Checksum := 0;
  Completed := False;

  Py := 0;
  while Py < RowLimit do
  begin
    cy := Y_MIN + Integer((LongInt(Py) * (Y_MAX - Y_MIN)) div SCR_H);

    Px := 0;
    while Px < SCR_W do
    begin
      cx := X_MIN + Integer((LongInt(Px) * (X_MAX - X_MIN)) div SCR_W);

      if UseFpu then
      begin
        SetC(Px, Py);
        IterFpu;
        It := ItG;
        { More iterations than palette bands once zoomed, so escape times are
          scaled into the 15 non-black entries rather than used directly. }
        if It >= MaxIt then
        begin
          Col := 0;
          Inc(InSet, 2);
        end
        else
          Col := Byte(1 + (LongInt(It) * (BANDS - 1)) div MaxIt);
        Checksum := Checksum + Col;
        ColPair := Word(Col) or (Word(Col) shl 8);
        for Dy := 0 to CELL - 1 do
          if (Py + Dy) < SCR_H then
          begin
            MemW[VGA_SEG : Word(Py + Dy) * SCR_W + Word(Px)] := ColPair;
            if DoMirror then
            begin
              MirY := SCR_H - 1 - (Py + Dy);
              MemW[VGA_SEG : Word(MirY) * SCR_W + Word(Px)] := ColPair;
            end;
          end;
        Px := Px + CELL;
        Continue;
      end;

      zx := 0; zy := 0; It := 0;
      while It < MAXITER do
      begin
        zx2 := MulQ8(zx, zx);
        zy2 := MulQ8(zy, zy);
        { Escape test without 32-bit arithmetic. `zx2 + zy2 > 4*SCALE` would
          be the obvious form, but after an escaping update the sum can reach
          ~48000 and overflow a 16-bit Integer -- which is why this started out
          as a LongInt add on every single iteration. Moving zy2 to the other
          side keeps both sides in range (zx2 <= 26632, and 4*SCALE - zy2 is at
          worst about -25600) and makes the test pure 16-bit. }
        if zx2 > (4 * SCALE - zy2) then Break;
        zy := MulQ8(zx, zy) * 2 + cy;                 { 2*zx*zy/SCALE }
        zx := zx2 - zy2 + cx;
        Inc(It);
      end;

      if It >= MAXITER then
      begin
        Col := 0;                      { inside the set: black }
        Inc(InSet, 2);                 { counted for both halves }
      end
      else
        Col := Byte(It + 1);           { outside: one palette band per escape time }

      Checksum := Checksum + Col;

      { The block is CELL pixels wide in one colour, and Px advances by CELL,
        so each row of it is one aligned 16-bit store rather than two byte
        stores. Eight far byte-writes per point become four word-writes, which
        is what finally fits the whole picture inside the ten seconds.
        This specialisation assumes CELL = 2. }
      ColPair := Word(Col) or (Word(Col) shl 8);

      for Dy := 0 to CELL - 1 do
      begin
        if (Py + Dy) < SCR_H then
        begin
          MemW[VGA_SEG : Word(Py + Dy) * SCR_W + Word(Px)] := ColPair;

          { Mirror into the bottom half. c and conj(c) escape at the same rate
            and the window is symmetric about the real axis, so this is an
            exact halving of the work, not an approximation. }
          MirY := SCR_H - 1 - (Py + Dy);
          MemW[VGA_SEG : Word(MirY) * SCR_W + Word(Px)] := ColPair;
        end;
      end;

      Px := Px + CELL;
    end;

    if DoMirror then
      RowsDone := (Py + CELL) * 2    { top half plus its mirror }
    else
      RowsDone := Py + CELL;
    Py := Py + CELL;

    { Give up on the rest of the picture rather than overrun the ten seconds. }
    if (Ticks - StartTick) >= Budget then Exit;
  end;

  Completed := True;
end;

var
  I    : Integer;
  Arg  : ShortString;
  Code : Integer;
  Want : Integer;      { 0 = auto, 1 = force FPU, 2 = force integer }

begin
  Want := 0;
  Zoom := 1;
  Budget := RUN_TICKS;
  I := 1;
  while I <= ParamCount do
  begin
    Arg := ParamStr(I);
    for Code := 1 to Length(Arg) do
      if (Arg[Code] >= 'a') and (Arg[Code] <= 'z') then
        Arg[Code] := Chr(Ord(Arg[Code]) - 32);
    if Arg = 'FPU' then Want := 1
    else if Arg = 'INT' then Want := 2
    else if Arg = 'SECS' then
    begin
      Inc(I);
      if I <= ParamCount then
      begin
        Val(ParamStr(I), Budget, Code);
        if (Code <> 0) or (Budget < 1) then Budget := 10;
        if Budget > 60 then Budget := 60;
        Budget := (Budget * 182) div 10;
      end;
    end
    else if Arg = 'ZOOM' then
    begin
      Inc(I);
      if I <= ParamCount then
      begin
        Val(ParamStr(I), Zoom, Code);
        if (Code <> 0) or (Zoom < 1) then Zoom := 1;
        if Zoom > 1000000 then Zoom := 1000000;
      end;
    end;
    Inc(I);
  end;

  UseFpu := HasFpu and (Want <> 2);
  if (Want = 1) and (not HasFpu) then
  begin
    WriteLn('=== mandelbrot, VGA mode 13h ===');
    WriteLn('  FPU was asked for and there is no coprocessor fitted.');
    WriteLn('  Refusing: x87 arithmetic carries WAIT prefixes, and WAIT with');
    WriteLn('  nothing answering hangs the machine until someone resets it.');
    Halt(1);
  end;
  if (Zoom > 1) and (not UseFpu) then
  begin
    { Q8 resolves 1/256, so a window narrower than that is all one value. }
    WriteLn('=== mandelbrot, VGA mode 13h ===');
    WriteLn('  ZOOM needs the 8087 -- Q8 fixed point cannot resolve it.');
    Halt(1);
  end;

  MaxIt := MAXITER;
  RowLimit := SCR_H div 2;
  DoMirror := True;
  if UseFpu and (Zoom > 1) then
  begin
    { Seahorse valley is off the real axis, so there is no symmetry to exploit
      and every row has to be computed. }
    RowLimit := SCR_H;
    DoMirror := False;
  end;
  if UseFpu then
  begin
    { Zooming needs more iterations to resolve anything, but every extra one
      costs a full pass of the inner loop and this machine has ten seconds.
      These are the largest values that still put a picture on the screen. }
    if Zoom >= 1000 then MaxIt := 64
    else if Zoom > 1 then MaxIt := 32;
    SetupFpuWindow;
  end;

  OldMode := GetMode;
  StartTick := Ticks;

  SetMode(MODE13);
  LoadFractalPalette;
  Render;

  { If it finished early, hold the picture up for the rest of the budget. }
  repeat
    Now_ := Ticks;
  until (Now_ - StartTick) >= Budget;

  Elapsed := Ticks - StartTick;
  SetMode(OldMode);

  WriteLn('=== mandelbrot, VGA mode 13h ===');
  WriteLn('  entry video mode   : ', OldMode);
  WriteLn('  resolution         : 320x200, 1 point per ', CELL, 'x', CELL, ' block');
  if UseFpu then
    WriteLn('  inner loop         : Intel 8087, double precision')
  else
    WriteLn('  inner loop         : Q8 fixed point, 16-bit integer');
  if Zoom > 1 then
    WriteLn('  zoom               : ', Zoom, 'x  at seahorse valley '
            + '(-0.743643887, 0.131825904)')
  else
    WriteLn('  zoom               : 1x  (whole set, centre -0.75, 0)');
  if DoMirror then
    WriteLn('  symmetry           : top half computed, bottom mirrored')
  else
    WriteLn('  symmetry           : none -- off-axis window, all rows computed');
  WriteLn('  max iterations     : ', MaxIt);
  WriteLn('  palette            : ', BANDS, ' colour bands + black interior');
  if Completed then
    WriteLn('  render             : COMPLETE')
  else
    WriteLn('  render             : cut off by the ',
            (Budget * 10) div 182, 's limit');
  WriteLn('  rows drawn         : ', RowsDone, ' of ', SCR_H);
  WriteLn('  points inside set  : ', InSet);
  WriteLn('  colour checksum    : ', Checksum);
  WriteLn('  elapsed ticks      : ', Elapsed, ' (18.2/sec)');
  WriteLn('  video mode restored to ', GetMode);
end.
