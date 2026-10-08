#include "DSP.h"
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <float.h>

const double EQFrequencies[EQBands] = {31.5,63,125,250,500,1000,2000,4000,8000,16000};
typedef struct { double b0,b1,b2,a1,a2; } Coeff;
enum { EQDelayCapacity = 5762 }; // 30 ms at 192 kHz, plus interpolation guard.
typedef struct {
    EQFilter filters[EQMaxFilters];
    Coeff coefficients[EQMaxFilters];
    unsigned count;
    double preamp, amplitude, bypassGainDB, bypassAmplitude;
    bool bypass;
    EQStereo stereo;
    double channelGain[2], delayFraction[2], crossfeedCoefficient, crossfeedDirect, crossfeedOpposite;
    unsigned delayFrames[2];
    unsigned warmupFrames;
    bool hasStereoEffects;
} Settings;
typedef struct {
    Settings settings;
    double z1[2][EQMaxFilters], z2[2][EQMaxFilters];
    double crossfeedLow[2], delay[2][EQDelayCapacity];
    unsigned delayIndex, delayValid;
} Chain;
struct EQ {
    double rate;
    unsigned offset;
    Settings queue[64], target;
    _Atomic unsigned read, write, faults;
    _Atomic unsigned protectionEnabled;
    _Atomic float peak, meterPeak, meterReduction;
    Chain chains[2];
    unsigned active, transitionFrame, transitionLength, warmupRemaining;
    bool transitioning, pending;
    double limiter, release;
};
_Static_assert(ATOMIC_INT_LOCK_FREE == 2, "Audio control requires lock-free atomics");
static Coeff coeff(EQFilter filter, double db, double rate) {
    double hz=filter.frequency;
    if (filter.disabled || hz >= rate * .49 || (filter.type <= EQFilterHighShelf && fabs(db) < 1e-10)) return (Coeff){1,0,0,0,0};
    double a=pow(10,db/40), w=2*M_PI*hz/rate, alpha=sin(w)/(2*filter.q), c=cos(w);
    double b0,b1,b2,a0,a1,a2;
    if (filter.type==1) {
        double t=2*sqrt(a)*alpha;
        b0=a*((a+1)-(a-1)*c+t); b1=2*a*((a-1)-(a+1)*c); b2=a*((a+1)-(a-1)*c-t);
        a0=(a+1)+(a-1)*c+t; a1=-2*((a-1)+(a+1)*c); a2=(a+1)+(a-1)*c-t;
    } else if (filter.type==2) {
        double t=2*sqrt(a)*alpha;
        b0=a*((a+1)+(a-1)*c+t); b1=-2*a*((a-1)+(a+1)*c); b2=a*((a+1)+(a-1)*c-t);
        a0=(a+1)-(a-1)*c+t; a1=2*((a-1)-(a+1)*c); a2=(a+1)-(a-1)*c-t;
    } else if (filter.type==EQFilterPeak) {
        a0=1+alpha/a; b0=1+alpha*a; b1=-2*c; b2=1-alpha*a; a1=-2*c; a2=1-alpha/a;
    } else {
        // RBJ biquads: https://www.w3.org/TR/audio-eq-cookbook/
        a0=1+alpha; a1=-2*c; a2=1-alpha;
        switch (filter.type) {
        case EQFilterLowPass: b0=(1-c)/2; b1=1-c; b2=b0; break;
        case EQFilterHighPass: b0=(1+c)/2; b1=-(1+c); b2=b0; break;
        case EQFilterBandPass: b0=alpha; b1=0; b2=-alpha; break; // 0 dB peak
        case EQFilterNotch: b0=1; b1=-2*c; b2=1; break;
        case EQFilterAllPass: b0=1-alpha; b1=-2*c; b2=1+alpha; break;
        default: return (Coeff){NAN,NAN,NAN,NAN,NAN}; // invalid callers must not look like unity
        }
    }
    return (Coeff){b0/a0,b1/a0,b2/a0,a1/a0,a2/a0};
}
EQ *eq_create(double rate, unsigned offset) {
    if (!isfinite(rate) || rate < 32000 || rate > 192000) return NULL;
    EQ *eq=calloc(1,sizeof(EQ));
    if (!eq) return NULL;
    eq->rate=rate; eq->offset=offset; eq->limiter=1;
    atomic_init(&eq->protectionEnabled,1);
    eq->release=1-exp(-1/(rate*.08));
    eq->transitionLength=(unsigned)ceil(rate*.02);
    eq->chains[0].settings.amplitude=eq->chains[1].settings.amplitude=1;
    eq->chains[0].settings.bypassAmplitude=eq->chains[1].settings.bypassAmplitude=1;
    for (unsigned bank=0;bank<2;bank++) {
        eq->chains[bank].settings.stereo=eq_stereo_default();
        eq->chains[bank].settings.channelGain[0]=eq->chains[bank].settings.channelGain[1]=1;
        eq->chains[bank].settings.crossfeedCoefficient=1-exp(-2*M_PI*700/rate);
    }
    if (!atomic_is_lock_free(&eq->peak) || !atomic_is_lock_free(&eq->meterPeak) ||
        !atomic_is_lock_free(&eq->meterReduction)) { free(eq); return NULL; }
    return eq;
}
void eq_destroy(EQ *eq) { free(eq); }
void eq_set_peak_protection(EQ *eq, bool enabled) {
    atomic_store_explicit(&eq->protectionEnabled,enabled,memory_order_relaxed);
    atomic_store_explicit(&eq->meterReduction,0,memory_order_relaxed);
}
EQStereo eq_stereo_default(void) { return (EQStereo){.width=1}; }
static bool valid_stereo(const EQStereo *s) {
    return isfinite(s->leftTrimDB) && s->leftTrimDB>=-24 && s->leftTrimDB<=12 &&
           isfinite(s->rightTrimDB) && s->rightTrimDB>=-24 && s->rightTrimDB<=12 &&
           isfinite(s->balance) && fabs(s->balance)<=1 && isfinite(s->width) && s->width>=0 && s->width<=2 &&
           isfinite(s->crossfeed) && s->crossfeed>=0 && s->crossfeed<=1 &&
           isfinite(s->leftDelayMS) && s->leftDelayMS>=0 && s->leftDelayMS<=30 &&
           isfinite(s->rightDelayMS) && s->rightDelayMS>=0 && s->rightDelayMS<=30;
}
bool eq_update_filters_matched(EQ *eq, const EQFilter *filters, unsigned count, double preamp, bool bypass,
    const EQStereo *stereo, double bypassGainDB) {
    if (!valid_stereo(stereo) || !isfinite(bypassGainDB) || bypassGainDB < -24 || bypassGainDB > 12) return false;
    if (!count || count>EQMaxFilters || !isfinite(preamp) || preamp < -60 || preamp > 24) return false;
    for (unsigned i=0;i<count;i++) {
        EQFilter f=filters[i];
        if (!isfinite(f.frequency) || f.frequency<10 || f.frequency>22000 || !isfinite(f.gain) || fabs(f.gain)>30 ||
            !isfinite(f.q) || f.q<.05 || f.q>50 || (!f.disabled && f.frequency>=eq->rate*.49) || f.type>EQFilterAllPass || f.channel>EQChannelRight || (f.type>EQFilterHighShelf && f.gain!=0)) return false;
    }
    unsigned w=atomic_load_explicit(&eq->write,memory_order_relaxed), next=(w+1)%64;
    if (next==atomic_load_explicit(&eq->read,memory_order_acquire)) return false;
    memcpy(eq->queue[w].filters,filters,sizeof(EQFilter)*count);
    eq->queue[w].count=count; eq->queue[w].preamp=preamp; eq->queue[w].bypass=bypass;
    eq->queue[w].amplitude=pow(10,preamp/20);
    eq->queue[w].bypassGainDB=bypassGainDB;
    eq->queue[w].bypassAmplitude=pow(10,bypassGainDB/20);
    eq->queue[w].stereo=*stereo;
    eq->queue[w].channelGain[0]=pow(10,stereo->leftTrimDB/20)*(1-fmax(0,stereo->balance))*(stereo->invertLeft ? -1 : 1);
    eq->queue[w].channelGain[1]=pow(10,stereo->rightTrimDB/20)*(1+fmin(0,stereo->balance))*(stereo->invertRight ? -1 : 1);
    double delays[2]={stereo->leftDelayMS*eq->rate/1000,stereo->rightDelayMS*eq->rate/1000};
    for (unsigned c=0;c<2;c++) {
        eq->queue[w].delayFrames[c]=(unsigned)delays[c];
        eq->queue[w].delayFraction[c]=delays[c]-eq->queue[w].delayFrames[c];
    }
    eq->queue[w].crossfeedCoefficient=1-exp(-2*M_PI*700/eq->rate);
    eq->queue[w].crossfeedDirect=1/(1+stereo->crossfeed);
    eq->queue[w].crossfeedOpposite=stereo->crossfeed/(1+stereo->crossfeed);
    eq->queue[w].hasStereoEffects=stereo->leftTrimDB!=0 || stereo->rightTrimDB!=0 || stereo->balance!=0 ||
        stereo->width!=1 || stereo->crossfeed!=0 || stereo->leftDelayMS!=0 || stereo->rightDelayMS!=0 ||
        stereo->invertLeft || stereo->invertRight || stereo->mono;
    // Fill the target's delay history before fading it in. This avoids a gap
    // when a new delay is longer than the normal 20 ms settings crossfade.
    eq->queue[w].warmupFrames=(unsigned)ceil(fmax(delays[0],delays[1]));
    if (stereo->crossfeed>0) eq->queue[w].warmupFrames+=(unsigned)ceil(eq->rate*.005);
    for (unsigned i=0;i<count;i++) eq->queue[w].coefficients[i]=coeff(filters[i],filters[i].gain,eq->rate);
    atomic_store_explicit(&eq->write,next,memory_order_release);
    return true;
}
bool eq_update_filters_stereo(EQ *eq, const EQFilter *filters, unsigned count, double preamp, bool bypass, const EQStereo *stereo) {
    return eq_update_filters_matched(eq,filters,count,preamp,bypass,stereo,0);
}
bool eq_update_filters(EQ *eq, const EQFilter *filters, unsigned count, double preamp, bool bypass) {
    EQStereo stereo=eq_stereo_default();
    return eq_update_filters_stereo(eq,filters,count,preamp,bypass,&stereo);
}
bool eq_update(EQ *eq, const double *gains, double preamp, bool bypass) {
    if (!isfinite(preamp) || preamp < -24 || preamp > 0) return false;
    EQFilter filters[EQBands];
    for (int i=0;i<EQBands;i++) {
        if (!isfinite(gains[i]) || fabs(gains[i])>12) return false;
        filters[i]=(EQFilter){EQFrequencies[i],gains[i],1.4,EQFilterPeak,EQFrequencies[i]>=eq->rate*.49,EQChannelStereo};
    }
    return eq_update_filters(eq,filters,EQBands,preamp,bypass);
}
static float *channel(const AudioBufferList *list, unsigned index, unsigned *stride, unsigned *frames) {
    for (unsigned b=0;b<list->mNumberBuffers;b++) {
        const AudioBuffer *buffer=&list->mBuffers[b];
        if (index < buffer->mNumberChannels) {
            if (buffer->mDataByteSize % (sizeof(float)*buffer->mNumberChannels) != 0) return NULL;
            *stride=buffer->mNumberChannels;
            *frames=buffer->mDataByteSize/(sizeof(float)*(*stride));
            return buffer->mData ? (float*)buffer->mData+index : NULL;
        }
        index-=buffer->mNumberChannels;
    }
    return NULL;
}
static bool same_filter(EQFilter a, EQFilter b) {
    return a.frequency==b.frequency && a.gain==b.gain && a.q==b.q &&
           a.type==b.type && a.disabled==b.disabled && a.channel==b.channel;
}
static bool identity(Coeff a) {
    return a.b0==1 && a.b1==0 && a.b2==0 && a.a1==0 && a.a2==0;
}
static bool applies_to_channel(EQFilter filter, unsigned channelIndex) {
    return filter.channel==EQChannelStereo || filter.channel==channelIndex+1;
}
static bool same_coefficients(Coeff a, Coeff b) {
    return a.b0==b.b0 && a.b1==b.b1 && a.b2==b.b2 && a.a1==b.a1 && a.a2==b.a2;
}
static bool same_settings(const Settings *a, const Settings *b) {
    if (a->count!=b->count || a->preamp!=b->preamp || a->bypass!=b->bypass || a->bypassGainDB!=b->bypassGainDB) return false;
    EQStereo x=a->stereo,y=b->stereo;
    if (x.leftTrimDB!=y.leftTrimDB || x.rightTrimDB!=y.rightTrimDB || x.balance!=y.balance ||
        x.width!=y.width || x.crossfeed!=y.crossfeed || x.leftDelayMS!=y.leftDelayMS ||
        x.rightDelayMS!=y.rightDelayMS || x.invertLeft!=y.invertLeft || x.invertRight!=y.invertRight || x.mono!=y.mono) return false;
    for (unsigned i=0;i<a->count;i++) if (!same_filter(a->filters[i],b->filters[i])) return false;
    return true;
}
static void reset_history(Chain *chain) {
    memset(chain->z1,0,sizeof(chain->z1));
    memset(chain->z2,0,sizeof(chain->z2));
    memset(chain->crossfeedLow,0,sizeof(chain->crossfeedLow));
    // Validity bounds make old ring contents inaccessible without clearing a
    // large buffer in the callback. Both delay rings are allocated at creation.
    chain->delayIndex=chain->delayValid=0;
}
static void begin_transition(EQ *eq) {
    Chain *old=&eq->chains[eq->active], *next=&eq->chains[1-eq->active];
    eq->pending=false;
    if (same_settings(&old->settings,&eq->target)) return;
    reset_history(next);
    next->settings=eq->target;
    // Each channel's unchanged prefix has the same input history. Linear states
    // scale exactly with preamp amplitude; discarding them on a volume change
    // would temporarily remove slow bass correction after the crossfade ends.
    // Other-channel and identity filters do not break that prefix, even when
    // insertion/removal moves its slots. Never copy downstream of an edited
    // coefficient on the channel whose state is being transferred.
    double scale=next->settings.amplitude/old->settings.amplitude;
    for (unsigned c=0;c<2;c++) {
        unsigned before=0,after=0;
        while (before<old->settings.count && after<next->settings.count) {
            if (!applies_to_channel(old->settings.filters[before],c) || identity(old->settings.coefficients[before])) { before++; continue; }
            if (!applies_to_channel(next->settings.filters[after],c) || identity(next->settings.coefficients[after])) { after++; continue; }
            if (!same_coefficients(old->settings.coefficients[before],next->settings.coefficients[after])) break;
            next->z1[c][after]=old->z1[c][before]*scale;
            next->z2[c][after]=old->z2[c][before]*scale;
            before++; after++;
        }
    }
    eq->transitionFrame=0;
    eq->warmupRemaining=next->settings.warmupFrames;
    eq->transitioning=true;
}
static double run_filters(Chain *chain, unsigned channelIndex, double dry) {
    double x=dry*chain->settings.amplitude;
    for (unsigned b=0;b<chain->settings.count;b++) {
        if (!applies_to_channel(chain->settings.filters[b],channelIndex)) continue;
        Coeff a=chain->settings.coefficients[b];
        double y=a.b0*x+chain->z1[channelIndex][b];
        chain->z1[channelIndex][b]=a.b1*x-a.a1*y+chain->z2[channelIndex][b];
        chain->z2[channelIndex][b]=a.b2*x-a.a2*y;
        x=y;
    }
    return x;
}
static void run_chain(Chain *chain, const double dry[2], double result[2]) {
    const Settings *settings=&chain->settings;
    const EQStereo *stereo=&settings->stereo;
    double wet[2]={run_filters(chain,0,dry[0]),run_filters(chain,1,dry[1])};
    if (!settings->hasStereoEffects) {
        for (unsigned c=0;c<2;c++) result[c]=settings->bypass ? dry[c]*settings->bypassAmplitude : wet[c];
        return;
    }
    if (stereo->crossfeed>0) {
        for (unsigned c=0;c<2;c++) chain->crossfeedLow[c]+=settings->crossfeedCoefficient*(wet[c]-chain->crossfeedLow[c]);
        wet[0]=wet[0]*settings->crossfeedDirect+chain->crossfeedLow[1]*settings->crossfeedOpposite;
        wet[1]=wet[1]*settings->crossfeedDirect+chain->crossfeedLow[0]*settings->crossfeedOpposite;
    }
    if (stereo->mono || stereo->width!=1) {
        double mid=(wet[0]+wet[1])*.5;
        double side=stereo->mono ? 0 : (wet[0]-wet[1])*.5*stereo->width;
        wet[0]=mid+side; wet[1]=mid-side;
    }
    if (chain->delayValid<EQDelayCapacity) chain->delayValid++;
    for (unsigned c=0;c<2;c++) {
        chain->delay[c][chain->delayIndex]=wet[c]*settings->channelGain[c];
        unsigned frames=settings->delayFrames[c];
        double fraction=settings->delayFraction[c];
        unsigned index=(chain->delayIndex+EQDelayCapacity-frames)%EQDelayCapacity;
        double value=frames<chain->delayValid ? chain->delay[c][index] : 0;
        if (fraction>0) {
            unsigned previous=(index+EQDelayCapacity-1)%EQDelayCapacity;
            double older=frames+1<chain->delayValid ? chain->delay[c][previous] : 0;
            value=value*(1-fraction)+older*fraction;
        }
        // Keep the entire wet chain warm in bypass. Optional linked peak
        // protection follows this switch, as it does for filter-only bypass.
        result[c]=settings->bypass ? dry[c]*settings->bypassAmplitude : value;
    }
    chain->delayIndex=(chain->delayIndex+1)%EQDelayCapacity;
}
static void hold_maximum(_Atomic float *held, float value) {
    float previous=atomic_load_explicit(held,memory_order_relaxed);
    // A UI read can reset the hold concurrently. Retry against that reset so
    // a short peak is reported in one of the two adjacent polling intervals.
    while (value>previous && !atomic_compare_exchange_weak_explicit(held,&previous,value,
            memory_order_relaxed,memory_order_relaxed)) { }
}
void eq_process(EQ *eq, const AudioBufferList *input, AudioBufferList *output) {
    for (unsigned b=0;b<output->mNumberBuffers;b++)
        if (output->mBuffers[b].mData) memset(output->mBuffers[b].mData,0,output->mBuffers[b].mDataByteSize);
    unsigned r=atomic_load_explicit(&eq->read,memory_order_relaxed), w=atomic_load_explicit(&eq->write,memory_order_acquire);
    while (r!=w) { eq->target=eq->queue[r]; eq->pending=true; r=(r+1)%64; }
    atomic_store_explicit(&eq->read,r,memory_order_release);
    unsigned is[2]={0}, os[2]={0}, inf[2]={0}, outf[2]={0};
    float *in[2], *out[2];
    for (unsigned c=0;c<2;c++) {
        in[c]=channel(input,eq->offset+c,&is[c],&inf[c]);
        out[c]=channel(output,c,&os[c],&outf[c]);
    }
    if (!in[0] || !in[1] || !out[0] || !out[1] || inf[0]!=outf[0] || inf[1]!=outf[0] || outf[1]!=outf[0]) {
        atomic_store_explicit(&eq->peak,0,memory_order_relaxed);
        atomic_fetch_add_explicit(&eq->faults,1,memory_order_relaxed); return;
    }
    if (eq->pending && !eq->transitioning) begin_transition(eq);
    bool protectionEnabled=atomic_load_explicit(&eq->protectionEnabled,memory_order_relaxed)!=0;
    if (!protectionEnabled) eq->limiter=1;
    float peak=0;
    double minimumGain=1;
    for (unsigned f=0;f<outf[0];f++) {
        double samples[2], dry[2];
        // Convex, sample-counted crossfade: no coefficient interpolation and no
        // mid-fade resets when controls arrive rapidly. Latest pending edit wins.
        double mix=eq->transitioning && !eq->warmupRemaining ? (double)eq->transitionFrame/eq->transitionLength : 0;
        for (unsigned c=0;c<2;c++) {
            dry[c]=in[c][f*is[c]];
            if (!isfinite(dry[c])) { dry[c]=0; atomic_fetch_add_explicit(&eq->faults,1,memory_order_relaxed); }
        }
        run_chain(&eq->chains[eq->active],dry,samples);
        if (eq->transitioning) {
            double next[2];
            run_chain(&eq->chains[1-eq->active],dry,next);
            for (unsigned c=0;c<2;c++) samples[c]=samples[c]*(1-mix)+next[c]*mix;
        }
        if (!isfinite(samples[0]) || !isfinite(samples[1]) || (!protectionEnabled &&
                (fabs(samples[0])>FLT_MAX || fabs(samples[1])>FLT_MAX))) {
                // Latch a fault for the control thread and recover state without
                // allowing NaNs or float overflow to reach the device, even
                // when peak protection is off.
            for (unsigned bank=0;bank<2;bank++) reset_history(&eq->chains[bank]);
            samples[0]=samples[1]=0;
            atomic_fetch_add_explicit(&eq->faults,1,memory_order_relaxed);
        }
        if (eq->transitioning) {
            if (eq->warmupRemaining) eq->warmupRemaining--;
            else if (++eq->transitionFrame>=eq->transitionLength) {
                eq->active=1-eq->active; eq->transitioning=false;
            }
        }
        if (protectionEnabled) {
            double p=fmax(fabs(samples[0]),fabs(samples[1]));
            double target=p>.98 ? .98/p : 1;
            if (target<eq->limiter) eq->limiter=target;
            else eq->limiter+=(target-eq->limiter)*eq->release;
        }
        minimumGain=fmin(minimumGain,eq->limiter);
        for (unsigned c=0;c<2;c++) {
            double y=samples[c]*eq->limiter;
            out[c][f*os[c]]=(float)y;
            peak=fmaxf(peak,fabsf((float)y));
        }
    }
    atomic_store_explicit(&eq->peak,peak,memory_order_relaxed);
    // Publish once per buffer; no per-sample atomics, allocations, or UI work.
    hold_maximum(&eq->meterPeak,peak);
    hold_maximum(&eq->meterReduction,minimumGain<1 ? (float)(-20*log10(minimumGain)) : 0);
}
OSStatus eq_callback(AudioObjectID device, const AudioTimeStamp *now, const AudioBufferList *input,
    const AudioTimeStamp *inputTime, AudioBufferList *output, const AudioTimeStamp *outputTime, void *context) {
    eq_process(context,input,output); return noErr;
}
float eq_peak(EQ *eq) { return atomic_load_explicit(&eq->peak,memory_order_relaxed); }
EQMeter eq_read_meter(EQ *eq) {
    float peak=atomic_exchange_explicit(&eq->meterPeak,0,memory_order_relaxed);
    float reduction=atomic_exchange_explicit(&eq->meterReduction,0,memory_order_relaxed);
    return (EQMeter){peak,atomic_load_explicit(&eq->protectionEnabled,memory_order_relaxed) ? reduction : 0};
}
unsigned eq_faults(EQ *eq) { return atomic_load_explicit(&eq->faults,memory_order_relaxed); }
OSStatus eq_enable_tap_input(AudioObjectID device, AudioDeviceIOProcID proc, unsigned count) {
    if (!count) return kAudioHardwareIllegalOperationError;
    size_t size=offsetof(AudioHardwareIOProcStreamUsage,mStreamIsOn)+count*sizeof(UInt32);
    AudioHardwareIOProcStreamUsage *usage=calloc(1,size);
    if (!usage) return kAudioHardwareUnspecifiedError;
    usage->mIOProc=(void*)proc; usage->mNumberStreams=count;
    usage->mStreamIsOn[count-1]=1;
    AudioObjectPropertyAddress address={kAudioDevicePropertyIOProcStreamUsage,kAudioObjectPropertyScopeInput,kAudioObjectPropertyElementMain};
    OSStatus result=AudioObjectSetPropertyData(device,&address,0,NULL,(UInt32)size,usage);
    free(usage); return result;
}
static double response_gain(Coeff a, double c1, double s1, double c2, double s2) {
    double nr=a.b0+a.b1*c1+a.b2*c2, ni=-a.b1*s1-a.b2*s2;
    double dr=1+a.a1*c1+a.a2*c2, di=-a.a1*s1-a.a2*s2;
    // Exact notch zeros have -infinite gain. Floor only the plotted magnitude.
    return 10*log10(fmax(1e-30,(nr*nr+ni*ni)/(dr*dr+di*di)));
}
double eq_response_filters_channel(double frequency, double rate, const EQFilter *filters, unsigned count, double preamp, unsigned channel) {
    if (channel==EQChannelStereo) {
        return fmax(eq_response_filters_channel(frequency,rate,filters,count,preamp,EQChannelLeft),
                    eq_response_filters_channel(frequency,rate,filters,count,preamp,EQChannelRight));
    }
    if (channel>EQChannelRight) return NAN;
    double result=preamp, w=2*M_PI*frequency/rate;
    double c1=cos(w), s1=sin(w), c2=cos(2*w), s2=sin(2*w);
    for (unsigned i=0;i<count;i++) {
        if (filters[i].channel!=EQChannelStereo && filters[i].channel!=channel) continue;
        Coeff a=coeff(filters[i],filters[i].gain,rate);
        result+=response_gain(a,c1,s1,c2,s2);
    }
    return result;
}
bool eq_response_filters_channel_samples(const double *frequencies, unsigned frequencyCount, double rate,
    const EQFilter *filters, unsigned count, double preamp, unsigned channel, double *decibels) {
    if (count>EQMaxFilters || channel>EQChannelRight || !isfinite(rate) || rate<=0 || !isfinite(preamp)) return false;
    Coeff coefficients[EQMaxFilters];
    for (unsigned i=0;i<count;i++) coefficients[i]=coeff(filters[i],filters[i].gain,rate);
    for (unsigned f=0;f<frequencyCount;f++) {
        double w=2*M_PI*frequencies[f]/rate;
        double c1=cos(w), s1=sin(w), c2=cos(2*w), s2=sin(2*w);
        double left=preamp, right=preamp;
        for (unsigned i=0;i<count;i++) {
            unsigned target=filters[i].channel;
            if (channel!=EQChannelStereo && target!=EQChannelStereo && target!=channel) continue;
            Coeff a=coefficients[i];
            if (identity(a)) continue;
            double gain=response_gain(a,c1,s1,c2,s2);
            if (target!=EQChannelRight) left+=gain;
            if (target!=EQChannelLeft) right+=gain;
        }
        decibels[f]=channel==EQChannelLeft ? left : channel==EQChannelRight ? right : fmax(left,right);
    }
    return true;
}
double eq_response_filters(double frequency, double rate, const EQFilter *filters, unsigned count, double preamp) {
    return eq_response_filters_channel(frequency,rate,filters,count,preamp,EQChannelStereo);
}

double eq_response(double frequency, double rate, const double *gains, double preamp) {
    EQFilter filters[EQBands];
    for(int i=0;i<EQBands;i++) filters[i]=(EQFilter){EQFrequencies[i],gains[i],1.4,EQFilterPeak,EQFrequencies[i]>=rate*.49,EQChannelStereo};
    return eq_response_filters(frequency,rate,filters,EQBands,preamp);
}
