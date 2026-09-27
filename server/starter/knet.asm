; ======================================================================
;  KNET.COM -- live remote keyboard for the DOS box, over the network.
;
;  DOS Bridge  --  StevenC & Claude
;
;  You type on the Windows side; the keystrokes arrive here as UDP and are
;  handed to whatever program is running, as though they came from the
;  keyboard. Unlike KINJ, nothing is scripted ahead of time: keys arrive
;  while the target is already running.
;
;  WHY THIS CAN WORK AT ALL
;  ------------------------
;  DOS is single-tasking and not reentrant, so while a target program runs
;  nothing else on the box does, and an interrupt handler cannot call DOS to
;  read a socket. That is exactly why KINJ has to load its whole script up
;  front.
;
;  The one opening is the PACKET DRIVER: it is callable at interrupt time and
;  needs no DOS at all. It calls a receiver of ours for every matching frame,
;  and that receiver can queue a keystroke without touching DOS. INT 16h then
;  hands the queue out.
;
;  WHY PLAIN UDP AND NOT A PRIVATE ETHERTYPE
;  -----------------------------------------
;  A frame delivered to one handle is not delivered to anyone else's, so
;  holding ethertype 0800 takes IP away from UGET/UPUT -- the bridge's own
;  transport. That sounds fatal and mostly is not: while the target program is
;  running, the agent loop is BLOCKED running it, so nothing else wants IP
;  during a session anyway. Hold it only for the session and release it before
;  the job ends.
;
;  The alternative -- a private ethertype like 88B5 -- keeps IP untouched but
;  needs raw layer-2 sending on the Windows side, which means installing a
;  capture driver. A plain UDP socket needs nothing. That trade is why this
;  parses IP and UDP headers by hand below.
;
;  KEYSTROKES MUST BE BROADCAST, AND THAT IS NOT A CONVENIENCE
;  -----------------------------------------------------------
;  Nothing on the box answers ARP while this holds the IP handle -- by then
;  the 0806 handle is long released -- so Windows cannot revalidate its cache
;  and quietly stops delivering unicast. Measured in one 15-second run:
;
;      unicast to the box    0 frames reached our port
;      broadcast             23 frames, 92 keys
;
;  Broadcast needs no resolution at all, which also means this TSR needs no
;  gratuitous-ARP emitter: a whole block of interrupt-time code that would
;  otherwise have to exist and be right. The cost is that every host on the
;  segment sees the keystrokes. On a lab network that is a fair trade; do not
;  type a password through it.
;
;  THE DANGEROUS PART, AND HOW IT IS BOUNDED
;  -----------------------------------------
;  access_type hands the driver a FAR POINTER TO OUR CODE which it calls at
;  interrupt time. Exit without release_type and that pointer dangles into
;  memory DOS reuses -- the next matching frame jumps into it, and since the
;  bridge runs over that network, recovery needs hands on the keyboard.
;
;  So /T exists: it acquires, listens, reports and releases in ONE run,
;  never going resident. Prove the receive path with /T before trusting the
;  TSR. Everything between acquire and release is straight-line code with no
;  DOS calls, exactly as pktcap.pas requires.
;
;  USAGE
;      KNET /T [secs]     listen and report, NEVER resident   <-- start here
;      KNET [port]        go resident, default port 8071
;      KNET /S            resident? counters
;      KNET /U            release the handle and unhook
; ======================================================================

%ifndef __MININASM__
        cpu     8086
%endif
        org     100h

PORT     equ    8071                   ; default UDP port we listen on
RINGN    equ    64                     ; queued keys; must be a power of two
RINGM    equ    RINGN - 1
PKTMAX   equ    1514                   ; one Ethernet frame

FLG_ZF   equ    0040h                  ; ZF in the flags word on the stack

; Frame layout we care about. Ethernet is fixed; IP's header length is not,
; so IHL is read rather than assumed.
ETH_TYPE equ    12                     ; ethertype, big-endian
ETH_LEN  equ    14
IP_VER   equ    ETH_LEN + 0            ; version<<4 | IHL
IP_PROTO equ    ETH_LEN + 9
PROTO_UDP equ   17

