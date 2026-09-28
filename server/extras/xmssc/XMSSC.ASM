; XMSSC -- an XMS driver for PCs with no extended memory, built on EMS
;
; StevenC & Claude, 2026.  Public domain (the Unlicense).  Written from the
; XMS 2.0/3.0 and EMS 3.2/4.0 specifications; no other driver's code.
;
; Assemble:  nasm -f bin -o XMSSC.SYS XMSSC.ASM            (CONFIG.SYS)
;            nasm -f bin -DCOM -o XMSSC.COM XMSSC.ASM      (a TSR)
;
; An 8086 has no memory above 1 MB, so there is nothing for an XMS driver to
; manage -- but an EMS board has megabytes, and software that wants XMS can
; have them.  Every extended memory block (EMB) is an EMS handle; a move
; maps the block's pages into the EMS page frame and copies.
;
;   DEVICE=C:\DRIVERS\XMSSC.SYS [switches]   after the EMS driver
;   XMSSC [switches]                          the same, from AUTOEXEC.BAT
;   XMSSC /U                                  unload the TSR
;
; TWO WAYS TO MAP, chosen at load time:
;
;   PicoMEM direct  On a PicoMEM card the EMS page registers are I/O ports
;                   that read back.  A move writes them itself -- four OUTs
;                   and four INs -- instead of calling INT 67h, and puts
;                   back exactly what it found.  Interrupts are held off
;                   while a window is borrowed (a slice at a time, /I:n),
;                   so an interrupt routine never sees the frame changed
;                   under it and the EMS driver's own record of the frame
;                   is never wrong.
;
;   EMS calls       Any EMS 3.2 or later driver: map with INT 67h 44h,
;                   around a page map saved with 4Eh on the caller's stack.
;                   Safe to call from an interrupt routine.
;
; Either way the frame is shared politely: the page map a program has set
; is always put back, a conventional address INSIDE the frame is read
; through whatever that program has mapped there, and the windows a move
; borrows are chosen not to overlap it.
;
; XMS versions: reports 3.00 (/V:2 reports 2.00).  All of 2.0 is here.
; The 3.0 calls that take 32-bit registers (88h 89h 8Eh 8Fh) work on a 386
; or later and answer 80h (not implemented) on anything older, where no
; program can make them.  There is no HMA and no A20 line on an 8086: HMA
; requests answer 90h, and A20 is reported as it really is.  A block cannot
; be locked (ADh): it has no address a program could use.  UMB calls go to
; the XMS driver that was already loaded, if it serves them (UMBSC does).

		cpu	8086

CR		equ	13
LF		equ	10

MAXH		equ	128		; handles, most
DEFH		equ	32		; handles, by default
GPSIZE		equ	256		; direct mode: global page of every EMB page
MAPMAX		equ	64		; EMS page map bytes we will hold on a stack

; a handle is the offset of its 8-byte entry
E_FLAG		equ	0		; byte: 1 = allocated
E_LOCK		equ	1		; byte: lock count, always 0 here
E_KB		equ	2		; word: size in KB
E_EMS		equ	4		; word: EMS handle, FFFFh = no pages
E_BASE		equ	6		; word: first of its pages in gp[] (direct)
ESIZE		equ	8

; flags
F_DIRECT	equ	1		; PicoMEM ports, not INT 67h
F_386		equ	2		; 32-bit registers
F_V3		equ	4		; report XMS 3.00
F_EMS4		equ	8		; EMS 4.0: 51h reallocate

%ifdef COM
RESORG		equ	60h		; the resident part moves down into the PSP
%else
RESORG		equ	12h		; after the device header
%endif

; ======================================================== file start
		section	.text
%ifdef COM
		org	100h
		jmp	com_start
%else
		org	0
		dd	-1
		dw	8000h			; character device
		dw	strategy
		dw	devint
		db	'XMSXXXX0'
%endif

; ======================================================== resident part
		section	blob follows=.text vstart=RESORG align=1
blob0:

%ifndef COM
strategy:	mov	[cs:reqptr], bx
		mov	[cs:reqptr+2], es
		retf

devint:		push	bx
		push	es
		les	bx, [cs:reqptr]
		cmp	byte [cs:inited], 0
		jne	.done
		cmp	byte [es:bx+2], 0	; INIT, the first time only
		jne	.done
		jmp	sys_init
.done:		mov	word [es:bx+3], 0100h	; done
		pop	es
		pop	bx
		retf
reqptr:		dd	0
inited:		db	0
%endif

old2f:		dd	0
umbxms:		dd	0			; UMB server's entry, 0 = none
emsport:	dw	0			; direct: page register of window 0
frame:		dw	0			; page frame segment
fend:		dw	0			; ...the paragraph after it
flin:		dd	0			; ...and its linear address
tabbeg:		dw	0			; handle table
tabend:		dw	0
gpbase:		dw	0			; direct: gp[] offset
gpused:		dw	0			; direct: gp[] slots in use
ichunk:		dw	0			; direct: bytes per slice
xver:		dw	0300h
flags:		db	0
cpucls:		db	0			; 0 8086, 1 186/V30, 2 286, 3 386+

int2f:		cmp	ax, 4300h
		je	.inst
		cmp	ax, 4310h
		je	.entry
		jmp	far [cs:old2f]
.inst:		mov	al, 80h
		iret
.entry:		mov	bx, xms
		push	cs
		pop	es
		iret

		db	'XMSSC1.0'		; found at entry-8 by /U and a reload
xms:		jmp	short .go		; the 5-byte hook area of the spec
		nop
		nop
		nop
.go:		cmp	ah, 0Bh
		jne	.disp
		jmp	move
.disp:		cmp	ah, 12h
		ja	.hi
		push	ax			; becomes the target
		push	bx
		push	bp
		mov	bl, ah
		xor	bh, bh
		shl	bx, 1
		mov	bx, [cs:ftab+bx]
		mov	bp, sp
		mov	[bp+4], bx
		pop	bp
		pop	bx
		ret				; near: into the function
.hi:		test	byte [cs:flags], F_386
		jz	notimpl
		test	byte [cs:flags], F_V3
		jz	notimpl
		cmp	ah, 88h
		jne	.h1
		jmp	f88
.h1:		cmp	ah, 89h
		jne	.h2
		jmp	f89
.h2:		cmp	ah, 8Eh
		jne	.h3
		jmp	f8E
.h3:		cmp	ah, 8Fh
		jne	notimpl
		jmp	f8F

ftab:		dw	f00, f01, f01, fena, fdis, fena, fdis, f07
		dw	f08, f09, f0A, move, f0C, f0D, f0E, f0F
		dw	fumb, fumb, fumb

notimpl:	mov	bl, 80h
fail:		xor	ax, ax
		retf

; ---- 00h: version.  BX = our revision, DX = 0: no HMA
f00:		mov	ax, [cs:xver]
		mov	bx, 0100h
		xor	dx, dx
		retf

; ---- 01h, 02h: request / release the HMA, which does not exist
f01:		mov	bl, 90h
		jmp	fail

; ---- 03h, 05h: enable A20; 04h, 06h: disable it; 07h: query.  There is
; no A20 line on an 8086/186 and this driver drives none elsewhere, so it
; reports the truth: enabled if and only if memory above 1 MB is reachable.
fena:		call	a20q
		jnz	okret
		mov	bl, 82h
		jmp	fail
fdis:		call	a20q
		jz	okret
		mov	bl, 94h			; A20 still enabled
		jmp	fail
f07:		call	a20q
		mov	bl, 0
		retf
okret:		mov	ax, 1
		retf

; AX = 1 and NZ if addresses wrap at 1 MB no longer, else AX = 0 and ZF
a20q:		xor	ax, ax
		cmp	byte [cs:cpucls], 2
		jb	.r			; an 8086 or 186 always wraps
		push	ds
		push	es
		push	cx
		mov	ds, ax			; 0000:0000
		dec	ax
		mov	es, ax			; FFFF:0010, the same byte if wrapped
		pushf
		cli
		mov	cx, [0]
		mov	ax, cx
		not	ax
		mov	[0], ax
		cmp	ax, [es:10h]
		mov	[0], cx
		mov	ax, 0
		je	.w
		inc	ax
.w:		popf
		pop	cx
		pop	es
		pop	ds
.r:		test	ax, ax		; ZF: wrapped
		ret

; ---- 08h: query free memory.  AX = largest block, DX = total, KB
f08:		call	emsfree
		mov	dx, ax
		mov	bl, 0
		test	ax, ax
		jnz	.r
		mov	bl, 0A0h
.r:		retf

; AX = KB of EMS we could still hand out (capped at 65535)
emsfree:	push	bx
		push	cx
		push	dx
		mov	ah, 42h
		int	67h
		test	ah, ah
		mov	ax, 0
		jnz	.r
		test	byte [cs:flags], F_DIRECT
		jz	.k
		mov	ax, GPSIZE		; direct: gp[] must have room
		sub	ax, [cs:gpused]
		cmp	bx, ax
		jbe	.k
		mov	bx, ax
