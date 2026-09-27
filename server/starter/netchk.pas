{ DOS Bridge  --  StevenC & Claude }
{ netchk.pas -- when the poll keeps failing, find out WHICH end is gone.

    NETCHK 192.168.1.10              from AI.BAT, once per failed poll
    NETCHK /PROBE 192.168.1.10       probe now, print, change nothing
    NETCHK /OK                       from AI.BAT, on the first good poll
    NETCHK /STATUS                   print the counters and the log

  WHY IT EXISTS

  On 2026-09-22 the 386SX dropped off its WiFi and stayed off for half an
  hour. The agent loop was perfectly healthy the whole time -- it retried
  the poll every few seconds and UGET printed "no ARP reply" each time --
  but nothing it could do from a batch file would bring the link back, and
  a power cycle did at once. A box that has lost its link cannot ask for
  help, so it has to decide for itself.

  The decision is the whole point, because a failed poll has three quite
  different causes and only one of them is cured by rebooting this box:

    the server answers ARP     this box's link is fine; dosd is down or
                               not answering. Rebooting here fixes nothing
    the ROUTER answers ARP     the WiFi is up, the server's host is gone
                               (off, asleep, moved). Nothing to fix here
    neither answers            this box's own link is dead -> reboot

  ARP rather than ping, and the router rather than the internet. ARP needs
  no IP stack beyond what net.pas already has, and a router always answers
  it. Pinging something on the internet would need DNS and ICMP, and would
  only add "is the ROUTER's uplink up", which does not matter to a bridge
  that lives entirely on the LAN. If the router answers, the WiFi is up.

  THE LOOP GUARD

  A box whose link does not come back after a reboot would otherwise
  reboot forever, every few minutes, with nobody watching. So:

    NETFAIL.DAT  failed polls THIS BOOT. The agent deletes it when it
                 starts, so every boot waits a full /N polls before it
                 may decide anything -- a reboot cannot follow a reboot
    NETBOOT.DAT  reboots THIS OUTAGE. Survives the reboot, and is only
                 cleared by a poll that works. After /R of them it stops
                 rebooting and just keeps polling, and says so

  Both live in C:\AGENT because that is where state that must survive a
  reboot lives. NETCHK.LOG beside them records every probe and every
  decision, so what happened while nobody was looking can be read
  afterwards: `dosexec "TYPE C:\AGENT\NETCHK.LOG"`.

  Exit codes:  0 keep polling
               3 the link is dead and a reboot is allowed: reboot now
               2 usage or config problem (keep polling)
               No packet driver counts as a dead link: 0 until the
               /N-th failure, then 3 under the same /R limit
    /PROBE:    0 server answered, 1 only the router did, 2 neither

  NOT "uses About", for the reason UGET gives: the agent loop runs this on
  every failed poll and the banner would scroll the boot screen away. It is
  silent except when a probe runs, and a probe runs once per /N failures. }

program NetChk;

{$MODE OBJFPC}{$H-}

uses Dos, VidFix, Net;   { VidFix: see vidfix.pas. Inert unless it is needed. }

const
  DEF_DIR   = 'C:\AGENT';
  { About eight seconds a failed poll when ARP is failing, so 30 is four
    minutes -- long enough that a dropped packet, a daemon restart or a
    router rebooting never costs a machine its uptime. }
  DEF_EVERY = 30;
  DEF_MAXRB = 3;
  LOG_CAP   = 16000;       { bytes; the log starts over past this }

  V_NONE   = 0;
  V_SERVER = 1;            { the server answered ARP }
  V_ROUTER = 2;            { only the router did }
  V_DEAD   = 3;            { nothing did }
  V_NODRV  = 4;            { no packet driver to probe with }

var
  StDir   : ShortString;
  Every   : LongInt;
  MaxRb   : LongInt;
  Server  : TIP;
  GwOver  : TIP;
  HaveGwO : Boolean;
  HaveDrv : Boolean;

