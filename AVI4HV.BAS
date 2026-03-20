' updated 2013/1/1
' removed check for number of frames
' added workaround for >2GB AVI header difference
' modified to support more frame sizes
' changed fps/sample size calculations

dim dither as ubyte
DIM fourcc AS STRING * 4
DIM a AS STRING * 1
dim k as string
dim audfile as string
dim ugh as string
dim outfile as string

dim as ulong frameperiod,fptest
dim as single fps
dim as short hres,vres,bitdepth,hlength,plsize
dim as short samplerate,channels,audbytes,aperiod
dim as short x,y,z,v,h,rdiff,gdiff,bdiff,p,o,hh
dim c as ushort

dim as integer l,m,frames,frameno
frameno = 0

dim as ubyte r,g,b,oldhamr,oldhamg,oldhamb
DIM rline(0 TO 335) AS ubyte
DIM gline(0 TO 335) AS ubyte
DIM bline(0 TO 335) AS ubyte
DIM hamline(0 TO 335) AS ubyte
dim plines(0 to 239,0 to 251) as ubyte

dim ff as integer
dim ff2 as integer
dim ff3 as integer

dim iline() as ushort
dim pline() as ubyte

PRINT
PRINT "AVI to HAMvid converter V1.05"
PRINT "Only uncompressed 15-bit RGB videos are supported."
PRINT
PRINT "input file: "; COMMAND$
PRINT

ff=freefile
'OPEN "c:\zopenraw.avi" FOR BINARY AS #ff
OPEN COMMAND$ FOR BINARY AS #ff

GET #ff, , fourcc
IF fourcc <> "RIFF" THEN PRINT "The specified file doesn't have a RIFF header!": END
GET #ff, , l ' turns out to be length-48
GET #ff, , fourcc ' AVI

a10:
GET #ff, , fourcc
a11:
GET #ff, , l

IF fourcc = "LIST" THEN GET #ff, , fourcc: GOTO a10

IF fourcc = "avih" THEN
hlength = l
GET #ff, , l: fps = (1000000.0 / l): frameperiod=l: PRINT "FPS: "; fps
? "(";l;"us per frame)"
FOR x = 1 TO 3: GET #ff, , l: NEXT x
GET #ff, , l: frames = l ': PRINT "Frames: "; frames
FOR x = 1 TO 3: GET #ff, , l: NEXT x

GET #ff, , l: hres = l: PRINT "Horizontal Resolution: "; hres
if hres=288 then goto a193
if hres=304 then goto a193
if hres=320 then goto a193
if hres=336 then goto a193
PRINT "only horizontal resolutions 288,304,320,336 are supported!": END
a193:
redim iline(0 to (hres-1)) as ushort
plsize=((hres*3) shr 2)
redim pline(0 to (plsize-1)) as ubyte

GET #ff, , l: vres = l: PRINT "Vertical Resolution: "; vres
IF vres > 240 THEN PRINT "vertical resolutions greater than 240 are not supported!": END
FOR x = 1 TO (hlength - 40)
GET #ff, , a
NEXT x
GOTO a10
END IF

IF fourcc = "strh" THEN
hlength = l
GET #ff, , fourcc                ' stream type
FOR x = 1 TO (hlength - 4)
GET #ff, , a
NEXT x
IF fourcc <> "vids" THEN GOTO a10
GET #ff, , fourcc
IF fourcc <> "strf" THEN GOTO a11
GET #ff, , l: hlength = l
GET #ff, , l                     ' ???
GET #ff, , l                     ' hres
GET #ff, , l                     ' vres
GET #ff, , x: GET #ff, , bitdepth: PRINT "bit depth: ";
IF bitdepth = 24 THEN PRINT "24": PRINT "24-bits not supported!": END
IF bitdepth = 16 THEN PRINT "15/16"
FOR x = 1 TO (hlength - 16)
GET #ff, , a
NEXT x
GOTO a12
END IF

FOR m = 1 TO INT((l + 1) / 2)
GET #ff, , x
NEXT m

goto a10

a12:
PRINT "Is this correct (y/n) "; : INPUT ugh
IF ugh = "n" THEN END
IF ugh = "N" THEN END


a13:
PRINT "audio file (must be 8-bit uncompressed WAV)"
INPUT audfile
'audfile = "c:\zopenraw.wav"
ff2=freefile
OPEN audfile FOR BINARY AS #ff2
GET #ff2, , fourcc
IF fourcc <> "RIFF" THEN PRINT "specified audio file doesn't have a RIFF header!": CLOSE #ff2: GOTO a13
FOR x = 2 TO 6: GET #ff2, , l: NEXT x
GET #ff2, , samplerate
GET #ff2, , x: GET #ff2, , x: GET #ff2, , x
GET #ff2, , channels
FOR x = 10 TO 13: GET #ff2, , l: NEXT x

PRINT "samplerate: "; samplerate
PRINT "channels: "; channels

frameperiod=frameperiod*samplerate
audbytes = ((frameperiod\1000000) AND 32766)
fptest=audbytes*10000
? "video/audio timing accuracy: ";frameperiod/fptest;"%"
aperiod = INT(3579545 \ samplerate)

DIM audiol(1 TO audbytes) AS ubyte
DIM audior(1 TO audbytes) AS ubyte


PRINT "output file "; : INPUT outfile
'outfile = "d:\zopen.hv"
ff3=freefile
OPEN outfile FOR BINARY AS #ff3

PRINT "enable dithering (y/n) "; : INPUT ugh
dither=1
IF ugh = "n" THEN dither=0
IF ugh = "N" THEN dither=0

