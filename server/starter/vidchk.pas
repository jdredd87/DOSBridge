program VidChk;
{ DOS Bridge  --  StevenC }
{ Is this machine on a colour or a mono display?

  HWINFO already prints this among thirty other lines. What it cannot give you
  is an exit code, so this exists purely to be branched on from a batch file or
  from dosexec:

      dosexec "VIDCHK"           -> rc 0 colour, 1 mono, 2 BIOS has no opinion

  The exit code is trustworthy because this is an external program; DOS
  internal commands never set ERRORLEVEL at all (see CLAUDE.md).

  Worth having because this card boots mono or colour unpredictably, and the
  answer changes what a graphics program should do. }

{$MODE OBJFPC}{$H-}

uses VGA, About;

var
  Supported : Boolean;
  Code      : Byte;
  Name      : ShortString;
  Colour    : Boolean;

begin
  Code := DisplayCode(Supported);

  if not Supported then
  begin
    WriteLn('display: pre-VGA BIOS, no display combination code');
    WriteLn('result : UNKNOWN (assuming colour is usually safe)');
    Halt(2);
  end;

  case Code of
    0:    Name := 'no display';
    1:    Name := 'MDA mono';
    2:    Name := 'CGA colour';
    4:    Name := 'EGA colour';
    5:    Name := 'EGA mono';
    6:    Name := 'PGC';
    7:    Name := 'VGA mono';
    8:    Name := 'VGA colour';
    $0A:  Name := 'MCGA colour';
    $0B:  Name := 'MCGA mono';
    $0C:  Name := 'MCGA colour';
  else
    Name := 'unrecognised';
  end;

  Colour := IsColourDisplay;

  WriteLn('display: code ', Code, ' = ', Name);
  if Colour then
    WriteLn('result : COLOUR')
  else
    WriteLn('result : MONO');

  if Colour then Halt(0) else Halt(1);
end.
