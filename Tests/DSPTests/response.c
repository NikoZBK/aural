#include "DSP.h"
#include <assert.h>
#include <math.h>
#include <stdio.h>

int main(void) {
    EQFilter filters[EQMaxFilters];
    enum { Points=513+EQMaxFilters+2 };
    double frequencies[Points], sampled[Points];
    double rates[]={32000,44100,48000,96000,192000};
    for (unsigned r=0;r<5;r++) {
        for (unsigned i=0;i<EQMaxFilters;i++) {
            unsigned type=i%8;
            filters[i]=(EQFilter){20*pow(1000,(i+.5)/EQMaxFilters),type<=EQFilterHighShelf ? (int)(i%7)*4.5-13.5 : 0,
                i%2 ? .05 : 50,type,i%5==0,i%3};
        }
        for (unsigned i=0;i<513;i++) frequencies[i]=20*pow(1000,i/512.0);
        for (unsigned i=0;i<EQMaxFilters;i++) frequencies[513+i]=filters[i].frequency;
        frequencies[Points-2]=0;frequencies[Points-1]=rates[r]/2;
        for (unsigned channel=EQChannelStereo;channel<=EQChannelRight;channel++) {
            assert(eq_response_filters_channel_samples(frequencies,Points,rates[r],filters,EQMaxFilters,-7.25,channel,sampled));
            for (unsigned i=0;i<Points;i++) {
                double scalar=eq_response_filters_channel(frequencies[i],rates[r],filters,EQMaxFilters,-7.25,channel);
                assert(isfinite(sampled[i]) && fabs(sampled[i]-scalar)<1e-8);
            }
        }
    }
    assert(eq_response_filters_channel_samples(frequencies,Points,48000,filters,0,3,EQChannelStereo,sampled));
    for (unsigned i=0;i<Points;i++) assert(sampled[i]==3);
    sampled[0]=123;
    assert(!eq_response_filters_channel_samples(frequencies,Points,48000,filters,EQMaxFilters+1,0,EQChannelStereo,sampled));
    assert(!eq_response_filters_channel_samples(frequencies,Points,48000,filters,1,0,EQChannelRight+1,sampled));
    assert(!eq_response_filters_channel_samples(frequencies,Points,0,filters,1,0,EQChannelStereo,sampled));
    assert(!eq_response_filters_channel_samples(frequencies,Points,NAN,filters,1,0,EQChannelStereo,sampled));
    assert(!eq_response_filters_channel_samples(frequencies,Points,48000,filters,1,INFINITY,EQChannelStereo,sampled));
    assert(sampled[0]==123);
    puts("PASS batched/scalar response parity for all filters, full filter capacity, L/R, disabled filters, exact centers, DC/Nyquist, five rates, and rejected configurations");
}
