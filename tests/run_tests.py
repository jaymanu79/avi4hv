#!/usr/bin/env python3
"""Unit tests of hamplay_core.s on the Musashi 68000 emulator."""
import os, random, re, struct, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))
CORE = os.path.join(HERE, "..", "amiga", "hamplay_core.s")
VASM = os.environ.get("VASM", "vasmm68k_mot")
ORG = 0x1000
random.seed(1)

code = []      # test code
data = []      # inputs and result slots
checks = []    # (label, kind, expected, description)
n = 0

def new(prefix):
    global n
    n += 1
    return f"{prefix}{n}"

def asm_string(label, s):
    data.append(f"{label}")
    data.append("        dc.b " + ",".join(str(b) for b in s.encode("latin-1")) + ",0" if s else "        dc.b 0")
    data.append("        even")

def slot(label, size):
    data.append(f"{label}  ds.b {size}")
    data.append("        even")

def copy_str(src, dst, size=64):
    lab = new("cp")
    code.append(f"        lea {src},a0\n        lea {dst},a1\n        move.w #{size-1},d1\n.{lab} move.b (a0)+,(a1)+\n        dbf d1,.{lab}")

# ---------------------------------------------------------------- ParseArgs
def t_args(cmdline, ok, bench, name, term="\n"):
    a, r = new("arg"), new("res")
    s = cmdline + term
    data.append(a)
    data.append("        dc.b " + ",".join(str(b) for b in s.encode()) + ",0")
    data.append("        even")
    slot(r, 72)
    code.append(f"        clr.w v_msglen(a4)\n        lea {a},a0\n        bsr ParseArgs\n        move.l d0,{r}\n        move.b v_bench(a4),{r}+4")
    copy_str("vidfile", f"{r}+8")
    checks.append((r, "args", (ok, bench, name), repr(cmdline)))

t_args("video.hv", True, False, "video.hv")
t_args("  BENCH   video.h8v  ", True, True, "video.h8v")
t_args('bench "Work:My Videos/clip one.hv"', True, True, "Work:My Videos/clip one.hv")
t_args('"DH0:a b.hv" Bench', True, True, "DH0:a b.hv")
t_args("BENCH", False, True, "")
t_args("", False, False, "")
t_args("?", False, False, "")
t_args("one.hv two.hv", False, False, "one.hv")
t_args("Work:Videos/x.h8v", True, False, "Work:Videos/x.h8v", term="")   # Workbench: NUL-terminated
t_args("benchmark.hv", True, False, "benchmark.hv")
t_args("\tvid.hv\t", True, False, "vid.hv")

# ------------------------------------------------------------- header checks
NTSC, PAL = 3579545, 3546895

def ref_period(p, file_pal, mach_pal):
    if file_pal != mach_pal:
        mul = 33070 if file_pal else 32469
        p = (p * mul + 16384) >> 15
    return min(max(p, 124), 0xFFFF)

