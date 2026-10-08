#include "DSP.h"
#include <assert.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

// Healthy audio raises neither route nor signal faults.
static bool no_faults(EQ *eq) { return eq_faults(eq)==0 && eq_signal_faults(eq)==0; }
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
    assert(no_faults(eq));
    if (correlation) *correlation=cross/sqrt(powerIn*powerOut);
    // Fit both quadratures: a finite, non-integral cycle window biases RMS ratios
    // when the filter shifts phase, especially at low frequency/high sample rate.
    double determinant=ss*cc-sc*sc;
    double sineGain=(ys*cc-yc*sc)/determinant, cosineGain=(yc*ss-ys*sc)/determinant;
    return 10*log10(fmax(1e-30,sineGain*sineGain+cosineGain*cosineGain));
}
static void frame(EQ *eq, float left, float right, float result[2]) {
    float inputSamples[2]={left,right};
    AudioBufferList input={1,{{2,sizeof(inputSamples),inputSamples}}}, output={1,{{2,2*sizeof(float),result}}};
    eq_process(eq,&input,&output);
}
static void settle(EQ *eq, float left, float right, float result[2]) {
    for (unsigned i=0;i<16000;i++) frame(eq,left,right,result);
    assert(no_faults(eq));
}
static double crossfeed_ratio(EQ *eq, double frequency) {
    double leftPower=0,rightPower=0;
    float out[2];
    for (unsigned i=0;i<48000;i++) {
        frame(eq,.05*sin(2*M_PI*frequency*i/48000),0,out);
        if (i>=24000) { leftPower+=out[0]*out[0]; rightPower+=out[1]*out[1]; }
    }
    return sqrt(rightPower/leftPower);
}
static void stereo_tests(void) {
    EQFilter flat={1000,0,1,EQFilterPeak,false,EQChannelStereo};
    EQStereo neutral=eq_stereo_default(),s=neutral;
    float out[2];
    EQ *eq=eq_create(48000,0); assert(eq);
    assert(eq_update_filters_stereo(eq,&flat,1,0,false,&s));
    settle(eq,.125,-.25,out);
    assert(out[0]==.125f && out[1]==-.25f);
    s.leftTrimDB=-6; s.rightTrimDB=6; s.balance=.5; s.invertRight=true;
    assert(eq_update_filters_stereo(eq,&flat,1,0,false,&s)); settle(eq,.1,.1,out);
    assert(fabs(out[0]-.1*pow(10,-6.0/20)*.5)<1e-7);
    assert(fabs(out[1]+.1*pow(10,6.0/20))<1e-7);
    s=neutral; s.balance=-1;
    assert(eq_update_filters_stereo(eq,&flat,1,0,false,&s)); settle(eq,.1,.2,out);
    assert(out[0]==.1f && out[1]==0);
    s=neutral; s.width=0;
    assert(eq_update_filters_stereo(eq,&flat,1,0,false,&s)); settle(eq,.1,.3,out);
    assert(fabs(out[0]-.2)<1e-7 && out[0]==out[1]);
    s.width=2;
    assert(eq_update_filters_stereo(eq,&flat,1,0,false,&s)); settle(eq,.1,-.1,out);
    assert(out[0]==.2f && out[1]==-.2f);
    s.mono=true;
    assert(eq_update_filters_stereo(eq,&flat,1,0,false,&s)); settle(eq,.1,-.1,out);
    assert(out[0]==0 && out[1]==0);
    s=neutral; s.crossfeed=1;
    assert(eq_update_filters_stereo(eq,&flat,1,0,false,&s)); settle(eq,.2,.2,out);
    assert(fabs(out[0]-.2)<1e-7 && out[0]==out[1]); // Normalized mono remains unity at DC.
    assert(crossfeed_ratio(eq,100)>.98 && crossfeed_ratio(eq,10000)<.09);
    s=(EQStereo){12,-24,-.7,2,1,30,17,true,true,true};
    assert(eq_update_filters_stereo(eq,&flat,1,-12,true,&s)); settle(eq,.125,-.25,out);
    assert(out[0]==.125f && out[1]==-.25f); // Full-chain bypass, including channel delay.
    s=neutral; s.leftTrimDB=NAN; assert(!eq_update_filters_stereo(eq,&flat,1,0,false,&s));
    s=neutral; s.rightTrimDB=12.01; assert(!eq_update_filters_stereo(eq,&flat,1,0,false,&s));
    s=neutral; s.balance=-1.01; assert(!eq_update_filters_stereo(eq,&flat,1,0,false,&s));
    s=neutral; s.width=2.01; assert(!eq_update_filters_stereo(eq,&flat,1,0,false,&s));
    s=neutral; s.crossfeed=-.01; assert(!eq_update_filters_stereo(eq,&flat,1,0,false,&s));
    s=neutral; s.leftDelayMS=30.01; assert(!eq_update_filters_stereo(eq,&flat,1,0,false,&s));
    s=neutral; s.rightDelayMS=INFINITY; assert(!eq_update_filters_stereo(eq,&flat,1,0,false,&s));
    eq_destroy(eq);
    puts("PASS stereo defaults, trims, balance, polarity, mid/side width, mono, frequency-shaped crossfeed and full-chain bypass");

    const double rates[]={32000,44100,48000,96000,192000};
    for (unsigned r=0;r<5;r++) {
        eq=eq_create(rates[r],0); assert(eq);
        s=neutral; s.leftDelayMS=1.25; s.rightDelayMS=30;
        assert(eq_update_filters_stereo(eq,&flat,1,0,false,&s)); settle(eq,0,0,out);
        double delay[2]={s.leftDelayMS*rates[r]/1000,s.rightDelayMS*rates[r]/1000};
        for (unsigned i=0;i<6000;i++) {
            frame(eq,i==0 ? .2 : 0,i==0 ? .1 : 0,out);
            for (unsigned c=0;c<2;c++) {
                unsigned whole=(unsigned)delay[c]; double fraction=delay[c]-whole;
                double expected=(c==0 ? .2 : .1)*(i==whole ? 1-fraction : (i==whole+1 ? fraction : 0));
                assert(fabs(out[c]-expected)<1e-7);
            }
        }
        assert(no_faults(eq)); eq_destroy(eq);
    }
    puts("PASS fractional stereo delay impulse timing, maximum delay and ring wrap at five sample rates");

    eq=eq_create(48000,0); s=neutral;
    assert(eq_update_filters_stereo(eq,&flat,1,0,false,&s)); settle(eq,.05,.05,out);
    s.leftDelayMS=30; s.rightDelayMS=25;
    assert(eq_update_filters_stereo(eq,&flat,1,0,false,&s));
    for (unsigned i=0;i<10000;i++) {
        frame(eq,.05,.05,out);
        assert(fabs(out[0]-.05)<1e-7 && fabs(out[1]-.05)<1e-7);
    }
    double previous=.05,largestStep=0;
    for (unsigned i=0;i<20000;i++) {
        if (i<5000 && i%64==0) {
            s.invertLeft=!s.invertLeft; s.width=s.width==2 ? 0 : 2;
            s.leftDelayMS=s.leftDelayMS==30 ? 0 : 30;
            assert(eq_update_filters_stereo(eq,&flat,1,0,false,&s));
        }
        if (i==5000) { s=neutral; assert(eq_update_filters_stereo(eq,&flat,1,0,false,&s)); }
        frame(eq,.05,.05,out);
        largestStep=fmax(largestStep,fabs(out[0]-previous)); previous=out[0];
        assert(isfinite(out[0]) && isfinite(out[1]));
    }
    assert(largestStep<.001 && out[0]==.05f && out[1]==.05f && no_faults(eq));
    eq_destroy(eq);
    puts("PASS delay warmup without signal drop, rapid stereo edits, smooth polarity transitions and latest target");
}
static void channel_tests(void) {
    EQ *eq=eq_create(48000,0); assert(eq);
    EQFilter filters[]={{1000,6,1,EQFilterPeak,false,EQChannelLeft},
                        {1000,-9,1,EQFilterPeak,false,EQChannelRight}};
    for (unsigned routing=0;routing<2;routing++) {
        if (routing==1) filters[0].channel=EQChannelRight;
        assert(eq_update_filters(eq,filters,2,-3,false));
        double powers[2]={0},inputPower=0; float out[2];
        for (unsigned i=0;i<24000;i++) {
            float sample=.02*sin(2*M_PI*1000*i/48000);
            frame(eq,sample,sample,out);
            if (i>12000) {
                inputPower+=sample*sample;
                for (unsigned c=0;c<2;c++) powers[c]+=out[c]*out[c];
            }
        }
        double expected[2]={routing==0 ? 3 : -3, routing==0 ? -12 : -6};
        for (unsigned c=0;c<2;c++) {
            assert(fabs(10*log10(powers[c]/inputPower)-expected[c])<.001);
            assert(fabs(eq_response_filters_channel(1000,48000,filters,2,-3,c+1)-expected[c])<1e-8);
        }
        assert(fabs(eq_response_filters(1000,48000,filters,2,-3)-fmax(expected[0],expected[1]))<1e-8);
        assert(no_faults(eq));
    }
    filters[0].channel=3; assert(!eq_update_filters(eq,filters,2,0,false));
    assert(isnan(eq_response_filters_channel(1000,48000,filters,2,0,3)));
    eq_destroy(eq);
    puts("PASS independent L/R filter magnitude, live channel rerouting, graph response and conservative stereo peak");
}
static void preamp_history_tests(void) {
    const double rates[]={32000,44100,48000,96000,192000};
    const double preamps[]={-6,-18,6,0};
    for (unsigned r=0;r<5;r++) {
        double rate=rates[r];
        EQ *eq=eq_create(rate,0),*reference=eq_create(rate,0);
        assert(eq && reference);
        // Slow bass correction makes discarded IIR history audible well beyond
        // a 20 ms fade. Compare against the same uninterrupted filter history.
        EQFilter filter={20,18,20,EQFilterPeak,false,EQChannelStereo};
        assert(eq_update_filters(eq,&filter,1,0,false));
        assert(eq_update_filters(reference,&filter,1,0,false));
        float out[2],base[2];
        unsigned sample=0;
        for (;sample<(unsigned)rate;sample++) {
            float input=.001*sin(2*M_PI*20*sample/rate);
            frame(eq,input,input,out); frame(reference,input,input,base);
        }
        double oldAmplitude=1;
        unsigned fade=(unsigned)ceil(rate*.02);
        for (unsigned p=0;p<4;p++) {
            assert(eq_update_filters(eq,&filter,1,preamps[p],false));
            double amplitude=pow(10,preamps[p]/20);
            for (unsigned i=0;i<(unsigned)(rate*.1);i++,sample++) {
                float input=.001*sin(2*M_PI*20*sample/rate);
                frame(eq,input,input,out); frame(reference,input,input,base);
                double mix=fmin(1,(double)i/fade);
                double expected=base[0]*(oldAmplitude*(1-mix)+amplitude*mix);
                assert(fabs(out[0]-expected)<2e-8 && out[0]==out[1]);
            }
            oldAmplitude=amplitude;
        }
        assert(no_faults(eq) && no_faults(reference));
        eq_destroy(eq);eq_destroy(reference);
    }
    puts("PASS preamp cuts and boosts preserve slow-filter history and fade magnitude at five sample rates");
}
static void channel_history_tests(void) {
    const double rates[]={32000,44100,48000,96000,192000};
    for (unsigned r=0;r<5;r++) for (unsigned c=0;c<2;c++) {
        double rate=rates[r];
        unsigned channel=c+1,other=2-c;
        EQ *eq=eq_create(rate,0),*reference=eq_create(rate,0);
        assert(eq && reference);
        EQFilter bass={20,18,20,EQFilterPeak,false,channel};
        EQFilter unrelated={1000,-3,1,EQFilterPeak,false,other};
        EQFilter filters[3]={unrelated,bass};
        assert(eq_update_filters(eq,filters,2,0,false));
        assert(eq_update_filters(reference,filters,2,0,false));
        float out[2],base[2]; unsigned sample=0;
        for (;sample<(unsigned)rate;sample++) {
            float input=.001*sin(2*M_PI*20*sample/rate);
            frame(eq,input,input,out); frame(reference,input,input,base);
        }
        double oldAmplitude=1;
        for (unsigned edit=0;edit<5;edit++) {
            unsigned count=2;
            double preamp=0;
            if (edit==0) { filters[0].gain=6; filters[0].q=2; }
            if (edit==1) { filters[0]=bass; count=1; }
            if (edit==2) {
                filters[0]=unrelated;
                filters[1]=(EQFilter){100,12,1,EQFilterPeak,true,channel};
                filters[2]=bass; count=3;
            }
            if (edit==3) { filters[1].disabled=false; filters[1].gain=0; count=3; preamp=-6; }
            if (edit==4) { filters[0]=bass; filters[0].channel=EQChannelStereo; count=1; preamp=-6; }
            assert(eq_update_filters(eq,filters,count,preamp,false));
            double amplitude=pow(10,preamp/20);
            unsigned fade=(unsigned)ceil(rate*.02);
            for (unsigned i=0;i<(unsigned)(rate*.12);i++,sample++) {
                float input=.001*sin(2*M_PI*20*sample/rate);
                frame(eq,input,input,out); frame(reference,input,input,base);
                double mix=fmin(1,(double)i/fade);
                double expected=base[c]*(oldAmplitude*(1-mix)+amplitude*mix);
                assert(fabs(out[c]-expected)<2e-8);
            }
            oldAmplitude=amplitude;
        }
        // Changing a contributing upstream filter invalidates the bass state.
        // After the fade it must match a fresh target chain, not copied history.
        eq_destroy(reference); reference=eq_create(rate,0); assert(reference);
        filters[0]=(EQFilter){200,0,.707,EQFilterHighPass,false,channel};
        filters[1]=bass;
        assert(eq_update_filters(eq,filters,2,-6,false));
        assert(eq_update_filters(reference,filters,2,-6,false));
        for (unsigned i=0;i<(unsigned)(rate*.12);i++,sample++) {
            float input=.001*sin(2*M_PI*20*sample/rate);
            frame(eq,input,input,out); frame(reference,input,input,base);
            if (i>=(unsigned)ceil(rate*.02)) assert(out[c]==base[c]);
        }
        assert(no_faults(eq) && no_faults(reference));
        eq_destroy(eq); eq_destroy(reference);
    }
    puts("PASS independent channel history across other-channel edits, removal, insertion, identity filters, preamp and routing at five rates");
}
static const double bassTone=.01;
static float bass_input(unsigned sample, double rate) { return bassTone*sin(2*M_PI*30*sample/rate); }
// Largest deviation (dB) of a 30 Hz tone from the settled response of the
// current filters, after skipping some frames. |sin| peaks once per 1/60 s.
static double bass_error(EQ *eq, double rate, unsigned *sample, unsigned skip, unsigned windows, const EQFilter *filters, unsigned count, double preamp) {
    double expected=eq_response_filters(30,rate,filters,count,preamp), worst=0;
    unsigned window=(unsigned)ceil(rate/60);
    float out[2];
    for (unsigned i=0;i<skip;i++,(*sample)++) frame(eq,bass_input(*sample,rate),bass_input(*sample,rate),out);
    for (unsigned w=0;w<windows;w++) {
        double peak=0;
        for (unsigned i=0;i<window;i++,(*sample)++) {
            frame(eq,bass_input(*sample,rate),bass_input(*sample,rate),out);
            assert(out[0]==out[1]); peak=fmax(peak,fabs(out[0]));
        }
        worst=fmax(worst,fabs(20*log10(peak/bassTone)-expected));
    }
    assert(no_faults(eq));
    return worst;
}
static void edit_history_tests(void) {
    const double rates[]={32000,44100,48000,96000,192000};
    for (unsigned r=0;r<5;r++) {
        double rate=rates[r];
        EQ *eq=eq_create(rate,0); assert(eq);
        unsigned fade=(unsigned)ceil(rate*.02);
        // An AutoEQ-like order: slow bass correction after a treble filter.
        EQFilter filters[2]={{3000,-3,2,EQFilterPeak,false,EQChannelStereo},{30,8,6,EQFilterPeak,false,EQChannelStereo}};
        assert(eq_update_filters(eq,filters,2,-8,false));
        unsigned sample=0;
        bass_error(eq,rate,&sample,0,180,filters,2,-8);
        assert(bass_error(eq,rate,&sample,0,6,filters,2,-8)<.01);
        // Restarting the edited bass filter would drop its 30 Hz level by ~5 dB.
        filters[1].gain=7.9; assert(eq_update_filters(eq,filters,2,-8,false));
        assert(bass_error(eq,rate,&sample,fade,60,filters,2,-8)<.12);
        // Drag its gain 4 dB at 60 updates per second; the level follows closely.
        double drag=0;
        for (unsigned step=1;step<=60;step++) {
            filters[1].gain=7.9-4.0*step/60; assert(eq_update_filters(eq,filters,2,-8,false));
            drag=fmax(drag,bass_error(eq,rate,&sample,0,1,filters,2,-8));
        }
        assert(drag<.6 && bass_error(eq,rate,&sample,fade,30,filters,2,-8)<.4);
        // Small upstream edits, including through 0 dB identity, keep bass history.
        const double treble[]={-2.5,0,.5};
        for (unsigned e=0;e<3;e++) {
            filters[0].gain=treble[e]; assert(eq_update_filters(eq,filters,2,-8,false));
            assert(bass_error(eq,rate,&sample,fade,30,filters,2,-8)<.01);
        }
        // Type changes and larger jumps restart the edited filter and those after
        // it: with nothing before it, the chain matches a fresh one exactly.
        EQFilter first=filters[0]; filters[0]=filters[1]; filters[1]=first;
        assert(eq_update_filters(eq,filters,2,-8,false));
        bass_error(eq,rate,&sample,0,30,filters,2,-8);
        for (unsigned jump=0;jump<2;jump++) {
            if (jump==0) filters[0].type=EQFilterLowShelf; else filters[0].frequency=60;
            EQ *reference=eq_create(rate,0); assert(reference);
            assert(eq_update_filters(eq,filters,2,-8,false) && eq_update_filters(reference,filters,2,-8,false));
            float out[2],base[2];
            for (unsigned i=0;i<(unsigned)(rate*.1);i++,sample++) {
                frame(eq,bass_input(sample,rate),bass_input(sample,rate),out);
                frame(reference,bass_input(sample,rate),bass_input(sample,rate),base);
                if (i>=fade) assert(out[0]==base[0] && out[1]==base[1]);
            }
            assert(no_faults(eq) && no_faults(reference)); eq_destroy(reference);
        }
        eq_destroy(eq);
    }
    puts("PASS small edits and drags keep slow bass history; type changes and large jumps restart at five rates");
}
// |c2 s² + c1 s + c0|² at s = jx.
static double analog_part(double c2, double c1, double c0, double x) { return (c0-c2*x*x)*(c0-c2*x*x)+c1*c1*x*x; }
// The cookbook's analog prototypes in dB, at x = frequency / filter frequency.
static double analog_db(EQFilter f, double x) {
    double a=pow(10,f.gain/40), s=sqrt(a), q=f.q, d=analog_part(1,1/q,1,x), m=1;
    switch (f.type) {
    case EQFilterPeak: m=analog_part(1,a/q,1,x)/analog_part(1,1/(a*q),1,x); break;
    case EQFilterLowShelf: m=a*a*analog_part(1,s/q,a,x)/analog_part(a,s/q,1,x); break;
    case EQFilterHighShelf: m=a*a*analog_part(a,s/q,1,x)/analog_part(1,s/q,a,x); break;
    case EQFilterLowPass: m=1/d; break;
    case EQFilterHighPass: m=x*x*x*x/d; break;
    case EQFilterBandPass: m=x*x/(q*q*d); break;
    case EQFilterNotch: m=(1-x*x)*(1-x*x)/d; break;
    }
    return 10*log10(m);
}
static void analog_shape_tests(void) {
    // Treble filters keep their analog shape instead of bunching up toward Nyquist,
    // so a profile sounds the same at every sample rate. The bilinear designs missed
    // all but the low shelf, high-pass and narrow peak here by 1-20 dB.
    const struct { EQFilter filter; double tolerance; } cases[]={
        {{10000,6,1,EQFilterPeak,false,EQChannelStereo},.5}, {{3000,-9,4,EQFilterPeak,false,EQChannelStereo},.05},
        {{16000,4,2,EQFilterPeak,false,EQChannelStereo},.5}, {{200,6,M_SQRT1_2,EQFilterLowShelf,false,EQChannelStereo},.01},
        {{8000,5,M_SQRT1_2,EQFilterHighShelf,false,EQChannelStereo},.1}, {{12000,-8,M_SQRT1_2,EQFilterHighShelf,false,EQChannelStereo},.3},
        {{12000,0,M_SQRT1_2,EQFilterLowPass,false,EQChannelStereo},1}, {{60,0,M_SQRT1_2,EQFilterHighPass,false,EQChannelStereo},.01},
        {{5000,0,2,EQFilterBandPass,false,EQChannelStereo},1}, {{6000,0,4,EQFilterNotch,false,EQChannelStereo},.05},
    };
    const double rates[]={44100,48000,96000,192000};
    for (unsigned i=0;i<sizeof cases/sizeof *cases;i++) for (unsigned r=0;r<4;r++) {
        EQFilter f=cases[i].filter; double rate=rates[r];
        // The match points are exact: the filter frequency, and DC (or the cut-off slope).
        double center=eq_response_filters(f.frequency,rate,&f,1,0), dc=eq_response_filters(1e-3,rate,&f,1,0);
        assert(fabs(fmax(-100,center)-fmax(-100,analog_db(f,1)))<1e-6);
        assert(fabs(fmax(-100,dc)-fmax(-100,analog_db(f,1e-3/f.frequency)))<1e-4);
        for (double hz=20;hz<=fmin(20000,rate*.45);hz*=1.01) {
            double want=analog_db(f,hz/f.frequency), got=eq_response_filters(hz,rate,&f,1,0);
            if (f.type==EQFilterNotch && want < -30) continue; // the null itself
            double error=fabs(fmax(-40,got)-fmax(-40,want));
            if (error>=cases[i].tolerance) fprintf(stderr,"type %u %.0f Hz at %.0f: %.3f dB vs analog %.3f dB at %.0f Hz\n",f.type,f.frequency,rate,got,want,hz);
            assert(error<cases[i].tolerance);
        }
    }
    puts("PASS peak, shelf, pass and notch filters keep their analog shape and exact centers at four sample rates");
}
int main(void) {
    analog_shape_tests();
    stereo_tests();
    channel_tests();
    preamp_history_tests();
    channel_history_tests();
    edit_history_tests();
    const double rates[]={32000,44100,48000,96000,192000};
    for (unsigned r=0;r<5;r++) {
        double rate=rates[r];
        for (unsigned type=EQFilterLowPass;type<=EQFilterAllPass;type++) {
            EQ *eq=eq_create(rate,0); assert(eq);
            EQFilter filter={1000,0,M_SQRT1_2,type,false,EQChannelStereo};
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
        EQ *eq=eq_create(48000,0); EQFilter filter={1000,12,.7,type,true,EQChannelStereo};
        assert(eq_update_filters(eq,&filter,1,0,false));
        assert(fabs(measure(eq,48000,1000,NULL))<.001);
        assert(eq_response_filters(1000,48000,&filter,1,0)==0);
        eq_destroy(eq);
    }
    EQ *eq=eq_create(48000,0); assert(eq);
    EQFilter invalid={1000,1,.7,EQFilterLowPass,false,EQChannelStereo};
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
    EQFilter filter={1000,0,.707,EQFilterHighPass,false,EQChannelStereo};
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
    assert(largestStep<.001 && fabs(previous-.05)<1e-6 && no_faults(eq));
    // Nonfinite input is contained as a signal fault; malformed buffers are route faults.
    in[0]=NAN; eq_process(eq,&input,&output); assert(eq_signal_faults(eq)==1 && eq_faults(eq)==0);
    for(unsigned i=0;i<128;i++) assert(isfinite(out[i]));
    unsigned faults=eq_faults(eq); input.mBuffers[0].mDataByteSize-=1;
    eq_process(eq,&input,&output); assert(eq_faults(eq)==faults+1);
    for(unsigned i=0;i<128;i++) assert(out[i]==0);
    assert(eq_peak(eq)==0);
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
                        b%2 ? .05 : 50,type,block%160==0,EQChannelStereo};
                }
                assert(eq_update_filters(eq,filters,EQMaxFilters,-12,false));
            }
            for(unsigned i=0;i<128;i++) in[i]=.1*sin((block*128+i)*.17);
            eq_process(eq,&input,&output);
            for(unsigned i=0;i<128;i++) assert(isfinite(out[i]) && fabs(out[i])<=.981);
        }
        assert(no_faults(eq));eq_destroy(eq);
    }
    printf("PASS %u-filter extreme-value stress at five rates (CPU %.3fs, sanitizer build)\n",(unsigned)EQMaxFilters,(double)(clock()-begin)/CLOCKS_PER_SEC);
}
