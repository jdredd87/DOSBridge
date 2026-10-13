{ ASK -- a request typed at the DOS machine, for Claude.
  StevenC & Claude (Anthropic), 2026-10-13.

    ASK [box] outfile

  The agent loop (AI.BAT) runs this when F10 is pressed, then sends the
  file to the bridge as asks/<box>.txt -- where a Claude Code session
  watching for it (askwatch.py, on the Windows side) picks it up, does what
  it asks, and answers on this screen.

  Lines are typed one after another; an empty line ends the request.  An
  empty first line cancels.  The file holds FROM <box>, AT <date time>, then
  the lines.  Exit code 0 written, 1 cancelled, 2 bad arguments or the file
  could not be written. }

program Ask;

{$MODE OBJFPC}{$H-}

uses About, Dos;

function Two(N: Word): ShortString;
var
  S: ShortString;
begin
  Str(N, S);
  if Length(S) < 2 then S := '0' + S;
  Two := S;
end;

const
  MAXLINES = 20;

var
  Box, Outf, S, Stamp: ShortString;
  Lines: array[1..MAXLINES] of ShortString;
  N, I: Integer;
  Y, Mo, D, Dw, H, Mi, Se, Hs: Word;
  F: Text;
begin
  { FPC 3.2.2's i8086-msdos runtime: ParamStr is '' until ParamCount runs }
  case ParamCount of
    1: begin Box := '(no BOXID)'; Outf := ParamStr(1); end;
    2: begin Box := ParamStr(1); Outf := ParamStr(2); end;
  else
    WriteLn('usage: ASK [box] outfile');
    Halt(2);
  end;

  WriteLn;
  WriteLn(' Ask Claude -- type your request.  Enter on an empty line sends it;');
  WriteLn(' an empty first line cancels.');
  N := 0;
  repeat
    Write(' > ');
    ReadLn(S);
    while (Length(S) > 0) and (S[Length(S)] = ' ') do Delete(S, Length(S), 1);
    if S = '' then Break;
    Inc(N);
    Lines[N] := S;
  until N = MAXLINES;
  if N = 0 then
  begin
    WriteLn(' cancelled -- nothing sent');
    Halt(1);
  end;

  GetDate(Y, Mo, D, Dw);
  GetTime(H, Mi, Se, Hs);
  Str(Y, Stamp);
  Stamp := Stamp + '-' + Two(Mo) + '-' + Two(D) + ' ' + Two(H) + ':' + Two(Mi) + ':' + Two(Se);

  Assign(F, Outf);
  {$I-} Rewrite(F); {$I+}
  if IOResult <> 0 then
  begin
    WriteLn(' could not write ', Outf);
    Halt(2);
  end;
  WriteLn(F, 'FROM ', Box);
  WriteLn(F, 'AT ', Stamp);
  for I := 1 to N do WriteLn(F, Lines[I]);
  Close(F);
  WriteLn(' sending...');
  Halt(0);
end.
