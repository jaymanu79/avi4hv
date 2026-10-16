# Unit tests of amiga/hamplay_core.s on the Musashi 68000 emulator.
#   git clone https://github.com/kstenerud/Musashi
#   make MUSASHI=path/to/Musashi test   (vasmm68k_mot in PATH, or VASM=...)
MUSASHI ?= ../../Musashi
CFLAGS  ?= -O2
CFLAGS  += -I$(MUSASHI) -DM68K_ILLG_HAS_CALLBACK=M68K_OPT_ON

harness: harness.c
	$(MAKE) -C $(MUSASHI) m68kops.c
	$(CC) $(CFLAGS) -o $@ harness.c $(MUSASHI)/m68kcpu.c $(MUSASHI)/m68kops.c \
	    $(MUSASHI)/m68kdasm.c $(MUSASHI)/softfloat/softfloat.c -lm

test: harness
	python3 run_tests.py

clean:
	rm -f harness test.s test.bin test.lst mem.bin

.PHONY: test clean
