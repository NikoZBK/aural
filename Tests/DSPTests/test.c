#include "DSP.h"
#include <assert.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <float.h>

#define N 48000
static float source[N*4], dest[N*2];
// Healthy audio raises neither route nor signal faults.
static bool no_faults(EQ *eq) { return eq_faults(eq)==0 && eq_signal_faults(eq)==0; }
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
static void check_peak_protection(void) {
    double rates[]={32000,44100,48000,96000,192000};
    for(unsigned r=0;r<5;r++) {
        EQ *eq=eq_create(rates[r],0); assert(eq);
        float input[256]={.5f,-.25f}, output[256];
        AudioBufferList in={1,{{2,sizeof(input),input}}}, out={1,{{2,sizeof(output),output}}};
        eq_process(eq,&in,&out);
        assert(memcmp(input,output,sizeof(input))==0);
        EQMeter meter=eq_read_meter(eq);
        assert(meter.peak==.5f && meter.reductionDB==0);
        meter=eq_read_meter(eq); assert(meter.peak==0 && meter.reductionDB==0);

        // An isolated transient must survive many silent callbacks before UI polling.
        input[0]=4; input[1]=-1;
        eq_process(eq,&in,&out);
        assert(fabs(output[0]-.98)<1e-7 && fabs(output[1]+.245)<1e-7);
        memset(input,0,sizeof(input));
        for(unsigned b=0;b<(unsigned)ceil(rates[r]*1.5/128);b++) eq_process(eq,&in,&out);
        assert(eq_peak(eq)==0);
        meter=eq_read_meter(eq);
        assert(fabs(meter.peak-.98)<1e-7 && fabs(meter.reductionDB-20*log10(4/.98))<1e-4);
        meter=eq_read_meter(eq); assert(meter.peak==0 && meter.reductionDB==0);
        input[0]=.5f; input[1]=-.25f;
        eq_process(eq,&in,&out);
        assert(memcmp(input,output,sizeof(input))==0); // Release restores neutral audio.
        input[0]=.2f; input[1]=-8;
        eq_process(eq,&in,&out);
        assert(fabs(output[1]+.98)<1e-7 && fabs(output[0]/output[1]+.025)<1e-7);
        meter=eq_read_meter(eq);
        assert(fabs(meter.reductionDB-20*log10(8/.98))<1e-4 && no_faults(eq));
        eq_destroy(eq);

        for(unsigned mode=0;mode<3;mode++) {
            eq=eq_create(rates[r],0); assert(eq);
            EQFilter filter={1000,30,1.4,EQFilterPeak,mode!=1,EQChannelStereo};
            EQStereo stereo=eq_stereo_default();
            if(mode==1) { stereo.leftTrimDB=12; stereo.rightTrimDB=-12; stereo.width=2; stereo.leftDelayMS=30; }
            if(mode==2) { stereo.leftTrimDB=stereo.rightTrimDB=12; stereo.width=2; }
            assert(eq_update_filters_stereo(eq,&filter,1,mode==2 ? 0 : 24,mode==1,&stereo));
            for(unsigned i=0;i<N;i++) { source[2*i]=4; source[2*i+1]=-1; }
            for(unsigned b=0;b<2;b++) {
                process(eq,2);
                for(unsigned i=0;i<N*2;i++) assert(isfinite(dest[i]) && fabs(dest[i])<=.980001);
            }
            double ratio=mode==2 ? -7.0/13 : -.25;
            assert(fabs(dest[N*2-1]/dest[N*2-2]-ratio)<1e-6);
            meter=eq_read_meter(eq);
            assert(fabs(meter.peak-.98)<1e-7 && meter.reductionDB>12 && no_faults(eq));
            AudioBufferList bad={1,{{2,sizeof(dest),NULL}}};
            AudioBufferList good={1,{{2,sizeof(source)/2,source}}};
            eq_process(eq,&good,&bad);
            meter=eq_read_meter(eq);
            assert(meter.peak==0 && meter.reductionDB==0 && eq_faults(eq)==1);
            eq_destroy(eq);
        }
    }
    puts("PASS peak protection, linked stereo, bypass, disabled filters, stereo gain, release, and interval metering at five rates");
}
static void check_peak_protection_switch(void) {
    double rates[]={32000,44100,48000,96000,192000};
    for(unsigned r=0;r<5;r++) {
        EQ *eq=eq_create(rates[r],0); assert(eq);
        float input[256]={4,-1}, output[256];
        AudioBufferList in={1,{{2,sizeof(input),input}}}, out={1,{{2,sizeof(output),output}}};
        eq_process(eq,&in,&out); // Do not read the previous reduction before switching.
        double held=output[0]/4.0; // 0.245; the silent rest of the buffer releases toward 0.28.
        eq_set_peak_protection(eq,false);
        assert(eq_read_meter(eq).reductionDB==0);
        // Off stops limiting the new peak; the reduction already applied releases
        // instead of jumping up by more than 10 dB within one sample.
        eq_process(eq,&in,&out);
        double gain=output[0]/4.0;
        assert(gain>held && gain<.3 && fabs(output[1]/output[0]+.25)<1e-6 && eq_peak(eq)==output[0]);
        EQMeter meter=eq_read_meter(eq);
        assert(meter.peak==output[0] && meter.reductionDB==0);
        // A steady signal rises smoothly and monotonically to unity.
        for(unsigned i=0;i<256;i+=2) { input[i]=.5f; input[i+1]=-.25f; }
        double largestStep=0, previous=gain;
        for(unsigned b=0;b<(unsigned)ceil(rates[r]*1.5/128);b++) {
            eq_process(eq,&in,&out);
            for(unsigned i=0;i<256;i+=2) {
                double g=output[i]/.5;
                assert(g>=previous && g<=1 && output[i+1]==-output[i]/2);
                if(b || i) largestStep=fmax(largestStep,g-previous);
                previous=g;
            }
        }
        assert(largestStep<.001);
        assert(memcmp(input,output,sizeof(input))==0); // Off removes all attenuation once released.
        eq_set_peak_protection(eq,true);
        eq_process(eq,&in,&out);
        assert(memcmp(input,output,sizeof(input))==0); // Re-enable without stale gain.
        memset(input,0,sizeof(input));
        previous=1;
        for(unsigned toggle=0;toggle<200;toggle++) {
            bool enabled=toggle%2!=0;
            eq_set_peak_protection(eq,enabled);
            input[0]=.2f; input[1]=-8;
            eq_process(eq,&in,&out);
            meter=eq_read_meter(eq);
            double g=output[1]/-8.0;
            if(enabled) {
                assert(fabs(output[1]+.98)<1e-7 && fabs(output[0]/output[1]+.025)<1e-7);
                assert(meter.reductionDB>18);
            } else {
                // Unlimited, still releasing from the previous buffer's 18 dB reduction.
                assert(g>=previous && g<=1 && (toggle==0 || g<.2) && fabs(output[0]/output[1]+.025)<1e-7);
                assert(meter.peak==-output[1] && meter.reductionDB==0);
            }
            previous=g;
        }
        assert(no_faults(eq));
        eq_destroy(eq);

        for(unsigned mode=0;mode<3;mode++) {
            eq=eq_create(rates[r],0); assert(eq);
            eq_set_peak_protection(eq,false); // Saved Off must apply before the first callback.
            EQFilter filter={1000,30,1.4,EQFilterPeak,mode!=1,EQChannelStereo};
            EQStereo stereo=eq_stereo_default();
            if(mode==1) { stereo.leftTrimDB=12; stereo.width=2; stereo.leftDelayMS=30; }
            if(mode==2) { stereo.leftTrimDB=stereo.rightTrimDB=12; stereo.width=2; }
            assert(eq_update_filters_stereo(eq,&filter,1,mode==2 ? 0 : 24,mode==1,&stereo));
            for(unsigned i=0;i<N;i++) { source[2*i]=4; source[2*i+1]=-1; }
            process(eq,2); process(eq,2);
            double left=mode==0 ? 4*pow(10,24.0/20) : mode==1 ? 4 : 6.5*pow(10,12.0/20);
            double ratio=mode==2 ? -7.0/13 : -.25;
            assert(fabs(dest[N*2-2]-left)<1e-5 && fabs(dest[N*2-1]/dest[N*2-2]-ratio)<1e-6);
            meter=eq_read_meter(eq); assert(meter.peak>1 && meter.reductionDB==0);
            eq_set_peak_protection(eq,true);
            process(eq,2);
            for(unsigned i=0;i<N*2;i++) assert(isfinite(dest[i]) && fabs(dest[i])<=.980001);
            assert(eq_read_meter(eq).reductionDB>12 && no_faults(eq));
            eq_destroy(eq);
        }
        eq=eq_create(rates[r],0); assert(eq);
        eq_set_peak_protection(eq,false);
        input[0]=NAN; input[1]=.5f;
        eq_process(eq,&in,&out);
        assert(output[0]==0 && output[1]==.5f && eq_signal_faults(eq)==1 && eq_faults(eq)==0);
        EQFilter disabled={1000,0,1,EQFilterPeak,true,EQChannelStereo};
        assert(eq_update_filters(eq,&disabled,1,24,false));
        memset(source,0,sizeof(source)); process(eq,2); // Complete the settings crossfade.
        source[0]=FLT_MAX; source[1]=.5f;
        process(eq,2);
        assert(dest[0]==0 && dest[1]==0 && eq_signal_faults(eq)==2 && eq_faults(eq)==0);
        for(unsigned i=0;i<N*2;i++) assert(isfinite(dest[i]));
        eq_destroy(eq);
    }
    puts("PASS protection On/Off, unattenuated output, rapid switching, startup, bypass and stereo independence, and fault containment at five rates");
}
static void check_matched_bypass(void) {
    EQ *eq=eq_create(48000,0); assert(eq);
    EQFilter peak={1000,6,.707,EQFilterPeak,false,EQChannelStereo};
    EQStereo stereo=eq_stereo_default();
    tone(.1,1);
    // 0 dB keeps the original Bypass; a gain-only change must still take effect.
    assert(eq_update_filters_matched(eq,&peak,1,-6,true,&stereo,0)); process(eq,2); process(eq,2);
    assert(fabs(rms(dest,N,N*2)-rms(source,N,N*2))<.0001);
    assert(eq_update_filters_matched(eq,&peak,1,-6,true,&stereo,-4.5)); process(eq,2);
    assert(fabs(20*log10(rms(dest,N,N*2)/rms(source,N,N*2))+4.5)<.001);
    // The stereo-effects path bypasses trim and width but applies the same gain.
    stereo.width=.5; stereo.leftTrimDB=-3;
    assert(eq_update_filters_matched(eq,&peak,1,-6,true,&stereo,2)); process(eq,2);
    for(int i=N/2;i<N;i++) for(int c=0;c<2;c++) assert(fabs(dest[2*i+c]-source[2*i+c]*pow(10,.1))<1e-6);
    // The gain belongs to Bypass only; the EQ path is unchanged.
    stereo=eq_stereo_default();
    assert(eq_update_filters_matched(eq,&peak,1,-6,false,&stereo,-20)); process(eq,2); process(eq,2);
    assert(fabs(20*log10(rms(dest,N,N*2)/rms(source,N,N*2)))<.02);
    assert(eq_update_filters_matched(eq,&peak,1,0,true,&stereo,-24));
    assert(eq_update_filters_matched(eq,&peak,1,0,true,&stereo,12));
    assert(!eq_update_filters_matched(eq,&peak,1,0,true,&stereo,NAN));
    assert(!eq_update_filters_matched(eq,&peak,1,0,true,&stereo,-24.01));
    assert(!eq_update_filters_matched(eq,&peak,1,0,true,&stereo,12.01));
    assert(no_faults(eq)); eq_destroy(eq);
    puts("PASS level-matched bypass gain, stereo path, EQ path independence, and validation");
}
int main(void) {
    check_peak_protection();
    check_peak_protection_switch();
    check_matched_bypass();
    double gains[10]={0};
    EQ *eq=eq_create(48000,0); assert(eq);
    tone(.1,0); process(eq,2);
    for(int i=0;i<N*2;i++) assert(source[i]==dest[i]); assert(no_faults(eq));
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
    // A stalled callback must not make edits fail. It applies only the latest.
    for(int i=0;i<1000;i++) assert(eq_update(eq,gains,-(i%24),false));
    tone(.1,1);process(eq,2);
    assert(fabs(dest[N*2-2]/source[N*2-2]-pow(10,-15/20.))<1e-6 && fabs(dest[N*2-1]/source[N*2-1]-pow(10,-15/20.))<1e-6);
    assert(eq_update(eq,gains,0,false));process(eq,2);
    assert(dest[N*2-2]==source[N*2-2] && dest[N*2-1]==source[N*2-1]);
    puts("PASS invalid parameters and stalled-callback updates");eq_destroy(eq);
    eq=eq_create(48000,0);assert(eq);
    size_t bytes=offsetof(AudioBufferList,mBuffers)+2*sizeof(AudioBuffer);
    AudioBufferList *planar=calloc(1,bytes);assert(planar);planar->mNumberBuffers=2;
    float left[128],right[128],outL[128],outR[128];
    for(int i=0;i<128;i++){left[i]=.1;right[i]=-.1;}
    planar->mBuffers[0]=(AudioBuffer){1,sizeof(left),left};planar->mBuffers[1]=(AudioBuffer){1,sizeof(right),right};
    AudioBufferList *out=calloc(1,bytes);assert(out);out->mNumberBuffers=2;
    out->mBuffers[0]=(AudioBuffer){1,sizeof(outL),outL};out->mBuffers[1]=(AudioBuffer){1,sizeof(outR),outR};
    eq_process(eq,planar,out);assert(memcmp(left,outL,sizeof(left))==0);assert(memcmp(right,outR,sizeof(right))==0);
    assert(eq_peak(eq)==.1f);
    planar->mBuffers[1].mData=NULL;eq_process(eq,planar,out);assert(eq_faults(eq)==1);
    for(int i=0;i<128;i++)assert(outL[i]==0&&outR[i]==0);
    assert(eq_peak(eq)==0);
    puts("PASS planar buffers and invalid-buffer fault reporting");free(planar);free(out);eq_destroy(eq);
    EQFilter custom={1000,6,.707,0,false,EQChannelStereo};
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
    custom=(EQFilter){1234,-7.3,3.21,0,false,EQChannelStereo};
    assert(fabs(eq_response_filters(1234,48000,&custom,1,-6.7)+14)<.001);
    custom.q=.7;double wide=eq_response_filters(2000,48000,&custom,1,0);
    custom.q=5;double narrow=eq_response_filters(2000,48000,&custom,1,0);assert(wide<narrow-1);
    eq=eq_create(48000,0);assert(eq);custom.type=EQFilterAllPass+1;assert(!eq_update_filters(eq,&custom,1,0,false));
    custom.type=0;custom.q=0;assert(!eq_update_filters(eq,&custom,1,0,false));
    assert(!eq_update_filters(eq,&custom,33,0,false));eq_destroy(eq);
    puts("PASS imported peaking, low/high shelves, custom frequency/Q, response consistency, and validation");
    // Keep one engine alive while switching filter count, frequency, Q and kind.
    eq=eq_create(48000,0);assert(eq);
    EQFilter layouts[4][10]={
        {{1000,4,1.4,0,false,EQChannelStereo},{3000,-2,1.4,0,false,EQChannelStereo},{8000,3,1.4,0,false,EQChannelStereo}},
        {{120,3,.7,1,false,EQChannelStereo},{1000,-5,2,0,false,EQChannelStereo},{6000,2,.8,2,false,EQChannelStereo}},
        {{1000,6,.707,0,false,EQChannelStereo}},
        {{31.5,2,1.4,0,false,EQChannelStereo},{63,3,1.4,0,false,EQChannelStereo},{125,2,1.4,0,false,EQChannelStereo},{250,1,1.4,0,false,EQChannelStereo},
         {500,0,1.4,0,false,EQChannelStereo},{1000,0,1.4,0,false,EQChannelStereo},{2000,-1,1.4,0,false,EQChannelStereo},{4000,-1,1.4,0,false,EQChannelStereo},
         {8000,0,1.4,0,false,EQChannelStereo},{16000,0,1.4,0,false,EQChannelStereo}}
    };
    unsigned counts[]={3,3,1,10,false};
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
        assert(no_faults(eq));
    }
    eq_destroy(eq);
    puts("PASS live preset layout changes on one engine with realistic audio buffers");
    puts("All 11 DSP test groups passed.");
}
