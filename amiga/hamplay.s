;
; HAMPLAY - HAM6 / HAM8 video player for the Amiga
;
; One player for every Amiga:
;   - HAM6 videos (.hv) on any Amiga (OCS, ECS, AGA)
;   - HAM8 videos (.h8v) on AGA Amigas
;   - PAL or NTSC: the sound pitch and the picture position are adapted
;   - BENCH option: measures how fast this machine can read the video
;
; Usage: HAMPLAY [BENCH] file
; Keys: Space pause, cursor Left/Right -/+10 s, Down/Up -/+1 min, Esc quit.
; Mouse: left button quits, right button pauses.
;
; Based on HAMNEW / HAMAGA by damage_x (http://www.hyakushiki.net/),
; Workbench support by Roy Schneider, startup code by piru.
; Plays the old 'HAMV' files and the new 'HAM2' files of video2ham.py.
;
; Assemble with vasm: vasmm68k_mot -Fhunkexe -nosym -o HAMPLAY hamplay.s
;

        machine 68000

; ------------------------------------------------------ library offsets
_LVOForbid              equ -132
_LVOAllocMem            equ -198
_LVOFreeMem             equ -210
_LVOFindTask            equ -294
_LVOAllocSignal         equ -330
_LVOFreeSignal          equ -336
_LVOGetMsg              equ -372
_LVOReplyMsg            equ -378
_LVOWaitPort            equ -384
_LVOCloseLibrary        equ -414
_LVOOpenDevice          equ -444
_LVOCloseDevice         equ -450
_LVODoIO                equ -456
_LVOOpenLibrary         equ -552

_LVOLoadView            equ -222
_LVOWaitTOF             equ -270

_LVOOpen                equ -30
_LVOClose               equ -36
_LVORead                equ -42
_LVOWrite               equ -48
_LVOOutput              equ -60
_LVOCurrentDir          equ -126
_LVODateStamp           equ -192
_LVODelay               equ -198
_LVOSeek                equ -66
OFFSET_BEGINNING        equ -1
OFFSET_END              equ 1

MODE_OLDFILE            equ 1005
MODE_NEWFILE            equ 1006
MEMF_CHIP_CLEAR         equ $00010002

ie_Class                equ $4
IOSTD_SIZE              equ $30
IO_DATA                 equ $28
IO_COMMAND              equ $1c
pr_WindowPtr            equ $b8
gb_ActiView             equ $22
pr_MsgPort              equ $5c
pr_CLI                  equ $ac
IECLASS_NULL            equ $0
IECLASS_RAWKEY          equ $1
ie_Code                 equ $6
ie_Qualifier            equ $8
IEQUALIFIER_REPEAT      equ $200
NT_INTERRUPT            equ $2
NT_REPLYMSG             equ $7
PA_SIGNAL               equ $0
NT_MSGPORT              equ $4
IND_REMHANDLER          equ $a
IND_ADDHANDLER          equ $9
gb_copinit              equ $26
gb_ChipRevBits0         equ $ec
LIB_VERSION             equ $14
VBlankFrequency         equ $212

        section code,code

; ======================================================= startup (piru)
_entry:
        movem.l d0/a0,_args
        move.l  4.w,a6
        moveq   #$14,d7

        ; handle wb startup
        sub.l   a1,a1
        jsr     _LVOFindTask(a6)
        move.l  d0,a2
        tst.l   pr_CLI(a2)
        bne.s   .iscli
        lea     pr_MsgPort(a2),a0
        jsr     _LVOWaitPort(a6)
        lea     pr_MsgPort(a2),a0
        jsr     _LVOGetMsg(a6)
        move.l  d0,_WBenchMsg
        beq.s   .iscli

        move.l  d0,a0
        cmp.l   #1,$1C(a0)          ; argument count >= 2
        ble.s   .iscli
        move.l  $24(a0),d0          ; argument pointer valid
        beq.s   .iscli
        move.l  d0,a0
        move.l  $08(a0),d7          ; read path lock
        lea     dosname(pc),a1
        moveq   #0,d0
        jsr     _LVOOpenLibrary(a6)
        tst.l   d0
        beq.s   .iscli
        move.l  d0,a6
        move.l  d7,d1               ; path lock
        jsr     _LVOCurrentDir(a6)
        move.l  d0,_OldDirLock
        move.l  a6,a1
        move.l  4.w,a6
        jsr     _LVOCloseLibrary(a6)

        move.l  _WBenchMsg(pc),a0
        move.l  $24(a0),a0
        move.l  $0C(a0),d0
        beq.s   .iscli
        lea     _args(pc),a0        ; project name as argument
        move.l  d0,4(a0)

.iscli:
        moveq   #-1,d0
        jsr     _LVOAllocSignal(a6)
        move.b  d0,_sigbit
        bmi     .nosignal
        move.l  a2,_sigtask

        ; hide requesters, the user could not see them
        moveq   #-1,d0
        move.l  pr_WindowPtr(a2),_oldwinptr
        move.l  d0,pr_WindowPtr(a2)

        ; input handler swallowing all input events
        lea     .inputname(pc),a0
        moveq   #0,d0
        moveq   #0,d1
        lea     _ioreq(pc),a1
        jsr     _LVOOpenDevice(a6)
        tst.b   d0
        bne     .noinput
        lea     _ioreq(pc),a1
        move.w  #IND_ADDHANDLER,IO_COMMAND(a1)
        move.l  #_ih_is,IO_DATA(a1)
        jsr     _LVODoIO(a6)

        lea     .gfxname(pc),a1
        moveq   #33,d0
        jsr     _LVOOpenLibrary(a6)
        move.l  d0,_GfxBase
        beq     .nogfx
        move.l  d0,a6

        move.l  gb_ActiView(a6),_oldview
        sub.l   a1,a1
        jsr     _LVOLoadView(a6)
        jsr     _LVOWaitTOF(a6)
        jsr     _LVOWaitTOF(a6)

        movem.l _args(pc),d0/a0
        bsr     _main
        move.l  d0,d7

        move.l  _GfxBase(pc),a6
        move.l  _oldview(pc),a1
        jsr     _LVOLoadView(a6)
        move.l  gb_copinit(a6),$DFF080
        jsr     _LVOWaitTOF(a6)
        jsr     _LVOWaitTOF(a6)

        move.l  a6,a1
        move.l  4.w,a6
        jsr     _LVOCloseLibrary(a6)

.nogfx:
        lea     _ioreq(pc),a1
        move.w  #IND_REMHANDLER,IO_COMMAND(a1)
        move.l  #_ih_is,IO_DATA(a1)
        jsr     _LVODoIO(a6)
        lea     _ioreq(pc),a1
        jsr     _LVOCloseDevice(a6)

.noinput:
        move.l  _sigtask(pc),a0
        move.l  _oldwinptr(pc),pr_WindowPtr(a0)
        moveq   #0,d0
        move.b  _sigbit(pc),d0
        jsr     _LVOFreeSignal(a6)

        ; display is back: show the messages, if any
        bsr     PrintMessages
        move.l  4.w,a6

.nosignal:
        move.l  _WBenchMsg(pc),d7
        beq.s   .notwb
        move.l  _OldDirLock(pc),d6
        cmp.l   #$FFFFFFFF,d6
        beq.s   .nolck
        lea     dosname(pc),a1
        moveq   #0,d0
        jsr     _LVOOpenLibrary(a6)
        tst.l   d0
        beq.s   .nolck
        move.l  d0,a6
        move.l  d6,d1
        jsr     _LVOCurrentDir(a6)
        move.l  a6,a1
        move.l  4.w,a6
        jsr     _LVOCloseLibrary(a6)
.nolck: jsr     _LVOForbid(a6)
        move.l  d7,a1
        jsr     _LVOReplyMsg(a6)
.notwb:
        moveq   #0,d0
        tst.b   _failed
        beq.s   .rc
        moveq   #10,d0              ; RETURN_ERROR
.rc     rts

.inputname      dc.b 'input.device',0
.gfxname        dc.b 'graphics.library',0
dosname         dc.b 'dos.library',0
conname         dc.b 'CON:20/20/600/110/HAMPLAY',0
        even

_OldDirLock     dc.l $FFFFFFFF
_args           dc.l 0,0
_oldwinptr      dc.l 0
_WBenchMsg      dc.l 0
_GfxBase        dc.l 0
_oldview        dc.l 0
_failed         dc.b 0
_lastkey        dc.b 0                  ; raw key code written by the input handler
        even

_msgport:
        dc.l    0,0
        dc.b    NT_MSGPORT,0
        dc.l    0
        dc.b    PA_SIGNAL
_sigbit dc.b    -1
_sigtask
        dc.l    0
.head   dc.l    .tail
.tail   dc.l    0
        dc.l    .head

_ioreq:
        dc.l    0,0
        dc.b    NT_REPLYMSG,0
        dc.l    0
        dc.l    _msgport
        dc.w    IOSTD_SIZE
        dc.l    0,0
        dc.w    0
        dc.b    0,0
        dc.l    0,0,0,0

_ih_is:
        dc.l    0,0
        dc.b    NT_INTERRUPT,127
        dc.l    .ih_name
        dc.l    0
        dc.l    .ih_code
.ih_code:
        ; swallow all input events, but remember the last key pressed
        ; (the player polls _lastkey once per frame: no cost while playing)
        move.l  a0,d0
.loop:  cmp.b   #IECLASS_RAWKEY,ie_Class(a0)
        bne.s   .null
        move.w  ie_Code(a0),d1
        btst    #7,d1                   ; key released
        bne.s   .null
        btst    #9-8,ie_Qualifier(a0)   ; IEQUALIFIER_REPEAT: auto-repeat
        bne.s   .null
        move.b  d1,_lastkey
.null:  move.b  #IECLASS_NULL,ie_Class(a0)
        move.l  (a0),a0
        move.l  a0,d1
        bne.b   .loop
        rts
.ih_name:
        dc.b    'eat-events inputhandler',0
        even

; ============================================================== main

; in: a0 = argument string. out: d0 = 0
_main:
        movem.l d2-d7/a2-a6,-(sp)
        lea     vars,a4
        lea     $DFF000,a5
        move.l  a0,a2

        move.l  4.w,a6
        lea     dosname(pc),a1
        moveq   #0,d0
        jsr     _LVOOpenLibrary(a6)
        move.l  d0,v_dos(a4)
        beq     .nodos

        move.l  a2,a0
        bsr     ParseArgs
        tst.l   d0
        bne     .error

        bsr     DetectMachine

        move.l  v_dos(a4),a6
        move.l  #vidfile,d1
        move.l  #MODE_OLDFILE,d2
        jsr     _LVOOpen(a6)
        move.l  d0,v_fh(a4)
        bne.s   .opened
        lea     msg_open(pc),a0
        bsr     AddMsg
        lea     vidfile,a0
        bsr     AddMsg
        lea     msg_nl(pc),a0
        bsr     AddMsg
        bra     .failed
.opened
        bsr     ReadHeader
        tst.l   d0
        bne     .error
        bsr     CheckHeader
        tst.l   d0
        bne     .error
        bsr     AllocBuffers
        tst.l   d0
        bne     .error
        bsr     InitSeek

        bsr     SetupDisplay
        bsr     HardwareOn
        tst.b   v_bench(a4)
        beq.s   .play
        bsr     Bench
        bsr     HardwareOff
        bsr     BenchReport
        bra.s   .cleanup
.play   bsr     Play
        bsr     HardwareOff
        bra.s   .cleanup

.error  move.l  d0,a0
        bsr     AddMsg
.failed st      _failed
.cleanup
        move.l  v_dos(a4),a6
        move.l  v_fh(a4),d1
        beq.s   .nofile
        jsr     _LVOClose(a6)
.nofile move.l  v_buf(a4),d0
        beq.s   .nomem
        move.l  d0,a1
        move.l  v_bufalloc(a4),d0
        move.l  4.w,a6
        jsr     _LVOFreeMem(a6)
.nomem  move.l  v_dos(a4),a1
        move.l  4.w,a6
        jsr     _LVOCloseLibrary(a6)
.nodos  movem.l (sp)+,d2-d7/a2-a6
        moveq   #0,d0
        rts

; DetectMachine - AGA chipset? PAL or NTSC?
DetectMachine:
        sf      v_aga(a4)
        move.l  _GfxBase(pc),a0
        cmp.w   #39,LIB_VERSION(a0)     ; ChipRevBits0 needs Kickstart 3.0
        blo.s   .noaga
        btst    #2,gb_ChipRevBits0(a0)  ; GFXB_AA_ALICE
        beq.s   .noaga
        st      v_aga(a4)
.noaga  move.l  4.w,a0
        cmp.b   #50,VBlankFrequency(a0)
        seq     v_pal(a4)
        rts

; ReadHeader - read and normalise the file header. Out: d0 = 0 or message
ReadHeader:
        move.l  v_dos(a4),a6
        move.l  v_fh(a4),d1
        lea     v_hdr(a4),a0
        move.l  a0,d2
        moveq   #14,d3
        jsr     _LVORead(a6)
        cmp.l   #14,d0
        bne.s   .bad
        move.l  v_hdr+H_MAGIC(a4),d0
        cmp.l   #'HAMV',d0
        bne.s   .new
        move.w  #14,v_hdrsize(a4)
        bsr     FixOldHeader
        moveq   #0,d0
        rts
.new    cmp.l   #'HAM2',d0
        bne.s   .bad
        move.l  v_fh(a4),d1
        lea     v_hdr+14(a4),a0
        move.l  a0,d2
        moveq   #6,d3
        jsr     _LVORead(a6)
        cmp.l   #6,d0
        bne.s   .bad
        move.w  #20,v_hdrsize(a4)
        moveq   #0,d0
        rts
.bad    lea     msg_badhdr(pc),a0
        move.l  a0,d0
        rts

; AllocBuffers - 3 frame buffers in chip RAM (2 if memory is short)
AllocBuffers:
        move.l  d2,-(sp)
        move.l  4.w,a6
        move.w  #3,v_nbuf(a4)
.try    move.l  v_bufsize(a4),d0        ; nbuf * bufsize
        move.l  d0,d2
        move.w  v_nbuf(a4),d1
        subq.w  #2,d1
.mul    add.l   d2,d0
        dbf     d1,.mul
        move.l  d0,v_bufalloc(a4)
        move.l  #MEMF_CHIP_CLEAR,d1
        jsr     _LVOAllocMem(a6)
        move.l  d0,v_buf(a4)
        bne.s   .ok
        cmp.w   #2,v_nbuf(a4)
        beq.s   .fail
        move.w  #2,v_nbuf(a4)
        bra.s   .try
.ok     clr.w   v_cur(a4)
        moveq   #0,d0
        move.l  (sp)+,d2
        rts
.fail   lea     msg_nomem(pc),a0
        move.l  a0,d0
        move.l  (sp)+,d2
        rts

; HardwareOn - take over the display and the audio channels 0 and 1
HardwareOn:
        move.w  $1C(a5),d0              ; INTENAR
        and.w   #$0180,d0
        move.w  d0,v_intena(a4)
        move.w  $10(a5),d0              ; ADKCONR
        and.w   #$00FF,d0
        move.w  d0,v_adkcon(a4)
        move.w  $02(a5),d0              ; DMACONR
        and.w   #$0020,d0
        move.w  d0,v_dmacon(a4)

        move.w  #$0003,$96(a5)          ; audio 0/1 DMA off
        move.w  #$0180,$9A(a5)          ; no audio 0/1 interrupts
        move.w  #$0180,$9C(a5)          ; clear pending requests
        move.w  #$00FF,$9E(a5)          ; no audio modulation
        move.w  #$0020,$96(a5)          ; sprites off
        moveq   #0,d0
        move.l  d0,$144(a5)
        move.l  d0,$14C(a5)
        move.l  d0,$154(a5)
        move.l  d0,$15C(a5)
        move.l  d0,$164(a5)
        move.l  d0,$16C(a5)
        move.l  d0,$174(a5)
        move.l  d0,$17C(a5)

        move.l  v_buf(a4),a0            ; buffer 0 (cleared) is shown first
        bsr     SetPlanes
        lea     CopperList,a0
        move.l  a0,$80(a5)
        clr.w   $88(a5)
        rts

; HardwareOff - give everything back as it was
HardwareOff:
        move.w  #$0003,$96(a5)          ; audio 0/1 DMA off
        move.w  #$0180,$9C(a5)          ; clear pending requests
        move.w  v_intena(a4),d0
        or.w    #$8000,d0
        move.w  d0,$9A(a5)              ; restore audio interrupts
        move.w  #$00FF,$9E(a5)
        move.w  v_adkcon(a4),d0
        or.w    #$8000,d0
        move.w  d0,$9E(a5)              ; restore ADKCON
        move.w  v_dmacon(a4),d0
        or.w    #$8000,d0
        move.w  d0,$96(a5)              ; sprites back if they were on
        rts

; ReadFrame - read the next frame into the next buffer
; Out: a2 = buffer, Z set if the frame was read completely
ReadFrame:
        bsr     NextBuffer
        move.l  v_dos(a4),a6
        move.l  v_fh(a4),d1
        move.l  a2,d2
        move.l  v_framesize(a4),d3
        jsr     _LVORead(a6)
        cmp.l   v_framesize(a4),d0
        bne.s   .short
        addq.l  #1,v_frameno(a4)
        moveq   #0,d0                   ; Z set
.short  rts

; InitSeek - number of frames in the file and in 10 seconds
InitSeek:
        move.l  v_dos(a4),a6
        move.l  v_fh(a4),d1
        moveq   #0,d2
        moveq   #OFFSET_END,d3
        jsr     _LVOSeek(a6)            ; go to the end...
        move.l  v_fh(a4),d1
        moveq   #0,d2
        move.w  v_hdrsize(a4),d2
        moveq   #OFFSET_BEGINNING,d3
        jsr     _LVOSeek(a6)            ; ...and back: returns the length
        bsr     CalcTotal
        bsr     CalcSkip
        clr.l   v_frameno(a4)
        rts

; DoSeek - d0 = frame to jump to (signed, clamped to the file)
DoSeek:
        bsr     SeekTarget              ; d0 = frame, d1 = position
        move.l  d0,v_frameno(a4)
        move.l  d1,d2
        move.l  v_dos(a4),a6
        move.l  v_fh(a4),d1
        moveq   #OFFSET_BEGINNING,d3
        jsr     _LVOSeek(a6)
        move.w  #$0003,$96(a5)          ; drop the queued sound: playback
        move.w  #$0180,$9C(a5)          ; restarts with the next frame read
        rts

; HandleKeys - act on the last key pressed, if any
HandleKeys:
        move.b  _lastkey,d0
        beq.s   .none
        clr.b   _lastkey
        cmp.b   #$45,d0                 ; Esc
        beq.s   .quit
        cmp.b   #$10,d0                 ; Q
        beq.s   .quit
        cmp.b   #$40,d0                 ; Space
        beq.s   .pause
        moveq   #1,d1                   ; 10 s
        cmp.b   #$4E,d0                 ; cursor right
        beq.s   .fwd
        cmp.b   #$4F,d0                 ; cursor left
        beq.s   .back
        moveq   #6,d1                   ; 1 min
        cmp.b   #$4C,d0                 ; cursor up
        beq.s   .fwd
        cmp.b   #$4D,d0                 ; cursor down
        beq.s   .back
.none   rts
.fwd    move.l  v_skip(a4),d0
        bsr     Mul32
        add.l   v_frameno(a4),d0
        bra     DoSeek
.back   move.l  v_skip(a4),d0
        bsr     Mul32
        neg.l   d0
        add.l   v_frameno(a4),d0
        subq.l  #1,d0                   ; the frame on screen, not the next one
        bra     DoSeek
.pause  bra     PauseLoop
.quit   st      v_quit(a4)
        rts

; Play - the sound drives the timing: a frame is shown when Paula starts
; playing its sound block, so picture and sound cannot drift apart.
Play:
.loop   bsr     HandleKeys
        tst.b   v_quit(a4)
        bne     .end
        bsr     ReadFrame
        bne     .end
        btst    #10-8,$16(a5)           ; right button: pause
        bne.s   .noclick
        bsr     PauseLoop
        tst.b   v_quit(a4)
        bne     .end
.noclick
        ; queue the sound block of this frame (Paula takes it when the
        ; current block ends, or at once if the sound was stopped)
        move.l  a2,d2
        add.l   v_videosize(a4),d2
        move.l  d2,$A0(a5)              ; AUD0LC (left)
        moveq   #0,d1
        move.w  v_hdr+H_AUDBYTES(a4),d1
        cmp.w   #2,v_hdr+H_CHANNELS(a4)
        bne.s   .mono
        add.l   d1,d2                   ; right channel follows
.mono   move.l  d2,$B0(a5)              ; AUD1LC (right)
        lsr.l   #1,d1
        move.w  d1,$A4(a5)              ; AUD0LEN in words
        move.w  d1,$B4(a5)
        move.w  v_period(a4),d0
        move.w  d0,$A6(a5)              ; AUD0PER
        move.w  d0,$B6(a5)
        move.w  #64,$A8(a5)             ; full volume
        move.w  #64,$B8(a5)
        move.w  #$8203,$96(a5)          ; audio 0/1 DMA on

        ; wait until Paula starts this block, then show the picture
.wait   move.w  $1E(a5),d0              ; INTREQR
        btst    #7,d0                   ; AUD0
        bne.s   .started
        btst    #6,$BFE001              ; left button: quit
        beq.s   .end
        bra.s   .wait
.started
        move.w  #$0180,$9C(a5)
        move.l  a2,a0
        bsr     SetPlanes               ; shown from the next vertical blank

        ; with only 2 buffers, the next read goes into the buffer still
        ; on screen until the vertical blank: wait for it
        cmp.w   #2,v_nbuf(a4)
        bne.s   .nowait
        move.l  _GfxBase(pc),a6
        jsr     _LVOWaitTOF(a6)
.nowait btst    #6,$BFE001
        bne     .loop
.end    rts

; PauseLoop - silence until Space or the right button; arrows and
; Esc are also handled. Waits with WaitTOF: other tasks keep running.
PauseLoop:
        move.w  #$0003,$96(a5)          ; silence
.rel1   btst    #10-8,$16(a5)           ; right button released?
        beq.s   .rel1
.wait   move.l  _GfxBase(pc),a6
        jsr     _LVOWaitTOF(a6)
        btst    #6,$BFE001              ; left button: quit
        beq.s   .quit
        btst    #10-8,$16(a5)           ; right button: resume
        beq.s   .rmb
        move.b  _lastkey,d0
        beq.s   .wait
        clr.b   _lastkey
        cmp.b   #$40,d0                 ; Space: resume
        beq.s   .resume
        cmp.b   #$45,d0                 ; Esc
        beq.s   .quit
        cmp.b   #$10,d0                 ; Q
        beq.s   .quit
        cmp.b   #$4C,d0                 ; cursor keys: resume and seek
        blo.s   .wait
        cmp.b   #$4F,d0
        bhi.s   .wait
        move.b  d0,_lastkey             ; handled by HandleKeys
        bra.s   .resume
.rmb    btst    #10-8,$16(a5)
        beq.s   .rmb
.resume move.w  #$0180,$9C(a5)
        rts
.quit   st      v_quit(a4)
        rts

; Bench - read and show the frames as fast as possible, without sound
Bench:
        move.l  v_dos(a4),a6
        lea     v_ds1(a4),a0
        move.l  a0,d1
        jsr     _LVODateStamp(a6)
        clr.l   v_frames(a4)
.loop   bsr     ReadFrame
        bne.s   .end
        move.l  a2,a0
        bsr     SetPlanes
        addq.l  #1,v_frames(a4)
        btst    #6,$BFE001              ; left button or Esc: stop
        beq.s   .end
        cmp.b   #$45,_lastkey
        bne.s   .loop
.end    move.l  v_dos(a4),a6
        lea     v_ds2(a4),a0
        move.l  a0,d1
        jsr     _LVODateStamp(a6)
        rts

; PrintMessages - write msgbuf to the CLI, or to a window from Workbench
PrintMessages:
        movem.l d2-d7/a2-a6,-(sp)
        lea     vars,a4
        tst.w   v_msglen(a4)
        beq.s   .none
        move.l  4.w,a6
        lea     dosname(pc),a1
        moveq   #0,d0
        jsr     _LVOOpenLibrary(a6)
        tst.l   d0
        beq.s   .none
        move.l  d0,a6
        moveq   #0,d7                   ; console opened by us
        tst.l   _WBenchMsg
        bne.s   .wb
        jsr     _LVOOutput(a6)
        move.l  d0,d6
        bne.s   .write
.wb     move.l  #conname,d1
        move.l  #MODE_NEWFILE,d2
        jsr     _LVOOpen(a6)
        move.l  d0,d6
        beq.s   .close
        move.l  d0,d7
.write  move.l  d6,d1
        move.l  #msgbuf,d2
        moveq   #0,d3
        move.w  v_msglen(a4),d3
        jsr     _LVOWrite(a6)
        tst.l   d7
        beq.s   .close
        move.l  #500,d1                 ; leave 10 s to read it
        jsr     _LVODelay(a6)
        move.l  d7,d1
        jsr     _LVOClose(a6)
.close  move.l  a6,a1
        move.l  4.w,a6
        jsr     _LVOCloseLibrary(a6)
.none   movem.l (sp)+,d2-d7/a2-a6
        rts

        include "hamplay_core.s"

; ================================================================ data

        section bss,bss
vars            ds.b    v_size
        even
vidfile         ds.b    NAMEMAX+1
tokbuf          ds.b    NAMEMAX+1
numbuf          ds.b    12
msgbuf          ds.b    MSGMAX+2

        section chipdata,data_c

CopperList:
        dc.w    $1FC,0                  ; FMODE: 1x fetch (AGA)
        dc.w    $106,0                  ; BPLCON3: palette bank 0 (ECS/AGA)
        dc.w    $10C,$0011              ; BPLCON4: no bitplane XOR (AGA)
cl_bplcon0
        dc.w    $100,$6A00              ; BPLCON0: HAM, colour burst, planes
        dc.w    $102,0                  ; BPLCON1
        dc.w    $104,0                  ; BPLCON2
cl_mod  dc.w    $108,0                  ; BPL1MOD
        dc.w    $10A,0                  ; BPL2MOD
cl_ddf  dc.w    $92,$38                 ; DDFSTRT
        dc.w    $94,$D0                 ; DDFSTOP
cl_diw  dc.w    $8E,$2C81               ; DIWSTRT
        dc.w    $90,$2CC1               ; DIWSTOP
        ; base palette: the converters choose among these 16 colours
        dc.w    $180,$0000,$182,$000A,$184,$00A0,$186,$00AA
        dc.w    $188,$0A00,$18A,$0A0A,$18C,$0AA0,$18E,$0AAA
        dc.w    $190,$0555,$192,$055F,$194,$05F5,$196,$05FF
        dc.w    $198,$0F55,$19A,$0F5F,$19C,$0FF5,$19E,$0FFF
cl_planes
        dc.w    $E0,0,$E2,0,$E4,0,$E6,0,$E8,0,$EA,0,$EC,0,$EE,0
        dc.w    $F0,0,$F2,0,$F4,0,$F6,0,$F8,0,$FA,0,$FC,0,$FE,0
        dc.w    $FFFF,$FFFE
