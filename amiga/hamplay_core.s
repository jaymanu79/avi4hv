;
; hamplay_core.s - hardware-independent routines of HAMPLAY
; (argument parsing, header checks, display layout, number formatting).
; Kept separate so they can be unit-tested on a 68000 emulator.
;
; Conventions: a4 = vars, routines preserve d2-d7/a2-a6 unless stated.
;

; ---------------------------------------------------------------- vars

        rsreset
v_dos           rs.l 1          ; dos.library base
v_fh            rs.l 1          ; video file handle
v_buf           rs.l 1          ; chip RAM buffers (nbuf * bufsize)
v_bufalloc      rs.l 1          ; size allocated
v_bufsize       rs.l 1          ; size of one buffer (multiple of 8)
v_framesize     rs.l 1          ; picture + sound of one frame
v_videosize     rs.l 1          ; picture of one frame
v_frames        rs.l 1          ; frames read (benchmark)
v_frameno       rs.l 1          ; number of the next frame to read
v_total         rs.l 1          ; frames in the file
v_skip          rs.l 1          ; frames in 10 seconds
v_ds1           rs.l 3          ; DateStamp at benchmark start
v_ds2           rs.l 3          ; DateStamp at benchmark end
v_nbuf          rs.w 1          ; number of buffers (2 or 3)
v_cur           rs.w 1          ; buffer being filled
v_planebytes    rs.w 1          ; hres / 8
v_period        rs.w 1          ; audio period for this machine
v_intena        rs.w 1          ; saved audio interrupt enable bits
v_adkcon        rs.w 1          ; saved ADKCON bits
v_dmacon        rs.w 1          ; saved sprite DMA bit
v_msglen        rs.w 1          ; length of the text in msgbuf
v_hdrsize       rs.w 1          ; 14 (HAMV) or 20 (HAM2)
v_bench         rs.b 1          ; benchmark mode
v_aga           rs.b 1          ; AGA chipset present
v_pal           rs.b 1          ; PAL machine
v_quit          rs.b 1          ; user asked to quit
v_hdr           rs.b 20         ; file header, see H_xxx
v_size          rs.b 0

; header fields (HAM2 layout; HAMV files are converted to it)
H_MAGIC         equ 0           ; 'HAMV' (old) or 'HAM2'
H_AUDBYTES      equ 4           ; audio samples per frame and channel
H_PERIOD        equ 6           ; audio period (for the clock given by flags)
H_CHANNELS      equ 8           ; 1 or 2
H_VRES          equ 10
H_HRES          equ 12
H_PLANES        equ 14          ; 6 (HAM6) or 8 (HAM8)
H_FLAGS         equ 16          ; bit 0: period computed for the PAL clock
H_RESERVED      equ 18

MSGMAX          equ 2000
NAMEMAX         equ 255
MIN_PERIOD      equ 124         ; fastest period Paula DMA can handle

; ---------------------------------------------------------- messages

; AddMsg - append the null-terminated string a0 to msgbuf
AddMsg:
        movem.l a0-a1/d0,-(sp)
        lea     msgbuf,a1
        move.w  v_msglen(a4),d0
        adda.w  d0,a1
.loop   tst.b   (a0)
        beq.s   .end
        cmp.w   #MSGMAX,d0
        bhs.s   .end
        move.b  (a0)+,(a1)+
        addq.w  #1,d0
        bra.s   .loop
.end    move.w  d0,v_msglen(a4)
        movem.l (sp)+,a0-a1/d0
        rts

; AddNum - append d0 (unsigned 32-bit) in decimal
AddNum:
        movem.l d0-d2/a0,-(sp)
        lea     numbuf+12,a0
        clr.b   -(a0)
.loop   moveq   #10,d1
        bsr     Div32           ; d0 = d0 / 10, d1 = remainder
        add.b   #'0',d1
        move.b  d1,-(a0)
        tst.l   d0
        bne.s   .loop
        bsr     AddMsg
        movem.l (sp)+,d0-d2/a0
        rts

