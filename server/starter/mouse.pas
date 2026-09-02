program MouseTest;
{ DOS Bridge  --  StevenC }
{ Exercise the mouse through the INT 33h driver API.

  Usage:  MOUSE [seconds]        default 10

  Why this API and not the serial port: CTMOUSE is resident on this machine and
  owns COM1, including its interrupt. Reading the UART directly would take bytes
  out of the driver's mouth and desynchronise it. INT 33h is the supported way
  in, and it works the same whether the mouse is serial, bus or PS/2.

  Move the mouse and click while this runs. It reports the range of travel and
  every button transition, so the result is checkable from the far end of the
  bridge without anyone watching the screen. }

{$MODE OBJFPC}{$H-}
{$ASMMODE INTEL}


uses About;

var
  RAX, RBX, RCX, RDX : Word;

  Secs      : Integer;
  Code      : Integer;
  Installed : Boolean;
  Buttons   : Word;
  X, Y      : Integer;
  Btn       : Word;
  PrevBtn   : Word;
  MinX, MaxX: Integer;
  MinY, MaxY: Integer;
  Moves     : LongInt;
  Presses   : LongInt;
  Releases  : LongInt;
  PrevX     : Integer;
  PrevY     : Integer;
  T0, Dl    : LongInt;
  First     : Boolean;
  MickX     : Integer;
  MickY     : Integer;
  TotMickX  : LongInt;
  TotMickY  : LongInt;

function Ticks: LongInt;
begin
  Ticks := MemL[$0040:$006C];
end;

{ AX=0000: reset driver and get status. AX comes back FFFF if a driver is
  there, and BX holds the button count. }
procedure MouseReset;
begin
  asm
    mov ax, 0
    int 33h
    mov RAX, ax
    mov RBX, bx
  end;
end;

{ AX=0003: current position in CX/DX and button bitmask in BX. }
procedure MouseStatus;
begin
  asm
    mov ax, 3
    int 33h
    mov RBX, bx
    mov RCX, cx
    mov RDX, dx
  end;
end;

{ AX=000B: motion counters since the last call, in mickeys. Reading them
  clears them, so this measures raw movement even if the pointer is clamped
  against the edge of its range. }
procedure MouseMotion;
begin
  asm
    mov ax, 0Bh
    int 33h
    mov RCX, cx
    mov RDX, dx
  end;
end;

function SignedW(W: Word): Integer;
begin
  if W > 32767 then SignedW := Integer(W - 65536) else SignedW := Integer(W);
end;

begin
  Secs := 10;
  if ParamCount >= 1 then
  begin
    Val(ParamStr(1), Secs, Code);
    if (Code <> 0) or (Secs < 1) or (Secs > 120) then Secs := 10;
  end;

  WriteLn('=== mouse: INT 33h driver test ===');

  MouseReset;
  Installed := RAX = $FFFF;
  Buttons   := RBX;

  if not Installed then
  begin
    WriteLn('  driver           : NOT PRESENT (INT 33h returned ', RAX, ')');
    WriteLn('  Nothing to test. CTMOUSE or equivalent must be loaded.');
    Halt(1);
  end;

  WriteLn('  driver           : present');
  WriteLn('  buttons reported : ', Buttons);
  WriteLn('  sampling for     : ', Secs, ' seconds -- move the mouse now');
  WriteLn;

  MinX := 32767; MaxX := -32768;
  MinY := 32767; MaxY := -32768;
  Moves := 0; Presses := 0; Releases := 0;
  TotMickX := 0; TotMickY := 0;
  First := True;
  PrevBtn := 0;
  PrevX := 0; PrevY := 0;

  T0 := Ticks;
  Dl := T0 + (LongInt(Secs) * 182) div 10;

  while Ticks < Dl do
  begin
    MouseStatus;
    Btn := RBX;
    X   := Integer(RCX);
    Y   := Integer(RDX);

    MouseMotion;
    MickX := SignedW(RCX);
    MickY := SignedW(RDX);
    if MickX < 0 then Inc(TotMickX, -MickX) else Inc(TotMickX, MickX);
    if MickY < 0 then Inc(TotMickY, -MickY) else Inc(TotMickY, MickY);

    if X < MinX then MinX := X;
    if X > MaxX then MaxX := X;
    if Y < MinY then MinY := Y;
    if Y > MaxY then MaxY := Y;

    if First then
    begin
      First := False;
      PrevX := X; PrevY := Y; PrevBtn := Btn;
    end
    else
    begin
      if (X <> PrevX) or (Y <> PrevY) then
      begin
        Inc(Moves);
        PrevX := X; PrevY := Y;
      end;
      if Btn <> PrevBtn then
      begin
        { A bit that turned on is a press, a bit that turned off a release. }
        if (Btn and (not PrevBtn)) <> 0 then Inc(Presses);
        if (PrevBtn and (not Btn)) <> 0 then Inc(Releases);
        PrevBtn := Btn;
      end;
    end;
  end;

  WriteLn('  position changes : ', Moves);
  WriteLn('  X range          : ', MinX, ' .. ', MaxX);
  WriteLn('  Y range          : ', MinY, ' .. ', MaxY);
  WriteLn('  travel (mickeys) : X ', TotMickX, '   Y ', TotMickY);
  WriteLn('  button presses   : ', Presses);
  WriteLn('  button releases  : ', Releases);
  WriteLn('  final buttons    : ', Btn);
  WriteLn;
  if (Moves = 0) and (TotMickX = 0) and (TotMickY = 0) and (Presses = 0) then
    WriteLn('  VERDICT          : no activity seen (idle, unplugged, or no mouse)')
  else
    WriteLn('  VERDICT          : mouse is alive and reporting');
end.
