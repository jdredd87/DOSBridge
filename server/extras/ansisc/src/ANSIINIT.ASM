PAGE	,132
TITLE	ANSI Console device CON$INIT routine

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;
;  MODULE_NAME: CON$INIT
;
;  FUNCTION:
;    THIS PROCEDURE PERFORMS ALL NECESSARY INITIALIZATION ROUTINES
;  FOR ANSI.SYS.
;
;  THIS ROUTINE WAS SPLIT FROM THE ORIGINAL ANSI.ASM SOURCE FILE
;  FOR RELEASE 4.00 OF DOS.  ALL CHANGED LINES HAVE BEEN MARKED WITH
;  WGR. NEW PROCS HAVE BEEN MARKED AS SUCH.
;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;AN001; P1767 VIDEO_MODE_TABLE not initialized correctly	   10/16/87 J.K.
;AN002; P2617 Order dependecy problem with Display.sys		   11/23/87 J.K.
;AN003; D479  An option to disable the extended keyboard functions 02/12/88 J.K.
;AN004; D493 New INIT request structure for error message	   02/25/88 J.K.
;-------------------------------------------------------------------------------

INCLUDE    ANSI.INC		   ; WGR equates and strucs				 ;AN000;
.XLIST
INCLUDE    STRUC.INC		   ; WGR structured macros				 ;AN000;
.LIST

PUBLIC	   CON$INIT		   ; WGR						 ;AN000;


CODE	SEGMENT  PUBLIC  BYTE
	ASSUME	CS:CODE,DS:CODE

EXTRN	VIDEO_MODE_TABLE:BYTE	       ; WGR						 ;AN000;
EXTRN	FUNC_INFO:BYTE		       ; WGR						 ;AN000;
EXTRN	HDWR_FLAG:WORD		       ; WGR						 ;AN000;
EXTRN	VIDEO_TABLE_MAX:ABS	       ; WGR						 ;AN000;
EXTRN	SCAN_LINES:BYTE 	       ; WGR						 ;AN000;
EXTRN	PTRSAV:DWORD		       ; WGR						 ;AN000;
EXTRN	PARSE_PARM:NEAR 	       ; WGR						 ;AN000;
EXTRN	ERR2:NEAR		       ; WGR						 ;AN000;
EXTRN	EXT_16:BYTE		       ; WGR						 ;AN000;
EXTRN	BRKADR:ABS		       ; WGR						 ;AN000;
EXTRN	BRKKY:NEAR		       ; WGR						 ;AN000;
EXTRN	COUT:NEAR		       ; WGR						 ;AN000;
EXTRN	BASE:WORD		       ; WGR						 ;AN000;
EXTRN	MODE:BYTE		       ; WGR						 ;AN000;
EXTRN	MAXCOL:BYTE		       ; WGR						 ;AN000;
EXTRN	TRANS:ABS		       ; WGR						 ;AN000;
EXTRN	STATUS:ABS		       ; WGR						 ;AN000;
EXTRN	EXIT:NEAR		       ; WGR						 ;AN000;
EXTRN	MAX_SCANS:BYTE		       ; WGR						 ;AN000;
EXTRN	ROM_INT10:WORD		       ; WGR						 ;AN000;
EXTRN	INT10_COM:NEAR		       ; WGR						 ;AN000;
EXTRN	ROM_INT2F:WORD		       ; WGR						 ;AN000;
EXTRN	INT2F_COM:NEAR		       ; WGR						 ;AN000;
EXTRN	ABORT:BYTE		       ; WGR						 ;AN000;
extrn	Display_Loaded_Before_me:byte  ;AN002;Defined in IOCTL.ASM
extrn	Switch_K:Byte		       ;AN003;
extrn	Switch_S:Byte, Idle_OK:Byte, Fast_HW:Byte
extrn	OUTC_PRO:NEAR, OUTC_EPI:NEAR

INCLUDE   ANSIVID.INC		       ; WGR video tables data				 ;AN000;

