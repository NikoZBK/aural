#include "DSP.h"
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>

const double EQFrequencies[EQBands] = {31.5,63,125,250,500,1000,2000,4000,8000,16000};
typedef struct { double b0,b1,b2,a1,a2; } Coeff;
typedef struct {
    EQFilter filters[EQMaxFilters];
    Coeff coefficients[EQMaxFilters];
    unsigned count;
    double preamp, amplitude;
    bool bypass;
} Settings;
typedef struct {
    Settings settings;
    double z1[2][EQMaxFilters], z2[2][EQMaxFilters];
} Chain;
struct EQ {
    double rate;
    unsigned offset;
    Settings queue[64], target;
    _Atomic unsigned read, write, faults;
    _Atomic float peak;
    Chain chains[2];
    unsigned active, transitionFrame, transitionLength;
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
    eq->release=1-exp(-1/(rate*.08));
    eq->transitionLength=(unsigned)ceil(rate*.02);
    eq->chains[0].settings.amplitude=eq->chains[1].settings.amplitude=1;
    if (!atomic_is_lock_free(&eq->peak)) { free(eq); return NULL; }
    return eq;
}
void eq_destroy(EQ *eq) { free(eq); }
bool eq_update_filters(EQ *eq, const EQFilter *filters, unsigned count, double preamp, bool bypass) {
    if (!count || count>EQMaxFilters || !isfinite(preamp) || preamp < -60 || preamp > 24) return false;
    for (unsigned i=0;i<count;i++) {
        EQFilter f=filters[i];
        if (!isfinite(f.frequency) || f.frequency<10 || f.frequency>22000 || !isfinite(f.gain) || fabs(f.gain)>30 ||
            !isfinite(f.q) || f.q<.05 || f.q>50 || (!f.disabled && f.frequency>=eq->rate*.49) || f.type>EQFilterAllPass || (f.type>EQFilterHighShelf && f.gain!=0)) return false;
    }
    unsigned w=atomic_load_explicit(&eq->write,memory_order_relaxed), next=(w+1)%64;
    if (next==atomic_load_explicit(&eq->read,memory_order_acquire)) return false;
    memcpy(eq->queue[w].filters,filters,sizeof(EQFilter)*count);
    eq->queue[w].count=count; eq->queue[w].preamp=preamp; eq->queue[w].bypass=bypass;
    eq->queue[w].amplitude=pow(10,preamp/20);
    for (unsigned i=0;i<count;i++) eq->queue[w].coefficients[i]=coeff(filters[i],filters[i].gain,eq->rate);
    atomic_store_explicit(&eq->write,next,memory_order_release);
    return true;
}
bool eq_update(EQ *eq, const double *gains, double preamp, bool bypass) {
    if (!isfinite(preamp) || preamp < -24 || preamp > 0) return false;
    EQFilter filters[EQBands];
    for (int i=0;i<EQBands;i++) {
        if (!isfinite(gains[i]) || fabs(gains[i])>12) return false;
        filters[i]=(EQFilter){EQFrequencies[i],gains[i],1.4,EQFilterPeak,EQFrequencies[i]>=eq->rate*.49};
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
           a.type==b.type && a.disabled==b.disabled;
}
static bool same_settings(const Settings *a, const Settings *b) {
    if (a->count!=b->count || a->preamp!=b->preamp || a->bypass!=b->bypass) return false;
    for (unsigned i=0;i<a->count;i++) if (!same_filter(a->filters[i],b->filters[i])) return false;
    return true;
}
static void begin_transition(EQ *eq) {
    Chain *old=&eq->chains[eq->active], *next=&eq->chains[1-eq->active];
    eq->pending=false;
    if (same_settings(&old->settings,&eq->target)) return;
    memset(next,0,sizeof(*next));
    next->settings=eq->target;
    // Only an unchanged prefix has the same input history. Never copy stale state
    // downstream of an edited filter or a changed preamp.
    if (old->settings.preamp==next->settings.preamp) {
        for (unsigned b=0;b<old->settings.count && b<next->settings.count;b++) {
            if (!same_filter(old->settings.filters[b],next->settings.filters[b])) break;
            for (unsigned c=0;c<2;c++) { next->z1[c][b]=old->z1[c][b]; next->z2[c][b]=old->z2[c][b]; }
        }
    }
    eq->transitionFrame=0;
    eq->transitioning=true;
}
static double run_chain(Chain *chain, unsigned channelIndex, double dry) {
    double x=dry*chain->settings.amplitude;
    for (unsigned b=0;b<chain->settings.count;b++) {
        Coeff a=chain->settings.coefficients[b];
        double y=a.b0*x+chain->z1[channelIndex][b];
        chain->z1[channelIndex][b]=a.b1*x-a.a1*y+chain->z2[channelIndex][b];
        chain->z2[channelIndex][b]=a.b2*x-a.a2*y;
        x=y;
    }
    // Keep the wet chain warm while bypassed, so re-enabling cannot replay stale state.
    return chain->settings.bypass ? dry : x;
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
        atomic_fetch_add_explicit(&eq->faults,1,memory_order_relaxed); return;
    }
    if (eq->pending && !eq->transitioning) begin_transition(eq);
    float peak=0;
    for (unsigned f=0;f<outf[0];f++) {
        double samples[2];
        // Convex, sample-counted crossfade: no coefficient interpolation and no
        // mid-fade resets when controls arrive rapidly. Latest pending edit wins.
        double mix=eq->transitioning ? (double)eq->transitionFrame/eq->transitionLength : 0;
        for (unsigned c=0;c<2;c++) {
            double dry=in[c][f*is[c]];
            if (!isfinite(dry)) { dry=0; atomic_fetch_add_explicit(&eq->faults,1,memory_order_relaxed); }
            double y=run_chain(&eq->chains[eq->active],c,dry);
            if (eq->transitioning) {
                double next=run_chain(&eq->chains[1-eq->active],c,dry);
                y=y*(1-mix)+next*mix;
            }
            if (!isfinite(y)) {
                // Latch a fault for the control thread and recover state without
                // allowing NaNs to reach the device or poison the limiter.
                for (unsigned bank=0;bank<2;bank++) {
                    memset(eq->chains[bank].z1[c],0,sizeof(eq->chains[bank].z1[c]));
                    memset(eq->chains[bank].z2[c],0,sizeof(eq->chains[bank].z2[c]));
                }
                y=0; atomic_fetch_add_explicit(&eq->faults,1,memory_order_relaxed);
            }
            samples[c]=y;
        }
        if (eq->transitioning && ++eq->transitionFrame>=eq->transitionLength) {
            eq->active=1-eq->active; eq->transitioning=false;
        }
        double p=fmax(fabs(samples[0]),fabs(samples[1]));
        double target=p>.98 ? .98/p : 1;
        if (target<eq->limiter) eq->limiter=target;
        else eq->limiter+=(target-eq->limiter)*eq->release;
        for (unsigned c=0;c<2;c++) {
            double y=samples[c]*eq->limiter;
            out[c][f*os[c]]=(float)y;
            peak=fmaxf(peak,fabsf((float)y));
        }
    }
    atomic_store_explicit(&eq->peak,peak,memory_order_relaxed);
}
OSStatus eq_callback(AudioObjectID device, const AudioTimeStamp *now, const AudioBufferList *input,
    const AudioTimeStamp *inputTime, AudioBufferList *output, const AudioTimeStamp *outputTime, void *context) {
    eq_process(context,input,output); return noErr;
}
float eq_peak(EQ *eq) { return atomic_load_explicit(&eq->peak,memory_order_relaxed); }
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
double eq_response_filters(double frequency, double rate, const EQFilter *filters, unsigned count, double preamp) {
    double result=preamp, w=2*M_PI*frequency/rate;
    for (unsigned i=0;i<count;i++) {
        Coeff a=coeff(filters[i],filters[i].gain,rate);
        double nr=a.b0+a.b1*cos(w)+a.b2*cos(2*w), ni=-a.b1*sin(w)-a.b2*sin(2*w);
        double dr=1+a.a1*cos(w)+a.a2*cos(2*w), di=-a.a1*sin(w)-a.a2*sin(2*w);
        // Exact notch zeros have -infinite gain. Floor only the plotted magnitude.
        result+=10*log10(fmax(1e-30,(nr*nr+ni*ni)/(dr*dr+di*di)));
    }
    return result;
}

double eq_response(double frequency, double rate, const double *gains, double preamp) {
    EQFilter filters[EQBands];
    for(int i=0;i<EQBands;i++) filters[i]=(EQFilter){EQFrequencies[i],gains[i],1.4,EQFilterPeak,EQFrequencies[i]>=rate*.49};
    return eq_response_filters(frequency,rate,filters,EQBands,preamp);
}
