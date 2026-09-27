; KINJ.COM  --  DOS Bridge  --  StevenC & Claude
;
; A resident keystroke injector and screen grabber, so an INTERACTIVE program
; on the DOS box can be driven and watched from Windows.
;
;   KINJ file.KI    load a script and go resident (or reload if already there)
;   KINJ /U         unhook and free
;   KINJ /D         print the captured screens as text
;   KINJ /S         say what is installed and how far through the script it is
;
; WHY THIS HAS TO BE RESIDENT, AND WHY THE SCRIPT IS LOADED UP FRONT.
;
; The bridge runs a job as a batch of commands, one after another, and DOS is
; single-tasking: while the target program is running, NOTHING else on the box
; runs.  So a keystroke cannot be delivered by another program, and a screen
; cannot be read by one either -- there is no "meanwhile".  The only code that
; executes during someone else's program is an interrupt handler, which is why
; this is a TSR.
;
; DOS is also not reentrant, so the handler cannot open a file to read the next
; keystroke or write out a capture.  Both sides of that are solved the same
; way: the script is read into resident memory at install time, when we are an
; ordinary program and DOS is ours to call, and the captures are buffered in
; resident memory and written out by a later invocation.  Nothing in the
; handler touches DOS at all.
;
; WHY INT 16h AND NOT A TIMER.
;
; The obvious injector hooks the timer and stuffs the BIOS keyboard buffer on a
; schedule.  Hooking INT 16h is strictly better: there is no timing to get
; right, no 15-entry ceiling, and no race with the target draining the buffer,
; because the keystroke is manufactured at the moment it is asked for.  It is
; also less code -- a switch on the function number.
;
; WHAT IT CANNOT DRIVE.  A program that reads the keyboard hardware itself by
; hooking INT 9 never calls INT 16h, so it never sees any of this.  That is
; most games, and it is RAYCAST KEYS.  Reaching those needs the keyboard
; controller (8042 command D2h) and is a different, riskier program.
;
; SNAPSHOTS ARE TAKEN WHEN THE PROGRAM ASKS FOR A KEY, which is exactly the
; moment worth photographing: it has finished drawing and is waiting.  No timer
; and no polling, so there is nothing to race.

%ifndef __MININASM__
cpu 8086
%endif

        org     100h

MAXK     equ    1024                   ; script words
MAXSNAP  equ    6
SNAPW    equ    80
SNAPH    equ    25
SNAPSZ   equ    SNAPW * SNAPH          ; characters only; attributes are not
                                       ; what an ASCII grab is for
FLG_ZF   equ    0040h

; Script words.  A real INT 16h result is never 0, 1, 2 or FFFFh -- AH holds a
; scancode and AL an ASCII code, and every key sets at least one of them -- so
; these can double as opcodes without an escape.
OP_SNAP  equ    0000h
OP_DELAY equ    0001h                  ; followed by a word: ticks between keys
OP_PAUSE equ    0002h                  ; followed by a word: ticks to wait now
OP_END   equ    0FFFFh

start:  jmp     init

; ----------------------------------------------------------------------
;  Resident data.  Fixed offsets: the transient copy and the resident copy
;  are the same image, so /U /D /S reach these through the resident segment
;  at exactly these labels.
; ----------------------------------------------------------------------
sig:    db      'KINJ01'               ; at 103h -- how we find ourselves
old16:  dd      0
kptr:   dw      0                      ; offset of the next script word
kend:   dw      0                      ; offset one past the last
kdelay: dw      2                      ; ticks between keys
kdue:   dw      0                      ; tick at which the next key may go
nsnap:  dw      0                      ; snapshots taken
nkeys:  dw      0                      ; keys delivered
fin:    db      0                      ; script exhausted: chain from here on

; ----------------------------------------------------------------------
;  The INT 16h handler
; ----------------------------------------------------------------------
int16:
        cmp     ah, 00h
        je      .read
        cmp     ah, 10h
        je      .read
        cmp     ah, 01h
        je      .peek
        cmp     ah, 11h
        je      .peek
.chain:
        jmp     far [cs:old16]         ; caller's flags stay on the stack and
                                       ; the old handler's IRET returns to it

