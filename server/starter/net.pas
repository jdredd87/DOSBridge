{ net.pas -- IPv4 and UDP on top of the packet driver.

  DOS Bridge  --  StevenC & Claude

  WHY THIS EXISTS

  Everything the bridge sends or receives goes through this unit. It used to
  go through a third-party TCP/IP suite, which worked but was a dependency the
  installer kit could not ship -- the client README had to tell people to go
  and find it themselves -- and it cost several papercuts that are documented
  in CLAUDE.md: a version block printed to the console on every poll, queued
  keystrokes eaten out from under the agent loop, and an exit code of >= 20
  even on success.

  This unit is the bottom half of replacing it. `pktdrv`, `pktcap` and `arp`
  already proved we can find the driver, receive frames at interrupt time, and
  transmit -- what was missing was IPv4 and a transport. UDP is eight bytes
  and a checksum once IPv4 exists, which is why it comes first. TCP is not
  planned and should not be: see the "Where to go next" note in CLAUDE.md.

  WHAT IT DOES NOT DO

  No fragmentation, in either direction. Everything the bridge sends fits in
  one frame and anything arriving fragmented is dropped rather than
  reassembled -- a wrong reassembly is worse than a retry. No routing table
  beyond "is the peer on my subnet?"; if it is not, frames go to the gateway.
  No DNS, because the bridge talks to an IP address.

  THE RULE THAT MATTERS

  `NetOpen` hands the driver a far pointer to `PktRecv`, which it then calls
  at interrupt time for every matching frame. Exit without `NetClose` and that
  pointer dangles into memory DOS has since reused, and the next frame to
  arrive jumps into it. That is a machine with no network, and the bridge runs
  over that network -- recovery needs hands on the keyboard. So every exit
  path calls NetClose, including the error ones, and nothing between open and
  close does DOS I/O. }

unit Net;

{$MODE OBJFPC}{$H-}
{$ASMMODE INTEL}

interface