; AddFix2 - append d0 / 100 with two decimals (d0 = value * 100)
AddFix2:
        movem.l d0-d1/a0,-(sp)
        moveq   #100,d1
        bsr     Div32
        bsr     AddNum          ; integer part
        lea     .dot(pc),a0
        bsr     AddMsg
        move.l  d1,d0
        cmp.l   #10,d0
        bhs.s   .two
        lea     .zero(pc),a0
        bsr     AddMsg
.two    bsr     AddNum
        movem.l (sp)+,d0-d1/a0
        rts
.dot    dc.b    '.',0
.zero   dc.b    '0',0
        even

; ------------------------------------------------------------- maths

; Div32 - unsigned d0 / d1 -> d0 quotient, d1 remainder (d1 <> 0)
Div32:
        movem.l d2-d3,-(sp)
        moveq   #0,d2           ; remainder
        moveq   #31,d3
.loop   add.l   d0,d0           ; shift dividend left, top bit into X
        addx.l  d2,d2
        cmp.l   d1,d2
        blo.s   .next
        sub.l   d1,d2
        addq.l  #1,d0
.next   dbf     d3,.loop
        move.l  d2,d1
        movem.l (sp)+,d2-d3
        rts

; Mul32 - d0 = d0 * d1 (low 32 bits, unsigned)
Mul32:
        movem.l d2-d3,-(sp)
        move.l  d0,d2
        move.l  d0,d3
        swap    d3
        mulu.w  d1,d3           ; a_hi * b_lo
        swap    d1
        mulu.w  d1,d2           ; a_lo * b_hi
        add.w   d3,d2
        swap    d2
        clr.w   d2
        swap    d1
        mulu.w  d1,d0           ; a_lo * b_lo
        add.l   d2,d0
        movem.l (sp)+,d2-d3
        rts

; --------------------------------------------------------- arguments

; ParseArgs - a0 = command line (ends with LF or NUL)
; Accepts: [BENCH] file   (file may be "quoted"), in any order.
; Out: d0 = 0 if ok, else pointer to an error message.
ParseArgs:
        movem.l d2/a2-a3,-(sp)
        lea     vidfile,a2
        clr.b   (a2)
        sf      v_bench(a4)
.next   move.b  (a0),d0         ; skip blanks
        cmp.b   #' ',d0
        beq.s   .skip
        cmp.b   #9,d0
        bne.s   .tok
.skip   addq.l  #1,a0
        bra.s   .next
.tok    tst.b   d0
        beq     .done
        cmp.b   #10,d0
        beq     .done
        ; copy one token into tokbuf
        lea     tokbuf,a3
        moveq   #0,d2           ; length
        cmp.b   #'"',d0
        bne.s   .plain
        addq.l  #1,a0           ; quoted token
.qloop  move.b  (a0),d0
        beq.s   .tokend
        cmp.b   #10,d0
        beq.s   .tokend
        addq.l  #1,a0
        cmp.b   #'"',d0
        beq.s   .tokend
        bsr.s   .store
        bra.s   .qloop
.plain  move.b  (a0),d0
        beq.s   .tokend
        cmp.b   #10,d0
        beq.s   .tokend
        cmp.b   #' ',d0
        beq.s   .tokend
        cmp.b   #9,d0
        beq.s   .tokend
        addq.l  #1,a0
        bsr.s   .store
        bra.s   .plain
.tokend clr.b   (a3)
        ; keyword?
        move.l  a0,-(sp)
        lea     tokbuf,a0
        lea     kw_bench(pc),a1
        bsr     StrCaseEq
        move.l  (sp)+,a0
        tst.b   d0
        beq.s   .notkw
        st      v_bench(a4)
        bra     .next
.notkw  cmp.b   #'?',tokbuf
        beq.s   .usage
        tst.b   (a2)
        bne.s   .usage          ; two file names
        ; copy tokbuf into vidfile
        lea     tokbuf,a1
        move.l  a2,a3
.cpy    move.b  (a1)+,(a3)+
        bne.s   .cpy
        bra     .next
.done   tst.b   (a2)
        beq.s   .usage
        moveq   #0,d0
        bra.s   .out
.usage  lea     msg_usage(pc),a0
        move.l  a0,d0
