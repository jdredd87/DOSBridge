unit Tester;
{ DOS Bridge  --  StevenC }
{ Minimal test harness for DOS programs driven by dosbridge.

  Everything prints through DOS calls (WriteLn), never direct video writes,
  so the output survives redirection to a file and makes it back to Windows.
  Halt code = number of failures, capped at 20 to match the errorlevel ladder
  that dosd generates for DOS 6.22. }

{$MODE OBJFPC}{$H-}

interface

procedure Check(const Name: ShortString; Passed: Boolean);
procedure Note(const S: ShortString);
procedure Note(const S: ShortString; V: LongInt);
procedure Finish;

{ Read the running tally. Finish's exit code is the failure count, which is the
  right answer for a test program but cannot express a third outcome -- FPU.EXE
  needs to return 1 for "no coprocessor fitted" and 2 for "fitted but wrong",
  and those are not failure counts. Such a tool calls Check as usual, then
  decides its own Halt code from these. }
function Failures: Integer;
function Passed: Integer;

implementation

var
  Passes: Integer = 0;
  Fails: Integer = 0;

procedure Check(const Name: ShortString; Passed: Boolean);
begin
  if Passed then
  begin
    Inc(Passes);
    WriteLn('PASS  ', Name);
  end
  else
  begin
    Inc(Fails);
    WriteLn('FAIL  ', Name);
  end;
end;

procedure Note(const S: ShortString);
begin
  WriteLn('      ', S);
end;

{ Overload so callers never need SysUtils/IntToStr, which is a lot of
  dead weight to link into a 16-bit real-mode binary. }
procedure Note(const S: ShortString; V: LongInt);
begin
  WriteLn('      ', S, V);
end;

function Failures: Integer;
begin
  Failures := Fails;
end;

function Passed: Integer;
begin
  Passed := Passes;
end;

procedure Finish;
begin
  WriteLn;
  WriteLn('--- ', Passes, ' passed, ', Fails, ' failed ---');
  if Fails > 20 then
    Halt(20)
  else
    Halt(Fails);
end;

end.
