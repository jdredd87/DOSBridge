program Hello;
{ DOS Bridge  --  StevenC }
{ Smoke test: proves the compile -> push -> run -> capture loop works. }
{$MODE OBJFPC}{$H-}
uses Tester, About;
begin
  WriteLn('hello from the DOS machine');
  Check('arithmetic still works', 2 + 2 = 4);
  Check('this one fails on purpose', 1 = 2);
  Finish;
end.