.out    movem.l (sp)+,d2/a2-a3
        rts
.store  cmp.w   #NAMEMAX,d2
        bhs.s   .full
        move.b  d0,(a3)+
        addq.w  #1,d2
.full   rts

; StrCaseEq - compare a0 with a1 (a1 in upper case) -> d0.b = -1 if equal
StrCaseEq:
.loop   move.b  (a0)+,d0
        cmp.b   #'a',d0
        blo.s   .cmp
        cmp.b   #'z',d0
        bhi.s   .cmp
        sub.b   #32,d0
.cmp    cmp.b   (a1)+,d0
        bne.s   .no
        tst.b   d0
        bne.s   .loop
        moveq   #-1,d0
        rts
.no     moveq   #0,d0
        rts

; EndsWithH8V - d0.b = -1 if vidfile ends with ".h8v" (any case)
EndsWithH8V:
        move.l  a0,-(sp)
        lea     vidfile,a0
.end    tst.b   (a0)+
        bne.s   .end
        subq.l  #1,a0           ; on the NUL
        move.l  a0,d0
        sub.l   #vidfile,d0
        cmp.l   #4,d0
        blo.s   .no
        lea     -4(a0),a0
        lea     ext_h8v(pc),a1
        bsr     StrCaseEq
        bra.s   .out
.no     moveq   #0,d0
.out    move.l  (sp)+,a0
        rts

; ------------------------------------------------------------- header

; FixOldHeader - complete a 'HAMV' header (old format): HAM8 if the
; file name ends with .h8v, HAM6 otherwise; period for the NTSC clock.
FixOldHeader:
        move.w  #6,v_hdr+H_PLANES(a4)
        bsr     EndsWithH8V
        tst.b   d0
        beq.s   .ham6
        move.w  #8,v_hdr+H_PLANES(a4)
.ham6   clr.w   v_hdr+H_FLAGS(a4)
        clr.w   v_hdr+H_RESERVED(a4)
        rts

; CheckHeader - validate v_hdr, compute the frame layout and the audio
; period for this machine. Out: d0 = 0 or error message.
CheckHeader:
        movem.l d2-d3/a0,-(sp)
        lea     v_hdr(a4),a0
        ; width
        move.w  H_HRES(a0),d0
        cmp.w   #288,d0
        beq.s   .wok
        cmp.w   #304,d0
        beq.s   .wok
        cmp.w   #320,d0
        beq.s   .wok
        cmp.w   #336,d0
        bne     .bad
.wok    move.w  H_VRES(a0),d0
        beq     .bad
        cmp.w   #256,d0
        bhi     .bad
        move.w  H_CHANNELS(a0),d0
        beq     .bad
        cmp.w   #2,d0
        bhi     .bad
        move.w  H_PLANES(a0),d0
        cmp.w   #6,d0
        beq.s   .pok
        cmp.w   #8,d0
        bne     .bad
        tst.b   v_aga(a4)
        bne.s   .pok
        lea     msg_needaga(pc),a0
        move.l  a0,d0
        bra     .out
.pok    move.w  H_AUDBYTES(a0),d0
        beq     .bad
        btst    #0,d0
        bne     .bad
        tst.w   H_PERIOD(a0)
        beq     .bad

        ; audio period: convert between the PAL and NTSC clocks if needed
        moveq   #0,d0
        move.w  H_PERIOD(a0),d0
        move.w  H_FLAGS(a0),d1
        and.w   #1,d1           ; 1 = file made for PAL
        moveq   #0,d2
        tst.b   v_pal(a4)
        beq.s   .ntsc
        moveq   #1,d2
.ntsc   cmp.w   d1,d2
        beq.s   .same
        tst.w   d2
        bne.s   .topal
        mulu.w  #33070,d0       ; PAL -> NTSC: x 3579545 / 3546895
        bra.s   .scale
.topal  mulu.w  #32469,d0       ; NTSC -> PAL: x 3546895 / 3579545
.scale  add.l   #16384,d0       ; round
        moveq   #15,d1
        lsr.l   d1,d0
