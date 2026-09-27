{ DOS Bridge  --  StevenC & Claude }
{ uget.pas -- fetch a file from dosd over our own UDP.

    UGET 192.168.1.10 starter/HELLO.EXE C:\WORK\HELLO.EXE
    UGET 192.168.1.10 job C:\AGENT\JOB.BAT POLL

  POLL means the job long-poll: wait much longer for the first packet and do
  NOT retransmit the request. dosd deliberately holds a job request open for
  several seconds, and a retransmit would read as a second poll -- which on a
  queue means quietly taking a second job and dropping the first.

  Exit codes:  0 the file arrived complete
               1 the transfer failed (the reason is printed)
               2 setup failed -- no packet driver, no config, ARP failed

  The exit code is HONEST, and that is a deliberate break with what came
  before: the old fetch tool returned >= 20 even on success, which is why
  every job batch still verifies with IF EXIST rather than trusting an
  errorlevel. Batches can trust this one.

  Anything written against the old behaviour has to be re-read, not assumed.
  AI.BAT's offline branch relied on a failed poll leaving >= 20 behind; when
  that became 1, the branch quit the agent instead of retrying. }

program UGet;

{$MODE OBJFPC}{$H-}

{ NOT "uses About".

  The agent loop runs this every poll, forever, and About prints its
  attribution line from the unit initialisation -- so linking it would
  repaint the banner on the console every eight seconds and scroll the boot
  banner away, which is one of the papercuts this transport was written to
  remove. Same reasoning as KEYHIT.COM being hand-assembled, not an FPC
  program.

  Silent on success for the same reason; pass -V when you want the numbers.
  Failures always print, because a transfer that quietly did nothing is the
  one thing worse than a noisy console. }

uses VidFix, Net, Tftp;   { VidFix: see vidfix.pas -- the runtime can hook INT 10h,
                             which wedges a 386 with no coprocessor. Inert elsewhere. }

var
  Server : TIP;
  Remote : ShortString;
  Local  : ShortString;
  Poll   : Boolean;
  Opened : Boolean;
  I, J   : Integer;
  A      : ShortString;
  Wait   : LongInt;
  Ok     : Boolean;
  Verbose: Boolean;
  NoSpin : Boolean;

{ A heartbeat for the agent loop.

  The loop spends nearly all its life inside one long poll, and with the
  transport gone quiet the console showed nothing at all -- a healthy box and
  a wedged one looked identical, which is the failure this project keeps
  having to design around. The old transport's version chatter used to serve
  that purpose by accident, at the cost of scrolling the boot banner away
  within a minute.

  This is the version that does not scroll: one character followed by a
  backspace, so it animates in place forever and the banner above it stays
  put. The phase comes from the BIOS tick counter, so it needs no state of
  its own and keeps moving at a steady rate whatever the poll is doing.

  #92 rather than a literal backslash so the character cannot be mangled by
  whatever edits this file next. }
