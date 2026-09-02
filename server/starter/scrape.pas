program Scrape;
{ DOS Bridge  --  StevenC }
{ Capture the text screen and print it through DOS.

  Usage:  SCRAPE            dump the screen as text
          SCRAPE /A         also show the attribute of each non-blank cell
          SCRAPE /R         raw: keep trailing spaces and blank lines

  Why this exists: the standing rule on this machine is that direct writes to
  video memory never make it back over the bridge, because only DOS-level
  output is captured. That leaves anything drawing straight to B800 invisible
  from Windows. This reads the video buffer and writes it out through DOS, so
  whatever a program left on screen becomes ordinary captured text.

  Run it in the same job, straight after the program you want to see:
      dosexec "MYPROG" "SCRAPE"
  DOS does not clear the screen between programs, so MYPROG's output is still
  sitting there when this runs. }

{$MODE OBJFPC}{$H-}
{$ASMMODE INTEL}


uses About;

var
  Mode     : Byte;
  VidSeg   : Word;
  Cols     : Integer;
  Rows     : Integer;
  ShowAttr : Boolean;
  Raw      : Boolean;
  R, C, K  : Integer;
  Cell     : Word;
  Ch       : Byte;
  At       : Byte;
  Line     : ShortString;
  NonBlank : LongInt;
  LastUsed : Integer;
  A        : ShortString;

const
  HexD: array[0..15] of Char = '0123456789ABCDEF';

function GetMode: Byte;
var W: Word;
begin
  asm
    mov ah, 0Fh
    int 10h
    mov W, ax
  end;
  GetMode := W and $FF;
end;

function Hex2(B: Byte): ShortString;
begin
  Hex2 := HexD[(B shr 4) and 15] + HexD[B and 15];
end;

begin
  ShowAttr := False;
  Raw      := False;
  for K := 1 to ParamCount do
  begin
    A := ParamStr(K);
    if (A = '/A') or (A = '/a') then ShowAttr := True;
    if (A = '/R') or (A = '/r') then Raw := True;
  end;

  Mode := GetMode;

  { Modes 0-3 and 7 are the text modes. Anything else has no character cells to
    read and needs the graphics capture instead. }
  if not ((Mode <= 3) or (Mode = 7)) then
  begin
    WriteLn('SCRAPE: video mode ', Mode, ' is a graphics mode.');
    WriteLn('        Use VSHOT for graphics screens.');
    Halt(1);
  end;

  { Mono text lives at B000, colour text at B800. }
  if Mode = 7 then VidSeg := $B000 else VidSeg := $B800;

  { The BIOS data area knows the real geometry, which beats assuming 80x25. }
  Cols := MemW[$0040:$004A];
  Rows := Integer(Mem[$0040:$0084]) + 1;
  if (Cols < 20) or (Cols > 132) then Cols := 80;
  if (Rows < 10) or (Rows > 60) then Rows := 25;

  WriteLn('=== scrape: mode ', Mode, ', ', Cols, 'x', Rows,
          ' at ', HexD[(VidSeg shr 12) and 15], HexD[(VidSeg shr 8) and 15],
          HexD[(VidSeg shr 4) and 15], HexD[VidSeg and 15], ' ===');

  NonBlank := 0;
  for R := 0 to Rows - 1 do
  begin
    Line     := '';
    LastUsed := 0;
    for C := 0 to Cols - 1 do
    begin
      Cell := MemW[VidSeg : Word((R * Cols + C) * 2)];
      Ch   := Cell and $FF;
      At   := (Cell shr 8) and $FF;

      { Control codes and the NUL that fills a cleared screen would corrupt the
        captured text, so they become spaces. }
      if (Ch < 32) or (Ch = 127) then Ch := 32;

      { A cell is "used" if it has a visible glyph. Attribute 0 means black on
        black, which is invisible whatever the character is. }
      if (Ch <> 32) and (At <> 0) then
      begin
        Inc(NonBlank);
        LastUsed := C + 1;
      end;

      Line := Line + Chr(Ch);
    end;

    if not Raw then
      Line := Copy(Line, 1, LastUsed);

    if Raw or (LastUsed > 0) then
      WriteLn(R:2, '|', Line, '|')
    else
      WriteLn(R:2, '|');
  end;

  if ShowAttr then
  begin
    WriteLn;
    WriteLn('  attributes of non-blank cells (row: col=attr ...):');
    for R := 0 to Rows - 1 do
    begin
      Line := '';
      for C := 0 to Cols - 1 do
      begin
        Cell := MemW[VidSeg : Word((R * Cols + C) * 2)];
        Ch   := Cell and $FF;
        At   := (Cell shr 8) and $FF;
        if (Ch > 32) and (At <> 0) then
          Line := Line + Hex2(At) + ' ';
      end;
      if Line <> '' then WriteLn(R:2, ': ', Line);
    end;
  end;

  WriteLn;
  WriteLn('  visible cells    : ', NonBlank, ' of ', LongInt(Cols) * Rows);
end.
