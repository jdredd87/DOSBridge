program Serial;
{ DOS Bridge  --  StevenC }
{ RS232 / UART inspection.

  Usage:  SERIAL              probe every COM port the BIOS knows about
          SERIAL /T           also identify the UART type (writes a register)
          SERIAL n /M secs    monitor COM n and dump incoming bytes
          SERIAL n /ID        pulse DTR/RTS and report the mouse ID byte
          ... /X              also mask the owning driver's interrupts,
                              so its handler cannot take the bytes first

  Why this exists: there is no stock way to see how a serial port is currently
  configured. This reads the UART registers back, so you can tell what baud
  rate and framing a driver has set up, whether anything owns the port, and
  which modem control lines are asserted.

  Safety: the default probe is as close to read-only as the hardware allows.
  Reading the divisor needs DLAB set in the LCR, so that one write is bracketed
  by CLI/STI and the LCR is restored immediately -- otherwise an interrupt
  landing in between would find the port in the wrong state. /T is opt-in
  because identifying the UART means writing the scratch and FIFO registers,
  which is not something to do behind a live driver's back.

  MONITOR MODE STEALS DATA. If a driver owns the port -- CTMOUSE does on this
  machine -- bytes this reads are bytes the driver never sees. }

{$MODE OBJFPC}{$H-}
{$ASMMODE INTEL}


uses About;

const
  { UART register offsets from the port base. }
  RBR = 0;    { receive buffer      (DLAB=0, read)  }
  THR = 0;    { transmit holding    (DLAB=0, write) }
  DLL = 0;    { divisor low         (DLAB=1) }
  IER = 1;    { interrupt enable    (DLAB=0) }
  DLM = 1;    { divisor high        (DLAB=1) }
  IIR = 2;    { interrupt ident (read) / FIFO control (write) }
  LCR = 3;    { line control }
  MCR = 4;    { modem control }
  LSR = 5;    { line status }
  MSR = 6;    { modem status }
  SCR = 7;    { scratch }

var
  Base    : array[1..4] of Word;
  NPorts  : Integer;
  DoType  : Boolean;
  Excl    : Boolean;
  DoId    : Boolean;
  IdSecs  : Integer;
  MonPort : Integer;
  MonSecs : Integer;
  I, K    : Integer;
  A       : ShortString;
  Code    : Integer;

const
  HexD: array[0..15] of Char = '0123456789ABCDEF';

function Hex2(B: Byte): ShortString;
begin
  Hex2 := HexD[(B shr 4) and 15] + HexD[B and 15];
end;

function Hex4(W: Word): ShortString;
begin
  Hex4 := Hex2((W shr 8) and $FF) + Hex2(W and $FF);
end;

function InB(P: Word): Byte;
var V: Byte;
begin
  asm
    mov dx, P
    in  al, dx
    mov V, al
  end;
  InB := V;
end;

procedure OutB(P: Word; V: Byte);
begin
  asm
    mov dx, P
    mov al, V
    out dx, al
  end;
end;

procedure Cli; begin asm cli end; end;
procedure Sti; begin asm sti end; end;

function Ticks: LongInt;
begin
  Ticks := MemL[$0040:$006C];
end;

{ Read the baud divisor. DLAB has to be set to see it, so the LCR is saved,
  flipped, read and restored with interrupts off -- an interrupt arriving while
  DLAB is set would read the divisor registers as IER/RBR and misbehave. }
function ReadDivisor(P: Word): Word;
var
  OldLcr: Byte;
  Lo, Hi: Byte;
begin
  Cli;
  OldLcr := InB(P + LCR);
  OutB(P + LCR, OldLcr or $80);
  Lo := InB(P + DLL);
  Hi := InB(P + DLM);
  OutB(P + LCR, OldLcr);
  Sti;
  ReadDivisor := (Word(Hi) shl 8) or Lo;
end;

function BaudOf(Div_: Word): LongInt;
begin
  if Div_ = 0 then BaudOf := 0 else BaudOf := 115200 div Div_;
end;

