program PktDrv;
{ DOS Bridge  --  StevenC }
{ Find and describe the packet driver -- the layer everything else on this
  machine's network sits on top of.

  Usage:  PKTDRV            scan 60h..80h and report what is there
          PKTDRV 60         look only at INT 60h  -- the argument is HEX,
                            because packet driver vectors are only ever
                            spoken about in hex

  Exit code: number of packet drivers found (0 means none).

  WHY THIS, AND WHY IT DOES SO LITTLE

  FPC has no TCP/IP stack for -Tmsdos. There is no Sockets unit, no
  gethostbyname, nothing. What DOS gives you instead is the Packet Driver
  Specification: a small, well-documented interrupt API that a resident driver
  publishes on one vector between 60h and 80h. mTCP is built on it. Anything we
  write in Pascal that speaks the network will be too.

  So this is step one and deliberately stops there. It uses exactly one call --
  driver_info, AH=1Fh -- which takes no handle, registers nothing, allocates
  nothing and cannot change the driver's state.

  THE HAZARD THAT COMES NEXT

  The bridge itself runs over this driver. The moment a program calls
  access_type (AH=02h) it hands the driver a far pointer to its own receive
  routine, which the driver then calls at interrupt time for every matching
  packet. Exit without release_type (AH=03h) and that pointer dangles into
  memory DOS has since handed to something else -- the next matching packet
  jumps into it. On this machine the result is a box with no network, which is
  exactly the failure that needs someone physically at the keyboard.

  That is worth doing, but it wants its own program with its own careful exit
  path, not a flag bolted onto a probe. Nothing here registers a handle. }

{$MODE OBJFPC}{$H-}
{$ASMMODE INTEL}

uses Dos, About;

type
  TFarPtr = packed record
    O, S: Word;
  end;

var
  Handler  : TFarPtr;      { the vector we are about to call, as ofs:seg }
  NameSeg  : Word;
  NameOfs  : Word;
  RAX, RBX : Word;
  RCX, RDX : Word;
  CarryB   : Byte;
  Found    : Integer;
  Only     : LongInt;

const
  HexD: array[0..15] of Char = '0123456789ABCDEF';

function Hex2(B: Byte): ShortString;
begin
  Hex2 := HexD[(B shr 4) and 15] + HexD[B and 15];
end;

function Num(L: LongInt): ShortString;
var
  S: ShortString;
begin
  Str(L, S);
  Num := S;
end;

{ The spec puts the eight bytes 'PKT DRVR' at offset 3 of the handler: the
  entry point begins with a three-byte jump and the signature sits right
  behind it. That is the whole discovery mechanism -- there is no registry and
  no fixed vector, only a convention that the driver was loaded somewhere in
  60h..80h and left its name in memory. }
function HasSignature(Sg, Of_: Word): Boolean;
const
  Sig = 'PKT DRVR';
var
  I: Integer;
begin
  HasSignature := False;
  if Sg = 0 then Exit;
  for I := 1 to 8 do
    if Chr(Mem[Sg : Word(Of_ + 2 + I)]) <> Sig[I] then Exit;
  HasSignature := True;
end;

{ INT with a number that is not known until run time. The opcode takes an
  immediate, so instead we read the vector out of the table ourselves and
  simulate the call: PUSHF then a far CALL leaves the stack looking exactly as
  INT would have left it, and the driver's IRET unwinds it correctly.

  Register handling is the fiddly part. The call returns with DS pointing at
  the driver's own segment, so until DS is put back, every global here is
  unreachable -- storing a result would write into the driver. The sequence
  below moves what it needs into registers first, restores DS, and only then
  writes. MOV does not touch the flags, so the carry the driver returned is
  still valid by the time it is tested. }
procedure CallDriverInfo;
begin
  asm
    push ds
    push si
    push di
    mov  ax, 01FFh          { AH=1Fh driver_info, AL=FFh for the no-handle form }
    pushf
    call far [Handler]
    mov  di, si             { name offset, before DS goes away }
    mov  si, ds             { name segment }
    pop  ax                 { discard the pushed di -- ax is reloaded below }
    pop  ax
    pop  ds                 { our data segment back }
    mov  NameOfs, di
    mov  NameSeg, si
    jnc  @@ok
    mov  CarryB, 1
    jmp  @@fin
  @@ok:
    mov  CarryB, 0
  @@fin:
  end;
end;

{ The register capture above cannot also keep AX/BX/CX/DX, because AX is needed
  to unwind the stack. A second call, made only once the first has proved the
  driver answers, collects them. Two calls to a read-only function is a cheap
  way to avoid a fragile single-pass unwind. }
procedure CallDriverInfoRegs;
begin
  asm
    push ds
    mov  ax, 01FFh
    pushf
    call far [Handler]
    mov  si, ds
    pop  ds
    mov  RAX, ax
    mov  RBX, bx
    mov  RCX, cx
    mov  RDX, dx
  end;
end;

function DriverName: ShortString;
var
  S: ShortString;
  I: Integer;
  C: Char;
begin
  S := '';
  if NameSeg = 0 then
  begin
    DriverName := '(none)';
    Exit;
  end;
  for I := 0 to 39 do
  begin
    C := Chr(Mem[NameSeg : Word(NameOfs + Word(I))]);
    if C = #0 then Break;
    if (C < ' ') or (C > '~') then C := '?';
    S := S + C;
  end;
  if S = '' then S := '(empty)';
  DriverName := S;