.same   cmp.l   #MIN_PERIOD,d0
        bhs.s   .perok
        moveq   #MIN_PERIOD,d0
.perok  cmp.l   #$FFFF,d0
        bls.s   .perok2
        move.l  #$FFFF,d0
.perok2 move.w  d0,v_period(a4)

        ; frame layout
        move.w  H_HRES(a0),d0
        lsr.w   #3,d0
        move.w  d0,v_planebytes(a4)
        mulu.w  H_PLANES(a0),d0         ; bytes per line
        mulu.w  H_VRES(a0),d0
        move.l  d0,v_videosize(a4)
        moveq   #0,d1
        move.w  H_AUDBYTES(a0),d1
        add.l   d1,d0
        cmp.w   #2,H_CHANNELS(a0)
        bne.s   .mono
        add.l   d1,d0
.mono   move.l  d0,v_framesize(a4)
        addq.l  #7,d0
        and.w   #$FFF8,d0
        move.l  d0,v_bufsize(a4)
        moveq   #0,d0
        bra.s   .out
.bad    lea     msg_badhdr(pc),a0
        move.l  a0,d0
.out    movem.l (sp)+,d2-d3/a0
        rts

; ------------------------------------------------------------ display

; SetupDisplay - fill the copper list for the current video
SetupDisplay:
        movem.l d2-d3/a0,-(sp)
        ; BPLCON0: HAM + colour burst, 6 or 8 bitplanes
        move.w  #$6A00,d0
        cmp.w   #8,v_hdr+H_PLANES(a4)
        bne.s   .six
        move.w  #$0A10,d0
.six    move.w  d0,cl_bplcon0+2
        ; modulo: the other planes of the line are skipped
        move.w  v_hdr+H_PLANES(a4),d0
        subq.w  #1,d0
        mulu.w  v_planebytes(a4),d0
        move.w  d0,cl_mod+2
        move.w  d0,cl_mod+6
        ; data fetch start/stop, from the width
        move.w  v_planebytes(a4),d0
        add.w   d0,d0
        sub.w   #72,d0          ; 0, 4, 8 or 12
        lea     ddftable(pc),a0
        adda.w  d0,a0
        move.w  (a0)+,cl_ddf+2
        move.w  (a0),cl_ddf+6
        ; display window, centred
        move.w  #$90,d2         ; NTSC centre line
        tst.b   v_pal(a4)
        beq.s   .ntsc
        move.w  #$AC,d2         ; PAL centre line
.ntsc   move.w  v_hdr+H_VRES(a4),d1
        lsr.w   #1,d1
        move.w  d2,d0
        sub.w   d1,d0           ; vertical start
        lsl.w   #8,d0
        move.w  v_hdr+H_HRES(a4),d3
        lsr.w   #1,d3
        move.w  #$120,d1
        sub.w   d3,d1           ; horizontal start
        move.b  d1,d0
        move.w  d0,cl_diw+2
        move.w  v_hdr+H_VRES(a4),d0
        lsr.w   #1,d0
        add.w   d2,d0           ; vertical stop
        lsl.w   #8,d0
        moveq   #$20,d1
        add.w   d3,d1           ; horizontal stop
        move.b  d1,d0
        move.w  d0,cl_diw+6
        movem.l (sp)+,d2-d3/a0
        rts

; SetPlanes - point the copper list's bitplane pointers to buffer a0
SetPlanes:
        movem.l d0-d2/a1,-(sp)
        move.l  a0,d0
        moveq   #0,d1
        move.w  v_planebytes(a4),d1
        lea     cl_planes,a1
        moveq   #8-1,d2
.loop   move.w  d0,6(a1)
        swap    d0
        move.w  d0,2(a1)
        swap    d0
        add.l   d1,d0
        addq.l  #8,a1
        dbf     d2,.loop
        movem.l (sp)+,d0-d2/a1
        rts

; NextBuffer - advance to the next buffer -> a2 = its address
NextBuffer:
        move.w  v_cur(a4),d0
        addq.w  #1,d0
        cmp.w   v_nbuf(a4),d0
        blo.s   .ok
        moveq   #0,d0