start:  jmp     init

; ----------------------------------------------------------------------
;  Resident data. Kept before the handlers so a signature search finds it
;  at a fixed offset, the same trick KINJ uses.
; ----------------------------------------------------------------------
sig:    db      'KNET01'               ; at 103h -- how we find ourselves
old16:  dd      0                      ; previous INT 16h
pdint:  db      0                      ; packet driver interrupt number
handle: dw      0                      ; packet driver handle
port:   dw      PORT                   ; UDP port, host order
nframe: dw      0                      ; frames the driver gave us
nkeys:  dw      0                      ; keys queued
ndrop:  dw      0                      ; frames refused (buffer busy)
nsent:  dw      0                      ; keys handed to a program
n_ip:   dw      0                      ; ...of those, ethertype 0800
n_udp:  dw      0                      ; ...of those, protocol UDP
n_port: dw      0                      ; ...of those, addressed to our port
n_mag:  dw      0                      ; ...of those, carrying our magic
busy:   db      0                      ; pktbuf holds a frame being parsed
rxlen:  dw      0                      ; its length
rhead:  dw      0
rtail:  dw      0
lastact: dw     0                      ; BIOS tick of the last key received
wticks: dw      2184                   ; idle ticks before self-release (120s)
relsd:  db      0                      ; the handle has been given back

etype:  db      08h, 00h               ; the type we ask for: IPv4

; ----------------------------------------------------------------------
;  The packet driver's receiver. CALLED AT INTERRUPT TIME.
;
;  DS belongs to the DRIVER on entry, not to us, so every access here uses a
;  cs: override rather than loading DS. That is cheaper than saving and
;  restoring it and removes a whole class of mistake.
;
;  Called twice per frame:
;     AX=0  give me a buffer of CX bytes  -> return ES:DI, or 0:0 to drop it
;     AX=1  it is copied in               -> DS:SI is the buffer
; ----------------------------------------------------------------------
recv:
        or      ax, ax
        jne     .copied

        ; ---- AX=0: asked for somewhere to put CX bytes ----
        cmp     byte [cs:busy], 0
        jne     .drop                  ; still parsing the last one
        cmp     cx, PKTMAX
        ja      .drop                  ; too big to be ours
        mov     [cs:rxlen], cx
        mov     byte [cs:busy], 1
        push    cs
        pop     es
        mov     di, pktbuf
        retf
.drop:
        inc     word [cs:ndrop]
        xor     di, di
        mov     es, di                 ; ES:DI = 0:0 means "drop it"
        retf

        ; ---- AX=1: the frame is in pktbuf ----
.copied:
        call    parse
        mov     byte [cs:busy], 0
        retf