function UpStr(S: ShortString): ShortString;
var I: Integer;
begin
  for I := 1 to Length(S) do S[I] := UpCase(S[I]);
  UpStr := S;
end;

function Num(L: LongInt): ShortString;
var S: ShortString;
begin
  Str(L, S);
  Num := S;
end;

function Two(W: Word): ShortString;
begin
  if W < 10 then Two := '0' + Num(W) else Two := Num(W);
end;

function Stamp: ShortString;
var Y, Mo, D, Dw, H, Mi, S, S100: Word;
begin
  GetDate(Y, Mo, D, Dw);
  GetTime(H, Mi, S, S100);
  Stamp := Num(Y) + '-' + Two(Mo) + '-' + Two(D) + ' ' +
           Two(H) + ':' + Two(Mi) + ':' + Two(S);
end;

{ ------------------------------------------------------------------ }
{  State files. Every one is a line of numbers or absent; absent and  }
{  unreadable both mean zero, which is always the safe reading.       }
{ ------------------------------------------------------------------ }

function PathOf(const Leaf: ShortString): ShortString;
begin
  PathOf := StDir + '\' + Leaf;
end;

procedure ReadPair(const Leaf: ShortString; var A, B: LongInt);
var F: Text;
begin
  A := 0; B := 0;
  {$I-}
  Assign(F, PathOf(Leaf));
  Reset(F);
  if IOResult <> 0 then Exit;
  Read(F, A);
  if IOResult <> 0 then A := 0;
  Read(F, B);
  if IOResult <> 0 then B := 0;
  Close(F);
  if IOResult <> 0 then ;
  {$I+}
end;

procedure WritePair(const Leaf: ShortString; A, B: LongInt);
var F: Text;
begin
  {$I-}
  Assign(F, PathOf(Leaf));
  Rewrite(F);
  if IOResult <> 0 then Exit;
  WriteLn(F, A, ' ', B);
  Close(F);
  if IOResult <> 0 then ;
  {$I+}
end;

procedure Remove(const Leaf: ShortString);
var F: File;
begin
  {$I-}
  Assign(F, PathOf(Leaf));
  Erase(F);
  if IOResult <> 0 then ;
  {$I+}
end;

procedure Log(const S: ShortString);
var
  F : Text;
  B : File;
  Sz: LongInt;
begin
  { Bounded, because the box writes it unattended for as long as an
    outage lasts. Starting over loses history, but a log that fills the
    disk loses the machine. }
  Sz := 0;
  {$I-}
  Assign(B, PathOf('NETCHK.LOG'));
  Reset(B, 1);
  if IOResult = 0 then
  begin
    Sz := FileSize(B);
    Close(B);
  end;
  if IOResult <> 0 then ;
  Assign(F, PathOf('NETCHK.LOG'));
  if Sz > LOG_CAP then Rewrite(F) else Append(F);
  if IOResult <> 0 then
  begin
    Rewrite(F);
    if IOResult <> 0 then Exit;
  end;
  WriteLn(F, Stamp, ' ', S);
  Close(F);
  if IOResult <> 0 then ;
  {$I+}
end;

{ ------------------------------------------------------------------ }
{  The probe                                                          }
{ ------------------------------------------------------------------ }

{ NetOpen ARPs its peer and releases everything itself when that fails,
  so a False here holds no handle. A True does, and is closed at once:
  nothing happens between the two, and no DOS call is made while the
  driver holds a pointer into this program. }
function Answers(const Who: TIP): Boolean;
begin
  Answers := False;
  if not NetOpen(Who) then Exit;
  NetClose;
  Answers := True;
end;

