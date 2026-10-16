# avi4hv: any video to Amiga HAM

Convert any video into HAM6 (every Amiga) or HAM8 (AGA) videos with sound,
and play them on a real Amiga, in an emulator, or on a PC.

Based on AVI4HV / AVI4AGA and the HAMNEW / HAMAGA players by damage_x
(http://www.hyakushiki.net/), with Workbench support by Roy Schneider.
The original 2014 files are kept in [`original/`](original/).

| Path | What it is |
|---|---|
| `video2ham.py` | Converter: any video in, `.hv` (HAM6) and/or `.h8v` (HAM8) out |
| `hamview.py` | PC checker and player for `.hv` / `.h8v` files |
| `amiga/HAMPLAY` | Amiga player (HAM6 + HAM8, OCS/ECS/AGA, PAL/NTSC) |
| `amiga/hamplay.s`, `amiga/hamplay_core.s` | Player source (vasm) |
| `disk/` | Startup-Sequence, ReadMe and FS-UAE configs for a bootable test disk |
| `tests/` | Unit tests of the player core on the Musashi 68000 emulator |
| `original/` | The original BASIC converters, assembler players and shell script |

## Converter: `video2ham.py`

Requires Python 3.8+, numpy and ffmpeg/ffprobe in the PATH. Works on
Linux, macOS and Windows.

ffmpeg decodes, resizes and resamples the source directly through pipes;
no intermediate AVI or WAV file is needed.

```sh
python3 video2ham.py movie.mkv                  # HAM6, NTSC timing
python3 video2ham.py -m both --pal movie.mkv    # HAM6 + HAM8, PAL timing
python3 video2ham.py --start 1:00 --duration 30 -o clip movie.mp4
python3 video2ham.py --help                     # all options
```

- **Aspect ratio:** the picture keeps its aspect ratio, and only the
  picture lines are stored (no black bars), so 16:9 videos are smaller and
  play faster. `--pad` restores the old full-height behaviour.
- **Sound:** normalised by default (`--no-normalize` to disable;
  `--compress` for quiet dialogue). Audio and video stay in sync over long
  videos.
- **PAL / NTSC:** `--pal` computes the sound period for the PAL clock and
  uses PAL-friendly frame rates (HAM6 16.7 fps, HAM8 12.5 fps).
  HAMPLAY corrects the pitch on the other kind of machine anyway.
- **Old players:** `--legacy` writes the old `HAMV` header for HAMNEW /
  HAMAGA.

### File format `HAM2`

`"HAM2"`, then 8 big-endian 16-bit words:
1. audio samples per frame and channel
2. audio period
3. channels
4. lines (vres)
5. width (hres)
6. bitplanes (6 or 8)
7. flags (bit 0: period computed for the PAL clock)
8. reserved

Then, for each frame:
- `vres` lines, each holding its bitplanes one after another
  (`hres/8` bytes each);
- the frame's sound, as signed 8-bit samples (left channel, then right).

The old `HAMV` header has only the first 5 words, and uses the NTSC clock.

## Amiga player: `amiga/HAMPLAY`

```
HAMPLAY [BENCH] <file>
```

- Plays HAM6 on any Amiga and HAM8 on AGA. It detects the chipset and
  PAL/NTSC itself.
- Reads both `HAM2` and the old `HAMV` files.
- Runs from the Shell or from a Workbench icon.

| Control | Action |
|---|---|
| Space, or right mouse button | pause |
| Cursor Left / Right | -10 s / +10 s |
| Cursor Down / Up | -1 min / +1 min |
| Esc / Q, or left mouse button | quit |

`BENCH` reads the file as fast as possible, without sound, and reports the
frame rate this machine and disk can sustain.

To rebuild the player:

```sh
cd amiga && vasmm68k_mot -Fhunkexe -nosym -o HAMPLAY hamplay.s
```

## PC viewer: `hamview.py`

Requires numpy; pygame for playing, ffmpeg for exporting.

```sh
python3 hamview.py --info video.hv           # check the file
python3 hamview.py video.h8v                 # play (Space, arrows, F, M, Esc...)
python3 hamview.py --export out.mp4 video.hv
python3 hamview.py --snapshot 100 f.png video.hv
```

The decoder simulates the Amiga's HAM display, so what you see is what the
Amiga shows.

## Tests

```sh
git clone https://github.com/kstenerud/Musashi
make -C tests MUSASHI=$PWD/Musashi test     # needs vasmm68k_mot in PATH (or VASM=...)
```

## Test disk for an emulator

Make a hard disk image with `disk/`, `amiga/HAMPLAY` in its root, and a
`Videos/` folder of converted clips. For example, with amitools:

```sh
rdbtool hamtest.hdf create size=48Mi + init + add size=100% dostype=ffs bootable=1
xdftool hamtest.hdf open part=DH0 + format HAMTEST ffs + write disk/S S \
        + write amiga/HAMPLAY HAMPLAY + write Videos Videos
```

Then boot it with `disk/hamtest-a1200.fs-uae` (AGA) or
`disk/hamtest-a500.fs-uae` (ECS); you need your own Kickstart ROM. The
Startup-Sequence runs a benchmark, then plays each clip.
