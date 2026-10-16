#!/usr/bin/env python3
"""
hamview.py - check and play Amiga HAM videos (.hv / .h8v) on a PC.

Reads the files made by video2ham.py ("HAM2") and the old "HAMV" files,
decodes the HAM pictures exactly as the Amiga displays them (same base
palette as the players, same hold-and-modify rules) and plays them with
their sound.

    hamview.py video.hv                 play (needs pygame)
    hamview.py video.hv --info          check the file and show its details
    hamview.py video.hv --export out.mp4   convert to a normal video (needs ffmpeg)
    hamview.py video.hv --snapshot 100 frame.png   save one frame (needs ffmpeg)

Keys while playing:
    Space pause/resume       Left/Right -/+10 s      Down/Up -/+1 min
    , and .  previous/next frame (paused)            Home  back to start
    A  pixel aspect on/off   F  fullscreen           M  mute
    I  information on/off    S  screenshot (PNG)     Esc/Q  quit

Requires Python 3.8+ and numpy; pygame for playing, ffmpeg for exporting.
"""

import argparse
import os
import shutil
import struct
import subprocess
import sys
import tempfile
import time
import wave

import numpy as np

NTSC_CLOCK = 3579545
PAL_CLOCK = 3546895
SUPPORTED_WIDTHS = (288, 304, 320, 336)

# Base palette of the Amiga players (12-bit colours of the copper list)
_PALETTE12 = [0x000, 0x00A, 0x0A0, 0x0AA, 0xA00, 0xA0A, 0xAA0, 0xAAA,
              0x555, 0x55F, 0x5F5, 0x5FF, 0xF55, 0xF5F, 0xFF5, 0xFFF]
PALETTE = np.zeros((64, 3), dtype=np.uint8)          # HAM8 has 64 registers
for _i, _c in enumerate(_PALETTE12):
    PALETTE[_i] = (((_c >> 8) & 15) * 17, ((_c >> 4) & 15) * 17, (_c & 15) * 17)

# Shape of a low-res pixel (width / height) on a 4:3 screen
PIXEL_ASPECT = {"PAL": 16 / 15, "NTSC": 5 / 6}


class HamError(Exception):
    pass


# --------------------------------------------------------------------------
# File access
# --------------------------------------------------------------------------