.k:		mov	ax, bx
		cmp	ax, 4096
		jb	.s
		mov	ax, 0FFFFh
		jmp	short .r
.s:		mov	cl, 4
		shl	ax, cl
.r:		pop	dx
		pop	cx
		pop	bx
		ret

; ---- 09h: allocate DX KB.  DX = handle
f09:		push	cx
		push	si
		call	newent
		mov	bl, 0A1h
		jc	.x
		mov	ax, dx
		call	kbpages			; CX = pages
		call	getpages
		jc	.x
		mov	[cs:si+E_KB], dx
		mov	byte [cs:si+E_FLAG], 1
		mov	byte [cs:si+E_LOCK], 0
		mov	dx, si
		pop	si
		pop	cx
		jmp	okret
.x:		pop	si
		pop	cx
		jmp	fail

; give entry SI an EMS handle of CX pages (none if 0) and learn them.
; CF and BL = XMS error if that cannot be done
getpages:	push	ax
		push	dx
		mov	word [cs:si+E_EMS], 0FFFFh
		mov	ax, [cs:gpused]
		mov	[cs:si+E_BASE], ax
		jcxz	.okc
		test	byte [cs:flags], F_DIRECT
		jz	.a
		add	ax, cx
		cmp	ax, GPSIZE
		mov	bl, 0A0h
		ja	.no
.a:		push	bx
		mov	bx, cx
		mov	ah, 43h
		int	67h
		pop	bx
		call	emserr
		jc	.no
		mov	[cs:si+E_EMS], dx
		test	byte [cs:flags], F_DIRECT
		jz	.ok
		add	[cs:gpused], cx
		xor	ax, ax
		call	learn
		jnc	.ok
		sub	[cs:gpused], cx
		mov	ah, 45h
		int	67h
		mov	word [cs:si+E_EMS], 0FFFFh
		mov	bl, 8Eh
.no:		stc
.ok:		pop	dx
		pop	ax
		ret
.okc:		clc
		jmp	short .ok

; AH = EMS status -> CF clear if 0, else CF and BL = the XMS error
emserr:		test	ah, ah
		jz	.r
		mov	bl, 0A1h
		cmp	ah, 85h			; no handles left
		je	.e
		mov	bl, 0A0h
		cmp	ah, 87h			; not enough pages
		je	.e
		cmp	ah, 88h
		je	.e
		mov	bl, 8Eh
.e:		stc
.r:		ret

; AX = KB -> CX = 16 KB pages
kbpages:	add	ax, 15
		mov	cx, 4096
		jc	.r
		mov	cl, 4
		shr	ax, cl
		mov	cx, ax
.r:		ret

; SI = a free entry, or CF
newent:		mov	si, [cs:tabbeg]
.l:		cmp	si, [cs:tabend]
		jae	.no
		cmp	byte [cs:si+E_FLAG], 0
		je	.r
		add	si, ESIZE
		jmp	.l
.no:		stc
.r:		ret

; BX = a handle -> CF clear if it is an allocated block
valid:		cmp	bx, [cs:tabbeg]
		jb	.no
		cmp	bx, [cs:tabend]
		jae	.no
		push	ax
		mov	ax, bx
		sub	ax, [cs:tabbeg]
		test	al, ESIZE - 1
		pop	ax
		jnz	.no
		cmp	byte [cs:bx+E_FLAG], 1
		jne	.no
		clc
		ret
.no:		stc
		ret

; direct mode: find the global page number of CX pages of entry SI, from
; its logical page AX on, by mapping each through the EMS driver and
; reading the port back -- inside a saved page map, so nothing changes
; for anybody.  The registers themselves are put back as read, too: an
; EMS driver may restore a window nobody had mapped as page 0 (PMEMMSC
; does), and a window nobody mapped should stay that way.  CF if the EMS
; driver refused.
learn:		push	ax
		push	bx
		push	cx
		push	dx
		push	di
		push	es
		push	bp
		mov	bp, sp
		sub	sp, MAPMAX + 4
		mov	bx, ax
		push	cx
		mov	dx, [cs:emsport]
		lea	di, [bp-MAPMAX-4]
		mov	cx, 4
.sv:		in	al, dx
		mov	[ss:di], al
		inc	di
		inc	dx
		loop	.sv
		pop	cx
		push	ss
		pop	es
		lea	di, [bp-MAPMAX]
		mov	ax, 4E00h
		int	67h
		test	ah, ah
		jnz	.bad
		mov	di, [cs:si+E_BASE]
		add	di, [cs:gpbase]
		add	di, bx
.l:		mov	ax, 4400h		; into window 0
		mov	dx, [cs:si+E_EMS]
		int	67h
		test	ah, ah
		jnz	.put
		mov	dx, [cs:emsport]
		in	al, dx
		mov	[cs:di], al
		inc	di
		inc	bx
		loop	.l
.put:		push	ax
		push	ds
		push	si
		push	ss
		pop	ds
		lea	si, [bp-MAPMAX]
		mov	ax, 4E01h
		int	67h
		mov	dx, [cs:emsport]
		lea	si, [bp-MAPMAX-4]
		mov	cx, 4
.rs:		lodsb
		out	dx, al
		inc	dx
		loop	.rs
		pop	si
		pop	ds
		pop	ax
		or	ah, ah
		jz	.r
.bad:		stc
.r:		mov	sp, bp
		pop	bp
		pop	es
		pop	di
		pop	dx
		pop	cx
		pop	bx
		pop	ax
		ret

; direct mode: gp[] slots.  gpins: CX new slots at index BX; gpdel: remove
; CX slots at index BX.  Every other entry's slice moves with them.
gpins:		jcxz	.r
		push	ax
		push	si
		push	di
		push	ds
		push	es
		push	cs
		pop	ds
		push	cs
		pop	es
		push	cx
		mov	si, [gpbase]
		add	si, [gpused]
		dec	si			; the last used slot
		mov	di, si
		add	di, cx
		mov	cx, [gpused]
		sub	cx, bx			; slots from BX to the end
		std
		rep	movsb
		cld
		pop	cx
		add	[gpused], cx
		pop	es
		pop	ds
		pop	di
		pop	si
		call	shiftfrom		; bases >= BX move up by CX
		pop	ax
.r:		ret

gpdel:		jcxz	.r
		push	ax
		push	si
		push	di
		push	ds
		push	es
		push	cs
		pop	ds
		push	cs
		pop	es
		mov	ax, cx
		mov	di, [gpbase]
		add	di, bx
		mov	si, di
		add	si, ax
		mov	cx, [gpused]
		sub	cx, bx
		sub	cx, ax			; slots after the removed ones
		rep	movsb
		sub	[gpused], ax
		mov	cx, ax
		pop	es
		pop	ds
		pop	di
		pop	si
		neg	cx
		call	shiftfrom		; bases > BX move down
		neg	cx
		pop	ax
.r:		ret

; add CX to the base of every entry but SI whose slice starts at or after
; BX (CX > 0), or after BX (CX < 0, a removal: never below BX)
shiftfrom:	push	ax
		push	di
		mov	di, [cs:tabbeg]
.l:		cmp	di, [cs:tabend]
		jae	.r
		cmp	di, si
		je	.n
		cmp	byte [cs:di+E_FLAG], 0
		je	.n
		mov	ax, [cs:di+E_BASE]
		test	cx, cx
		js	.del
		cmp	ax, bx
		jb	.n
		add	ax, cx
		jmp	short .st
.del:		cmp	ax, bx
		jbe	.n
		add	ax, cx
		cmp	ax, bx
		jge	.st
		mov	ax, bx
.st:		mov	[cs:di+E_BASE], ax
.n:		add	di, ESIZE
		jmp	.l
.r:		pop	di
		pop	ax
		ret

; ---- 0Ah: free handle DX
f0A:		push	bx
		mov	bx, dx
		call	valid
		mov	al, 0A2h
		jc	.x
		mov	al, 0ABh
		cmp	byte [cs:bx+E_LOCK], 0
		jne	.x
		push	si
		mov	si, bx
		call	droppages
		pop	si
		mov	al, 8Eh
		jc	.x
		mov	byte [cs:bx+E_FLAG], 0
		pop	bx
		jmp	okret
.x:		pop	bx
		mov	bl, al
		jmp	fail

; give back entry SI's EMS pages and gp[] slots.  CF if EMS refused
droppages:	push	ax
		push	bx
		push	cx
		push	dx
		mov	dx, [cs:si+E_EMS]
		cmp	dx, 0FFFFh
		je	.ok
		mov	ah, 45h
		int	67h
		test	ah, ah
		stc
		jnz	.r
		mov	word [cs:si+E_EMS], 0FFFFh
		test	byte [cs:flags], F_DIRECT
		jz	.ok
		mov	ax, [cs:si+E_KB]
		call	kbpages
		mov	bx, [cs:si+E_BASE]
		call	gpdel
.ok:		clc
.r:		pop	dx
		pop	cx
		pop	bx
		pop	ax
		ret

