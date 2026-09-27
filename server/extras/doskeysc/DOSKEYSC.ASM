;=============================================================================
; DOSKEYSC -- DOSKEY for MS-DOS 5 and later, with TAB filename completion.
; StevenC & Claude, 2026.  Public domain.
;
; Everything MS-DOS 6.22's DOSKEY does -- line editing, the DOS template keys
; F1-F6, history (Up, Down, PgUp, PgDn, F7, F8, F9, Alt+F7), macros with
; $1-$9 $* $T $G $L $B $$, Alt+F10, /BUFSIZE /HISTORY /MACROS /INSERT
; /OVERSTRIKE /REINSTALL -- with the same result on the screen, key for key.
; It is written from a study of 6.22's DOSKEY and contains none of its code.
;
; Added: TAB completes the file or directory name being typed; TAB again
; steps to the next match, SHIFT+TAB to the previous one, in name order.
; /NOTAB turns that off (TAB then inserts a tab, as 6.22's does), /TAB back.
;
; The resident part keeps 6.22's data layout for the words both DOSKEYs'
; command lines read and write (history, macros, insert mode), so each can
; list and change the other's: 6.22's DOSKEY /M works with this one loaded.
;
;   nasm -f bin -o DOSKEYSC.COM DOSKEYSC.ASM
;=============================================================================

        cpu     8086
        org     100h

start:  jmp     init

;---------------------------------------------------------------- resident data
; 103h-243h: the same places and meanings as 6.22's DOSKEY.

%macro  place 1
        times   (%1) - ($ - $$ + 100h) db 0
%endmacro

        place   103h
v_bufp  dd      0               ; the caller's line buffer
v_mbeg  dw      0               ; macros: first byte
v_mend  dw      0               ;         end of the used part
v_mlim  dw      0               ;         end of the macro area
v_hbeg  dw      0               ; history ring: first byte
v_hnew  dw      0               ;         where the next line goes
v_hold  dw      0               ;         oldest line
v_bend  dw      0               ;         end of the whole buffer
v_hcur  dw      0               ;         line being recalled; 0 = empty
v_insd  db      0               ; FFh = insert mode is the default
v_segp  dw      0               ; macro/^T expansion: where the args are
v_macp  dw      0               ;         where in the macro text
v_cols  dw      0               ; screen columns
v_page  db      0
v_col   db      0               ; column we think the cursor is in
v_srow  db      0               ; saved cursor
v_scol  db      0
v_wrap  db      0               ; lines wrapped since the cursor was saved
v_shape dw      0               ; cursor shape on entry
v_tlen  dw      0               ; template length
v_line  times 129 db 0          ; 127h: the line, which is also the template
v_wid   times 128 db 0          ; 1A8h: screen width of each character
v_len   dw      0               ; 228h: line length
v_cur   dw      0               ; 22Ah: cursor
v_flags db      0               ; 22Ch: 1 insert, 2 edited, 4 more to hand
                                ;       out, 8 expanding a macro
v_dig   times 5 db 0            ; 22Dh: F9's digits
v_ioctl db      0, 0            ; 232h: generic IOCTL 037Fh, get display mode
        dw      14, 0
v_vmode db      0, 0            ; 238h: 1 = text
        dw      0, 0, 0, 0
v_rows  dw      0               ; 242h

;------------------------------------------------------- ours from here on
        place   244h
sig     db      'DKSC'          ; our resident, as opposed to 6.22's
        db      1               ; layout version
v_opts  db      1               ; 1 = TAB completes
tc_on   db      0               ; a TAB cycle: 1 begun, 2 a name is in
tc_dir  db      0               ; its word's directory part, in bytes
tc_ws   dw      0               ; its word's start in the line
tc_last times 13 db 0           ; the name it last put in
tc_best times 14 db 0           ; while searching: best so far + attribute
tc_wrap times 14 db 0           ;                  wrap-around choice
tc_back db      0               ; 1 = SHIFT+TAB
tc_pos  dw      0               ; where the name goes in the line
tc_nl   dw      0               ; its length
tc_tail dw      0               ; what follows the cursor
tc_odta dd      0
tc_vec  dw      t_i23, 0, t_i24, 0  ; INT 23h, 24h: ours, or the saved ones
old2f   dd      0
ten     dw      10
s_more  db      13, 10, '-- More --', 0
s_linen db      'Line number: ', 0

win_sis dw      3               ; Windows startup: version 3.0
win_nxt dd      0
        dd      0, 0
        dw      win_ins
win_seg dw      0
win_ins dw      v_bufp          ; instance data: our variables...
win_s1  dw      0
        dw      v_end - v_bufp
win_b   dw      0               ; ...the history and macros...
win_s2  dw      0
win_bl  dw      0
        dw      TC_PAT          ; ...and the completion scratch in the PSP
win_s3  dw      0
        dw      TC_END - TC_PAT
        dd      0
v_end:

; scratch kept in the PSP, which nothing uses once we are resident
TC_PAT  equ     5Ch             ; the search pattern, up to 80 bytes
TC_DTA  equ     0ACh            ; find-first's 43 bytes
TC_END  equ     0D8h

;------------------------------------------------------------------- INT 2Fh
int2f:  cmp     ax, 1605h               ; Windows starting
        je      .win
        cmp     ax, 4B05h               ; task switcher wants instance data
        je      .win
        cmp     ah, 48h
        je      .ours
.chain: jmp     far [cs:old2f]
.win:   pushf
        call    far [cs:old2f]
        mov     [cs:win_nxt], bx
        mov     [cs:win_nxt+2], es
        push    cs
        pop     es
        mov     bx, win_sis
        iret
.ours:  cmp     al, 10h
        jne     .inst
        xchg    dx, bx
        cmp     byte [bx], 80h          ; only COMMAND.COM's 128-byte buffer
        xchg    dx, bx
        jne     .chain
        sti
        call    readline
        xor     ax, ax
        iret
.inst:  or      al, al
        jne     .chain
        push    cs
        pop     es
        mov     ax, 0AA02h
        iret

;------------------------------------------------ INT 2Fh AX=4810h: one line
readline:
        push    ax
        push    bx
        push    cx
        push    dx
        push    si
        push    di
        push    bp
        push    ds
        push    es
        cld
        mov     [cs:v_bufp], dx
        mov     [cs:v_bufp+2], ds
        push    cs
        pop     ds
        push    cs
        pop     es
        test    byte [v_flags], 4
        jnz     .more
        call    edit
        mov     si, v_line
        mov     cx, [v_len]
        or      cx, cx
        jz      .noadd
        call    h_add
.noadd: mov     si, [v_len]
        mov     byte [si+v_line], 13
        mov     word [v_segp], v_line
        call    m_look
        jc      .empty
        mov     di, [v_segp]
        mov     cx, [v_len]
        mov     al, 14h                 ; a ^T typed in the line splits it
        jcxz    .copy
        repne   scasb
        je      .empty
.copy:  les     di, [v_bufp]
        mov     si, v_line
        mov     cx, [v_len]
        inc     di
        mov     [es:di], cl
        inc     di
        rep     movsb
        mov     al, 13
        stosb
        jmp     .done
.empty: or      byte [v_flags], 4       ; hand back nothing now, the parts next
        les     di, [v_bufp]
        mov     word [es:di+1], 0D00h
        jmp     .done

; the next command of a macro or a ^T line
.more:  les     di, [v_bufp]
        inc     di
        inc     di
        mov     cx, 80h
        dec     cx
        test    byte [v_flags], 8
        jnz     .mac
        jmp     .seg
.mac:   mov     si, [v_macp]
.mc:    lodsb
        or      al, al
        je      .mend
        cmp     al, 14h
        je      .msep
        cmp     al, '$'
        jne     .mput
        lodsb
        or      al, al
        je      .mend
        cmp     al, 14h
        je      .msep
        cmp     al, '*'
        je      .star
        cmp     al, '1'
        jb      .mput
        cmp     al, '9'
        jbe     .parm
.mput:  stosb
        call    dchar
        loop    .mc
.mskip: lodsb                           ; full: drop the rest of this command
        or      al, al
        je      .mend
        cmp     al, 14h
        jne     .mskip
.msep:  mov     [v_macp], si
        jmp     .fin
.mend:  and     byte [v_flags], 0F3h
        mov     si, [v_segp]            ; a ^T after the macro's arguments?
        mov     cx, [v_len]
        jcxz    .mend2
.mt:    lodsb
        cmp     al, 14h
        loopne  .mt
        jne     .mend2
        or      byte [v_flags], 4
        mov     [v_segp], si
        mov     [v_len], cx
        push    es
        push    di
        push    cs
        pop     es
        call    m_look
        pop     di
        pop     es
.mend2: jmp     .fin

.star:  push    si                      ; $*: all the arguments
        mov     si, [v_segp]
        mov     bx, [v_len]
.st1:   or      bx, bx
        je      .pdone
        dec     bx
        lodsb
        cmp     al, ' '
        je      .st1
        cmp     al, 9
        je      .st1
        dec     si
        inc     bx
.st2:   or      bx, bx
        je      .pdone
        dec     bx
        lodsb
        cmp     al, 14h
        je      .pdone
        stosb
        call    dchar
        loop    .st2
.pfull: pop     si
        jmp     .mskip
.pdone: pop     si
        jmp     .mc

.parm:  push    si                      ; $1-$9
        mov     si, [v_segp]
        mov     bx, [v_len]
        sub     al, '0'
        mov     ah, al
.pa1:   or      bx, bx
        je      .pdone
        dec     bx
        lodsb
        cmp     al, 14h
        je      .pdone
        cmp     al, ' '
        je      .pa1
        cmp     al, 9
        je      .pa1
        dec     ah
        je      .pa3
.pa2:   or      bx, bx
        je      .pdone
        dec     bx
        lodsb
        cmp     al, ' '
        je      .pa1
        cmp     al, 9
        je      .pa1
        cmp     al, 14h
        je      .pdone
        jmp     .pa2
.pa3:   inc     bx
        dec     si
.pa4:   or      bx, bx
        je      .pdone
        dec     bx
        lodsb
        cmp     al, ' '
        je      .pdone
        cmp     al, 9
        je      .pdone
        cmp     al, 14h
        je      .pdone
        stosb
        call    dchar
        loop    .pa4
        jmp     .pfull

.seg:   mov     si, [v_segp]            ; the next part of a ^T line
        mov     bx, [v_len]
.sg1:   or      bx, bx
        je      .sgend
        dec     bx
        lodsb
        cmp     al, 14h
        je      .sgcut
        stosb
        call    dchar
        loop    .sg1
.sgcut: mov     [v_segp], si
        mov     [v_len], bx
        or      bx, bx
        jne     .fin
.sgend: and     byte [v_flags], 0FBh

.fin:   mov     al, 13
        stosb
        mov     cx, di
        mov     di, [v_bufp]
        sub     cx, di
        sub     cx, 3
        mov     [es:di+1], cl
.done:  pop     es
        pop     ds
        pop     bp
        pop     di
        pop     si
        pop     dx
        pop     cx
        pop     bx
        pop     ax
        ret

;------------------------------------------------------------------ macros
; is the word at [v_segp] a macro?  CF=1 if so, and set up to expand it
m_look: mov     si, [v_segp]
        call    wordlen
        jcxz    .no
        mov     si, [v_segp]
        push    cx
        call    m_find
        pop     cx
        jc      .no
        add     di, cx
        inc     di
        add     [v_segp], cx
        sub     [v_len], cx
        mov     [v_macp], di
        or      byte [v_flags], 0Ch
        stc
        ret
.no:    clc
        ret

upcase: cmp     al, 'a'
        jb      .r
        cmp     al, 'z'
        ja      .r
        and     al, 5Fh
.r:     ret

; length of the word at SI, up to CR, blank, '=' or ^T
wordlen:
        xor     cx, cx
.l:     lodsb
        cmp     al, 13
        je      .e
        cmp     al, ' '
        je      .e
        cmp     al, 9
        je      .e
        cmp     al, '='
        je      .e
        cmp     al, 14h
        je      .e
        inc     cx
        jmp     .l
.e:     dec     si
        ret

; find macro DS:SI (CX bytes) in ES's macro area.  CF=0: ES:DI = its name
m_find: lodsb
        call    upcase
        mov     ah, al
        dec     cx
        mov     di, [es:v_mbeg]
.l:     cmp     di, [es:v_mend]
        jae     .no
        push    di
        scasb
        jne     .nx
        jcxz    .end
        push    si
        push    cx
.c:     lodsb
        call    upcase
        scasb
        loope   .c
        pop     cx
        pop     si
        jne     .nx
.end:   cmp     byte [es:di], 0
.nx:    pop     di
        je      .yes
        push    cx
        mov     cx, [es:v_mend]
        sub     cx, di
        xor     al, al
        repne   scasb
        repne   scasb
        pop     cx
        mov     al, ah
        jmp     .l
.no:    stc
        ret
.yes:   add     si, cx
        ret

;----------------------------------------------------------------- history
h_next: mov     si, [v_hcur]
        or      si, si
        je      .r
.l:     cmp     si, [v_hnew]
        je      .st
        call    h_run
        jcxz    .w
        xchg    di, si
        xor     al, al
        repne   scasb
        xchg    di, si
        je      .f
        cmp     si, [v_hnew]
        je      .st
.w:     mov     si, [v_hbeg]
        jmp     .l
.f:     cmp     si, [v_hnew]
        je      .st
        call    h_wrap
.st:    mov     [v_hcur], si
.r:     ret

h_prev: std
        mov     si, [v_hcur]
        or      si, si
        je      .d
        call    h_back
        jb      .s
.l:     call    h_back
        jb      .s
        mov     al, [si]
        or      al, al
        jne     .l
        inc     si
        call    h_wrap
.s:     mov     [v_hcur], si
.d:     cld
        ret

h_back: cmp     si, [v_hold]
        stc
        je      .r
        cmp     si, [v_hbeg]
        jne     .d
        mov     si, [v_bend]
.d:     dec     si
        clc
.r:     ret

; copy the line at v_hcur to ES:DI; CX = its length
h_copy: push    si
        xor     cx, cx
        mov     si, [v_hcur]
        or      si, si
        je      .r
        cmp     si, [v_hnew]
        je      .r
        push    di
        push    bx
        xor     bx, bx
.a:     call    h_run
        jcxz    .w
.b:     lodsb
        or      al, al
        je      .e
        stosb
        inc     bx
        loop    .b
.w:     mov     si, [v_hbeg]
        jmp     .a
.e:     mov     cx, bx
        pop     bx
        pop     di
.r:     pop     si
        ret

; add DS:SI, CX bytes, to the ring
h_add:  push    di
        push    si
        push    cx
        inc     cx
        mov     di, [v_hnew]
        cmp     di, [v_hold]
        sbb     bl, bl
        mov     ax, [v_bend]
        sub     ax, di
        cmp     ax, cx
        rcl     bl, 1
        test    bl, 1
        je      .one
        xchg    cx, ax
        sub     ax, cx
        rep     movsb
        mov     di, [v_hbeg]
        mov     cx, ax
.one:   rep     movsb
        cmp     di, [v_hold]
        cmc
        rcl     bl, 1
        cmp     bl, 3
        je      .fix
        cmp     bl, 0FDh
        jb      .ok
.fix:   push    di                      ; ran over the oldest: drop it
        xor     al, al
        mov     cx, [v_bend]
        sub     cx, di
        repne   scasb
        je      .f2
        mov     di, [v_hbeg]
        mov     cx, [v_bend]
        sub     cx, di
        repne   scasb
.f2:    mov     si, di
        call    h_wrap
        mov     [v_hold], si
        pop     di
.ok:    mov     byte [di-1], 0
        mov     [v_hnew], di
        mov     [v_hcur], di
        pop     cx
        pop     si
        pop     di
        ret

; does the line at v_hcur start with ES:DI, BX bytes (letters any case)?
h_pfx:  mov     si, [v_hcur]
.a:     call    h_run
.l:     or      bx, bx
        je      .r
        jcxz    .w
        lodsb
        dec     bx
        dec     cx
        scasb
        je      .l
        and     al, 5Fh
        cmp     al, 'A'
        jb      .ne
        cmp     al, 'Z'
        ja      .ne
        xor     al, [di-1]
        and     al, 5Fh
        je      .l
.ne:    or      al, 1
.r:     ret
.w:     mov     si, [v_hbeg]
        jmp     .a

; bytes from SI to the ring's end or the newest line, whichever is first
h_run:  mov     cx, [v_hnew]
        sub     cx, si
        jae     .r
        mov     cx, [v_bend]
        sub     cx, si
.r:     ret

h_wrap: cmp     si, [v_bend]
        jne     .r
        mov     si, [v_hbeg]
.r:     ret

;------------------------------------------------------------------ screen
vinit:  mov     ah, 0Fh
        int     10h
        mov     al, ah
        xor     ah, ah
        mov     [v_cols], ax
        mov     [v_page], bh
        mov     ah, 3
        int     10h
        mov     [v_shape], cx
        mov     [v_col], dl
        ret

csave:  mov     ah, 3
        mov     bh, [v_page]
        int     10h
        mov     [v_col], dl
        mov     [v_srow], dh
        mov     [v_scol], dl
        mov     byte [v_wrap], 0
        ret

crest:  cmp     byte [v_wrap], 0
        je      .set
        mov     ah, 3
        mov     bh, [v_page]
        int     10h
        sub     dh, [v_wrap]
        mov     [v_srow], dh
.set:   mov     ah, 2
        mov     bh, [v_page]
        mov     dh, [v_srow]
        mov     dl, [v_scol]
        mov     [v_col], dl
        int     10h
        ret

cshape: mov     ah, 1
        int     10h
        ret

; screen width of character AL -> CX
cwidth: cmp     al, 9
        je      .tab
        mov     cx, 1
        cmp     al, 20h
        jae     .r
        cmp     al, 14h
        je      .r
        cmp     al, 15h
        je      .r
        inc     cl
.r:     ret
.tab:   mov     cx, 0708h
        and     ch, [v_col]
        sub     cl, ch
        xor     ch, ch
        ret

; move the cursor back CX columns
cback:  push    cx
        call    csave
        pop     cx
        mov     al, [v_scol]
        xor     ah, ah
        sub     ax, cx
        jae     .s
.l:     dec     byte [v_srow]
        add     ax, [v_cols]
        jae     .l
.s:     mov     [v_scol], al
        call    crest
        ret

; show character AL; AX = its width
dchar:  push    si
        push    cx
        call    cwidth
        push    cx
        cmp     al, 9
        je      .tab
        cmp     al, 20h
        jae     .raw
        cmp     al, 13
        je      .raw
        cmp     al, 10
        je      .raw
        cmp     al, 14h
        je      .raw
        cmp     al, 15h
        je      .raw
        mov     cl, al
        mov     al, '^'
        call    ochar
        mov     al, cl
        add     al, 40h
.raw:   call    ochar
.r:     pop     ax
        pop     cx
        pop     si
        ret
.tab:   mov     al, ' '
.t:     call    ochar
        loop    .t
        jmp     .r

beep:   mov     ax, 0E07h
        int     10h
        ret

; list the history.  AL=0: plain (DOSKEY /H); AL=1: numbered, paged (F7)
hlist:  mov     bx, 8000h
        mov     si, [v_hold]
        cmp     si, [v_hnew]
        jbe     .two
        mov     cx, [v_bend]
        sub     cx, si
        call    .run
        mov     si, [v_hbeg]
.two:   mov     cx, [v_hnew]
        sub     cx, si
.run:   jcxz    .ret
.l:     push    ax
        test    bh, 80h
        jz      .ch
        and     bh, 7Fh
        or      al, al
        jz      .pl
        or      bx, bx
        jz      .num
        mov     ax, bx
        xor     dx, dx
        div     word [v_rows]
        or      dx, dx
        jne     .num
        push    cx
        push    si
        mov     si, s_more
        call    pstr
        pop     si
        call    getkey
        pop     cx
.num:   inc     bx
        call    crlf
        mov     ax, bx
        call    pnum
        mov     al, ':'
        call    dchar
        mov     al, ' '
        cmp     si, [v_hcur]
        jne     .p
        mov     al, '>'
.p:     call    dchar
        jmp     .ch
.pl:    or      bx, bx
        jz      .i
        call    crlf
.i:     inc     bx
.ch:    lodsb
        or      al, al
        jne     .d
        or      bh, 80h
        jmp     .n
.d:     call    dchar
.n:     pop     ax
        loop    .l
.ret:   ret

crlf:   mov     al, 13
        call    dchar
        mov     al, 10
        jmp     dchar

pnum:   xor     dx, dx
        div     word [cs:ten]
        or      ax, ax
        push    dx
        je      .p
        call    pnum
.p:     pop     ax
        add     al, '0'
        jmp     dchar

pstr1:  call    dchar
pstr:   lodsb
        or      al, al
        jne     pstr1
        ret

; one character to the console through DOS, keeping track of the column
ochar:  mov     ah, 2
        mov     dl, al
        int     21h
        xor     ah, ah
        cmp     al, 13
        je      .set
        mov     ah, [v_col]
        inc     ah
        cmp     ah, [v_cols]
        jb      .set
        push    bx
        push    cx
        mov     ah, 3
        mov     bh, [v_page]
        int     10h
        pop     cx
        pop     bx
        inc     dl
        cmp     dl, [v_cols]
        jne     .w
        mov     dl, 13                  ; a console that does not wrap
        mov     ah, 2
        int     21h
        mov     dl, 10
        mov     ah, 2
        int     21h
.w:     xor     ah, ah
        inc     byte [v_wrap]
.set:   mov     [v_col], ah
        ret

;------------------------------------------------------------ the line editor
edit:   call    ldtmpl
        mov     word [v_len], 0
        mov     word [v_cur], 0
        and     byte [v_flags], 0FCh
        mov     byte [tc_on], 0
        push    ds
        xor     ax, ax
        mov     ds, ax
        and     byte [417h], 7Fh
        pop     ds
        call    vinit
        cmp     byte [v_insd], 0
        je      .l
        call    k_ins
.l:     call    getkey
        call    dispat
        jmp     .l

; the template: whatever COMMAND.COM left in its buffer
ldtmpl: lds     si, [v_bufp]
        mov     di, v_line
        inc     si
        lodsb
        mov     cl, al
        xor     ch, ch
        cmp     cx, 7Fh
        jbe     .n
        mov     cx, 7Fh
.n:     mov     [es:v_tlen], cx
        jcxz    .d
.l:     lodsb
        cmp     al, 13
        je      .e
        stosb
        loop    .l
.e:     sub     [es:v_tlen], cx
.d:     push    cs
        pop     ds
        ret

; AL/AH = key (AH=FFh a character, 0 an extended key)
dispat: cmp     ah, 0
        jne     .chr
        cmp     al, 0Fh                 ; SHIFT+TAB
        jne     .x0
        test    byte [v_opts], 1
        jz      .x0
        mov     byte [tc_back], 1
        jmp     k_tab
.x0:    mov     byte [tc_on], 0
        mov     di, t_ext
        mov     cx, T_EXTN
        mov     bx, j_ext
        jmp     .go
.chr:   cmp     al, 9
        jne     .c0
        test    byte [v_opts], 1
        jz      .c0
        mov     byte [tc_back], 0
        jmp     k_tab
.c0:    mov     byte [tc_on], 0
        mov     di, t_chr
        mov     cx, T_CHRN
        mov     bx, j_chr
.go:    repne   scasb
        shl     cx, 1
        add     bx, cx
        jmp     [bx]

; searched first to last; the handler is found counting from the END of
; the jump table, and entry 0 is for a key not in the list
t_chr   db      13, 10, 1Bh, 8, 6
T_CHRN  equ     $ - t_chr + 1
        db      6
j_chr   dw      k_char, k_none, k_bs, k_esc, k_none, k_cr
t_ext   db      71h, 6Eh, 43h, 42h, 41h, 74h, 73h, 77h, 75h, 40h, 3Fh, 3Eh, 3Dh
        db      3Ch, 3Bh, 53h, 52h, 4Fh, 47h, 50h, 48h, 4Bh, 4Dh, 49h, 51h
T_EXTN  equ     $ - t_ext + 1
        db      51h
j_ext   dw      k_none, k_page, k_page, k_f1, k_left, k_up, k_down, k_home
        dw      k_end, k_ins, k_del, k_f1, k_f2, k_f3, k_f4, k_f5, k_f6
        dw      k_cend, k_chome, k_cleft, k_cright, k_f7, k_f8, k_f9
        dw      k_af7, k_af10

; Enter
k_cr:   push    ax
        call    k_end
        pop     ax
        call    dchar
crfin:  mov     cx, [v_shape]
        call    cshape
        pop     ax                      ; out of edit, back to readline
k_none: ret

; PgUp / PgDn: the oldest / newest line
k_page: cmp     word [v_hcur], 0
        je      k_none
        push    ax
        call    k_esc
        mov     ax, [v_hold]
        mov     [v_hcur], ax
        pop     ax
        cmp     al, 49h
        je      .l
        mov     ax, [v_hnew]
        mov     [v_hcur], ax
        call    h_prev
.l:     jmp     ldline

k_left: cmp     word [v_cur], 0
        je      .r
        dec     word [v_cur]
        mov     si, [v_cur]
        mov     cl, [si+v_wid]
        xor     ch, ch
        call    cback
        or      al, 1
.r:     ret

; Right / F1: one character, from the template past the end of the line
k_f1:   mov     si, [v_cur]
        cmp     si, [v_len]
        jb      .show
        cmp     si, [v_tlen]
        je      .r
        inc     word [v_len]
.show:  mov     al, [si+v_line]
        call    dchar
        mov     [si+v_wid], al
        inc     word [v_cur]
.r:     ret

k_home: call    k_left
        jne     k_home
        ret

k_end:  mov     si, [v_cur]
        cmp     si, [v_len]
        je      .r
        call    k_f1
        jmp     k_end
.r:     ret

k_f3:   call    k_f1
        jne     k_f3
        ret

k_del:  mov     cx, 1
; delete CX characters at the cursor, from the line and the template
deln:   push    cx
        or      byte [v_flags], 2
        call    wsum
        pop     bx
        mov     di, [v_cur]
        sub     [v_len], bx
        jb      .fix
        cmp     di, [v_len]
        jbe     .ok
.fix:   mov     [v_len], di
.ok:    lea     si, [bx+di]
.mv:    cmp     si, [v_tlen]
        jae     .mvd
        mov     al, [si+v_line]
        mov     [di+v_line], al
        inc     si
        inc     di
        jmp     .mv
.mvd:   mov     [v_tlen], di
        push    cx
        call    csave
        call    redisp
        call    wsum
        pop     ax
        sub     ax, cx
        mov     cx, ax
        jmp     erase0

k_bs:   cmp     word [v_cur], 0
        je      .r
        call    k_left
        mov     si, [v_len]
        dec     si
        cmp     si, [v_cur]
        jne     k_del
        mov     [v_len], si
        mov     cl, [si+v_wid]
        jmp     erase
.r:     ret

k_chome:
        push    word [v_cur]
        call    k_home
        pop     cx
        jmp     deln

k_cend: call    wsum
        mov     si, [v_cur]
        mov     [v_tlen], si
        mov     [v_len], si
        jmp     erase

k_cleft:
        call    k_left
        mov     si, [v_cur]
        or      si, si
        je      .r
        mov     al, [si+v_line]
        call    blank
        je      k_cleft
.b:     mov     si, [v_cur]
        or      si, si
        je      .r
        dec     si
        mov     al, [si+v_line]
        call    blank
        je      .r
        call    k_left
        jmp     .b
.r:     ret

k_cright:
        mov     si, [v_cur]
        cmp     si, [v_tlen]
        je      .r
        mov     al, [si+v_line]
        call    blank
        je      .sp
        call    k_f1
        jmp     k_cright
.sp:    call    k_f1
        je      .r
        mov     si, [v_cur]
        mov     al, [si+v_line]
        call    blank
        je      .sp
.r:     ret

; F2 c: copy the template up to c
k_f2:   call    getkey
        cmp     ah, 0
        je      .r
        mov     si, [v_cur]
        cmp     si, [v_tlen]
        je      .r
.s:     inc     si
        cmp     si, [v_tlen]
        je      .r
        cmp     [si+v_line], al
        jne     .s
.c:     push    si
        call    k_f1
        pop     si
        cmp     si, [v_cur]
        ja      .c
.r:     ret

; F4 c: delete from the template up to c
k_f4:   call    getkey
        cmp     ah, 0
        je      k_f2.r
        mov     si, [v_cur]
        cmp     si, [v_tlen]
        je      k_f2.r
.s:     inc     si
        cmp     si, [v_tlen]
        je      k_f2.r
        cmp     [si+v_line], al
        jne     .s
        sub     si, [v_cur]
        mov     cx, si
        jmp     deln

k_f6:   mov     al, 1Ah
        jmp     k_char

k_af7:  mov     ax, [v_hbeg]
        mov     [v_hold], ax
        mov     [v_hnew], ax
        mov     word [v_hcur], 0
        ret

; F7: the history, numbered, a screen at a time; then a fresh prompt
k_f7:   mov     ax, 440Ch
        mov     bx, 2
        mov     cx, 037Fh
        mov     dx, v_ioctl
        int     21h
        jb      .bios
        cmp     byte [v_vmode], 1
        je      .have
.bios:  push    ds
        mov     ax, 40h
        mov     ds, ax
        mov     al, [84h]
        pop     ds
        or      al, al
        jne     .n
        mov     al, 24
.n:     xor     ah, ah
        mov     [v_rows], ax
.have:  dec     word [v_rows]
        call    k_esc
        mov     al, 1
        call    hlist
        jmp     crfin

; F8: the next older line starting with what is before the cursor
k_f8:   mov     si, [v_hcur]
.l:     push    si
        mov     si, [v_hcur]
        cmp     si, [v_hold]
        jne     .p
        mov     si, [v_hnew]
        mov     [v_hcur], si
        pop     si
        cmp     si, [v_hcur]
        je      .t
        push    si
.p:     call    h_prev
        mov     di, v_line
        mov     bx, [v_cur]
        call    h_pfx
        je      .f
        pop     si
.t:     cmp     si, [v_hcur]
        jne     .l
        ret
.f:     pop     si
        push    word [v_cur]
        call    k_esc
        call    ldline
        pop     ax
        mov     cx, [v_cur]
        sub     cx, ax
        jcxz    .r
.b:     push    cx
        call    k_left
        pop     cx
        loop    .b
.r:     ret

; F9: a line by its number
k_f9:   cmp     word [v_hcur], 0
        jne     .go
        ret
.bs:    cmp     si, v_dig
        jbe     .k
        dec     si
        mov     cl, [v_srow]
        mov     ch, [v_scol]
        push    cx
        mov     cx, 1
        call    cback
        mov     al, ' '
        call    dchar
        mov     cx, 1
        call    cback
        pop     cx
        mov     [v_srow], cl
        mov     [v_scol], ch
        jmp     .k
.go:    call    k_esc
        call    csave
        mov     si, s_linen
        call    pstr
        mov     si, v_dig
.k:     call    getkey
        sub     ah, 0FFh
        jne     .k
        cmp     al, 1Bh
        je      .done
        cmp     al, 13
        je      .ent
        cmp     al, 8
        je      .bs
        cmp     al, '0'
        jb      .k
        cmp     al, '9'
        ja      .k
        cmp     si, v_dig+5
        jae     .k
        mov     [si], al
        inc     si
        call    dchar
        jmp     .k
.ent:   mov     cx, si
        mov     si, v_dig
        sub     cx, si
        xor     ax, ax
        jcxz    .done
.d:     mul     word [ten]
        mov     bx, ax
        lodsb
        sub     al, '0'
        xor     ah, ah
        add     ax, bx
        loop    .d
        mov     bx, ax
        mov     ax, [v_hold]
        mov     [v_hcur], ax
        mov     cx, bx
        sub     cx, 1
        jbe     .z
.n:     push    cx
        call    h_next
        pop     cx
        mov     ax, [v_hcur]
        cmp     ax, [v_hnew]
        je      .last
        loop    .n
        jmp     .z
.last:  call    h_prev
.z:     xor     al, al
.done:  push    ax
        push    word [v_col]
        call    crest
        pop     ax
        sub     al, [v_col]
        xor     ah, ah
        mov     cx, ax
        call    erase0
        pop     ax
        cmp     al, 1Bh
        jne     ldline
        ret

k_af10: mov     ax, [v_mbeg]
        mov     [v_mend], ax
        ret

k_esc:  call    k_home
        call    k_cend
        and     byte [v_flags], 0FDh
        jmp     ldtmpl

k_f5:   push    word [v_tlen]
        call    k_home
        call    k_cend
        pop     word [v_tlen]
        and     byte [v_flags], 0FDh
        ret

; show the history line at v_hcur as the line
ldline: mov     di, v_line
        call    h_copy
        mov     [v_len], cx
        mov     [v_tlen], cx
        mov     word [v_cur], 0
        push    cx
        call    redisp
        pop     word [v_cur]
        ret

k_up:   call    h_prev
        call    k_esc
        jmp     ldline

k_down: cmp     word [v_len], 0
        je      .l
        call    k_esc
        call    h_next
.l:     jmp     ldline

k_ins:  xor     byte [v_flags], 1
        mov     al, [v_insd]
        xor     al, [v_flags]
        test    al, 1
        push    cx
        mov     cx, [v_shape]
        je      .s
        sub     ch, 2
        ja      .s
        xor     ch, ch
.s:     call    cshape
        pop     cx
        push    ds
        xor     ax, ax
        mov     ds, ax
        and     byte [417h], 7Fh
        test    byte [cs:v_flags], 1
        je      .x
        or      byte [417h], 80h
.x:     pop     ds
        ret

; a character typed
k_char: or      byte [v_flags], 2
        test    byte [v_flags], 1
        jnz     .ins
        mov     si, [v_cur]
        cmp     si, 7Fh
        jae     .beep
        mov     si, [v_cur]
        mov     [si+v_line], al
        call    dchar
        mov     si, [v_cur]
        xchg    [si+v_wid], al
        sub     al, [si+v_wid]
        inc     si
        mov     [v_cur], si
        cmp     si, [v_len]
        jbe     .x
        inc     word [v_len]
        cmp     si, [v_tlen]
        jbe     .x
        inc     word [v_tlen]
.x:     or      al, al
        je      .r
        push    ax
        call    csave
        pop     ax
        mov     si, [v_cur]
.rd:    cmp     si, [v_len]
        je      .e
        push    ax
        mov     al, [si+v_line]
        call    dchar
        mov     cl, al
        pop     ax
        add     al, [si+v_wid]
        mov     [si+v_wid], cl
        inc     si
        sub     al, cl
        jne     .rd
.e:     cbw
        mov     cx, ax
        jmp     erase0
.r:     ret
.ins:   mov     si, [v_len]
        cmp     si, 7Fh
        jb      .i1
.beep:  jmp     beep
.i1:    mov     si, [v_tlen]
        cmp     si, 7Fh
        je      .i2
        inc     si
        mov     [v_tlen], si
.i2:    cmp     si, [v_cur]
        je      .i3
        dec     si
        mov     cl, [si+v_line]
        mov     [si+v_line+1], cl
        jmp     .i2
.i3:    mov     [si+v_line], al
        inc     word [v_len]
        call    dchar
        mov     [si+v_wid], al
        inc     word [v_cur]
        call    csave
        call    redisp
        jmp     crest

; total width of the line from the cursor on -> CX
wsum:   mov     cx, 0
        mov     si, [v_cur]
.l:     cmp     si, [v_len]
        jae     blank.r
        mov     al, [si+v_wid]
        inc     si
        cbw
        add     cx, ax
        jmp     .l

; show the line from the cursor on
redisp: mov     si, [v_cur]
.l:     cmp     si, [v_len]
        jae     blank.r
        mov     al, [si+v_line]
        call    dchar
        mov     [si+v_wid], al
        inc     si
        jmp     .l

blank:  cmp     al, ' '
        je      .r
        cmp     al, 9
.r:     ret

; a key, through DOS, idling while there is none: AH=FFh char, 0 extended
getkey0:
        int     28h
        mov     ax, 1680h
        int     2Fh
getkey: mov     ah, 0Bh
        int     21h
        or      al, al
        je      getkey0
        mov     ah, 8
        int     21h
        mov     ah, 0FFh
        or      al, al
        jne     .r
        mov     ah, 8
        int     21h
        mov     ah, 0
.r:     ret

; blank CX columns and put the cursor back
erase:  push    cx
        call    csave
        pop     cx
erase0: cmp     cx, 0
        jle     .r
.l:     mov     al, ' '
        call    dchar
        loop    .l
.r:     jmp     crest

;---------------------------------------------------------- TAB completion
; TAB puts the first name (in order) matching the word before the cursor in
; place of it -- the whole word, though only what is before the cursor is
; matched; TAB again the next, SHIFT+TAB the one before.  Any other key
; ends the cycle, so the next TAB starts from what is then on the line.
k_tab:  cmp     byte [tc_on], 0
        jne     .search
        ; a new cycle: find the word, make the pattern
        mov     si, [v_cur]
.ws:    or      si, si
        je      .wsd
        mov     al, [si+v_line-1]
        call    tdelim
        je      .wsd
        dec     si
        jmp     .ws
.wsd:   mov     [tc_ws], si
        mov     cx, [v_cur]
        sub     cx, si
        cmp     cx, 76
        ja      .nope
        add     si, v_line
        mov     di, TC_PAT
        xor     dx, dx                  ; DX = where the name part starts
        xor     bx, bx                  ; BL = 1 if the name part has a '.'
        jcxz    .pd
.pc:    lodsb
        stosb
        cmp     al, '.'
        jne     .pc1
        mov     bl, 1
.pc1:   cmp     al, '\'
        je      .pc2
        cmp     al, ':'
        jne     .pc3
.pc2:   mov     dx, di
        sub     dx, TC_PAT
        xor     bl, bl
.pc3:   loop    .pc
.pd:    mov     [tc_dir], dl
        mov     al, '*'
        stosb
        or      bl, bl
        jnz     .pz
        mov     ax, '.*'
        stosw
.pz:    mov     byte [di], 0
        mov     byte [tc_last], 0
        mov     byte [tc_on], 1
.search:
        call    tfind
        jc      .nope
        mov     si, tc_best
        mov     di, tc_last
        mov     cx, 13
        rep     movsb
        ; what goes in: the name, in the case being typed.  A directory
        ; gets no '\' after it: CD will not take one.  The directory part
        ; before the name stays as it was typed
        call    tcase                   ; AL = 20h to make it lower case
        mov     ah, al
        mov     si, tc_best
        mov     di, tc_wrap
.nm:    lodsb
        or      al, al
        je      .nmd
        cmp     al, 'A'
        jb      .nm1
        cmp     al, 'Z'
        ja      .nm1
        or      al, ah
.nm1:   stosb
        jmp     .nm
.nmd:   sub     di, tc_wrap
        mov     [tc_nl], di
        mov     al, [tc_dir]
        xor     ah, ah
        add     ax, [tc_ws]
        mov     [tc_pos], ax            ; where it goes
        mov     si, [v_cur]             ; the rest of the word goes too --
        cmp     byte [tc_on], 2         ; but only the first time: after
        je      .wed                    ; that, just the name we put in
.we:    cmp     si, [v_len]
        jae     .wed
        mov     al, [si+v_line]
        call    tdelim
        je      .wed
        inc     si
        jmp     .we
.wed:   mov     dx, [v_len]
        sub     dx, si
        mov     [tc_tail], dx           ; what follows the word
        mov     ax, [tc_pos]
        add     dx, ax
        add     dx, di
        cmp     dx, 7Fh
        jbe     .fits
.nope:  ret
.fits:  mov     byte [tc_on], 2
        mov     si, [v_cur]             ; cursor back to where it goes
        mov     ax, [tc_pos]
        call    wback
        call    cback
        mov     ax, [tc_pos]
        mov     [v_cur], ax
        call    wsum
        mov     bp, cx                  ; width of what is being replaced
        mov     si, [v_len]             ; move the tail
        sub     si, [tc_tail]
        add     si, v_line
        mov     di, [tc_pos]
        add     di, [tc_nl]
        add     di, v_line
        mov     cx, [tc_tail]
        cmp     di, si
        jbe     .fwd
        add     si, cx
        add     di, cx
        dec     si
        dec     di
        std
.fwd:   rep     movsb
        cld
        mov     si, tc_wrap             ; put the name in
        mov     di, [tc_pos]
        add     di, v_line
        mov     cx, [tc_nl]
        rep     movsb
        mov     ax, [tc_pos]
        add     ax, [tc_nl]
        push    ax
        add     ax, [tc_tail]
        mov     [v_len], ax
        mov     [v_tlen], ax
        call    redisp                  ; draw it
        call    wsum
        sub     bp, cx                  ; and blank what is left of the old
        jbe     .nb
        mov     cx, bp
.bl:    mov     al, ' '
        call    dchar
        loop    .bl
        mov     cx, bp
        call    cback
.nb:    pop     ax                      ; cursor to the end of the name
        push    ax
        mov     si, [v_len]
        call    wback
        call    cback
        pop     word [v_cur]
        or      byte [v_flags], 2
        ret

; CX = width of the characters from AX up to SI
wback:  xor     cx, cx
.l:     cmp     si, ax
        jbe     .r
        dec     si
        mov     dl, [si+v_wid]
        xor     dh, dh
        add     cx, dx
        jmp     .l
.r:     ret

; is AL a character that ends a word?
tdelim: cmp     al, ' '
        je      .r
        cmp     al, 9
        je      .r
        cmp     al, 14h
        je      .r
        push    di
        push    cx
        mov     di, t_delim
        mov     cx, T_DELN
        push    es
        push    cs
        pop     es
        repne   scasb
        pop     es
        pop     cx
        pop     di
.r:     ret
t_delim db      ';,=+<>|"/'
T_DELN  equ     $ - t_delim

; lower case if the nearest letter before the cursor is: AL = 20h, else 0
tcase:  mov     si, [v_cur]
.l:     xor     al, al
        or      si, si
        je      .r
        dec     si
        mov     al, [si+v_line]
        or      al, 20h
        cmp     al, 'a'
        jb      .l
        cmp     al, 'z'
        ja      .l
        mov     al, [si+v_line]
        and     al, 20h
.r:     ret

; search the directory: tc_best = the next name after tc_last (the one
; before, for SHIFT+TAB), wrapping round.  CF=1 if nothing matches.
tfind:  push    es
        mov     ah, 2Fh                 ; our own DTA...
        int     21h
        mov     [tc_odta], bx
        mov     [tc_odta+2], es
        pop     es
        mov     dx, TC_DTA
        mov     ah, 1Ah
        int     21h
        call    tswap                   ; ...and no ^C or critical error prompt
        xor     ax, ax
        mov     [tc_best], al
        mov     [tc_wrap], al
        mov     dx, TC_PAT
        mov     cx, 10h
        mov     ah, 4Eh
.f:     int     21h
        jc      .end
        mov     si, TC_DTA+1Eh
        cmp     byte [si], '.'
        je      .nx
        ; after tc_last (in the direction of travel): a candidate for the
        ; next; otherwise for the wrap round.  Either way the first in order.
        mov     di, tc_last
        call    tcmp
        mov     di, tc_best
        ja      .cand
        mov     di, tc_wrap
.cand:  cmp     byte [di], 0
        je      .take
        call    tcmp
        jae     .nx
.take:  mov     cx, 13
        rep     movsb
        mov     al, [TC_DTA+15h]
        mov     [di], al
.nx:    mov     ah, 4Fh
        jmp     .f
.end:   cmp     byte [tc_best], 0
        jne     .got
        mov     si, tc_wrap
        mov     di, tc_best
        mov     cx, 14
        rep     movsb
.got:   call    tswap
        push    ds
        lds     dx, [tc_odta]
        mov     ah, 1Ah
        int     21h
        pop     ds
        cmp     byte [tc_best], 1       ; CF=1 if empty
        ret

; our INT 23h and 24h in, or the ones that were there back: they trade
; places with tc_vec
tswap:  push    es
        xor     ax, ax
        mov     es, ax
        mov     si, tc_vec
        mov     di, 23h*4
        mov     cx, 4
.l:     mov     ax, [si]
        xchg    ax, [es:di]
        mov     [si], ax
        inc     si
        inc     si
        inc     di
        inc     di
        loop    .l
        pop     es
        ret

; compare the names at SI and DI in the direction of travel: flags as for
; SI - DI going forward, DI - SI for SHIFT+TAB.  Empty is least.
tcmp:   push    si
        push    di
        cmp     byte [tc_back], 0
        je      .l
        xchg    si, di
.l:     mov     al, [si]
        cmp     al, [di]
        jne     .r
        or      al, al
        je      .r
        inc     si
        inc     di
        jmp     .l
.r:     pop     di
        pop     si
        ret

t_i24:  mov     al, 3                   ; critical error: fail the call
t_i23:  iret                            ; ^C: carry on

;============================================================ end of resident
res_end:

;---------------------------------------------------------------------- init
init:   push    cs
        pop     ds
        push    cs
        pop     es
        mov     ah, 30h
        int     21h
        cmp     al, 5
        jae     .dosok
        mov     dx, m_dosv
        jmp     fail
.dosok: mov     si, 81h
.opt:   call    skipws
        mov     di, o_help
        call    match
        je      help
        mov     di, o_ins
        call    match
        je      .ins
        mov     di, o_ovr
        call    match
        je      .ovr
        mov     di, o_reins
        call    match
        je      .reins
        mov     di, o_hist
        call    match
        je      .hist
        mov     di, o_h
        call    match
        je      .hist
        mov     di, o_mac
        call    match
        je      .mac
        mov     di, o_m
        call    match
        je      .mac
        mov     di, o_notab
        call    match
        je      .notab
        mov     di, o_tab
        call    match
        je      .tab
        mov     di, o_buf
        call    match
        jne     .parsed
        call    skipws
        cmp     al, '='
        je      .bufn
        jmp     invalid
.bufn:  call    skipws1
        call    number
        mov     [bufsize], bx
        or      byte [cs:opts], 2
        jmp     .opt
.reins: or      byte [cs:opts], 1
        jmp     .opt
.ins:   or      byte [cs:opts], 20h
        jmp     .opt
.ovr:   or      byte [cs:opts], 40h
        jmp     .opt
.hist:  or      byte [cs:opts], 8
        jmp     .opt
.mac:   or      byte [cs:opts], 10h
        jmp     .opt
.notab: mov     byte [cs:tabset], 0
        jmp     .opt
.tab:   mov     byte [cs:tabset], 1
        jmp     .opt

.parsed:
        test    byte [cs:opts], 1
        jne     install
        mov     ax, 4800h
        int     2Fh
        cmp     ax, 4800h
        je      install
        cmp     ax, 0AA02h
        mov     dx, m_incomp
        jne     .f
        test    byte [opts], 2
        je      cont
        mov     dx, m_nobuf
.f:     jmp     fail

install:
        push    si
        mov     ax, [bufsize]
        cmp     ax, 101h
        jae     .b1
        mov     ax, 101h
.b1:    mov     cx, 0FFFFh
        sub     cx, res_end
        cmp     ax, cx
        jbe     .b2
        mov     ax, cx
.b2:    push    ax
        mov     es, [2Ch]
        mov     ah, 49h
        int     21h
        mov     ax, res_end
        mov     [v_mbeg], ax
        mov     [v_mend], ax
        mov     [v_mlim], ax
        mov     [v_hbeg], ax
        mov     [v_hold], ax
        mov     [v_hnew], ax
        pop     bx
        add     ax, bx
        mov     [v_bend], ax
        mov     ax, cs
        mov     [tc_vec+2], ax
        mov     [tc_vec+6], ax
        mov     [win_seg], ax
        mov     [win_s1], ax
        mov     [win_s2], ax
        mov     [win_s3], ax
        mov     ax, [v_mbeg]
        mov     [win_b], ax
        mov     ax, [v_bend]
        sub     ax, [v_mbeg]
        mov     [win_bl], ax
        mov     ax, int2f
        mov     bx, cs
        xor     cx, cx
        mov     es, cx
        cli
        xchg    ax, [es:2Fh*4]
        xchg    bx, [es:2Fh*4+2]
        mov     [old2f], ax
        mov     [old2f+2], bx
        sti
        or      byte [cs:opts], 4
        pop     si
        push    cs
        pop     es

; ES = the resident copy, ours or 6.22's
cont:   test    byte [cs:opts], 20h
        je      .c1
        mov     byte [es:v_insd], 0FFh
.c1:    test    byte [cs:opts], 40h
        je      .c2
        mov     byte [es:v_insd], 0
.c2:    mov     al, [cs:tabset]
        cmp     al, 0FFh
        je      .c3
        cmp     word [es:sig], 'DK'     ; only ours has the option
        jne     .c3
        cmp     word [es:sig+2], 'SC'
        jne     .c3
        mov     [es:v_opts], al
.c3:    call    skipws
        mov     di, si
        call    wordlen
        jcxz    .show
        call    skipws
        cmp     al, '='
        jne     invalid
        call    skipws1
        mov     bx, cx
        mov     byte [defd], 1
        call    mconv
        call    mdef
        mov     dx, m_nomem
        jb      fail
.show:  test    byte [cs:opts], 8
        push    ds
        push    es
        pop     ds
        je      .s1
        xor     al, al
        call    hlist
        call    crlf
.s1:    test    byte [cs:opts], 10h
        je      .s2
        xor     al, al
        call    mlist
        call    crlf
.s2:    pop     ds
        ; plain DOSKEYSC with 6.22's DOSKEY loaded would otherwise do
        ; nothing at all, and leave TAB not working with no word said
        test    byte [opts], 7Ch        ; installed now, or any switch?
        jne     .s3
        cmp     byte [tabset], 0FFh
        jne     .s3
        cmp     byte [defd], 0
        jne     .s3
        cmp     word [es:sig], 'DK'
        jne     .note
        cmp     word [es:sig+2], 'SC'
        je      .s3
.note:  mov     dx, m_other
        call    msg
.s3:    mov     al, 0
        jmp     exit

invalid:
        mov     dx, m_inval
fail:   call    msg
        mov     al, 1
exit:   test    byte [opts], 4
        jne     .tsr
        mov     ah, 4Ch
        int     21h
.tsr:   mov     dx, [v_bend]
        int     27h

help:   mov     bx, m_help
.l:     mov     al, [bx]
        inc     bx
        or      al, al
        je      .d
        push    bx
        mov     dl, al
        mov     ah, 2
        int     21h
        pop     bx
        jmp     .l
.d:     mov     al, 0
        jmp     exit

; DI = name (upper-cased in place, BX bytes), SI = text (CX bytes):
; define it in ES's macro area.  CF=1 if there is no room.
mdef:   push    di
        push    bx
.u:     mov     al, [di]
        call    upcase
        mov     [di], al
        inc     di
        dec     bx
        jne     .u
        pop     bx
        pop     di
        push    si
        push    cx
        push    di
        push    bx
        call    mdel
        pop     bx
        pop     di
        pop     cx
        pop     si
        jcxz    .ok
        mov     ax, bx
        add     ax, cx
        add     ax, 2
        mov     dx, [es:v_mlim]
        sub     dx, [es:v_mend]
        sub     ax, dx
        jbe     .fits
        push    ax
        call    grow
        pop     ax
        jb      .r
        add     [es:v_mlim], ax
.fits:  push    si
        push    cx
        mov     si, di
        mov     cx, bx
        mov     di, [es:v_mend]
        rep     movsb
        xor     al, al
        stosb
        pop     cx
        pop     si
        rep     movsb
        xor     al, al
        stosb
        mov     [es:v_mend], di
.ok:    clc
.r:     ret

; the $ codes of a macro's text, converted in place; CX = its new length
mconv:  push    es
        push    di
        push    si
        push    ds
        pop     es
        mov     di, si
.l:     lodsb
        cmp     al, 13
        je      .e
        cmp     al, '$'
        jne     .s
        lodsb
        cmp     al, 13
        je      .e
        cmp     al, '$'
        je      .k
        cmp     al, '*'
        je      .k
        cmp     al, '1'
        jb      .c
        cmp     al, '9'
        ja      .c
.k:     mov     byte [es:di], '$'
        inc     di
        jmp     .s
.c:     call    upcase
        mov     ah, '|'
        cmp     al, 'B'
        je      .x
        mov     ah, '<'
        cmp     al, 'L'
        je      .x
        mov     ah, '>'
        cmp     al, 'G'
        je      .x
        mov     ah, 14h
        cmp     al, 'T'
        jne     .l                      ; any other $x is dropped
.x:     mov     al, ah
.s:     stosb
        jmp     .l
.e:     mov     cx, di
        pop     si
        pop     di
        pop     es
        sub     cx, si
        ret

; delete macro DI (BX bytes) if it exists
mdel:   mov     si, di
        mov     cx, bx
        call    m_find
        jb      .r
        push    di
        mov     cx, [es:v_mend]
        sub     cx, di
        xor     al, al
        repne   scasb
        repne   scasb
        mov     si, di
        pop     di
        push    ds                      ; (not an ES: override: the 8086
        push    es                      ; drops it if an interrupt lands)
        pop     ds
        rep     movsb
        pop     ds
        mov     [es:v_mend], di
.r:     ret

; take AX bytes from the history for the macros.  CF=1 if it would leave
; the history less than 258 bytes.
grow:   push    cx
        push    si
        push    di
        push    ds
        push    es
        pop     ds
        mov     di, [v_bend]
        sub     di, [v_hbeg]
        sub     di, ax
        jb      .ret
        cmp     di, 102h
        jb      .ret
        mov     cx, [v_hnew]
        cmp     cx, [v_hold]
        jae     .flat
        sub     cx, [v_hbeg]
        sub     di, cx
        jbe     .all
        mov     si, [v_bend]
        sub     si, di
        cmp     si, [v_hold]
        jbe     .keep
        mov     cx, di
        mov     di, si
        dec     di
        inc     cx
        push    ax
        xor     al, al
        repne   scasb
        pop     ax
        jne     .all
        mov     [v_hold], di
.keep:  mov     si, [v_hnew]
        add     [v_hnew], ax
        mov     di, [v_hnew]
        mov     cx, si
        sub     cx, [v_hbeg]
        add     [v_hbeg], ax
        dec     si
        dec     di
        std
        rep     movsb
        cld
.fix:   mov     ax, [v_bend]
        cmp     ax, [v_hold]
        jne     .f2
        mov     si, [v_hbeg]
        mov     [v_hold], si
        cmp     ax, [v_hnew]
        jne     .f2
        mov     [v_hnew], si
.f2:    mov     ax, [v_hnew]
        cmp     ax, [v_hold]
        jne     .f3
        xor     ax, ax
.f3:    mov     [v_hcur], ax
        clc
.ret:   pop     ds
        pop     di
        pop     si
        pop     cx
        ret
.all:   mov     si, [v_hbeg]
        mov     [v_hold], si
.flat:  add     [v_hbeg], ax
        mov     ax, [v_hbeg]
        cmp     ax, [v_hold]
        jbe     .fix
        mov     di, [v_bend]
        mov     si, di
        xchg    [v_hnew], si
        mov     cx, [v_hold]
        sub     cx, si
        neg     cx
        dec     di
        dec     si
        std
        rep     movsb
        inc     di
        inc     si
        cld
        mov     [v_hold], di
        mov     si, [v_hbeg]
        cmp     si, [v_hold]
        jbe     .fix
        mov     di, si
        dec     di
        mov     cx, [v_hnew]
        sub     cx, di
        xor     al, al
        repne   scasb
        mov     [v_hold], di
        jmp     .fix

; list the macros, the way they were typed
mlist:  xor     al, al
        mov     si, [v_mbeg]
        cmp     si, [v_mend]
        je      .r
.l:     call    pstr
        mov     al, '='
        call    dchar
        call    .text
        cmp     si, [v_mend]
        je      .r
        call    crlf
        jmp     .l
.r:     ret
.text:  lodsb
        or      al, al
        je      .r
        mov     ah, 'b'
        cmp     al, '|'
        je      .d
        mov     ah, 'g'
        cmp     al, '>'
        je      .d
        mov     ah, 'l'
        cmp     al, '<'
        je      .d
        mov     ah, 't'
        cmp     al, 14h
        je      .d
        cmp     al, '$'
        jne     .c
        lodsb
        mov     ah, al
.d:     push    ax
        mov     al, '$'
        call    dchar
        pop     ax
        mov     al, ah
.c:     call    dchar
        jmp     .text

msg:    mov     ah, 9
        int     21h
        mov     dx, m_crlf
        mov     ah, 9
        int     21h
        ret

skipws1:
        inc     si
skipws: lodsb
        cmp     al, 9
        je      skipws
        cmp     al, ' '
        je      skipws
        dec     si
        ret

; does the command line at SI start with the switch at ES:DI?  ZF=1 and SI
; past it if so
match:  push    si
.l:     cmp     byte [es:di], 0
        je      .y
        lodsb
        call    upcase
        scasb
        je      .l
        pop     si
        ret
.y:     pop     ax
        ret

number: xor     bx, bx
.l:     lodsb
        sub     al, '0'
        cmp     al, 10
        jae     .e
        mov     cx, bx
        add     bx, bx
        add     bx, bx
        add     bx, cx
        add     bx, bx
        cbw
        add     bx, ax
        jmp     .l
.e:     dec     si
        ret

opts    db      0               ; 1 /REINSTALL 2 /BUFSIZE 4 installed
                                ; 8 /H 10h /M 20h /INSERT 40h /OVERSTRIKE
tabset  db      0FFh            ; /TAB 1, /NOTAB 0, neither FFh
bufsize dw      512
defd    db      0               ; a macro was defined

o_reins db      '/REINSTALL', 0
o_buf   db      '/BUFSIZE', 0
o_hist  db      '/HISTORY', 0
o_h     db      '/H', 0
o_mac   db      '/MACROS', 0
o_m     db      '/M', 0
o_help  db      '/?', 0
o_ins   db      '/INSERT', 0
o_ovr   db      '/OVERSTRIKE', 0
o_notab db      '/NOTAB', 0
o_tab   db      '/TAB', 0

m_incomp db     7, 'An incompatible DOSKey is already installed.$'
m_nobuf db      7, 'Cannot change BUFSIZE.$'
m_inval db      'Invalid macro definition.$'
m_nomem db      7, 'Insufficient memory to store macro. Use the DOSKEY command with the /BUFSIZE', 13, 10
        db      'switch to increase available memory.$'
m_dosv  db      7, 'Incorrect DOS version$'
m_crlf  db      13, 10, '$'
m_other db      'The DOSKEY already loaded is not DOSKEYSC, so TAB does not complete names.', 13, 10
        db      'DOSKEYSC /REINSTALL loads DOSKEYSC over it, or load DOSKEYSC in its place.$'

m_help  db      'Edits command lines, recalls MS-DOS commands, creates macros, and completes', 13, 10
        db      'file names.  DOSKEYSC 1.0, by StevenC & Claude.', 13, 10, 13, 10
        db      'DOSKEYSC [/REINSTALL] [/BUFSIZE=size] [/MACROS] [/HISTORY]', 13, 10
        db      '  [/INSERT | /OVERSTRIKE] [/TAB | /NOTAB] [macroname=[text]]', 13, 10, 13, 10
        db      '  /REINSTALL    Installs a new copy of Doskey.', 13, 10
        db      '  /BUFSIZE=size Sets size of command history buffer.', 13, 10
        db      '  /MACROS       Displays all Doskey macros.', 13, 10
        db      '  /HISTORY      Displays all commands stored in memory.', 13, 10
        db      '  /INSERT       Specifies that new text you type is inserted in old text.', 13, 10
        db      '  /OVERSTRIKE   Specifies that new text overwrites old text.', 13, 10
        db      '  /TAB /NOTAB   Turns TAB filename completion on (the default) or off.', 13, 10
        db      '  macroname     Specifies a name for a macro you create.', 13, 10
        db      '  text          Specifies commands you want to record.', 13, 10, 13, 10
        db      'UP and DOWN ARROWS recall commands; ESC clears command line; F7 displays', 13, 10
        db      'command history; ALT+F7 clears command history; F8 searches command', 13, 10
        db      'history; F9 selects a command by number; ALT+F10 clears macro definitions.', 13, 10
        db      'TAB completes a file or directory name; TAB again and SHIFT+TAB step through', 13, 10
        db      'the other names that match.', 13, 10, 13, 10
        db      'The following are some special codes in Doskey macro definitions:', 13, 10
        db      '$T     Command separator.  Allows multiple commands in a macro.', 13, 10
        db      '$1-$9  Batch parameters.  Equivalent to %1-%9 in batch programs.', 13, 10
        db      '$*     Symbol replaced by everything following macro name on command line.', 13, 10
        db      0
