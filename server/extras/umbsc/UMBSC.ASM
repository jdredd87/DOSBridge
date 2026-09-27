; UMBSC.SYS -- an upper memory block manager that uses NO conventional memory
;
; StevenC & Claude, 2026.  Public domain, like the work it comes from:
;   USE!UMBS.SYS  Marco van Zwetselaar, 1991, dedicated to the public domain
;   v2.1/v2.2     Krister Nordvall's NASM rewrite (PMUMB.SYS.asm in the
;                 ISA-PicoMEM tree is the same code with a PicoMEM check)
;
; Assemble:  nasm -f bin -o UMBSC.SYS UMBSC.ASM
;
; Use it exactly like USE!UMBS.SYS -- same command line, same answers:
;
;   DOS=UMB
;   DEVICE=C:\DRIVERS\UMBSC.SYS C800-D000 D800-E000
;
; WHAT IS DIFFERENT
;
; USE!UMBS keeps its XMS entry point, its INT 2Fh hook and its list of free
; blocks in the driver's own memory, which DOS loads in CONVENTIONAL memory
; because there is no upper memory yet -- 224 bytes on the V30, for the
; whole session, for code that runs a handful of times during boot.
;
; This one copies those ~125 bytes to the END of the last upper memory
; block, hands DOS the rest of that block, and then tells DOS to discard the
; driver: it clears bit 15 of its attribute word and reports zero units,
; which makes DOS treat it as a block device that found no drives and free
; it (MS-DOS SYSCONF.ASM, ISBLOCK -> Erase_Dev_do; no message is printed).
; The upper memory it keeps is the memory DOS would have given away, so
; nothing that was usable before is lost except those ~9 paragraphs of UMB.
;
; What callers see is unchanged: INT 2Fh AX=4300h returns 80h, AX=4310h
; returns the entry point, and the entry point answers function 10h
; (request UMB) exactly as v2.2 does, everything else as v2.2 does, or --
; if an XMS driver without UMB support was already loaded -- by passing the
; call on to it.

		cpu	8086

TAB		equ	9
CR		equ	13
LF		equ	10
SPACE		equ	32
MAXRANGES	equ	16

rhCommand	equ	2
rhStatus	equ	3
rhUnits		equ	13
rhBreak		equ	14
rhCmdLine	equ	18

		section	.text
		org	0

header:		dd	-1
attrib:		dw	8000h			; character device (see Erase)
		dw	strategy
		dw	interrupt
		db	'SCUMBDRV'

req:		dd	0

strategy:	mov	[cs:req], bx
		mov	[cs:req+2], es
		retf

interrupt:	push	ax
		push	bx
		push	cx
		push	dx
		push	si
		push	di
		push	bp
		push	ds
		push	es
		les	bx, [cs:req]
		cmp	byte [es:bx+rhCommand], 0
		je	init
		mov	word [es:bx+rhStatus], 8103h	; unknown command
		jmp	done

; ------------------------------------------------------------------ init
; Everything from here on is discarded.

init:		cld
		push	cs
		pop	ds
		mov	dx, sHello
		call	print

		; an XMS driver already?  then chain to it, unless it does UMBs
		mov	ax, 4300h
		int	2Fh
		cmp	al, 80h
		jne	.noxms
		mov	ax, 4310h
		int	2Fh
		mov	[oldxms], bx
		mov	[oldxms+2], es
		mov	byte [chain], 1
		mov	dx, sXmm
		call	print
		mov	ah, 10h			; ask for far too much: an XMS
		mov	dx, 0FFFFh		; that does not do UMBs says 80h
		call	far [oldxms]
		cmp	bl, 80h
		je	.noxms
		mov	dx, sManaged
		jmp	fail
.noxms:
		call	parse
		jnc	.parsed
		mov	dx, sParam
		jmp	fail
.parsed:
		; zero every block first, as v2.2 does, so a parity board never
		; reads uninitialised RAM -- then the resident part goes on top
		mov	si, ranges
		mov	cx, [nranges]
.zero:		push	cx
		lodsw
		mov	bx, ax			; segment
		lodsw
		mov	dx, ax			; paragraphs
		call	zerofill
		pop	cx
		loop	.zero

		; its size: the code, then (segment, length) per block and an
		; end mark, in whole paragraphs
		mov	ax, [nranges]
		shl	ax, 1
		shl	ax, 1
		add	ax, BLOBCODE + 2 + 15
		mov	cl, 4
		shr	ax, cl
		mov	[paras], ax

		; home: the END of the LAST block big enough to hold it with a
		; paragraph to spare.  At the end, so every block keeps its
		; start and DOS is handed them in the same order as before --
		; largest first, and on a tie the lowest address.
		mov	cx, [nranges]
		mov	si, cx
		dec	si
		shl	si, 1
		shl	si, 1
		add	si, ranges