; ----------------------------------------------------------------------
;  Pick the keys out of one frame. Interrupt time: no DOS, no stack games.
;  Everything is cs:-relative. Anything that does not look exactly right is
;  dropped in silence -- this runs on every IP frame the box receives.
; ----------------------------------------------------------------------
parse:
        push    ax
        push    bx
        push    cx
        push    dx
        push    si

        inc     word [cs:nframe]

        mov     bx, pktbuf
        cmp     word [cs:rxlen], ETH_LEN + 20 + 8 + 6
        jb      .out                   ; too short to hold a payload

        ; ethertype 0800?  (big-endian on the wire)
        cmp     byte [cs:bx + ETH_TYPE], 08h
        jne     .out
        cmp     byte [cs:bx + ETH_TYPE + 1], 00h
        jne     .out
        inc     word [cs:n_ip]

        ; IPv4, and how long is its header?
        mov     al, [cs:bx + IP_VER]
        mov     ah, al
        and     ah, 0F0h
        cmp     ah, 40h
        jne     .out
        and     al, 0Fh
        cmp     al, 5
        jb      .out                   ; a header shorter than 20 is nonsense
        xor     ah, ah
        shl     ax, 1
        shl     ax, 1                  ; IHL is in 32-bit words
        mov     dx, ax                 ; dx = IP header length

        ; UDP?
        mov     si, ETH_LEN
        add     si, dx
        ; si now indexes the UDP header; check the protocol byte first
        mov     al, [cs:bx + IP_PROTO]
        cmp     al, PROTO_UDP
        jne     .out
        inc     word [cs:n_udp]

        ; destination port, big-endian on the wire
        mov     ah, [cs:bx + si + 2]
        mov     al, [cs:bx + si + 3]
        cmp     ax, [cs:port]
        jne     .out
        inc     word [cs:n_port]

        ; payload starts after the 8-byte UDP header
        add     si, 8

        ; magic 'KN01', then a word count, then that many key words
        cmp     byte [cs:bx + si + 0], 'K'
        jne     .out
        cmp     byte [cs:bx + si + 1], 'N'
        jne     .out
        cmp     byte [cs:bx + si + 2], '0'
        jne     .out
        cmp     byte [cs:bx + si + 3], '1'
        jne     .out
        inc     word [cs:n_mag]

        mov     cx, [cs:bx + si + 4]   ; how many keys
        or      cx, cx
        jz      .out
        cmp     cx, 128
        ja      .out                   ; refuse a silly count
        add     si, 6

.push:
        mov     ax, [cs:bx + si]
        call    ringput
        add     si, 2
        loop    .push

.out:
        pop     si
        pop     dx
        pop     cx
        pop     bx
        pop     ax
        ret

; ---- put AX in the ring; silently drop if it is full -------------------
ringput:
        push    bx
        push    dx
        mov     bx, [cs:rtail]
        mov     dx, bx
        inc     dx
        and     dx, RINGM
        cmp     dx, [cs:rhead]
        je      .full                  ; one slot always left empty
        shl     bx, 1
        mov     [cs:ring + bx], ax
        mov     [cs:rtail], dx
        inc     word [cs:nkeys]
        ; Feed the watchdog. Interrupt time, but reading the BIOS tick is
        ; just a memory read at 0040:006Ch -- no DOS, nothing to reenter.
        push    ds
        mov     dx, 40h
        mov     ds, dx
        mov     dx, [6Ch]
        pop     ds
        mov     [cs:lastact], dx
.full:
        pop     dx
        pop     bx
        ret

; ---- take a key into BX; CF=1 if there was one ------------------------
ringget:
        push    ax
        mov     ax, [cs:rhead]
        cmp     ax, [cs:rtail]
        je      .empty
        push    ax
        shl     ax, 1
        xchg    ax, bx
        mov     bx, [cs:ring + bx]
        xchg    ax, bx                 ; ax = key, bx = scratch
        mov     bx, ax
        pop     ax
        inc     ax
        and     ax, RINGM
        mov     [cs:rhead], ax
        inc     word [cs:nsent]
        pop     ax
        stc
        ret
.empty:
        pop     ax
        clc
        ret

; ----------------------------------------------------------------------
;  The watchdog: give the packet handle back if nobody has typed for a while.
;
;  WHY THIS HAS TO EXIST. While KNET is resident it holds ethertype 0800, so
;  UGET cannot get a handle and the box cannot poll:
;
;      UGET: access_type refused for ethertype 0800, driver error 10
;
;  The machine is perfectly healthy and completely unreachable, which is the
;  exact failure this project is built to avoid. Loading KNET and letting the
;  job end -- the obvious thing to do if you want to type interactively -- is
;  all it takes, so relying on /U always being reached is not good enough.
;
;  After `wticks` with no keystroke this releases the handle and becomes a
;  pass-through, and the box starts polling again on its own.
;
;  IT DOES NOT UNHOOK ITSELF, DELIBERATELY. Restoring the vector needs INT 21h
;  and this can run from inside DOS -- COMMAND.COM polls the keyboard from its
;  break check, which is itself inside an INT 21h. Reentering DOS there is a
;  crash. Releasing the handle is a packet-driver call and touches no DOS at
;  all, so that half is safe and is the half that matters: the network comes
;  back. The vector stays ours, chaining, and ~2 KB stays allocated until
;  somebody runs /U or reboots. A small leak beats a trip to the machine.
; ----------------------------------------------------------------------
wdcheck:
        pushf
        push    ax
        push    bx
        push    cx
        push    dx
        push    si
        push    di
        push    ds
        push    es
        cmp     byte [cs:relsd], 0
        jne     .out                   ; already given back
        mov     ax, 40h
        mov     ds, ax
        mov     ax, [6Ch]              ; BIOS tick, low word
        sub     ax, [cs:lastact]       ; unsigned: correct across the wrap
        cmp     ax, [cs:wticks]
        jb      .out
        ; Expired. pdopc was patched when the handle was acquired and has not
        ; changed since, so there is nothing to patch here.
        mov     ah, 03h                ; release_type
        mov     bx, [cs:handle]
        call    callpd
        mov     byte [cs:relsd], 1
