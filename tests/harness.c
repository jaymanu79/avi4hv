#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "m68k.h"
#define MEMSIZE 0x100000
static unsigned char mem[MEMSIZE];
static int done=0;
unsigned int rd8(unsigned a){a&=MEMSIZE-1;return mem[a];}
unsigned int rd16(unsigned a){return (rd8(a)<<8)|rd8(a+1);}
unsigned int rd32(unsigned a){return (rd16(a)<<16)|rd16(a+2);}
void wr8(unsigned a,unsigned v){a&=MEMSIZE-1;mem[a]=v;}
void wr16(unsigned a,unsigned v){wr8(a,v>>8);wr8(a+1,v);}
void wr32(unsigned a,unsigned v){wr16(a,v>>16);wr16(a+2,v);}
unsigned int m68k_read_memory_8(unsigned int a){return rd8(a);}
unsigned int m68k_read_memory_16(unsigned int a){return rd16(a);}
unsigned int m68k_read_memory_32(unsigned int a){return rd32(a);}
unsigned int m68k_read_disassembler_16(unsigned int a){return rd16(a);}
unsigned int m68k_read_disassembler_32(unsigned int a){return rd32(a);}
void m68k_write_memory_8(unsigned int a,unsigned int v){wr8(a,v);}
void m68k_write_memory_16(unsigned int a,unsigned int v){wr16(a,v);}
void m68k_write_memory_32(unsigned int a,unsigned int v){wr32(a,v);}
int illegal_cb(int op){done=1;m68k_end_timeslice();return 1;}
int main(int argc,char**argv){
  FILE*f=fopen(argv[1],"rb");unsigned org=strtoul(argv[2],0,0);
  size_t n=fread(mem+org,1,MEMSIZE-org,f);fclose(f);
  wr32(0,0x000F0000); wr32(4,org); /* reset vectors: SSP, PC */
  m68k_init(); m68k_set_cpu_type(M68K_CPU_TYPE_68000);
  m68k_set_illg_instr_callback(illegal_cb);
  m68k_pulse_reset();
  long cycles=0;
  while(!done && cycles<2000000000L){cycles+=m68k_execute(100000);}
  fprintf(stderr,"cycles=%ld done=%d pc=%x\n",cycles,done,m68k_get_reg(NULL,M68K_REG_PC));
  FILE*o=fopen(argv[3],"wb");fwrite(mem,1,MEMSIZE,o);fclose(o);
  return done?0:1;
}
