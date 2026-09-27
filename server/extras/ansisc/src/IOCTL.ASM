        PAGE    ,132
        TITLE   ANSISC Generic IOCTL, INT 10h and INT 2Fh
;
;  ANSISC -- ANSI.SYS for DOS, fast.  StevenC & Claude, 2026.
;
;  This module replaces IOCTL.ASM of Microsoft's MS-DOS 4.0 ANSI.SYS
;  (MIT licence, https://github.com/microsoft/MS-DOS).  The data layout and
;  names are 4.0's; the LOGIC follows MS-DOS 6.22's ANSI.SYS, which reworked
;  it, so that this driver answers MODE CON and programs exactly as 6.22
;  does.  It was written from the observed behaviour and structure of the
;  6.22 driver -- no 6.22 code is reproduced -- and every routine here is
;  checked against the 6.22 binary in an emulator (test\emuansi.py).
;
;  What it provides:
;    GENERIC_IOCTL  DOS IOCTL 440Ch category 3: get (7Fh) and set (5Fh) the
;                   display mode -- what MODE CON uses
;    INT10_COM      INT 10h hook: a program's mode set re-runs the set so
;                   the driver's view stays right, and on an EGA with a
;                   5151 monitor, cursor shapes are scaled for 8-pixel cells
;    INT2F_COM      INT 2Fh function 1Ah: 00 installed check (AL = FFh),
;                   01 the IOCTL through INT 2Fh, 02 DISPLAY.SYS handshake
;
;  Differences from the 4.0 logic, all 6.22's:
;    - GET reports intensity/blink from the VGA itself (INT 10h 1Bh), 0 in
;      mode 7, and the row count from the BIOS data area
;    - SET asks DISPLAY.SYS (INT 2Fh AD00h/AD10h) before changing the rows;
;      a VGA is recognised by INT 10h 1Ah; there is no /L retention (6.22
;      accepts /L and ignores it)
;    - the alternate print screen routine is selected once, the first time
;      more than 25 rows are set, instead of at load time
;
INCLUDE     ANSI.INC

PUBLIC      GENERIC_IOCTL
PUBLIC      FUNC_INFO
PUBLIC      MAX_SCANS
PUBLIC      INT10_COM
PUBLIC      ROM_INT10
PUBLIC      INT2F_COM
PUBLIC      ROM_INT2F
PUBLIC      ABORT
PUBLIC      REQ_TXT_LENGTH
PUBLIC      GRAPHICS_FLAG
public      Display_Loaded_Before_Me

CODE        SEGMENT  PUBLIC  BYTE
            ASSUME CS:CODE,DS:CODE

EXTRN       PTRSAV:DWORD
EXTRN       NO_OPERATION:NEAR
EXTRN       ERR1:NEAR
EXTRN       VIDEO_MODE_TABLE:BYTE
EXTRN       HDWR_FLAG:WORD
EXTRN       SCAN_LINES:BYTE
EXTRN       MAX_VIDEO_TAB_NUM:ABS

SCAN_LINE_TABLE  LABEL    BYTE
   SCAN_LINE_STR <200,000000001B,0>            ; 25 rows x 8
   SCAN_LINE_STR <344,000000010B,1>            ; 43 rows x 8
   SCAN_LINE_STR <400,000000100B,2>            ; 50 rows x 8

In_Generic_IOCTL_flag   db      0
I_AM_IN_NOW          EQU     00000001b
SET_MODE_BY_DISPLAY  EQU     00000010b
CALLED_BY_INT10COM   EQU     00000100b

INT10_V_Mode    db      0ffh

My_IOCTL_Req_Packet REQ_PCKT <0,0,0Eh,0,?,0,?,?,?,?,?>

FUNC_INFO        INFO_BLOCK <>
ROM_INT10        DW    ?
                 DW    ?
ROM_INT2F        DW    ?
                 DW    ?
INTENSITY_FLAG   DW    OFF
REQ_TXT_LENGTH   DW    DEFAULT_LENGTH
SCAN_DESIRED     DB    0
MAX_SCANS        DB    0
GRAPHICS_FLAG    DB    TEXT_MODE
Display_Loaded_Before_Me db     0
ANSI_SetMode_Call_Flag   db     0       ; inside INT10_COM's mode set
ALT_PRTSC_DONE   DB    0               ; alternate print screen selected

MR_V_MODE       EQU     0               ; MODE_TABLE fields, by offset
MR_D_MODE       EQU     1
MR_COLORS       EQU     3
MR_WIDTH        EQU     5
MR_LENGTH       EQU     7
MR_COLS         EQU     9
MR_ROWS         EQU     11

;----------------------------------------------------------------------
; GENERIC_IOCTL: request header minor function 7Fh = get, 5Fh = set,
; anything else goes to DOS's own CON.
;----------------------------------------------------------------------
GENERIC_IOCTL:
        LES     BX,[PTRSAV]
        MOV     AL,ES:[BX].MIN_FUNC
        LES     DI,ES:[BX].REQ_PCKT_PTR
        CMP     AL,GET_FUNC
        JNE     GI1
        CALL    GET_IOCTL
        JMP     SHORT GI2
GI1:    CMP     AL,SET_FUNC
        JNE     GI3
        CALL    SET_IOCTL
GI2:    JNC     GI4
        OR      AX,CMD_ERROR
GI4:    OR      AX,DONE
        JMP     ERR1
GI3:    JMP     NO_OPERATION

;----------------------------------------------------------------------
; GET_IOCTL: ES:DI -> request packet.  CF clear on success, else AX = code.
; On success SI -> the video table record of the current mode.
;----------------------------------------------------------------------
GET_IOCTL PROC  NEAR
        CMP     BYTE PTR ES:[DI].INFO_LEVEL,0
        JNE     GET_BAD
        CMP     WORD PTR ES:[DI].DATA_LENGTH,(TYPE MODE_TABLE)+1
        JGE     GET_OK
GET_BAD:
        MOV     AX,INVALID_FUNC
        STC
        RET
GET_OK:
        MOV     BYTE PTR ES:[DI].INFO_LEVEL+1,0
        MOV     AH,REQ_VID_MODE
        INT     10H
        AND     AL,VIDEO_MASK
        LEA     SI,VIDEO_MODE_TABLE
        CALL    GET_SEARCH
        JNC     GET_FOUND
        MOV     AX,NOT_SUPPORTED
        RET
GET_FOUND:
        PUSH    DI
        MOV     WORD PTR ES:[DI].DATA_LENGTH,(TYPE MODE_TABLE)+1
        INC     SI
        ADD     DI,RP_FLAGS
        CMP     AL,MODE7                ; mono: no intensity control
        MOV     AX,0
        JE      GET_FLAG
        CMP     HDWR_FLAG,MCGA_ACTIVE
        JL      GET_FLAG
        TEST    HDWR_FLAG,VGA_ACTIVE
        JZ      GET_INT
        PUSH    ES                      ; VGA: ask it whether blink is on
        PUSH    DI
        PUSH    DS
        POP     ES
        LEA     DI,FUNC_INFO
        MOV     AH,FUNC_CALL
        XOR     BX,BX
        INT     10H
        MOV     INTENSITY_FLAG,0
        TEST    BYTE PTR ES:[DI].MISC_INFO,00100000B
        JNZ     GET_BLINK
        INC     INTENSITY_FLAG
GET_BLINK:
        POP     DI
        POP     ES
GET_INT:
        MOV     AX,INTENSITY_FLAG
GET_FLAG:
        STOSW
        MOV     CX,(TYPE MODE_TABLE)-1
        REP     MOVSB
        SUB     SI,TYPE MODE_TABLE
        CMP     BYTE PTR [SI].MR_D_MODE,TEXT_MODE
        JNE     GET_DONE
        CMP     WORD PTR [SI].MR_ROWS,DEFAULT_LENGTH
        JE      GET_DONE
        DEC     DI                      ; text, rows not fixed: the BIOS
        DEC     DI                      ; data area has the real count
        PUSH    DS
        MOV     AX,ROM_BIOS
        MOV     DS,AX
        MOV     AL,BYTE PTR DS:[NUM_ROWS]
        CBW
        INC     AX
        MOV     WORD PTR ES:[DI],AX
        POP     DS
GET_DONE:
        XOR     AX,AX
        CLC
        POP     DI
        RET
GET_IOCTL ENDP

;----------------------------------------------------------------------
; SET_IOCTL: ES:DI -> request packet.  CF clear on success, else AX = code.
;----------------------------------------------------------------------
SET_IOCTL PROC  NEAR
        OR      In_Generic_IOCTL_flag,I_AM_IN_NOW
        PUSH    REQ_TXT_LENGTH
        CMP     BYTE PTR ES:[DI].INFO_LEVEL,0
        JNE     SET_BADF
        CMP     WORD PTR ES:[DI].DATA_LENGTH,(TYPE MODE_TABLE)+1
        JNE     SET_BADF
        MOV     AX,ES:[DI].RP_FLAGS
        TEST    AX,0FFFEH
        JNZ     SET_BADF
        TEST    WORD PTR ES:[DI].RP_FLAGS,1
        JZ      SET_SRCH
        CMP     HDWR_FLAG,MCGA_ACTIVE
        JGE     SET_SRCH
SET_BADF:
        MOV     AX,INVALID_FUNC
        JMP     SET_FAIL
SET_SRCH:
        CALL    SET_SEARCH
        JNC     SET_FOUND
        JMP     SET_NOTSUP
SET_FOUND:
        CMP     BYTE PTR [SI].MR_D_MODE,TEXT_MODE
        JE      SET_TEXT
        CALL    SET_VIDEO_MODE
        JMP     SET_DONE
SET_TEXT:
        MOV     AX,ES:[DI].RP_ROWS
        MOV     REQ_TXT_LENGTH,AX
        CMP     AX,DEFAULT_LENGTH
        JE      SET_NODISP
        MOV     AX,0AD00H               ; DISPLAY.SYS loaded?
        INT     2FH
        CMP     AL,0FFH
        JNE     SET_NODISP
        MOV     AX,0AD10H               ; and does it allow this?
        INT     2FH
        JNC     SET_NODISP
        MOV     AX,0CH
        JMP     SET_FAIL
SET_NODISP:
        CMP     WORD PTR [SI].MR_ROWS,-1
        JE      SET_VGA
        TEST    HDWR_FLAG,VGA_ACTIVE
        JZ      SET_NORMAL
SET_VGA:
        MOV     AX,1A00H
        INT     10H
        MOV     AX,REQ_TXT_LENGTH
        CMP     BL,7                    ; a VGA display attached?
        JB      SET_NORMAL
        MOV     CL,3
        SHL     AX,CL                   ; rows * 8 = scan lines
        LEA     BX,SCAN_LINE_TABLE
        MOV     CX,3
SET_SL: CMP     AX,[BX].NUM_LINES
        JE      SET_SLF
        ADD     BX,TYPE SCAN_LINE_STR
        LOOP    SET_SL
        JMP     SET_NOTSUP
SET_SLF:
        MOV     DL,[BX].REP_1BH
        TEST    SCAN_LINES,DL
        JNZ     SET_SLOK
        JMP     SET_NOTSUP
SET_SLOK:
        MOV     CL,[BX].REP_12H
        MOV     SCAN_DESIRED,CL
        CMP     REQ_TXT_LENGTH,DEFAULT_LENGTH
        JNE     SET_SD
        MOV     AL,MAX_SCANS
        MOV     SCAN_DESIRED,AL
SET_SD: TEST    In_Generic_IOCTL_flag,CALLED_BY_INT10COM
        JNZ     SET_FONT
        MOV     AH,ALT_SELECT
        MOV     BL,SELECT_SCAN
        MOV     AL,SCAN_DESIRED
        INT     10H
        JMP     SHORT SET_VMODE
SET_NORMAL:
        MOV     AX,REQ_TXT_LENGTH
        CMP     AX,DEFAULT_LENGTH
        JE      SET_N2
        CMP     AX,[SI].MR_ROWS
        JNE     SET_NOTSUP
SET_N2: CALL    SET_CURSOR_EMUL
SET_VMODE:
        CALL    SET_VIDEO_MODE
SET_FONT:
        CALL    LOAD_FONT
        CMP     ALT_PRTSC_DONE,0
        JNE     SET_AP
        CMP     WORD PTR ES:[DI].RP_ROWS,DEFAULT_LENGTH
        JLE     SET_AP
        CMP     HDWR_FLAG,MCGA_ACTIVE
        JL      SET_AP
        MOV     AH,ALT_SELECT
        MOV     BL,ALT_PRT_SC
        INT     10H
        MOV     ALT_PRTSC_DONE,0FFH
SET_AP: CALL    SET_CURSOR_EMUL
        CMP     HDWR_FLAG,MCGA_ACTIVE
        JL      SET_DONE
        CMP     BYTE PTR [SI].MR_V_MODE,MODE7
        JE      SET_DONE
        XOR     BX,BX
        TEST    WORD PTR ES:[DI].RP_FLAGS,1
        JZ      SET_I
        INC     BX
SET_I:  MOV     INTENSITY_FLAG,BX
        MOV     AX,1003H                ; blink (BL=1) or intensity (BL=0)
        XOR     BL,1
        INT     10H
SET_DONE:
        AND     In_Generic_IOCTL_flag,NOT I_AM_IN_NOW
        POP     AX
        XOR     AX,AX
        CLC
        RET
SET_NOTSUP:
        MOV     AX,NOT_SUPPORTED
SET_FAIL:
        AND     In_Generic_IOCTL_flag,NOT I_AM_IN_NOW
        POP     REQ_TXT_LENGTH
        STC
        RET
SET_IOCTL ENDP

; An 8x8 font for more than 25 rows.
LOAD_FONT PROC  NEAR
        CMP     REQ_TXT_LENGTH,DEFAULT_LENGTH
        JE      LF_RET
        MOV     AX,1112H
        XOR     BL,BL
        INT     10H
        MOV     AX,1103H
        XOR     BL,BL
        INT     10H
LF_RET: RET
LOAD_FONT ENDP

; SET_SEARCH: the video table record matching the packet at ES:DI, or, when
; INT10_V_Mode is set, the record for that mode.  CF set if none.
SET_SEARCH PROC NEAR
        LEA     SI,VIDEO_MODE_TABLE
        MOV     CX,MAX_VIDEO_TAB_NUM
SS_LP:  CMP     BYTE PTR [SI].MR_V_MODE,UNOCCUPIED
        JE      SS_NF
        MOV     AL,INT10_V_Mode
        CMP     AL,0FFH
        JNE     SS_BYMODE
        MOV     AL,ES:[DI].RP_MODE
        CMP     [SI].MR_D_MODE,AL
        JNE     SS_NEXT
        MOV     AX,ES:[DI].RP_COLORS
        CMP     [SI].MR_COLORS,AX
        JNE     SS_NEXT
        CMP     BYTE PTR ES:[DI].RESERVED2,0
        JNE     SS_NEXT
        CMP     BYTE PTR ES:[DI].RP_MODE,GRAPHICS_MODE
        JNE     SS_TXT
        MOV     AX,ES:[DI].RP_WIDTH
        CMP     [SI].MR_WIDTH,AX
        JNE     SS_NEXT
        MOV     AX,ES:[DI].RP_LENGTH
        CMP     [SI].MR_LENGTH,AX
        JNE     SS_NEXT
        JMP     SHORT SS_FOUND
SS_TXT: MOV     AX,ES:[DI].RP_COLS
        CMP     [SI].MR_COLS,AX
        JNE     SS_NEXT
SS_FOUND:
        CLC
        JMP     SHORT SS_END
SS_BYMODE:
        CMP     [SI].MR_V_MODE,AL
        JE      SS_FOUND
SS_NEXT:
        ADD     SI,TYPE MODE_TABLE
        LOOP    SS_LP
SS_NF:  STC
SS_END: MOV     INT10_V_Mode,0FFH
        RET
SET_SEARCH ENDP

; GET_SEARCH: DS:SI -> table, AL = mode.  CF clear with SI -> record.
GET_SEARCH PROC NEAR
        MOV     CX,MAX_VIDEO_TAB_NUM
GS_LP:  CMP     BYTE PTR [SI].MR_V_MODE,UNOCCUPIED
        JE      GS_NF
        CMP     [SI].MR_V_MODE,AL
        JE      GS_F
        ADD     SI,TYPE MODE_TABLE
        LOOP    GS_LP
GS_NF:  STC
        RET
GS_F:   CLC
        RET
GET_SEARCH ENDP

; On an EGA with an enhanced colour display, the BIOS cursor emulation bit
; follows the row count.
SET_CURSOR_EMUL PROC NEAR
        TEST    HDWR_FLAG,E5154_ACTIVE
        JZ      SCE_RET
        PUSH    SI
        PUSH    DS
        MOV     AX,ROM_BIOS
        MOV     DS,AX
        MOV     SI,CURSOR_FLAG
        MOV     AL,BYTE PTR [SI]
        CMP     CS:REQ_TXT_LENGTH,DEFAULT_LENGTH
        JNE     SCE_ON
        AND     AL,0FEH
        JMP     SHORT SCE_ST
SCE_ON: OR      AL,1
SCE_ST: MOV     BYTE PTR [SI],AL
        POP     DS
        POP     SI
SCE_RET:
        RET
SET_CURSOR_EMUL ENDP

;----------------------------------------------------------------------
; INT 10h hook
;----------------------------------------------------------------------
INT10_COM PROC  NEAR
        STI
        CMP     AH,SET_CURSOR_CALL
        JE      I10_CUR
        CMP     AH,SET_MODE
        JE      I10_MODE
        JMP     DWORD PTR CS:ROM_INT10
I10_CUR:                                ; 5151 with more than 25 rows:
        PUSH    AX                      ; scale 14-line cursor shapes
        TEST    CS:HDWR_FLAG,E5151_ACTIVE ; to the 8-line cell
        JZ      I10_CX
        CMP     CS:REQ_TXT_LENGTH,DEFAULT_LENGTH
        JE      I10_CX
        CMP     CS:GRAPHICS_FLAG,TEXT_MODE
        JNE     I10_CX
        CMP     CL,8
        JL      I10_CX
        MOV     AL,CH
        AND     AL,01100000B
        CMP     AL,00100000B            ; cursor off: leave it
        JE      I10_CX
        MOV     AL,CH
        CALL    CUR_SCALE
        MOV     CH,AL
        MOV     AL,CL
        CALL    CUR_SCALE
        MOV     CL,AL
I10_CX: POP     AX
        JMP     DWORD PTR CS:ROM_INT10
I10_MODE:                               ; a mode set: do it, then bring the
        PUSHF                           ; driver's idea of the screen up to
        MOV     CS:ANSI_SetMode_Call_Flag,1 ; date by re-running the set
        CALL    DWORD PTR CS:ROM_INT10
        MOV     CS:ANSI_SetMode_Call_Flag,0
        PUSH    BP
        PUSH    ES
        PUSH    DS
        PUSH    SI
        PUSH    DI
        PUSH    DX
        PUSH    CX
        PUSH    BX
        PUSH    AX
        PUSH    CS
        POP     DS
        MOV     AH,REQ_VID_MODE
        PUSHF
        CALL    DWORD PTR ROM_INT10
        AND     AL,VIDEO_MASK
        TEST    In_Generic_IOCTL_flag,I_AM_IN_NOW+SET_MODE_BY_DISPLAY
        JNZ     I10_FLAG
        PUSH    AX
        PUSH    ES
        PUSH    CS
        POP     ES
        MOV     DI,OFFSET My_IOCTL_Req_Packet
        MOV     INT10_V_Mode,AL
        CALL    GET_IOCTL
        JC      I10_NG
        OR      In_Generic_IOCTL_flag,CALLED_BY_INT10COM
        CALL    SET_IOCTL
        AND     In_Generic_IOCTL_flag,NOT CALLED_BY_INT10COM
I10_NG: POP     ES
        POP     AX
        MOV     INT10_V_Mode,0FFH
I10_FLAG:
        LEA     SI,VIDEO_MODE_TABLE
        CALL    GET_SEARCH
        JC      I10_GR
        CMP     BYTE PTR [SI].MR_D_MODE,TEXT_MODE
        JE      I10_TX
I10_GR: MOV     GRAPHICS_FLAG,GRAPHICS_MODE
        JMP     SHORT I10_OUT
I10_TX: MOV     GRAPHICS_FLAG,TEXT_MODE
I10_OUT:
        POP     AX
        POP     BX
        POP     CX
        POP     DX
        POP     DI
        POP     SI
        POP     DS
        POP     ES
        POP     BP
        IRET
INT10_COM ENDP

;----------------------------------------------------------------------
; INT 2Fh hook, multiplex 1Ah
;----------------------------------------------------------------------
INT2F_COM PROC  NEAR
        STI
        CMP     AH,MULT_ANSI
        JNE     I2F_CHAIN
        CMP     AL,DA_INFO_2F
        JLE     I2F_MINE
I2F_CHAIN:
        JMP     DWORD PTR CS:ROM_INT2F
I2F_MINE:
        CMP     AL,INSTALL_CHECK
        JNE     I2F_NOTIC
        MOV     AL,INSTALLED
        CLC
        JMP     I2F_IRET
I2F_NOTIC:
        CMP     AL,DA_INFO_2F
        JBE     I2F_WORK
        JMP     I2F_IRET
I2F_WORK:
        PUSH    BP
        PUSH    AX
        PUSH    CX
        PUSH    DX
        PUSH    DS
        PUSH    ES
        PUSH    DI
        PUSH    SI
        PUSH    BX
        PUSH    DS
        POP     ES
        MOV     DI,DX
        PUSH    CS
        POP     DS
        CMP     AL,IOCTL_2F
        JNE     I2F_INFO
        CMP     CL,GET_SUBFUNC
        JNE     I2F_SET
        CALL    GET_IOCTL
        JB      I2F_EXIT
        CMP     HDWR_FLAG,E5151_ACTIVE
        JL      I2F_EXIT
        CMP     BYTE PTR [SI].MR_D_MODE,TEXT_MODE
        JNE     I2F_EXIT
        CMP     ANSI_SetMode_Call_Flag,1
        JNE     I2F_ROWS
        CMP     Display_Loaded_Before_Me,1
        JE      I2F_OK
I2F_ROWS:
        MOV     BX,REQ_TXT_LENGTH
        MOV     ES:[DI].RP_ROWS,BX
I2F_OK: CLC
        JMP     SHORT I2F_EXIT
I2F_SET:
        CMP     CL,SET_FUNC
        JNE     I2F_BAD
        CALL    SET_IOCTL
        JMP     SHORT I2F_EXIT
I2F_BAD:
        MOV     AX,INVALID_FUNC
        STC
        JMP     SHORT I2F_EXIT
I2F_INFO:                               ; 02: DISPLAY.SYS tells us things
        CMP     BYTE PTR ES:[DI],0
        JNE     I2F_I1
        CMP     BYTE PTR ES:[DI+1],1
        JNE     I2F_I0
        OR      In_Generic_IOCTL_flag,SET_MODE_BY_DISPLAY
        JMP     SHORT I2F_ICLC
I2F_I0: AND     In_Generic_IOCTL_flag,NOT SET_MODE_BY_DISPLAY
        JMP     SHORT I2F_ICLC
I2F_I1: CMP     BYTE PTR ES:[DI],1
        JNE     I2F_ICLC
        MOV     AL,0
        MOV     BYTE PTR ES:[DI+2],AL
I2F_ICLC:
        CLC
I2F_EXIT:
        POP     BX
        POP     SI
        POP     DI
        POP     ES
        POP     DS
        POP     DX
        POP     CX
        PUSH    AX                      ; stack: AX, caller AX, BP, IP, CS, flags
        MOV     BP,SP
        MOV     AX,[BP+10]
        JB      I2F_ERR
        AND     AX,0FFFEH               ; success: CF clear, and AX is the
        MOV     [BP+10],AX              ; caller's AX byte-swapped
        POP     AX
        POP     AX
        XCHG    AL,AH
        JMP     SHORT I2F_POPBP
I2F_ERR:
        OR      AX,1                    ; failure: CF set, AX = error code
        MOV     [BP+10],AX
        POP     AX
        POP     BP
I2F_POPBP:
        POP     BP
I2F_IRET:
        IRET
INT2F_COM ENDP

ABORT:  IRET

; AL = AL * 8 / 14: a 14-line cursor scan line on an 8-line cell.
CUR_SCALE PROC NEAR
        PUSH    BX
        XOR     AH,AH
        MOV     BL,8
        PUSH    DX
        MUL     BL
        POP     DX
        MOV     BL,14
        DIV     BL
        POP     BX
        RET
CUR_SCALE ENDP

; Set the video mode of the record at SI -- unless this is INT10_COM
; re-running a set the program already made.  On an LCD or a VGA the
; equipment word is told which kind of display the mode wants.
SET_VIDEO_MODE PROC NEAR
        TEST    In_Generic_IOCTL_flag,CALLED_BY_INT10COM
        JNZ     SVM_RET
        MOV     AL,[SI].MR_V_MODE
        TEST    HDWR_FLAG,LCD_ACTIVE
        JNZ     SVM_EQ
        TEST    HDWR_FLAG,VGA_ACTIVE
        JZ      SVM_SET
SVM_EQ: PUSH    DS
        MOV     BL,AL
        MOV     AX,ROM_BIOS
        MOV     DS,AX
        MOV     AX,DS:[EQUIP_FLAG]
        AND     AX,INIT_VID_MASK
        CMP     BL,MODE7
        JE      SVM_MONO
        CMP     BL,0FH
        JNE     SVM_COL
SVM_MONO:
        OR      AX,LCD_MONO_MODE
        JMP     SHORT SVM_ST
SVM_COL:
        OR      AX,LCD_COLOR_MODE
SVM_ST: MOV     DS:[EQUIP_FLAG],AX
        MOV     AL,BL
        POP     DS
SVM_SET:
        MOV     AH,SET_MODE
        INT     10H
SVM_RET:
        RET
SET_VIDEO_MODE ENDP

CODE    ENDS
        END