; ---- 0Ch: lock.  A block in EMS has no linear address to give
f0C:		push	bx
		mov	bx, dx
		call	valid
		pop	bx
		mov	bl, 0A2h
		jc	.no
		mov	bl, 0ADh
.no:		jmp	fail

; ---- 0Dh: unlock -- nothing is ever locked
f0D:		push	bx
		mov	bx, dx
		call	valid
		pop	bx
		mov	bl, 0A2h
		jc	.no
		mov	bl, 0AAh
.no:		jmp	fail

; ---- 0Eh: handle information.  BH = locks, BL = free handles, DX = KB
f0E:		push	bx
		mov	bx, dx
		call	valid
		pop	bx
		jnc	.ok
		mov	bl, 0A2h
		jmp	fail
.ok:		call	nfree
		cmp	ax, 255
		jbe	.s
		mov	al, 255
.s:		mov	bl, al
		mov	bh, 0			; never locked
		push	si
		mov	si, dx
		mov	dx, [cs:si+E_KB]
		pop	si
		jmp	okret

; AX = free handles
nfree:		push	si
		xor	ax, ax
		mov	si, [cs:tabbeg]
.l:		cmp	si, [cs:tabend]
		jae	.r
		cmp	byte [cs:si+E_FLAG], 0
		jne	.n
		inc	ax
.n:		add	si, ESIZE
		jmp	.l
.r:		pop	si
		ret

; ---- 0Fh: reallocate handle DX to BX KB
f0F:		push	cx
		push	si
		push	bx
		mov	bx, dx
		call	valid
		mov	si, bx
		pop	bx
		mov	al, 0A2h
		jc	.x
		mov	al, 0ABh
		cmp	byte [cs:si+E_LOCK], 0
		jne	.x
		mov	ax, [cs:si+E_KB]
		call	kbpages			; CX = pages it has
		push	cx
		mov	ax, bx
		call	kbpages
		mov	ax, cx			; AX = pages it needs
		pop	cx
		push	bx
		cmp	ax, cx
		je	.same
		call	repage
		jnc	.same
		mov	al, bl
		pop	bx
		jmp	short .x
.same:		pop	bx
		mov	[cs:si+E_KB], bx
		pop	si
		pop	cx
		jmp	okret
.x:		pop	si
		pop	cx
		mov	bl, al
		jmp	fail

; entry SI goes from CX pages to AX pages, keeping the contents up to the
; smaller.  CF and BL = the XMS error on failure, the block as it was.
repage:		push	cx
		push	dx
		push	di
		jcxz	.fresh
		test	ax, ax
		jz	.none
		test	byte [cs:flags], F_EMS4
		jz	.copy
		mov	di, cx			; DI = pages it had
		push	ax
		mov	bx, ax
		mov	dx, [cs:si+E_EMS]
		mov	ah, 51h			; EMS 4.0: reallocate in place
		int	67h
		call	emserr
		pop	ax			; AX = pages it has now
		jc	.r
		test	byte [cs:flags], F_DIRECT
		jz	.r
		mov	bx, [cs:si+E_BASE]
		add	bx, di			; just past its old slice
		mov	cx, ax
		sub	cx, di
		jb	.shrink
		mov	dx, [cs:gpused]
		add	dx, cx
		cmp	dx, GPSIZE
		ja	.undo
		call	gpins
		jmp	short .lrn
.shrink:	neg	cx
		sub	bx, cx
		call	gpdel
.lrn:		mov	cx, ax			; learn them all again: the EMS
		xor	ax, ax			; driver may have moved any of them
		call	learn
		mov	bl, 8Eh
		jmp	short .r
.undo:		mov	bx, di			; no room in gp[]: back as it was
		mov	dx, [cs:si+E_EMS]
		mov	ah, 51h
		int	67h
		mov	bl, 0A0h
		stc
		jmp	short .r
.fresh:		mov	cx, ax			; had nothing: allocate
		call	getpages
		jmp	short .r
.none:		call	droppages		; to nothing: free
		mov	bl, 8Eh
		jmp	short .r
.copy:		call	copyre
.r:		pop	di
		pop	dx
		pop	cx
		ret

; EMS 3.2 has no reallocate: take a new handle of AX pages, copy the
; smaller of the two page counts across, and free the old one.  Generic
; mode only (a PicoMEM is EMS 4.0).
copyre:		push	ax
		push	cx
		push	dx
		push	si
		push	di
		push	ds
		push	es
		push	bp
		mov	bp, sp
		sub	sp, MAPMAX
		cmp	ax, cx
		jae	.n
		mov	cx, ax			; CX = pages to copy
.n:		mov	bx, ax
		mov	ah, 43h
		int	67h
		call	emserr
		jc	.r
		mov	di, dx			; DI = the new EMS handle
		push	cx
		push	ss
		pop	es
		push	di
		lea	di, [bp-MAPMAX]
		mov	ax, 4E00h
		int	67h
		pop	di
		pop	cx
		test	ah, ah
		jnz	.bad
		xor	bx, bx			; page
.l:		mov	ax, 4400h		; old -> window 0
		mov	dx, [cs:si+E_EMS]
		int	67h
		test	ah, ah
		jnz	.bad2
		mov	ax, 4401h		; new -> window 1
		mov	dx, di
		int	67h
		test	ah, ah
		jnz	.bad2
		push	cx
		push	si
		push	di
		mov	ax, [cs:frame]
		mov	ds, ax
		add	ax, 400h
		mov	es, ax
		xor	si, si
		xor	di, di
		mov	cx, 2000h
		rep	movsw
		pop	di
		pop	si
		pop	cx
		inc	bx
		loop	.l
		call	.put
		mov	dx, [cs:si+E_EMS]
		mov	ah, 45h
		int	67h
		mov	[cs:si+E_EMS], di
		clc
		jmp	short .r
.bad2:		call	.put
.bad:		mov	dx, di
		mov	ah, 45h
		int	67h
		mov	bl, 8Eh
		stc
.r:		mov	sp, bp
		pop	bp
		pop	es
		pop	ds
		pop	di
		pop	si
		pop	dx
		pop	cx
		pop	ax
		ret
.put:		push	si
		push	ss
		pop	ds
		lea	si, [bp-MAPMAX]
		mov	ax, 4E01h
		int	67h
		pop	si
		ret

; ---- 10h-12h: UMBs, served by whoever was here first
fumb:		cmp	word [cs:umbxms+2], 0
		je	.no
		jmp	far [cs:umbxms]
.no:		jmp	notimpl

; ======================================================== 0Bh: move
; DS:SI -> length dd, source handle dw, offset dd, destination handle dw,
; offset dd.  Handle 0 means the offset is a real-mode seg:off.
; Every register but AX (and BL on an error) comes back as it went in.

M_REML		equ	-2
M_REMH		equ	-4
M_SENT		equ	-6			; source entry, 0 = conventional
M_SLO		equ	-8			; its position: EMB offset, or linear
M_SHI		equ	-10
M_DENT		equ	-12
M_DLO		equ	-14
M_DHI		equ	-16
M_DIR		equ	-18			; byte: 1 = backwards
M_SAVED		equ	-17			; byte: page map saved on the stack
M_CHUNK		equ	-20
M_SW		equ	-22			; windows
M_DW		equ	-24
M_SSEG		equ	-26
M_SOFF		equ	-28
M_DSEG		equ	-30
M_DOFF		equ	-32
M_SPORT		equ	-34			; direct: ports borrowed, and what
M_SOLD		equ	-36			; they held
M_DPORT		equ	-38
M_DOLD		equ	-40
M_BOR		equ	-42			; byte: direct, and an EMB side
M_ALN		equ	-41			; byte: 0 align the source, 1 the
						; destination (the conventional one)
M_MAP		equ	-42-MAPMAX
M_LOCALS	equ	42+MAPMAX

move:		push	bx
		push	cx
		push	dx
		push	si
		push	di
		push	bp
		push	ds
		push	es
		cld
		mov	bp, sp
		test	byte [cs:flags], F_DIRECT
		jz	mgen
		jmp	fast

mgen:		mov	sp, bp			; the general engine
		sub	sp, M_LOCALS
		mov	byte [bp+M_SAVED], 0
		mov	ax, [si]
		mov	dx, [si+2]
		test	al, 1
		jz	.even
		jmp	.elen
.even:		mov	[bp+M_REML], ax
		mov	[bp+M_REMH], dx
		mov	bx, [si+4]
		mov	ax, [si+6]
		mov	dx, [si+8]
		call	side
		jnc	.s1
		cmp	al, 0A7h
		je	.f1
		add	al, 0A3h		; A3h handle, A4h offset
.f1:		jmp	.fail
.s1:		mov	[bp+M_SENT], bx
		mov	[bp+M_SLO], ax
		mov	[bp+M_SHI], dx
		mov	bx, [si+10]
		mov	ax, [si+12]
		mov	dx, [si+14]
		call	side
		jnc	.s2
		cmp	al, 0A7h
		je	.f2
		add	al, 0A5h		; A5h handle, A6h offset
