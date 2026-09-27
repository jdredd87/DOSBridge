unit Kbd;
{ DOS Bridge  --  StevenC & Claude }
{ KEY STATE, NOT KEYSTROKES: which keys are held down at this instant.

  Everything in starter/ that has wanted the keyboard so far has wanted a
  keystroke -- one answer to one question -- and INT 16h serves that
  perfectly well. A camera does not. Walking forward while turning left is
  two keys held at once, and the BIOS can report neither fact: it offers a
  QUEUE of characters, gated by the typematic delay (about half a second
  before a held key repeats at all) and with no concept of a release. Drive
  a camera from it and the first half second of every movement is one lurch
  followed by a pause, which reads as a dropped frame rather than as input.

  So this hooks INT 9 and keeps a byte per scancode. The handler is four
  instructions of work; everything careful in here is about giving the
  vector back.

  WHY IT CHAINS RATHER THAN HANDLING THE KEYBOARD ITSELF. Not chaining is
  less code and it is tempting, because the interrupt then belongs entirely
  to us. It also means acknowledging the keyboard controller by hand, and
  the correct acknowledgement is not the same on an XT as on an AT-class
  machine -- get it wrong and the keyboard is dead until somebody power
  cycles the box, which over this bridge means somebody walking to it. The
  BIOS already knows which machine this is. Chaining also keeps three things
  working that would otherwise quietly stop: the BIOS key buffer, the
  keyboard flags byte at 0040:0017 -- which is where ScrollLock lives, and
  ScrollLock is how the agent loop is stopped -- and the lock LEDs.

  Verified: FPC's `interrupt` directive on i8086 emits the right prologue.
  It saves ax bx cx dx si di ds es, loads DS from DGROUP (so globals are
  reachable, which is the trap that makes hand-written handlers hard), sets
  up BP, and ends in IRET. Checked against the generated assembly, not
  assumed. The chain is an indirect far call through a Pointer, which is
  four contiguous bytes in offset-then-segment order; two separate Word
  variables would read as the same thing and are NOT guaranteed to be laid
  out adjacently. }

{$MODE OBJFPC}{$H-}
{$ASMMODE INTEL}

interface

const
  { Make codes. Break is the same code with bit 7 set, which is what the
    handler tests. Only the ones a demo is likely to want -- there is no
    value in transcribing a whole keyboard nobody will index into. }
  SC_ESC    = $01;
  SC_TAB    = $0F;
  SC_Q      = $10;  SC_W = $11;  SC_E = $12;  SC_R = $13;
  SC_A      = $1E;  SC_S = $1F;  SC_D = $20;
  SC_M      = $32;
  SC_LSHIFT = $2A;  SC_RSHIFT = $36;
  SC_SPACE  = $39;
  { The arrow cluster. A grey arrow sends E0 then this; a keypad arrow
    sends this on its own. Both land on the same entry, because the handler
    stores every byte it sees and E0 masks to $60, which nothing reads. }
  SC_UP     = $48;  SC_LEFT = $4B;  SC_RIGHT = $4D;  SC_DOWN = $50;

var
  { 1 while held, 0 otherwise. Public because reading it is the whole point
    and a function call per key per frame is not worth the tidiness. }
  KeyState : array[0 .. 127] of Byte;
  KbdOn    : Boolean;         { the vector is currently ours }

{ True if it took the vector. False if it was already installed. }
function  KbdInstall: Boolean;
{ Idempotent, and safe to call when it never installed. }
procedure KbdRemove;
function  KbdDown(Scan: Byte): Boolean;
{ Throw away whatever the BIOS queued while we were reading state. Without
  it a key held for a second fills the 16-entry buffer and the BIOS starts
  beeping on every further repeat. }
procedure KbdDrain;

implementation

type
  { A far pointer, and its two halves, guaranteed to overlap. `call far
    [OldInt9]` reads four bytes as offset-then-segment, so they have to BE
    four contiguous bytes in that order. }
  TVec = record
    case Byte of
      0: (P : Pointer);
      1: (O, S : Word);
  end;