.out:
        pop     es
        pop     ds
        pop     di
        pop     si
        pop     dx
        pop     cx
        pop     bx
        pop     ax
        popf
        ret

; ----------------------------------------------------------------------
;  INT 16h. Same shape as KINJ's, with one important difference: when we
;  have nothing queued we CHAIN, so the real keyboard keeps working and
;  somebody standing at the machine can always take over.
; ----------------------------------------------------------------------
int16:
        call    wdcheck
        cmp     byte [cs:relsd], 0
        jne     .chain                 ; handle given back: pure pass-through
        cmp     ah, 00h
        je      .read
        cmp     ah, 10h
        je      .read
        cmp     ah, 01h
        je      .peek
        cmp     ah, 11h
        je      .peek
.chain:
        jmp     far [cs:old16]

; ---- AH=01h/11h: is a key available? Must not consume one. ----
.peek:
        push    bp
        mov     bp, sp                 ; bp+2 IP, bp+4 CS, bp+6 FLAGS
        push    bx
        push    ax
        mov     ax, [cs:rhead]
        cmp     ax, [cs:rtail]
        pop     ax
        je      .peek_chain            ; nothing of ours: let the BIOS answer
        mov     bx, [cs:rhead]
        shl     bx, 1
        mov     ax, [cs:ring + bx]
        and     word [bp+6], ~FLG_ZF   ; ZF=0: a key is waiting
        pop     bx
        pop     bp
        iret
.peek_chain:
        pop     bx
        pop     bp
        jmp     .chain

; ---- AH=00h/10h: read a key, waiting for one. ----
;
;  Both sources have to be watched at once. Chaining straight to the BIOS
;  would block inside it and our frames would never get a look in; serving
;  only our ring would ignore the real keyboard. So poll both, with
;  INTERRUPTS ON -- the packet driver's IRQ is what fills the ring, and with
;  them off this spins for ever.
.read:
        push    bx
.rwait:
        call    ringget
        jc      .rgot
        sti
        call    biosready              ; did somebody press a real key?
        jc      .rchain
        jmp     .rwait
.rgot:
        mov     ax, bx
        pop     bx
        iret
.rchain:
        pop     bx
        jmp     .chain

; ---- CF=1 if the real BIOS says a key is waiting ----------------------
biosready:
        push    ax
        push    bx
        push    cx
        push    dx
        push    si
        push    di
        push    bp
        push    es
        push    ds
        pushf                          ; the old handler ends in IRET, so it
        mov     ah, 01h                ;  needs flags on the stack like an INT
        call    far [cs:old16]
        pushf
        pop     ax                     ; AX = flags the old handler returned
        pop     ds
        pop     es
        pop     bp
        pop     di
        pop     si
        pop     dx
        pop     cx
        pop     bx
        test    ax, FLG_ZF
        pop     ax
        jz      .yes                   ; ZF=0 meant a key is there
        clc
        ret
.yes:
        stc
        ret

; ======================================================================
;  Everything below is transient: it runs once and is not kept resident.
; ======================================================================

