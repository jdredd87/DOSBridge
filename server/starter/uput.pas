{ DOS Bridge  --  StevenC }
{ uput.pas -- send a file to dosd over our own UDP. The NC replacement.

    UPUT 192.168.1.10 C:\WORK\RES.TXT result
    UPUT 192.168.1.10 C:\WORK\OUT.BIN pull/OUT.BIN

  The remote name "result" feeds dosd's result intake -- the same parser the
  TCP path on port 8081 uses, so a report means the same thing however it
  arrived. Any other name is written under dosd's files/ directory.

  Exit codes:  0 the whole file was acknowledged
               1 the transfer failed (the reason is printed)
               2 setup failed -- no packet driver, no config, ARP failed

  This replaces `NC -target host 8081 < file`, and it fixes NC's worst
  property along the way: NC without -bin opens stdin in text mode and
  silently eats every 0x0D and 0x1A, which once turned a 27,298-byte EXE into
  a corrupt but entirely plausible 27,258. There is no text mode here at all
  -- TFTP "octet" moves bytes, and a short final block is what ends the
  transfer, so a 0x1A in the middle is just a byte. }

program UPut;

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
  Local  : ShortString;
  Remote : ShortString;
  Opened : Boolean;
  Ok     : Boolean;
  Verbose: Boolean;
  I, J   : Integer;
  A      : ShortString;

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
  if Opened then NetClose;
  Halt(Code);
end;

begin
  Opened := False;
  Verbose := False;

  if ParamCount < 3 then
  begin
    WriteLn('usage: UPUT <server-ip> <local-file> <remote-name>');
    WriteLn('       UPUT 192.168.1.10 C:\WORK\RES.TXT result');
    Halt(2);
  end;

  if not ParseIP(ParamStr(1), Server) then
  begin
    WriteLn('UPUT: "', ParamStr(1), '" is not an IP address (no DNS here)');
    Halt(2);
  end;
  Local  := ParamStr(2);
  Remote := ParamStr(3);
  for I := 4 to ParamCount do
  begin
    A := ParamStr(I);
    for J := 1 to Length(A) do A[J] := UpCase(A[J]);
    if (A = '-V') or (A = '/V') then Verbose := True;
  end;

  if not NetReadConfig then
  begin
    WriteLn('UPUT: ', NetErr);
    Halt(2);
  end;
  if not NetOpen(Server) then
  begin
    WriteLn('UPUT: ', NetErr);
    Halt(2);
  end;
  Opened := True;

  { Ask for big blocks. A result is one or two either way, but a `dosctl
    pull` of a real file is the case this pays for. }
  TftpWantBlk := TFTP_BLK_MAX;
  Ok := TftpPut(TFTP_PORT, Local, Remote);

  NetClose;
  Opened := False;

  if not Ok then
  begin
    WriteLn(' uput: ', Fit(Leaf(Local), 16), ' FAILED - ', Fit(TftpErr, 40));
    WriteLn('       rx ', NetRxFrames, ' (', NetRxWrong, ' foreign, ',
            NetRxDrop, ' dropped)  tx ', NetTxFrames, ' (', NetTxFail,
            ' refused)');
    { The stall measurement. Only interesting when a flow was rebuilt:
      it says what reached the card during the silence. }
    if TftpRestarts > 0 then
      WriteLn('       during ', TftpRestarts, ' stall(s): rx ',
              TftpStallRx, ' seen, ', TftpStallWrong, ' not ours, ',
              TftpStallDrop, ' dropped');
    Halt(1);
  end;

  if Verbose then
    WriteLn(' uput: ', Fit(Leaf(Local), 16), '  ', TftpBytes, ' bytes, ',
            TftpBlocks, ' blocks of ', TftpBlkSize, ', ',
            TftpResends, ' resends');
  Halt(0);
end.