.ok     move.w  d0,v_cur(a4)
        move.l  v_buf(a4),a2
        bra.s   .test
.add    add.l   v_bufsize(a4),a2
.test   dbf     d0,.add
        rts

; ------------------------------------------------------------- seeking

; CalcSkip - v_skip = number of frames in 10 seconds (at least 1)
CalcSkip:
        move.l  #35795450,d0            ; NTSC clock x10
        tst.b   v_pal(a4)
        beq.s   .ntsc
        move.l  #35468950,d0            ; PAL clock x10
.ntsc   move.w  v_period(a4),d1
        mulu.w  v_hdr+H_AUDBYTES(a4),d1 ; clock ticks per frame
        bsr     Div32
        tst.l   d0
        bne.s   .ok
        moveq   #1,d0
.ok     move.l  d0,v_skip(a4)
        rts

; CalcTotal - d0 = file length -> v_total = number of whole frames
CalcTotal:
        moveq   #0,d1
        move.w  v_hdrsize(a4),d1
        sub.l   d1,d0
        bcc.s   .pos
        moveq   #0,d0
.pos    move.l  v_framesize(a4),d1
        bsr     Div32
        move.l  d0,v_total(a4)
        rts

; SeekTarget - d0 = wanted frame (signed) -> d0 = frame clamped to the
; file, d1 = its position in the file
SeekTarget:
        tst.l   d0
        bpl.s   .notneg
        moveq   #0,d0
.notneg move.l  v_total(a4),d1
        beq.s   .zero
        cmp.l   d1,d0
        blo.s   .inside
        move.l  d1,d0
        subq.l  #1,d0                   ; last frame
        bra.s   .inside
.zero   moveq   #0,d0
.inside move.l  d0,-(sp)
        move.l  v_framesize(a4),d1
        bsr     Mul32
        moveq   #0,d1
        move.w  v_hdrsize(a4),d1
        add.l   d0,d1
        move.l  (sp)+,d0
        rts

; ---------------------------------------------------------- benchmark

; BenchReport - append the benchmark results to the messages
BenchReport:
        movem.l d2-d5/a0,-(sp)
        ; elapsed ticks (1/50 s)
        move.l  v_ds2(a4),d0            ; days
        sub.l   v_ds1(a4),d0
        move.l  #1440*3000,d1
        bsr     Mul32
        move.l  d0,d2
        move.l  v_ds2+4(a4),d0          ; minutes
        sub.l   v_ds1+4(a4),d0
        move.l  #3000,d1
        bsr     Mul32
        add.l   d0,d2
        add.l   v_ds2+8(a4),d2          ; ticks
        sub.l   v_ds1+8(a4),d2
        bgt.s   .tok
        moveq   #1,d2
.tok    ; d2 = elapsed ticks

        lea     msg_b1(pc),a0           ; "Read "
        bsr     AddMsg
        move.l  v_frames(a4),d0
        bsr     AddNum
        lea     msg_b2(pc),a0           ; " frames of "
        bsr     AddMsg
        move.l  v_framesize(a4),d0
        bsr     AddNum
        lea     msg_b3(pc),a0           ; " bytes in "
        bsr     AddMsg
        move.l  d2,d0
        add.l   d0,d0                   ; hundredths of a second
        bsr     AddFix2
        lea     msg_b4(pc),a0           ; " s"
        bsr     AddMsg

        ; measured frames per second x100
        move.l  v_frames(a4),d0
        move.l  #5000,d1
        bsr     Mul32
        move.l  d2,d1
        bsr     Div32
        move.l  d0,d3                   ; d3 = measured fps x100
        ; KB/s = frames * framesize / ticks * 50 / 1024
        move.l  v_frames(a4),d0
        move.l  v_framesize(a4),d1
        bsr     Mul32
        move.l  d2,d1
        bsr     Div32                   ; bytes per tick
        moveq   #50,d1
        bsr     Mul32
        moveq   #10,d1
        lsr.l   d1,d0                   ; KB/s
        lea     msg_b5(pc),a0           ; "Speed: "
        bsr     AddMsg
        bsr     AddNum
        lea     msg_b6(pc),a0           ; " KB/s = "
        bsr     AddMsg
        move.l  d3,d0
        bsr     AddFix2
        lea     msg_b7(pc),a0           ; " frames/s max"
        bsr     AddMsg

        ; frame rate of this video x100 = clock * 100 / (period * audbytes)
        move.l  #357954500,d0           ; NTSC clock x100
        tst.b   v_pal(a4)
        beq.s   .ntsc
        move.l  #354689500,d0           ; PAL clock x100
