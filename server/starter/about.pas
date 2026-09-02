unit About;
{ DOS Bridge  --  StevenC }
{ Attribution for every tool in the suite, in exactly one place.

  Add `About` to a program's uses clause and it prints the banner. Nothing
  else is required and there is no call to forget, because the work happens in
  this unit's initialization section -- FPC runs those before the main program
  body, so the line lands above whatever header the tool prints for itself.

  Doing it here rather than pasting a WriteLn into twenty-nine programs is not
  only about typing. A banner copied twenty-nine times is a banner that says
  twenty-nine slightly different things within a year, and the one place it
  matters -- an EXE found on a disk with no context -- is exactly where the
  drift would show.

  The strings are deliberately plain ASCII. These binaries print through DOS
  on a machine whose code page is not guaranteed, and a stray byte in a banner
  is a silly way to make output unreadable. }

{$MODE OBJFPC}{$H-}

interface

const
  PRODUCT = 'DOS Bridge';
  AUTHOR  = 'StevenC';
  BUILT   = {$I %DATE%};

{ The single line every tool prints before its own output. }
function AboutLine: ShortString;

implementation

{ The compile date comes from FPC's own {$I %DATE%} macro, so there is no
  generation step and nothing to keep in sync.

  Deliberately the compile date and NOT the installer's build number. That
  counter lives on the Windows side and is advanced by makeinst, while these
  binaries are built independently by build.cmd -- so a build number baked in
  here would be whatever the counter happened to read at compile time, which is
  not necessarily the build that ships the binary. A date cannot be wrong in
  that way. The installer stamps its own build number separately, and the two
  answer different questions: which release, versus when was this EXE made. }
function AboutLine: ShortString;
begin
  AboutLine := PRODUCT + ' tools  --  ' + AUTHOR + '  --  built ' + BUILT;
end;

initialization
  { Printed, not merely stored, so it is also visible in a captured job log --
    and because it is printed the string is certainly linked in, which means
    HD or any strings-style dump of the EXE identifies the binary even if
    nobody ever runs it. }
  WriteLn(AboutLine);

end.
