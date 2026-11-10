#!/usr/bin/env python3
"""
video2ham.py - convert any video into Amiga HAM videos, in one step.

ffmpeg decodes, resizes and resamples the source; the frames and the sound
are read straight from ffmpeg through pipes (no intermediate file), then
encoded for the Amiga players:
  - HAM6 (.hv),  for every Amiga
  - HAM8 (.h8v), for AGA Amigas

Based on AVI4HV.BAS / AVI4AGA.BAS by damage_x (http://www.hyakushiki.net/),
via the jaymanu79/avi4hv fork.

Output format ("HAM2", played by HAMPLAY):
  "HAM2", then 8 big-endian words: audio samples per frame and channel,
  audio period, channels, vres, hres, bitplanes (6 or 8), flags (bit 0:
  period computed for the PAL clock), reserved.
  Then for each frame: vres lines, each line holding the bitplanes one
  after another (hres/8 bytes each), followed by the sound of the frame
  (left channel, then right if stereo), as signed 8-bit samples.
  With --legacy, the header is the old one ("HAMV" + the first 5 words,
  NTSC clock) for the original HAMNEW / HAMAGA players.

Requires Python 3.8+, numpy, and ffmpeg/ffprobe in the PATH.
"""

import argparse
import fractions
import json
import os
import shutil
import struct
import subprocess
import sys
import threading

import numpy as np

SUPPORTED_WIDTHS = (288, 304, 320, 336)
MAX_HEIGHT = 240         # NTSC (and the old players)
MAX_HEIGHT_PAL = 256
MIN_PERIOD = 124         # fastest Paula DMA rate: about 28.8 kHz
NTSC_CLOCK = 3579545
PAL_CLOCK = 3546895
MAX_GAIN = 64.0          # normalisation never amplifies more than this (+36 dB)

# default settings for each mode (the ones of the original video2ham script)
MODES = {
    # fps: NTSC default (divides 60 Hz), fps_pal: PAL default (divides 50 Hz)
    "ham6": dict(ext=".hv", width=320, height=216, fps=fractions.Fraction(15),
                 fps_pal=fractions.Fraction(50, 3), rate=11025, channels=1,
                 pix_fmt="rgb555le", bytes_per_pixel=2, planes=6,
                 legacy_max_frame=0xFFFF),   # HAMNEW: 64 KB buffers, size on 16 bits
    "ham8": dict(ext=".h8v", width=336, height=240, fps=fractions.Fraction(12),
                 fps_pal=fractions.Fraction(25, 2), rate=16000, channels=2,
                 pix_fmt="bgr24", bytes_per_pixel=3, planes=8,
                 legacy_max_frame=0x18000),  # HAMAGA: 96 KB buffers
}


class ConversionError(Exception):
    pass


# --------------------------------------------------------------------------
# ffmpeg helpers
# --------------------------------------------------------------------------

def check_tools():
    for tool in ("ffmpeg", "ffprobe"):
        if shutil.which(tool) is None:
            raise ConversionError(f"{tool} not found, please install ffmpeg")


def probe(path):
    """Return (duration in seconds or None, number of audio channels or 0,
    display aspect ratio of the video as a Fraction)."""
    try:
        out = subprocess.run(
            ["ffprobe", "-v", "error", "-show_entries",
             "format=duration:stream=codec_type,channels,width,height,sample_aspect_ratio"
             ":stream_tags=rotate:stream_side_data=rotation",
             "-of", "json", path],
            capture_output=True, text=True, check=True).stdout
    except subprocess.CalledProcessError as e:
        raise ConversionError(f"cannot read {path}: {e.stderr.strip() or 'ffprobe failed'}")
    info = json.loads(out)
    streams = info.get("streams", [])
    videos = [s for s in streams if s.get("codec_type") == "video"]
    if not videos:
        raise ConversionError(f"{path}: no video stream")
    aspect = display_aspect(videos[0])
    audio = [s for s in streams if s.get("codec_type") == "audio"]
    channels = int(audio[0].get("channels", 1)) if audio else 0
    try:
        duration = float(info.get("format", {}).get("duration"))
    except (TypeError, ValueError):
        duration = None
    return duration, channels, aspect


