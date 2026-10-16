HAMPLAY test disk
=================

HAMPLAY plays HAM6 (.hv, any Amiga) and HAM8 (.h8v, AGA) videos with
sound, adapting itself to the chipset (OCS/ECS/AGA) and to PAL/NTSC.

  HAMPLAY [BENCH] <file>

  Space          pause / resume
  Cursor Left    back 10 s           Cursor Right   forward 10 s
  Cursor Down    back 1 min          Cursor Up      forward 1 min
  Esc / Q        quit
  Right button   pause               Left button    quit

  BENCH reads the file as fast as possible, without sound, and tells
  how many frames per second this machine can play.

Videos (synthetic test clips made with ffmpeg, free to use):
  demo169.hv    HAM6, 320x192 (16:9), 16.7 fps PAL, 16 s
  demo169.h8v   HAM8, 336x202 (16:9), 12.5 fps PAL, 16 s
  demo43.hv     HAM6, 320x256 (4:3, full height), 16.7 fps PAL, 8 s
  legacy.hv     old 'HAMV' format (320x216 with black bars), 15 fps, 5 s

Needs Kickstart 2.04 or newer to boot this disk (3.1 for HAM8 / AGA).
Videos made with video2ham.py; player based on HAMNEW/HAMAGA by damage_x.