function Probe(var Why: ShortString): Integer;
var Gw: TIP;
begin
  Why := '';
  if Answers(Server) then
  begin
    Probe := V_SERVER;
    Why := 'server ' + IPStr(Server) + ' answers ARP';
    Exit;
  end;
  if HaveGwO then Gw := GwOver else Gw := NetGw;
  if (Gw[0] or Gw[1] or Gw[2] or Gw[3]) = 0 then
  begin
    Probe := V_DEAD;
    Why := 'server silent, no GATEWAY configured to try';
    Exit;
  end;
  if Answers(Gw) then
  begin
    Probe := V_ROUTER;
    Why := 'server ' + IPStr(Server) + ' silent, router ' + IPStr(Gw) +
           ' answers';
    Exit;
  end;
  Probe := V_DEAD;
  Why := 'server ' + IPStr(Server) + ' and router ' + IPStr(Gw) +
         ' both silent';
end;

{ ------------------------------------------------------------------ }
{  Modes                                                              }
{ ------------------------------------------------------------------ }

procedure DoStatus;
var
  A, B : LongInt;
  F    : Text;
  L    : ShortString;
begin
  ReadPair('NETFAIL.DAT', A, B);
  WriteLn('failed polls this boot : ', A);
  ReadPair('NETBOOT.DAT', A, B);
  WriteLn('reboots this outage    : ', A, ' of ', MaxRb);
  WriteLn('--- ', PathOf('NETCHK.LOG'), ' ---');
  {$I-}
  Assign(F, PathOf('NETCHK.LOG'));
  Reset(F);
  if IOResult <> 0 then
  begin
    WriteLn('(no log: no probe has ever run)');
    Exit;
  end;
  while not Eof(F) do
  begin
    ReadLn(F, L);
    if IOResult <> 0 then Break;
    WriteLn(L);
  end;
  Close(F);
  if IOResult <> 0 then ;
  {$I+}
end;

procedure DoOk;
var Rb, Dummy: LongInt;
begin
  ReadPair('NETBOOT.DAT', Rb, Dummy);
  if Rb > 0 then
    Log('RECOVERED: polling again after ' + Num(Rb) + ' reboot(s)');
  Remove('NETBOOT.DAT');
  Remove('NETFAIL.DAT');
end;

function DoProbe: Integer;
var
  V  : Integer;
  Why: ShortString;
begin
  V := Probe(Why);
  WriteLn('netchk: ', Why);
  case V of
    V_SERVER: DoProbe := 0;
    V_ROUTER: DoProbe := 1;
  else
    DoProbe := 2;
  end;
end;

function DoFailed: Integer;
var
  Fails, Last, Rb, Dummy: LongInt;
  V  : Integer;
  Why: ShortString;
begin
  DoFailed := 0;
  ReadPair('NETFAIL.DAT', Fails, Last);
  Inc(Fails);
  if (Fails mod Every) <> 0 then
  begin
    WritePair('NETFAIL.DAT', Fails, Last);
    Exit;
  end;

  if HaveDrv then
    V := Probe(Why)
  else
  begin
    V := V_NODRV;
    Why := 'no packet driver: ' + NetErr;
  end;
  ReadPair('NETBOOT.DAT', Rb, Dummy);

  if (V <> V_DEAD) and (V <> V_NODRV) then
  begin
    Log(Num(Fails) + ' failed polls: ' + Why + ' - not rebooting');
    { One line on the screen when the verdict changes, not one per probe:
      the console is a status display and a long outage must not scroll
      the banner away. }
    if V <> Last then
    begin
      if V = V_SERVER then
        WriteLn(' [offline] link is fine, dosd is not answering')
      else
        WriteLn(' [offline] WiFi is up, the server''s host is not');
    end;
    WritePair('NETFAIL.DAT', Fails, V);
    Exit;
  end;

  if Rb >= MaxRb then
  begin
    Log(Num(Fails) + ' failed polls: ' + Why + ' - reboot limit (' +
        Num(MaxRb) + ') reached, polling only');
    if V <> Last then
    begin
      if V = V_NODRV then
        WriteLn(' [offline] no packet driver, ', MaxRb,
                ' reboots did not load one - polling only')
      else
        WriteLn(' [offline] link dead, ', MaxRb,
                ' reboots did not fix it - polling only');
    end;
    WritePair('NETFAIL.DAT', Fails, V);
    Exit;
  end;

  Inc(Rb);
  WritePair('NETBOOT.DAT', Rb, 0);
  WritePair('NETFAIL.DAT', Fails, V);
  Log(Num(Fails) + ' failed polls: ' + Why + ' - REBOOT ' + Num(Rb) +
      ' of ' + Num(MaxRb));
  if V = V_NODRV then
    WriteLn(' [offline] no packet driver - rebooting (', Rb, ' of ', MaxRb, ')')
  else
    WriteLn(' [offline] link dead - rebooting (', Rb, ' of ', MaxRb, ')');
  DoFailed := 3;
