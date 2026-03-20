;
; changed from HAM6 to HAM8
;
; modified to allow 288/304/320/336 widths and up to 240 lines
;
; accepts filename as command line argument, yay!
;
; a119 is next
;
;

_LVOOpen equ -30
_LVORead equ -42
_LVOClose equ -36
_LVOCurrentDir equ -126

ie_Class equ $4
IOSTD_SIZE equ $30
IO_DATA equ $28
IO_COMMAND equ $1c
pr_WindowPtr equ $b8
gb_ActiView equ $22
pr_MsgPort equ $5c
pr_CLI equ $ac
IECLASS_NULL equ $0
NT_INTERRUPT equ $2
NT_REPLYMSG equ $7
PA_SIGNAL equ $0
NT_MSGPORT equ $4
IND_REMHANDLER equ $a
IND_ADDHANDLER equ $9
gb_copinit equ $26

        machine 68000

        include "exec_lib.i"
        include "graphics_lib.i"

        section friendlycode,code

        ; piru`s startup
_entry:
        movem.l d0/a0,_args
        move.l 4.w,a6
        moveq #$14,d7

        ; handle wb startup
        sub.l a1,a1
        jsr _LVOFindTask(a6)
        move.l d0,a2
        tst.l pr_CLI(a2)
        bne.s .iscli
        lea pr_MsgPort(a2),a0
        jsr _LVOWaitPort(a6)
        lea pr_MsgPort(a2),a0
        jsr _LVOGetMsg(a6)
        move.l d0,_WBenchMsg
        beq.s   .iscli

        move.l  d0,a0
        cmp.l   #1,$1C(a0)          ; argument count >= 2
        ble.s   .iscli
        move.l  $24(a0),d0          ; argument pointer valid
        beq.s   .iscli
        move.l  d0,a0
        move.l  $08(a0),d7          ; read path lock
        lea.l   dosname(pc),a1
        moveq   #0,d0 
        jsr     _LVOOpenLibrary(a6) ; open dos library
        tst.l   d0
        beq.s   .iscli
        move.l  d0,a6
        move.l  d7,d1               ; path lock
        jsr     _LVOCurrentDir(a6)  ; CurrentDir ()
        move.l  d0,_OldDirLock      ; store old lock
        move.l  a6,a1
        move.l  4.w,a6
        jsr     _LVOCloseLibrary(a6); close dos library

        move.l  _WBenchMsg(pc),a0
        move.l  $24(a0),a0
        move.l  $0C(a0),d0
        beq.s   .iscli
        lea.l   _args(pc),a0        ; store project name as arg(0)
        move.l  d0,4(a0)            ; arg pointer
        move.b  #1,3(a0)            ; one arg

.iscli:
        ; init msgport
        moveq #-1,d0
        jsr _LVOAllocSignal(a6)
        move.b d0,_sigbit
        bmi .nosignal
        move.l a2,_sigtask

        ; hide possible requesters since user has no way to
        ; see or close them.
        moveq #-1,d0
        move.l pr_WindowPtr(a2),_oldwinptr
        move.l d0,pr_WindowPtr(a2)

        ; open input.device
        lea .inputname(pc),a0
        moveq #0,d0
        moveq #0,d1
        lea _ioreq(pc),a1
        jsr _LVOOpenDevice(a6)
        tst.b d0
        bne .noinput

        ; install inputhandler
        lea _ioreq(pc),a1
        move.w #IND_ADDHANDLER,IO_COMMAND(a1)
        move.l #_ih_is,IO_DATA(a1)
        jsr _LVODoIO(a6)

        ; open graphics.library
        lea .gfxname(pc),a1
        moveq #33,d0            ; Kickstart 1.2 or higher
        jsr _LVOOpenLibrary(a6)
        move.l d0,_GfxBase
        beq .nogfx
        move.l d0,a6

        ; save old view
        move.l gb_ActiView(a6),_oldview

        ; flush view
        sub.l a1,a1
        jsr _LVOLoadView(a6)
        jsr _LVOWaitTOF(a6)
        jsr _LVOWaitTOF(a6)

        ; do the stuff
        movem.l _args(pc),d0/a0
        bsr _main
        move.l d0,d7

        move.l _GfxBase(pc),a6

        ; restore view & copper ptr
        move.l _oldview(pc),a1
        jsr _LVOLoadView(a6)
        move.l gb_copinit(a6),$DFF080
        jsr _LVOWaitTOF(a6)
        jsr _LVOWaitTOF(a6)

        ; close graphics.library
        move.l a6,a1
        move.l 4.w,a6
        jsr _LVOCloseLibrary(a6)

.nogfx:
        ; remove inputhandler
        lea _ioreq(pc),a1
        move.w #IND_REMHANDLER,IO_COMMAND(a1)
        move.l #_ih_is,IO_DATA(a1)
        jsr _LVODoIO(a6)

        lea _ioreq(pc),a1
        jsr _LVOCloseDevice(a6)

.noinput:
        move.l _sigtask(pc),a0
        move.l _oldwinptr(pc),pr_WindowPtr(a0)

        moveq #0,d0
        move.b _sigbit(pc),d0
        jsr _LVOFreeSignal(a6)

.nosignal:
        move.l _WBenchMsg(pc),d7
        beq.s .notwb
        
        move.l  _OldDirLock(pc),d6
        cmp.l   #$FFFFFFFF,d6
        beq.s   .nolck
        lea.l   dosname(pc),a1
        moveq   #0,d0 
        jsr     _LVOOpenLibrary(a6) ; open dos library
        tst.l   d0
        beq.s   .nolck
        move.l  d0,a6
        move.l  d6,d1               ; path lock
        jsr     _LVOCurrentDir(a6)  ; CurrentDir ()
        move.l  a6,a1
        move.l  4.w,a6
        jsr     _LVOCloseLibrary(a6); close dos library

.nolck: jsr _LVOForbid(a6)
        move.l d7,a1
        jsr _LVOReplyMsg(a6)

.notwb:
        move.l d7,d0
        rts


.inputname:
        dc.b 'input.device',0
.gfxname:
        dc.b 'graphics.library',0
dosname
        dc.b 'dos.library',0
        
        CNOP 0,4

_OldDirLock:
        dc.l $FFFFFFFF
_args:
        dc.l 0,0
_oldwinptr:
        dc.l 0
_WBenchMsg:
        dc.l 0
_GfxBase:
        dc.l 0
_oldview:
        dc.l 0

_msgport:
        dc.l 0,0        ; LN_SUCC, LN_PRED
        dc.b NT_MSGPORT,0    ; LN_TYPE, LN_PRI
        dc.l 0        ; LN_NAME
        dc.b PA_SIGNAL    ; MP_FLAGS
_sigbit:
        dc.b -1        ; MP_SIGBIT
_sigtask:
        dc.l 0        ; MP_SIGTASK
.head:
        dc.l .tail        ; MLH_HEAD
.tail:
        dc.l 0        ; MLH_TAIL
        dc.l .head        ; MLH_TAILPRED

_ioreq:
        dc.l 0,0        ; LN_SUCC, LN_PRED
        dc.b NT_REPLYMSG,0    ; LN_TYPE, LN_PRI
        dc.l 0        ; LN_NAME
        dc.l _msgport    ; MN_REPLYPORT
        dc.w IOSTD_SIZE    ; MN_LENGTH
        dc.l 0        ; IO_DEVICE
        dc.l 0        ; IO_UNIT
        dc.w 0        ; IO_COMMAND
        dc.b 0,0        ; IO_FLAGS, IO_ERROR
        dc.l 0        ; IO_ACTUAL
        dc.l 0        ; IO_LENGTH
        dc.l 0        ; IO_DATA
        dc.l 0        ; IO_OFFSET

_ih_is:
        dc.l 0,0        ; LN_SUCC, LN_PRED
        dc.b NT_INTERRUPT,127    ; LN_TYPE, LN_PRI ** highest priority **
        dc.l .ih_name    ; LN_NAME
        dc.l 0        ; IS_DATA
        dc.l .ih_code    ; IS_CODE

.ih_code:
        move.l a0,d0
.loop:
        move.b #IECLASS_NULL,ie_Class(a0)
        move.l (a0),a0
        move.l a0,d1
        bne.b .loop

        ; d0 is the original a0
        rts

.ih_name:
        dc.b 'eat-events inputhandler',0

        CNOP 0,4

;
; _main can poke display registers and copper. all user input
; is swallowed, but task scheduling and system interrupts are
; running normally.
;
; _main MUST allocate further hardware resources it uses:
; blitter, audio, potgo, cia registers (timers, mouse &
; joystick). do not make any assumptations about the initial
; value of any hardware register.
;
; if full interrupt control is desired, _main must _LVODisable,
; save intenar and disable all interrupts by writing $7fff to
; intena. to restore, write $7fff to intena, or $8000 to saved
; intenar value and write it to intena, and finally _LVOEnable.
;
; if dma register control is desired, the same procedure is
; required, but this time for dmaconr and dmacon.
;
; the code poking interrupt-vectors must be aware of 68010+ VBR
; register. interrupt code satisfying an interrupt request must
; write the intreq and 'nop' to avoid problems with fast 040 and
; 060 systems.
;
; selfmodifying code must be aware of 020/030 and 040 caches
; (040 cacheflush handles 060 too).
;

 
;
;  in: a0.l  UBYTE *argstr
;      d0.l  LONG   arglen
; out: d0.l  LONG   returncode
;
_main:

; --------------------------------------------------------------------

Setup   lea $DFF000,a5
        lea varbase,a4
        move.l 4.w,a6
        move.l a0,(a4)    ; save a0

; First, open dos.library

        lea dosname(pc),a1
        moveq #0,d0 
        jsr _LVOOpenLibrary(a6)
        move.l d0,$04(a4)
        beq theend                ; failure?

; look for filename as command line argument
        move.l (a4),a0
a112
        move.b (a0)+,d0
        cmp.b #$20,d0
        beq a112
        cmp.b #$0A,d0
        beq setupstep1

        moveq #$4F,d2
        lea vidfile(pc),a1
        move.b d0,(a1)+
a113
        move.b (a0)+,d0
        cmp.b #$0A,d0
        beq a114
        move.b d0,(a1)+
        subq.b #1,d2
        bne a113
a114

; second, allocate chipmem
    
        move.l #$30000,d0
        move.l #$00010002,d1   ; set bit 1 for chipmem (set bit 16 to clear the RAM)
        jsr _LVOAllocMem(a6)
        move.l d0,(a4)
        beq setupstep1          ; failure?

; open file
        move.l $04(a4),a6
        lea vidfile(pc),a0
        move.l a0,d1    
        move.l #$3ed,d2
        jsr _LVOOpen(a6)
        move.l d0,$08(a4)
        beq setupstep3            ; failure?
        
        jsr initcopperlist

        lea CopperList,a0
        move.l a0,$80(a5)          ; cop1lch
        clr.w $88(a5)             ; copjmp1

        move.w #$0180,$9A(a5)  ; intena - disable audio interrupts
        move.w #$FF,$9E(a5)
        move.w #32,$96(a5)    ; dmacon - turn off sprites 

        ; clear sprite data registers
        moveq #0,d0
        move.l d0,$144(a5)
        move.l d0,$14C(a5)
        move.l d0,$154(a5)
        move.l d0,$15C(a5)
        move.l d0,$164(a5)
        move.l d0,$16C(a5)
        move.l d0,$174(a5)
        move.l d0,$17C(a5)

; ------------------ now it's file I/O time ------------------

; read header
        move.l #14,d3
        move.l a4,d2         ; address
        addi.l #$18,d2
        move.l $08(a4),d1    ; file handle
        jsr _LVORead(a6)
        cmp.l d0,d3
        bne a100

; figure frame size

        move.w $24(a4),d1      ; bytes per line
        move.w $22(a4),d2       ; number of lines
        mulu.w d2,d1
        move.l d1,$28(a4)

        moveq #0,d2
        move.w $1C(a4),d2
        add.l d2,d1
        move.w $20(a4),d0
        cmp.b #2,d0
        bne a110
        add.l d2,d1
a110
        move.l d1,$30(a4)       ; total size of video + audio chunks


        ; set display registers according to frame size
        lea diwmoves,a0
        move.w $22(a4),d0
        asr #1,d0
        move.w #$90,d1
        add d0,d1
        move.b d1,6(a0)
        move.w #$90,d1
        sub d0,d1
        move.b d1,2(a0)

        move.w $24(a4),d0
        asr #1,d0
        moveq #$20,d1
        add d0,d1
        move.b d1,7(a0)
        move.w #$120,d1
        sub d0,d1
        move.b d1,3(a0)

        lea bplxmod,a0
        asr #2,d0
        moveq #7,d1
        mulu.w d0,d1
        move.w d1,2(a0)
        move.w d1,6(a0)

        lea ddftable,a0
        asl #1,d0
        subi.b #72,d0
        adda d0,a0
        lea ddfs,a1
        move.w (a0)+,2(a1)
        move.w (a0),6(a1)

;        move.w #777,$0C(a4)    ; number of frames to play

readframe
        eori.w #1,$0E(a4)   ; swap framebuffers 

        move.l (a4),d2      ; pointer to chipmem
        move.w $0E(a4),d1
        beq a103
        addi.l #$18000,d2
a103
        ; read from file
        move.l $30(a4),d3        
        move.l $08(a4),d1    ; file handle
        jsr _LVORead(a6)
        cmp.l d0,d3
        bne a100

        jsr initcopperlist


        move.w $DFF016,d0
        not.w d0
        and.w $34(a4),d0
        beq a115
        ; pause playback
a116
        move.w #15,$96(a5)    ; dmacon - turn off audio
a117
        btst #10,$DFF016
        beq a117
a118
        btst #10,$DFF016
        bne a118
a115
        move.w $DFF016,d0
        and.w #$400,d0
        move.w d0,$34(a4)        ; save old port value


        moveq #0,d2
        move.l $28(a4),d2      ; size of video chunk
        add.l (a4),d2          ; address of chipmem buffer
        move.w $0E(a4),d1
        beq a104
        addi.l #$18000,d2
a104
        move.l d2,$A0(a5)          ; aud0lch

        moveq #0,d1
        move.w $1C(a4),d1
        move.w $20(a4),d0
        cmp.b #2,d0
        bne a111
        add.l d1,d2     ; change pointer for second channel if stereo
a111                    ; leave it the same for mono
        move.l d2,$B0(a5)          ; aud1lch

        asr.w #1,d1
        move.w d1,$A4(a5)          ; aud0len
        move.w d1,$B4(a5)          ; aud1len
        move.w $1E(a4),$A6(a5)     ; aud0per
        move.w $1E(a4),$B6(a5)     ; aud1per
        move.w #64,$A8(a5)         ; aud0vol
        move.w #64,$B8(a5)         ; aud1vol
        move.w #$8203,$96(a5)    ; dmacon - enable 0&1

        jsr waitaudio

;        subq.w #1,$0C(a4)
;        bne readframe

        btst #6,$BFE001         ; test for left mousebutton
        beq a100

        bra readframe

;    --------------------------------------------------------------------

a100
        move.w #15,$96(a5)    ; dmacon - turn off audio

        moveq #99,d5
        move.l _GfxBase(pc),a6
.delay: jsr _LVOWaitTOF(a6)
        dbf d5,.delay

        move.w #$8020,$96(a5) ; dmacon - turn sprites back on

closefile
        lea vidfile(pc),a0
        move.l a0,d0    
        move.l $08(a4),d1
        move.l $04(a4),a6
        jsr _LVOClose(a6)

; free fastmem
setupstep3
;        move.l #$10000,d0
;        move.l $10(a4),a1
;        move.l 4.w,a6
;        jsr _LVOFreeMem(a6)

; free framebuffer mem
setupstep2
        move.l #$20000,d0
        move.l (a4),a1
        move.l 4.w,a6
        jsr _LVOFreeMem(a6)

; close dos.library
setupstep1
        move.l $04(a4),a1
        move.l 4.w,a6
        jsr _LVOCloseLibrary(a6)

theend
        moveq #0,d0     ; return status code ok
        rts

initcopperlist
        moveq #0,d2
        move.w $24(a4),d2
        asr #3,d2
        move.l (a4),d0
        move.w $0E(a4),d1
        beq a102
        addi.l #$18000,d0
a102
        lea CprPln1,a0
        bsr InstallAddrToCopper
        lea CprPln2,a0
        bsr InstallAddrToCopper
        lea CprPln3,a0
        bsr InstallAddrToCopper
        lea CprPln4,a0
        bsr InstallAddrToCopper
        lea CprPln5,a0
        bsr InstallAddrToCopper
        lea CprPln6,a0
        bsr InstallAddrToCopper
        lea CprPln7,a0
        bsr InstallAddrToCopper
        lea CprPln8,a0
        bsr InstallAddrToCopper
        rts

InstallAddrToCopper
        move.w d0,6(a0)    ; Store the lo-word
        swap d0        ; Make the hi-word available
        move.w d0,2(a0)    ; Store the hi-word
        swap d0        ; Restore the old value in d0
        add.l d2,d0   ; move pointer to next "bitline"
        rts

waitaudio
        move.w $14(a4),d0
        bne a106
        addq.w #1,$14(a4)
        bra a109
a106
        move.w $1E(a5),d0
        andi.w #$180,d0
        beq a106
a109
        move.w #$180,$9C(a5)    ; intreq - "acknowledge" ints
        rts


vidfile
;        dc.b 'high288.hv',0
        dc.b 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        dc.b 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        dc.b 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0

; ---------------------------- variable land ----------------------------
        EVEN

varbase dc.l 0        ; $00 framebuffer base address
        dc.l 0        ; $04 dos.library base address
        dc.l 0        ; $08 file handle
        dc.w 0        ; $0C frame counter
        dc.w 0        ; $0E framebuffer selector
        dc.l 0        ; $10 file buffer address
        dc.w 0        ; $14 audio status
        dc.w 0        ; $16 audio buffer selector
vheader dc.l 0        ; $18 'HAMV'
        dc.w 0        ; $1C audio chunk size
        dc.w 0        ; $1E audio period
        dc.w 0        ; $20 number of sound channels
        dc.w 0        ; $22 vertical resolution
        dc.w 0        ; $24 horizontal resolution

        dc.w 0        ; $26 
        dc.l 0        ; $28 size of video chunk
        dc.l 0        ; $2C start of audio buffer
        dc.l 0        ; $30 video+audio total chunk size
        dc.w 0        ; $34 old value from port

ddftable
        dc.w $40,$C8
        dc.w $38,$C8
        dc.w $38,$D0
        dc.w $30,$D0

; --------------------------- CHIP RAM stuff ----------------------------

        section friendlydata,data_c

CopperList
        dc.w $100,$0A10         ; bplcon0 - HAM, Color Burst, 8 bitplanes
;        dc.w $100,$6A00         ; bplcon0 - HAM, Color Burst, 6 bitplanes
        dc.w $102,0             ; bplcon1
bplxmod
        dc.w $108,200           ; bpl1mod - added to address to get to next line
        dc.w $10A,200           ; bpl2mod

ddfs
; horizontal screen width?
; ddfstrt bits 3-6: $28,$30,$38,$40
        dc.w $92,$30            ; ddfstrt
; ddfstop bits 3-7: $C8,$D0,$D8 
        dc.w $94,$D0            ; ddfstop (was $D0)

diwmoves
; high bytes are vertical start/stop positions (lines)
; low bytes are horizontal start/stop (low-res pixels, 81-C1 makes 320)
        dc.w $8E,$3881      ; diwstrt
        dc.w $90,$E8C1      ; diwstop

CopperListColors
        dc.w $180,$0000
        dc.w $182,$000A
        dc.w $184,$00A0
        dc.w $186,$00AA
        dc.w $188,$0A00
        dc.w $18A,$0A0A
        dc.w $18C,$0AA0
        dc.w $18E,$0AAA
        dc.w $190,$0555
        dc.w $192,$055F
        dc.w $194,$05F5
        dc.w $196,$05FF
        dc.w $198,$0F55
        dc.w $19A,$0F5F
        dc.w $19C,$0FF5
        dc.w $19E,$0FFF

        ; bitplane pointers need to be reinitialized every vblank
        ; (bplXpth and bplXptl)
CprPln1
        dc.w $E0,0
        dc.w $E2,0
CprPln2
        dc.w $E4,0
        dc.w $E6,0
CprPln3
        dc.w $E8,0
        dc.w $EA,0
CprPln4
        dc.w $EC,0
        dc.w $EE,0
CprPln5
        dc.w $F0,0
        dc.w $F2,0
CprPln6
        dc.w $F4,0
        dc.w $F6,0
CprPln7
        dc.w $F8,0
        dc.w $FA,0
CprPln8
        dc.w $FC,0
        dc.w $FE,0

; wait
        dc.w $FFFF,$FFFE
        dc.w $FFFF,$FFFE