def display_aspect(stream):
    """Shape of the picture as shown by a player (pixel aspect and rotation included)."""
    try:
        w, h = int(stream["width"]), int(stream["height"])
        aspect = fractions.Fraction(w, h)
    except (KeyError, ValueError, ZeroDivisionError):
        return fractions.Fraction(4, 3)
    sar = stream.get("sample_aspect_ratio", "1:1")
    try:
        num, den = (int(x) for x in sar.split(":"))
        if num > 0 and den > 0:
            aspect *= fractions.Fraction(num, den)
    except ValueError:
        pass
    rotation = stream.get("tags", {}).get("rotate")
    for side in stream.get("side_data_list", []):
        rotation = side.get("rotation", rotation)
    try:
        if abs(int(float(rotation))) % 180 == 90:   # phone videos filmed upright
            aspect = 1 / aspect
    except (TypeError, ValueError):
        pass
    return aspect


def time_args(args):
    """-ss / -t options to select a part of the source (placed before -i)."""
    opts = []
    if args.start:
        opts += ["-ss", args.start]
    if args.duration:
        opts += ["-t", args.duration]
    return opts


def read_audio(path, args, rate, channels):
    """Decode the whole sound track (it is small) and return it as unsigned
    8-bit samples, interleaved, ready to be cut into frames.

    The sound is decoded in 16 bits, then normalised and converted to 8 bits
    here: with only 8 bits, a quiet sound track would use just a few of the
    256 levels and be barely audible (or lost in the noise) on the Amiga."""
    filters = []
    if args.compress:
        # evens out the volume: quiet passages (dialogues...) become louder
        filters.append("dynaudnorm=f=250:g=15")
    cmd = (["ffmpeg", "-nostdin", "-v", "error"] + time_args(args) + ["-i", path,
           "-map", "0:a:0", "-vn", "-ac", str(channels), "-ar", str(rate)]
           + (["-af", ",".join(filters)] if filters else [])
           + ["-f", "s16le", "-acodec", "pcm_s16le", "-"])
    proc = subprocess.run(cmd, capture_output=True)
    if proc.returncode != 0:
        raise ConversionError("ffmpeg audio decoding failed:\n" + proc.stderr.decode(errors="replace").strip())
    samples = np.frombuffer(proc.stdout, dtype="<i2").astype(np.float64)

    gain = args.volume
    if not args.no_normalize and len(samples):
        # peak normalisation, ignoring the 0.01 % loudest samples (isolated clicks)
        peak = np.percentile(np.abs(samples), 99.99)
        if peak > 0:
            gain *= min(32000.0 / peak, MAX_GAIN)
    if not args.quiet and len(samples):
        print(f"  audio gain x{gain:.2f}")
    samples = np.clip(np.round(samples * gain / 256.0), -128, 127)
    return (samples.astype(np.int16) + 128).astype(np.uint8)