.f2:		jmp	.fail
.s2:		mov	[bp+M_DENT], bx
		mov	[bp+M_DLO], ax
		mov	[bp+M_DHI], dx
		; nothing to move?
		mov	ax, [bp+M_REML]
		or	ax, [bp+M_REMH]
		jnz	.some
		jmp	.done
		; overlapping, destination above source: copy from the top
.some:		mov	byte [bp+M_DIR], 0
		mov	ax, [bp+M_SENT]
		cmp	ax, [bp+M_DENT]
		jne	.go
		mov	ax, [bp+M_DLO]
		mov	dx, [bp+M_DHI]
		sub	ax, [bp+M_SLO]
		sbb	dx, [bp+M_SHI]
		jb	.go
		mov	cx, ax
		or	cx, dx
		jnz	.ov
		jmp	.done			; onto itself
.ov:		cmp	dx, [bp+M_REMH]
		ja	.go
		jb	.back
		cmp	ax, [bp+M_REML]
		jae	.go
.back:		mov	byte [bp+M_DIR], 1
		mov	ax, [bp+M_REML]
		mov	dx, [bp+M_REMH]
		add	[bp+M_SLO], ax
		adc	[bp+M_SHI], dx
		add	[bp+M_DLO], ax
		adc	[bp+M_DHI], dx
.go:		mov	byte [bp+M_ALN], 1
		cmp	word [bp+M_SENT], 0
		jne	.g1
		mov	byte [bp+M_ALN], 0
.g1:		mov	byte [bp+M_BOR], 0
		mov	ax, [bp+M_SENT]
		or	ax, [bp+M_DENT]
		jz	.loop			; conventional to conventional
		test	byte [cs:flags], F_DIRECT
		jz	.gsave
		mov	byte [bp+M_BOR], 1
		jmp	short .loop
.gsave:		; EMS calls: keep the caller's page map
		push	ss
		pop	es
		lea	di, [bp+M_MAP]
		mov	ax, 4E00h
		int	67h
		test	ah, ah
		jz	.saved
		mov	al, 8Eh
		jmp	.fail
.saved:		mov	byte [bp+M_SAVED], 1

		; ------------------------------------------------ a slice
.loop:		mov	cx, 16384
		cmp	byte [bp+M_BOR], 0
		je	.lim
		mov	cx, [cs:ichunk]
.lim:		cmp	word [bp+M_REMH], 0
		jne	.l1
		cmp	cx, [bp+M_REML]
		jbe	.l1
		mov	cx, [bp+M_REML]
.l1:		cmp	word [bp+M_SENT], 0
		je	.l2
		mov	ax, [bp+M_SLO]
		call	room
		cmp	cx, ax
		jbe	.l2
		mov	cx, ax
.l2:		cmp	word [bp+M_DENT], 0
		je	.l3
		mov	ax, [bp+M_DLO]
		call	room
		cmp	cx, ax
		jbe	.l3
		mov	cx, ax
.l3:		mov	[bp+M_CHUNK], cx
		cmp	byte [bp+M_DIR], 0
		je	.win
		sub	[bp+M_SLO], cx
		sbb	word [bp+M_SHI], 0
		sub	[bp+M_DLO], cx
		sbb	word [bp+M_DHI], 0

		; windows: source 0 and destination 1, unless one side is
		; conventional memory inside the frame -- then one it misses
.win:		mov	word [bp+M_SW], 0
		mov	word [bp+M_DW], 1
		cmp	word [bp+M_SENT], 0
		je	.w1
		cmp	word [bp+M_DENT], 0
		jne	.map
		mov	ax, [bp+M_DLO]
		mov	dx, [bp+M_DHI]
		call	pickw
		mov	[bp+M_SW], bx
		jmp	short .map
.w1:		cmp	word [bp+M_DENT], 0
		je	.map
		mov	ax, [bp+M_SLO]
		mov	dx, [bp+M_SHI]
		call	pickw
		mov	[bp+M_DW], bx

		; map, and work out both addresses
.map:		cmp	byte [bp+M_BOR], 0
		je	.m0
		pushf				; direct: no interrupts while the
		cli				; windows are borrowed
.m0:		mov	bx, [bp+M_SENT]
		mov	ax, [bp+M_SLO]
		mov	dx, [bp+M_SHI]
		test	bx, bx
		jnz	.m1
		call	convptr
		mov	[bp+M_SSEG], dx
		mov	[bp+M_SOFF], ax
		jmp	short .m2
.m1:		mov	di, [bp+M_SW]
		call	mapwin
		jc	.emap
		mov	[bp+M_SSEG], dx
		mov	[bp+M_SOFF], ax
		mov	[bp+M_SPORT], cx
		mov	[bp+M_SOLD], si
.m2:		mov	bx, [bp+M_DENT]
		mov	ax, [bp+M_DLO]
		mov	dx, [bp+M_DHI]
		test	bx, bx
		jnz	.m3
		call	convptr
		mov	[bp+M_DSEG], dx
		mov	[bp+M_DOFF], ax
		jmp	short .cp
.m3:		mov	di, [bp+M_DW]
		call	mapwin
		jc	.emap
		mov	[bp+M_DSEG], dx
		mov	[bp+M_DOFF], ax
		mov	[bp+M_DPORT], cx
		mov	[bp+M_DOLD], si

.cp:		mov	cx, [bp+M_CHUNK]
		mov	es, [bp+M_DSEG]
		mov	di, [bp+M_DOFF]
		mov	si, [bp+M_SOFF]
		mov	ds, [bp+M_SSEG]
		call	copy

		; direct: give the windows back, then let interrupts in.  EMS
		; calls: put the caller's page map back after every slice too --
		; a later slice may read conventional memory through a window
		; this one borrowed
		cmp	byte [bp+M_BOR], 0
		jne	.dput
		mov	ax, [bp+M_REML]		; the last slice: .done does it
		sub	ax, [bp+M_CHUNK]
		or	ax, [bp+M_REMH]
		jz	.adv
		call	putmap
		jmp	short .adv
.dput:
		cmp	word [bp+M_DENT], 0
		je	.u1
		mov	dx, [bp+M_DPORT]
		mov	al, [bp+M_DOLD]
		out	dx, al
.u1:		cmp	word [bp+M_SENT], 0
		je	.u2
		mov	dx, [bp+M_SPORT]
		mov	al, [bp+M_SOLD]
		out	dx, al
.u2:		popf				; IF as the caller had it

.adv:		mov	cx, [bp+M_CHUNK]
		sub	[bp+M_REML], cx
		sbb	word [bp+M_REMH], 0
		cmp	byte [bp+M_DIR], 0
		jne	.next
		add	[bp+M_SLO], cx
		adc	word [bp+M_SHI], 0
		add	[bp+M_DLO], cx
		adc	word [bp+M_DHI], 0
.next:		mov	ax, [bp+M_REML]
		or	ax, [bp+M_REMH]
		jz	.done
		jmp	.loop

.done:		call	putmap
		mov	sp, bp
		pop	es
		pop	ds
		pop	bp
		pop	di
		pop	si
		pop	dx
		pop	cx
		pop	bx
		mov	ax, 1
		retf

.emap:		mov	al, 8Eh			; the EMS driver refused a map
		jmp	short .fail
.elen:		mov	al, 0A7h
.fail:		call	putmap
		mov	sp, bp
		pop	es
		pop	ds
		pop	bp
		pop	di
		pop	si
		pop	dx
		pop	cx
		pop	bx
		mov	bl, al
		xor	ax, ax
		retf

; ---- the fast path: PicoMEM direct, one side conventional memory clear of
; the page frame and the other a block, forwards -- what a RAM disk, a
; cache or a swapper does all day, so it is the shortest path there is:
; one window, the page and its offset kept as they go rather than worked
; out from 32 bits each slice, and a conventional pointer renormalised
; only every 32 KB.  Anything else -- errors, block to block, conventional
; to conventional, conventional memory touching the frame, EMS calls --
; goes to mgen, which starts again from scratch: nothing here changes
; DS:SI.
;
; Measured on the V30, 512-byte moves a second: 979 with this, 813 with
; the general engine alone, 805 for the EMS driver's own 57h.  A second
; fast path for block to block was tried and taken out: the card itself
; stops those at ~445 KB/s, the general engine reaches 432, and it cost
; ~900 bytes of conventional memory.

F_CSEG		equ	-2			; conventional address, offset 0-15
F_COFF		equ	-4			; on the way (renormalised at 32 KB)
F_REML		equ	-6			; bytes still to move
F_REMH		equ	-8
F_GP		equ	-10			; the block's current page, in gp[]
F_POFS		equ	-12			; offset in that page
F_DIR		equ	-13			; byte: 1 = block to conventional
F_OLD		equ	-14			; byte: what window 0 held
F_LOC		equ	14