; ---- find the packet driver: 'PKT DRVR' at offset 3 of the handler ----
findpd:
        mov     ax, 3500h + 60h
.scan:
        push    ax
        mov     ah, 35h
        int     21h                    ; ES:BX = handler
        pop     ax
        push    ax
        push    es
        push    bx
        ; compare the eight bytes at ES:BX+3
        mov     si, pdsig
        mov     di, bx
        add     di, 3
        mov     cx, 8
        push    ds
        push    cs
        pop     ds
.cmp:
        mov     ah, [si]
        cmp     ah, [es:di]
        jne     .nomatch
        inc     si
        inc     di
        loop    .cmp
        pop     ds
        pop     bx
        pop     es
        pop     ax
        mov     [pdint], al
        clc
        ret
.nomatch:
        pop     ds
        pop     bx
        pop     es
        pop     ax
        inc     al
        cmp     al, 81h
        jb      .scan
        stc
        ret

pdsig:  db      'PKT DRVR'

; ---- build "int <pdint>" so a run-time vector can be called -----------
;  The INT opcode takes an immediate, so the number cannot come from a
;  variable. pktdrv.pas solves this with PUSHF + far CALL; here the byte is
;  simply patched into the instruction below, which is smaller.
callpd:
        db      0CDh
pdopc:  db      60h
        ret

; ---- acquire: access_type for IPv4 ------------------------------------
acquire:
        mov     al, [pdint]
        mov     [pdopc], al
        mov     ax, 0201h              ; AH=02 access_type, AL=1 class Ethernet
        mov     bx, 0FFFFh             ; any type
        mov     dl, 0                  ; interface 0
        mov     si, etype
        mov     cx, 2
        push    cs
        pop     ds
        push    cs
        pop     es
        mov     di, recv
        call    callpd
        jc      .fail
        mov     [handle], ax
        clc
        ret
.fail:
        stc
        ret

; ---- release: MANDATORY on every exit path ----------------------------
release:
        mov     al, [pdint]
        mov     [pdopc], al
        mov     ah, 03h
        mov     bx, [handle]
        call    callpd
        ret

puts:
        mov     ah, 09h
        int     21h
        ret

; ---- print AX as four hex digits --------------------------------------
puthex:
        push    ax
        push    cx
        mov     cx, 4
.next:
        rol     ax, 1
        rol     ax, 1
        rol     ax, 1
        rol     ax, 1
        push    ax
        and     al, 0Fh
        add     al, '0'
        cmp     al, '9'
        jbe     .ok
        add     al, 7
.ok:
        mov     dl, al
        mov     ah, 02h
        int     21h
        pop     ax
        loop    .next
        pop     cx
        pop     ax
        ret

; ---- print AX as decimal ----------------------------------------------
putdec:
        push    ax
        push    bx
        push    cx
        push    dx
        mov     bx, 10
        xor     cx, cx
.split:
        xor     dx, dx
        div     bx
        push    dx
        inc     cx
        or      ax, ax
        jnz     .split
.emit:
        pop     dx
        add     dl, '0'
        mov     ah, 02h
        int     21h
        loop    .emit
        pop     dx
        pop     cx
        pop     bx
        pop     ax
        ret

; ---- read the BIOS tick at 0040:006Ch ---------------------------------
;  Directly, not through INT 1Ah AH=0, which returns the midnight-rollover
;  flag in AL and CLEARS it -- DOS reads that same flag to advance the date,
;  so a timer built on it occasionally eats a day.
tick:
        push    ds
        mov     ax, 40h
        mov     ds, ax
        mov     ax, [6Ch]
        pop     ds
        ret

init:
        ; ---- parse the command tail ----
        mov     si, 81h
        xor     cx, cx
.skip:
        lodsb
        cmp     al, 0Dh
        je      .noargs
        cmp     al, ' '
        je      .skip
        cmp     al, 9
        je      .skip
        cmp     al, '/'
        je      .switch
        cmp     al, '-'
        je      .switch
        ; a number: the port
        dec     si
        call    getnum
        jc      .usage
        mov     [port], ax
        jmp     do_install