function FormatOf(L: Byte): ShortString;
var
  R: ShortString;
begin
  case L and 3 of
    0: R := '5';
    1: R := '6';
    2: R := '7';
  else
    R := '8';
  end;
  if (L and 8) = 0 then R := R + 'N'
  else if (L and 16) <> 0 then R := R + 'E'
  else R := R + 'O';
  if (L and 4) <> 0 then R := R + '2' else R := R + '1';
  FormatOf := R;
end;

function BoolToStr(B: Boolean): ShortString;
begin
  if B then BoolToStr := 'ON' else BoolToStr := 'off';
end;

procedure DescribePort(N: Integer; P: Word);
var
  L, M, St, Ms, Ie: Byte;
  D: Word;
begin
  L  := InB(P + LCR);
  M  := InB(P + MCR);
  St := InB(P + LSR);
  Ms := InB(P + MSR);
  Ie := InB(P + IER);
  D  := ReadDivisor(P);

  WriteLn('  COM', N, ' at ', Hex4(P));
  WriteLn('    divisor        : ', D, '  -> ', BaudOf(D), ' baud');
  WriteLn('    format         : ', FormatOf(L), '   (LCR ', Hex2(L), ')');
  WriteLn('    IER            : ', Hex2(Ie),
          '   interrupts ', BoolToStr(Ie <> 0));
  WriteLn('    MCR            : ', Hex2(M),
          '   DTR=', Ord((M and 1) <> 0),
          ' RTS=', Ord((M and 2) <> 0),
          ' OUT2=', Ord((M and 8) <> 0));
  WriteLn('    LSR            : ', Hex2(St),
          '   dataready=', Ord((St and 1) <> 0),
          ' overrun=', Ord((St and 2) <> 0),
          ' thre=', Ord((St and 32) <> 0));
  WriteLn('    MSR            : ', Hex2(Ms),
          '   CTS=', Ord((Ms and 16) <> 0),
          ' DSR=', Ord((Ms and 32) <> 0),
          ' RI=', Ord((Ms and 64) <> 0),
          ' DCD=', Ord((Ms and 128) <> 0));
  if Ie <> 0 then
    WriteLn('    NOTE           : a driver has interrupts enabled on this port');
end;

{ Writing SCR and FCR is how you tell the UART generation apart, but both are
  writes to a port something else may be using -- hence /T rather than default. }
procedure IdentifyUart(P: Word);
var
  OldScr, T, Ident: Byte;
begin
  OldScr := InB(P + SCR);
  OutB(P + SCR, $AA);
  T := InB(P + SCR);
  OutB(P + SCR, OldScr);
  if T <> $AA then
  begin
    WriteLn('    UART           : 8250 (no scratch register)');
    Exit;
  end;

  OutB(P + IIR, $C7);              { try to enable FIFOs }
  Ident := InB(P + IIR);
  OutB(P + IIR, $00);              { and turn them back off }
  case (Ident shr 6) and 3 of
    3: WriteLn('    UART           : 16550A (working FIFO)');
    2: WriteLn('    UART           : 16550 (FIFO present but unusable)');
  else
    WriteLn('    UART           : 16450 / 8250A (no FIFO)');
  end;
end;

{ Monitor with the owning driver's interrupts masked.

  Polling alone loses: CTMOUSE's handler fires the instant a byte lands and has
  already read RBR before a poll loop gets there. Clearing IER stops the UART
  raising the interrupt at all, so the bytes stay in the register for us to
  read. The old IER is restored on the way out; the driver should pick straight
  back up, though a reboot is the sure fix if it does not. }
{ Force a serial mouse to identify itself.

  A Microsoft-compatible serial mouse is powered from DTR and RTS. Dropping
  them and raising them again is a power cycle, and the mouse answers with an
  identification byte: 'M' (4D) for a plain two-button Microsoft mouse, 'M3'
  for a three-button Logitech, 'MZ' for a wheel mouse. This is exactly how a
  driver probes at boot.

  The value of doing it this way is that it needs nobody to touch the mouse --
  unlike watching for movement, a silent result here is real evidence. }