fast:		sub	sp, F_LOC
		mov	ax, [si]		; the length: even, not 0
		mov	dx, [si+2]
		test	al, 1
		jnz	.gen
		mov	cx, ax
		or	cx, dx
		jz	.gen
		mov	[bp+F_REML], ax
		mov	[bp+F_REMH], dx
		mov	bx, [si+4]
		mov	ax, [si+10]
		test	bx, bx
		jz	.fc
		test	ax, ax
		jnz	.gen			; block to block
		mov	byte [bp+F_DIR], 1	; block to conventional
		mov	ax, [si+6]
		mov	dx, [si+8]
		les	di, [si+12]
		jmp	short .f1
.fc:		test	ax, ax
		jz	.gen			; conventional to conventional
		mov	byte [bp+F_DIR], 0	; conventional to block
		mov	bx, ax
		mov	ax, [si+12]
		mov	dx, [si+14]
		les	di, [si+6]
.f1:		; BX = the block, DX:AX = the offset in it, ES:DI = conventional
		cmp	bx, [cs:tabbeg]
		jb	.gen
		cmp	bx, [cs:tabend]
		jae	.gen
		mov	cx, bx
		sub	cx, [cs:tabbeg]
		test	cl, ESIZE - 1
		jnz	.gen
		cmp	byte [cs:bx+E_FLAG], 1
		je	.f2
.gen:		jmp	mgen
.f2:		push	ax			; offset + length within its size?
		push	dx
		add	ax, [bp+F_REML]
		adc	dx, [bp+F_REMH]
		jc	.gen			; (mgen resets SP)
		push	bx
		mov	cx, [cs:bx+E_KB]
		xor	bx, bx
		shl	cx, 1
		rcl	bx, 1
		shl	cx, 1
		rcl	bx, 1
		mov	bh, bl
		mov	bl, ch
		mov	ch, cl
		xor	cl, cl			; BX:CX = KB * 1024
		cmp	dx, bx
		jne	.f3
		cmp	ax, cx
.f3:		pop	bx
		pop	dx
		pop	ax
		ja	.gen
		mov	cx, ax			; offset in its page
		and	cx, 3FFFh
		mov	[bp+F_POFS], cx
		rol	ax, 1			; the page, and its gp[] slot
		rol	ax, 1
		and	ax, 3
		shl	dx, 1
		shl	dx, 1
		or	ax, dx
		add	ax, [cs:bx+E_BASE]
		add	ax, [cs:gpbase]
		mov	[bp+F_GP], ax
		mov	ax, di			; conventional: offset 0-15
		mov	cl, 4
		shr	ax, cl
		mov	dx, es
		add	ax, dx
		jc	.gen			; wraps at 1 MB
		and	di, 15
		mov	[bp+F_COFF], di
		mov	[bp+F_CSEG], ax
		mov	bx, di			; its end, in paragraphs:
		add	bx, 15			; AX + (offset + length + 15) / 16
		mov	dx, [bp+F_REMH]
		add	bx, [bp+F_REML]
		adc	dx, 0
		jnz	.big
		shr	bx, cl
		jmp	short .end
.big:		cmp	dx, 10h
		jae	.gen			; a megabyte or more
		shr	bx, cl
		mov	cl, 12
		shl	dx, cl
		or	bx, dx
.end:		add	bx, ax
		jc	.gen
		cmp	bx, [cs:frame]
		jbe	.sl			; ends below the frame
		cmp	ax, [cs:fend]
		jb	.gen			; starts before its end: touches it

.sl:		mov	cx, 4000h		; a slice: to the end of the page,
		sub	cx, [bp+F_POFS]		; the interrupt window, or the
		cmp	cx, [cs:ichunk]		; end of the move
		jbe	.s1
		mov	cx, [cs:ichunk]
.s1:		cmp	word [bp+F_REMH], 0
		jne	.s2
		cmp	cx, [bp+F_REML]
		jbe	.s2
		mov	cx, [bp+F_REML]
.s2:		mov	bx, cx
		mov	dx, [cs:emsport]	; window 0
		mov	si, [bp+F_GP]
		pushf
		cli
		in	al, dx
		mov	[bp+F_OLD], al
		mov	al, [cs:si]
		out	dx, al
		cmp	byte [bp+F_DIR], 0
		jne	.e2c
		lds	si, [bp+F_COFF]
		mov	es, [cs:frame]
		mov	di, [bp+F_POFS]
		test	si, 1
		jmp	short .cp
.e2c:		les	di, [bp+F_COFF]
		mov	ds, [cs:frame]
		mov	si, [bp+F_POFS]
		test	di, 1
.cp:		jz	.ev
		movsb				; the conventional side made even
		dec	cx
.ev:		test	byte [cs:flags], F_386
		jnz	.d32
		shr	cx, 1
		rep	movsw
		jnc	.cd
		movsb
		jmp	short .cd
.d32:		mov	ax, cx
		shr	cx, 1
		shr	cx, 1
		cpu	386
		rep	movsd
		cpu	8086
		mov	cx, ax
		and	cx, 3
		rep	movsb
.cd:		mov	al, [bp+F_OLD]		; window 0 back as it was, then
		out	dx, al			; interrupts as the caller had them
		popf
		sub	[bp+F_REML], bx
		sbb	word [bp+F_REMH], 0
		mov	ax, [bp+F_REML]
		or	ax, [bp+F_REMH]
		jz	.done
		mov	ax, [bp+F_COFF]		; on through conventional memory
		add	ax, bx
		cmp	ax, 8000h
		jb	.c1
		sub	ax, 8000h
		add	word [bp+F_CSEG], 800h
.c1:		mov	[bp+F_COFF], ax
		add	bx, [bp+F_POFS]		; and through the block
		cmp	bx, 4000h
		jb	.s3
		xor	bx, bx
		inc	word [bp+F_GP]
.s3:		mov	[bp+F_POFS], bx
		jmp	.sl
.done:		mov	sp, bp
		pop	es
		pop	ds
		pop	bp
		pop	di
		pop	si
		pop	dx
		pop	cx
		pop	bx
		mov	ax, 1
		retf

; put the caller's page map back, if we saved it.  AX kept
putmap:		cmp	byte [bp+M_SAVED], 0
		je	.r
		push	ax
		push	ss
		pop	ds
		lea	si, [bp+M_MAP]
		mov	ax, 4E01h
		int	67h
		pop	ax
.r:		ret

; check one side of a move.  BX = handle, DX:AX = offset (seg:off for
; handle 0), the length at [bp+M_REMH:M_REML].
; -> BX = entry (0 = conventional), DX:AX = position (linear address for
;    conventional memory).  CF and AL = 0 bad handle, 1 bad offset, A7h
;    bad length, on failure.
side:		test	bx, bx
		jnz	.emb
		push	cx			; linear = seg * 16 + off
		mov	bx, dx
		mov	cl, 12
		shr	bx, cl
		push	bx			; seg >> 12
		mov	bx, dx
		mov	cl, 4
		shl	bx, cl
		add	ax, bx
		pop	dx
		adc	dx, 0
		xor	bx, bx
		pop	cx
		clc
		ret
.emb:		call	valid
		jnc	.v
		mov	al, 0
		ret
.v:		push	cx
		push	si
		push	di
		mov	si, [cs:bx+E_KB]	; the size in bytes, SI:DI
		mov	di, si
		mov	cl, 10
		shl	di, cl
		mov	cl, 6
		shr	si, cl
		cmp	dx, si			; offset past the end?
		ja	.eoff
		jb	.o1
		cmp	ax, di
		ja	.eoff
.o1:		push	ax
		push	dx
		add	ax, [bp+M_REML]		; ...or offset + length?
		adc	dx, [bp+M_REMH]
		jc	.elen
		cmp	dx, si
		ja	.elen
		jb	.ok
		cmp	ax, di
		ja	.elen
.ok:		pop	dx
		pop	ax
		pop	di
		pop	si
		pop	cx
		clc
		ret
.elen:		pop	dx
		pop	ax
		mov	al, 0A7h
		jmp	short .e
.eoff:		mov	al, 1
.e:		pop	di
		pop	si
		pop	cx
		stc
		ret

; bytes from position AX to the end of its 16 KB page, in the direction
; of the move (backwards: from the page start up to AX)
room:		cmp	byte [bp+M_DIR], 0
		jne	.b
		and	ax, 3FFFh
		neg	ax
		add	ax, 4000h
		ret
.b:		dec	ax
		and	ax, 3FFFh
		inc	ax
		ret

; DX:AX = a conventional linear address, CX bytes from it -> BX = a frame
; window (0-3) the range does not touch.  A slice is at most 16 KB, so it
; touches at most two, and the first one free is 0, 1 or 2.
pickw:		push	ax
		push	dx
		xor	bx, bx
		sub	ax, [cs:flin]
		sbb	dx, [cs:flin+2]
		cmp	dx, 0FFFFh
		je	.below
		test	dx, dx
		jnz	.r			; beyond the frame, or far below it
		test	ah, 0C0h
		jnz	.r			; starts past window 0
		add	ax, cx
		dec	ax
		rol	ax, 1
		rol	ax, 1
		and	ax, 3			; the window its last byte is in
		inc	ax
		mov	bx, ax
		jmp	short .r