def t_hdr(magic, aud, per, ch, vres, hres, planes, flags, aga, pal, name="v.hv", expect_ok=True, expect_aga_err=False):
    r = new("hdr")
    slot(r, 64)
    nm = new("name")
    asm_string(nm, name)
    code.append(f"""        lea {nm},a0
        lea vidfile,a1
.n{r}   move.b (a0)+,(a1)+
        bne.s .n{r}
        move.l #'{magic}',v_hdr+H_MAGIC(a4)
        move.w #{aud},v_hdr+H_AUDBYTES(a4)
        move.w #{per},v_hdr+H_PERIOD(a4)
        move.w #{ch},v_hdr+H_CHANNELS(a4)
        move.w #{vres},v_hdr+H_VRES(a4)
        move.w #{hres},v_hdr+H_HRES(a4)
        move.w #{planes},v_hdr+H_PLANES(a4)
        move.w #{flags},v_hdr+H_FLAGS(a4)
        move.b #{-1 if aga else 0},v_aga(a4)
        move.b #{-1 if pal else 0},v_pal(a4)""")
    if magic == "HAMV":
        code.append("        bsr FixOldHeader")
    code.append(f"""        bsr CheckHeader
        move.l d0,{r}
        tst.l d0
        bne.s .s{r}
        bsr SetupDisplay
.s{r}   move.w v_period(a4),{r}+4
        move.l v_videosize(a4),{r}+6
        move.l v_framesize(a4),{r}+10
        move.l v_bufsize(a4),{r}+14
        move.w v_hdr+H_PLANES(a4),{r}+18
        move.w cl_bplcon0+2,{r}+20
        move.w cl_mod+2,{r}+22
        move.w cl_mod+6,{r}+24
        move.w cl_ddf+2,{r}+26
        move.w cl_ddf+6,{r}+28
        move.w cl_diw+2,{r}+30
        move.w cl_diw+6,{r}+32
        move.w v_planebytes(a4),{r}+34""")
    if magic == "HAMV":
        planes = 8 if name.lower().endswith(".h8v") else 6
        flags = 0
    exp = None
    if expect_ok:
        pb = hres // 8
        video = pb * planes * vres
        frame = video + aud * ch
        ddf = {288: (0x40, 0xC8), 304: (0x38, 0xC8), 320: (0x38, 0xD0), 336: (0x30, 0xD0)}[hres]
        centre = 0xAC if pal else 0x90
        vstart, vstop = centre - vres // 2, (centre + vres // 2) & 0xFF
        hstart, hstop = (0x120 - hres // 2) & 0xFF, (0x20 + hres // 2) & 0xFF
        exp = dict(period=ref_period(per, flags & 1, pal), video=video, frame=frame,
                   buf=(frame + 7) & ~7, planes=planes,
                   bplcon0=0x0A10 if planes == 8 else 0x6A00,
                   mod=(planes - 1) * pb, ddf=ddf,
                   diw=((vstart << 8) | hstart, (vstop << 8) | hstop), pb=pb)
    checks.append((r, "hdr", (expect_ok, expect_aga_err, exp), f"{magic} {hres}x{vres} p{planes} aga={aga} pal={pal} {name}"))

t_hdr("HAM2", 734, 324, 1, 216, 320, 6, 0, False, False)               # HAM6 NTSC file, NTSC machine
t_hdr("HAM2", 734, 324, 1, 216, 320, 6, 0, False, True)                # NTSC file on PAL machine
t_hdr("HAM2", 1332, 222, 2, 240, 336, 8, 1, True, True)                # HAM8 PAL file, PAL machine
t_hdr("HAM2", 1332, 222, 2, 240, 336, 8, 1, True, False)               # PAL file on NTSC machine
t_hdr("HAM2", 1332, 222, 2, 240, 336, 8, 1, False, True, expect_ok=False, expect_aga_err=True)
t_hdr("HAMV", 734, 324, 1, 216, 320, 0, 0, True, False, name="clip.hv")
t_hdr("HAMV", 1332, 223, 2, 240, 336, 0, 0, True, False, name="DH0:Movies/Clip.H8V")
t_hdr("HAMV", 1332, 223, 2, 240, 336, 0, 0, False, False, name="x.h8v", expect_ok=False, expect_aga_err=True)
t_hdr("HAM2", 600, 300, 1, 200, 288, 6, 0, False, False)
t_hdr("HAM2", 600, 300, 2, 100, 304, 6, 0, False, True)
t_hdr("HAM2", 600, 300, 1, 256, 320, 6, 1, False, True)
t_hdr("HAM2", 600, 100, 1, 216, 320, 6, 0, False, True)                # period below 124 after scaling? (100 -> 99 -> 124)
t_hdr("HAM2", 600, 300, 1, 216, 300, 6, 0, False, False, expect_ok=False)   # bad width
t_hdr("HAM2", 601, 300, 1, 216, 320, 6, 0, False, False, expect_ok=False)   # odd audio size
t_hdr("HAM2", 600, 300, 3, 216, 320, 6, 0, False, False, expect_ok=False)   # 3 channels
t_hdr("HAM2", 600, 300, 1, 257, 320, 6, 0, False, False, expect_ok=False)   # too many lines
t_hdr("HAM2", 600, 300, 1, 216, 320, 7, 0, True, False, expect_ok=False)    # 7 planes
t_hdr("HAM2", 600, 0, 1, 216, 320, 6, 0, False, False, expect_ok=False)     # period 0
t_hdr("HAM2", 65534, 124, 2, 256, 336, 8, 0, True, False)                    # biggest frame

# --------------------------------------------------------------- maths
pairs = [(0, 1), (1, 1), (100, 7), (0xFFFFFFFF, 10), (0xFFFFFFFF, 0x7FFFFFFF), (123456789, 1000),
         (357954500, 324 * 734), (5, 3000)] + [(random.getrandbits(32), random.randint(1, 0x7FFFFFFF)) for _ in range(40)] \
        + [(random.getrandbits(32), random.randint(1, 65535)) for _ in range(40)]
din = new("divin"); dout = new("divout")
data.append(din)
for a, b in pairs:
    data.append(f"        dc.l ${a:08X},${b:08X}")
slot(dout, 16 * len(pairs))
code.append(f"""        lea {din},a2
        lea {dout},a3
        move.w #{len(pairs)-1},d7
.dv     move.l (a2),d0
        move.l 4(a2),d1
        bsr Div32
        move.l d0,(a3)+
        move.l d1,(a3)+
        move.l (a2)+,d0
        move.l (a2)+,d1
        bsr Mul32
        move.l d0,(a3)+
        move.l d1,(a3)+
        dbf d7,.dv""")
checks.append((dout, "math", pairs, "Div32/Mul32"))

# ------------------------------------------------------------ formatting
fmt = [("num", 0), ("num", 7), ("num", 4294967295), ("num", 1000000), ("fix", 0), ("fix", 5), ("fix", 1234),
       ("fix", 100), ("fix", 99999)]
fr = new("fmt")
slot(fr, 200)
code.append("        clr.w v_msglen(a4)")
for kind, v in fmt:
    code.append(f"        move.l #{v},d0\n        bsr {'AddNum' if kind == 'num' else 'AddFix2'}\n        lea sep(pc),a0\n        bsr AddMsg")
code.append(f"        move.w v_msglen(a4),{fr}")
copy_str("msgbuf", f"{fr}+2", 180)
exp_fmt = "".join((str(v) if k == "num" else f"{v // 100}.{v % 100:02d}") + "|" for k, v in fmt)
checks.append((fr, "fmt", exp_fmt, "AddNum/AddFix2"))

# --------------------------------------------------------- buffers/planes
nb = new("nbuf")
slot(nb, 64)
code.append(f"""        move.l #$20000,v_buf(a4)
        move.l #$C000,v_bufsize(a4)
        move.w #3,v_nbuf(a4)
        clr.w v_cur(a4)
        lea {nb},a3
        moveq #6,d7
.nb     bsr NextBuffer
        move.l a2,(a3)+
        dbf d7,.nb
        move.w #2,v_nbuf(a4)
        moveq #4,d7
.nb2    bsr NextBuffer
        move.l a2,(a3)+
        dbf d7,.nb2""")
checks.append((nb, "nbuf", None, "NextBuffer"))

sp = new("planes")
slot(sp, 64)
code.append(f"""        move.w #42,v_planebytes(a4)
        lea $12345678,a0
        bsr SetPlanes
        lea cl_planes,a0
        lea {sp},a1
        moveq #15,d1
.sp     move.l (a0)+,(a1)+
        dbf d1,.sp""")
checks.append((sp, "planes", None, "SetPlanes"))

# --------------------------------------------------------- bench report
def t_bench(frames, framesize, ds1, ds2, period, aud, pal, aga):
    r = new("bench")
    slot(r, 400)
    code.append(f"""        clr.w v_msglen(a4)
        move.l #{frames},v_frames(a4)
        move.l #{framesize},v_framesize(a4)
        move.l #{ds1[0]},v_ds1(a4)
        move.l #{ds1[1]},v_ds1+4(a4)
        move.l #{ds1[2]},v_ds1+8(a4)
        move.l #{ds2[0]},v_ds2(a4)
        move.l #{ds2[1]},v_ds2+4(a4)
        move.l #{ds2[2]},v_ds2+8(a4)
        move.w #{period},v_period(a4)
        move.w #{aud},v_hdr+H_AUDBYTES(a4)
        move.b #{-1 if pal else 0},v_pal(a4)
        move.b #{-1 if aga else 0},v_aga(a4)
        bsr BenchReport
        move.w v_msglen(a4),{r}""")
    copy_str("msgbuf", f"{r}+2", 380)
    ticks = (ds2[0] - ds1[0]) * 1440 * 3000 + (ds2[1] - ds1[1]) * 3000 + (ds2[2] - ds1[2])
    if ticks <= 0:
        ticks = 1
    f2 = lambda v: f"{v // 100}.{v % 100:02d}"
    fps = frames * 5000 // ticks
    kbs = (frames * framesize // ticks) * 50 >> 10
    clock = (354689500 if pal else 357954500)
    need = clock // (period * aud)
    needkb = need * framesize // 102400
    text = (f"Read {frames} frames of {framesize} bytes in {f2(ticks * 2)} s\n"
            f"Speed: {kbs} KB/s = {f2(fps)} frames/s max\n"
            f"This video: {f2(need)} frames/s, {needkb} KB/s -> {'OK' if fps >= need else 'TOO FAST for this machine'}\n"
            f"Machine: {'AGA' if aga else 'OCS/ECS'}, {'PAL' if pal else 'NTSC'}\n")
    checks.append((r, "fmt", text, "BenchReport"))

t_bench(300, 52574, (100, 50, 10), (100, 50, 1010), 324, 734, False, False)       # 20 s
t_bench(500, 83304, (100, 1439, 2990), (101, 0, 3010), 222, 1332, True, True)   # across midnight
t_bench(10, 1000, (5, 5, 5), (5, 5, 5), 300, 600, True, False)                   # zero time

# ----------------------------------------------------------- seeking
def t_seek(pal, period, aud, framesize, hdrsize, length, wanted):
    r = new("seek")
    slot(r, 16 + 8 * len(wanted))
    code.append(f"""        move.b #{-1 if pal else 0},v_pal(a4)
        move.w #{period},v_period(a4)
        move.w #{aud},v_hdr+H_AUDBYTES(a4)
        move.l #{framesize},v_framesize(a4)
        move.w #{hdrsize},v_hdrsize(a4)
        bsr CalcSkip
        move.l #{length},d0
        bsr CalcTotal
        move.l v_skip(a4),{r}
        move.l v_total(a4),{r}+4""")
    for i, w in enumerate(wanted):
        code.append(f"""        move.l #{w & 0xFFFFFFFF},d0
        bsr SeekTarget
        move.l d0,{r}+16+{8*i}
        move.l d1,{r}+20+{8*i}""")
    clock = 35468950 if pal else 35795450
    skip = max(1, clock // (period * aud))
    total = max(0, length - hdrsize) // framesize
    exp = []
    for w in wanted:
        f = max(0, w)
        f = 0 if total == 0 else min(f, total - 1)
        exp.append((f, hdrsize + f * framesize))
    checks.append((r, "seek", (skip, total, exp), f"seek pal={pal} total={total}"))

t_seek(False, 324, 736, 46742, 20, 20 + 46742 * 300, [0, 150, 299, 300, 5000, -1, -500])
t_seek(True, 222, 1280, 69152, 20, 20 + 69152 * 250 + 100, [10, 249, 250, -2])
t_seek(False, 223, 1332, 83304, 14, 14 + 83304 * 1, [0, 1, -1])
t_seek(True, 321, 662, 46742, 20, 10, [0, 3])                      # truncated file: no frame

# ---------------------------------------------------------------- build
src = [f"        org ${ORG:X}", "start:", "        lea vars,a4"] + code + ["        illegal",
       f'        include "{CORE}"',
       "sep     dc.b '|',0", "        even",
       "vars    ds.b v_size", "        even",
       "vidfile ds.b NAMEMAX+1", "tokbuf ds.b NAMEMAX+1", "numbuf ds.b 12", "msgbuf ds.b MSGMAX+2", "        even",
       "cl_bplcon0 dc.w $100,0", "cl_mod dc.w $108,0,$10A,0", "cl_ddf dc.w $92,0,$94,0", "cl_diw dc.w $8E,0,$90,0",
       "cl_planes dc.w $E0,0,$E2,0,$E4,0,$E6,0,$E8,0,$EA,0,$EC,0,$EE,0,$F0,0,$F2,0,$F4,0,$F6,0,$F8,0,$FA,0,$FC,0,$FE,0"] + data
open(os.path.join(HERE, "test.s"), "w").write("\n".join(src) + "\n")
r = subprocess.run([VASM, "-quiet", "-Fbin", "-m68000", "-L", "test.lst", "-o", "test.bin", "test.s"],
                   cwd=HERE, capture_output=True, text=True, stdin=subprocess.DEVNULL)
if r.returncode:
    print(r.stdout, r.stderr)
    sys.exit(1)
r = subprocess.run(["./harness", "test.bin", hex(ORG), "mem.bin"], cwd=HERE, capture_output=True, text=True)
print(r.stderr.strip())
mem = open(os.path.join(HERE, "mem.bin"), "rb").read()

syms = {}
for line in open(os.path.join(HERE, "test.lst"), errors="replace"):
    m = re.match(r"^(\S+)\s+[A-Z]*:?([0-9A-F]{8})\s*$", line.strip())
    if m:
        syms[m.group(1)] = int(m.group(2), 16)
if "res2" not in syms and "res1" not in syms:
    # fallback: parse "Symbols by name" section
    pass

def L(a): return struct.unpack(">I", mem[a:a + 4])[0]
def W(a): return struct.unpack(">H", mem[a:a + 2])[0]
def S(a, n=400):
    b = mem[a:a + n]
    return b[:b.index(0)].decode("latin-1") if 0 in b else b.decode("latin-1")

fails = 0
def check(cond, desc, detail=""):
    global fails
    if not cond:
        fails += 1
        print("FAIL", desc, detail)

usage_addr = syms.get("msg_usage")
for label, kind, exp, desc in checks:
    a = syms[label]
    if kind == "args":
        ok, bench, name = exp
        d0 = L(a)
        check((d0 == 0) == ok, f"args {desc}", f"d0={d0:x}")
        if not ok:
            check(d0 == usage_addr, f"args {desc} usage msg")
        else:
            check(S(a + 8) == name, f"args {desc} name", repr(S(a + 8)))
            check((mem[a + 4] != 0) == bench, f"args {desc} bench")
    elif kind == "hdr":
        ok, agaerr, e = exp
        d0 = L(a)
        if not ok:
            check(d0 != 0, f"hdr {desc} should fail")
            if agaerr:
                check(d0 == syms["msg_needaga"], f"hdr {desc} aga msg")
            else:
                check(d0 == syms["msg_badhdr"], f"hdr {desc} bad msg")
            continue
        check(d0 == 0, f"hdr {desc} should pass", hex(d0))
        got = dict(period=W(a + 4), video=L(a + 6), frame=L(a + 10), buf=L(a + 14), planes=W(a + 18),
                   bplcon0=W(a + 20), mod=W(a + 22), ddf=(W(a + 26), W(a + 28)), diw=(W(a + 30), W(a + 32)), pb=W(a + 34))
        check(W(a + 22) == W(a + 24), f"hdr {desc} mod2")
        for k in e:
            check(got[k] == e[k], f"hdr {desc} {k}", f"got {got[k]!r} expected {e[k]!r}")
    elif kind == "math":
        for i, (x, y) in enumerate(exp):
            q, rr, m, d1 = L(a + 16 * i), L(a + 16 * i + 4), L(a + 16 * i + 8), L(a + 16 * i + 12)
            check(q == x // y and rr == x % y, f"div {x}/{y}", f"{q} {rr}")
            check(m == (x * y) & 0xFFFFFFFF, f"mul {x}*{y}", hex(m))
            check(d1 == y, f"mul keeps d1 {x}*{y}")
    elif kind == "fmt":
        ln = W(a)
        got = mem[a + 2:a + 2 + ln].decode("latin-1")
        check(got == exp, desc, f"\n got {got!r}\n exp {exp!r}")
    elif kind == "nbuf":
        got = [L(a + 4 * i) for i in range(12)]
        e = [0x20000 + 0xC000 * i for i in (1, 2, 0, 1, 2, 0, 1)]
        # after switching to 2 buffers, cur was 1
        e += [0x20000 + 0xC000 * i for i in (0, 1, 0, 1, 0)]
        check(got == e, desc, f"{[hex(x) for x in got]}")
    elif kind == "seek":
        skip, total, e = exp
        check(L(a) == skip, f"{desc} skip", f"{L(a)} vs {skip}")
        check(L(a + 4) == total, f"{desc} total", f"{L(a+4)} vs {total}")
        for i, (f, pos) in enumerate(e):
            check((L(a + 16 + 8 * i), L(a + 20 + 8 * i)) == (f, pos), f"{desc} target {i}",
                  f"got {(L(a + 16 + 8 * i), L(a + 20 + 8 * i))} expected {(f, pos)}")
    elif kind == "planes":
        for p in range(8):
            reg_hi, hi, reg_lo, lo = W(a + 8 * p), W(a + 8 * p + 2), W(a + 8 * p + 4), W(a + 8 * p + 6)
            addr = 0x12345678 + 42 * p
            check((hi << 16 | lo) == addr and reg_hi == 0xE0 + 4 * p and reg_lo == 0xE2 + 4 * p,
                  f"{desc} plane {p}", hex(hi << 16 | lo))

total = len(checks)
print(f"{total} test groups, {fails} failures")
sys.exit(1 if fails else 0)
