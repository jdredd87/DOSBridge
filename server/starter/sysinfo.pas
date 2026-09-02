program SysInfo;
{ DOS Bridge  --  StevenC }
{ A more realistic example: reports what the machine actually is, and shows
  the pattern for a hardware test you'd drive from Claude Code.

  Build:  fpc -Tmsdos -Pi8086 -WmLarge sysinfo.pas
  Run:    dosrun sysinfo.exe }

{$MODE OBJFPC}{$H-}

uses Dos, Cpu, Tester, About;

var
  Maj, Min: Word;
  Free: LongInt;
begin
  WriteLn('=== sysinfo ===');

  Maj := Lo(DosVersion);
  Min := Hi(DosVersion);
  WriteLn('      DOS version: ', Maj, '.', Min);
  Check('DOS 6.x or later', Maj >= 6);

{$IFDEF CPUI8086}
  Free := MemAvail;
{$ELSE}
  Free := 65535;          { host build, for syntax checking only }
{$ENDIF}
  Note('heap available (bytes): ', Free);
  Check('at least 32K of heap', Free > 32768);

  { CpuClass probes at run time, so this reports whatever it is really
    running on rather than whatever it was built for. See cpu.pas. }
  Note('CPU: ' + CpuName);
  if Has186 then
    Note('  186-class instructions: available')
  else
    Note('  186-class instructions: no, plain 8086 only');
  Check('CPU identified', CpuClass <> cpuUnknown);

  { Reported, never required. Nothing else in the suite changes behaviour on
    the answer -- run FPU.EXE for the full report and the arithmetic tests. }
  if HasFpu then
    Note('coprocessor: ' + FpuName)
  else
    Note('coprocessor: none (everything here runs integer-only anyway)');

  Finish;
end.
