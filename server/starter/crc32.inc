{ DOS Bridge  --  StevenC & Claude }
{ crc32.inc -- CRC-32 (the zlib/PKZIP one, reflected, poly EDB88320), fast
  enough to run on data as it arrives.  Shared by tftp.pas (UGET checks a
  download as it lands) and crctest.pas (which proves it against a bit-by-bit
  reference and times it).

  Crc32Init once; then Crc32Upd over the data, starting from $FFFFFFFF, and
  xor the result with $FFFFFFFF -- the same number HD.EXE and Python's
  zlib.crc32 give.

  The table lives at offset 0 of its own paragraph-aligned block, 256 low
  words then 256 high words, so a byte's entry is found by doubling it: no
  table base to add inside the loop. }

var
  Crc32Seg: Word;                  { the table's segment; 0 until Crc32Init }
  Crc32Mem: Pointer;

procedure Crc32Init;
var
  I, J: Word;
  C: LongInt;
  P: Word;
begin
  if Crc32Seg <> 0 then Exit;
  GetMem(Crc32Mem, 1024 + 16);
  P := Seg(Crc32Mem^) + (Ofs(Crc32Mem^) + 15) shr 4;
  Crc32Seg := P;
  for I := 0 to 255 do
  begin
    C := I;
    for J := 1 to 8 do
      if (C and 1) <> 0 then
        C := (C shr 1) xor LongInt($EDB88320)
      else
        C := C shr 1;
    MemW[P : I * 2] := Word(C and $FFFF);
    MemW[P : 512 + I * 2] := Word((C shr 16) and $FFFF);
  end;
end;

{ Crc := CRC of Len bytes at Buf, continuing from Crc (not inverted here).
  The running CRC is DX:BX; AH stays 0 so AX is the table index as soon as
  the byte is in AL.  Four bytes a pass, the odd ones first: about 70
  cycles a byte on the V30. }
procedure Crc32Upd(var Crc: LongInt; var Buf; Len: Word); assembler;
asm
  push ds
  mov  ax, Crc32Seg
  les  di, Crc
  mov  bx, es:[di]
  mov  dx, es:[di+2]
  mov  cx, Len
  lds  si, Buf
  mov  es, ax
  cld
  xor  ax, ax
  push cx
  and  cx, 3
  jcxz @@quad
@@one:
  lodsb
  xor  al, bl
  mov  di, ax
  shl  di, 1
  mov  bl, bh
  mov  bh, dl
  mov  dl, dh
  mov  dh, 0
  xor  bx, es:[di]
  xor  dx, es:[di+512]
  loop @@one
@@quad:
  pop  cx
  shr  cx, 1
  shr  cx, 1
  jcxz @@done
@@four:
  lodsb
  xor  al, bl
  mov  di, ax
  shl  di, 1
  mov  bl, bh
  mov  bh, dl
  mov  dl, dh
  mov  dh, 0
  xor  bx, es:[di]
  xor  dx, es:[di+512]
  lodsb
  xor  al, bl
  mov  di, ax
  shl  di, 1
  mov  bl, bh
  mov  bh, dl
  mov  dl, dh
  mov  dh, 0
  xor  bx, es:[di]
  xor  dx, es:[di+512]
  lodsb
  xor  al, bl
  mov  di, ax
  shl  di, 1
  mov  bl, bh
  mov  bh, dl
  mov  dl, dh
  mov  dh, 0
  xor  bx, es:[di]
  xor  dx, es:[di+512]
  lodsb
  xor  al, bl
  mov  di, ax
  shl  di, 1
  mov  bl, bh
  mov  bh, dl
  mov  dl, dh
  mov  dh, 0
  xor  bx, es:[di]
  xor  dx, es:[di+512]
  loop @@four
@@done:
  pop  ds
  les  di, Crc
  mov  es:[di], bx
  mov  es:[di+2], dx
end;