.noargs:
        jmp     do_install
.switch:
        lodsb
        or      al, 20h
        cmp     al, 't'
        je      do_test
        cmp     al, 's'
        je      do_status
        cmp     al, 'u'
        je      do_unload
        cmp     al, 'w'
        je      .wdog
.wdog:
        ; /W<secs> -- how long with no keystroke before the handle goes back.
        ; 0 disables it, which is what a session with somebody watching wants
        ; and is a bad default for one without.
        call    getnum
        jc      .usage
        mov     bx, 18                 ; ticks a second, near enough: 1% slow
        mul     bx
        mov     [wticks], ax
        jmp     .skip

.usage:
        mov     dx, msg_use
        call    puts
        mov     al, 1
        jmp     bye

; ---- read a decimal number at DS:SI into AX ---------------------------
getnum:
        xor     ax, ax
        xor     cx, cx
.digit:
        mov     bl, [si]
        cmp     bl, '0'
        jb      .done
        cmp     bl, '9'
        ja      .done
        mov     dx, 10
        push    dx
        mul     word [si_ten]
        pop     dx
        sub     bl, '0'
        xor     bh, bh
        add     ax, bx
        inc     si
        inc     cx
        jmp     .digit
.done:
        or      cx, cx
        jz      .bad
        clc
        ret
.bad:
        stc
        ret
si_ten: dw      10

; ======================================================================
;  /T -- acquire, listen, report, release. NEVER goes resident.
;
;  This is the whole point of having a test mode: the dangerous thing here
;  is a far pointer into our code held by the driver, and this proves the
;  receive path start to finish while guaranteeing the pointer is given back
;  before the program exits.
; ======================================================================
do_test:
        mov     dx, msg_tbeg
        call    puts

        call    findpd
        jnc     .gotpd
        mov     dx, msg_nopd
        call    puts
        mov     al, 2
        jmp     bye
.gotpd:
        mov     dx, msg_pdat
        call    puts
        mov     al, [pdint]
        xor     ah, ah
        call    puthex
        mov     dx, msg_crlf
        call    puts

        call    acquire
        jnc     .got
        mov     dx, msg_noacc
        call    puts
        mov     al, 3
        jmp     bye
.got:
        mov     dx, msg_listen
        call    puts
        mov     ax, [port]
        call    putdec
        mov     dx, msg_crlf
        call    puts

        ; Listen for 15 seconds, printing each key as it arrives.
        ;
        ; NOTE this prints -- calls DOS -- while the handle is HELD, which
        ; pktcap.pas forbids outright. The rule there exists because ITS
        ; receiver could be re-entered while the main line sat inside DOS.
        ; This receiver touches nothing but our own memory: no INT 21h, no
        ; WriteLn, no buffers DOS owns. So an interrupt landing mid-print is
        ; harmless here, and printing live is the entire point of a test mode.
        ; If this receiver ever grows a DOS call, that stops being true.
        call    tick
        mov     [t0], ax

.loop:
        call    ringget
        jnc     .nokey
        mov     ax, bx
        call    puthex
        mov     dl, ' '
        mov     ah, 02h
        int     21h
.nokey:
        ; stop after ~15s (273 ticks) or if a real key is pressed
        call    tick
        sub     ax, [t0]
        cmp     ax, 273
        jae     .stop
        mov     ah, 01h
        int     16h                    ; our hook is NOT installed in /T mode
        jz      .loop
.stop:
        call    release

        mov     dx, msg_crlf
        call    puts
        mov     dx, msg_frames
        call    puts
        mov     ax, [nframe]
        call    putdec
        mov     dx, msg_keys
        call    puts
        mov     ax, [nkeys]
        call    putdec
        mov     dx, msg_ip
        call    puts
        mov     ax, [n_ip]
        call    putdec
        mov     dx, msg_udp
        call    puts
        mov     ax, [n_udp]
        call    putdec
        mov     dx, msg_port
        call    puts
        mov     ax, [n_port]
        call    putdec
        mov     dx, msg_mag
        call    puts
        mov     ax, [n_mag]
        call    putdec
        mov     dx, msg_drops
        call    puts
        mov     ax, [ndrop]
        call    putdec
        mov     dx, msg_crlf
        call    puts
        mov     dx, msg_treleased
        call    puts
        xor     al, al
        jmp     bye

