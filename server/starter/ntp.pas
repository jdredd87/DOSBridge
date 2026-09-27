{ DOS Bridge  --  StevenC & Claude }
{ ntp.pas -- ask an NTP server what time it is, over our own UDP.

  This was the first program to send and receive IP on our own stack, and it
  exists to prove `net.pas` works against something that is not also ours. An
  echo
  bounced off our own daemon would pass even if both ends agreed on the same
  mistake; a real NTP server checks the UDP checksum, checks the addresses,
  and answers in a format we did not invent -- so a correct reply is evidence
  the whole stack is right, not just self-consistent.

  It is READ-ONLY on purpose. Setting the clock is one line more and it is
  deliberately not here: the point of this build is to find out whether the
  network layer is trustworthy, and a tool that changes machine state while
  answering that question makes a bad experiment.

    NTP                 ask the GATEWAY from the bridge's network config
    NTP 192.168.1.1    ask a specific server

  Exit codes:  0 got a plausible reply
               1 no reply, or the reply was not usable
               2 setup failed (no driver, no config, ARP failed)

  Note there is no DNS here, so the server must be an address. That is not a
  limitation worth fixing for the bridge, which only ever talks to one host by
  IP, but it does mean a name like pool.ntp.org cannot be used. Most home
  routers answer NTP for their own LAN, which is why the default is the
  gateway. }

program Ntp;

{$MODE OBJFPC}{$H-}

uses Dos, Net, About;

const
  NTP_PORT  = 123;
  { A source port well clear of anything assigned. Nothing here demands a
    particular one -- the reply comes back to whatever we send from. }
  MY_PORT   = 50123;
  NTP_LEN   = 48;
  { Seconds between 1900-01-01 and 1970-01-01. NTP counts from the former,
    everything else from the latter. }
  EPOCH_OFS = LongWord(2208988800);

var
  Pkt     : array[0 .. NTP_LEN - 1] of Byte;
  Reply   : array[0 .. 127] of Byte;
  Got     : Word;
  Server  : TIP;
  T0, T1  : LongInt;
  Secs    : LongWord;
  RC      : Integer;
  Opened  : Boolean;

function Num(L: LongInt): ShortString;
var S: ShortString;
begin
  Str(L, S);
  Num := S;
end;

{ LongWord has no Str() overload that behaves on i8086 for values above
  MaxLongInt, so print it by pulling digits off the bottom. Today's NTP
  seconds are about 3.99e9, comfortably past LongInt's 2.15e9 ceiling -- the
  obvious Str(LongInt(Secs)) prints a negative number. }
function NumU(V: LongWord): ShortString;
var
  S: ShortString;
  D: LongWord;
begin
  if V = 0 then
  begin
    NumU := '0';
    Exit;
  end;
  S := '';
  while V > 0 do
  begin
    D := V mod 10;
    S := Chr(Ord('0') + Byte(D)) + S;
    V := V div 10;
  end;
  NumU := S;
end;

{ Hex, because packet driver vectors are always spoken of in hex and printing
  "INT 96" for 60h is the same decimal/hex confusion that made PKTDRV report
  no driver when it was handed one. }
function Hex2(B: Byte): ShortString;
const HexD: array[0..15] of Char = '0123456789ABCDEF';
begin
  Hex2 := HexD[B shr 4] + HexD[B and $0F];
end;

function Pad2(V: Integer): ShortString;
begin
  if V < 10 then Pad2 := '0' + Num(V) else Pad2 := Num(V);
end;

{ Days since 1970-01-01 back to a civil date. The shift-the-year-to-March
  trick makes the leap day the last day of the year, so the month-length
  pattern becomes a single linear formula and no table is needed. }
procedure CivilFromDays(Z: LongInt; var Y: LongInt; var M, D: Integer);
var
  Era, DoE, YoE, DoY, Mp: LongInt;
begin
  Z := Z + 719468;
  if Z >= 0 then Era := Z div 146097 else Era := (Z - 146096) div 146097;
  DoE := Z - Era * 146097;
  YoE := (DoE - DoE div 1460 + DoE div 36524 - DoE div 146096) div 365;
  Y   := YoE + Era * 400;
  DoY := DoE - (365 * YoE + YoE div 4 - YoE div 100);
  Mp  := (5 * DoY + 2) div 153;
  D   := DoY - (153 * Mp + 2) div 5 + 1;
  if Mp < 10 then M := Mp + 3 else M := Mp - 9;
  if M <= 2 then Inc(Y);
end;

procedure Bail(Code: Integer);
begin
  { Release before anything else. Leaving the handle open leaves the driver
    holding a far pointer into memory DOS is about to reuse, and the next
    matching frame jumps into it -- a box with no network, recovered only at
    the keyboard. }
  if Opened then NetClose;
  Halt(Code);
end;

var
  Y      : LongInt;
  Mo, Da : Integer;
  Days   : LongInt;
  Rem    : LongWord;
  Hh, Mm, Ss : Integer;
  Unix   : LongWord;
  DY, DM, DD, DW : Word;
  TH, TM, TS, TC : Word;
  Mode, Strat, LI : Byte;
  I      : Integer;