end;

function ClassName_(C: Byte): ShortString;
begin
  case C of
    1  : ClassName_ := 'DIX Ethernet';
    2  : ClassName_ := 'ProNET-10';
    3  : ClassName_ := 'IEEE 802.5 Token Ring';
    4  : ClassName_ := 'Omninet';
    5  : ClassName_ := 'Appletalk';
    6  : ClassName_ := 'Serial Line';
    7  : ClassName_ := 'StarLAN';
    8  : ClassName_ := 'ARCNET';
    9  : ClassName_ := 'AX.25';
    10 : ClassName_ := 'KISS';
    11 : ClassName_ := 'IEEE 802.3 w/802.2 hdr';
    12 : ClassName_ := 'FDDI w/802.2 hdr';
    13 : ClassName_ := 'Internet X.25';
    14 : ClassName_ := 'LANstar';
    15 : ClassName_ := 'SLFP';
  else
    ClassName_ := 'unknown class';
  end;
end;

function FuncName(F: Byte): ShortString;
begin
  case F of
    1 : FuncName := 'basic';
    2 : FuncName := 'basic + extended';
    5 : FuncName := 'high performance';
    6 : FuncName := 'high performance + extended';
    9 : FuncName := 'basic + virtual';
  else
    FuncName := 'unreported (' + Num(F) + ')';
  end;
end;

procedure Report(Vec: Byte);
var
  Cls, Nr, Fn: Byte;
begin
  Handler.O := MemW[0 : Word(Vec) * 4];
  Handler.S := MemW[0 : Word(Vec) * 4 + 2];

  if not HasSignature(Handler.S, Handler.O) then Exit;

  Inc(Found);
  WriteLn;
  WriteLn('  INT ', Hex2(Vec), 'h  packet driver found');
  WriteLn('    handler        : ', Hex2(Handler.S shr 8), Hex2(Handler.S and $FF),
          ':', Hex2(Handler.O shr 8), Hex2(Handler.O and $FF));

  CallDriverInfo;
  if CarryB <> 0 then
  begin
    WriteLn('    driver_info    : refused (this happens on drivers that want');
    WriteLn('                     a handle even for AH=1Fh)');
    Exit;
  end;
  CallDriverInfoRegs;

  Cls := Byte(RCX shr 8);
  Nr  := Byte(RCX and $FF);
  Fn  := Byte(RAX and $FF);

  WriteLn('    name           : ', DriverName);
  WriteLn('    spec version   : ', RBX);
  WriteLn('    class          : ', Cls, '  (', ClassName_(Cls), ')');
  WriteLn('    type           : ', RDX);
  WriteLn('    number         : ', Nr);
  WriteLn('    functionality  : ', Fn, '  (', FuncName(Fn), ')');
end;

var
  V, Code : Integer;
  S       : ShortString;
  Cfg     : String;

begin
  Only := -1;
  if ParamCount >= 1 then
  begin
    { Hex, not decimal. The first version parsed this as decimal and `PKTDRV
      60` therefore probed vector 3Ch and reported no driver at all -- on a
      machine whose driver was sitting at 60h the whole time. Nobody types a
      packet driver vector in decimal. }
    S := ParamStr(1);
    Only := 0;
    Code := 0;
    for V := 1 to Length(S) do
    begin
      if (S[V] >= '0') and (S[V] <= '9') then
        Only := Only * 16 + (Ord(S[V]) - 48)
      else if (S[V] >= 'A') and (S[V] <= 'F') then
        Only := Only * 16 + (Ord(S[V]) - 55)
      else if (S[V] >= 'a') and (S[V] <= 'f') then
        Only := Only * 16 + (Ord(S[V]) - 87)
      else if (S[V] = 'h') or (S[V] = 'H') then
        { a trailing 'h' is how everyone writes these }
      else
        Code := 1;
    end;
    if (Code <> 0) or (Only < 0) or (Only > 255) then Only := -1;
  end;

  WriteLn('=== pktdrv: packet driver probe ===');
  WriteLn('  Read-only. driver_info (AH=1Fh) only -- no handle is opened, so');
  WriteLn('  nothing here can disturb the link this bridge is running over.');

  Found := 0;
  if Only >= 0 then
    Report(Byte(Only))
  else
    { 60h..80h is where the specification says to look, and where every driver
      in practice puts itself. Scanning the whole table would find false
      positives in unrelated resident code. }
    for V := $60 to $80 do
      Report(Byte(V));

  WriteLn;
  if Found = 0 then
  begin
    WriteLn('  No packet driver in 60h..80h.');
    WriteLn('  Without one there is no networking at all -- and if this program');
    WriteLn('  reached you over the bridge, something is loaded somewhere else.');
  end
  else
    WriteLn('  packet drivers found: ', Found);

  { mTCP reads its settings from the file this points at. Worth reporting in
    the same breath: a driver that is present but a config that is missing is
    the other half of "why is there no network". }
  Cfg := GetEnv('MTCPCFG');
  WriteLn;
  if Cfg = '' then
    WriteLn('  MTCPCFG        : not set (mTCP tools will refuse to run)')
  else
  begin
    WriteLn('  MTCPCFG        : ', Cfg);
    if FSearch(Cfg, '') <> '' then
      WriteLn('  config file    : present')
    else
      WriteLn('  config file    : MISSING at that path');
  end;

  if Found > 20 then Halt(20);
  Halt(Found);
end.