.ntsc   move.w  v_period(a4),d1
        mulu.w  v_hdr+H_AUDBYTES(a4),d1
        bsr     Div32
        move.l  d0,d4                   ; d4 = needed fps x100
        lea     msg_b8(pc),a0           ; "This video: "
        bsr     AddMsg
        move.l  d4,d0
        bsr     AddFix2
        lea     msg_b9(pc),a0           ; " frames/s, "
        bsr     AddMsg
        move.l  d4,d0
        move.l  v_framesize(a4),d1
        bsr     Mul32
        move.l  #102400,d1
        bsr     Div32
        bsr     AddNum
        lea     msg_b10(pc),a0          ; " KB/s -> "
        bsr     AddMsg
        lea     msg_ok(pc),a0
        cmp.l   d4,d3
        bhs.s   .verdict
        lea     msg_slow(pc),a0
.verdict
        bsr     AddMsg
        bsr     AddMachine
        movem.l (sp)+,d2-d5/a0
        rts

; AddMachine - append "Machine: AGA/OCS-ECS, PAL/NTSC"
AddMachine:
        move.l  a0,-(sp)
        lea     msg_mach(pc),a0
        bsr     AddMsg
        lea     msg_ocs(pc),a0
        tst.b   v_aga(a4)
        beq.s   .1
        lea     msg_aga(pc),a0
.1      bsr     AddMsg
        lea     msg_ntsc(pc),a0
        tst.b   v_pal(a4)
        beq.s   .2
        lea     msg_palm(pc),a0
.2      bsr     AddMsg
        move.l  (sp)+,a0
        rts

; ----------------------------------------------------------- constants

ddftable                        ; DDFSTRT, DDFSTOP for 288/304/320/336
        dc.w    $40,$C8
        dc.w    $38,$C8
        dc.w    $38,$D0
        dc.w    $30,$D0

kw_bench        dc.b    'BENCH',0
ext_h8v         dc.b    '.H8V',0
msg_usage       dc.b    'Usage: HAMPLAY [BENCH] <file.hv|file.h8v>',10
                dc.b    '  BENCH: read the file as fast as possible and report the speed',10
                dc.b    'Keys: Space pause, Left/Right -/+10 s, Down/Up -/+1 min, Esc quit',10
                dc.b    'Mouse: right button pause, left button quit',10,0
msg_badhdr      dc.b    'Not a HAM video, or unsupported format',10,0
msg_needaga     dc.b    'This video is HAM8 and needs an AGA Amiga',10,0
msg_open        dc.b    'Cannot open ',0
msg_nomem       dc.b    'Not enough chip RAM',10,0
msg_nl          dc.b    10,0
msg_b1          dc.b    'Read ',0
msg_b2          dc.b    ' frames of ',0
msg_b3          dc.b    ' bytes in ',0
msg_b4          dc.b    ' s',10,0
msg_b5          dc.b    'Speed: ',0
msg_b6          dc.b    ' KB/s = ',0
msg_b7          dc.b    ' frames/s max',10,0
msg_b8          dc.b    'This video: ',0
msg_b9          dc.b    ' frames/s, ',0
msg_b10         dc.b    ' KB/s -> ',0
msg_ok          dc.b    'OK',10,0
msg_slow        dc.b    'TOO FAST for this machine',10,0
msg_mach        dc.b    'Machine: ',0
msg_aga         dc.b    'AGA, ',0
msg_ocs         dc.b    'OCS/ECS, ',0
msg_palm        dc.b    'PAL',10,0
msg_ntsc        dc.b    'NTSC',10,0
        even
