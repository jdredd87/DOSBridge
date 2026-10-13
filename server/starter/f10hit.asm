; f10hit.asm -- has F10 been pressed?  For the agent loop's "ask Claude".
; StevenC & Claude (Anthropic), 2026-10-13.
;
;   F10HIT        exit 1 if F10 is among the keys waiting, else 0
;
; AI.BAT runs this once per poll, after KEYHIT.  F10 opens ASK.EXE: a line
; typed at the DOS machine, sent to the bridge as asks/<box>.txt, where a
; Claude Code session watching for it picks it up.
;
; A queued keystroke works here now, where it did not when KEYHIT was
; written: the poll was mTCP's HTGET then, which read the keyboard so ESC
; could abort a transfer and ate whatever was waiting.  The poll is UGET's
; now, our own UDP, and UGET never touches the keyboard -- so a key pressed
; while it waits is still in the BIOS buffer when the loop comes round.
;
; Every key waiting is taken, F10 or not: anything else typed at the agent
; loop has no meaning, and a stray key left at the front of the buffer would
; hide an F10 behind it for ever.  Nothing is printed.
;
; Build:  nasm -f bin -o build\F10HIT.COM f10hit.asm

        org     100h

        xor     bl,bl               ; BL = 1 once F10 has been seen
next:
        mov     ah,1                ; INT 16h 01h: is a key waiting?
        int     16h
        jz      done                ; ZF set: the buffer is empty
        xor     ah,ah               ; INT 16h 00h: take it
        int     16h
        cmp     ax,4400h            ; F10: scan code 44h, no character
        jne     next
        mov     bl,1
        jmp     next
done:
        mov     al,bl               ; exit code: 1 F10, 0 not
        mov     ah,4Ch
        int     21h
