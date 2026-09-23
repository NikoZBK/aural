#include "DSP.h"
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>

const double EQFrequencies[EQBands] = {31.5,63,125,250,500,1000,2000,4000,8000,16000};
typedef struct { EQFilter filters[EQMaxFilters]; unsigned count; double preamp; bool bypass; } Settings;
typedef struct { double b0,b1,b2,a1,a2; } Coeff;
struct EQ {
    double rate;
    unsigned offset;
    Settings queue[64], target;
    _Atomic unsigned read, write, faults;
    _Atomic float peak;
    double gains[EQMaxFilters], preamp, wet;
    EQFilter layout[EQMaxFilters]; unsigned count;
    double z1[2][EQMaxFilters], z2[2][EQMaxFilters];
    double limiter;
};
_Static_assert(ATOMIC_INT_LOCK_FREE == 2, "Audio control requires lock-free atomics");
static Coeff coeff(EQFilter filter, double db, double rate) {
    double hz=filter.frequency;
    if (hz >= rate * .49 || fabs(db) < 1e-10) return (Coeff){1,0,0,0,0};
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
    } else {
        a0=1+alpha/a; b0=1+alpha*a; b1=-2*c; b2=1-alpha*a; a1=-2*c; a2=1-alpha/a;
    }
    return (Coeff){b0/a0,b1/a0,b2/a0,a1/a0,a2/a0};
}
EQ *eq_create(double rate, unsigned offset) {
    if (!isfinite(rate) || rate < 32000 || rate > 192000) return NULL;
    EQ *eq=calloc(1,sizeof(EQ));
    if (!eq) return NULL;
    eq->rate=rate; eq->offset=offset; eq->limiter=1; eq->wet=1;
    if (!atomic_is_lock_free(&eq->peak)) { free(eq); return NULL; }
    return eq;
}
void eq_destroy(EQ *eq) { free(eq); }
bool eq_update_filters(EQ *eq, const EQFilter *filters, unsigned count, double preamp, bool bypass) {
    if (!count || count>EQMaxFilters || !isfinite(preamp) || preamp < -60 || preamp > 24) return false;
    for (unsigned i=0;i<count;i++) {
        EQFilter f=filters[i];
        if (!isfinite(f.frequency) || f.frequency<10 || f.frequency>22000 || !isfinite(f.gain) || fabs(f.gain)>30 ||
            !isfinite(f.q) || f.q<.05 || f.q>50 || f.type>2) return false;
    }
    unsigned w=atomic_load_explicit(&eq->write,memory_order_relaxed), next=(w+1)%64;
    if (next==atomic_load_explicit(&eq->read,memory_order_acquire)) return false;
    memcpy(eq->queue[w].filters,filters,sizeof(EQFilter)*count);
    eq->queue[w].count=count; eq->queue[w].preamp=preamp; eq->queue[w].bypass=bypass;
    atomic_store_explicit(&eq->write,next,memory_order_release);
    return true;
}
bool eq_update(EQ *eq, const double *gains, double preamp, bool bypass) {
    if (!isfinite(preamp) || preamp < -24 || preamp > 0) return false;
    EQFilter filters[EQBands];
    for (int i=0;i<EQBands;i++) {
        if (!isfinite(gains[i]) || fabs(gains[i])>12) return false;
        filters[i]=(EQFilter){EQFrequencies[i],gains[i],1.4,0};
    }
    return eq_update_filters(eq,filters,EQBands,preamp,bypass);
}
static float *channel(const AudioBufferList *list, unsigned index, unsigned *stride, unsigned *frames) {
    for (unsigned b=0;b<list->mNumberBuffers;b++) {
        const AudioBuffer *buffer=&list->mBuffers[b];
        if (index < buffer->mNumberChannels) {
            *stride=buffer->mNumberChannels;
            *frames=buffer->mDataByteSize/(sizeof(float)*(*stride));
            return buffer->mData ? (float*)buffer->mData+index : NULL;
        }
        index-=buffer->mNumberChannels;
    }
    return NULL;
}
void eq_process(EQ *eq, const AudioBufferList *input, AudioBufferList *output) {
    for (unsigned b=0;b<output->mNumberBuffers;b++)
        if (output->mBuffers[b].mData) memset(output->mBuffers[b].mData,0,output->mBuffers[b].mDataByteSize);
    unsigned r=atomic_load_explicit(&eq->read,memory_order_relaxed), w=atomic_load_explicit(&eq->write,memory_order_acquire);
    while (r!=w) { eq->target=eq->queue[r]; r=(r+1)%64; }
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
    unsigned frames=outf[0];
    double smooth=1-exp(-(double)frames/(eq->rate*.03));
    Coeff co[EQMaxFilters];
    for (unsigned b=0;b<eq->target.count;b++) {
        EQFilter f=eq->target.filters[b], old=eq->layout[b];
        if (b>=eq->count || old.frequency!=f.frequency || old.q!=f.q || old.type!=f.type) {
            eq->gains[b]=0;
            for (unsigned c=0;c<2;c++) eq->z1[c][b]=eq->z2[c][b]=0;
        }
        eq->layout[b]=f;
        eq->gains[b]+=(f.gain-eq->gains[b])*smooth;
        co[b]=coeff(f,eq->gains[b],eq->rate);
    }
    eq->count=eq->target.count;
    double amplitude=pow(10,eq->preamp/20), desired=pow(10,eq->target.preamp/20);
    double step=frames ? (desired-amplitude)/frames : 0;
    double wetStep=1-exp(-1/(eq->rate*.01)), release=1-exp(-1/(eq->rate*.08));
    float peak=0;
    for (unsigned f=0;f<frames;f++) {
        double samples[2]; amplitude+=step;
        eq->wet+=((eq->target.bypass ? 0 : 1)-eq->wet)*wetStep;
        for (unsigned c=0;c<2;c++) {
            double dry=in[c][f*is[c]], x=dry*amplitude;
            if (!isfinite(x)) { x=0; dry=0; atomic_fetch_add_explicit(&eq->faults,1,memory_order_relaxed); }
            for (unsigned b=0;b<eq->count;b++) {
                Coeff a=co[b]; double y=a.b0*x+eq->z1[c][b];
                eq->z1[c][b]=a.b1*x-a.a1*y+eq->z2[c][b];
                eq->z2[c][b]=a.b2*x-a.a2*y; x=y;
            }
            samples[c]=dry*(1-eq->wet)+x*eq->wet;
        }
        double p=fmax(fabs(samples[0]),fabs(samples[1]));
        double target=p>.98 ? .98/p : 1;
        if (target<eq->limiter) eq->limiter=target;
        else eq->limiter+=(target-eq->limiter)*release;
        for (unsigned c=0;c<2;c++) {
            double y=samples[c]*eq->limiter;
            out[c][f*os[c]]=(float)y;
            peak=fmaxf(peak,fabsf((float)y));
        }
    }
    eq->preamp=eq->target.preamp;
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
        result+=10*log10((nr*nr+ni*ni)/(dr*dr+di*di));
    }
    return result;
}

double eq_response(double frequency, double rate, const double *gains, double preamp) {
    EQFilter filters[EQBands];
    for(int i=0;i<EQBands;i++) filters[i]=(EQFilter){EQFrequencies[i],gains[i],1.4,0};
    return eq_response_filters(frequency,rate,filters,EQBands,preamp);
}