' make a header
a = "H": PUT #ff3, , a
a = "A": PUT #ff3, , a
a = "M": PUT #ff3, , a
a = "V": PUT #ff3, , a

' store chunksize,period,channels as words with Motorola byte order
a = CHR$(INT(audbytes / 256)): PUT #ff3, , a
a = CHR$(audbytes AND 255): PUT #ff3, , a

a = CHR$(INT(aperiod / 256)): PUT #ff3, , a
a = CHR$(aperiod AND 255): PUT #ff3, , a

a = CHR$(INT(channels / 256)): PUT #ff3, , a
a = CHR$(channels AND 255): PUT #ff3, , a

' store vres and hres as words with Motorola byte order
a = CHR$(INT(vres / 256)): PUT #ff3, , a
a = CHR$(vres AND 255): PUT #ff3, , a

a = CHR$(INT(hres / 256)): PUT #ff3, , a
a = CHR$(hres AND 255): PUT #ff3, , a


screen 14,32

DO
a110:
GET #ff, , fourcc
a111:
GET #ff, , l

k = INKEY$
IF k = "q" THEN END

if eof(ff) then end

IF fourcc = "LIST" THEN get #ff,,fourcc: GOTO a110

IF ((fourcc = "00dc") OR (fourcc = "00db")) THEN

screenlock

FOR v = vres - 1 TO 0 STEP -1

' read a line of RGB15 pixels and convert to RGB12
get #ff,,iline()

FOR h = 0 TO hres-1
c=iline(h)
bline(h) = (c AND 30) shr 1
gline(h) = (c and 960) shr 6
rline(h) = (c and 30720) shr 11

if dither=1 then
if ((h+v) and 1)=1 then
IF (c AND 1) THEN IF bline(h) < 15 THEN bline(h) = bline(h) + 1
IF (c AND 32) THEN IF gline(h) < 15 THEN gline(h) = gline(h) + 1
IF (c AND 1024) THEN IF rline(h) < 15 THEN rline(h) = rline(h) + 1
end if
end if

'm=bline(h) shl 4
'm=m+gline(h) shl 12
'm=m+rline(h) shl 20
'pset (h,v),m

NEXT h

' HAMify it
FOR h = 0 TO hres-1
r = rline(h)
g = gline(h)
b = bline(h)

IF h = 0 THEN
IF (r AND 7) + (g AND 7) + (b AND 7) > 12 THEN
c = 8: oldhamr = 5: oldhamg = 5: oldhamb = 5
ELSE
c = 0: oldhamr = 0: oldhamg = 0: oldhamb = 0
END IF
IF (r AND 8) THEN c = c + 4: oldhamr = oldhamr + 10
IF (g AND 8) THEN c = c + 2: oldhamg = oldhamg + 10
IF (b AND 8) THEN c = c + 1: oldhamb = oldhamb + 10
hamline(0) = c
GOTO a52
END IF

IF r = 15 THEN IF g = 15 THEN IF b = 15 THEN hamline(h) = 15: oldhamr = 15: oldhamg = 15: oldhamb = 15: GOTO a52
IF r = 0 THEN IF g = 0 THEN IF b = 0 THEN hamline(h) = 0: oldhamr = 0: oldhamg = 0: oldhamb = 0: GOTO a52

rdiff = r - oldhamr: IF r < oldhamr THEN rdiff = oldhamr - r
gdiff = g - oldhamg: IF g < oldhamg THEN gdiff = oldhamg - g
bdiff = b - oldhamb: IF b < oldhamb THEN bdiff = oldhamb - b

IF ((bdiff > gdiff) AND (bdiff > rdiff)) THEN c = b + 16: oldhamb = b: GOTO a53
IF ((rdiff >= bdiff) AND (rdiff > gdiff)) THEN c = r + 32: oldhamr = r: GOTO a53
c = g + 48: oldhamg = g
a53:
hamline(h) = c
a52:

m=oldhamb shl 4
m+=oldhamg shl 12
m+=oldhamr shl 20
pset (h,v),m

NEXT h

' PLANARify it
z = 1: o = 0
FOR p = 0 TO 5
FOR h = 0 TO (hres shr 3)-1
hh = h shl 3: c = 0: y = 1
FOR x = 7 TO 0 STEP -1
IF (hamline(hh + x) AND z) <> 0 THEN c = c + y
y = y + y
NEXT x
plines(v,o)=c
o=o+1
NEXT h
z = z + z
NEXT p

NEXT v

screenunlock

for v=0 to vres-1
for h=0 to plsize-1
pline(h)=plines(v,h)
next h
put #ff3,,pline()
next v

' read and write audio data
FOR x = 1 TO audbytes
GET #ff2, , r: audiol(x) = ((r - 128) AND 255)
IF channels = 2 THEN GET #ff2, , r: audior(x) = ((r - 128) AND 255)
NEXT x

put #ff3,,audiol()
IF channels = 2 THEN put #ff3,,audior()


a121:
frameno = frameno + 1
GOTO a112
END IF

' skip past extra RIFF header in "new format" large AVIs
IF fourcc = "RIFF" THEN
get #ff,,fourcc
goto a110
end if

' skip past "ICRD" (whatever that is)
' which has an incorrect length of $0000000B specified
IF ((fourcc = "ICRD") and (l=11)) THEN
for x=0 to l
get #ff,,a
next x
goto a110
end if

a113:   ' skip past some extraneous chunk
IF l > hres+hres-1 THEN l = l - (hres+hres): GET #ff, ,iline(): GOTO a113

if l>0 then 
for x=1 to l
get #ff,,a
next x
end if


a112:
LOOP ' UNTIL frameno = frames

END

