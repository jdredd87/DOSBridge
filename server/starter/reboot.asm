; reboot.asm -- REBOOT.COM and COLDBOOT.COM, the agent's two ways to restart.
; StevenC & Claude (Anthropic).
;
;   REBOOT        warm boot: no memory test, the way Ctrl-Alt-Del does it
;   COLDBOOT      cold boot: the full POST, as near to a power cycle as
;                 software gets
;
; The BIOS reads the word at 0040:0072 on its way through the reset vector:
; 1234h means "warm, skip the memory test", anything else means a full POST.
; So both are the same four instructions -- set the flag, jump to FFFF:0000 --
; and 16 bytes each.  dosreboot runs REBOOT (COLDBOOT with --cold), dosdrv
; ends its batch with COLDBOOT, and the agent loop (C:\AI\AI.BAT) cold-boots
; when NETCHK says the link is dead.
;
; Build both from this one file (the copies the kit ships are in dos\):
;   nasm -f bin -o build\REBOOT.COM reboot.asm
;   nasm -f bin -DCOLD -o build\COLDBOOT.COM reboot.asm

        cpu     8086
        org     100h
        mov     ax,40h
        mov     ds,ax
%ifdef COLD
        mov     word [72h],0        ; not 1234h: a full POST
%else
        mov     word [72h],1234h    ; the BIOS's warm-boot flag
%endif
        jmp     0FFFFh:0000h        ; the reset vector
