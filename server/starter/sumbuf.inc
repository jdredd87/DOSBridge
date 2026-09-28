{ DOS Bridge  --  StevenC & Claude }
{ sumbuf.inc -- the UDP/IP checksum loop, shared by net.pas and sumtest.pas
  so the test runs the very code the transport does.  Needs TPkt. }

{ The one's complement sum of Len bytes at P[Ofs], added into S.

  It was Pascal -- a call to AddW per 16-bit word -- and on the V30 a call
  costs ~21 us, so summing a 1400-byte datagram took around 15 ms: a big
  share of every block UPUT sent (2026-09-27).  Now one ADC a word.

  The sum is taken over little-endian words, which is the network-order sum
  with its bytes swapped (a property of the one's complement sum), so the
  bytes are swapped back at the end.  An odd trailing byte is the high byte
  of a network-order word padded on the right -- the low byte of a
  little-endian one.  sumtest.pas checks it against the old Pascal on random
  data, every length and offset, before anything sends with it. }
procedure SumBuf(var S: Word; var P: TPkt; Ofs, Len: Word); assembler;
asm
  push ds
  lds  si, P
  add  si, Ofs
  mov  cx, Len
  xor  ax, ax
  xor  bx, bx
  mov  dx, cx
  shr  cx, 1
  jcxz @@tail
  clc
@@words:
  adc  ax, [si]
  inc  si
  inc  si
  loop @@words
  adc  ax, 0
@@tail:
  test dl, 1
  jz   @@swap
  mov  bl, [si]
  add  ax, bx
  adc  ax, 0
@@swap:
  xchg al, ah
  pop  ds
  les  di, S
  add  ax, es:[di]
  adc  ax, 0
  mov  es:[di], ax
end;