class HamFile:
    def __init__(self, path):
        self.path = path
        with open(path, "rb") as f:
            head = f.read(20)
        if len(head) < 14:
            raise HamError("file too short")
        magic = head[:4]
        if magic == b"HAM2":
            if len(head) < 20:
                raise HamError("truncated header")
            (self.audbytes, self.period, self.channels, self.vres, self.hres,
             self.planes, self.flags, _) = struct.unpack(">8H", head[4:20])
            self.hdrsize = 20
            self.format = "HAM2"
        elif magic == b"HAMV":
            (self.audbytes, self.period, self.channels, self.vres,
             self.hres) = struct.unpack(">5H", head[4:14])
            self.planes = 8 if path.lower().endswith(".h8v") else 6
            self.flags = 0
            self.hdrsize = 14
            self.format = "HAMV (old)"
        else:
            raise HamError("not a HAM video (no HAM2/HAMV header)")

        problems = []
        if self.hres not in SUPPORTED_WIDTHS:
            problems.append(f"width {self.hres} not in {SUPPORTED_WIDTHS}")
        if not 1 <= self.vres <= 256:
            problems.append(f"height {self.vres} not in 1..256")
        if self.planes not in (6, 8):
            problems.append(f"{self.planes} bitplanes (must be 6 or 8)")
        if self.channels not in (1, 2):
            problems.append(f"{self.channels} audio channels (must be 1 or 2)")
        if self.audbytes == 0 or self.audbytes & 1:
            problems.append(f"{self.audbytes} audio bytes per frame (must be even, not 0)")
        if self.period == 0:
            problems.append("audio period 0")
        if problems:
            raise HamError("invalid header: " + "; ".join(problems))

        self.pal = bool(self.flags & 1)
        self.clock = PAL_CLOCK if self.pal else NTSC_CLOCK
        self.rate = self.clock / self.period                 # audio samples per second
        self.fps = self.rate / self.audbytes
        self.planebytes = self.hres // 8
        self.videosize = self.planebytes * self.planes * self.vres
        self.audiosize = self.audbytes * self.channels
        self.framesize = self.videosize + self.audiosize

        size = os.path.getsize(path)
        self.nframes = max(0, size - self.hdrsize) // self.framesize
        self.trailing = max(0, size - self.hdrsize) - self.nframes * self.framesize
        if self.nframes == 0:
            raise HamError("no complete frame in the file")
        self.data = np.memmap(path, dtype=np.uint8, mode="r", offset=self.hdrsize,
                              shape=(self.nframes, self.framesize))

    @property
    def duration(self):
        return self.nframes / self.fps

    @property
    def mode(self):
        return "HAM8" if self.planes == 8 else "HAM6"

    def describe(self):
        lines = [
            f"file:     {self.path}",
            f"format:   {self.format}, {self.mode} ({'AGA only' if self.planes == 8 else 'any Amiga'})",
            f"picture:  {self.hres} x {self.vres}, {self.planes} bitplanes",
            f"sound:    {'stereo' if self.channels == 2 else 'mono'}, {self.rate:.0f} Hz "
            f"(period {self.period}, {'PAL' if self.pal else 'NTSC'} clock)",
            f"timing:   {self.fps:.3f} frames/s, {self.audbytes} samples per frame",
            f"length:   {self.nframes} frames, {fmt_time(self.duration)}",
            f"frame:    {self.framesize} bytes ({self.videosize} picture + {self.audiosize} sound)",
            f"data rate: {self.framesize * self.fps / 1024:.0f} KB/s from disk",
            f"chip RAM: {3 * ((self.framesize + 7) & ~7) // 1024} KB for HAMPLAY's 3 buffers",
        ]
        if self.trailing:
            lines.append(f"warning:  {self.trailing} extra bytes at the end (incomplete frame)")
        if self.format.startswith("HAMV"):
            limit = 0xFFFF if self.planes == 6 else 0x18000
            ok = self.framesize <= limit
            lines.append(f"old players: frame {'fits' if ok else 'is TOO BIG for'} "
                         f"{'HAMNEW' if self.planes == 6 else 'HAMAGA'}'s buffer ({limit} bytes)")
        return "\n".join(lines)

    # -- pictures ----------------------------------------------------------

    def codes(self, i):
        """Pixel codes of frame i, as the Amiga reads them from the bitplanes."""
        planes = np.asarray(self.data[i, :self.videosize]).reshape(
            self.vres, self.planes, self.planebytes)
        bits = np.unpackbits(planes, axis=2)                 # (vres, planes, hres)
        weights = (1 << np.arange(self.planes, dtype=np.uint16))[None, :, None]
        return (bits.astype(np.uint16) * weights).sum(axis=1).astype(np.uint8)

    def rgb(self, i):
        """Frame i as displayed by the Amiga: (vres, hres, 3) uint8."""
        return ham_decode(self.codes(i), self.planes)

    # -- sound -------------------------------------------------------------

    def audio(self, first, count):
        """Sound of `count` frames from `first`: (samples, channels) int8."""
        count = max(0, min(count, self.nframes - first))
        if count == 0:
            return np.zeros((0, self.channels), dtype=np.int8)
        block = np.asarray(self.data[first:first + count, self.videosize:])
        block = block.view(np.int8).reshape(count, self.channels, self.audbytes)
        return block.transpose(0, 2, 1).reshape(count * self.audbytes, self.channels)


def ham_decode(codes, planes):
    """Hold-and-modify decoding, vectorised: each colour channel keeps the
    value of the last pixel that set it (palette pixel or modify pixel of
    that channel); the line starts from colour 0 (black)."""
    if planes == 6:
        ctl, val = codes >> 4, codes & 15
        level = val.astype(np.uint16) * 17                   # 4 -> 8 bits
    else:
        ctl, val = codes & 3, codes >> 2
        level = (val.astype(np.uint16) << 2) | (val >> 4)    # 6 -> 8 bits
    base = PALETTE[val]                                      # used where ctl == 0
    vres, hres = codes.shape
    cols = np.arange(hres, dtype=np.int32)[None, :]
    out = np.empty((vres, hres, 3), dtype=np.uint8)
    # modify codes: 1 = blue, 2 = red, 3 = green (same in HAM6 and HAM8)
    for channel, modify in ((0, 2), (1, 3), (2, 1)):
        sets = (ctl == 0) | (ctl == modify)
        value = np.where(ctl == 0, base[:, :, channel], level).astype(np.uint8)
        last = np.maximum.accumulate(np.where(sets, cols, -1), axis=1)
        held = np.take_along_axis(value, np.maximum(last, 0), axis=1)
        out[:, :, channel] = np.where(last >= 0, held, 0)
    return out