.below:		add	ax, cx			; ends inside window 0?
		jnc	.r
		jz	.r
		inc	bx
.r:		pop	dx
		pop	ax
		ret

; DX:AX = linear -> DX = segment, AX = offset (0-15).  CX kept
convptr:	push	cx
		push	bx
		mov	bx, ax
		and	bx, 15
		mov	cl, 4
		shr	ax, cl
		and	dx, 15			; wraps at 1 MB, as an 8086 does
		ror	dx, cl
		or	dx, ax
		mov	ax, bx
		pop	bx
		pop	cx
		ret

; map position DX:AX of entry BX into window DI.
; -> DX = segment, AX = offset of it in the frame.  Direct mode also
;    returns CX = the port and SI = what it held.  CF if EMS refused.
mapwin:		push	bx
		push	ax
		rol	ax, 1			; page = offset >> 14
		rol	ax, 1
		and	ax, 3
		shl	dx, 1
		shl	dx, 1
		or	ax, dx
		test	byte [cs:flags], F_DIRECT
		jz	.ems
		add	ax, [cs:bx+E_BASE]
		add	ax, [cs:gpbase]
		mov	bx, ax
		mov	dx, [cs:emsport]
		add	dx, di
		in	al, dx
		xor	ah, ah
		mov	si, ax			; what it held
		mov	al, [cs:bx]
		out	dx, al
		mov	cx, dx
		jmp	short .seg
.ems:		push	dx
		mov	dx, [cs:bx+E_EMS]
		mov	bx, ax
		mov	ax, di
		mov	ah, 44h
		int	67h
		pop	dx
		test	ah, ah
		jz	.seg
		pop	ax
		pop	bx
		stc
		ret
.seg:		mov	dx, di			; frame + window * 400h
		xchg	dl, dh
		shl	dx, 1
		shl	dx, 1
		add	dx, [cs:frame]
		pop	ax
		and	ax, 3FFFh
		pop	bx
		clc
		ret

; copy CX bytes (not 0) from DS:SI to ES:DI; backwards if the move is.
; A slice can be odd -- an odd offset meets a 16 KB page boundary -- so
; any count is taken.  Forwards, the CONVENTIONAL side is made even first:
; measured on the V30, a misaligned word costs 16% there and nothing on
; the card, whose bus is 8 bits wide anyway.  On a 386, doublewords when
; both sides are even.
copy:		cmp	byte [bp+M_DIR], 0
		jne	.back
		mov	ax, si			; the conventional side's address
		cmp	byte [bp+M_ALN], 0
		je	.a
		mov	ax, di
.a:		test	al, 1
		jz	.al
		movsb				; one byte makes it even
		dec	cx
		jz	.r
.al:		mov	ax, cx
		test	byte [cs:flags], F_386
		jz	.w
		test	si, 1
		jnz	.w
		test	di, 1
		jnz	.w
		shr	cx, 1
		shr	cx, 1
		cpu	386
		rep	movsd
		cpu	8086
		mov	cx, ax
		and	cx, 3
		rep	movsb
.r:		ret
.w:		shr	cx, 1
		rep	movsw
		test	al, 1
		jz	.r
		movsb
		ret
.back:		std
		add	si, cx
		add	di, cx
		dec	si			; the last byte
		dec	di
		test	cl, 1
		jz	.bw
		movsb
		dec	cx
.bw:		dec	si			; the last word
		dec	di
		shr	cx, 1
		rep	movsw
		cld
		ret

; ======================================================== XMS 3.0, 386
		cpu	386
; ---- 88h: EAX = largest free KB, EDX = total, ECX = highest address
f88:		call	emsfree
		movzx	eax, ax
		mov	edx, eax
		xor	ecx, ecx		; no memory has an address here
		mov	bl, 0
		test	eax, eax
		jnz	.r
		mov	bl, 0A0h
.r:		retf

; ---- 89h: allocate EDX KB
f89:		test	edx, 0FFFF0000h
		jz	.s
		mov	bl, 0A0h
		xor	ax, ax
		retf
.s:		jmp	f09

; ---- 8Eh: BH = locks, CX = free handles, EDX = size KB
f8E:		push	bx
		mov	bx, dx
		call	valid
		pop	bx
		jnc	.ok
		mov	bl, 0A2h
		xor	ax, ax
		retf
.ok:		call	nfree
		mov	cx, ax
		mov	bh, 0
		push	si
		mov	si, dx
		movzx	edx, word [cs:si+E_KB]
		pop	si
		mov	ax, 1
		retf

; ---- 8Fh: reallocate DX to EBX KB
f8F:		test	ebx, 0FFFF0000h
		jz	.s
		mov	bl, 0A0h
		xor	ax, ax
		retf
.s:		jmp	f0F
		cpu	8086

restab:		times	GPSIZE + MAXH * ESIZE db 0	; gp[], then handles
resend:

; ======================================================== initialisation
		section	init follows=blob

; everything worked out before anything is installed
i_handles	dw	DEFH
i_chunk		dw	4096
i_flags		db	F_V3
i_cpu		db	0FFh			; /C:n forces it
i_nec		db	0			; a NEC V20/V30, for the report
i_generic	db	0
i_quiet		db	0
i_unload	db	0
i_port		dw	0
i_frame		dw	0
i_umb		dd	0
i_mapsz		dw	0
i_emsver	db	0

%ifndef COM
sys_init:	push	ax
		push	cx
		push	dx
		push	si
		push	di
		push	bp
		push	ds
		mov	byte [cs:inited], 1
		push	cs
		pop	ds
		lds	si, [es:bx+18]		; the command line: skip the name
.nm:		lodsb
		cmp	al, ' '
		ja	.nm
		dec	si
		call	parse
		push	cs
		pop	ds
		call	setup
		jc	.fail
		call	install
		les	bx, [reqptr]
		mov	[es:bx+14], ax		; break address
		mov	[es:bx+16], cs
		jmp	short .r
.fail:		les	bx, [reqptr]
		mov	word [es:bx+14], 0	; keep nothing: a "block device"
		mov	[es:bx+16], cs		; with no units, which DOS
		and	word [cs:4], 7FFFh	; discards without a message
		mov	byte [es:bx+13], 0
.r:		mov	word [es:bx+3], 0100h
		pop	ds
		pop	bp
		pop	di
		pop	si
		pop	dx
		pop	cx
		pop	ax
		pop	es
		pop	bx
		retf
%else
com_start:	mov	si, 81h
		call	parse
		cmp	byte [i_unload], 0
		je	.ld
		jmp	unload
.ld:		call	setup
		jnc	.ok
		mov	ax, 4C01h
		int	21h
.ok:		; the resident part down into the PSP, then the rest.  ES is
		; whatever setup's last vector lookup left (the EMS driver's
		; segment): it must be ours before REP MOVSB writes through it
		push	cs
		pop	es
		mov	si, section.blob.start
		mov	di, RESORG
		mov	cx, resend - RESORG
		cld
		rep	movsb
		call	install			; AX = end of the resident part
		push	ax
		mov	es, [2Ch]		; no environment
		mov	ah, 49h
		int	21h
		mov	word [2Ch], 0
		pop	dx
		add	dx, 15
		mov	cl, 4
		shr	dx, cl
		mov	ax, 3100h
		int	21h
%endif

; ---- the command line at DS:SI, ending in CR, LF or 0
parse:		cld
.l:		lodsb
		cmp	al, CR
		je	.r
		cmp	al, LF
		je	.r
		test	al, al
		je	.r
		cmp	al, '/'
		je	.sw
		cmp	al, '-'
		jne	.l
.sw:		lodsb
		and	al, 0DFh		; upper case
		cmp	al, 'V'
		jne	.h
		call	num
		cmp	ax, 2
		jne	.v3
		and	byte [cs:i_flags], ~F_V3
		jmp	.l
.v3:		or	byte [cs:i_flags], F_V3
		jmp	.l
.h:		cmp	al, 'H'
		jne	.i
		call	num
		cmp	ax, 1
		jb	.l
		cmp	ax, MAXH
		jbe	.h1
		mov	ax, MAXH
.h1:		mov	[cs:i_handles], ax
		jmp	.l
.i:		cmp	al, 'I'
		jne	.g
		call	num
		cmp	ax, 1
		jb	.l
		cmp	ax, 8			; 8 KB between the two windows is 18 ms
		jbe	.i1			; on the V30; past ~27 ms (half a tick)
		mov	ax, 8			; interrupts off loses BIOS ticks there
.i1:		mov	cl, 10
		shl	ax, cl			; KB -> bytes
		mov	[cs:i_chunk], ax
		jmp	.l
.g:		cmp	al, 'G'
		jne	.q
		mov	byte [cs:i_generic], 1
		jmp	.l
.q:		cmp	al, 'Q'
		jne	.c
		mov	byte [cs:i_quiet], 1
		jmp	.l