const
  SPIN: array[0..3] of Char = ('-', #92, '|', '/');

procedure Heartbeat;
begin
  Write(SPIN[(NetTicks shr 2) and 3], #8);
end;

{ Console hygiene. The screen is 80 columns and the agent loop leaves its
  boot banner on it permanently, so a line that wraps costs two rows and
  reads as damage. Everything printed here is built to fit in 78. }
function Leaf(const S: ShortString): ShortString;
var I: Integer;
begin
  Leaf := S;
  for I := Length(S) downto 1 do
    if (S[I] = '\') or (S[I] = '/') then
    begin
      Leaf := Copy(S, I + 1, Length(S) - I);
      Exit;
    end;
end;

function Fit(const S: ShortString; N: Integer): ShortString;
begin
  if Length(S) <= N then Fit := S else Fit := Copy(S, 1, N);
end;

function UpStr(S: ShortString): ShortString;
var I: Integer;
begin
  for I := 1 to Length(S) do S[I] := UpCase(S[I]);
  UpStr := S;
end;

procedure Bail(Code: Integer);
begin
  { Always, on every path. The driver holds a far pointer to our receiver;
    exiting without releasing leaves it dangling into memory DOS reuses, and
    the next matching frame jumps into it. That is a box with no network,
    recovered only at the keyboard. }
  if Opened then NetClose;
  Halt(Code);
end;

begin
  Opened := False;
  Verbose := False;
  NoSpin := False;
  Poll := False;

  { -INFO answers "what does this machine think its address is, and which
    config did that come from?" without touching the network. The agent's
    boot banner uses it: FIND on the config file needed two lines and one of
    them was a filename header. }
  if (ParamCount >= 1) and (UpStr(ParamStr(1)) = '-INFO') then
  begin
    if not NetReadConfig then
    begin
      WriteLn(' address     : FAILED - ', Fit(NetErr, 50));
      Halt(2);
    end;
    { Label field is 12 wide to match the agent's banner. Two lines printed
      by different programs sitting under one heading look accidental unless
      their colons line up. }
    WriteLn(' address     : ', IPStr(NetMyIP), '   mask ', IPStr(NetMask));
    WriteLn(' gateway     : ', IPStr(NetGw), '   from ', Fit(NetCfgUsed, 40));
    Halt(0);
  end;

  if ParamCount < 3 then
  begin
    WriteLn('usage: UGET <server-ip> <remote-name> <local-file> [POLL] [-V]');
    WriteLn('       UGET -INFO      show configured address and config file');
    Halt(2);
  end;

  if not ParseIP(ParamStr(1), Server) then
  begin
    WriteLn('UGET: "', ParamStr(1), '" is not an IP address (no DNS here)');
    Halt(2);
  end;
  Remote := ParamStr(2);
  Local  := ParamStr(3);
  for I := 4 to ParamCount do
  begin
    A := ParamStr(I);
    for J := 1 to Length(A) do A[J] := UpCase(A[J]);
    if A = 'POLL' then Poll := True;
    if (A = '-V') or (A = '/V') then Verbose := True;
    if A = '-NOSPIN' then NoSpin := True;
  end;

  if not NetReadConfig then
  begin
    WriteLn('UGET: ', NetErr);
    Halt(2);
  end;
  if not NetOpen(Server) then
  begin
    WriteLn('UGET: ', NetErr);
    Halt(2);
  end;
  Opened := True;

  { About six seconds per attempt for a poll, and up to three attempts. That
    is deliberately SHORTER than dosd's eight-second hold: the first attempt
    is expected to time out, resend the request -- which dosd deduplicates --
    and the second attempt then catches the answer. If the first request was
    lost instead, the second one starts the hold and the third catches it.
    Either way a single lost packet costs time, not the poll. }
  { 4 seconds per attempt, three attempts. dosd's TFTP job hold is 2s,
    so the answer normally arrives inside the FIRST attempt -- which
    matters more than it sounds: a long gap between our request and
    its reply lets the server's ARP entry for us expire, and we do not
    answer ARP, so the reply would never reach the wire. }
  { Ask for big blocks on a real fetch; leave the job poll alone. A batch is
    a block or two, and an extra round trip on every poll would cost more
    than it saves. }
  if Poll then TftpWantBlk := 0 else TftpWantBlk := TFTP_BLK_MAX;
  if Poll then Wait := 73 else Wait := 36;
  if Poll and (not NoSpin) then NetIdleHook := @Heartbeat;

  Ok := TftpGet(TFTP_PORT, Remote, Local, Wait, True);

  NetIdleHook := nil;
  { Wipe the spinner so it does not sit under the next line of output. }
  if Poll then Write(' ', #8);

  NetClose;
  Opened := False;

  if not Ok then
  begin
    { A failed POLL is the normal state of a box that cannot reach the
      server, not an event. Reporting it here printed two lines every five
      seconds -- eight pairs during one daemon restart -- which scrolled the
      boot banner away and buried the jobs that had actually run. The agent
      loop says it once instead, and the spinner shows the retries. -V still
      gives the counters, which is what diagnosis needs. }
    if Poll and (not Verbose) then Halt(1);
    WriteLn(' uget: ', Fit(Leaf(Remote), 16), ' FAILED - ', Fit(TftpErr, 40));
    WriteLn('       rx ', NetRxFrames, ' (', NetRxWrong, ' foreign, ',
            NetRxDrop, ' dropped)  tx ', NetTxFrames, ' (', NetTxFail,
            ' refused, ', NetArpSent, ' arp, ', NetArpReplied, ' answered)');
    { The stall measurement. Only interesting when a flow was rebuilt:
      it says what reached the card during the silence. }
    if TftpRestarts > 0 then
      WriteLn('       during ', TftpRestarts, ' stall(s): rx ',
              TftpStallRx, ' seen, ', TftpStallWrong, ' not ours, ',
              TftpStallDrop, ' dropped, ', TftpStrays, ' stray');
    Halt(1);
  end;

  if Verbose then
  begin
    WriteLn(' uget: ', Fit(Leaf(Local), 16), '  ', TftpBytes, ' bytes, ',
            TftpBlocks, ' blocks of ', TftpBlkSize, ', ', TftpResends,
            ' resends');
    WriteLn('       rx ', NetRxFrames, ' (', NetRxWrong, ' foreign, ',
            NetRxDrop, ' dropped)  tx ', NetTxFrames, ' (', NetTxFail,
            ' refused, ', NetArpSent, ' arp, ', NetArpReplied, ' answered)');
    { The stall measurement. Only interesting when a flow was rebuilt:
      it says what reached the card during the silence. }
    if TftpRestarts > 0 then
      WriteLn('       during ', TftpRestarts, ' stall(s): rx ',
              TftpStallRx, ' seen, ', TftpStallWrong, ' not ours, ',
              TftpStallDrop, ' dropped, ', TftpStrays, ' stray');
  end;
  Halt(0);
end.