procedure IdentifyMouse(P: Word; Secs: Integer);
var
  OldIer, OldMcr, St, B: Byte;
  T0, Deadline: LongInt;
  Got: Integer;
  Hi6, Hi7: Integer;
  Line, Asc: ShortString;
begin
  OldIer := InB(P + IER);
  OldMcr := InB(P + MCR);
  WriteLn('  mouse identify on ', Hex4(P));
  WriteLn('    saved IER ', Hex2(OldIer), '  MCR ', Hex2(OldMcr));

  OutB(P + IER, 0);                        { silence the owning driver }

  { Drop DTR and RTS: the mouse loses power. }
  OutB(P + MCR, 0);
  T0 := Ticks;
  while (Ticks - T0) < 6 do ;              { about a third of a second }

  { Drain anything stale, then power it back up. }
  while (InB(P + LSR) and 1) <> 0 do B := InB(P + RBR);
  OutB(P + MCR, $0B);                      { DTR + RTS + OUT2 }

  Got := 0; Hi6 := 0; Hi7 := 0;
  Line := ''; Asc := '';
  T0 := Ticks;
  Deadline := T0 + (LongInt(Secs) * 182) div 10;
  while Ticks < Deadline do
  begin
    St := InB(P + LSR);
    if (St and 1) <> 0 then
    begin
      B := InB(P + RBR);
      Inc(Got);
      Line := Line + Hex2(B) + ' ';
      if (B >= 32) and (B < 127) then Asc := Asc + Chr(B) else Asc := Asc + '.';
      { Match the full header shape, not just one bit. Counting every byte
        with bit 6 set is wrong: a negative movement delta like F4 or EB has
        bit 6 set too, so movement data gets miscounted as Microsoft headers
        and a working Mouse Systems mouse is misreported the moment someone
        actually moves it.
          Mouse Systems header: 1000 0xxx  -> (B and F8) = 80
          Microsoft header    : 01xx xxxx  -> (B and C0) = 40 }
      if (B and $F8) = $80 then Inc(Hi7);
      if (B and $C0) = $40 then Inc(Hi6);
    end;
  end;

  OutB(P + MCR, OldMcr);
  OutB(P + IER, OldIer);
  WriteLn('    restored  IER ', Hex2(OldIer), '  MCR ', Hex2(OldMcr));
  WriteLn;

  if Got = 0 then
  begin
    WriteLn('    NO RESPONSE. Nothing is transmitting on this port.');
    WriteLn('    A serial mouse powered by DTR/RTS would answer here.');
  end
  else
  begin
    WriteLn('    bytes: ', Line);
    WriteLn('    ascii: ', Asc);
    { Tell the two serial mouse protocols apart by their sync bit. Microsoft
      frames 3-byte packets with bit 6 set in the header and announces itself
      with an ASCII 'M'. Mouse Systems frames 5-byte packets with bit 7 set and
      bits 2..0 holding the buttons, active low. Getting this wrong is not
      subtle -- a driver expecting the other one sees pure noise. }
    if Pos('M', Asc) > 0 then
      WriteLn('    -> Microsoft-compatible serial mouse (ID byte M)')
    else if (Hi7 > 0) and (Hi7 >= Hi6) then
    begin
      WriteLn('    -> MOUSE SYSTEMS protocol: 5-byte packets, header bit 7 set,');
      WriteLn('       buttons active-low in bits 2..0 (87 = none down).');
      WriteLn('       ', Hi7, ' headers with bit 7, ', Hi6, ' with bit 6.');
      WriteLn('       A driver expecting Microsoft framing will see only noise,');
      WriteLn('       which is why INT 33h reports no movement.');
      WriteLn('       Fix: set the mouse switch to MS, or start CTMOUSE in');
      WriteLn('       Mouse Systems mode.');
    end
    else if Hi6 > 0 then
      WriteLn('    -> Microsoft framing (', Hi6, ' headers with bit 6 set)')
    else
      WriteLn('    -> data present but framing not recognised');
  end;
