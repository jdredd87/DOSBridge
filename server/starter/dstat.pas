program DStat;
{ DOS Bridge  --  StevenC }
{ Recursive directory statistics, summarised on the DOS side.

  Usage:  DSTAT [path]           default: current directory

  Why this exists: answering "how many files are on E:" with stock DOS meant
  DIR /S into a file (which needs a batch wrapper, because dosexec appends its
  own redirection), pulling 200KB back over the bridge, and parsing it on the
  Windows side. This does the walk locally and returns about twenty lines.

  Note also that DIR /S's own "Total files listed" is misleading: it counts
  directories and every . and .. entry as files. On E: it says 4100 where the
  real file count is 3545. This reports them separately. }

{$MODE OBJFPC}{$H-}

uses Dos, About;

const
  TOPN     = 10;      { how many directories to rank }
  MAXSUB   = 40;      { subdirectories collected per level before overflow }

type
  { A DOS 8.3 name needs 12 characters, so 13 bytes. Declaring this array as
    ShortString instead costs 256 bytes an entry -- 12KB of stack per level of
    recursion, which overflows the stack a few directories deep. That is not a
    hypothetical: it is what hung the first version of this program. }
  TName = String[12];

var
  TotFiles   : LongInt;
  TotHidden  : LongInt;
  TotDirs    : LongInt;
  TotBytes   : LongInt;
  MaxDepth   : Integer;
  Overflowed : LongInt;

  { Running top-N by file count and by bytes, so memory stays flat no matter
    how many directories the tree has. }
  TopCName : array[1..TOPN] of ShortString;
  TopCVal  : array[1..TOPN] of LongInt;
  TopBName : array[1..TOPN] of ShortString;
  TopBVal  : array[1..TOPN] of LongInt;

  StartDir : ShortString;
  I        : Integer;

procedure NoteTop(var Names: array of ShortString; var Vals: array of LongInt;
                  const D: ShortString; V: LongInt);
var
  J: Integer;
begin
  if V <= Vals[TOPN - 1] then Exit;         { arrays are 0-based here }
  J := TOPN - 1;
  while (J > 0) and (Vals[J - 1] < V) do
  begin
    Vals[J]  := Vals[J - 1];
    Names[J] := Names[J - 1];
    Dec(J);
  end;
  Vals[J]  := V;
  Names[J] := D;
end;

{ One directory: tally its files, remember its subdirectory names, close the
  search, and only then recurse.

  Collecting subdirectories first is deliberate. DOS keeps one DTA per process
  and FindFirst points it at the SearchRec, so starting a nested search inside
  an open one is a classic way to corrupt the outer walk. Finishing this level
  before descending sidesteps that entirely. }
procedure Walk(const Path: ShortString; Depth: Integer);
var
  SR      : SearchRec;
  Subs    : array[1..MAXSUB] of TName;
  NSub, K : Integer;
  Here    : LongInt;
  HereB   : LongInt;
  Base    : ShortString;
begin
  if Depth > MaxDepth then MaxDepth := Depth;

  NSub  := 0;
  Here  := 0;
  HereB := 0;

  Base := Path;
  if (Length(Base) > 0) and (Base[Length(Base)] <> '\') then Base := Base + '\';

  { NOT AnyFile. AnyFile ($3F) sets the VolumeID bit, and a long-filename slot
    is stored as a directory entry with attribute $0F -- ReadOnly+Hidden+System
    +VolumeID -- so DOS hands those back as if they were real entries. Their
    size field holds name characters rather than a length, which is how the
    first version of this reported 1.6GB on a 208MB drive and double-counted
    every file that had a long name. }
  FindFirst(Base + '*.*', ReadOnly or Hidden or SysFile or Directory, SR);
  while DosError = 0 do
  begin
    { Belt and braces: skip LFN slots and volume labels even if the mask let
      one through. }
    if ((SR.Attr and $0F) = $0F) or ((SR.Attr and VolumeID) <> 0) then
    begin
      FindNext(SR);
      Continue;
    end;

    if (SR.Attr and Directory) <> 0 then
    begin
      if (SR.Name <> '.') and (SR.Name <> '..') then
      begin
        Inc(TotDirs);
        if NSub < MAXSUB then
        begin
          Inc(NSub);
          Subs[NSub] := SR.Name;
        end
        else
          Inc(Overflowed);
      end;
    end
    else
    begin
      Inc(TotFiles);
      if (SR.Attr and (Hidden or SysFile)) <> 0 then Inc(TotHidden);
      Inc(Here);
      Inc(TotBytes, SR.Size);
      Inc(HereB, SR.Size);
    end;
    FindNext(SR);
  end;
  FindClose(SR);

  if Here > 0 then
  begin
    NoteTop(TopCName, TopCVal, Base, Here);
    NoteTop(TopBName, TopBVal, Base, HereB);
  end;

  for K := 1 to NSub do
    Walk(Base + Subs[K], Depth + 1);
end;

begin
  TotFiles   := 0;
  TotHidden  := 0;
  TotDirs    := 0;
  TotBytes   := 0;
  MaxDepth   := 0;
  Overflowed := 0;

  for I := 1 to TOPN do
  begin
    TopCName[I] := ''; TopCVal[I] := 0;
    TopBName[I] := ''; TopBVal[I] := 0;
  end;

  if ParamCount >= 1 then
    StartDir := ParamStr(1)
  else
    StartDir := '.';

  WriteLn('=== dstat: ', StartDir, ' ===');

  Walk(StartDir, 1);

  WriteLn('  files            : ', TotFiles);
  WriteLn('    of those hidden: ', TotHidden,
          '   (DIR without /A does not show these)');
  WriteLn('    DIR-visible    : ', TotFiles - TotHidden);
  WriteLn('  directories      : ', TotDirs);
  WriteLn('  bytes            : ', TotBytes);
  WriteLn('  deepest level    : ', MaxDepth);
  if Overflowed > 0 then
    WriteLn('  NOT WALKED       : ', Overflowed,
            ' subdirs past the ', MAXSUB, '-per-level limit');
  WriteLn;

  WriteLn('  top directories by file count:');
  for I := 1 to TOPN do
    if TopCVal[I] > 0 then
      WriteLn('    ', TopCVal[I]:6, '  ', TopCName[I]);
  WriteLn;

  WriteLn('  top directories by bytes:');
  for I := 1 to TOPN do
    if TopBVal[I] > 0 then
      WriteLn('    ', TopBVal[I]:10, '  ', TopBName[I]);
end.