; ---- AH=01h/11h: is a key available?  Must not consume one. ----
.peek:
        cmp     byte [cs:fin], 0
        jne     .chain
        push    bp
        mov     bp, sp                 ; bp+2 IP, bp+4 CS, bp+6 FLAGS
        push    bx
        call    scan                   ; CF=1 and BX=key if one is due now
        jnc     .peek_none
        and     word [bp+6], ~FLG_ZF   ; ZF=0: a key is waiting
        mov     ax, bx
        pop     bx
        pop     bp
        iret
.peek_none:
        ; Nothing from us yet -- either mid-delay, or the script just ended.
        cmp     byte [cs:fin], 0
        jne     .peek_chain
        or      word [bp+6], FLG_ZF    ; ZF=1: no key
        xor     ax, ax
        pop     bx
        pop     bp
        iret
.peek_chain:
        pop     bx
        pop     bp
        jmp     .chain

; ---- AH=00h/10h: read a key, waiting for one. ----
.read:
        cmp     byte [cs:fin], 0
        jne     .chain
        push    bx
.rwait:
        call    scan
        jc      .rgot
        cmp     byte [cs:fin], 0
        jne     .rchain
        ; Mid-delay.  The caller asked to WAIT, so wait -- with interrupts on,
        ; or the BIOS tick never advances and this spins forever.
        sti
        jmp     .rwait
.rgot:
        call    consume
        mov     ax, bx
        pop     bx
        iret
.rchain:
        pop     bx
        jmp     .chain

; ----------------------------------------------------------------------
;  scan -- walk the script, executing SNAP/DELAY/PAUSE as it goes.
;
;  out:  CF=1, BX = the key that is due now
;        CF=0 and fin=0   -> a key is next but its delay has not expired
;        CF=0 and fin<>0  -> the script is finished
;  Everything is CS-relative: DS belongs to whoever was interrupted.
; ----------------------------------------------------------------------
scan:
        push    ax
        push    dx
        push    si
.next:
        mov     si, [cs:kptr]
        cmp     si, [cs:kend]
        jae     .done
        mov     ax, [cs:si]
        cmp     ax, OP_END
        je      .done
        or      ax, ax
        je      .snap
        cmp     ax, OP_DELAY
        je      .setdelay
        cmp     ax, OP_PAUSE
        je      .pause
        ; A key.  Due yet?
        call    tick
        sub     dx, [cs:kdue]
        js      .waiting               ; tick < kdue
        mov     bx, ax
        pop     si
        pop     dx
        pop     ax
        stc
        ret
.waiting:
        pop     si
        pop     dx
        pop     ax
        clc
        ret
.snap:
        ; A SNAP obeys PAUSE and DELAY exactly as a key does. Without this it
        ; fires on the very first poll after install -- which is COMMAND.COM
        ; checking for Ctrl-C between two batch commands, so the photograph
        ; is of the batch file's own screen and not of the program the script
        ; was written to watch.
        call    tick
        sub     dx, [cs:kdue]
        js      .waiting
        call    grab
        add     word [cs:kptr], 2
        jmp     .next
.setdelay:
        mov     ax, [cs:si+2]
        mov     [cs:kdelay], ax
        add     word [cs:kptr], 4
        jmp     .next
.pause:
        call    tick
        add     dx, [cs:si+2]
        mov     [cs:kdue], dx
        add     word [cs:kptr], 4
        jmp     .next
.done:
        mov     byte [cs:fin], 1
        pop     si
        pop     dx
        pop     ax
        clc
        ret

; Consume the key scan just reported, and set when the next one may go.
consume:
        push    ax
        push    dx
        add     word [cs:kptr], 2
        inc     word [cs:nkeys]
        call    tick
        add     dx, [cs:kdelay]
        mov     [cs:kdue], dx
        pop     dx
        pop     ax
        ret

; DX = the low word of the BIOS tick at 0040:006Ch.
;
; Read directly rather than through INT 1Ah AH=00h: that call returns the
; midnight-rollover flag in AL and CLEARS it, and DOS reads the same flag to
; advance the date -- so a clock built on it occasionally eats a day.  Same
; reasoning as ELAPSED.COM.
tick:
        push    ax
        push    es
        mov     ax, 40h
        mov     es, ax
        mov     dx, [es:6Ch]
        pop     es
        pop     ax
        ret

