; IRQCOUNT.COM -- how often does each hardware interrupt fire?
; StevenC & Claude, 2026.  Public domain (the Unlicense).
;
; Hooks INT 08h-0Fh (IRQ 0-7) with a counter each, waits 36 BIOS ticks
; (about two seconds), puts every vector back and prints the counts.  Found
; while working out why copies between two PicoMEM EMS windows run 32%
; faster with interrupts off: which interrupt is it?
;
; nasm -f bin -o IRQCOUNT.COM IRQCOUNT.ASM

		cpu	8086
		org	100h

		; save and hook the eight vectors
		xor	ax, ax
		mov	es, ax
		mov	si, 8 * 4
		mov	di, old
		mov	bx, stubs
		mov	cx, 8
		cli
.h:		mov	ax, [es:si]
		mov	[di], ax
		mov	ax, [es:si+2]
		mov	[di+2], ax
		mov	[es:si], bx
		mov	[es:si+2], cs
		add	si, 4
		add	di, 4
		add	bx, STUBLEN
		loop	.h
		sti

		; 36 ticks
		mov	ax, [es:046Ch]
.w0:		cmp	ax, [es:046Ch]
		je	.w0
		mov	ax, [es:046Ch]
		add	ax, 36
.w1:		cmp	ax, [es:046Ch]
		jne	.w1

		; unhook
		mov	si, 8 * 4
		mov	di, old
		mov	cx, 8
		cli
.u:		mov	ax, [di]
		mov	[es:si], ax
		mov	ax, [di+2]
		mov	[es:si+2], ax
		add	si, 4
		add	di, 4
		loop	.u
		sti

		; report
		mov	dx, sHead
		mov	ah, 9
		int	21h
		xor	bx, bx
.p:		mov	dx, sIrq
		mov	ah, 9
		int	21h
		mov	dl, bl
		add	dl, '0'
		mov	ah, 2
		int	21h
		mov	dl, ':'
		int	21h
		mov	dl, ' '
		int	21h
		push	bx
		shl	bx, 1
		mov	ax, [count+bx]
		call	pdec
		mov	dx, sCrlf
		mov	ah, 9
		int	21h
		pop	bx
		inc	bx
		cmp	bx, 8
		jb	.p
		mov	ax, 4C00h
		int	21h

pdec:		mov	bx, 10
		xor	cx, cx
.d:		xor	dx, dx
		div	bx
		push	dx
		inc	cx
		test	ax, ax
		jnz	.d
.o:		pop	dx
		add	dl, '0'
		mov	ah, 2
		int	21h
		loop	.o
		ret

; one stub per IRQ: count, then on to the old handler
%macro STUB 1
		inc	word [cs:count + %1 * 2]
		jmp	far [cs:old + %1 * 4]
%endmacro
stubs:
STUB 0
STUBLEN		equ	$ - stubs
STUB 1
STUB 2
STUB 3
STUB 4
STUB 5
STUB 6
STUB 7

old:		times	8 dd 0
count:		times	8 dw 0
sHead		db	'interrupts in 36 BIOS ticks (about 2 seconds):', 13, 10, '$'
sIrq		db	'  IRQ $'
sCrlf		db	13, 10, '$'