.c:		cmp	al, 'C'
		jne	.u
		call	num
		cmp	ax, 3
		ja	.l
		mov	[cs:i_cpu], al
		jmp	.l
.u:		cmp	al, 'U'
		jne	.hl
		mov	byte [cs:i_unload], 1
		jmp	.l
.hl:		cmp	al, '?'
		jne	.l
		push	cs
		pop	ds
		mov	dx, sHelp
		call	say
%ifdef COM
		mov	ax, 4C00h
		int	21h
%else
		mov	byte [cs:i_quiet], 0
		mov	byte [cs:i_unload], 2	; load nothing
%endif
.r:		ret

; a decimal number after an optional ':' or '=' -> AX
num:		xor	ax, ax
		cmp	byte [si], ':'
		je	.sk
		cmp	byte [si], '='
		jne	.l
.sk:		inc	si
.l:		mov	bl, [si]
		sub	bl, '0'
		cmp	bl, 9
		ja	.r
		inc	si
		mov	bh, 0
		push	dx
		mov	dx, 10
		mul	dx
		pop	dx
		add	ax, bx
		jmp	.l
.r:		ret

; ---- find out what we are running on.  DS = CS.  CF on a refusal
setup:		cmp	byte [i_unload], 2
		jne	.go
		stc
		ret
.go:		mov	dx, sBanner
		call	sayq
		; already here?  or another XMS driver?
		mov	ax, 4300h
		int	2Fh
		cmp	al, 80h
		jne	.noxms
		mov	ax, 4310h
		int	2Fh
		cmp	word [es:bx-8], 'XM'
		jne	.other
		cmp	word [es:bx-6], 'SS'
		jne	.other
		mov	dx, sAgain
		jmp	.refuse
.other:		mov	[i_umb], bx
		mov	[i_umb+2], es
		xor	ax, ax
		call	far [i_umb]		; its version
		cmp	ax, 0200h
		jb	.umbonly
		mov	ah, 08h			; a real one hands out memory
		call	far [i_umb]
		test	ax, ax
		jnz	.real
		cmp	bl, 80h
		je	.umbonly
.real:		mov	dx, sXms
		jmp	.refuse
.umbonly:	mov	dx, sUmb
		call	sayq
		jmp	short .ems
.noxms:		mov	word [i_umb], 0
		mov	word [i_umb+2], 0

		; an EMS driver
.ems:		mov	ax, 3567h
		int	21h
		mov	di, 0Ah
		mov	si, sEmmName
		mov	cx, 8
		repe	cmpsb
		je	.e1
		mov	dx, sNoEms
		jmp	.refuse
.e1:		mov	ah, 40h
		int	67h
		test	ah, ah
		jz	.e2
		mov	dx, sEmsBad
		jmp	.refuse
.e2:		mov	ah, 46h
		int	67h
		test	ah, ah
		jnz	.e2b
		mov	[i_emsver], al
		cmp	al, 32h
		jae	.e3
.e2b:		mov	dx, sEmsOld
		jmp	.refuse
.e3:		cmp	al, 40h
		jb	.e4
		or	byte [i_flags], F_EMS4
.e4:		mov	ah, 41h
		int	67h
		test	ah, ah
		jnz	.e2b
		mov	[i_frame], bx
		mov	ax, 4E03h
		int	67h
		test	ah, ah
		jnz	.e2b
		xor	ah, ah
		mov	[i_mapsz], ax
		cmp	ax, MAPMAX
		jbe	.cpu
		mov	dx, sMapBig
		jmp	.refuse

.cpu:		call	cpuid
		cmp	byte [i_cpu], 3
		jb	.pm
		or	byte [i_flags], F_386

		; a PicoMEM whose page registers read back?
.pm:		cmp	byte [i_generic], 0
		jne	.done
		call	picomem
.done:		clc
		ret
.refuse:	call	say			; always shown
		mov	dx, sNotLoaded
		call	say
		stc
		ret

; ---- which CPU (unless /C:n said).  0 8086/88, 1 186/V20/V30, 2 286, 3 386+
cpuid:		cmp	byte [i_cpu], 0FFh
		jne	.r
		pushf
		pushf
		pop	ax
		and	ax, 0FFFh		; bits 12-15 clear: stuck at 1 on
		push	ax			; an 8086 or 186
		popf
		pushf
		pop	ax
		and	ax, 0F000h
		cmp	ax, 0F000h
		je	.lt286
		mov	ax, 7000h		; a 386 lets bits 12-14 be set
		push	ax
		popf
		pushf
		pop	ax
		mov	bl, 2
		test	ax, 7000h
		jz	.st
		mov	bl, 3
		jmp	short .st
.lt286:		mov	ax, 0FFFFh		; a 186 masks shift counts to 5
		mov	cl, 33			; bits; an 8086 shifts all 33
		shr	ax, cl
		mov	bl, 1
		jnz	.st
		mov	ax, 0101h		; so does a NEC V20/V30 -- but its
		db	0D5h, 10h		; AAD always works in base 10:
		mov	bl, 0			; AAD 16 gives 11h on an 8086, 0Bh
		cmp	al, 0Bh			; on a V20/V30
		jne	.st
		mov	bl, 1			; the 186 instruction set
		mov	byte [i_nec], 1
.st:		popf
		mov	[i_cpu], bl
.r:		ret

; ---- the PicoMEM check.  Sets i_port and F_DIRECT if the page
; registers read back and an OUT of a read-back number maps that page.
picomem:	push	es
		test	byte [i_flags], F_EMS4
		jz	.no
		mov	ax, 6000h
		mov	dx, 1234h
		pushf				; its BIOS returns with interrupts
		int	13h			; off: keep ours
		popf
		cmp	dx, 0AA55h
		jne	.no
		mov	ax, 6001h
		mov	dx, 1234h
		pushf
		int	13h
		popf
		test	cx, cx
		jz	.no
		cmp	dx, [i_frame]
		jne	.no
		mov	[i_port], cx
		; one page of our own: map it through EMS, read the register,
		; and see the same memory through window 1 by OUT alone
		mov	ah, 43h
		mov	bx, 1
		int	67h
		test	ah, ah
		jnz	.no
		mov	bp, dx			; its EMS handle
		mov	dx, [i_port]		; the registers as they are
		in	al, dx
		mov	ah, al
		inc	dx
		in	al, dx
		push	ax			; windows 0 and 1
		inc	dx
		in	al, dx
		mov	ah, al
		inc	dx
		in	al, dx
		push	ax			; windows 2 and 3
		sub	sp, MAPMAX
		mov	di, sp
		push	ss
		pop	es
		mov	ax, 4E00h
		int	67h
		test	ah, ah
		jnz	.free
		mov	ax, 4400h
		xor	bx, bx
		mov	dx, bp
		int	67h
		test	ah, ah
		jnz	.put
		mov	dx, [i_port]
		in	al, dx			; the page, as the card numbers it
		mov	bl, al
		mov	es, [i_frame]
		mov	word [es:0], 0A55Ah
		mov	word [es:3FFEh], 1234h
		inc	dx
		pushf
		cli
		in	al, dx
		mov	bh, al			; window 1 as it was
		mov	al, bl
		out	dx, al
		in	al, dx
		cmp	al, bl			; reads back?
		jne	.bad
		cmp	word [es:4000h], 0A55Ah	; the same memory?
		jne	.bad
		cmp	word [es:7FFEh], 1234h
		jne	.bad
		mov	word [es:4002h], 5AA5h	; and both ways
		cmp	word [es:0002h], 5AA5h
		jne	.bad
		or	byte [i_flags], F_DIRECT
.bad:		mov	al, bh
		out	dx, al
		popf
.put:		push	ds
		push	ss
		pop	ds
		mov	si, sp
		add	si, 2
		mov	ax, 4E01h
		int	67h
		pop	ds
.free:		add	sp, MAPMAX
		mov	dx, [i_port]		; put the registers back as read
		add	dx, 3
		pop	ax
		out	dx, al
		dec	dx
		mov	al, ah
		out	dx, al
		dec	dx
		pop	ax
		out	dx, al
		dec	dx
		mov	al, ah
		out	dx, al
		mov	dx, bp
		mov	ah, 45h
		int	67h
		test	byte [i_flags], F_DIRECT
		jnz	.r
		mov	dx, sPmSlow
		call	sayq
.no:
.r:		pop	es
		ret

; ---- set the resident part up and hook INT 2Fh.  DS = CS.
; -> AX = the offset just past what stays resident
install:	mov	al, [i_flags]
		mov	[flags], al
		mov	al, [i_cpu]
		mov	[cpucls], al
		mov	ax, 0300h
		test	byte [flags], F_V3
		jnz	.v
		mov	ax, 0200h
.v:		mov	[xver], ax
		mov	ax, [i_port]
		mov	[emsport], ax
		mov	ax, [i_frame]
		mov	[frame], ax
		add	ax, 1000h
		jnc	.fe
		mov	ax, 0FFFFh