CON$INIT:
	LDS	BX,CS:[PTRSAV]	       ; WGR establish addressability to request header  ;AC000;
	LDS	SI,[BX].ARG_PTR        ; WGR DS:SI now points to rest of DEVICE=statement;AN000;
	CALL	PARSE_PARM	       ; WGR parse DEVICE= command line 		 ;AN000;
	JNC	CONT_INIT	       ; WGR no error in parse...continue install	 ;AN000;
	LDS	BX,CS:[PTRSAV]	       ; WGR prepare to abort install			 ;AC000;
	XOR	AX,AX		       ; WGR						 ;AC000;
	MOV	[BX].NUM_UNITS,AL      ; WGR set number of units to zero		 ;AC000;
	MOV	[BX].END_ADDRESS_O,AX  ; WGR set ending address offset to 0		 ;AC000;
	MOV	[BX].END_ADDRESS_S,CS  ; WGR set ending address segment to CS		 ;AC000;
	mov	word ptr [bx].CONFIG_ERRMSG, -1 ;AN004; Let IBMBIO display "Error in CONFIG.SYS..".
	MOV	AX,UNKNOWN_CMD	       ; WGR set error in status			 ;AC000;
	MOV	WORD PTR [BX].STATUS,AX ; WGR set error status				 ;AC000;
	JMP	ERR2		       ; WGR prepare to exit				 ;AN000;

CONT_INIT:			       ; WGR						 ;AN000;
	PUSH	CS		       ; WGR						 ;AN000;
	POP	DS		       ; WGR restore DS to ANSI segment 		 ;AN000;
	MOV	AX,ROM_BIOS	       ; WGR						 ;AN000;
	MOV	ES,AX		       ; WGR DS now points to BIOS data area		 ;AN000;
	CMP	Switch_S,OFF	       ; 6.22: /S or /SCREENSIZE -- the BIOS data area
	JE	NO_SWS		       ; says 25 rows, for BIOSes that leave it 0
	MOV	BYTE PTR ES:[NUM_ROWS],24
NO_SWS:
	MOV	AH,ES:[KBD_FLAG_3]     ; WGR load AH with KBD_FLAG_3			 ;AN000;
	.IF  <BIT AH AND EXT16_FLAG> AND   ; WGR see if extended INT16 is loaded	       ;AN000;
	.IF  <Switch_K EQ OFF>	       ;The user does not want to disable the extended INT 16h ;AN003;
	  MOV	  EXT_16,ON	       ; WGR extended INT16 available, set flag 	 ;AN000;
	.ENDIF			       ; WGR						 ;AN000;
	CALL	DET_HDWR	       ; WGR procedure to determine video hardware status;AN000;
				       ; 6.22: no alternate print screen here -- the
				       ; set IOCTL selects it when rows go past 25
	CALL	LOAD_INT10	       ; WGR load interrupt 10h handler 		 ;AN000;
	CALL	LOAD_INT2F	       ; WGR load interrupt 2Fh handler 		 ;AN000;
	PUSH	DS		       ; 6.22: does the BIOS take INT 15h AH=41h?
	POP	ES		       ; Then CON's "nothing waiting" tells it we
	XOR	DI,DI		       ; are idle.
	MOV	AX,4101H
	MOV	BL,1
	MOV	BH,ES:[DI]
	STC
	INT	15H
	JB	NO_IDLE
	MOV	Idle_OK,1
NO_IDLE:
	TEST	HDWR_FLAG,MCGA_ACTIVE+E5151_ACTIVE+E5153_ACTIVE+E5154_ACTIVE+VGA_ACTIVE
	JZ	NO_FAST		       ; SC: text can be written straight to
	MOV	Fast_HW,1	       ; video memory -- a CGA would snow
NO_FAST:
	CALL	CPU_PATCH	       ; SC: PUSHA/POPA on a 186 or V20/V30
	int	11h
	and	al,00110000b
	cmp	al,00110000b
	jnz	iscolor
	mov	[base],0b000h		;look for bw card
iscolor:
	cmp	al,00010000b		;look for 40 col mode
	ja	setbrk
	mov	[mode],0
	mov	[maxcol],39