t0:     dw      0

; ---- find our own resident copy: the signature sits at 103h in the
;      segment INT 16h points into, exactly as KINJ does it -------------
findres:
        push    ax
        push    bx
        push    cx
        push    si
        push    di
        mov     ax, 3516h
        int     21h                    ; ES:BX = current INT 16h
        mov     si, sig
        mov     di, sig
        mov     cx, 6
        push    ds
        push    cs
        pop     ds
.cmp:
        mov     al, [si]
        cmp     al, [es:di]
        jne     .no
        inc     si
        inc     di
        loop    .cmp
        pop     ds
        jmp     .yes
.no:
        pop     ds
        pop     di
        pop     si
        pop     cx
        pop     bx
        pop     ax
        stc
        ret
.yes:
        pop     di
        pop     si
        pop     cx
        pop     bx
        pop     ax
        clc
        ret

; ======================================================================
;  Install
; ======================================================================
do_install:
        call    findres
        jnc     .already

        call    findpd
        jnc     .gotpd
        mov     dx, msg_nopd
        call    puts
        mov     al, 2
        jmp     bye
.gotpd:
        call    acquire
        jnc     .got
        mov     dx, msg_noacc
        call    puts
        mov     al, 3
        jmp     bye
.got:
        ; Hook INT 16h only AFTER the handle is in hand. If acquire had
        ; failed we would otherwise be resident, hooked and useless -- and
        ; unhooking is the part that needs us to still be here.
        mov     ax, 3516h
        int     21h
        mov     [old16], bx
        mov     [old16 + 2], es
        push    ds
        mov     dx, int16
        push    cs
        pop     ds
        mov     ax, 2516h
        int     21h
        pop     ds

        call    tick                   ; start the idle clock now, not at the
        mov     [lastact], ax          ; first keystroke that may never come

        mov     dx, msg_ins
        call    puts
        mov     ax, [port]
        call    putdec
        mov     dx, msg_crlf
        call    puts

        ; Paragraphs to keep, computed at run time: NASM will not apply >>
        ; to a label-derived value in a flat binary, and shift-by-CL is
        ; 8086-legal where shift-by-immediate is not.
        mov     dx, resend + 15
        mov     cl, 4
        shr     dx, cl
        mov     ax, 3100h
        int     21h
.already:
        mov     dx, msg_already
        call    puts
        mov     al, 1
        jmp     bye

; ======================================================================
;  Status
; ======================================================================
do_status:
        call    findres
        jc      .none
        mov     dx, msg_res
        call    puts
        mov     ax, [es:port]
        call    putdec
        mov     dx, msg_sframes
        call    puts
        mov     ax, [es:nframe]
        call    putdec
        mov     dx, msg_skeys
        call    puts
        mov     ax, [es:nkeys]
        call    putdec
        mov     dx, msg_ssent
        call    puts
        mov     ax, [es:nsent]
        call    putdec
        cmp     byte [es:relsd], 0
        je      .holding
        mov     dx, msg_gaveback
        call    puts
.holding:
        mov     dx, msg_crlf
        call    puts
        xor     al, al
        jmp     bye
.none:
        mov     dx, msg_notres
        call    puts
        mov     al, 1
        jmp     bye