.home:		mov	ax, [paras]
		cmp	[si+2], ax
		ja	.found
		sub	si, 4
		loop	.home
		mov	dx, sSmall
		jmp	fail
.found:		sub	[si+2], ax		; DOS keeps the start of it
		mov	ax, [si]
		add	ax, [si+2]
		mov	[home], ax

		; copy the resident part there, then fill in its pointers
		mov	es, ax
		xor	di, di
		mov	si, section.blob.start	; not a label: NASM may pad
		mov	cx, BLOBCODE
		rep	movsb
		mov	si, ranges		; the free list, then its end mark
		mov	cx, [nranges]
		shl	cx, 1
		rep	movsw
		xor	ax, ax
		stosw
		cmp	byte [chain], 0
		je	.nochain
		mov	byte [es:b_other], 0EAh	; jmp far oldxms
		mov	ax, [oldxms]
		mov	[es:b_other+1], ax
		mov	ax, [oldxms+2]
		mov	[es:b_other+3], ax
.nochain:
		mov	ax, 352Fh
		int	21h			; ES:BX = old INT 2Fh
		mov	ax, [home]
		mov	ds, ax
		mov	[b_old2f], bx
		mov	[b_old2f+2], es
		mov	dx, b_int2f		; DS:DX = new INT 2Fh
		mov	ax, 252Fh
		int	21h
		push	cs
		pop	ds

		mov	ax, [home]
		mov	di, sAt
		call	hex4
		mov	dx, sInstalled
		call	print
		jmp	erase

fail:		call	print
		mov	dx, sNotInst
		call	print
		; fall through: nothing was hooked, so nothing is kept

; Tell DOS to discard this driver: a block device with no units.
erase:		and	word [cs:attrib], 7FFFh
		les	bx, [cs:req]
		mov	byte [es:bx+rhUnits], 0
		mov	word [es:bx+rhBreak], 0
		mov	[es:bx+rhBreak+2], cs
		mov	word [es:bx+rhStatus], 0100h	; done, no error

done:		pop	es
		pop	ds
		pop	bp
		pop	di
		pop	si
		pop	dx
		pop	cx
		pop	bx
		pop	ax
		retf

; ------------------------------------------------ helpers (init only)

print:		mov	ah, 9
		int	21h
		ret

; AX -> four hex digits at DS:DI
hex4:		mov	cx, 4
.h:		push	cx
		mov	cl, 4
		rol	ax, cl
		pop	cx
		push	ax
		and	al, 0Fh
		add	al, '0'
		cmp	al, '9'
		jbe	.d
		add	al, 7
.d:		mov	[di], al
		inc	di
		pop	ax
		loop	.h
		ret

; zero DX paragraphs from BX:0
zerofill:	push	es
		xor	ax, ax
		xor	di, di
.seg:		mov	es, bx
		cmp	dx, 1000h
		jb	.last
		mov	cx, 8000h
		rep	stosw
		add	bx, 1000h
		sub	dx, 1000h
		jnz	.seg
		jmp	short .z
.last:		mov	cx, dx
		shl	cx, 1
		shl	cx, 1
		shl	cx, 1
		rep	stosw
.z:		pop	es
		ret

; Parse "XXXX-YYYY XXXX-YYYY ..." from the command line into 'ranges' as
; (segment, paragraphs).  CF set on any error, as v2.2 refuses the line.
parse:		push	ds
		les	bx, [cs:req]
		lds	si, [es:bx+rhCmdLine]
		xor	bx, bx			; ranges found
.skipname:	lodsb				; past the driver's own path
		cmp	al, CR
		je	.end
		cmp	al, LF
		je	.end
		or	al, al
		jz	.end
		cmp	al, SPACE
		je	.next
		cmp	al, TAB
		jne	.skipname
.next:		lodsb				; skip blanks
		cmp	al, SPACE
		je	.next
		cmp	al, TAB
		je	.next
		cmp	al, CR
		je	.end
		cmp	al, LF
		je	.end
		or	al, al
		jz	.end
		dec	si
		call	hexword			; start
		jc	.bad
		mov	di, dx
		lodsb
		cmp	al, '-'
		jne	.bad
		call	hexword			; end
		jc	.bad
		cmp	dx, di
		jbe	.bad
		cmp	bx, MAXRANGES
		jae	.bad
		sub	dx, di			; length in paragraphs
		push	bx
		shl	bx, 1
		shl	bx, 1
		mov	[cs:ranges+bx], di
		mov	[cs:ranges+bx+2], dx
		pop	bx
		inc	bx
		lodsb				; must be a separator
		cmp	al, SPACE
		je	.next
		cmp	al, TAB
		je	.next
		cmp	al, CR
		je	.end
		cmp	al, LF
		je	.end
		or	al, al
		jz	.end