setbrk:
	XOR	BX,BX
	MOV	DS,BX
	MOV	BX,BRKADR
	MOV	WORD PTR [BX],OFFSET BRKKY
	MOV	WORD PTR [BX+2],CS

	MOV	BX,29H*4
	MOV	WORD PTR [BX],OFFSET COUT
	MOV	WORD PTR [BX+2],CS

	LDS	BX,CS:[PTRSAV]
	MOV	WORD PTR [BX].TRANS,OFFSET CON$INIT	;SET BREAK ADDRESS
	MOV	[BX].TRANS+2,CS
	JMP	EXIT


;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;
;  PROCEDURE_NAME: DET_HDWR
;
;  FUNCTION:
;  THIS CODE DETERMINES WHAT VIDEO HARDWARE IS AVAILABLE.  THIS INFORMATION
;  IS USED TO LOAD APPROPRIATE VIDEO TABLES INTO MEMORY FOR USE IN THE
;  GENERIC IOCTL.
;
;  AT ENTRY:
;
;  AT EXIT:
;     NORMAL: FLAG WORD WILL CONTAIN BITS SET FOR THE APPROPRIATE
;	      TABLES. IN ADDITION, FOR VGA SUPPORT, A FLAG BYTE
;	      WILL CONTAIN THE AVAILABLE SCAN LINE SETTINGS FOR THE
;	      INSTALLED ADAPTER.
;	      VIDEO TABLES WILL BE LOADED INTO MEMORY REFLECTING
;	      APPLICABLE MODE SETTINGS AND SCREEN LINE LENGTHS.
;
;     ERROR:  N/A
;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
; SC: CPU_PATCH -- on a CPU with the 186 instruction set (80186 and
; later, and NEC's V20/V30, which have it but fail the usual shift test),
; rewrite OUTC's eight pushes and eight pops as PUSH ES/PUSHA and
; POPA/POP ES.  An 8086/8088 keeps the original code.  One binary for all.
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
CPU_PATCH PROC	  NEAR
	  CMP	 No186,0
	  JNE	 CP_RET
	  MOV	 AX,1		     ; 186+: the shift count is taken mod 32
	  MOV	 CL,32
	  SHL	 AX,CL
	  OR	 AX,AX
	  JNZ	 CP_186
	  MOV	 AX,0101H	     ; NEC V20/V30: AAD ignores its operand
	  DB	 0D5H,0BH	     ; AAD 11: Intel gives 12, NEC gives 11
	  CMP	 AL,11
	  JNE	 CP_RET
CP_186:	  PUSH	 ES
	  PUSH	 CS
	  POP	 ES
	  CLD
	  MOV	 DI,OFFSET OUTC_PRO
	  MOV	 SI,OFFSET PRO186
	  MOV	 CX,4
	  REP	 MOVSB
	  MOV	 DI,OFFSET OUTC_EPI
	  MOV	 SI,OFFSET EPI186
	  MOV	 CX,3
	  REP	 MOVSB
	  POP	 ES
CP_RET:	  RET
		  DB	 'SC_NO186'	     ; test\emuansi.py sets the byte after
No186		  DB	 0		     ; this to force the 8086 code
PRO186	  DB	 06H,60H,0EBH,04H    ; PUSH ES / PUSHA / JMP SHORT +4
EPI186	  DB	 61H,07H,0C3H	     ; POPA / POP ES / RET
CPU_PATCH ENDP

DET_HDWR  PROC	  NEAR									 ;AN000;
	  MOV	 AH,GET_SYS_ID		     ; see if this is a Convertible		 ;AN000;
	  INT	 15H			     ;						 ;AN000;
	  .IF <ES:[BX].MODEL_BYTE EQ LCD_MODEL> AND ; yes...check for LCD attached?	 ;AN000;
	  MOV	 AH,GET_STATUS		     ; system status will tell us		 ;AN000;
	  INT	 15H			     ;						 ;AN000;
	  .IF <BIT AL NAND ON>		     ; if bit 0 = 0 then LCD..			 ;AN000;
	     OR     HDWR_FLAG,LCD_ACTIVE     ; so ...set hdwr flag and...		 ;AN000;
	     LEA    SI,COLOR_TABLE	     ;						 ;AN000;
	     MOV    CX,COLOR_NUM	     ; load color table (for LCD)		 ;AN000;
	     CALL   LOAD_TABLE		     ;						 ;AN000;
	     LEA    SI,MONO_TABLE	     ; and mono table				 ;AN000;
	     MOV    CX,MONO_NUM 	     ;						 ;AN000;
	     CALL   LOAD_TABLE		     ;						 ;AN000;
	  .ELSE 			     ; not LCD...check for CGA and mono 	 ;AN000;
	    MOV   AX,MONO_ADDRESS	     ; write to mono buffer to see if present	 ;AN000;
	    CALL  CHECK_BUF		     ;						 ;AN000;
	    .IF <AH EQ AL>		     ; if present then...			 ;AN000;
	      OR     HDWR_FLAG,MONO_ACTIVE   ; set hdwr flag and..			 ;AN000;
	      LEA    SI,MONO_TABLE	     ;						 ;AN000;
	      MOV    CX,MONO_NUM	     ; load mono table				 ;AN000;
	      CALL   LOAD_TABLE 	     ;						 ;AN000;
	    .ENDIF			     ;						 ;AN000;
	    MOV   AX,COLOR_ADDRESS	     ; write to CGA buffer to see if present	 ;AN000;
	    CALL  CHECK_BUF		     ;						 ;AN000;
	    .IF <AH EQ AL>		     ; if present then..			 ;AN000;
	      OR     HDWR_FLAG,CGA_ACTIVE    ; set hdwr flag and...			 ;AN000;
	      LEA    SI,COLOR_TABLE	     ;						 ;AN000;
	      MOV    CX,COLOR_NUM	     ; load color table 			 ;AN000;
	      CALL   LOAD_TABLE 	     ;						 ;AN000;
	    .ENDIF			     ;						 ;AN000;
	  .ENDIF			     ;						 ;AN000;
	  PUSH	  CS			     ; setup addressiblity for			 ;AN000;
	  POP	  ES			     ;	functionality call			 ;AN000;
	  XOR	  AX,AX 		     ;						 ;AN000;
	  MOV	  AH,FUNC_CALL		     ; functionality call			 ;AN000;
	  XOR	  BX,BX 		     ; implementation type 0			 ;AN000;
	  LEA	  DI,FUNC_INFO		     ; block to hold data			 ;AN000;
	  INT	  10H			     ;						 ;AN000;
	  .IF <AL EQ FUNC_CALL> 	     ; if call supported then.. 		 ;AN000;
	    PUSH   BX			     ; 6.22 decides VGA by the display
	    PUSH   CX			     ; combination code: 7 or 8
	    MOV    AX,1A00H
	    INT    10H
	    MOV    AL,BL
	    POP    CX
	    POP    BX
	    .IF <AL EQ 8> OR
	    .IF <AL EQ 7>
	      OR     HDWR_FLAG,VGA_ACTIVE    ; yes ....so				 ;AN000;
	      LEA    SI,COLOR_TABLE	     ; set hdwr flag and...			 ;AN000;
	      MOV    CX,COLOR_NUM	     ; load color table +..			 ;AN000;
	      CALL   LOAD_TABLE 	     ;						 ;AN000;
	      LEA    SI,VGA_TABLE	     ; load VGA table				 ;AN000;
	      MOV    CX,VGA_NUM 	     ;						 ;AN000;
	      CALL   LOAD_TABLE 	     ;						 ;AN000;
	    .ELSE			     ; not VGA...then must be MCGA		 ;AN000;
	      .IF <[DI].ACTIVE_DISPLAY EQ MOD30_MONO> OR				 ;AN000;
	      .IF <[DI].ACTIVE_DISPLAY EQ MOD30_COLOR> OR				 ;AN000;
	      .IF <[DI].ALT_DISPLAY EQ MOD30_MONO> OR					 ;AN000;
	      .IF <[DI].ALT_DISPLAY EQ MOD30_COLOR>					 ;AN000;
		OR     HDWR_FLAG,MCGA_ACTIVE ; so...set hdwr flag and...		 ;AN000;
		LEA    SI,COLOR_TABLE	     ;						 ;AN000;
		MOV    CX,COLOR_NUM	     ; load color table +..			 ;AN000;
		CALL   LOAD_TABLE	     ;						 ;AN000;
		LEA    SI,MCGA_TABLE	     ; load MCGA table				 ;AN000;
		MOV    CX,MCGA_NUM	     ;						 ;AN000;
		CALL   LOAD_TABLE	     ;						 ;AN000;
	      .ENDIF			     ;						 ;AN000;
	    .ENDIF			     ;						 ;AN000;
	    MOV    AL,[DI].CURRENT_SCANS     ; copy current scan line setting.. 	 ;AN000;
	    MOV    MAX_SCANS,AL 	     ; as maximum text mode scan setting.	 ;AN000;
	    LES    DI,[DI].STATIC_ADDRESS    ; point to static functionality table	 ;AN000;
	    MOV    AL,ES:[DI].SCAN_TEXT      ; load available scan line flag byte..	 ;AN000;
	    MOV    SCAN_LINES,AL	     ; and store it in resident data.		 ;AN000;
	  .ELSE 			     ; call not supported..try EGA		 ;AN000;
	    MOV    AH,ALT_SELECT	     ; alternate select call			 ;AN000;
	    MOV    BL,EGA_INFO		     ; get EGA information subcall		 ;AN000;
	    INT    10H			     ;						 ;AN000;
	    .IF <BL NE EGA_INFO>	     ; check if call was valid			 ;AN000;
	      .IF <BH EQ MONOCHROME>	     ; yes...check for monochrome		 ;AN000;
		OR    HDWR_FLAG,E5151_ACTIVE ; ..5151 found so set hdwr flag and..	 ;AN000;
		LEA   SI,EGA_5151_TABLE      ;						 ;AN000;
		MOV   CX,EGA_5151_NUM	     ; load 5151 table. 			 ;AN000;
		CALL  LOAD_TABLE	     ;						 ;AN000;
	      .ELSE			     ;						 ;AN000;
		AND   CL,0FH		     ; clear upper nibble of switch setting byte ;AN000;
		.IF <CL EQ NINE> OR	     ; test for switch settings of 5154 	 ;AN000;
		.IF <CL EQ THREE>	     ; ..5154 found..				 ;AN000;
		  OR	 HDWR_FLAG,E5154_ACTIVE ; so..set hdwr flag and...		 ;AN000;
		  LEA	 SI,COLOR_TABLE      ;						 ;AN000;
		  MOV	 CX,COLOR_NUM	     ; load color table +..			 ;AN000;
		  CALL	 LOAD_TABLE	     ;						 ;AN000;
		  LEA	 SI,EGA_5154_TABLE   ; load 5154 table				 ;AN000;
		  MOV	 CX,EGA_5154_NUM     ;						 ;AN000;
		  CALL	 LOAD_TABLE	     ;						 ;AN000;
		.ELSE			     ; 5154 not found...must be 5153... 	 ;AN000;
		  OR	 HDWR_FLAG,E5153_ACTIVE ; so..set hdwr flag and...		 ;AN000;
		  LEA	 SI,COLOR_TABLE      ;						 ;AN000;
		  MOV	 CX,COLOR_NUM	     ; load color table +..			 ;AN000;
		  CALL	 LOAD_TABLE	     ;						 ;AN000;
		  LEA	 SI,EGA_5153_TABLE   ; load 5153 table				 ;AN000;
		  MOV	 CX,EGA_5153_NUM     ;						 ;AN000;
		  CALL	 LOAD_TABLE	     ;						 ;AN000;
		.ENDIF			     ;						 ;AN000;
	      .ENDIF			     ;						 ;AN000;
	    .ENDIF			     ;						 ;AN000;
	  .ENDIF			     ;						 ;AN000;
	  RET
DET_HDWR  ENDP


;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;
; PROCEDURE_NAME: CHECK_BUF
;
; FUNCTION:
; THIS PROCEDURE WRITES TO THE VIDEO BUFFER AND READS THE DATA BACK
; AGAIN TO DETERMINE THE EXISTANCE OF THE VIDEO CARD.
;
; AT ENTRY:
;
; AT EXIT:
;    NORMAL: AH EQ AL IF BUFFER PRESENT
;	     AH NE AL IF NO BUFFER
;
;    ERROR: N/A
;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

CHECK_BUF PROC	 NEAR		    ; write to video buffer to see if it is present	 ;AN000;
	  PUSH	 DS		    ;							 ;AN000;
	  MOV	 DS,AX		    ; load DS with address of buffer			 ;AN000;
	  MOV	 CH,DS:0	    ; save buffer information (if present)		 ;AN000;
	  MOV	 AL,55H 	    ; prepare to write sample data			 ;AN000;
	  MOV	 DS:0,AL	    ; write to buffer					 ;AN000;
	  PUSH	 BX		    ; terminate the bus so that lines.. 		 ;AN000;
	  POP	 BX		    ; are reset 					 ;AN000;
	  MOV	 AH,DS:0	    ; bring sample data back... 			 ;AN000;
	  MOV	 DS:0,CH	    ; repair damage to buffer				 ;AN000;
	  POP	 DS		    ;							 ;AN000;
	  RET										 ;AN000;
CHECK_BUF ENDP

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;
; PROCEDURE_NAME: LOAD_TABLE
;
; FUNCTION:
; THIS PROCEDURE COPIES ONE OF THE VIDEO TABLES INTO RESIDENT DATA.
; IT MAY BE REPEATED TO LOAD SEVERAL TABLES INTO THE SAME DATA SPACE.
; MATCHING MODES WILL BE OVERWRITTEN...THEREFORE..CARE MUST BE TAKEN
; IN LOAD ORDERING.
;
; AT ENTRY:
;   SI: POINTS TO TOP OF TABLE TO COPY
;   CX: NUMBER OF RECORDS TO COPY
;
; AT EXIT:
;    NORMAL: TABLE POINTED TO BY SI IS COPIED INTO RESIDENT DATA AREA
;
;    ERROR: N/A
;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

LOAD_TABLE PROC   NEAR									 ;AN000;
	   PUSH   DI			  ; save DI					 ;AN000;
	   PUSH   ES			  ; and ES					 ;AN000;
	   PUSH   CS			  ; setup ES to code segment			 ;AN000;
	   POP	  ES			  ;						 ;AN000;
	   LEA	  DI,VIDEO_MODE_TABLE	  ; point DI to resident video table		 ;AN000;
	   .WHILE <CX NE 0> AND 	  ; do for as many records as there are 	 ;AN000;
	   .WHILE <DI LT VIDEO_TABLE_MAX> ; check to ensure other data not overwritten	 ;AN000;
	     MOV    AL,[DI].V_MODE	  ; prepare to check resident table		 ;AN000;
	     .IF <AL NE UNOCCUPIED> AND   ; if this spot is occupied...and		 ;AN000;
	     .IF <AL NE [SI].V_MODE>	  ; ...is not the same mode then...		 ;AN000;
	       ADD    DI,TYPE MODE_TABLE  ; do not touch...go to next mode		 ;AN000;
	     .ELSE			  ; can write at this location			 ;AN000;
	       PUSH   CX		  ; save record count				 ;AN000;
	       MOV    CX,TYPE MODE_TABLE  ; load record length				 ;AN000;
	       REP    MOVSB		  ; copy record to resident data		 ;AN000;
	       lea    DI,VIDEO_MODE_TABLE ;AN001; Set DI to the top of the target again.
	       POP    CX		  ; restore record count and..			 ;AN000;
	       DEC    CX		  ; decrement					 ;AN000;
	     .ENDIF			  ;						 ;AN000;
	   .ENDWHILE			  ;						 ;AN000;
	   POP	  ES			  ; restore..					 ;AN000;
	   POP	  DI			  ; registers					 ;AN000;
	   RET				  ;						 ;AN000;
LOAD_TABLE ENDP


;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;
; PROCEDURE_NAME: LOAD_INT10
;
; FUNCTION:
; THIS PROCEDURE LOADS THE INTERRUPT HANDLER FOR INT10H
;
; AT ENTRY:
;
; AT EXIT:
;    NORMAL: INTERRUPT 10H VECTOR POINTS TO INT10_COM. OLD INT 10H
;	     VECTOR STORED.
;
;    ERROR:  N/A
;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

LOAD_INT10 PROC   NEAR									 ;AN000;
	   PUSH   ES									 ;AN000;
	   XOR	  AX,AX 			   ; point ES to low..			 ;AN000;
	   MOV	  ES,AX 			   ; memory.				 ;AN000;
	   MOV	  CX,ES:WORD PTR INT10_LOW	   ; store original..			 ;AN000;
	   MOV	  CS:ROM_INT10,CX		   ; interrupt 10h..			 ;AN000;
	   MOV	  CX,ES:WORD PTR INT10_HI	   ; location.. 			 ;AN000;
	   MOV	  CS:ROM_INT10+2,CX		   ;					 ;AN000;
	   CLI					   ;					 ;AN000;
	   MOV	  ES:WORD PTR INT10_LOW,OFFSET INT10_COM ; replace vector..		 ;AN000;
	   MOV	  ES:WORD PTR INT10_HI,CS	   ; with our own..			 ;AN000;
	   STI					   ;					 ;AN000;
	   mov	  ax, DISPLAY_CHECK		   ;AN002;DISPLAY.SYS already loaded?
	   int	  2fh				   ;AN002;
	   cmp	  al, INSTALLED 		   ;AN002;
	   jne	  L_INT10_Ret			   ;AN002;
	   mov	  cs:Display_Loaded_Before_Me,1    ;AN002;
L_INT10_Ret:					   ;AN002;
	   POP	  ES				   ;					 ;AN000;
	   RET					   ;					 ;AN000;
LOAD_INT10 ENDP


;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;
; PROCEDURE_NAME: LOAD_INT2F
;
; FUNCTION:
; THIS PROCEDURE LOADS THE INTERRUPT HANDLER FOR INT2FH
;
; AT ENTRY:
;
; AT EXIT:
;    NORMAL: INTERRUPT 2FH VECTOR POINTS TO INT2F_COM. OLD INT 2FH
;	     VECTOR STORED.
;
;    ERROR:  N/A
;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

LOAD_INT2F PROC   NEAR									 ;AN000;
	   PUSH   ES									 ;AN000;
	   XOR	  AX,AX 			   ; point ES to low..			 ;AN000;
	   MOV	  ES,AX 			   ; memory.				 ;AN000;
	   MOV	  AX,ES:WORD PTR INT2F_LOW	   ; store original..			 ;AN000;
	   MOV	  CS:ROM_INT2F,AX		   ; interrupt 2Fh..			 ;AN000;
	   MOV	  CX,ES:WORD PTR INT2F_HI	   ; location.. 			 ;AN000;
	   MOV	  CS:ROM_INT2F+2,CX		   ;					 ;AN000;
	   OR	  AX,CX 			   ; check if old int2F..		 ;AN000;
	   .IF Z				   ; is 0.				 ;AN000;
	     MOV    AX,OFFSET ABORT		   ; yes....point to..			 ;AN000;
	     MOV    CS:ROM_INT2F,AX		   ; IRET.				 ;AN000;
	     MOV    AX,CS			   ;					 ;AN000;
	     MOV    CS:ROM_INT2F+2,AX		   ;					 ;AN000;
	   .ENDIF				   ;					 ;AN000;
	   CLI					   ;					 ;AN000;
	   MOV	  ES:WORD PTR INT2F_LOW,OFFSET INT2F_COM ; replace vector..		 ;AN000;
	   MOV	  ES:WORD PTR INT2F_HI,CS	   ; with our own..			 ;AN000;
	   STI					   ;					 ;AN000;
	   POP	  ES				   ;					 ;AN000;
	   RET					   ;					 ;AN000;
LOAD_INT2F ENDP 									 ;AN000;


CODE	ENDS
	END