; ======================================================================
;  Unload
;
;  ORDER MATTERS AND IS THE WHOLE POINT. release_type FIRST, while the
;  memory the driver holds a pointer into is still ours; then unhook; then
;  free. Free it first and the driver is left calling into a block DOS has
;  handed to the next program -- which takes the network down, and the
;  bridge runs over that network.
; ======================================================================
do_unload:
        call    findres
        jc      .none

        ; If the watchdog already gave the handle back, releasing it again
        ; fails -- correctly -- and printing that as an error would report a
        ; normal idle unload as a fault.
        cmp     byte [es:relsd], 0
        jne     .released

        ; release the handle, using the RESIDENT copy's driver and handle
        mov     al, [es:pdint]
        mov     [pdopc], al
        mov     ah, 03h
        mov     bx, [es:handle]
        call    callpd
        jnc     .released
        mov     dx, msg_norel
        call    puts
        ; Deliberately carry on: leaving it hooked as well would be worse,
        ; and the message above says exactly what happened.
.released:
        push    es
        push    ds
        mov     ax, [es:old16]         ; restore from the RESIDENT copy --
        mov     dx, ax                 ; ours is zero
        mov     ax, [es:old16 + 2]
        mov     ds, ax
        mov     ax, 2516h
        int     21h
        pop     ds
        pop     es

        mov     ah, 49h                ; free its block; ES is its PSP
        int     21h
        jc      .nofree
        mov     dx, msg_unl
        call    puts
        xor     al, al
        jmp     bye
.nofree:
        mov     dx, msg_nofree
        call    puts
        mov     al, 4
        jmp     bye
.none:
        mov     dx, msg_notres
        call    puts
        mov     al, 1
        jmp     bye

bye:
        mov     ah, 4Ch
        int     21h

msg_use:   db 'KNET -- live remote keyboard over UDP', 13, 10
           db '  KNET /T        listen and report, never resident', 13, 10
           db '  KNET [port]    go resident (default 8071)', 13, 10
           db '  KNET /W<secs>  idle seconds before the handle is', 13, 10
           db '                 released automatically (default 120)', 13, 10
           db '  KNET /S        status', 13, 10
           db '  KNET /U        release and unhook', 13, 10, '$'
msg_tbeg:  db 'KNET: test mode -- nothing will stay resident', 13, 10, '$'
msg_nopd:  db 'KNET: no packet driver found in 60h..80h', 13, 10, '$'
msg_pdat:  db 'KNET: packet driver at INT $'
msg_noacc: db 'KNET: access_type refused -- is something else holding IP?', 13, 10, '$'
msg_listen: db 'KNET: listening on UDP port $'
msg_frames: db 'KNET: frames seen  : $'
msg_keys:   db 13, 10, 'KNET: keys queued  : $'
msg_ip:     db 13, 10, 'KNET:   ethertype 0800: $'
msg_udp:    db 13, 10, 'KNET:   protocol UDP  : $'
msg_port:   db 13, 10, 'KNET:   our port      : $'
msg_mag:    db 13, 10, 'KNET:   our magic     : $'
msg_drops:  db 13, 10, 'KNET: frames dropped: $'
msg_treleased: db 'KNET: handle released, not resident', 13, 10, '$'
msg_ins:    db 'KNET: installed, listening on UDP port $'
msg_already: db 'KNET: already resident -- /U first', 13, 10, '$'
msg_res:    db 'KNET: resident on port $'
msg_sframes: db ', frames $'
msg_skeys:  db ', queued $'
msg_ssent:  db ', delivered $'
msg_gaveback: db ' -- IDLE, handle given back (run /U to unload)$'
msg_notres: db 'KNET: not resident', 13, 10, '$'
msg_unl:    db 'KNET: handle released, unhooked, unloaded', 13, 10, '$'
msg_norel:  db 'KNET: release_type FAILED -- unhooking anyway', 13, 10, '$'
msg_nofree: db 'KNET: could not free the block', 13, 10, '$'
msg_crlf:  db 13, 10, '$'

; ----------------------------------------------------------------------
;  Buffers past the end of the file image, so the .COM stays small. DOS
;  gives a .COM the whole segment, so this space is ours already.
; ----------------------------------------------------------------------
buffers:
ring        equ buffers
pktbuf      equ ring + RINGN * 2
resend      equ pktbuf + PKTMAX
