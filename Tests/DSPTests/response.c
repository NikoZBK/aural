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
            unsigned type=i%10;
            filters[i]=(EQFilter){20*pow(1000,(i+.5)/EQMaxFilters),type<=EQFilterHighShelf || type>EQFilterAllPass ? (int)(i%7)*4.5-13.5 : 0,
                i%2 ? .05 : 50,type,i%5==0,i%5};
        }
        for (unsigned i=0;i<513;i++) frequencies[i]=20*pow(1000,i/512.0);
        for (unsigned i=0;i<EQMaxFilters;i++) frequencies[513+i]=filters[i].frequency;
        frequencies[Points-2]=0;frequencies[Points-1]=rates[r]/2;
        for (unsigned channel=EQChannelStereo;channel<=EQChannelSide;channel++) {
            assert(eq_response_filters_channel_samples(frequencies,Points,rates[r],filters,EQMaxFilters,-7.25,channel,sampled));
            for (unsigned i=0;i<Points;i++) {
                double scalar=eq_response_filters_channel(frequencies[i],rates[r],filters,EQMaxFilters,-7.25,channel);
                assert(isfinite(sampled[i]) && fabs(sampled[i]-scalar)<1e-8);
            }
        }
    }
    // Independently: without Mid/Side filters, each channel's dB responses add, and with
    // only Mid and Stereo filters so do the mid component's; Side passes Stereo filters.
    for (unsigned mode=0;mode<2;mode++) {
        for (unsigned i=0;i<EQMaxFilters;i++) {
            filters[i].channel=mode ? (i%2 ? EQChannelMid : EQChannelStereo) : i%3;
            if (filters[i].type==EQFilterNotch) filters[i].type=EQFilterPeak; // no -infinite sums
        }
        const unsigned channels[2][3]={{EQChannelLeft,EQChannelRight,EQChannelStereo},{EQChannelMid,EQChannelSide,EQChannelStereo}};
        double results[3][Points];
        for (unsigned k=0;k<3;k++)
            assert(eq_response_filters_channel_samples(frequencies,Points,44100,filters,EQMaxFilters,-2,channels[mode][k],results[k]));
        for (unsigned i=0;i<Points;i++) {
            double sums[2]={-2,-2};
            for (unsigned b=0;b<EQMaxFilters;b++) {
                EQFilter one=filters[b]; unsigned target=one.channel; one.channel=EQChannelStereo;
                double gain=eq_response_filters_channel(frequencies[i],44100,&one,1,0,EQChannelStereo);
                if (mode ? true : target!=EQChannelRight) sums[0]+=gain;
                if (mode ? target==EQChannelStereo : target!=EQChannelLeft) sums[1]+=gain;
            }
            // The product of complex responses rounds differently far below audibility.
            for (unsigned k=0;k<2;k++) assert(sums[k]<-150 ? results[k][i]<-149 : fabs(results[k][i]-sums[k])<1e-8*fmax(1,fabs(sums[k])));
            if (mode==0) assert(results[2][i]==fmax(results[0][i],results[1][i]));
            else assert(results[2][i]>=fmax(results[0][i],results[1][i])-1e-9); // either output's worst case
        }
    }
    assert(eq_response_filters_channel_samples(frequencies,Points,48000,filters,0,3,EQChannelStereo,sampled));
    for (unsigned i=0;i<Points;i++) assert(sampled[i]==3);
    sampled[0]=123;
    assert(!eq_response_filters_channel_samples(frequencies,Points,48000,filters,EQMaxFilters+1,0,EQChannelStereo,sampled));
    assert(!eq_response_filters_channel_samples(frequencies,Points,48000,filters,1,0,EQChannelSide+1,sampled));
    filters[0].channel=EQChannelSide+1;
    assert(!eq_response_filters_channel_samples(frequencies,Points,48000,filters,1,0,EQChannelStereo,sampled));
    assert(!eq_response_filters_channel_samples(frequencies,Points,0,filters,1,0,EQChannelStereo,sampled));
    assert(!eq_response_filters_channel_samples(frequencies,Points,NAN,filters,1,0,EQChannelStereo,sampled));
    assert(!eq_response_filters_channel_samples(frequencies,Points,48000,filters,1,INFINITY,EQChannelStereo,sampled));
    assert(sampled[0]==123);
    puts("PASS batched/scalar response parity for all filters, full filter capacity, L/R/M/S, independent channel and mid sums, disabled filters, exact centers, DC/Nyquist, five rates, and rejected configurations");
}