; ----------------------------------------------------------------------
;  grab -- copy the text screen into the next snapshot slot.
;
;  Safe from inside the handler: it is a memory copy and touches no DOS and
;  no BIOS call.  Characters only, every other byte, because an ASCII grab
;  has no use for the attribute plane.
; ----------------------------------------------------------------------
grab:
        push    ax
        push    bx
        push    cx
        push    dx
        push    si
        push    di
        push    ds
        push    es

        mov     ax, [cs:nsnap]
        cmp     ax, MAXSNAP
        jae     .full

        ; Where to put it: snaps + nsnap*SNAPSZ.  SNAPSZ is 2000, so this is
        ; a real multiply -- but it runs a handful of times a session.
        mov     bx, SNAPSZ
        mul     bx
        add     ax, snaps
        mov     di, ax

        ; Mono text lives at B000, colour at B800.  The mode can change while
        ; a program runs, so it is read now rather than assumed.
        mov     ax, 40h
        mov     ds, ax
        mov     al, [49h]              ; current BIOS video mode
        mov     bx, 0B800h
        cmp     al, 7
        jne     .seg_ok
        mov     bx, 0B000h
.seg_ok:
        mov     ds, bx
        push    cs
        pop     es

        xor     si, si
        mov     cx, SNAPSZ
.copy:
        mov     al, [si]               ; character; skip the attribute byte
        cmp     al, 32
        jae     .keep
        mov     al, ' '                ; NUL fills a cleared screen, and a
.keep:                                 ; control code would corrupt the dump
        cmp     al, 127
        jne     .store
        mov     al, ' '
.store:
        mov     [es:di], al
        inc     di
        inc     si
        inc     si
        loop    .copy

        inc     word [cs:nsnap]
.full:
        pop     es
        pop     ds
        pop     di
        pop     si
        pop     dx
        pop     cx
        pop     bx
        pop     ax
        ret

; ----------------------------------------------------------------------
;  Transient: everything below runs once, as an ordinary program.
; ----------------------------------------------------------------------

; Find the resident copy.  ES = its segment, CF=0 if found.
;
; It is located through the INT 16h vector, so this only finds us while we
; are the CURRENT owner.  A TSR loaded after us takes the vector and we
; become invisible -- which is the right way round: uninstalling out of turn
; would leave the later hook pointing into freed memory.
findres:
        push    ax
        push    bx
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
        pop     di
        pop     si
        pop     bx
        pop     ax
        clc
        ret
.no:
        pop     ds
        pop     di
        pop     si
        pop     bx
        pop     ax
        stc
        ret

init:
        mov     si, 81h                ; the command tail
.skip:
        lodsb
        cmp     al, ' '
        je      .skip
        cmp     al, 9
        je      .skip
        cmp     al, 13
        je      .usage
        cmp     al, '/'
        je      .switch
        cmp     al, '-'
        je      .switch
        dec     si
        jmp     do_load

.switch:
        lodsb
        and     al, 0DFh               ; upper-case it
        cmp     al, 'U'
        je      do_unload
        cmp     al, 'D'
        je      do_dump
        cmp     al, 'S'
        je      do_status
.usage:
        mov     dx, msg_use
        jmp     die

; ---- /S ----
do_status:
        call    findres
        jc      .none
        mov     dx, msg_in
        call    puts
        mov     ax, [es:nkeys]
        call    putnum
        mov     dx, msg_keys
        call    puts
        mov     ax, [es:nsnap]
        call    putnum
        mov     dx, msg_snaps
        call    puts
        cmp     byte [es:fin], 0
        je      .running
        mov     dx, msg_donez
        call    puts
.running:
        mov     dx, msg_crlf           ; one line ending, after whichever of
        call    puts                   ; the two tails above was printed
        jmp     ok
.none:
        mov     dx, msg_out
        call    puts
        jmp     ok