const
  { The bridge's network config. Written by the installer. }
  NET_CFG = 'C:\AI\NET.CFG';

  NET_MAXPKT = 1520;           { one Ethernet frame, with slack }
  NET_SLOTS  = 8;              { receive ring: a power of two }
  NET_SLOTSZ = 2048;           { a slot: length word + frame, padded to 2^11 }
  OFS_RHEAD  = 12 + NET_MAXPKT;
  OFS_RING   = OFS_RHEAD + 2;
  NET_HDRLEN = 14 + 20 + 8;    { Ethernet + IPv4 + UDP }
  NET_MAXUDP = NET_MAXPKT - NET_HDRLEN;

type
  TIP  = packed array[0..3] of Byte;
  TMac = packed array[0..5] of Byte;

var
  NetMyIP    : TIP;            { IPADDR, out of the network config }

  { Two OPTIONAL overrides, both defaulting to exactly the behaviour that
    was here before, so nothing which does not set them can be affected.
    They exist so a SECOND network interface can be driven from this unit
    without disturbing the one the bridge itself runs over.

    NetVecWant  0 = scan 60h..80h and take the first, as always.  Set to a
                vector and only that vector is accepted, so a tool can be
                aimed at a second packet driver rather than whichever
                answers first -- which on this box is always the NE2000 the
                machine is administered over.
    NetCfgWant  empty = NET_CFG then %MTCPCFG%, as always.  Set to a path
                and that file is tried first, because a second interface
                needs its own address and the bridge's config names the
                first one.

    UGET and UPUT set neither, so their BEHAVIOUR is unchanged -- but the
    binaries are not: adding these two globals and the two tests below
    makes UGET 138 bytes bigger (CRC 04A4A6DA -> 2F7FA149). That was
    checked by building both ways rather than assumed, because the first
    draft of this comment claimed byte-identical and was wrong, and UGET
    is how the box stays reachable. `starter/build/UGET.EXE` has been put
    back to the original binary so `dosctl verify` still agrees with what
    is deployed; rebuild it deliberately, not by accident. }
  NetVecWant : Byte;
  NetCfgWant : ShortString;

  { Accept datagrams addressed to the BROADCAST address as well as to us.
    Default False, so nothing that does not ask for it changes.

    This is not a convenience. Nothing on this box answers ARP while our
    stack holds only the 0800 handle -- the 0806 handle is released as soon
    as NetOpen's ARP phase finishes -- so a peer's cache entry for us
    expires after a couple of minutes and it silently stops delivering
    unicast. KNET measured the same thing and it is stark: 0 frames
    arriving unicast against 23 broadcast in the same 15 seconds. A
    long-running LISTENER therefore cannot be reached by unicast at all,
    and broadcast needs no resolution.

    The cost is that every host on the segment sees the traffic, which is
    fine for a test pattern on a lab network and is why this is opt-in. }
  NetRxBcast : Boolean;
  NetMask    : TIP;
  NetGw      : TIP;
  NetMyMac   : TMac;           { from the driver, not the config }
  NetPeerIP  : TIP;            { who NetOpen was pointed at }
  NetPeerMac : TMac;           { the peer, or the gateway if off-subnet }
  NetViaGw   : Boolean;
  NetVec     : Byte;           { the packet driver's interrupt vector }
  NetErr     : ShortString;    { why the last call returned False }

  { Who the last datagram accepted by NetUdpRecv came from. TFTP needs this
    and it is not a detail: a TFTP server answers from a NEW ephemeral port
    (the "transfer identifier"), not from the port the request went to, and
    every subsequent packet of that transfer must be aimed at it. Reply to
    port 69 for the whole transfer and a correct server ignores you. }
  NetFromIP   : TIP;
  NetFromPort : Word;

  { Which config file the settings actually came from. Worth reporting: with
    two candidate locations, "wrong address" and "wrong file" look identical
    from the outside. }
  NetCfgUsed  : ShortString;

  { Called roughly once per BIOS tick while NetUdpRecv is waiting, so a
    caller can show that it is alive without this unit deciding what that
    should look like. Left nil it costs one comparison per spin.

    Doing DOS output from here is safe: our receiver runs at interrupt time
    but never calls DOS itself, so there is no reentrancy to worry about --
    the only cost is that a frame arriving mid-write is refused and the
    sender retransmits. Once a tick is far too rare to matter. }
  NetIdleHook : procedure;

  { Diagnostics. Cheap to keep and the first thing you want when a transfer
    goes quiet -- "nothing arrived" and "plenty arrived and none of it was
    for us" look identical from the outside otherwise. }
  NetRxFrames : Word;          { frames the handler accepted }
  NetRxDrop   : Word;          { frames refused: busy, or too big }
  NetRxWrong  : Word;          { arrived, parsed, not ours }
  NetTxFrames : Word;
  NetTxFail   : Word;          { send_pkt refused it -- driver buffer full }

  { THE ARP KEEPALIVE, and why the transport was unusable without it.
    ----------------------------------------------------------------
    Ticks between unsolicited ARP requests for the peer while we are sitting
    in NetUdpRecv. 0 disables it. About eight seconds by default.

    Nothing on this box answers ARP: NetOpen releases the 0806 handle as soon
    as its resolve finishes and holds only 0800 afterwards, so an ARP request
    for us is never delivered to this program and never replied to. The
    comment on NetRxBcast above has said so for a long time, and KNET already
    measured the consequence for a listener -- 0 unicast frames against 23
    broadcast in the same 15 seconds. What nobody connected to it is that the
    SAME fault is the mid-transfer stall that this bridge has worked around,
    and built a whole flow-restart mechanism for, since the first 5 MB file.

    The chain, measured on 2026-09-12 rather than reasoned about:

      1. NetOpen ARPs the peer. Windows, as the TARGET of that request, is
         obliged by RFC 826 to refresh its own cache entry for us. Healthy.
      2. Fifteen to forty-five seconds later Windows' neighbour entry goes
         Stale, then Delay, then Probe -- it unicasts ARP requests to us.
      3. We cannot hear them, so we cannot answer.
      4. The entry reaches Unreachable and WINDOWS STOPS SENDING. Not the
         card, not the link, not the driver: the packets are never put on
         the wire at all.
      5. We time out three times, rebuild the flow, and NetOpen ARPs again --
         which is the only reason the stall ever cleared, and exactly why
         "a completely fresh flow always works" was true and so misleading.

    Correlated directly: every resume logged by dosd during a 1 MB fetch fell
    inside a window where Get-NetNeighbor showed the entry Unreachable or
    Incomplete, and the one 61-second stretch with no state change is the one
    stretch that transferred without a stall. The control that settles it is
    mTCP: it answers ARP, and it moved 10 MB over this same card and link at
    83 KB/s with no interruption at all while our own stack managed 12 KB/s.

    Why an ARP REQUEST and not a gratuitous reply: a request names Windows as
    its target, and a host receiving a request addressed to it must record the
    sender. An unsolicited reply is advisory and a stack may ignore it.

    Why PREVENTIVE and not on demand: an earlier attempt (`NetArpPoke`, now
    gone) fired an ARP on every retransmit DURING a stall and was recorded as
    changing nothing. By then the entry is already Unreachable and the flow is
    already lost. Refreshing it before it can expire is a different thing, and
    the interval is chosen against Windows' reachable time -- 30 seconds base,
    randomised 0.5x to 1.5x, so the floor to stay under is about 15. }
  NetArpEvery : Word;          { ticks between keepalive ARPs; 0 = off }
  NetArpSent  : Word;          { how many went out }
  NetArpReplied : Word;        { ARP requests for us that we answered }

function  NetReadConfig: Boolean;
function  NetFindDriver: Boolean;
function  NetOpen(const Peer: TIP): Boolean;
procedure NetClose;

function  NetUdpSend(SrcPort, DstPort: Word; var Data; Len: Word): Boolean;
function  NetUdpRecv(DstPort: Word; var Data; MaxLen: Word;
                     var GotLen: Word; TimeoutTicks: LongInt): Boolean;

function  NetTicks: LongInt;
function  IPStr(const A: TIP): ShortString;
function  MacStr(const M: TMac): ShortString;
function  ParseIP(S: ShortString; var A: TIP): Boolean;
function  SameNet(const A, B, M: TIP): Boolean;

implementation

uses Dos;                        { GetEnv }

type
  TPkt = array[0 .. NET_MAXPKT - 1] of Byte;
  PPkt = ^TPkt;

  { The layout the interrupt-time receiver below writes into. The assembler
    reaches these by hard-coded byte offsets, so DO NOT reorder or resize the
    fields ahead of Buf -- see the comment on PktRecv. Buf is TPkt rather than
    an anonymous array so it can be passed to the parsing helpers: in Pascal
    an anonymous array type will not bind to a named one as a var parameter. }
  { Frames arrive into a ring of slots, not straight into Buf.

    A single slot was enough for stop-and-wait: one datagram in flight,
    and Busy refused anything else that arrived while it was being read.
    With several blocks in flight (TFTP windowsize, 2026-09-27) they arrive
    back to back, faster than the main loop reads them, so the receiver
    queues up to NET_SLOTS of them.  The interrupt handler owns RHead (it
    fills slot RHead and then advances it); the main loop owns RTail -- so
    neither ever read-modify-writes the other's counter.  Pump moves the
    oldest queued frame into Buf when Buf is free, which is where every
    parser already looks. }
  TSlot = packed record
    Len : Word;
    Buf : TPkt;
    Pad : array[0 .. NET_SLOTSZ - 2 - NET_MAXPKT - 1] of Byte;
  end;

  TShared = packed record
    Busy     : Word;                                 { +0  }
    PktLen   : Word;                                 { +2  }
    PktCount : Word;                                 { +4  }
    Dropped  : Word;                                 { +6  }
    BytesLo  : Word;                                 { +8  }
    BytesHi  : Word;                                 { +10 }
    Buf      : TPkt;                                 { +12 }
    RHead    : Byte;                                 { OFS_RHEAD }
    RTail    : Byte;                                 { OFS_RHEAD + 1 }
    Ring     : array[0 .. NET_SLOTS - 1] of TSlot;   { OFS_RING, NET_SLOTSZ each }
  end;

const
  ETH_IP  = $0800;
  ETH_ARP = $0806;
  IPPROTO_UDP = 17;

var
  Shared  : TShared;
  { TWO filter buffers, not one reused.

    access_type is handed DS:SI pointing at the ethertype, and the spec does
    not promise the driver copies it rather than keeping the pointer. That
    was harmless while the two handles were strictly sequential; holding both
    at once, a shared buffer would let the second acquire rewrite the first
    handle's filter. Four bytes is a cheap way not to find out. }
  Filt    : packed array[0..1] of Byte;      { the IP handle's }
  FiltA   : packed array[0..1] of Byte;      { the ARP handle's }
  ArpHnd  : Word;
  HaveArpH: Boolean;
  Handler : packed record O, S: Word; end;
  TxBuf   : TPkt;
  Handle  : Word;
  CarryB  : Byte;
  ErrDH   : Byte;
  HaveDrv : Boolean;
  IsOpen  : Boolean;
  IPIdent : Word;

{ ------------------------------------------------------------------ }
{  The interrupt-time receiver.                                       }
{                                                                     }
{  Copied byte for byte from arp.pas, which is verified on hardware.  }
{  The first fourteen bytes are hand-written db/dw precisely because  }
{  two words need patching at run time and they have to sit at known  }
{  offsets: +7 is our data segment and +12 is Ofs(Shared). Let the    }
{  assembler pick its own encoding and those offsets stop being       }
{  knowable from Pascal. If you edit this prologue, re-check the      }
{  offsets against the linked binary before running it -- a wrong     }
{  patch corrupts an interrupt-time routine, which fails at the worst }
{  possible moment.                                                   }
{                                                                     }
{  The driver calls us twice per frame: AX=0 asks for a buffer of CX  }
{  bytes (return ES:DI, or 0:0 to drop it), AX=1 says it has been     }
{  copied in. Busy makes the second call safe to read from the main   }
{  loop: while it is set we refuse and count a drop rather than       }
{  overwrite a frame somebody is still reading.                       }
{ ------------------------------------------------------------------ }
procedure PktRecv; assembler; nostackframe;
asm
  db  01Eh              { push ds                       +0 }
  db  053h              { push bx                       +1 }
  db  051h              { push cx                       +2 }
  db  056h              { push si                       +3 }
  db  08Bh, 0F0h        { mov si, ax                 +4,+5 }
  db  0B8h              { mov ax, imm16                 +6 }
  dw  0                 {   patched: data segment       +7 }
  db  08Eh, 0D8h        { mov ds, ax                 +9,+10 }
  db  0BBh              { mov bx, imm16                +11 }
  dw  0                 {   patched: Ofs(Shared)       +12 }

  cmp  si, 0
  jne  @@second

  { AX=0: a buffer for CX bytes -- the slot at RHead, if the ring has room }
  cmp  cx, NET_MAXPKT
  ja   @@refuse
  mov  al, [bx + OFS_RHEAD]
  sub  al, [bx + OFS_RHEAD + 1]
  cmp  al, NET_SLOTS
  jae  @@refuse
  mov  al, [bx + OFS_RHEAD]
  and  al, NET_SLOTS - 1
  mov  ah, al
  xor  al, al
  shl  ah, 1
  shl  ah, 1
  shl  ah, 1                     { AX = slot * 2048 }
  mov  di, bx
  add  di, OFS_RING + 2
  add  di, ax
  mov  ax, ds
  mov  es, ax
  jmp  @@out

@@refuse:
  inc  word ptr [bx + 6]
  xor  ax, ax
  mov  es, ax
  xor  di, di
  jmp  @@out

@@second:
  { AX=1: the frame is in slot RHead -- note its length, then publish it }
  mov  al, [bx + OFS_RHEAD]
  and  al, NET_SLOTS - 1
  mov  ah, al
  xor  al, al
  shl  ah, 1
  shl  ah, 1
  shl  ah, 1
  mov  si, bx
  add  si, OFS_RING
  add  si, ax
  mov  [si], cx
  inc  byte ptr [bx + OFS_RHEAD]
  inc  word ptr [bx + 4]
  add  word ptr [bx + 8], cx
  adc  word ptr [bx + 10], 0

@@out:
  pop  si
  pop  cx
  pop  bx
  pop  ds
  retf
end;

{ ------------------------------------------------------------------ }
{  Small helpers                                                      }
{ ------------------------------------------------------------------ }

{ The oldest queued frame into Buf, if Buf is free.  Everything that reads
  frames calls this before looking at Busy. }
procedure Pump;
var
  S: Byte;
  L: Word;
begin
  if (Shared.Busy = 0) and (Shared.RHead <> Shared.RTail) then
  begin
    S := Shared.RTail and (NET_SLOTS - 1);
    L := Shared.Ring[S].Len;
    Move(Shared.Ring[S].Buf, Shared.Buf, L);
    Shared.PktLen := L;
    Shared.Busy := 1;
    Inc(Shared.RTail);
  end;
end;

{ Forget every frame received and not yet read. }
procedure Discard;
begin
  Shared.Busy := 0;
  Shared.RTail := Shared.RHead;
end;

function NetTicks: LongInt;
begin
  NetTicks := MemL[$0040 : $006C];
end;

function Num(L: LongInt): ShortString;
var S: ShortString;
begin
  Str(L, S);
  Num := S;
end;

function Hex2(B: Byte): ShortString;
const HexD: array[0..15] of Char = '0123456789ABCDEF';
begin
  Hex2 := HexD[B shr 4] + HexD[B and $0F];
end;

function IPStr(const A: TIP): ShortString;
begin
  IPStr := Num(A[0]) + '.' + Num(A[1]) + '.' + Num(A[2]) + '.' + Num(A[3]);
end;

function MacStr(const M: TMac): ShortString;
var
  S: ShortString;
  I: Integer;
begin
  S := '';
  for I := 0 to 5 do
  begin
    if I > 0 then S := S + ':';
    S := S + Hex2(M[I]);
  end;
  MacStr := S;
end;

function SameNet(const A, B, M: TIP): Boolean;
var I: Integer;
begin
  SameNet := False;
  for I := 0 to 3 do
    if (A[I] and M[I]) <> (B[I] and M[I]) then Exit;
  SameNet := True;
end;

function ParseIP(S: ShortString; var A: TIP): Boolean;
var
  I, N, V: Integer;
  Ch: Char;
  Digits: Integer;
begin
  ParseIP := False;
  N := 0; V := 0; Digits := 0;
  for I := 1 to Length(S) + 1 do
  begin
    if I <= Length(S) then Ch := S[I] else Ch := '.';
    if (Ch >= '0') and (Ch <= '9') then
    begin
      V := V * 10 + (Ord(Ch) - Ord('0'));
      Inc(Digits);
      if (V > 255) or (Digits > 3) then Exit;
    end
    else if Ch = '.' then
    begin
      if (Digits = 0) or (N > 3) then Exit;
      A[N] := Byte(V);
      Inc(N); V := 0; Digits := 0;
    end
    else
      Exit;
  end;
  ParseIP := (N = 4);
end;

{ Big-endian store/load. Network order is the opposite of the x86's, and
  getting this backwards produces packets that look plausible in a hex dump
  and are silently discarded by every host on the wire. }
procedure PutW(var P: TPkt; Ofs, V: Word);
begin
  P[Ofs] := Hi(V);
  P[Ofs + 1] := Lo(V);
end;

function GetW(var P: TPkt; Ofs: Word): Word;
begin
  GetW := (Word(P[Ofs]) shl 8) or P[Ofs + 1];
end;

{ One's-complement sum, accumulated 16 bits at a time with the end-around
  carry done inline. A 32-bit accumulator would be the textbook version and
  is 5-8x dearer here (see the BENCH figures in CLAUDE.md); this stays in
  16-bit arithmetic, which on an 8086 is the difference that matters. }
procedure AddW(var S: Word; W: Word);
begin
  S := S + W;
  if S < W then Inc(S);          { the carry wraps around to the low end }
end;

{$I sumbuf.inc}

function Fold(S: Word): Word;
begin
  Fold := S xor $FFFF;
end;

{ ------------------------------------------------------------------ }
{  Configuration                                                      }
{                                                                     }
{  C:\AI\NET.CFG, which the installer writes.                        }
{                                                                     }
{  A legacy fallback follows it -- see NetReadConfig. Both files use   }
{  the same key names, which is why that fallback is one line rather   }
{  than a second parser.                                               }
{                                                                     }
{  Reading a file is a DOS operation, so it must happen -- and does   }
{  -- before any packet handle is ever opened.                        }
{ ------------------------------------------------------------------ }
function ReadCfgFile(const Cfg: ShortString; var GotIP: Boolean): Boolean;
var
  F     : Text;
  Line  : ShortString;
  I     : Integer;
  Key   : ShortString;
  Rest  : ShortString;
begin
  ReadCfgFile := False;
  if Cfg = '' then Exit;

  {$I-}
  Assign(F, Cfg);
  Reset(F);
  {$I+}
  if IOResult <> 0 then Exit;

  while not Eof(F) do
  begin
    {$I-}
    ReadLn(F, Line);
    {$I+}
    if IOResult <> 0 then Break;

    I := 1;
    while (I <= Length(Line)) and (Line[I] = ' ') do Inc(I);
    Key := '';
    while (I <= Length(Line)) and (Line[I] <> ' ') do
    begin
      Key := Key + UpCase(Line[I]);
      Inc(I);
    end;
    while (I <= Length(Line)) and (Line[I] = ' ') do Inc(I);
    Rest := '';
    while (I <= Length(Line)) and (Line[I] <> ' ') do
    begin
      Rest := Rest + Line[I];
      Inc(I);
    end;

    if Key = 'IPADDR' then
      GotIP := ParseIP(Rest, NetMyIP)
    else if Key = 'NETMASK' then
      ParseIP(Rest, NetMask)
    else if Key = 'GATEWAY' then
      ParseIP(Rest, NetGw);
  end;
  Close(F);
  NetCfgUsed := Cfg;
  ReadCfgFile := True;
end;

{ NET_CFG, then the legacy config named by %MTCPCFG%.

  Ours first, so a box carrying both is driven by the bridge's own settings
  rather than silently inheriting someone else's. The second path is a
  compatibility shim for machines configured before the bridge had a config of
  its own; nothing the installer produces needs it, and it can go once no such
  box is left. It is the last mention of that suite in this tree, and it is
  four lines. }
function NetReadConfig: Boolean;
var
  GotIP: Boolean;
begin
  NetReadConfig := False;
  GotIP := False;
  NetCfgUsed := '';
  { A sane default: if the config names no mask, assume a /24. Being wrong
    here only decides gateway-or-direct, and both are ARPed for. }
  NetMask[0] := 255; NetMask[1] := 255; NetMask[2] := 255; NetMask[3] := 0;
  FillChar(NetGw, SizeOf(NetGw), 0);

  if (NetCfgWant <> '') and ReadCfgFile(NetCfgWant, GotIP) then
    GotIP := GotIP      { the caller named a config and it read: use it }
  else if not ReadCfgFile(NET_CFG, GotIP) then
    if not ReadCfgFile(GetEnv('MTCPCFG'), GotIP) then
    begin
      NetErr := 'no network config: ' + NET_CFG;
      Exit;
    end;

  if not GotIP then
  begin
    NetErr := 'no usable IPADDR in ' + NetCfgUsed;
    Exit;
  end;
  NetReadConfig := True;
end;

{ ------------------------------------------------------------------ }
{  Packet driver plumbing                                             }
{                                                                     }
{  Calling a vector known only at run time needs a trick: the INT     }
{  opcode takes an immediate operand, so instead we PUSHF and far     }
{  CALL, which leaves the stack exactly as INT would and unwinds      }
{  correctly on the driver's IRET.                                    }
{                                                                     }
{  The fiddly part is that the call returns with DS pointing at the   }
{  DRIVER's segment, so until DS is put back every global here is     }
{  unreachable and storing a result would write into the driver. Move }
{  what you need into registers first, restore DS, then store -- MOV  }
{  does not touch the flags, so the carry the driver returned is      }
{  still valid when you test it.                                      }
{ ------------------------------------------------------------------ }
function NetFindDriver: Boolean;
const
  Sig = 'PKT DRVR';
var
  V, I: Integer;
  Sg, Of_: Word;
  Ok: Boolean;
begin
  NetFindDriver := False;
  if HaveDrv then
  begin
    NetFindDriver := True;
    Exit;
  end;
  for V := $60 to $80 do
  begin
    if (NetVecWant <> 0) and (V <> NetVecWant) then Continue;
    Of_ := MemW[0 : Word(V) * 4];
    Sg  := MemW[0 : Word(V) * 4 + 2];
    if Sg = 0 then Continue;
    Ok := True;
    for I := 1 to 8 do
      if Chr(Mem[Sg : Word(Of_ + 2 + I)]) <> Sig[I] then
      begin
        Ok := False; Break;
      end;
    if Ok then
    begin
      NetVec := Byte(V);
      Handler.O := Of_; Handler.S := Sg;
      HaveDrv := True;
      NetFindDriver := True;
      Exit;
    end;
  end;
  if NetVecWant <> 0 then
    NetErr := 'no packet driver on the requested vector'
  else
    NetErr := 'no packet driver found on vectors 60h..80h';
end;

{ access_type (AH=02h) for one ethertype. }
function Acquire(EtherType: Word; FOfs: Word): Boolean;
var
  RSeg, ROfs: Word;
begin
  MemW[Seg(Filt) : FOfs] := Swap(EtherType);   { the filter is network order }
  Discard;
  RSeg := Seg(PktRecv);
  ROfs := Ofs(PktRecv);
  asm
    push ds
    push es
    push si
    push di
    mov  ax, RSeg
    mov  es, ax
    mov  di, ROfs
    mov  si, FOfs
    mov  cx, 2
    mov  bx, 0FFFFh
    mov  dl, 0
    mov  ah, 2
    mov  al, 1
    pushf
    call far [Handler]
    mov  cx, ax
    mov  ax, dx
    pop  di
    pop  si
    pop  es
    pop  ds
    jnc  @@ok
    mov  CarryB, 1
    jmp  @@fin
  @@ok:
    mov  CarryB, 0
  @@fin:
    mov  Handle, cx
    mov  ErrDH, ah
  end;
  Acquire := (CarryB = 0);
  if CarryB <> 0 then
    NetErr := 'access_type refused for ethertype ' + Hex2(Hi(EtherType))
              + Hex2(Lo(EtherType)) + ', driver error ' + Num(ErrDH);
end;

{ release_type (AH=03h) for one named handle. Two are held at once now, so
  releasing "the" handle is no longer a well-formed request. }
procedure ReleaseOne(H: Word);
begin
  asm
    push ds
    mov  bx, H
    mov  ah, 3
    pushf
    call far [Handler]
    pop  ds
  end;
end;

{ get_address (AH=06h): our own MAC into ES:DI. Needs the handle, so it can
  only be called between Acquire and ReleaseHandle. }
procedure GetMyMac;
var
  MSeg, MOfs: Word;
begin
  MSeg := Seg(NetMyMac); MOfs := Ofs(NetMyMac);
  asm
    push ds
    push es
    push di
    mov  ax, MSeg
    mov  es, ax
    mov  di, MOfs
    mov  cx, 6
    mov  bx, Handle
    mov  ah, 6
    pushf
    call far [Handler]
    pop  di
    pop  es
    pop  ds
  end;
end;

{ send_pkt (AH=04h): DS:SI = frame, CX = length. No handle, no callback,
  nothing to release -- transmitting really is the easy half. }
{ send_pkt (AH=04h): DS:SI = frame, CX = length.

  The carry flag matters and was being thrown away. A driver whose transmit
  buffer is full returns carry set and sends NOTHING, which from the caller's
  side is indistinguishable from a packet lost on the wire -- except that
  retransmitting immediately will fail exactly the same way. Counting these
  separately is the difference between "the link is lossy" and "we are
  overrunning the card". }
procedure SendFrame(Len: Word);
var
  FOfs: Word;
begin
  FOfs := Ofs(TxBuf);
  asm
    push ds
    push si
    mov  si, FOfs
    mov  cx, Len
    mov  ah, 4
    pushf
    call far [Handler]
    pop  si
    pop  ds
    jnc  @@ok
    mov  CarryB, 1
    jmp  @@fin
  @@ok:
    mov  CarryB, 0
  @@fin:
  end;
  if CarryB <> 0 then Inc(NetTxFail) else Inc(NetTxFrames);
end;

{ Point the patched words in PktRecv at this program's data. }
procedure PatchRecv;
begin
  MemW[Seg(PktRecv) : Word(Ofs(PktRecv) + 7)]  := Seg(Shared);
  MemW[Seg(PktRecv) : Word(Ofs(PktRecv) + 12)] := Ofs(Shared);
end;

{ ------------------------------------------------------------------ }
{  ARP                                                                }
{ ------------------------------------------------------------------ }

procedure BuildArpRequest(const Target: TIP);
var I: Integer;
begin
  for I := 0 to 59 do TxBuf[I] := 0;
  for I := 0 to 5 do TxBuf[I] := $FF;                  { broadcast }
  for I := 0 to 5 do TxBuf[6 + I] := NetMyMac[I];
  PutW(TxBuf, 12, ETH_ARP);
  PutW(TxBuf, 14, 1);                                  { Ethernet }
  PutW(TxBuf, 16, ETH_IP);                             { resolving IPv4 }
  TxBuf[18] := 6;
  TxBuf[19] := 4;
  PutW(TxBuf, 20, 1);                                  { request }
  for I := 0 to 5 do TxBuf[22 + I] := NetMyMac[I];
  for I := 0 to 3 do TxBuf[28 + I] := NetMyIP[I];
  { 32..37 target MAC stays zero -- it is what we are asking for }
  for I := 0 to 3 do TxBuf[38 + I] := Target[I];
end;

{ Who NetOpen resolved -- the peer, or the gateway when it is off-subnet.
  Kept so the keepalive can re-ask the same question NetOpen asked. }
var
  ArpWhom : TIP;
  LastArp : LongInt;

{ One unsolicited ARP request for the peer, fire and forget.

  The reply is not waited for and does not need to be: the point is not to
  learn anything, it is to make the far end record US. We hold the 0800
  handle, so the reply is not even delivered to this program -- which is
  convenient, because it cannot then displace a data block in the receiver's
  single-frame buffer.

  send_pkt takes no handle (see SendFrame), so this is legal while the IPv4
  handle is the only one open. }
procedure ArpKeepalive;
begin
  if (ArpWhom[0] or ArpWhom[1] or ArpWhom[2] or ArpWhom[3]) = 0 then Exit;
  BuildArpRequest(ArpWhom);
  SendFrame(60);
  Inc(NetArpSent);
end;

{ Answer an ARP request for our own address.

  This is the half of ARP that was missing, and its absence is what made
  every long transfer stall. A peer that cannot refresh its cache entry for
  us stops being able to send to us at all -- see the keepalive note in the
  interface for the measurement -- and refreshing it from our side on a timer
  only shortens the dead window. Replying closes it: the peer's own probe
  gets an answer, its entry goes Reachable, and it stays there.

  Called from NetUdpRecv with a frame already in the shared buffer. Returns
  True if the frame was an ARP request for us and a reply went out, so the
  caller knows it was handled rather than merely foreign.

  Note this reuses TxBuf. That is safe from here because NetUdpRecv is not
  sending anything of its own -- but it is why this must not be called from
  inside a send path. }
function ArpService(L: Word): Boolean;
var I: Integer;
begin
  ArpService := False;
  if L < 42 then Exit;
  if (Shared.Buf[12] <> $08) or (Shared.Buf[13] <> $06) then Exit;
  if (Shared.Buf[20] <> $00) or (Shared.Buf[21] <> $01) then Exit;  { request }
  { Bytes 38..41 are the target protocol address: is it us? }
  for I := 0 to 3 do
    if Shared.Buf[38 + I] <> NetMyIP[I] then Exit;

  for I := 0 to 59 do TxBuf[I] := 0;
  for I := 0 to 5 do TxBuf[I] := Shared.Buf[22 + I];   { to the asker }
  for I := 0 to 5 do TxBuf[6 + I] := NetMyMac[I];
  PutW(TxBuf, 12, ETH_ARP);
  PutW(TxBuf, 14, 1);                                  { Ethernet }
  PutW(TxBuf, 16, ETH_IP);
  TxBuf[18] := 6;
  TxBuf[19] := 4;
  PutW(TxBuf, 20, 2);                                  { reply }
  for I := 0 to 5 do TxBuf[22 + I] := NetMyMac[I];
  for I := 0 to 3 do TxBuf[28 + I] := NetMyIP[I];
  for I := 0 to 5 do TxBuf[32 + I] := Shared.Buf[22 + I];
  for I := 0 to 3 do TxBuf[38 + I] := Shared.Buf[28 + I];
  SendFrame(60);
  Inc(NetArpReplied);
  ArpService := True;
end;

{ Send an ARP request and wait for the matching reply.

  The sender address matters and is easy to get wrong: the packet driver has
  no idea what our IP is -- addresses are a concept one layer up -- so it has
  to come from the config. An earlier version of arp.pas guessed ".0" of the
  target's range and got no replies at all, because .0 is a network address
  that well-behaved hosts are right to ignore. }
function ArpResolve(const Target: TIP; var M: TMac; Tries: Integer;
                    PerTry: LongInt): Boolean;
var
  Attempt : Integer;
  Deadline, T0: LongInt;
  L, I    : Word;
  Ok      : Boolean;
begin
  ArpResolve := False;
  for Attempt := 1 to Tries do
  begin
    BuildArpRequest(Target);
    Discard;
    SendFrame(60);

    T0 := NetTicks;
    Deadline := T0 + PerTry;
    repeat
      Pump;
      if Shared.Busy <> 0 then
      begin
        L := Shared.PktLen;
        Ok := (L >= 42)
              and (Shared.Buf[12] = $08) and (Shared.Buf[13] = $06)
              and (Shared.Buf[20] = $00) and (Shared.Buf[21] = $02);
        if Ok then
          for I := 0 to 3 do
            if Shared.Buf[28 + I] <> Target[I] then Ok := False;
        if Ok then
        begin
          for I := 0 to 5 do M[I] := Shared.Buf[22 + I];
          Shared.Busy := 0;
          ArpResolve := True;
          Exit;
        end;
        Inc(NetRxWrong);
        Shared.Busy := 0;
      end;
      { NetTicks wraps at midnight. Treat a counter that has gone backwards
        as "time is up" rather than looping for another 24 hours. }
    until (NetTicks >= Deadline) or (NetTicks < T0);
  end;
  NetErr := 'no ARP reply from ' + IPStr(Target);
end;

{ ------------------------------------------------------------------ }
{  Open / close                                                       }
{ ------------------------------------------------------------------ }

{ Resolve the peer, then hold a handle for IPv4.

  Two handles are NOT held at once. The packet driver spec lets a driver
  refuse a second access_type for a type already in use, and behaviour when
  two handles want the same type is not something to depend on -- so the ARP
  phase opens 0806, finishes, releases, and only then does the IP phase open
  0800. Sequential, never concurrent. The same reasoning is why this can
  coexist with any other packet-driver program on the box -- PKTCAP, ARP,
  anything else resident: they are separate programs that never hold a handle
  at the same moment. }
procedure DropArpHandle;
begin
  if not HaveArpH then Exit;
  ReleaseOne(ArpHnd);
  HaveArpH := False;
end;

function NetOpen(const Peer: TIP): Boolean;
var
  Whom: TIP;
begin
  NetOpen := False;
  NetErr := '';
  if IsOpen then
  begin
    NetErr := 'NetOpen called twice without NetClose';
    Exit;
  end;
  if not NetFindDriver then Exit;

  NetPeerIP := Peer;
  PatchRecv;

  { --- ARP phase ------------------------------------------------- }
  if not Acquire(ETH_ARP, Ofs(FiltA)) then Exit;
  ArpHnd := Handle;
  HaveArpH := True;
  GetMyMac;

  NetViaGw := not SameNet(NetMyIP, Peer, NetMask);
  if NetViaGw then Whom := NetGw else Whom := Peer;
  ArpWhom := Whom;
  LastArp := NetTicks;

  if (Whom[0] or Whom[1] or Whom[2] or Whom[3]) = 0 then
  begin
    DropArpHandle;
    NetErr := IPStr(Peer) + ' is off-subnet and no GATEWAY is configured';
    Exit;
  end;

  if not ArpResolve(Whom, NetPeerMac, 3, 18) then
  begin
    DropArpHandle;
    Exit;
  end;

  { --- IP phase -------------------------------------------------- }
  { The ARP handle is KEPT this time, so that ARP requests for us are
    delivered and can be answered -- see ArpService, and the keepalive note
    in the interface for why being unreachable by ARP was costing this link
    most of its throughput.

    Two handles at once is what the original comment here declined to do,
    on the grounds that a driver may refuse a second access_type for a type
    already in use. That is true of the SAME type; 0800 and 0806 are
    different, and this driver takes both. It is still not assumed: if the
    IP acquire fails while ARP is held, the ARP handle is dropped and the
    acquire retried alone, so the worst case is the behaviour this unit had
    before -- a working transport that cannot answer ARP -- rather than a
    box that cannot talk at all. }
  if not Acquire(ETH_IP, Ofs(Filt)) then
  begin
    DropArpHandle;
    if not Acquire(ETH_IP, Ofs(Filt)) then Exit;
  end;
  IsOpen := True;
  NetOpen := True;
end;

procedure NetClose;
begin
  if not IsOpen then Exit;
  ReleaseOne(Handle);
  DropArpHandle;
  IsOpen := False;
end;

{ ------------------------------------------------------------------ }
{  UDP                                                                }
{ ------------------------------------------------------------------ }

function NetUdpSend(SrcPort, DstPort: Word; var Data; Len: Word): Boolean;
var
  I, Total, UdpLen, Ck: Word;
  Src: PPkt;
  S: Word;
begin
  NetUdpSend := False;
  if not IsOpen then
  begin
    NetErr := 'NetUdpSend before NetOpen';
    Exit;
  end;
  if Len > NET_MAXUDP then
  begin
    NetErr := 'payload ' + Num(Len) + ' exceeds ' + Num(NET_MAXUDP)
              + ' -- this unit does not fragment';
    Exit;
  end;

  Src    := PPkt(@Data);
  UdpLen := 8 + Len;
  Total  := 14 + 20 + UdpLen;
  FillChar(TxBuf, SizeOf(TxBuf), 0);

  { Ethernet }
  for I := 0 to 5 do TxBuf[I] := NetPeerMac[I];
  for I := 0 to 5 do TxBuf[6 + I] := NetMyMac[I];
  PutW(TxBuf, 12, ETH_IP);

  { IPv4 }
  TxBuf[14] := $45;                       { version 4, 20-byte header }
  TxBuf[15] := 0;                         { DSCP/ECN }
  PutW(TxBuf, 16, 20 + UdpLen);           { total length }
  Inc(IPIdent);
  PutW(TxBuf, 18, IPIdent);
  PutW(TxBuf, 20, 0);                     { no flags, no fragment offset }
  TxBuf[22] := 64;                        { TTL }
  TxBuf[23] := IPPROTO_UDP;
  PutW(TxBuf, 24, 0);                     { checksum, filled in below }
  for I := 0 to 3 do TxBuf[26 + I] := NetMyIP[I];
  for I := 0 to 3 do TxBuf[30 + I] := NetPeerIP[I];
  S := 0;
  SumBuf(S, TxBuf, 14, 20);
  PutW(TxBuf, 24, Fold(S));

  { UDP }
  PutW(TxBuf, 34, SrcPort);
  PutW(TxBuf, 36, DstPort);
  PutW(TxBuf, 38, UdpLen);
  PutW(TxBuf, 40, 0);                     { checksum, filled in below }
  { Guarded: Len is a Word, so "0 to Len - 1" with Len = 0 counts to 65535. }
  if Len > 0 then
    Move(Src^[0], TxBuf[42], Len);

  { UDP's checksum covers a pseudo-header of the IP addresses, the protocol
    and the UDP length, as well as the datagram itself. It is optional in
    IPv4 -- zero means "not computed" -- but computing it costs almost
    nothing here and it is the only end-to-end check on the payload. }
  S := 0;
  SumBuf(S, TxBuf, 26, 8);                { source and destination IP }
  AddW(S, IPPROTO_UDP);
  AddW(S, UdpLen);
  SumBuf(S, TxBuf, 34, UdpLen);
  Ck := Fold(S);
  { An all-zero checksum on the wire means "none sent", so the one's
    complement rule is to transmit it as all ones instead. }
  if Ck = 0 then Ck := $FFFF;
  PutW(TxBuf, 40, Ck);

  { Ethernet's minimum payload is 46 bytes; pad short frames rather than
    relying on the card to do it. FillChar already zeroed the tail. }
  if Total < 60 then Total := 60;
  SendFrame(Total);
  NetUdpSend := True;
end;

{ Wait for one UDP datagram addressed to DstPort.

  Anything else that arrives on the handle -- and on a busy LAN plenty will,
  since we asked for every IPv4 frame -- is counted and discarded. That
  counting is not decoration: "nothing came back" and "lots came back and
  none of it was ours" are the same silence from the caller's side, and they
  have completely different causes. }
function NetUdpRecv(DstPort: Word; var Data; MaxLen: Word;
                    var GotLen: Word; TimeoutTicks: LongInt): Boolean;
var
  T0, Deadline, LastTick, Now: LongInt;
  L, Ihl, UdpLen, PayOfs, PayLen, I: Word;
  Dst: PPkt;
  Ok: Boolean;
begin
  NetUdpRecv := False;
  GotLen := 0;
  Dst := PPkt(@Data);
  if not IsOpen then
  begin
    NetErr := 'NetUdpRecv before NetOpen';
    Exit;
  end;

  T0 := NetTicks;
  Deadline := T0 + TimeoutTicks;
  LastTick := T0;
  repeat
    if NetIdleHook <> nil then
    begin
      Now := NetTicks;
      if Now <> LastTick then
      begin
        LastTick := Now;
        NetIdleHook;
      end;
    end;
    { The keepalive is paced ACROSS calls, not within one: a single
      NetUdpRecv lasts about two seconds and the interval to defend is
      fifteen, so a per-call timer would either never fire or fire on every
      block. LastArp is module state for that reason, and NetOpen resets it
      so a fresh flow does not immediately ARP again on top of the one it
      has just done. }
    if NetArpEvery > 0 then
    begin
      Now := NetTicks;
      if (Now - LastArp >= LongInt(NetArpEvery)) or (Now < LastArp) then
      begin
        LastArp := Now;
        ArpKeepalive;
      end;
    end;
    Pump;
    if Shared.Busy <> 0 then
    begin
      Inc(NetRxFrames);
      L := Shared.PktLen;
      Ok := False;

      { ARP first, and it is never "ours" in the datagram sense -- answering
        it is a side effect, and the caller is still waiting for its UDP.
        Counting it as wrong would misreport the one statistic used to tell
        a deaf card from a quiet one. }
      if ArpService(L) then
      begin
        Shared.Busy := 0;
        Continue;
      end;

      if (L >= NET_HDRLEN)
         and (Shared.Buf[12] = $08) and (Shared.Buf[13] = $00)
         and ((Shared.Buf[14] shr 4) = 4) then
      begin
        Ihl := (Shared.Buf[14] and $0F) * 4;
        { A fragment has a non-zero offset or the More Fragments bit set.
          Reassembly is not implemented, so drop it rather than hand the
          caller half a datagram that looks whole. }
        if (Ihl >= 20) and (L >= 14 + Ihl + 8)
           and (Shared.Buf[14 + 9] = IPPROTO_UDP)
           and ((GetW(Shared.Buf, 14 + 6) and $3FFF) = 0) then
        begin
          Ok := True;
          for I := 0 to 3 do
            if Shared.Buf[14 + 16 + I] <> NetMyIP[I] then Ok := False;
          if (not Ok) and NetRxBcast then
          begin
            { Addressed to the subnet's broadcast address, or to
              255.255.255.255. Both are legitimately ours to take. }
            Ok := True;
            for I := 0 to 3 do
              if Shared.Buf[14 + 16 + I] <>
                 Byte(NetMyIP[I] or (not NetMask[I])) then Ok := False;
            if not Ok then
            begin
              Ok := True;
              for I := 0 to 3 do
                if Shared.Buf[14 + 16 + I] <> 255 then Ok := False;
            end;
          end;
          if Ok and (GetW(Shared.Buf, 14 + Ihl + 2) <> DstPort) then
            Ok := False;
          if Ok then
          begin
            UdpLen := GetW(Shared.Buf, 14 + Ihl + 4);
            if (UdpLen < 8) or (L < 14 + Ihl + UdpLen) then
              Ok := False
            else
            begin
              PayOfs := 14 + Ihl + 8;
              PayLen := UdpLen - 8;
              if PayLen > MaxLen then PayLen := MaxLen;
              { Move, not a byte loop: the loop cost ~7 ms of a
                1400-byte block on the V30 (2026-09-27). }
              if PayLen > 0 then
                Move(Shared.Buf[PayOfs], Dst^[0], PayLen);
              GotLen := PayLen;
              for I := 0 to 3 do NetFromIP[I] := Shared.Buf[14 + 12 + I];
              NetFromPort := GetW(Shared.Buf, 14 + Ihl);
            end;
          end;
        end;
      end;

      if not Ok then Inc(NetRxWrong);
      Shared.Busy := 0;
      if Ok then
      begin
        NetUdpRecv := True;
        Exit;
      end;
    end;
  until (NetTicks >= Deadline) or (NetTicks < T0);

  NetRxDrop := Shared.Dropped;
  NetErr := 'timed out waiting for a UDP reply on port ' + Num(DstPort);
end;

begin
  HaveDrv := False;
  IsOpen  := False;
  IPIdent := 0;
  NetIdleHook := nil;
  NetErr  := '';
  NetRxFrames := 0;
  NetRxDrop   := 0;
  NetRxWrong  := 0;
  NetTxFrames := 0;
  NetTxFail   := 0;
  { ~8 seconds at 18.2 Hz. Windows' reachable time is 30 seconds base,
    randomised 0.5x to 1.5x, so the entry can go stale as early as 15 --
    eight seconds clears that with room, and costs one 60-byte frame every
    eight seconds against a link that carries 1400-byte blocks. }
  NetArpEvery := 145;
  NetArpSent  := 0;
  NetArpReplied := 0;
  LastArp     := 0;
  HaveArpH    := False;
end.
