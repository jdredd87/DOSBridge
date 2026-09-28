{ tftp.pas -- TFTP over our own UDP, both directions.

  DOS Bridge  --  StevenC & Claude

  WHY TFTP AND NOT HTTP

  Replacing the old fetch and send tools literally would mean writing TCP:
  they were an HTTP client and a raw TCP client. TCP's failure mode is the bad
  one -- correct on the bench, silently corrupting under loss -- and the
  transport is the one
  component of this bridge whose failure cannot be fixed from the Windows
  side. TFTP is the opposite trade: four opcodes, 512-byte blocks, one packet
  in flight at a time, and every failure is a timeout you can see.

  It is also the protocol that was designed for precisely this situation -- a
  machine with no stack that needs to move a file -- which is why it fits the
  bridge's three jobs exactly: fetch a job batch, fetch a program, push a
  result.

  WHY STOP-AND-WAIT MAKES THE DISK SAFE

  Writing to disk while a packet handle is open would normally be a race: a
  frame arriving mid-write is dropped, because the receiver refuses anything
  while Busy is set. Stop-and-wait removes the race entirely -- the server
  does not send block N+1 until it has our ACK for block N, so there is
  nothing on the wire while we are in DOS. That is worth knowing before
  anyone "optimises" this into a windowed transfer.

  Note the receiver never calls DOS itself, so DOS reentrancy is not the
  issue here; the issue is only whether a frame can arrive unheard.

  THE TRANSFER IDENTIFIER

  A TFTP server answers from a NEW ephemeral port, not from the port the
  request was sent to. Every packet after the first must be aimed at that
  port. Keep replying to the well-known port and a correct server ignores
  you -- which looks exactly like a server that is not running. }

unit Tftp;

{$MODE OBJFPC}{$H-}

interface

uses Net;