begin
  Opened := False;
  RC := 0;
  WriteLn('=== ntp ===');

  if not NetReadConfig then
  begin
    WriteLn('  config         : FAILED -- ', NetErr);
    Halt(2);
  end;

  if ParamCount >= 1 then
  begin
    if not ParseIP(ParamStr(1), Server) then
    begin
      WriteLn('  server         : "', ParamStr(1), '" is not an IP address');
      WriteLn('  usage          : NTP [a.b.c.d]   (no DNS here -- see the header)');
      Halt(2);
    end;
  end
  else
  begin
    Server := NetGw;
    if (Server[0] or Server[1] or Server[2] or Server[3]) = 0 then
    begin
      WriteLn('  server         : no GATEWAY in the config and none given');
      WriteLn('  usage          : NTP a.b.c.d');
      Halt(2);
    end;
  end;

  if not NetOpen(Server) then
  begin
    WriteLn('  open           : FAILED -- ', NetErr);
    Halt(2);
  end;
  Opened := True;

  { --- the request -------------------------------------------------
    48 bytes, and only the first one has to be anything in particular:
    LI = 0 (no warning), VN = 3, Mode = 3 (client) is 00 011 011 = 1Bh.
    Version 3 rather than 4 because every server answers 3 and some old
    ones do not answer 4. Everything else stays zero -- a client has
    nothing useful to say about its own clock when it is asking. }
  FillChar(Pkt, SizeOf(Pkt), 0);
  Pkt[0] := $1B;

  T0 := NetTicks;
  if not NetUdpSend(MY_PORT, NTP_PORT, Pkt, NTP_LEN) then
  begin
    WriteLn('  send           : FAILED -- ', NetErr);
    Bail(1);
  end;

  { Three seconds. A LAN server answers in milliseconds; this is long
    enough for one off the far side of a slow uplink and short enough
    that a wrong address is obvious rather than tedious. }
  if not NetUdpRecv(MY_PORT, Reply, SizeOf(Reply), Got, 54) then
  begin
    WriteLn('  our address    : ', IPStr(NetMyIP), '  ', MacStr(NetMyMac));
    WriteLn('  server         : ', IPStr(Server), '  ', MacStr(NetPeerMac));
    WriteLn('  reply          : NONE -- ', NetErr);
    WriteLn('  frames seen    : ', NetRxFrames, ' accepted, ',
            NetRxWrong, ' not for us, ', NetRxDrop, ' dropped');
    WriteLn;
    WriteLn('  Frames "not for us" with none accepted means the stack is');
    WriteLn('  listening and this server did not answer. Zero of both means');
    WriteLn('  nothing came back at all -- suspect the address or the ARP.');
    Bail(1);
  end;
  T1 := NetTicks;

  NetClose;
  Opened := False;

  WriteLn('  packet driver  : INT ', Hex2(NetVec), 'h');
  WriteLn('  our address    : ', IPStr(NetMyIP), '  ', MacStr(NetMyMac));
  if NetViaGw then
    WriteLn('  server         : ', IPStr(Server), '  via gateway ',
            IPStr(NetGw), ' at ', MacStr(NetPeerMac))
  else
    WriteLn('  server         : ', IPStr(Server), '  ', MacStr(NetPeerMac),
            '  (same subnet)');
  WriteLn('  round trip     : ', T1 - T0, ' ticks  (~',
          ((T1 - T0) * 55), ' ms, 55ms resolution)');
  WriteLn('  reply size     : ', Got, ' bytes');

  if Got < NTP_LEN then
  begin
    WriteLn('  VERDICT        : too short to be NTP -- wanted ', NTP_LEN);
    Halt(1);
  end;

  LI    := Reply[0] shr 6;
  Mode  := Reply[0] and $07;
  Strat := Reply[1];
  WriteLn('  leap / mode    : LI=', LI, '  mode=', Mode,
          '  stratum=', Strat);
  if Mode <> 4 then
  begin
    WriteLn('  NOTE           : mode ', Mode, ' is not 4 (server) -- odd reply');
    RC := 1;
  end;
  if LI = 3 then
  begin
    WriteLn('  NOTE           : LI=3 means the server clock is UNSYNCHRONISED');
    RC := 1;
  end;

  { Transmit timestamp: seconds at bytes 40..43, big-endian, unsigned. }
  Secs := 0;
  for I := 0 to 3 do
    Secs := (Secs shl 8) or LongWord(Reply[40 + I]);

  WriteLn('  NTP seconds    : ', NumU(Secs), '   (since 1900-01-01 UTC)');

  if Secs < EPOCH_OFS then
  begin
    WriteLn('  VERDICT        : timestamp predates 1970 -- not a real answer');
    Halt(1);
  end;

  Unix := Secs - EPOCH_OFS;
  Days := LongInt(Unix div 86400);
  Rem  := Unix mod 86400;
  Hh   := Integer(Rem div 3600);
  Mm   := Integer((Rem mod 3600) div 60);
  Ss   := Integer(Rem mod 60);
  CivilFromDays(Days, Y, Mo, Da);

  WriteLn('  server says    : ', Y, '-', Pad2(Mo), '-', Pad2(Da), ' ',
          Pad2(Hh), ':', Pad2(Mm), ':', Pad2(Ss), '  UTC');

  GetDate(DY, DM, DD, DW);
  GetTime(TH, TM, TS, TC);
  WriteLn('  this DOS clock : ', DY, '-', Pad2(DM), '-', Pad2(DD), ' ',
          Pad2(TH), ':', Pad2(TM), ':', Pad2(TS), '  local');
  WriteLn;
  WriteLn('  Checking this against a second, independent SNTP client is');
  WriteLn('  the real test -- two stacks agreeing on the second means it.');
  WriteLn('  frames seen    : ', NetRxFrames, ' accepted, ',
          NetRxWrong, ' not for us, ', NetRxDrop, ' dropped');

  Halt(RC);
end.