def fmt_time(seconds):
    seconds = max(0, int(seconds))
    return f"{seconds // 60}:{seconds % 60:02d}"


# --------------------------------------------------------------------------
# Export with ffmpeg
# --------------------------------------------------------------------------

def need_ffmpeg():
    if shutil.which("ffmpeg") is None:
        raise HamError("ffmpeg not found")


def write_wav(path, ham):
    with wave.open(path, "wb") as w:
        w.setnchannels(ham.channels)
        w.setsampwidth(1)
        w.setframerate(round(ham.rate))
        step = 500
        for first in range(0, ham.nframes, step):
            a = ham.audio(first, step)
            w.writeframes((a.astype(np.int16) + 128).astype(np.uint8).tobytes())


def export(ham, out_path, args):
    need_ffmpeg()
    sar = "16/15" if ham.pal else "5/6"
    with tempfile.TemporaryDirectory() as tmp:
        wav = os.path.join(tmp, "sound.wav")
        write_wav(wav, ham)
        cmd = ["ffmpeg", "-v", "error", "-y",
               "-f", "rawvideo", "-pix_fmt", "rgb24", "-s", f"{ham.hres}x{ham.vres}",
               "-framerate", f"{ham.fps:.6f}", "-i", "-", "-i", wav,
               # double the size without smoothing, keep the Amiga pixel shape
               "-vf", f"scale=iw*2:ih*2:flags=neighbor,setsar={sar}",
               "-c:v", "libx264", "-crf", "16", "-pix_fmt", "yuv420p",
               "-c:a", "aac", "-b:a", "128k", "-shortest", out_path]
        proc = subprocess.Popen(cmd, stdin=subprocess.PIPE)
        try:
            for i in range(ham.nframes):
                proc.stdin.write(ham.rgb(i).tobytes())
                if not args.quiet and i % 25 == 0:
                    print(f"\r  frame {i}/{ham.nframes}", end="", flush=True)
            proc.stdin.close()
        except BrokenPipeError:
            pass
        if proc.wait() != 0:
            raise HamError("ffmpeg failed")
    if not args.quiet:
        print(f"\r  {ham.nframes} frames written to {out_path}")


def snapshot(ham, index, out_path):
    need_ffmpeg()
    if not 0 <= index < ham.nframes:
        raise HamError(f"frame {index} out of range (0..{ham.nframes - 1})")
    _save_png(ham.rgb(index), out_path)


def _save_png(rgb, out_path):
    h, w = rgb.shape[:2]
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-f", "rawvideo", "-pix_fmt", "rgb24",
                    "-s", f"{w}x{h}", "-i", "-", "-frames:v", "1", out_path],
                   input=rgb.tobytes(), check=True)


# --------------------------------------------------------------------------
# Player (pygame)
# --------------------------------------------------------------------------