; ---- /U ----
do_unload:
        call    findres
        jc      .none
        push    es
        push    ds
        mov     ax, [es:old16]         ; restore the vector from the resident
        mov     dx, ax                 ; copy, not from ours -- ours is zero
        mov     ax, [es:old16+2]
        mov     ds, ax
        mov     ax, 2516h
        int     21h
        pop     ds
        pop     es
        mov     ah, 49h                ; free its block. ES is already its
        int     21h                    ; segment, which for a .COM is its PSP
        jc      .nofree
        mov     dx, msg_unl
        call    puts
        jmp     ok
.nofree:
        mov     dx, msg_nofree
        jmp     die
.none:
        mov     dx, msg_out
        jmp     die

; ---- /D ----
do_dump:
        call    findres
        jc      .none
        mov     cx, [es:nsnap]
        or      cx, cx
        jne     .some
        mov     dx, msg_nosnap
        call    puts
        jmp     ok
.some:
        mov     word [snapno], 0
.each:
        push    cx
        mov     dx, msg_shot
        call    puts
        mov     ax, [snapno]
        inc     ax
        call    putnum
        mov     dx, msg_of
        call    puts
        mov     ax, [es:nsnap]
        call    putnum
        mov     dx, msg_nl
        call    puts

        ; source = snaps + snapno*SNAPSZ, in the resident segment
        mov     ax, [snapno]
        mov     bx, SNAPSZ
        mul     bx
        add     ax, snaps
        mov     si, ax
        mov     word [rowno], 0
.row:
        ; copy one row out of the resident buffer into our own line, so the
        ; trailing-space trim and the DOS write both work on our own data
        mov     di, line
        mov     cx, SNAPW
.col:
        mov     al, [es:si]
        mov     [di], al
        inc     si
        inc     di
        loop    .col
        ; trim trailing spaces: 80 columns of padding on every row is most of
        ; the output and none of the information
        mov     di, line + SNAPW - 1
.trim:
        cmp     di, line
        jb      .emit
        cmp     byte [di], ' '
        jne     .emit
        dec     di
        jmp     .trim
.emit:
        inc     di
        mov     byte [di], 13
        inc     di
        mov     byte [di], 10
        inc     di
        mov     cx, di
        sub     cx, line
        mov     dx, line
        mov     bx, 1
        mov     ah, 40h
        int     21h
        inc     word [rowno]
        cmp     word [rowno], SNAPH
        jb      .row
        inc     word [snapno]
        pop     cx
        loop    .each
        jmp     ok
.none:
        mov     dx, msg_out
        jmp     die

; ---- load a script ----
;
; SI points at the filename in the command tail.  Terminate it in place and
; open it.
do_load:
        mov     di, si
.term:
        lodsb
        cmp     al, 13
        je      .gotend
        cmp     al, ' '
        je      .gotend
        cmp     al, 9
        jne     .term
.gotend:
        dec     si
        mov     byte [si], 0
        mov     dx, di
        mov     ax, 3D00h              ; open read-only
        int     21h
        jnc     .opened
        mov     dx, msg_noopen
        jmp     die
.opened:
        mov     [fh], ax

        ; header: 'KI01' then a word count
        mov     bx, [fh]
        mov     cx, 6
        mov     dx, hdr
        mov     ah, 3Fh
        int     21h
        jc      .badf
        cmp     ax, 6
        jne     .badf
        cmp     word [hdr], 'KI'
        jne     .badf
        cmp     word [hdr+2], '01'
        jne     .badf
        mov     ax, [hdr+4]
        cmp     ax, MAXK
        jbe     .sizeok
        mov     ax, MAXK
.sizeok:
        mov     [wcount], ax

        ; Read straight into the buffer.  If we are already resident the
        ; buffer belongs to the RESIDENT copy, not to this one -- so read into
        ; ours first and copy, which keeps the DOS call pointing at memory
        ; this process owns.
        shl     ax, 1
        mov     cx, ax
        mov     dx, keys
        mov     bx, [fh]
        mov     ah, 3Fh
        int     21h
        jc      .badf
        mov     [gotbytes], ax
        mov     bx, [fh]
        mov     ah, 3Eh
        int     21h

        call    findres
        jc      .install

        ; Already resident: refill it and reset, rather than stacking a second
        ; copy on the vector.  Repeated sessions are the normal case.
        mov     si, keys
        mov     di, keys
        mov     cx, [gotbytes]
        jcxz    .norefill
