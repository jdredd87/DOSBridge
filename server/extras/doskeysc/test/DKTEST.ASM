;=============================================================================
; DKTEST -- drive the resident DOSKEY from a key script, and report.
; StevenC & Claude, 2026.  Public domain.  (A test tool, not part of the kit.)
;
;   DKTEST file.KEY [report]      (the report to stdout if no file named)
;
; Does what COMMAND.COM does -- prompt, INT 2Fh AX=4810h with its 128-byte
; buffer holding the last line as the template -- while serving DOSKEY's
; keyboard reads (INT 21h AH=0Bh/08h) from the script, so no keystroke can
; be left over for anything else.  DOSKEY draws on the real console; after
; each line the report gets the line, the cursor and the whole text screen.
; test/hwcheck.py makes the same report in the emulator to compare with.
;
; Script: bytes as typed; 00h xx is the extended key xx.  When it runs out,
; the reads get Enter, and DKTEST stops after that line.
;=============================================================================
        cpu     8086
        org     100h

start:  mov     sp, stack_top
        ; the file name
        mov     si, 81h
.sk:    lodsb
        cmp     al, ' '
        je      .sk
        cmp     al, 13
        je      usage
        lea     dx, [si-1]
.nm:    lodsb
        cmp     al, ' '
        je      .nme
        cmp     al, 13
        jne     .nm
.nme:   mov     byte [si-1], 0
        cmp     al, 13                  ; a second name: the report file
        je      .one
.sk2:   lodsb
        cmp     al, ' '
        je      .sk2
        cmp     al, 13
        je      .one
        lea     bx, [si-1]
.nm2:   lodsb
        cmp     al, ' '
        je      .nm2e
        cmp     al, 13
        jne     .nm2
.nm2e:  mov     byte [si-1], 0
        push    dx
        mov     dx, bx
        xor     cx, cx
        mov     ah, 3Ch
        int     21h
        pop     dx
        jc      usage
        mov     [outh], ax