var
  OldInt9  : Pointer;         { read by the handler's far call }
  SavedVec : TVec;
  PrevExit : Pointer;

procedure Int9Handler; interrupt;
var
  Code : Byte;
begin
  asm
    in   al, 60h
    mov  Code, al
  end;
  { Bit 7 is the break flag; the low seven bits are the key either way. The
    port is deliberately read but NOT acknowledged -- the BIOS handler below
    reads it again, gets the same byte, and does the acknowledging.

    READ THEN CHAIN, RATHER THAN CHAIN THEN READ, AND THE CHOICE IS NOT
    OBVIOUS. Reading port 60h clears the controller's output-buffer-full
    flag, and a BIOS whose handler tests that flag before reading would find
    it clear and could decide there was nothing to do -- or wait for it. The
    other order avoids that entirely: chain first, then read the data
    register, which still holds the byte.

    It has its own failure though, and a worse one for this unit. If the
    BIOS handler sends the controller a command -- which it does for the
    lock keys, to update the LEDs -- the data register holds the ACK by the
    time we look, so we would record a byte that is not a key AND miss the
    one that was. And on a controller that advances to the next pending
    scancode when the BIOS reads, every key would arrive one behind.

    This order is observed working on the target machine. The other is a
    theory. Do not swap them without a machine in front of you. }
  if (Code and $80) <> 0 then
    KeyState[Code and $7F] := 0
  else
    KeyState[Code and $7F] := 1;
  asm
    pushf
    call far [OldInt9]
  end;
end;

function GetVec9: TVec;
var
  Sg, Of_ : Word;
  V       : TVec;
begin
  asm
    push es
    mov  ax, 3509h
    int  21h
    mov  Of_, bx
    mov  ax, es
    mov  Sg, ax
    pop  es
  end;
  V.O := Of_;
  V.S := Sg;
  GetVec9 := V;
end;

procedure SetVec9(Sg, Of_: Word);
begin
  { DX and the new DS are both loaded from parameters, which FPC addresses
    through SS:BP -- so neither read depends on DS and the order does not
    matter. DS is put back before returning either way. }
  asm
    push ds
    mov  dx, Of_
    mov  ax, Sg
    mov  ds, ax
    mov  ax, 2509h
    int  21h
    pop  ds
  end;
end;

{ Runs on EVERY exit, including a runtime error and including Halt.

  This is the same rule pktcap and net follow for a packet driver handle,
  and for the same reason: what is left behind is a far pointer into memory
  DOS is about to hand to the next program, and the next keystroke jumps
  into it. An explicit call at the end of the main program covers the happy
  path only, and the happy path is not the one that needs covering. }
procedure KbdExit;
begin
  ExitProc := PrevExit;
  KbdRemove;
end;

function KbdInstall: Boolean;
var
  NewV : TVec;
begin
  KbdInstall := False;
  if KbdOn then Exit;
  FillChar(KeyState, SizeOf(KeyState), 0);
  SavedVec := GetVec9;
  OldInt9  := SavedVec.P;
  NewV.P   := @Int9Handler;
  { The exit hook goes on BEFORE the vector does. The other order has a
    window -- however short -- in which the vector is ours and nothing is
    arranged to give it back. }
  PrevExit := ExitProc;
  ExitProc := @KbdExit;
  KbdOn    := True;
  SetVec9(NewV.S, NewV.O);
  KbdInstall := True;
end;

procedure KbdRemove;
begin
  if not KbdOn then Exit;
  KbdOn := False;
  SetVec9(SavedVec.S, SavedVec.O);
  FillChar(KeyState, SizeOf(KeyState), 0);
  KbdDrain;
end;

function KbdDown(Scan: Byte): Boolean;
begin
  KbdDown := KeyState[Scan and $7F] <> 0;
end;

procedure KbdDrain;
begin
  { head := tail. Cheaper than an INT 16h loop and, more to the point, it
    cannot block: AH=00h on an empty buffer waits forever, and getting the
    AH=01h test wrong around it would hang the machine. }
  MemW[$0040:$001A] := MemW[$0040:$001C];
end;

begin
  KbdOn := False;
end.