class VideoPipe:
    """Stream raw frames out of ffmpeg, already resized and at the target rate."""

    def __init__(self, path, args, mode):
        w, h = mode["width"], mode["height"]
        pw, ph = mode["pic_width"], mode["pic_height"]   # picture inside the frame
        vf = (f"fps={mode['fps'].numerator}/{mode['fps'].denominator},"
              f"scale={pw}:{ph}:flags=lanczos,"
              # convert to RGB before padding: in a YUV 4:2:0 format, pad rounds
              # an odd size down and refuses a picture with an odd height
              f"format={mode['pix_fmt']},"
              f"pad={w}:{h}:(ow-iw)/2:(oh-ih)/2,setsar=1")
        cmd = (["ffmpeg", "-nostdin", "-v", "error"] + time_args(args) + ["-i", path,
               "-map", "0:v:0", "-an", "-vf", vf,
               "-pix_fmt", mode["pix_fmt"], "-f", "rawvideo", "-"])
        self.frame_size = w * h * mode["bytes_per_pixel"]
        self.proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        # collect error messages in the background so the pipe never fills up
        self.errors = []
        self._t = threading.Thread(target=lambda: self.errors.append(self.proc.stderr.read()), daemon=True)
        self._t.start()

    def frames(self):
        while True:
            data = self.proc.stdout.read(self.frame_size)
            if len(data) < self.frame_size:
                return
            yield data

    def close(self):
        self.proc.stdout.close()
        rc = self.proc.wait()
        self._t.join()
        if rc != 0:
            msg = b"".join(self.errors).decode(errors="replace").strip()
            raise ConversionError("ffmpeg video decoding failed:\n" + msg)

    def kill(self):
        if self.proc.poll() is None:
            self.proc.kill()
        self.proc.wait()


# --------------------------------------------------------------------------
# HAM encoding
# --------------------------------------------------------------------------

def ham6_line(r, g, b):
    """HAM6 encoding of one line of 4-bit components (lists of ints).
    Returns (codes, displayed colours as (r, g, b) tuples of 0-15 values)."""
    n = len(r)
    codes = [0] * n
    display = [None] * n

    # first pixel: closest of the 16 palette colours
    r0, g0, b0 = r[0], g[0], b[0]
    if (r0 & 7) + (g0 & 7) + (b0 & 7) > 12:
        c, orr, og, ob = 8, 5, 5, 5
    else:
        c, orr, og, ob = 0, 0, 0, 0
    if r0 & 8:
        c += 4
        orr += 10
    if g0 & 8:
        c += 2
        og += 10
    if b0 & 8:
        c += 1
        ob += 10
    codes[0] = c
    display[0] = (orr, og, ob)

    for h in range(1, n):
        rr, gg, bb = r[h], g[h], b[h]
        if rr == 15 and gg == 15 and bb == 15:
            codes[h] = 15
            orr = og = ob = 15
        elif rr == 0 and gg == 0 and bb == 0:
            codes[h] = 0
            orr = og = ob = 0
        else:
            rdiff = abs(rr - orr)
            gdiff = abs(gg - og)
            bdiff = abs(bb - ob)
            if bdiff > gdiff and bdiff > rdiff:
                codes[h] = bb + 16
                ob = bb
            elif rdiff >= bdiff and rdiff > gdiff:
                codes[h] = rr + 32
                orr = rr
            else:
                codes[h] = gg + 48
                og = gg
        display[h] = (orr, og, ob)
    return codes, display


def ham8_line(r, g, b):
    """HAM8 encoding of one line of 8-bit components masked to their
    6 significant bits (& 252). Control bits are bits 0-1 of each code
    (00 palette, 01 blue, 10 red, 11 green); data is in bits 2-7."""
    n = len(r)
    codes = [0] * n
    display = [None] * n

    r0, g0, b0 = r[0], g[0], b[0]
    if (r0 & 124) + (g0 & 124) + (b0 & 124) > 320:
        c, orr, og, ob = 8, 84, 84, 84
    else:
        c, orr, og, ob = 0, 0, 0, 0
    if r0 & 128:
        c += 4
        orr += 168
    if g0 & 128:
        c += 2
        og += 168
    if b0 & 128:
        c += 1
        ob += 168
    # AVI4AGA.BAS stored c directly here, which put the palette index in the
    # control bits (the first pixel of each line became a "modify" pixel and
    # the wrong colour spread along the line). The palette index belongs in
    # bits 2-7, like the white pixel below (60 = 15 << 2).
    codes[0] = c << 2
    display[0] = (orr, og, ob)

    for h in range(1, n):
        rr, gg, bb = r[h], g[h], b[h]
        if rr == 252 and gg == 252 and bb == 252:
            codes[h] = 60
            orr = og = ob = 252
        elif rr == 0 and gg == 0 and bb == 0:
            codes[h] = 0
            orr = og = ob = 0
        else:
            rdiff = abs(rr - orr)
            gdiff = abs(gg - og)
            bdiff = abs(bb - ob)
            if bdiff > gdiff and bdiff > rdiff:
                codes[h] = bb + 1
                ob = bb
            elif rdiff >= bdiff and rdiff > gdiff:
                codes[h] = rr + 2
                orr = rr
            else:
                codes[h] = gg + 3
                og = gg
        display[h] = (orr, og, ob)
    return codes, display


