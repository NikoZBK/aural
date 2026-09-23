#include "DSP.h"
#include <assert.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define N 48000
static float source[N*4], dest[N*2];
static void process(EQ *eq, unsigned channels) {
    AudioBufferList in={1,{{channels,N*channels*sizeof(float),source}}};
    AudioBufferList out={1,{{2,sizeof(dest),dest}}};
    eq_process(eq,&in,&out);
}
static double rms(float *a, int start, int end) {
    double sum=0; for(int i=start;i<end;i++) sum+=(double)a[i]*a[i];
    return sqrt(sum/(end-start));
}
static void tone(float scale, float right) {
    for(int i=0;i<N;i++) {source[2*i]=scale*sin(2*M_PI*1000*i/48000);source[2*i+1]=source[2*i]*right;}
}
int main(void) {
    double gains[10]={0};
    EQ *eq=eq_create(48000,0); assert(eq);
    tone(.1,0); process(eq,2);
    for(int i=0;i<N*2;i++) assert(source[i]==dest[i]); assert(eq_faults(eq)==0);
    puts("PASS flat response and stereo isolation");
    gains[5]=6; assert(eq_update(eq,gains,0,false)); tone(.1,1);process(eq,2);
    double measured=20*log10(rms(dest,N,N*2)/rms(source,N,N*2));
    assert(fabs(measured-6)<.02); assert(fabs(eq_response(1000,48000,gains,0)-measured)<.02);
    printf("PASS measured 1 kHz boost: %.4f dB\n",measured);
    assert(eq_update(eq,gains,-6,false));process(eq,2);process(eq,2);
    assert(fabs(rms(dest,N,N*2)-rms(source,N,N*2))<.0001);
    assert(eq_update(eq,gains,-12,true));process(eq,2);
    assert(fabs(rms(dest,N,N*2)-rms(source,N,N*2))<.0001);
    puts("PASS preamp headroom and bypass");eq_destroy(eq);
    double rates[]={32000,44100,48000,96000,192000};
    for(int r=0;r<5;r++) {
        eq=eq_create(rates[r],0); assert(eq);
        for(int b=0;b<10;b++) gains[b]=12;
        assert(eq_update(eq,gains,0,false));tone(2,1);process(eq,2);
        for(int i=0;i<N*2;i++) assert(isfinite(dest[i])&&fabs(dest[i])<=.981);
        eq_destroy(eq);
    }
    puts("PASS limiter and stability at five sample rates");
    eq=eq_create(48000,2);assert(eq);
    for(int i=0;i<N;i++){source[4*i]=.8;source[4*i+1]=.9;source[4*i+2]=.1;source[4*i+3]=-.2;}
    process(eq,4);
    for(int i=0;i<N;i++){assert(dest[2*i]==(float).1);assert(dest[2*i+1]==(float)-.2);}
    puts("PASS hardware input channels skipped");eq_destroy(eq);
    eq=eq_create(48000,0);assert(eq);memset(gains,0,sizeof(gains));gains[0]=NAN;
    assert(!eq_update(eq,gains,0,false));gains[0]=0;assert(!eq_update(eq,gains,1,false));
    for(int i=0;i<63;i++) assert(eq_update(eq,gains,0,false));
    assert(!eq_update(eq,gains,0,false));tone(.1,1);process(eq,2);assert(eq_update(eq,gains,0,false));
    puts("PASS invalid parameters and queue saturation");eq_destroy(eq);
    eq=eq_create(48000,0);assert(eq);
    size_t bytes=offsetof(AudioBufferList,mBuffers)+2*sizeof(AudioBuffer);
    AudioBufferList *planar=calloc(1,bytes);assert(planar);planar->mNumberBuffers=2;
    float left[128],right[128],outL[128],outR[128];
    for(int i=0;i<128;i++){left[i]=.1;right[i]=-.1;}
    planar->mBuffers[0]=(AudioBuffer){1,sizeof(left),left};planar->mBuffers[1]=(AudioBuffer){1,sizeof(right),right};
    AudioBufferList *out=calloc(1,bytes);assert(out);out->mNumberBuffers=2;
    out->mBuffers[0]=(AudioBuffer){1,sizeof(outL),outL};out->mBuffers[1]=(AudioBuffer){1,sizeof(outR),outR};
    eq_process(eq,planar,out);assert(memcmp(left,outL,sizeof(left))==0);assert(memcmp(right,outR,sizeof(right))==0);
    planar->mBuffers[1].mData=NULL;eq_process(eq,planar,out);assert(eq_faults(eq)==1);
    for(int i=0;i<128;i++)assert(outL[i]==0&&outR[i]==0);
    puts("PASS planar buffers and invalid-buffer fault reporting");free(planar);free(out);eq_destroy(eq);
    EQFilter custom={1000,6,.707,0};
    for(unsigned type=0;type<3;type++) {
        eq=eq_create(48000,0);assert(eq);custom.type=type;
        assert(eq_update_filters(eq,&custom,1,0,false));tone(.1,1);process(eq,2);
        double db=20*log10(rms(dest,N,N*2)/rms(source,N,N*2));
        double expected=type==0 ? 6 : 3;
        assert(fabs(db-expected)<.02);
        assert(fabs(eq_response_filters(1000,48000,&custom,1,0)-db)<.02);
        if(type==1) {assert(fabs(eq_response_filters(10,48000,&custom,1,0)-6)<.01);assert(fabs(eq_response_filters(20000,48000,&custom,1,0))<.01);}
        if(type==2) {assert(fabs(eq_response_filters(10,48000,&custom,1,0))<.01);assert(fabs(eq_response_filters(20000,48000,&custom,1,0)-6)<.01);}
        eq_destroy(eq);
    }
    custom=(EQFilter){1234,-7.3,3.21,0};
    assert(fabs(eq_response_filters(1234,48000,&custom,1,-6.7)+14)<.001);
    custom.q=.7;double wide=eq_response_filters(2000,48000,&custom,1,0);
    custom.q=5;double narrow=eq_response_filters(2000,48000,&custom,1,0);assert(wide<narrow-1);
    eq=eq_create(48000,0);assert(eq);custom.type=3;assert(!eq_update_filters(eq,&custom,1,0,false));
    custom.type=0;custom.q=0;assert(!eq_update_filters(eq,&custom,1,0,false));
    assert(!eq_update_filters(eq,&custom,33,0,false));eq_destroy(eq);
    puts("PASS imported peaking, low/high shelves, custom frequency/Q, response consistency, and validation");
    // Keep one engine alive while switching filter count, frequency, Q and kind.
    eq=eq_create(48000,0);assert(eq);
    EQFilter layouts[4][10]={
        {{1000,4,1.4,0},{3000,-2,1.4,0},{8000,3,1.4,0}},
        {{120,3,.7,1},{1000,-5,2,0},{6000,2,.8,2}},
        {{1000,6,.707,0}},
        {{31.5,2,1.4,0},{63,3,1.4,0},{125,2,1.4,0},{250,1,1.4,0},
         {500,0,1.4,0},{1000,0,1.4,0},{2000,-1,1.4,0},{4000,-1,1.4,0},
         {8000,0,1.4,0},{16000,0,1.4,0}}
    };
    unsigned counts[]={3,3,1,10};
    float liveIn[256],liveOut[256];
    AudioBufferList liveInput={1,{{2,sizeof(liveIn),liveIn}}};
    AudioBufferList liveOutput={1,{{2,sizeof(liveOut),liveOut}}};
    for(int preset=0;preset<4;preset++) {
        assert(eq_update_filters(eq,layouts[preset],counts[preset],-8,false));
        double inputPower=0,outputPower=0;
        for(int block=0;block<400;block++) {
            for(int i=0;i<128;i++) {
                liveIn[2*i]=.05*sin(2*M_PI*1000*(block*128+i)/48000);
                liveIn[2*i+1]=0;
            }
            eq_process(eq,&liveInput,&liveOutput);
            for(int i=0;i<128;i++) {
                assert(isfinite(liveOut[2*i])&&fabs(liveOut[2*i])<=.981);
                assert(liveOut[2*i+1]==0);
                if(block>300) {inputPower+=liveIn[2*i]*liveIn[2*i];outputPower+=liveOut[2*i]*liveOut[2*i];}
            }
        }
        double expected=eq_response_filters(1000,48000,layouts[preset],counts[preset],-8);
        assert(fabs(10*log10(outputPower/inputPower)-expected)<.03);
        assert(eq_faults(eq)==0);
    }
    eq_destroy(eq);
    puts("PASS live preset layout changes on one engine with realistic audio buffers");
    puts("All 9 DSP test groups passed.");
}