end;

{ ------------------------------------------------------------------ }

var
  I, Code : Integer;
  A       : ShortString;
  Mode    : ShortString;
  HaveSrv : Boolean;
  N       : LongInt;

procedure Usage;
begin
  WriteLn('usage: NETCHK <server-ip> [/N polls] [/R reboots] [/DIR path]');
  WriteLn('       NETCHK /PROBE <server-ip> [/GW ip]');
  WriteLn('       NETCHK /OK | /STATUS [/DIR path]');
  Halt(2);
end;

begin
  StDir := DEF_DIR;
  Every := DEF_EVERY;
  MaxRb := DEF_MAXRB;
  HaveSrv := False;
  HaveGwO := False;
  Mode := '';

  I := 1;
  while I <= ParamCount do
  begin
    A := UpStr(ParamStr(I));
    if (A = '/PROBE') or (A = '/OK') or (A = '/STATUS') then
      Mode := A
    else if ((A = '/N') or (A = '/R') or (A = '/DIR') or (A = '/GW'))
            and (I < ParamCount) then
    begin
      Inc(I);
      if A = '/DIR' then
        StDir := ParamStr(I)
      else if A = '/GW' then
      begin
        if not ParseIP(ParamStr(I), GwOver) then Usage;
        HaveGwO := True;
      end
      else
      begin
        Val(ParamStr(I), N, Code);
        if (Code <> 0) or (N < 0) then Usage;
        if A = '/N' then
        begin
          if N < 1 then Usage;
          Every := N;
        end
        else
          MaxRb := N;
      end;
    end
    else if (not HaveSrv) and ParseIP(ParamStr(I), Server) then
      HaveSrv := True
    else
      Usage;
    Inc(I);
  end;

  if Mode = '/STATUS' then begin DoStatus; Halt(0); end;
  if Mode = '/OK' then begin DoOk; Halt(0); end;
  if not HaveSrv then Usage;

  { The config, and so the router's address, is read before any handle is
    opened -- reading a file is a DOS call. A box with no config cannot
    probe; say so once in the log and keep polling, never reboot. }
  if not NetReadConfig then
  begin
    WriteLn('netchk: ', NetErr);
    Halt(2);
  end;

  { No packet driver at all used to be treated as a boot problem --
    AUTOEXEC.BAT, the card's configuration -- on the grounds that rebooting
    into the same boot fixes nothing, so it kept polling forever. On
    2026-09-25 the driver was unloaded by a job whose reload named a file
    DOS would not run (PM2000.ORG), and the box sat printing "no packet
    driver" until someone pressed Ctrl-Alt-Del -- the one fault a reboot
    certainly cures. So it now counts toward a reboot exactly like a dead
    link, under the same guard: every /N failed polls, at most /R reboots
    an outage. A truly broken AUTOEXEC costs /R reboots and then polls
    quietly, which is what a dead link has always cost. The probe mode
    still refuses outright: it has nothing to probe with. }
  HaveDrv := NetFindDriver;
  if (not HaveDrv) and (Mode = '/PROBE') then
  begin
    WriteLn('netchk: ', NetErr);
    Halt(2);
  end;

  if Mode = '/PROBE' then Halt(DoProbe);
  Halt(DoFailed);
end.