.bad:		pop	ds
		stc
		ret
.end:		pop	ds
		mov	[nranges], bx
		or	bx, bx
		jz	.none
		clc
		ret
.none:		stc
		ret

; exactly four hex digits at DS:SI -> DX
hexword:	xor	dx, dx
		mov	cx, 4
.dig:		lodsb
		cmp	al, '0'
		jb	.no
		cmp	al, '9'
		jbe	.num
		and	al, 0DFh
		cmp	al, 'A'
		jb	.no
		cmp	al, 'F'
		ja	.no
		sub	al, 7
.num:		sub	al, '0'
		push	cx
		mov	cl, 4
		shl	dx, cl
		pop	cx
		or	dl, al
		loop	.dig
		clc
		ret
.no:		stc
		ret

oldxms:		dd	0
chain:		db	0
home:		dw	0
paras:		dw	0
nranges:	dw	0
ranges:		times MAXRANGES*2 dw 0

sHello:		db	CR, LF, 'UMBSC 2.2-SC1: upper memory manager (USE!UMBS by Marco van Zwetselaar,', CR, LF
		db	'  Krister Nordvall) -- rebuilt by StevenC & Claude to use no low memory', CR, LF, '$'
sXmm:		db	' > XMS memory manager found', CR, LF, '$'
sInstalled:	db	' > Installed: resident at '
sAt:		db	'0000h in upper memory, 0 bytes of conventional', CR, LF, LF, '$'
sNotInst:	db	' > Not installed', CR, LF, LF, '$'
sManaged:	db	' > UMBs are managed already', CR, LF, '$'
sParam:		db	' > Invalid command line: give ranges as XXXX-YYYY', CR, LF, '$'
sSmall:		db	' > No block is big enough to hold the resident part', CR, LF, '$'


; ----------------------------------------------------- the resident part
; Runs at HOME:0000.  Addresses below are offsets from its own start.

		section	blob follows=.text vstart=0 align=1

b_int2f:	cmp	ah, 43h
		je	b_mine
		db	0EAh			; JMP FAR to the old INT 2Fh,
b_old2f:	dd	0			; filled in at init
b_mine:		cmp	al, 10h
		jne	.inst
		mov	bx, b_xms
		push	cs
		pop	es
		iret
.inst:		mov	al, 80h			; 4300h, and every other 43xx,
		iret				; as v2.2 answers them

; XMS entry point.  The first five bytes are the conventional hook area.
b_xms:		jmp	short .go
		nop
		nop
		nop
.go:		cmp	ah, 10h
		je	b_umb
b_other:	jmp	short b_notimpl		; becomes JMP FAR old XMS when
		db	0, 0, 0			; chaining

; Function 10h, request UMB: DX = paragraphs wanted.
;   found:  AX = 1, BX = segment, DX = size of the block given
;   not:    AX = 0, BL = B0h (smaller available) or B1h (none), DX = largest
; Each block is handed out whole, once -- v2.2's rule.
b_umb:		push	si
		push	cx
		push	bx
		mov	si, b_list
		xor	cx, cx
		xchg	dx, cx			; DX = largest so far, CX = wanted
.search:	cs lodsw
		test	ax, ax
		jz	.none
		mov	bx, ax
		inc	ax			; FFFFh = given away already
		cs lodsw
		jz	.search
		cmp	dx, ax
		ja	.chk
		mov	dx, ax
.chk:		cmp	cx, ax
		ja	.search
		mov	word [cs:si-4], 0FFFFh
		mov	dx, 1
		xchg	dx, ax
		pop	cx			; drop the saved BX
		jmp	short .ret
.none:		pop	bx
		mov	bl, 0B0h
		test	dx, dx
		jnz	.ret
		inc	bx			; B1h: none at all
.ret:		pop	cx
		pop	si
		retf

; Everything else, as v2.2: version 0 with no HMA, no extended memory,
; and 80h "not implemented", always with AX = 0.
b_notimpl:	test	ah, ah
		jnz	.nv
		xor	bx, bx
		cwd
		jmp	short .r
.nv:		cmp	ah, 8
		jne	.ni
		cwd
.ni:		mov	bl, 80h
.r:		xor	ax, ax
		retf

b_list:						; (segment, paragraphs) ... 0

BLOBCODE	equ	b_list