.refill:
        mov     al, [si]
        mov     [es:di], al
        inc     si
        inc     di
        loop    .refill
.norefill:
        mov     ax, keys
        mov     [es:kptr], ax
        add     ax, [gotbytes]
        mov     [es:kend], ax
        mov     word [es:kdue], 0
        mov     word [es:nkeys], 0
        mov     word [es:nsnap], 0
        mov     byte [es:fin], 0
        mov     dx, msg_re
        call    puts
        jmp     ok

.install:
        mov     ax, keys
        mov     [kptr], ax
        add     ax, [gotbytes]
        mov     [kend], ax

        mov     ax, 3516h              ; save the old vector
        int     21h
        mov     [old16], bx
        mov     [old16+2], es

        push    ds
        mov     dx, int16
        push    cs
        pop     ds
        mov     ax, 2516h
        int     21h
        pop     ds

        mov     dx, msg_ins
        call    puts

        ; Keep everything up to the end of the snapshot buffers.  The transient
        ; code above stays resident too -- a few hundred wasted bytes against
        ; the complication of moving it, which is not a trade worth making.
        ; Paragraphs to keep.  Computed at run time with a shift by CL --
        ; NASM will not apply >> to a label-derived value in a flat binary,
        ; and shift-by-CL is 8086-legal where shift-by-immediate is not.
        mov     dx, resend + 15
        mov     cl, 4
        shr     dx, cl
        mov     ax, 3100h
        int     21h

.badf:
        mov     bx, [fh]
        mov     ah, 3Eh
        int     21h
        mov     dx, msg_badf
        jmp     die

; ---- small helpers ----
puts:                                  ; DS:DX = $-terminated
        push    ax
        mov     ah, 9
        int     21h
        pop     ax
        ret

putnum:                                ; AX unsigned, no padding
        push    ax
        push    bx
        push    cx
        push    dx
        mov     bx, 10
        xor     cx, cx
.div:
        xor     dx, dx
        div     bx
        add     dl, '0'
        push    dx
        inc     cx
        or      ax, ax
        jne     .div
.out:
        pop     dx
        mov     ah, 2
        int     21h
        loop    .out
        pop     dx
        pop     cx
        pop     bx
        pop     ax
        ret

die:
        call    puts
        mov     ax, 4C01h
        int     21h
ok:
        mov     ax, 4C00h
        int     21h

msg_use:    db 'KINJ file.KI | /U unload | /D dump screens | /S status',13,10,'$'
msg_ins:    db 'KINJ: installed',13,10,'$'
msg_re:     db 'KINJ: script reloaded',13,10,'$'
msg_unl:    db 'KINJ: unloaded',13,10,'$'
msg_in:     db 'KINJ: resident, $'
msg_keys:   db ' key(s) sent, $'
msg_snaps:  db ' snapshot(s)$'
msg_donez:  db ', script finished$'
msg_out:    db 'KINJ: not resident',13,10,'$'
msg_noopen: db 'KINJ: cannot open that script',13,10,'$'
msg_badf:   db 'KINJ: not a KI01 script',13,10,'$'
msg_nofree: db 'KINJ: unhooked but could not free the block',13,10,'$'
msg_nosnap: db 'KINJ: no snapshots were taken',13,10,'$'
msg_shot:   db 13,10,'--- KINJ screen $'
msg_of:     db ' of $'
msg_nl:     db ' ---',13,10,'$'
msg_crlf:   db 13,10,'$'

fh:         dw 0
hdr:        times 6 db 0
wcount:     dw 0
gotbytes:   dw 0
snapno:     dw 0
rowno:      dw 0
line:       times SNAPW + 4 db 0

; Buffers past the end of the file image.  A .COM is given the whole segment,
; so this memory exists without being stored -- `times` here would put 13 KB
; of zeros in the binary for nothing.
buffers:
keys        equ buffers
snaps       equ buffers + MAXK * 2
resend      equ snaps + MAXSNAP * SNAPSZ