const
  TFTP_PORT = 8069;          { dosd's TFTP endpoint; 69 needs privilege }
  TFTP_BLK  = 512;
  { RFC 2348. The ceiling is what fits in one Ethernet frame without
    fragmenting -- 1500 - 20 (IP) - 8 (UDP) - 4 (TFTP) = 1468 -- because the
    receiver in Net drops fragments rather than reassembling them. 1400
    leaves headroom and still cuts the packet count by nearly two thirds,
    which on this link is most of the transfer time. }
  TFTP_BLK_MAX = 1400;

  OP_RRQ   = 1;
  OP_WRQ   = 2;
  OP_DATA  = 3;
  OP_ACK   = 4;
  OP_ERROR = 5;
  OP_OACK  = 6;               { RFC 2347 option acknowledgement }

var
  TftpErr     : ShortString;   { why the last call returned False }
  TftpBytes   : LongInt;       { payload bytes transferred }
  TftpBlocks  : LongInt;
  TftpResends : Word;          { our retransmits -- packets we lost }
  TftpDups    : Word;          { blocks re-sent to us -- ACKs they lost }
  TftpRestarts: Integer;       { flows rebuilt mid-transfer after a stall }

  { What the wire looked like WHILE a transfer was stalled.

    This is the measurement the four dead hypotheses in CLAUDE.md never had.
    The stall is: frames stop being delivered to this card partway through a
    transfer, while broadcasts keep arriving. That last clause was an eyeball
    observation, and everything since has been built on it -- so it is worth
    counting properly, because it splits the remaining possibilities cleanly.

      frames arrived, none of them ours  -> the card is still receiving. Our
        packets specifically are not getting through, or are arriving and
        being rejected by our own address/port match. Suspect addressing,
        the server's idea of our port, or the receiver's filter.
      nothing arrived at all             -> the card stopped receiving. Not
        something the client can fix, and not our filter's fault.

    PKTCAP cannot answer this, which is why it is instrumented here instead:
    it would need a second access_type for the same ethertype the transfer is
    using, which the driver is entitled to refuse -- and capturing ALL takes
    frames away from the very transfer being watched. The observer would
    change the thing observed. }
  TftpStallRx   : Word;        { accepted for us during stall windows }
  TftpStallWrong: Word;        { arrived, parsed, not ours }
  TftpStallDrop : Word;        { refused: receiver busy, or oversized }
  { Packets addressed to our port, correctly formed, from a server flow we
    are NOT talking to. Non-zero means the server has more than one thread
    serving this one transfer -- which is what a retransmitted request used
    to cause. See the OACK branch in TftpGet for why that was expensive. }
  TftpStrays    : Word;
  { Set by the caller BEFORE a get: the block size to ask for, or 0 to ask
    for nothing and stay on the 512-byte default. The job poll leaves it at
    0 -- a job batch is a couple of blocks and does not want an extra round
    trip on every poll. }
  TftpWantBlk : Word;
  TftpBlkSize : Word;          { what was actually agreed, 512 if no OACK }
  { windowsize (RFC 7440), for a get: how many blocks the server may send
    before waiting for an ACK.  0 or 1 asks for nothing -- stop-and-wait,
    exactly as before.  Agreed value in TftpWin; TftpGaps counts the times
    a block went missing inside a window. }
  TftpWantWin : Word;
  TftpWin     : Word;
  TftpGaps    : LongInt;
  TftpPeerTID : Word;

{ FirstWait is separate from the per-block timeout because the job poll is a
  long poll: the server deliberately holds the request open for several
  seconds before answering, and treating that as a lost packet would make the
  client retransmit a request the server is still working on. }
function TftpGet(SrvPort: Word; const Remote, Local: ShortString;
                 FirstWait: LongInt; RetryFirst: Boolean): Boolean;
function TftpPut(SrvPort: Word; const Local, Remote: ShortString): Boolean;

implementation

const
  { Budgets sized for a lossy link, and sized to OUTLAST the server's.

    They were 1 second and 5 retries, which gave up after about five seconds
    while dosd was still retransmitting out to ten -- so a burst of loss
    ended the transfer even though the other end had not finished trying.
    Whichever side gives up first decides the outcome, so the client must be
    the more patient of the two. Measured on this PicoMEM WiFi link: bursts
    of three or more consecutive losses of the same block do happen. }
  TIMEOUT_TICKS = 36;        { ~2 seconds at 18.2 Hz }
  { 10 x 2s. This was raised to 60 while hunting the large-transfer
    failures and it made no difference at all -- which was itself the
    proof that the bug was a deadlock in the SERVER's send loop and
    not a shortage of patience here. More retries meant more stale
    ACKs, which was exactly what kept the server from retransmitting. }
  MAX_RETRIES   = 10;        { ~20 seconds of trying }
  { Requests get their own, smaller budget. Each attempt at a request may
    wait many seconds -- the job poll is a long poll -- so five of them would
    be half a minute of silence before the caller heard anything. }
  MAX_RQ_TRIES  = 2;
  { A stall is spotted long before the flow is given up on. Three silent
    timeouts is six seconds; waiting out all of MAX_RETRIES first would cost
    twenty seconds per stall, which is unaffordable on a file that stalls
    every 45 KB. }
  RESTART_AFTER = 3;
  MAX_RESTARTS  = 250;
  { Restarts that moved no data AT ALL, consecutively, before giving up.

    MAX_RESTARTS alone is not a timeout, and treating it as one is what made
    this machine look like it was freezing. 250 restarts at roughly six
    seconds each is twenty-five minutes of silent grinding, plus an ARP on
    every one -- and the observed "hangs" were 10, 43 and 48 minutes of a box
    that had simply stopped polling. It was never wedged. It was still trying.

    The count is right for what it was sized for: a 5 MB file over a link that
    genuinely stalls every 45 KB needs about 110 restarts, and each of those
    moves data. It is catastrophic for a peer that is not there, because a
    restart count cannot tell "slow and lossy" from "gone".

    So budget restarts against PROGRESS instead. A restart that recovers even
    one block is the fault this mechanism was built for and costs nothing from
    this budget; a run of restarts that move nothing is a dead peer, and three
    of those is about twenty seconds -- after which the caller fails, the
    agent's offline branch takes over, and the box keeps polling. }
  DEAD_RESTARTS = 3;

type
  { Sized for the largest block we will ever negotiate, plus TFTP and
    slack. Two of these is about 2.9 KB of the 514 KB heap. }
  TBuf = array[0 .. TFTP_BLK_MAX + 63] of Byte;

const
  { Received blocks are gathered here and written 12 at a time.  One
    1400-byte write per block cost ~14 ms of the 59 ms each block took on
    the V30 (2026-09-27): every write straddles sectors, so DOS reads,
    patches and rewrites a partial one each time.  Twelve blocks per write
    turns most of that into whole-sector writes.  Still stop-and-wait: a
    block is ACKed only once it is in the buffer or on the disk, so nothing
    is on the wire while we are in DOS. }
  WBUF_SIZE = 12 * TFTP_BLK_MAX;

var
  Pkt  : TBuf;               { outgoing }
  RxP  : TBuf;               { incoming }
  WBuf : array[0 .. WBUF_SIZE - 1] of Byte;
  WLen : Word;
  { A put reads the file through the same buffer, 16.8 KB at a time: a get
    and a put never run at once. }
  RLen, RPos : Word;
  MyPort : Word;

function Num(L: LongInt): ShortString;
var S: ShortString;
begin
  Str(L, S);
  Num := S;
end;

procedure PutW(var P: TBuf; Ofs, V: Word);
begin
  P[Ofs] := Hi(V);
  P[Ofs + 1] := Lo(V);
end;

function GetW(var P: TBuf; Ofs: Word): Word;
begin
  GetW := (Word(P[Ofs]) shl 8) or P[Ofs + 1];
end;

{ Pick a source port that changes run to run. A fixed one would happily
  accept a straggler from the PREVIOUS transfer -- a duplicate ACK arriving
  late is enough to desynchronise a stop-and-wait exchange. }
procedure PickPort;
begin
  MyPort := 20000 + Word(NetTicks and $0FFF);
end;

{ RRQ/WRQ: opcode, filename, 0, "octet", 0. netascii is not offered -- it
  rewrites line endings, and this moves .EXE files. }
{ Pull blksize out of an OACK. Anything we asked for that is not echoed
  keeps its default, which is what RFC 2347 requires and what lets this talk
  to a server that only understands some of the options. }
{ The value the server gave option Name in its OACK, if it is within Lo..Hi;
  else Default.  OackBlkSize is the same thing for one option. }
function OackOpt(Len: Word; const Name: ShortString; Lo, Hi, Default: Word): Word;
var
  I    : Word;
  S    : ShortString;
  V    : LongInt;
  Code : Integer;
  Want : Boolean;
begin
  OackOpt := Default;
  Want := False;
  I := 2;
  while I < Len do
  begin
    S := '';
    while (I < Len) and (RxP[I] <> 0) do
    begin
      if Length(S) < 40 then S := S + UpCase(Chr(RxP[I]));
      Inc(I);
    end;
    Inc(I);
    if Want then
    begin
      Val(S, V, Code);
      if (Code = 0) and (V >= Lo) and (V <= Hi) then
        OackOpt := Word(V);
      Want := False;
    end
    else if S = Name then
      Want := True;
  end;
end;

function OackBlkSize(Len: Word): Word;
var
  I    : Word;
  S    : ShortString;
  V    : LongInt;
  Code : Integer;
  Want : Boolean;
begin
  OackBlkSize := TFTP_BLK;
  Want := False;
  I := 2;
  while I < Len do
  begin
    S := '';
    while (I < Len) and (RxP[I] <> 0) do
    begin
      if Length(S) < 40 then S := S + UpCase(Chr(RxP[I]));
      Inc(I);
    end;
    Inc(I);                    { step over the terminator }
    if Want then
    begin
      Val(S, V, Code);
      if (Code = 0) and (V >= 8) and (V <= TFTP_BLK_MAX) then
        OackBlkSize := Word(V);
      Want := False;
    end
    else if S = 'BLKSIZE' then
      Want := True;
  end;
end;

function BuildRQ(Op: Word; const Name: ShortString): Word;
var
  I, N: Word;
  Opt : ShortString;

  procedure PutZ(const S: ShortString);
  var K: Word;
  begin
    for K := 1 to Length(S) do
    begin
      Pkt[N] := Ord(S[K]);
      Inc(N);
    end;
    Pkt[N] := 0;
    Inc(N);
  end;

begin
  PutW(Pkt, 0, Op);
  N := 2;
  for I := 1 to Length(Name) do
  begin
    Pkt[N] := Ord(Name[I]);
    Inc(N);
  end;
  Pkt[N] := 0; Inc(N);
  Pkt[N] := Ord('o'); Inc(N);
  Pkt[N] := Ord('c'); Inc(N);
  Pkt[N] := Ord('t'); Inc(N);
  Pkt[N] := Ord('e'); Inc(N);
  Pkt[N] := Ord('t'); Inc(N);
  Pkt[N] := 0; Inc(N);
  { An option the server does not understand is ignored and it simply sends
    512-byte blocks, so asking costs nothing against an older dosd. }
  if TftpWantBlk > 0 then
  begin
    Opt := 'blksize';
    PutZ(Opt);
    Opt := Num(TftpWantBlk);
    PutZ(Opt);
  end;
  if TftpWantWin > 1 then
  begin
    Opt := 'windowsize';
    PutZ(Opt);
    Opt := Num(TftpWantWin);
    PutZ(Opt);
  end;
  BuildRQ := N;
end;

{ An ERROR packet carries a NUL-terminated human message after the code.
  Reporting it verbatim is the difference between "the transfer failed" and
  "file not found" -- and the server is the only one that knows which. }
function ErrText(Got: Word): ShortString;
var
  S: ShortString;
  I: Word;
begin
  S := '';
  I := 4;
  while (I < Got) and (RxP[I] <> 0) and (Length(S) < 200) do
  begin
    S := S + Chr(RxP[I]);
    Inc(I);
  end;
  if Length(S) > 40 then S := Copy(S, 1, 40);
  ErrText := 'server said: ' + S;
end;

{ The gathered blocks to the file.  False if the disk would not take them. }
function FlushW(var F: file): Boolean;
var
  Wrote: Word;
begin
  FlushW := True;
  if WLen = 0 then Exit;
  {$I-}
  BlockWrite(F, WBuf, WLen, Wrote);
  {$I+}
  if (IOResult <> 0) or (Wrote <> WLen) then FlushW := False;
  WLen := 0;
end;

{ N bytes (fewer at the end of the file) from the file into Dest, through
  WBuf.  -1 if the disk would not read. }
function ReadBlk(var F: file; var Dest; N: Word): Integer;
var
  Got, Take, R: Word;
  D: PByte;
begin
  D := @Dest;
  Got := 0;
  while Got < N do
  begin
    if RPos >= RLen then
    begin
      {$I-}
      BlockRead(F, WBuf, WBUF_SIZE, R);
      {$I+}
      if IOResult <> 0 then
      begin
        ReadBlk := -1;
        Exit;
      end;
      RLen := R;
      RPos := 0;
      if R = 0 then Break;
    end;
    Take := RLen - RPos;
    if Take > N - Got then Take := N - Got;
    Move(WBuf[RPos], D[Got], Take);
    Inc(RPos, Take);
    Inc(Got, Take);
  end;
  ReadBlk := Got;
end;

function TftpGet(SrvPort: Word; const Remote, Local: ShortString;
                 FirstWait: LongInt; RetryFirst: Boolean): Boolean;
var
  F        : file;
  FOpen    : Boolean;
  RQLen    : Word;
  Got      : Word;
  Op, Blk  : Word;
  Expect   : Word;
  Tries    : Integer;
  DeadRuns : Integer;          { consecutive restarts that moved nothing }
  DeadMark : LongInt;          { TftpBytes as of the last restart }
  MarkRx, MarkWr, MarkDr : Word;   { receiver counters at the last restart }
  DataLen  : Word;
  Wrote    : Integer;
  Wait     : LongInt;
  MaxRq    : Integer;
  Done     : Boolean;
  Peer     : TIP;
  InWin    : Word;             { in-order blocks since our last ACK }
  Diff     : SmallInt;         { where a block is relative to Expect }
  Last     : Boolean;
  DupAcked, GapAcked : Boolean;
begin
  TftpGet := False;
  TftpErr := '';
  TftpBytes := 0; TftpBlocks := 0; TftpResends := 0; TftpDups := 0;
  TftpPeerTID := 0;
  FOpen := False;
  Done := False;
  WLen := 0;
  TftpWin := 1; InWin := 0; TftpGaps := 0;
  DupAcked := False; GapAcked := False;

  PickPort;
  RQLen := BuildRQ(OP_RRQ, Remote);

  {$I-}
  Assign(F, Local);
  Rewrite(F, 1);
  {$I+}
  if IOResult <> 0 then
  begin
    TftpErr := 'cannot create ' + Local;
    Exit;
  end;
  FOpen := True;

  if not NetUdpSend(MyPort, SrvPort, Pkt, RQLen) then
  begin
    TftpErr := NetErr;
    Close(F);
    Erase(F);
    Exit;
  end;

  Expect := 1;
  Tries  := 0;
  Wait   := FirstWait;
  TftpStallRx := 0; TftpStallWrong := 0; TftpStallDrop := 0;
  TftpStrays := 0;
  MarkRx := NetRxFrames; MarkWr := NetRxWrong; MarkDr := NetRxDrop;
  DeadRuns := 0;
  DeadMark := -1;
  TftpRestarts := 0;
  Peer := NetPeerIP;
  TftpBlkSize := TFTP_BLK;

  while not Done do
  begin
    if not NetUdpRecv(MyPort, RxP, SizeOf(RxP), Got, Wait) then
    begin
      { Nothing arrived. Resend whatever we last said and try again -- except
        for the very first request when the caller told us not to, which is
        the long-poll case: the server is holding the request deliberately
        and a retransmit would make it look like a second poll. }
      Inc(Tries);
      if TftpPeerTID = 0 then
      begin
        { Still waiting for the first packet, so it is the REQUEST that went
          missing (or is still being held). Resending is safe even for the
          long poll, because dosd ignores a repeat request from a client it
          is already holding one for -- without that deduplication a
          retransmit would start a second hold and take a second job. }
        if not RetryFirst then MaxRq := 0 else MaxRq := MAX_RQ_TRIES;
        if Tries > MaxRq then
        begin
          TftpErr := 'no reply after ' + Num(Tries) + ' requests';
          Break;
        end;
        Inc(TftpResends);
        RQLen := BuildRQ(OP_RRQ, Remote);
        NetUdpSend(MyPort, SrvPort, Pkt, RQLen);
        Wait := FirstWait;
      end
      else
      begin
        { Silence begins HERE, not at the previous restart.

          The first version marked the counters at transfer start and took the
          delta at the restart, so the "stall window" for the first stall
          spanned the entire successful transfer before it -- and duly
          reported a hundred frames as having arrived during the silence.
          They were the good blocks. A window that includes the thing it is
          meant to exclude measures nothing. }
        { Tries = 1, not 0: Inc(Tries) runs BEFORE this branch, so testing
          for 0 here can never fire and the mark silently stayed at its
          transfer-start value -- which is the same artifact this was written
          to remove, a second time. }
        if Tries = 1 then
        begin
          MarkRx := NetRxFrames; MarkWr := NetRxWrong; MarkDr := NetRxDrop;
        end;

        { A stall on this link is not a lost packet. The server keeps
          sending -- its own trace shows the block going out again on every
          duplicate ACK we send -- and none of it reaches us, while broadcast
          frames keep arriving perfectly well throughout. Re-taking the
          packet driver handle does not help, and nor does putting the card
          into promiscuous mode so it accepts every frame on the wire. Both
          were built, measured and removed.

          What always works is a completely fresh flow: every transfer that
          stalled succeeded on the next attempt. So build one here rather
          than making the caller do it -- drop the handle and the ARP state,
          take a new local port, and ask for the rest of the file from where
          we got to. The file stays open and we keep appending, so nothing
          already received is fetched twice. }
        if (Tries >= RESTART_AFTER) and (TftpRestarts < MAX_RESTARTS) then
        begin
          { What reached the card during the silence just ended -- from the
            first missed reply to now, and nothing before it. }
          Inc(TftpStallRx,    NetRxFrames - MarkRx);
          Inc(TftpStallWrong, NetRxWrong  - MarkWr);
          Inc(TftpStallDrop,  NetRxDrop   - MarkDr);
          MarkRx := NetRxFrames; MarkWr := NetRxWrong; MarkDr := NetRxDrop;

          { Did the last flow achieve anything? }
          if TftpBytes = DeadMark then
            Inc(DeadRuns)
          else
            DeadRuns := 0;
          DeadMark := TftpBytes;
          if DeadRuns > DEAD_RESTARTS then
          begin
            TftpErr := 'no answer from the server';
            Break;
          end;
          Inc(TftpRestarts);
          NetClose;
          if not NetOpen(Peer) then
          begin
            TftpErr := 'lost the network at block ' + Num(Expect);
            Break;
          end;
          PickPort;
          TftpPeerTID := 0;
          Expect := 1;
          Tries  := 0;
          Wait   := FirstWait;
          { The new flow negotiates from scratch, so do not assume the size
            the old one agreed to. }
          TftpBlkSize := TFTP_BLK;
          TftpWin := 1; InWin := 0;
          DupAcked := False; GapAcked := False;
          RQLen := BuildRQ(OP_RRQ, Remote + '@' + Num(TftpBytes));
          if not NetUdpSend(MyPort, SrvPort, Pkt, RQLen) then
          begin
            TftpErr := NetErr;
            Break;
          end;
          Continue;
        end;
        if Tries > MAX_RETRIES then
        begin
          TftpErr := 'stalled at block ' + Num(Expect);
          Break;
        end;
        Inc(TftpResends);
        PutW(Pkt, 0, OP_ACK);
        PutW(Pkt, 2, Expect - 1);
        NetUdpSend(MyPort, TftpPeerTID, Pkt, 4);
        Wait := TIMEOUT_TICKS;
        InWin := 0;             { the server starts its window again at Expect }
        DupAcked := False; GapAcked := False;
      end;
      Continue;
    end;

    if Got < 4 then Continue;
    Op := GetW(RxP, 0);

    if Op = OP_ERROR then
    begin
      { Same rule as an OACK, and here it is the difference between a
        transfer that survives and one that does not: an ERROR ends the
        whole thing, so honouring one from a flow we are not talking to
        would let a phantom kill a transfer that was going perfectly. }
      if (TftpPeerTID <> 0) and (NetFromPort <> TftpPeerTID) then
      begin
        Inc(TftpStrays);
        Continue;
      end;
      TftpErr := ErrText(Got);
      Break;
    end;
    if Op = OP_OACK then
    begin
      { An OACK from a port we are NOT locked on to is a second server flow
        talking to us, and it must be ignored as completely as a stray DATA
        block is -- which this branch used to fail to do, because only the
        DATA branch below checked the TID.

        The way a second flow arises: a retransmitted request. dosd spawns a
        thread with a fresh socket for every RRQ and deduplicated only the
        job poll, so when our first request went missing (or was merely
        slow) the retransmit -- sent from the SAME local port, so it looks
        identical to the server -- started a second flow serving the same
        file. Both then OACKed us. We locked on to whichever arrived first
        and the loser spent its whole 8x2s budget re-OACKing a client that
        was never going to answer, which is where every `did not confirm
        blksize 1400` in dosd.log came from.

        Accepting those strays cost more than the noise, and this is the
        expensive part: `Tries := 0` below. A stray arriving every two
        seconds reset the stall counter every two seconds, so `Tries` could
        never reach RESTART_AFTER and the rebuild-the-flow recovery -- the
        one mechanism that has ever cleared this link's stall -- was held
        off for exactly as long as the phantom kept talking. The transfer
        sat in a stall it had been carefully taught to escape.

        It also re-ACKed block 0 to the REAL flow on every stray, which that
        flow reads as a duplicate ACK for an earlier block and answers with
        an immediate retransmit of the block in flight. So each phantom OACK
        also bought a duplicate DATA block, on a link whose receiver holds
        one frame at a time.

        dosd no longer starts the second flow (it drops a request it is
        already serving, the way it always has for the job poll), but the
        check belongs here too: this client has to be safe against an older
        daemon, and a stray is cheap to ignore and expensive to obey. }
      if (TftpPeerTID <> 0) and (NetFromPort <> TftpPeerTID) then
      begin
        Inc(TftpStrays);
        Continue;
      end;
      { The server accepted our options. Lock on to its transfer port, take
        the block size it agreed to, and ACK block 0 -- that ACK is what
        tells it to start sending. }
      if TftpPeerTID = 0 then TftpPeerTID := NetFromPort;
      TftpBlkSize := OackBlkSize(Got);
      { At most as many blocks as the write buffer holds: the disk is only
        written between windows, while the server waits for our ACK. }
      TftpWin := OackOpt(Got, 'WINDOWSIZE', 1, WBUF_SIZE div TFTP_BLK_MAX, 1);
      InWin := 0;
      PutW(Pkt, 0, OP_ACK);
      PutW(Pkt, 2, 0);
      NetUdpSend(MyPort, TftpPeerTID, Pkt, 4);
      Tries := 0;
      Wait  := TIMEOUT_TICKS;
      Continue;
    end;
    if Op <> OP_DATA then Continue;

    { Lock on to the server's transfer port the first time we hear from it,
      and ignore anything from a different one afterwards. }
    if TftpPeerTID = 0 then
      TftpPeerTID := NetFromPort
    else if NetFromPort <> TftpPeerTID then
    begin
      Inc(TftpStrays);
      Continue;
    end;

    Blk     := GetW(RxP, 2);
    DataLen := Got - 4;
    Diff    := SmallInt(Blk - Expect);    { block numbers wrap at 65536 }

    if Diff = 0 then
    begin
      DupAcked := False; GapAcked := False;
      if DataLen > 0 then
      begin
        { With a window of one the server is waiting, so writing here is
          safe.  With a bigger one this never fires: the buffer is emptied
          at each window's end so that a whole window fits. }
        if WLen + DataLen > WBUF_SIZE then
          if not FlushW(F) then
          begin
            TftpErr := 'write failed at block ' + Num(Blk) + ' (disk full?)';
            Break;
          end;
        Move(RxP[4], WBuf[WLen], DataLen);
        Inc(WLen, DataLen);
        TftpBytes := TftpBytes + DataLen;
      end;
      Inc(TftpBlocks);
      Inc(InWin);
      { A short block is the end of the transfer, by definition. A file that
        is an exact multiple of the block size ends with a zero-length one. }
      Last := DataLen < TftpBlkSize;

      if Last or (InWin >= TftpWin) then
      begin
        { The end of a window (or of the file): the server now waits for this
          ACK, so this is the moment to write -- everything at the end, so a
          "done" the server hears means the file is complete; otherwise
          enough to make room for the next window. }
        if Last or (WLen + LongInt(TftpWin) * TftpBlkSize > WBUF_SIZE) then
          if not FlushW(F) then
          begin
            TftpErr := 'write failed at block ' + Num(Blk) + ' (disk full?)';
            Break;
          end;
        PutW(Pkt, 0, OP_ACK);
        PutW(Pkt, 2, Blk);
        NetUdpSend(MyPort, TftpPeerTID, Pkt, 4);
        InWin := 0;
      end;

      if Last then
      begin
        Done := True;
        TftpGet := True;
      end;
      Inc(Expect);
      Tries := 0;
      Wait := TIMEOUT_TICKS;
    end
    else if Diff < 0 then
    begin
      { A block we already have: the server did not hear our ACK and sent it
        again. Re-ACK the last one we have WITHOUT writing, or the file gains
        a duplicate -- the classic way a stop-and-wait transfer corrupts
        silently.  Once per burst when windowed: a whole resent window would
        otherwise draw an ACK for every block, each one restarting it. }
      Inc(TftpDups);
      if (TftpWin <= 1) or not DupAcked then
      begin
        PutW(Pkt, 0, OP_ACK);
        PutW(Pkt, 2, Expect - 1);
        NetUdpSend(MyPort, TftpPeerTID, Pkt, 4);
        DupAcked := True;
        InWin := 0;
      end;
    end
    else if TftpWin > 1 then
    begin
      { A block went missing inside the window: ACK the last one we have,
        once, and the server starts again from the one after it.  The rest
        of this window, still arriving, is ignored until it does. }
      if not GapAcked then
      begin
        Inc(TftpGaps);
        PutW(Pkt, 0, OP_ACK);
        PutW(Pkt, 2, Expect - 1);
        NetUdpSend(MyPort, TftpPeerTID, Pkt, 4);
        GapAcked := True;
        InWin := 0;
      end;
    end;
    { Anything else is a stray from an older exchange: ignore it. }
  end;

  if FOpen then
  begin
    {$I-}
    Close(F);
    {$I+}
    if IOResult <> 0 then ;
    { A failed download leaves no file behind. Half a program on disk that
      IF EXIST will happily find is worse than none -- the job batches test
      for existence, not for correctness. }
    if not Done then
    begin
      {$I-}
      Assign(F, Local);
      Erase(F);
      {$I+}
      if IOResult <> 0 then ;
    end;
  end;
end;

function TftpPut(SrvPort: Word; const Local, Remote: ShortString): Boolean;
var
  F       : file;
  FOpen   : Boolean;
  RQLen   : Word;
  Got     : Word;
  Op, Blk : Word;
  Block   : Word;
  Tries   : Integer;
  DeadRuns: Integer;           { consecutive restarts that moved nothing }
  DeadMark: LongInt;           { TftpBytes as of the last restart }
  MarkRx, MarkWr, MarkDr : Word;   { receiver counters at the last restart }
  ReadLen : Integer;
  Done    : Boolean;
  Sent    : Boolean;
  Restart : Boolean;
  LastLen : Word;
  Peer    : TIP;
  RQName  : ShortString;
  SentN, Moved : Word;         { windowed: blocks sent this window, and ACKed }
  D       : SmallInt;
  Final, Fatal, Heard, Silent : Boolean;

  { The write request, and the wait for whatever opens the transfer: an ACK
    of block 0, or an OACK if the server took our options. Factored out
    because a flow rebuilt after a stall has to do the whole thing again, and
    two hand-copied versions of a handshake is how they drift. }
  function Handshake: Boolean;
  var T: Integer;
  begin
    Handshake := False;
    TftpWin := 1;               { unless the OACK says otherwise }
    T := 0;
    while TftpPeerTID = 0 do
    begin
      if NetUdpRecv(MyPort, RxP, SizeOf(RxP), Got, TIMEOUT_TICKS) then
      begin
        if Got >= 4 then
        begin
          Op := GetW(RxP, 0);
          if Op = OP_ERROR then
          begin
            TftpErr := ErrText(Got);
            Exit;
          end;
          { An OACK opens the write in place of ACK 0 (RFC 2347). Unlike a
            read we do not answer it -- the first DATA block is the answer. }
          if Op = OP_OACK then
          begin
            TftpBlkSize := OackBlkSize(Got);
            TftpWin := OackOpt(Got, 'WINDOWSIZE', 1, 8, 1);
            TftpPeerTID := NetFromPort;
          end
          else if (Op = OP_ACK) and (GetW(RxP, 2) = 0) then
            TftpPeerTID := NetFromPort;
        end;
      end
      else
      begin
        Inc(T);
        if T > MAX_RETRIES then
        begin
          TftpErr := 'no ACK for the write request';
          Exit;
        end;
        Inc(TftpResends);
        RQLen := BuildRQ(OP_WRQ, RQName);
        NetUdpSend(MyPort, SrvPort, Pkt, RQLen);
      end;
    end;
    Handshake := True;
  end;

  { Back to the first byte the server has not acknowledged, forgetting what
    was read ahead.  False (TftpErr set) if the file will not seek. }
  function Rewind: Boolean;
  begin
    {$I-}
    Seek(F, TftpBytes);
    {$I+}
    RLen := 0;
    RPos := 0;
    Rewind := IOResult = 0;
    if IOResult <> 0 then ;
    if not Rewind then TftpErr := 'seek failed on ' + Local;
  end;

begin
  TftpPut := False;
  TftpErr := '';
  TftpGaps := 0;
  TftpBytes := 0; TftpBlocks := 0; TftpResends := 0; TftpDups := 0;
  TftpPeerTID := 0;
  TftpBlkSize := TFTP_BLK;
  TftpStallRx := 0; TftpStallWrong := 0; TftpStallDrop := 0;
  TftpStrays := 0;
  MarkRx := NetRxFrames; MarkWr := NetRxWrong; MarkDr := NetRxDrop;
  DeadRuns := 0;
  DeadMark := -1;
  TftpRestarts := 0;
  Peer := NetPeerIP;
  Done := False;
  Restart := False;

  {$I-}
  Assign(F, Local);
  Reset(F, 1);
  {$I+}
  if IOResult <> 0 then
  begin
    TftpErr := 'cannot open ' + Local;
    Exit;
  end;
  FOpen := True;

  PickPort;
  RQName := Remote;
  RQLen := BuildRQ(OP_WRQ, RQName);
  if not NetUdpSend(MyPort, SrvPort, Pkt, RQLen) then
  begin
    TftpErr := NetErr;
    Close(F);
    Exit;
  end;
  if not Handshake then
  begin
    Close(F);
    Exit;
  end;

  Block   := 1;
  LastLen := TftpBlkSize;
  RLen := 0;
  RPos := 0;
  Tries := 0;
  while not Done do
  begin
    if Restart then
    begin
      Inc(TftpRestarts);
      Restart := False;
      NetClose;
      if not NetOpen(Peer) then
      begin
        TftpErr := NetErr;
        Break;
      end;
      PickPort;
      TftpPeerTID := 0;
      { The new flow negotiates from scratch, so do not carry over the size
        the old one agreed to. }
      TftpBlkSize := TFTP_BLK;
      RQName := Remote + '@' + Num(TftpBytes);
      RQLen  := BuildRQ(OP_WRQ, RQName);
      if not NetUdpSend(MyPort, SrvPort, Pkt, RQLen) then
      begin
        TftpErr := NetErr;
        Break;
      end;
      if not Handshake then Break;
      { Rewind to what the server has actually acknowledged. Anything sent
        but unacked goes again -- at worst a duplicate, which the server
        re-ACKs and discards rather than appending. }
      {$I-}
      Seek(F, TftpBytes);
      {$I+}
      RLen := 0;                  { what was read ahead is from before }
      RPos := 0;
      if IOResult <> 0 then
      begin
        TftpErr := 'seek failed on ' + Local;
        Break;
      end;
      Block := 1;
      Continue;
    end;

    { ---- windowed (dosd granted windowsize): up to TftpWin blocks, then
      the ACK that says how far the server got.  A gap is sent again from
      the first block it lacks, re-read from the file: gaps are rare, and a
      seek is cheaper than holding a window of blocks in memory. }
    if TftpWin > 1 then
    begin
      SentN := 0; Final := False; Fatal := False;
      while (SentN < TftpWin) and not Final do
      begin
        ReadLen := ReadBlk(F, Pkt[4], TftpBlkSize);
        if ReadLen < 0 then
        begin
          TftpErr := 'read failed on ' + Local;
          Fatal := True;
          Break;
        end;
        LastLen := Word(ReadLen);
        PutW(Pkt, 0, OP_DATA);
        PutW(Pkt, 2, Block + SentN);
        NetUdpSend(MyPort, TftpPeerTID, Pkt, 4 + LastLen);
        Inc(SentN);
        if LastLen < TftpBlkSize then Final := True;
      end;
      if Fatal then Break;

      Moved := 0; Heard := False; Silent := False;
      while not Heard do
      begin
        if NetUdpRecv(MyPort, RxP, SizeOf(RxP), Got, TIMEOUT_TICKS) then
        begin
          if Got >= 4 then
          begin
            Op := GetW(RxP, 0);
            if Op = OP_ERROR then
            begin
              TftpErr := ErrText(Got);
              Fatal := True;
              Heard := True;
            end
            else if (Op = OP_ACK) and (NetFromPort = TftpPeerTID) then
            begin
              { how many of this window's blocks it has: 0 .. SentN }
              D := SmallInt(GetW(RxP, 2) - (Block - 1));
              if (D >= 0) and (D <= SmallInt(SentN)) then
              begin
                Moved := Word(D);
                Heard := True;
              end;
              { anything else is an ACK from an older window: keep waiting }
            end;
          end;
        end
        else
        begin
          Silent := True;
          Heard := True;
        end;
      end;
      if Fatal then Break;

      if Silent then
      begin
        if Tries = 0 then
        begin
          MarkRx := NetRxFrames; MarkWr := NetRxWrong; MarkDr := NetRxDrop;
        end;
        Inc(Tries);
        if (Tries >= RESTART_AFTER) and (TftpRestarts < MAX_RESTARTS) then
        begin
          Inc(TftpStallRx,    NetRxFrames - MarkRx);
          Inc(TftpStallWrong, NetRxWrong  - MarkWr);
          Inc(TftpStallDrop,  NetRxDrop   - MarkDr);
          MarkRx := NetRxFrames; MarkWr := NetRxWrong; MarkDr := NetRxDrop;
          if TftpBytes = DeadMark then
            Inc(DeadRuns)
          else
            DeadRuns := 0;
          DeadMark := TftpBytes;
          if DeadRuns > DEAD_RESTARTS then
          begin
            TftpErr := 'no answer from the server';
            Break;
          end;
          Restart := True;
          Tries := 0;
          Continue;
        end;
        if Tries > MAX_RETRIES then
        begin
          TftpErr := 'stalled at block ' + Num(Block);
          Break;
        end;
        Inc(TftpResends);
        if not Rewind then Break;     { the window again, from what it has }
        Continue;
      end;

      Tries := 0;
      if Moved > 0 then
      begin
        if (Moved = SentN) and Final then
          TftpBytes := TftpBytes + LongInt(Moved - 1) * TftpBlkSize + LastLen
        else
          TftpBytes := TftpBytes + LongInt(Moved) * TftpBlkSize;
        Inc(TftpBlocks, Moved);
        Inc(Block, Moved);
      end;
      if Moved = SentN then
      begin
        { the whole window arrived: the file is already where the next
          window starts -- or that was the end of it }
        if Final then
        begin
          Done := True;
          TftpPut := True;
        end;
      end
      else
      begin
        Inc(TftpGaps);                { a block went missing: from there }
        if not Rewind then Break;
      end;
      Continue;
    end;

    ReadLen := ReadBlk(F, Pkt[4], TftpBlkSize);
    if ReadLen < 0 then
    begin
      TftpErr := 'read failed on ' + Local;
      Break;
    end;
    LastLen := Word(ReadLen);
    PutW(Pkt, 0, OP_DATA);
    PutW(Pkt, 2, Block);

    Tries := 0;
    Sent  := False;
    NetUdpSend(MyPort, TftpPeerTID, Pkt, 4 + LastLen);

    while not Sent do
    begin
      if NetUdpRecv(MyPort, RxP, SizeOf(RxP), Got, TIMEOUT_TICKS) then
      begin
        if Got >= 4 then
        begin
          Op := GetW(RxP, 0);
          if Op = OP_ERROR then
          begin
            TftpErr := ErrText(Got);
            Close(F);
            Exit;
          end;
          if (Op = OP_ACK) and (NetFromPort = TftpPeerTID) then
          begin
            Blk := GetW(RxP, 2);
            if Blk = Block then Sent := True
            else
            begin
              { A duplicate ACK for an EARLIER block means the block we are
                sending never arrived. Resend it now -- and do NOT let it
                count towards a restart: a duplicate ACK is proof the far end
                is alive and listening, which is the opposite of a stall.

                Counting the duplicate and looping -- which is what this did
                -- goes back to waiting with a fresh two-second timer. The
                server, having timed out, re-ACKs the last block it holds
                every two seconds, and each of those restarted this timer, so
                we never reached our own timeout and never retransmitted while
                it sat waiting for a block that was never coming. That is the
                same deadlock that broke every large DOWNLOAD until dosd
                stopped doing exactly this, mirrored into the upload path. }
              Inc(TftpDups);
              Inc(Tries);
              if Tries > MAX_RETRIES then
              begin
                TftpErr := 'stalled at block ' + Num(Block);
                Close(F);
                Exit;
              end;
              Inc(TftpResends);
              PutW(Pkt, 0, OP_DATA);
              PutW(Pkt, 2, Block);
              NetUdpSend(MyPort, TftpPeerTID, Pkt, 4 + LastLen);
            end;
          end;
        end;
      end
      else
      begin
        if Tries = 0 then
        begin
          MarkRx := NetRxFrames; MarkWr := NetRxWrong; MarkDr := NetRxDrop;
        end;
        Inc(Tries);
        { Silence, repeatedly. This is the link fault that no amount of
          retrying fixes -- frames stop being delivered to this card partway
          through a transfer while broadcasts keep arriving -- and the only
          thing that has ever cleared it is a completely fresh flow. The
          download path has done this since the 5 MB transfers were made to
          work; without it here a large `dospull` simply fails, which is
          exactly what it did the first time one was tried. }
        if (Tries >= RESTART_AFTER) and (TftpRestarts < MAX_RESTARTS) then
        begin
          { What reached the card during the silence just ended -- same
            measurement as the read path, since a dospull stalls too. }
          Inc(TftpStallRx,    NetRxFrames - MarkRx);
          Inc(TftpStallWrong, NetRxWrong  - MarkWr);
          Inc(TftpStallDrop,  NetRxDrop   - MarkDr);
          MarkRx := NetRxFrames; MarkWr := NetRxWrong; MarkDr := NetRxDrop;

          { Same rule as the read path: a restart that shifted no bytes at all
            means the far end is gone, not slow. }
          if TftpBytes = DeadMark then
            Inc(DeadRuns)
          else
            DeadRuns := 0;
          DeadMark := TftpBytes;
          if DeadRuns > DEAD_RESTARTS then
          begin
            TftpErr := 'no answer from the server';
            Close(F);
            Exit;
          end;
          Restart := True;
          Sent    := True;          { leave the inner loop, not the transfer }
        end
        else if Tries > MAX_RETRIES then
        begin
          TftpErr := 'stalled at block ' + Num(Block);
          Close(F);
          Exit;
        end
        else
        begin
          Inc(TftpResends);
          { Rebuild: RxP and Pkt are separate buffers, so Pkt still holds the
            block we are trying to place. }
          PutW(Pkt, 0, OP_DATA);
          PutW(Pkt, 2, Block);
          NetUdpSend(MyPort, TftpPeerTID, Pkt, 4 + LastLen);
        end;
      end;
    end;

    if Restart then Continue;     { the top of the loop builds the new flow }

    TftpBytes := TftpBytes + LastLen;
    Inc(TftpBlocks);
    if LastLen < TftpBlkSize then
    begin
      Done := True;
      TftpPut := True;
    end;
    Inc(Block);
  end;

  if FOpen then
  begin
    {$I-}
    Close(F);
    {$I+}
    if IOResult <> 0 then ;
  end;
end;

begin
  TftpErr := '';
  MyPort := 20000;
end.