end;

procedure Monitor(P: Word; Secs: Integer; Exclusive: Boolean);
var
  T0, Deadline: LongInt;
  St, B       : Byte;
  OldIer      : Byte;
  Count       : LongInt;
  Line        : ShortString;
  NL          : Integer;
  Asc         : ShortString;
begin
  WriteLn('  monitoring ', Hex4(P), ' for ', Secs, ' seconds...');
  WriteLn('  (this consumes bytes -- any driver owning the port loses them)');
  WriteLn;
  OldIer := InB(P + IER);
  if Exclusive then
  begin
    WriteLn('  masking the owning driver: IER ', Hex2(OldIer), ' -> 00');
    OutB(P + IER, 0);
  end;

  T0 := Ticks;
  Deadline := T0 + (LongInt(Secs) * 182) div 10;
  Count := 0;
  Line  := '';
  Asc   := '';
  NL    := 0;

  while Ticks < Deadline do
  begin
    St := InB(P + LSR);
    if (St and 1) <> 0 then
    begin
      B := InB(P + RBR);
      Inc(Count);
      Line := Line + Hex2(B) + ' ';
      if (B >= 32) and (B < 127) then Asc := Asc + Chr(B) else Asc := Asc + '.';
      Inc(NL);
      if NL = 16 then
      begin
        WriteLn('    ', Line, ' ', Asc);
        Line := ''; Asc := ''; NL := 0;
      end;
    end;
  end;

  if NL > 0 then WriteLn('    ', Line, '':(16 - NL) * 3 + 1, Asc);

  if Exclusive then
  begin
    OutB(P + IER, OldIer);
    WriteLn;
    WriteLn('  IER restored to  : ', Hex2(OldIer));
  end;

  WriteLn;
  WriteLn('  bytes received   : ', Count);
end;

begin
  DoType  := False;
  Excl    := False;
  DoId    := False;
  IdSecs  := 2;
  MonPort := 0;
  MonSecs := 5;
  for K := 1 to ParamCount do
  begin
    A := ParamStr(K);
    if (A = '/T') or (A = '/t') then DoType := True
    else if (A = '/X') or (A = '/x') then Excl := True
    else if (A = '/ID') or (A = '/id') then DoId := True
    else if (A = '/M') or (A = '/m') then
    begin
      if K < ParamCount then
      begin
        Val(ParamStr(K + 1), MonSecs, Code);
        if (Code <> 0) or (MonSecs < 1) or (MonSecs > 120) then MonSecs := 5;
      end;
      if MonPort = 0 then MonPort := 1;
      IdSecs := MonSecs;
    end
    else
    begin
      Val(A, I, Code);
      if (Code = 0) and (I >= 1) and (I <= 4) then MonPort := I;
    end;
  end;

  WriteLn('=== serial: UART inspection ===');

  { The BIOS data area holds up to four COM base addresses at 0040:0000. }
  NPorts := 0;
  for I := 1 to 4 do
  begin
    Base[I] := MemW[$0040 : Word((I - 1) * 2)];
    if Base[I] <> 0 then Inc(NPorts);
  end;
  WriteLn('  ports in BDA     : ', NPorts);
  WriteLn;

  if NPorts = 0 then
  begin
    WriteLn('  no serial ports reported by the BIOS');
    Halt(1);
  end;

  for I := 1 to 4 do
    if Base[I] <> 0 then
    begin
      DescribePort(I, Base[I]);
      if DoType then IdentifyUart(Base[I]);
      WriteLn;
    end;

  if DoId then
  begin
    if MonPort = 0 then MonPort := 1;
    if Base[MonPort] <> 0 then IdentifyMouse(Base[MonPort], IdSecs);
    Halt(0);
  end;

  if MonPort > 0 then
  begin
    if Base[MonPort] = 0 then
    begin
      WriteLn('  COM', MonPort, ' does not exist');
      Halt(1);
    end;
    Monitor(Base[MonPort], MonSecs, Excl);
  end;
end.