.fe:		mov	[fend], ax
		mov	ax, [i_frame]
		mov	dx, ax			; linear address of the frame
		mov	cl, 4
		shl	ax, cl
		mov	cl, 12
		shr	dx, cl
		mov	[flin], ax
		mov	[flin+2], dx
		mov	ax, [i_chunk]
		mov	[ichunk], ax
		mov	ax, [i_umb]
		mov	[umbxms], ax
		mov	ax, [i_umb+2]
		mov	[umbxms+2], ax
		; tables: gp[] (direct only), then the handles, all zero
		mov	ax, restab
		mov	[gpbase], ax
		mov	word [gpused], 0
		test	byte [flags], F_DIRECT
		jz	.t
		add	ax, GPSIZE
.t:		mov	[tabbeg], ax
		mov	cx, [i_handles]
		shl	cx, 1
		shl	cx, 1
		shl	cx, 1
		add	ax, cx
		mov	[tabend], ax
		push	ax
		; hook INT 2Fh
		mov	ax, 352Fh
		int	21h
		mov	[old2f], bx
		mov	[old2f+2], es
		mov	dx, int2f
		mov	ax, 252Fh
		int	21h
		; say what we did
		cmp	byte [i_quiet], 0
		jne	.q
		call	report
.q:		pop	ax
		ret

report:		mov	dx, sDirect
		test	byte [flags], F_DIRECT
		jnz	.m
		mov	dx, sEmsMode
.m:		call	say
		test	byte [flags], F_DIRECT
		jz	.f
		mov	ax, [i_port]
		call	hex3
		mov	dx, sPort2
		call	say
.f:		mov	dx, sPf
		call	say
		mov	ax, [i_frame]
		call	hex4
		mov	dx, sFrame2
		call	say
		mov	al, [i_emsver]
		mov	cl, 4
		mov	ah, al
		shr	ah, cl
		add	ah, '0'
		and	al, 15
		add	al, '0'
		mov	[sVer+0], ah
		mov	[sVer+2], al
		mov	dx, sVer
		call	say
		call	emsfree
		call	pdec
		mov	dx, sKb
		call	say
		mov	ax, [i_handles]
		call	pdec
		mov	dx, sHandles
		call	say
		mov	bl, [cpucls]
		xor	bh, bh
		shl	bx, 1
		mov	dx, [cpus+bx]
		cmp	byte [i_nec], 0
		je	.c
		mov	dx, sNec
.c:
		call	say
		mov	dx, sX3
		test	byte [flags], F_V3
		jnz	.x
		mov	dx, sX2
.x:		call	say
		ret

%ifdef COM
; ---- /U: take the resident copy out, if nothing depends on it
unload:		mov	ax, 4300h
		int	2Fh
		cmp	al, 80h
		jne	.none
		mov	ax, 4310h
		int	2Fh
		cmp	word [es:bx-8], 'XM'
		jne	.none
		cmp	word [es:bx-6], 'SS'
		jne	.none
		; ES = its segment.  The same build as this one?  Everything
		; below reads its variables at THIS build's offsets
		push	si
		push	di
		mov	si, section.blob.start + (xms - blob0)
		mov	di, xms
		mov	cx, restab - xms
		cld
		repe	cmpsb
		pop	di
		pop	si
		jne	.other
		; still the owner of INT 2Fh?
		push	es
		mov	ax, 352Fh
		int	21h
		pop	ax
		mov	cx, es
		cmp	cx, ax
		jne	.hooked
		cmp	bx, int2f
		jne	.hooked
		mov	es, ax
		mov	si, [es:tabbeg]		; any blocks still allocated?
.l:		cmp	si, [es:tabend]
		jae	.free
		cmp	byte [es:si+E_FLAG], 0
		jne	.busy
		add	si, ESIZE
		jmp	.l
.free:		push	ds
		lds	dx, [es:old2f]
		mov	ax, 252Fh
		int	21h
		pop	ds
		mov	ah, 49h			; ES = its PSP
		int	21h
		mov	dx, sGone
		call	say
		mov	ax, 4C00h
		int	21h
.none:		mov	dx, sNotHere
		jmp	short .x
.other:		mov	dx, sOtherBuild
		jmp	short .x
.hooked:	mov	dx, sHooked
		jmp	short .x
.busy:		mov	dx, sBusy
.x:		call	say
		mov	ax, 4C01h
		int	21h
%endif

; ---- printing
sayq:		cmp	byte [i_quiet], 0
		jne	say.r
say:		push	ax
		push	ds
		push	cs
		pop	ds
		mov	ah, 9
		int	21h
		pop	ds
		pop	ax
.r:		ret

pdec:		push	ax
		push	bx
		push	cx
		push	dx
		mov	bx, 10
		xor	cx, cx
.d:		xor	dx, dx
		div	bx
		push	dx
		inc	cx
		test	ax, ax
		jnz	.d
.p:		pop	dx
		add	dl, '0'
		mov	ah, 2
		int	21h
		loop	.p
		pop	dx
		pop	cx
		pop	bx
		pop	ax
		ret

hex4:		push	ax
		mov	al, ah
		call	hex2
		pop	ax
hex2:		push	ax
		mov	cl, 4
		shr	al, cl
		call	hex1
		pop	ax
hex1:		push	ax
		push	dx
		and	al, 15
		add	al, '0'
		cmp	al, '9'
		jbe	.p
		add	al, 7
.p:		mov	dl, al
		mov	ah, 2
		int	21h
		pop	dx
		pop	ax
		ret
hex3:		push	ax
		mov	al, ah
		call	hex1
		pop	ax
		jmp	hex2

sEmmName	db	'EMMXXXX0'
sBanner		db	'XMSSC 1.0 -- XMS on expanded memory -- StevenC & Claude', CR, LF, '$'
sAgain		db	'XMSSC is already loaded.', CR, LF, '$'
sXms		db	'Another XMS driver is already loaded.', CR, LF, '$'
sUmb		db	'  UMB calls go on to the UMB server already loaded.', CR, LF, '$'
sNoEms		db	'No EMS driver: XMSSC needs one, loaded before it.', CR, LF, '$'
sEmsBad		db	'The EMS driver reports a fault.', CR, LF, '$'
sEmsOld		db	'The EMS driver is older than EMS 3.2.', CR, LF, '$'
sMapBig		db	'The EMS page map is too big for XMSSC to save.', CR, LF, '$'
sNotLoaded	db	'XMSSC not loaded.', CR, LF, '$'
sPmSlow		db	'  PicoMEM found, but its page registers do not read back:', CR, LF
		db	'  using EMS calls instead.', CR, LF, '$'
sDirect		db	'  PicoMEM direct: port $'
sPort2		db	'h, $'
sEmsMode	db	'  Through EMS calls: $'
sPf		db	'page frame $'
sFrame2		db	'h, EMS $'
sVer		db	'x.x', CR, LF, '  $'
sKb		db	' KB free, $'
sHandles	db	' handles, $'
cpus		dw	s86, s186, s286, s386
s86		db	'8086$'
s186		db	'80186$'
sNec		db	'NEC V20/V30$'
s286		db	'80286$'
s386		db	'386 or later$'
sX3		db	', XMS 3.00', CR, LF, '$'
sX2		db	', XMS 2.00', CR, LF, '$'
%ifdef COM
sGone		db	'XMSSC unloaded.', CR, LF, '$'
sNotHere	db	'XMSSC is not loaded.', CR, LF, '$'
sOtherBuild	db	'XMSSC cannot unload: a different build is loaded -- unload it with its own XMSSC.COM.', CR, LF, '$'
sHooked		db	'XMSSC cannot unload: something hooked INT 2Fh after it.', CR, LF, '$'
sBusy		db	'XMSSC cannot unload: blocks are still allocated.', CR, LF, '$'
%endif
sHelp		db	'XMSSC 1.0 -- XMS 3.0 on expanded memory, for PCs with no extended memory.', CR, LF
		db	'By StevenC & Claude.  Public domain.', CR, LF, CR, LF
%ifdef COM
		db	'  XMSSC [/V:2] [/H:n] [/I:n] [/G] [/Q]      load it (after the EMS driver)', CR, LF
		db	'  XMSSC /U                                  unload it', CR, LF, CR, LF
%else
		db	'  DEVICE=XMSSC.SYS [/V:2] [/H:n] [/I:n] [/G] [/Q]   after the EMS driver', CR, LF, CR, LF
%endif
		db	'  /V:2   report XMS 2.00 instead of 3.00', CR, LF
		db	'  /H:n   n handles (1-128, default 32)', CR, LF
		db	'  /I:n   PicoMEM: let interrupts in every n KB of a move (1-8, default 4)', CR, LF
		db	'  /G     use EMS calls even on a PicoMEM', CR, LF
		db	'  /Q     say nothing when loading', CR, LF
		db	'  /C:n   treat the CPU as 0 8086, 1 186/V30, 2 286, 3 386 (for testing)', CR, LF
		db	'$'
