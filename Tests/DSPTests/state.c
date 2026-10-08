// White-box checks of engine state that the public API cannot observe.
#include "../../Sources/DSP/DSP.c"
#include <assert.h>
#include <stdio.h>

static unsigned nonzero_state(const EQ *eq) {
    unsigned count=0;
    for (unsigned bank=0;bank<2;bank++) for (unsigned c=0;c<2;c++) {
        const Chain *chain=&eq->chains[bank];
        for (unsigned b=0;b<EQMaxFilters;b++) count+=(chain->z1[c][b]!=0)+(chain->z2[c][b]!=0);
        count+=chain->crossfeedLow[c]!=0;
    }
    return count;
}
// Silence after loud noise must bring filter and crossfeed state to exact zero,
// not leave it cycling in the subnormal range (slow on Intel, forever).
static void silence_tests(void) {
    const double rates[]={44100,48000,96000,192000};
    EQFilter f[]={
        {105,6,.7,EQFilterLowShelf,false,EQChannelStereo},
        {25,3,2,EQFilterPeak,false,EQChannelStereo},
        {200,-2,1,EQFilterPeak,false,EQChannelLeft},
        {3000,-3,3,EQFilterPeak,false,EQChannelStereo},
        {10000,3,.7,EQFilterHighShelf,false,EQChannelRight},
        {15,0,.7,EQFilterHighPass,false,EQChannelStereo},
        {40,4,5,EQFilterPeak,false,EQChannelStereo},
    };
    for (unsigned r=0;r<sizeof rates/sizeof *rates;r++) {
        EQ *eq=eq_create(rates[r],0); assert(eq);
        EQStereo s=eq_stereo_default(); s.crossfeed=.3;
        assert(eq_update_filters_stereo(eq,f,7,-7,false,&s));
        float in[512*2],out[512*2];
        AudioBufferList input={1,{{2,sizeof in,in}}}, output={1,{{2,sizeof out,out}}};
        unsigned seed=1, second=(unsigned)(rates[r]/512);
        for (unsigned b=0;b<second;b++) {
            for (unsigned i=0;i<1024;i++) { seed=seed*1664525+1013904223; in[i]=.5f*((seed>>8)/(float)(1<<24)-.5f); }
            eq_process(eq,&input,&output);
        }
        assert(nonzero_state(eq)>0);
        for (unsigned i=0;i<1024;i++) in[i]=0;
        // The slowest pole (the 40 Hz Q5 peak, ~20 Np/s) falls below -600 dB
        // within 10 s; without a flush, faster filters are stuck subnormal by then.
        for (unsigned b=0;b<10*second;b++) eq_process(eq,&input,&output);
        assert(nonzero_state(eq)==0);
        for (unsigned i=0;i<1024;i++) assert(out[i]==0);
        assert(eq_faults(eq)==0 && eq_signal_faults(eq)==0);
        eq_destroy(eq);
    }
    printf("PASS silence flushes filter and crossfeed state to zero at four rates\n");
}
int main(void) {
    silence_tests();
    return 0;
}