class Player:
    AUDIO_CHUNK = 0.5          # seconds of sound queued at a time

    def __init__(self, ham, args, pygame):
        self.ham, self.args, self.pg = ham, args, pygame
        self.aspect = not args.square
        self.scale = args.scale
        self.fullscreen = False
        self.show_info = True
        self.muted = args.mute
        self.message, self.message_until = "", 0.0

        pg = pygame
        self.sound_ok = False
        if not args.mute:
            try:
                pg.mixer.pre_init(frequency=round(ham.rate), size=-16, channels=2, buffer=1024)
                pg.mixer.init()
                self.mixer_rate = pg.mixer.get_init()[0]
                self.sound_ok = True
            except pg.error as e:
                print(f"no sound: {e}", file=sys.stderr)
        pg.display.init()
        pg.font.init()
        pg.display.set_caption(f"hamview - {os.path.basename(ham.path)}")
        self.font = pg.font.Font(None, 22)
        self.window = None
        self.open_window()

        self.frame = max(0, min(int(args.start * ham.fps), ham.nframes - 1))
        self.shown = -1
        self.playing = True
        self.channel = None
        self.start_playback()

    # -- window ------------------------------------------------------------

    def picture_size(self):
        par = PIXEL_ASPECT["PAL" if self.ham.pal else "NTSC"] if self.aspect else 1.0
        return round(self.ham.hres * self.scale * par), self.ham.vres * self.scale

    def open_window(self):
        pg = self.pg
        if self.fullscreen:
            self.window = pg.display.set_mode((0, 0), pg.FULLSCREEN)
        else:
            self.window = pg.display.set_mode(self.picture_size())
        self.shown = -1

    # -- sound -------------------------------------------------------------

    def make_sound(self, first, count):
        a = self.ham.audio(first, count).astype(np.int16) << 8
        if a.shape[1] == 1:
            a = np.repeat(a, 2, axis=1)
        if self.mixer_rate != round(self.ham.rate):          # mixer refused our rate
            n = len(a)
            m = max(1, round(n * self.mixer_rate / self.ham.rate))
            x = np.linspace(0, n - 1, m)
            a = np.stack([np.interp(x, np.arange(n), a[:, c]) for c in range(2)], axis=1).astype(np.int16)
        return self.pg.sndarray.make_sound(np.ascontiguousarray(a))

    def frames_per_chunk(self):
        return max(1, round(self.AUDIO_CHUNK * self.ham.fps))

    def start_playback(self):
        """(Re)start the clock and the sound from self.frame."""
        self.t0 = time.perf_counter()
        self.f0 = self.frame
        self.next_audio = self.frame
        if self.channel:
            self.channel.stop()
            self.channel = None
        if self.playing and self.sound_ok and not self.muted:
            n = self.frames_per_chunk()
            self.channel = self.make_sound(self.next_audio, n).play()
            self.next_audio += n
            self.feed_sound()

    def feed_sound(self):
        if self.channel and self.channel.get_queue() is None and self.next_audio < self.ham.nframes:
            n = self.frames_per_chunk()
            self.channel.queue(self.make_sound(self.next_audio, n))
            self.next_audio += n

    def stop_sound(self):
        if self.channel:
            self.channel.stop()
            self.channel = None

    # -- control -----------------------------------------------------------

    def say(self, text):
        self.message, self.message_until = text, time.perf_counter() + 2.0

    def seek(self, frame):
        self.frame = max(0, min(frame, self.ham.nframes - 1))
        self.start_playback() if self.playing else self.stop_sound()
        self.say(f"{fmt_time(self.frame / self.ham.fps)} / {fmt_time(self.ham.duration)}")

    def toggle_pause(self):
        self.playing = not self.playing
        if self.playing:
            if self.frame >= self.ham.nframes - 1:          # at the end: start again
                self.frame = 0
            self.start_playback()
            self.say("play")
        else:
            self.stop_sound()
            self.say("pause")

    def handle(self, event):
        pg, ham = self.pg, self.ham
        if event.type == pg.QUIT:
            return False
        if event.type != pg.KEYDOWN:
            return True
        k = event.key
        ten = round(10 * ham.fps)
        if k in (pg.K_ESCAPE, pg.K_q):
            return False
        elif k == pg.K_SPACE:
            self.toggle_pause()
        elif k == pg.K_RIGHT:
            self.seek(self.frame + ten)
        elif k == pg.K_LEFT:
            self.seek(self.frame - ten)
        elif k == pg.K_UP:
            self.seek(self.frame + 6 * ten)
        elif k == pg.K_DOWN:
            self.seek(self.frame - 6 * ten)
        elif k == pg.K_HOME:
            self.seek(0)
        elif k in (pg.K_PERIOD, pg.K_COMMA):
            if self.playing:
                self.toggle_pause()
            self.seek(self.frame + (1 if k == pg.K_PERIOD else -1))
            self.say(f"frame {self.frame}")
        elif k == pg.K_a:
            self.aspect = not self.aspect
            self.open_window()
            self.say("Amiga pixel shape" if self.aspect else "square pixels")
        elif k == pg.K_f:
            self.fullscreen = not self.fullscreen
            self.open_window()
        elif k == pg.K_m:
            self.muted = not self.muted
            self.start_playback() if self.playing else None
            self.say("sound off" if self.muted else "sound on")
        elif k == pg.K_i:
            self.show_info = not self.show_info
            self.shown = -1
        elif k == pg.K_s:
            name = f"{os.path.splitext(os.path.basename(ham.path))[0]}_{self.frame:05d}.png"
            surf = pg.surfarray.make_surface(ham.rgb(self.frame).swapaxes(0, 1))
            pg.image.save(surf, name)
            self.say(f"saved {name}")
        return True

    # -- drawing -----------------------------------------------------------

    def draw(self):
        pg, ham = self.pg, self.ham
        surf = pg.surfarray.make_surface(ham.rgb(self.frame).swapaxes(0, 1))
        ww, wh = self.window.get_size()
        pw, ph = self.picture_size()
        if self.fullscreen:                                   # fit the screen
            f = min(ww / pw, wh / ph)
            pw, ph = int(pw * f), int(ph * f)
        self.window.fill((0, 0, 0))
        self.window.blit(pg.transform.scale(surf, (pw, ph)), ((ww - pw) // 2, (wh - ph) // 2))
        now = time.perf_counter()
        lines = []
        if self.show_info:
            lines.append(f"{ham.mode} {ham.hres}x{ham.vres}  {ham.fps:.2f} fps  "
                         f"{fmt_time(self.frame / ham.fps)} / {fmt_time(ham.duration)}  "
                         f"frame {self.frame}/{ham.nframes}{'' if self.playing else '  [pause]'}")
        if now < self.message_until:
            lines.append(self.message)
        y = 4
        for text in lines:
            img = self.font.render(text, True, (255, 255, 255), (0, 0, 0))
            self.window.blit(img, (4, y))
            y += img.get_height() + 2
        pg.display.flip()
        self.shown = self.frame

    # -- main loop -----------------------------------------------------------

    def run(self):
        pg, ham = self.pg, self.ham
        clock = pg.time.Clock()
        running = True
        while running:
            for event in pg.event.get():
                if not self.handle(event):
                    running = False
                    break
            if not running:
                break
            if self.playing:
                self.frame = self.f0 + int((time.perf_counter() - self.t0) * ham.fps)
                if self.frame >= ham.nframes:
                    if self.args.loop:
                        self.frame = 0
                        self.start_playback()
                    else:
                        self.frame = ham.nframes - 1
                        self.playing = False
                        self.stop_sound()
                        self.say("end")
                self.feed_sound()
            if self.frame != self.shown or time.perf_counter() < self.message_until + 0.1:
                self.draw()
            clock.tick(100)
        self.stop_sound()
        pg.quit()


# --------------------------------------------------------------------------
# Main
# --------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(
        description="Check and play Amiga HAM videos (.hv / .h8v) on a PC.")
    parser.add_argument("video", help="HAM video file (.hv or .h8v)")
    parser.add_argument("--info", action="store_true", help="check the file and show its details")
    parser.add_argument("--export", metavar="OUT", help="convert to a normal video file with ffmpeg (e.g. out.mp4)")
    parser.add_argument("--snapshot", nargs=2, metavar=("FRAME", "OUT"),
                        help="save one frame as an image (e.g. --snapshot 100 frame.png)")
    parser.add_argument("--scale", type=int, default=3, help="window size factor (default 3)")
    parser.add_argument("--square", action="store_true", help="square pixels instead of the Amiga's pixel shape")
    parser.add_argument("--start", type=float, default=0.0, help="start position in seconds")
    parser.add_argument("--loop", action="store_true", help="play in a loop")
    parser.add_argument("--mute", action="store_true", help="no sound")
    parser.add_argument("-q", "--quiet", action="store_true")
    args = parser.parse_args()

    try:
        ham = HamFile(args.video)
        if args.info or not args.quiet:
            print(ham.describe())
        if args.info:
            return
        if args.snapshot:
            snapshot(ham, int(args.snapshot[0]), args.snapshot[1])
            return
        if args.export:
            export(ham, args.export, args)
            return
        try:
            import pygame
        except ImportError:
            raise HamError("playing needs pygame: pip install pygame "
                           "(or use --export to make an mp4 instead)")
        Player(ham, args, pygame).run()
    except HamError as e:
        print(f"error: {e}", file=sys.stderr)
        sys.exit(1)
    except (OSError, subprocess.CalledProcessError) as e:
        print(f"error: {e}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