.one:   mov     ax, 3D00h
        int     21h
        jc      usage
        mov     bx, ax
        mov     cx, KEYMAX
        mov     dx, keys
        mov     ah, 3Fh
        int     21h
        mov     [nkeys], ax
        mov     ah, 3Eh
        int     21h
        ; the console, for the prompt
        mov     dx, s_con
        mov     ax, 3D01h
        int     21h
        mov     [conh], ax
        ; DOSKEY echoes through stdout: make that the console for the test
        ; (a bridge job's stdout is a file), and keep the old one
        mov     bx, 1
        mov     ah, 45h
        int     21h
        mov     [savout], ax
        cmp     word [outh], 1
        jne     .own
        mov     [outh], ax
.own:   mov     bx, [conh]
        mov     cx, 1
        mov     ah, 46h
        int     21h
        ; take over DOSKEY's key reads
        mov     ax, 3521h
        int     21h
        mov     [old21], bx
        mov     [old21+2], es
        mov     dx, i21
        mov     ax, 2521h
        int     21h
        push    cs
        pop     es
        ; a clean screen, cursor home, the usual cursor
        mov     ax, 0600h
        mov     bh, 07h
        xor     cx, cx
        mov     dx, 184Fh
        int     10h
        mov     ah, 2
        xor     bh, bh
        xor     dx, dx
        int     10h
        mov     ah, 1
        mov     cx, 0607h
        int     10h
        push    ds
        xor     ax, ax
        mov     ds, ax
        and     byte [417h], 7Fh
        pop     ds
        mov     byte [buf], 80h
        mov     byte [buf+1], 0
        mov     byte [buf+2], 13

.line:  mov     dx, s_prompt
        mov     cx, 4
        call    conw
        mov     dx, buf
        mov     ax, 4810h
        int     2Fh
        or      ax, ax
        jz      .got
        mov     dx, s_decl
        call    outz
        jmp     done
.got:   ; report: the line, the cursor, the screen
        mov     dx, s_l
        call    outz
        mov     cl, [buf+1]
        xor     ch, ch
        mov     dx, buf+2
        call    outw
        call    outcrlf
        mov     ah, 3
        xor     bh, bh
        int     10h
        mov     [cpos], dx
        mov     [cshp], cx
        mov     al, [cpos+1]
        call    outhex
        mov     al, [cpos]
        call    outhex
        mov     al, [cshp+1]
        call    outhex
        mov     al, [cshp]
        call    outhex
        push    ds
        xor     ax, ax
        mov     ds, ax
        mov     al, [417h]
        pop     ds
        and     al, 80h
        call    outhex
        call    outcrlf
        call    dumpscr
        ; COMMAND.COM's own new line
        mov     dx, s_crlf
        mov     cx, 2
        call    conw
        cmp     byte [ended], 0
        je      .line

done:   push    ds
        lds     dx, [old21]
        mov     ax, 2521h
        int     21h
        pop     ds
        mov     bx, [savout]            ; stdout back as it was
        mov     cx, 1
        mov     ah, 46h
        int     21h
        mov     bx, [conh]
        mov     ah, 3Eh
        int     21h
        mov     bx, [outh]
        mov     ah, 3Eh
        int     21h
        mov     ax, 4C00h
        int     21h

usage:  mov     dx, s_usage
        call    outz
        mov     ax, 4C01h
        int     21h

; the text screen, 25 rows, trailing blanks dropped
dumpscr:
        push    ds
        mov     ax, 40h
        mov     ds, ax
        mov     ax, 0B800h
        cmp     byte [49h], 7
        jne     .c
        mov     ax, 0B000h
.c:     mov     si, [4Eh]
        pop     ds
        mov     [vseg], ax
        mov     [voff], si
        xor     bx, bx                  ; row
.r:     push    ds
        mov     si, [voff]
        mov     ax, bx
        mov     cx, 160
        mul     cx
        add     si, ax
        mov     ds, [cs:vseg]
        mov     di, rowbuf
        mov     cx, 80
.ch:    lodsb
        inc     si
        mov     [es:di], al
        inc     di
        loop    .ch
        pop     ds
        mov     cx, 80                  ; drop the trailing blanks
.tr:    mov     di, cx
        cmp     byte [rowbuf+di-1], ' '
        jne     .trd
        loop    .tr
.trd:   mov     dx, s_r
        push    cx
        call    outz
        pop     cx
        mov     dx, rowbuf
        call    outw
        call    outcrlf
        inc     bx
        cmp     bx, 25
        jb      .r
        ret

; to the report (stdout): DS:DX, CX bytes / ASCIIZ / CRLF / AL in hex
outw:   push    bx
        mov     bx, [outh]
        mov     ah, 40h
        int     21h
        pop     bx
        ret
outz:   mov     si, dx
        xor     cx, cx
.l:     lodsb
        or      al, al
        je      outw
        inc     cx
        jmp     .l
outcrlf:
        mov     dx, s_crlf
        mov     cx, 2
        jmp     outw
outhex: push    ax
        mov     cl, 4
        shr     al, cl
        call    .d
        pop     ax
        and     al, 0Fh
.d:     add     al, '0'
        cmp     al, '9'
        jbe     .p
        add     al, 7
.p:     mov     [hexb], al
        mov     dx, hexb
        mov     cx, 1
        jmp     outw
; to the console
conw:   push    bx
        mov     bx, [conh]
        mov     ah, 40h
        int     21h
        pop     bx
        ret

; INT 21h: AH=0Bh and 08h from the script, everything else to DOS
i21:    cmp     ah, 0Bh
        je      .chk
        cmp     ah, 08h
        je      .get
        jmp     far [cs:old21]
.chk:   mov     al, 0FFh                ; always a key: Enter when the
        iret                            ; script is done
.get:   push    si
        mov     si, [cs:kpos]
        cmp     si, [cs:nkeys]
        jb      .k
        mov     byte [cs:ended], 1
        mov     al, 13
        pop     si
        iret
.k:     mov     al, [cs:keys+si]
        inc     si
        mov     [cs:kpos], si
        pop     si
        iret

s_con   db      'CON', 0
s_prompt db     'C:\>'
s_crlf  db      13, 10
s_l     db      'L:', 0
s_r     db      'R:', 0
s_decl  db      'DECLINED', 13, 10, 0
s_usage db      'DKTEST file.KEY [report]', 13, 10, 0
hexb    db      0
ended   db      0
kpos    dw      0
nkeys   dw      0
conh    dw      0
outh    dw      1
savout  dw      1
old21   dd      0
vseg    dw      0
cpos    dw      0
cshp    dw      0
voff    dw      0
KEYMAX  equ     16384

        section .bss
buf     resb    130
rowbuf  resb    80
keys    resb    KEYMAX
        resb    512
stack_top:
