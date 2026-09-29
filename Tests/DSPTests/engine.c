#include "DSP.h"
#include <assert.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

static double measure(EQ *eq, double rate, double frequency, double *correlation) {
    float in[256],out[256];
    AudioBufferList input={1,{{2,sizeof(in),in}}}, output={1,{{2,sizeof(out),out}}};
    double powerIn=0,powerOut=0,cross=0,ss=0,cc=0,sc=0,ys=0,yc=0;
    for (unsigned block=0;block<600;block++) {
        for (unsigned i=0;i<128;i++) {
            in[2*i]=.02*sin(2*M_PI*frequency*(block*128+i)/rate);
            in[2*i+1]=0;
        }
        eq_process(eq,&input,&output);
        for (unsigned i=0;i<128;i++) {
            assert(isfinite(out[2*i]) && fabs(out[2*i])<=.981 && out[2*i+1]==0);
            if(block>=400) {
                powerIn+=in[2*i]*in[2*i]; powerOut+=out[2*i]*out[2*i]; cross+=in[2*i]*out[2*i];
                double phase=2*M_PI*frequency*(block*128+i)/rate;
                double sine=.02*sin(phase), cosine=.02*cos(phase);
                ss+=sine*sine; cc+=cosine*cosine; sc+=sine*cosine;
                ys+=out[2*i]*sine; yc+=out[2*i]*cosine;
            }
        }
    }
    assert(eq_faults(eq)==0);
    if (correlation) *correlation=cross/sqrt(powerIn*powerOut);
    // Fit both quadratures: a finite, non-integral cycle window biases RMS ratios
    // when the filter shifts phase, especially at low frequency/high sample rate.
    double determinant=ss*cc-sc*sc;
    double sineGain=(ys*cc-yc*sc)/determinant, cosineGain=(yc*ss-ys*sc)/determinant;
    return 10*log10(fmax(1e-30,sineGain*sineGain+cosineGain*cosineGain));
}
int main(void) {
    const double rates[]={32000,44100,48000,96000,192000};
    for (unsigned r=0;r<5;r++) {
        double rate=rates[r];
        for (unsigned type=EQFilterLowPass;type<=EQFilterAllPass;type++) {
            EQ *eq=eq_create(rate,0); assert(eq);
            EQFilter filter={1000,0,M_SQRT1_2,type,false};
            assert(eq_update_filters(eq,&filter,1,0,false));
            double phase,db=measure(eq,rate,1000,&phase);
            if(type==EQFilterLowPass || type==EQFilterHighPass) assert(fabs(db+3.01029995664)<.02);
            if(type==EQFilterBandPass || type==EQFilterAllPass) assert(fabs(db)<.02);
            if(type==EQFilterNotch) assert(db < -100);
            if(type==EQFilterAllPass) assert(phase < -.999); // all-pass must change phase, not be identity
            for(unsigned i=0;i<3;i++) {
                double f=(double[]){100,1700,10000}[i];
                double expected=eq_response_filters(f,rate,&filter,1,0);
                assert(isfinite(expected));
                double actual=measure(eq,rate,f,NULL);
                if (fabs(actual-expected)>=.04) fprintf(stderr,"rate %.0f type %u frequency %.0f actual %.8f expected %.8f\n",rate,type,f,actual,expected);
                assert(fabs(actual-expected)<.04);
            }
            double low=eq_response_filters(100,rate,&filter,1,0);
            double high=eq_response_filters(10000,rate,&filter,1,0);
            if(type==EQFilterLowPass) assert(fabs(low)<.01 && high < -40);
            if(type==EQFilterHighPass) assert(low < -40 && fabs(high)<.01);
            if(type==EQFilterBandPass) assert(low < -15 && high < -15);
            filter.disabled=true;
            assert(eq_update_filters(eq,&filter,1,-3,false));
            assert(fabs(measure(eq,rate,1000,NULL)+3)<.02);
            assert(fabs(eq_response_filters(1000,rate,&filter,1,-3)+3)<1e-9);
            filter.disabled=false;
            assert(eq_update_filters(eq,&filter,1,-12,true));
            assert(fabs(measure(eq,rate,1000,NULL))<.02);
            eq_destroy(eq);
        }
    }
    puts("PASS pass/notch/all-pass magnitude, phase, stereo isolation, disabled filters and bypass at five rates");

    // Disabled gain filters must preserve their saved gain while acting as identity.
    for(unsigned type=0;type<=EQFilterHighShelf;type++) {
        EQ *eq=eq_create(48000,0); EQFilter filter={1000,12,.7,type,true};
        assert(eq_update_filters(eq,&filter,1,0,false));
        assert(fabs(measure(eq,48000,1000,NULL))<.001);
        assert(eq_response_filters(1000,48000,&filter,1,0)==0);
        eq_destroy(eq);
    }
    EQ *eq=eq_create(48000,0); assert(eq);
    EQFilter invalid={1000,1,.7,EQFilterLowPass,false};
    assert(!eq_update_filters(eq,&invalid,1,0,false));
    invalid.gain=0; invalid.frequency=24000; assert(!eq_update_filters(eq,&invalid,1,0,false));
    invalid.frequency=22000;
    EQ *lowRate=eq_create(32000,0); assert(!eq_update_filters(lowRate,&invalid,1,0,false));
    invalid.disabled=true; assert(eq_update_filters(lowRate,&invalid,1,0,false)); eq_destroy(lowRate);
    invalid.frequency=1000;invalid.type=99;assert(!eq_update_filters(eq,&invalid,1,0,false));
    eq_destroy(eq);
    puts("PASS control-side filter validation and explicit disabled EQ gain preservation");

    // Constant input isolates transition steps from the input waveform itself.
    // Rapid requests during a fade must not reset its state; the last target wins.
    eq=eq_create(48000,0);
    float in[128],out[128];
    for(unsigned i=0;i<128;i++) in[i]=.05;
    AudioBufferList input={1,{{2,sizeof(in),in}}}, output={1,{{2,sizeof(out),out}}};
    EQFilter filter={1000,0,.707,EQFilterHighPass,false};
    assert(eq_update_filters(eq,&filter,1,0,false));
    double previous=.05,largestStep=0;
    for(unsigned block=0;block<160;block++) {
        if(block<40) {
            filter.type=block%2 ? EQFilterLowPass : EQFilterHighPass;
            assert(eq_update_filters(eq,&filter,1,0,false));
        }
        if(block==40) {filter.disabled=true; assert(eq_update_filters(eq,&filter,1,0,false));}
        eq_process(eq,&input,&output);
        for(unsigned i=0;i<64;i++) {
            largestStep=fmax(largestStep,fabs(out[2*i]-previous));previous=out[2*i];
            assert(isfinite(previous) && out[2*i]==out[2*i+1]);
        }
    }
    assert(largestStep<.001 && fabs(previous-.05)<1e-6 && eq_faults(eq)==0);
    // Malformed and nonfinite input must surface a fault without leaking bad output.
    in[0]=NAN; eq_process(eq,&input,&output); assert(eq_faults(eq)>0);
    for(unsigned i=0;i<128;i++) assert(isfinite(out[i]));
    unsigned faults=eq_faults(eq); input.mBuffers[0].mDataByteSize-=1;
    eq_process(eq,&input,&output); assert(eq_faults(eq)==faults+1);
    for(unsigned i=0;i<128;i++) assert(out[i]==0);
    eq_destroy(eq);
    printf("PASS rapid transitions, latest target, continuity (max step %.8f), malformed input and fault containment\n",largestStep);

    // Worst supported chain size and extreme Q/frequency values, with real callback sizes.
    clock_t begin=clock();
    for(unsigned r=0;r<5;r++) {
        eq=eq_create(rates[r],0); EQFilter filters[EQMaxFilters];
        input.mBuffers[0].mDataByteSize=sizeof(in);
        for(unsigned block=0;block<2000;block++) {
            if(block%80==0) {
                for(unsigned b=0;b<EQMaxFilters;b++) {
                    unsigned type=(b+block/80)%8;
                    filters[b]=(EQFilter){b%2 ? 10 : fmin(22000,rates[r]*.48),type<3 ? (b%2 ? 30 : -30) : 0,
                        b%2 ? .05 : 50,type,block%160==0};
                }
                assert(eq_update_filters(eq,filters,EQMaxFilters,-12,false));
            }
            for(unsigned i=0;i<128;i++) in[i]=.1*sin((block*128+i)*.17);
            eq_process(eq,&input,&output);
            for(unsigned i=0;i<128;i++) assert(isfinite(out[i]) && fabs(out[i])<=.981);
        }
        assert(eq_faults(eq)==0);eq_destroy(eq);
    }
    printf("PASS 32-filter extreme-value stress at five rates (CPU %.3fs, sanitizer build)\n",(double)(clock()-begin)/CLOCKS_PER_SEC);
}