def planarize(codes, planes):
    """(vres, hres) array of pixel codes -> bytes, line by line, each line
    holding `planes` bitplanes of hres/8 bytes (leftmost pixel = MSB)."""
    vres, hres = codes.shape
    packed = np.stack([np.packbits(((codes >> p) & 1).astype(np.uint8), axis=1)
                       for p in range(planes)], axis=1)
    return packed.reshape(vres, planes * (hres // 8)).tobytes()


class Encoder:
    def __init__(self, mode_name, mode, dither):
        self.mode_name = mode_name
        self.hres, self.vres = mode["width"], mode["height"]
        self.planes = mode["planes"]
        self.dither = dither
        # dither pattern: pixels where (h + v) is odd
        hh, vv = np.meshgrid(np.arange(self.hres), np.arange(self.vres))
        self.dither_mask = ((hh + vv) & 1) == 1

    def components(self, raw):
        """Raw top-down frame -> r, g, b arrays (vres, hres)."""
        if self.mode_name == "ham6":
            c = np.frombuffer(raw, dtype="<u2").reshape(self.vres, self.hres).astype(np.int32)
            b = (c & 30) >> 1
            g = (c & 960) >> 6
            r = (c & 30720) >> 11
            if self.dither:
                # use the dropped 5th bit to round up on every other pixel
                m = self.dither_mask
                b = np.where(m & ((c & 1) != 0) & (b < 15), b + 1, b)
                g = np.where(m & ((c & 32) != 0) & (g < 15), g + 1, g)
                r = np.where(m & ((c & 1024) != 0) & (r < 15), r + 1, r)
        else:
            px = np.frombuffer(raw, dtype=np.uint8).reshape(self.vres, self.hres, 3).astype(np.int32)
            b = px[:, :, 0] & 252
            g = px[:, :, 1] & 252
            r = px[:, :, 2] & 252
        return r, g, b

    def encode(self, raw, want_display=False):
        r, g, b = self.components(raw)
        line_func = ham6_line if self.mode_name == "ham6" else ham8_line
        codes = np.zeros((self.vres, self.hres), dtype=np.int32)
        display = [] if want_display else None
        rl, gl, bl = r.tolist(), g.tolist(), b.tolist()
        for v in range(self.vres):
            line_codes, line_display = line_func(rl[v], gl[v], bl[v])
            codes[v] = line_codes
            if want_display:
                display.append(line_display)
        return planarize(codes, self.planes), display


def write_ppm(path, display, mode_name):
    scale = 17 if mode_name == "ham6" else 1  # 4-bit -> 8-bit for HAM6
    arr = np.array(display, dtype=np.int32) * scale
    arr = np.clip(arr, 0, 255).astype(np.uint8)
    with open(path, "wb") as f:
        f.write(b"P6 %d %d 255\n" % (arr.shape[1], arr.shape[0]))
        f.write(arr.tobytes())


# --------------------------------------------------------------------------
# Conversion
# --------------------------------------------------------------------------

# Shape of an Amiga low-res pixel (width / height): a 4:3 screen is
# 320 x 256 pixels in PAL and 320 x 200 in NTSC.
PIXEL_ASPECT_PAL = fractions.Fraction(16, 15)
PIXEL_ASPECT_NTSC = fractions.Fraction(5, 6)


def frame_geometry(width, aspect, pixel_aspect, max_height, fixed_height=None):
    """Picture size for a source of display aspect `aspect`, `width` pixels
    wide. Without fixed_height, the frame is only as tall as the picture (no
    black bars stored: the player centres it on the screen). Returns
    (frame height, picture width, picture height)."""
    full_height = width * pixel_aspect / aspect          # lines for the whole width
    height = fixed_height or min(max_height, max(2, round(full_height)))
    pic_w, pic_h = width, round(full_height)
    if pic_h > height:                                   # too tall: narrower picture
        pic_h = height
        pic_w = min(width, round(height * aspect / pixel_aspect))
    return height, max(2, pic_w), max(2, pic_h)


def convert_mode(path, args, mode_name, duration, source_channels, aspect):
    mode = dict(MODES[mode_name])
    if args.width:
        mode["width"] = args.width
    if args.pal:
        mode["fps"] = mode["fps_pal"]
    if args.fps:
        mode["fps"] = fractions.Fraction(args.fps).limit_denominator(1000)
    if args.rate:
        mode["rate"] = args.rate
    if args.channels:
        mode["channels"] = args.channels
    if source_channels <= 1:
        mode["channels"] = 1  # no point making stereo out of mono or silence

    if mode["width"] not in SUPPORTED_WIDTHS:
        raise ConversionError(f"width {mode['width']} not supported (must be one of {SUPPORTED_WIDTHS})")
    max_height = MAX_HEIGHT_PAL if args.pal and not args.legacy else MAX_HEIGHT
    if args.height and not 1 <= args.height <= max_height:
        raise ConversionError(f"height {args.height} not supported (max {max_height})")
    if args.legacy and not (args.height or args.pad):
        args.pad = True       # the old players do not centre short pictures
    if args.pad:
        fixed = args.height or mode["height"]     # fixed height, black bars stored
    else:
        fixed = None                              # height follows the picture
        if args.height:
            max_height = args.height
    pixel_aspect = PIXEL_ASPECT_PAL if args.pal else PIXEL_ASPECT_NTSC
    mode["height"], mode["pic_width"], mode["pic_height"] = frame_geometry(
        mode["width"], aspect, pixel_aspect, max_height, fixed)

    base = args.output or os.path.splitext(path)[0]
    out_path = base + mode["ext"]
    out_dir = os.path.dirname(out_path)
    if out_dir:
        os.makedirs(out_dir, exist_ok=True)

    # Audio timing. Each frame carries exactly `audbytes` samples, so the
    # sound is resampled at audbytes * fps: picture and sound then stay in
    # sync over the whole video. The Amiga plays it with the closest period.
    channels = mode["channels"]
    fps = mode["fps"]
    pal_clock = args.pal and not args.legacy
    clock = PAL_CLOCK if pal_clock else NTSC_CLOCK
    audbytes = 2 * round(mode["rate"] / fps / 2)        # even number of samples per frame
    if audbytes < 2:
        raise ConversionError("audio sample rate too low for this frame rate")
    if audbytes > 65534:
        raise ConversionError("too many audio samples per frame: raise the frame rate")
    rate = round(audbytes * fps)                         # resampling rate
    aperiod = round(clock / (audbytes * fps))
    if aperiod < MIN_PERIOD:
        raise ConversionError(f"sample rate {rate} Hz too high for the Amiga (max {clock // MIN_PERIOD} Hz)")
    amiga_fps = clock / aperiod / audbytes               # speed of the real playback

    frame_total = mode["planes"] * mode["width"] // 8 * mode["height"] + audbytes * channels
    if args.legacy and frame_total > mode["legacy_max_frame"]:
        # the old players read each frame into a fixed-size buffer
        raise ConversionError(
            f"frame too big for the old {mode_name.upper()} player ({frame_total} bytes, "
            f"max {mode['legacy_max_frame']}): lower the sample rate, use mono, "
            f"raise the frame rate or reduce the picture size")

    if source_channels:
        audio = read_audio(path, args, rate, channels)
    else:
        audio = np.zeros(0, dtype=np.uint8)  # silent video: the sound track will be silence

    total = None
    if duration:
        if args.duration:
            duration = min(duration, parse_seconds(args.duration))
        if args.start:
            duration = max(0.0, duration - parse_seconds(args.start))
        total = int(duration * fps)

    if not args.quiet:
        print(f"{mode_name.upper()}{' PAL' if pal_clock else ''}: {mode['width']}x{mode['height']}"
              f"{'' if (mode['pic_width'], mode['pic_height']) == (mode['width'], mode['height']) else ' (picture %dx%d)' % (mode['pic_width'], mode['pic_height'])}, "
              f"{float(fps):.3g} fps, {rate} Hz {'stereo' if channels == 2 else 'mono'}"
              f"{'' if source_channels else ' (silent)'} -> {out_path}")
        print(f"  {frame_total} bytes per frame, {frame_total * amiga_fps / 1024:.0f} KB/s from disk, "
              f"{3 * ((frame_total + 7) & ~7) // 1024} KB of chip RAM")

    encoder = Encoder(mode_name, mode, dither=not args.no_dither)
    if args.preview:
        os.makedirs(args.preview, exist_ok=True)

    video = VideoPipe(path, args, mode)
    frameno = 0
    samples_per_frame = audbytes * channels
    # write to a temporary file, renamed at the end, so that a failed
    # conversion never destroys a previous output
    tmp_path = out_path + ".part"
    try:
        with open(tmp_path, "wb") as out:
            if args.legacy:
                # old format, for HAMNEW / HAMAGA (NTSC clock, mode from the extension)
                out.write(b"HAMV")
                out.write(struct.pack(">HHHHH", audbytes, aperiod, channels,
                                      mode["height"], mode["width"]))
            else:
                # HAM2: adds the number of bitplanes and the clock used for the period
                out.write(b"HAM2")
                out.write(struct.pack(">HHHHHHHH", audbytes, aperiod, channels, mode["height"],
                                      mode["width"], mode["planes"], 1 if pal_clock else 0, 0))
            for raw in video.frames():
                want_preview = bool(args.preview) and frameno % args.preview_every == 0
                encoded, display = encoder.encode(raw, want_display=want_preview)
                if want_preview:
                    write_ppm(os.path.join(args.preview, f"{mode_name}_{frameno:05d}.ppm"),
                              display, mode_name)
                out.write(encoded)

                # sound of this frame, padded with silence after the end
                start = frameno * samples_per_frame
                block = audio[start:start + samples_per_frame]
                if len(block) < samples_per_frame:
                    block = np.concatenate([block, np.full(samples_per_frame - len(block), 128, np.uint8)])
                block = block ^ 0x80  # unsigned -> signed 8-bit
                if channels == 2:
                    out.write(block[0::2].tobytes())
                    out.write(block[1::2].tobytes())
                else:
                    out.write(block.tobytes())

                frameno += 1
                if not args.quiet and frameno % 10 == 0:
                    progress = f"{frameno}/{total}" if total else str(frameno)
                    print(f"\r  frame {progress}", end="", flush=True)
        video.close()
        if frameno == 0:
            raise ConversionError("ffmpeg produced no frame (is the start time past the end?)")
    except BaseException:
        video.kill()
        if os.path.exists(tmp_path):
            os.remove(tmp_path)
        raise
    os.replace(tmp_path, out_path)
    if not args.quiet:
        print(f"\r  {frameno} frames written to {out_path}")


def parse_seconds(text):
    """'90', '1:30', '00:01:30.5' -> seconds."""
    seconds = 0.0
    for part in text.split(":"):
        seconds = seconds * 60 + float(part)
    return seconds


def main():
    parser = argparse.ArgumentParser(
        description="Convert any video into Amiga HAM6 (.hv) and/or HAM8 (.h8v) videos.")
    parser.add_argument("video", help="input video (any format ffmpeg can read)")
    parser.add_argument("-m", "--mode", choices=("ham6", "ham8", "both"), default="both",
                        help="HAM6 (OCS/ECS), HAM8 (AGA) or both (default)")
    parser.add_argument("-o", "--output", metavar="BASE",
                        help="output path without extension (default: same as the video)")
    parser.add_argument("--start", help="start time in the source (seconds or [hh:]mm:ss)")
    parser.add_argument("--duration", help="duration to convert (seconds or [hh:]mm:ss)")
    parser.add_argument("--width", type=int, choices=SUPPORTED_WIDTHS,
                        help="picture width (default 320 for HAM6, 336 for HAM8)")
    parser.add_argument("--height", type=int,
                        help=f"maximum frame height (at most {MAX_HEIGHT}, {MAX_HEIGHT_PAL} with --pal). "
                             "The height follows the shape of the video: no black bars are stored, "
                             "the player centres the picture")
    parser.add_argument("--pad", action="store_true",
                        help="fixed frame height (--height, or 216 for HAM6 and 240 for HAM8) "
                             "with black bars stored, like the old converter")
    parser.add_argument("--pal", action="store_true",
                        help="make the video for PAL Amigas: frame rates that divide 50 Hz "
                             "(16.67 for HAM6, 12.5 for HAM8) and up to 256 lines")
    parser.add_argument("--legacy", action="store_true",
                        help="old 'HAMV' format, for the original HAMNEW / HAMAGA players")
    parser.add_argument("--fps", type=float,
                        help="frame rate (default 15 for HAM6, 12 for HAM8; with --pal 16.67 and 12.5)")
    parser.add_argument("--rate", type=int, help="audio sample rate in Hz, up to about 28800 "
                                                 "(default 11025 for HAM6, 16000 for HAM8)")
    parser.add_argument("--channels", type=int, choices=(1, 2),
                        help="1 = mono, 2 = stereo (default mono for HAM6, stereo for HAM8)")
    parser.add_argument("--volume", type=float, default=1.0,
                        help="extra audio volume factor, applied after normalisation (default 1.0)")
    parser.add_argument("--no-normalize", action="store_true",
                        help="keep the original audio level (no peak normalisation)")
    parser.add_argument("--compress", action="store_true",
                        help="even out the volume (louder quiet passages), useful for films")
    parser.add_argument("--no-dither", action="store_true", help="disable dithering (HAM6)")
    parser.add_argument("--preview", metavar="DIR",
                        help="save the HAM rendering of some frames as PPM images in DIR")
    parser.add_argument("--preview-every", type=int, default=25, metavar="N",
                        help="with --preview, save one frame every N (default 25)")
    parser.add_argument("-q", "--quiet", action="store_true", help="no progress output")
    args = parser.parse_args()
    if args.preview_every < 1:
        parser.error("--preview-every must be at least 1")
    if args.fps is not None and args.fps <= 0:
        parser.error("--fps must be positive")

    try:
        check_tools()
        if not os.path.isfile(args.video):
            raise ConversionError(f"{args.video}: no such file")
        for value in (args.start, args.duration):
            if value:
                try:
                    parse_seconds(value)
                except ValueError:
                    raise ConversionError(f"invalid time: {value}")
        duration, source_channels, aspect = probe(args.video)
        modes = ("ham6", "ham8") if args.mode == "both" else (args.mode,)
        for mode_name in modes:
            convert_mode(args.video, args, mode_name, duration, source_channels, aspect)
    except ConversionError as e:
        print(f"\nerror: {e}", file=sys.stderr)
        sys.exit(1)
    except OSError as e:
        print(f"\nerror: {e}", file=sys.stderr)
        sys.exit(1)
    except KeyboardInterrupt:
        print("\ninterrupted", file=sys.stderr)
        sys.exit(130)


if __name__ == "__main__":
    main()
