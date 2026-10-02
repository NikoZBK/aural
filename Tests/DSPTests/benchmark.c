#include "DSP.h"
#include <assert.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>

static double now(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC,&t); return t.tv_sec+t.tv_nsec*1e-9; }
static int compare(const void *a,const void *b) { double x=*(const double*)a,y=*(const double*)b;return (x>y)-(x<y); }
int main(void) {
    enum { Frames=64, Blocks=10000 };
    double times[Blocks],sum=0;
    float in[Frames*2],out[Frames*2];
    AudioBufferList input={1,{{2,sizeof(in),in}}},output={1,{{2,sizeof(out),out}}};
    EQ *eq=eq_create(192000,0);assert(eq);
    EQFilter filters[EQMaxFilters];
    for(unsigned i=0;i<Frames*2;i++)in[i]=.01*sin(i*.2);
    for(unsigned block=0;block<Blocks;block++) {
        if(block%8==0) {
            for(unsigned i=0;i<EQMaxFilters;i++) {
                unsigned type=i%8;
                filters[i]=(EQFilter){100+i*500+(block%2),type<3 ? 2 : 0,.707,type,false,EQChannelStereo};
            }
            // Alternate preamp so the benchmark includes repeated two-chain fades.
            assert(eq_update_filters(eq,filters,EQMaxFilters,block%16 ? -10 : -12,false));
        }
        double start=now();eq_process(eq,&input,&output);times[block]=now()-start;sum+=times[block];
        for(unsigned i=0;i<Frames*2;i++)assert(isfinite(out[i])&&fabs(out[i])<=.981);
    }
    assert(eq_faults(eq)==0);eq_destroy(eq);
    qsort(times,Blocks,sizeof(double),compare);
    printf("192 kHz / 64 frames / 32 filters / repeated transitions: mean %.2f us, p99 %.2f us, max %.2f us; buffer budget %.2f us\n",
        sum/Blocks*1e6,times[Blocks*99/100]*1e6,times[Blocks-1]*1e6,Frames/192000.0*1e6);
}
