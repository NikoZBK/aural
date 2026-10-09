#include "DSP.h"
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <float.h>
#include <complex.h>

const double EQFrequencies[EQBands] = {31.5,63,125,250,500,1000,2000,4000,8000,16000};
typedef struct { double b0,b1,b2,a1,a2; } Coeff;
enum { EQDelayCapacity = 5762 }; // 30 ms at 192 kHz, plus interpolation guard.
enum { Fresh = 4 }; // Mailbox flag: its slot holds an update the callback has not taken.
typedef struct {
    EQFilter filters[EQMaxFilters];
    Coeff coefficients[EQMaxFilters];
    unsigned count;
    // Slots of the filters that are not identity, in order: only these run.
    unsigned active[EQMaxFilters], activeCount;
    bool hasMidSide; // an active Mid or Side filter
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
// The capacity holds the look-ahead at 192 kHz: a 1 ms ramp plus 7 frames.
enum { LimiterTaps = 12, LimiterPhases = 8, LimiterCapacity = 200 };
typedef struct {
    double interpolator[LimiterPhases-1][LimiterTaps], bound;
    double history[2][2*LimiterTaps], delayed[2][LimiterCapacity];
    double minimum[LimiterCapacity], ramp[LimiterCapacity], rampSum, held, release;
    unsigned minimumFrame[LimiterCapacity], minimumHead, minimumCount;
    unsigned frame, historyIndex, delayIndex, rampIndex, rampLength, window, latency;
} Limiter;
struct EQ {
    double rate;
    unsigned offset;
    // Triple buffer: the control thread fills slots[back] and swaps it into the
    // mailbox; the callback swaps its slot for the mailbox's when it is Fresh.
    // Updates never fail, and only the latest one is copied.
    Settings slots[3], target;
    unsigned back, front;
    _Atomic unsigned mailbox, faults, signalFaults;
    _Atomic unsigned protectionEnabled;
    _Atomic float peak, meterPeak, meterReduction;
    Chain chains[2];
    unsigned active, transitionFrame, transitionLength, warmupRemaining;
    bool transitioning, pending;
    Limiter limiter;
};
_Static_assert(ATOMIC_INT_LOCK_FREE == 2, "Audio control requires lock-free atomics");
// Filters follow the analog prototypes of the RBJ cookbook
// (https://www.w3.org/TR/audio-eq-cookbook/) at every sample rate. The bilinear
// transform would squeeze their treble toward Nyquist by a rate-dependent amount,
// so a profile would sound different at 44.1 and 96 kHz. Instead, the poles are
// mapped exactly and the numerator matches the analog magnitude at DC, Nyquist
// and the filter frequency: M. Vicanek, "Matched Second Order Digital Filters" (2016).

// |c2 s² + c1 s + c0|² at s = jx.
static double quad(double c2, double c1, double c0, double x) {
    double re=c0-c2*x*x, im=c1*x;
    return re*re+im*im;
}
// A pole pair r·e^{±jθ}, or two real poles r[0], r[1] (θ = 0); d = 1 - r.
typedef struct { double r[2], d[2], theta; } Poles;
// Poles of s² + s w/q + w², with w in radians per sample, mapped by z = e^s.
static Poles matched_poles(double w, double q) {
    double z=1/(2*q);
    if (z<1) { double r=exp(-z*w), d=-expm1(-z*w); return (Poles){{r,r},{d,d},w*sqrt(1-z*z)}; }
    double s=sqrt(z*z-1), slow=w/(z+s), fast=w*(z+s); // slow = w(z - s) without cancellation
    return (Poles){{exp(-slow),exp(-fast)},{-expm1(-slow),-expm1(-fast)},0};
}
// |1 + a1 e^{-jw} + a2 e^{-2jw}|² from distances to the poles, which stays exact
// even for slow, sharp filters whose coefficients nearly cancel.
static double pole_distance(Poles p, double w) {
    double u=sin((w-p.theta)/2), v=sin((w+p.theta)/2);
    return (p.d[0]*p.d[0]+4*p.r[0]*u*u)*(p.d[1]*p.d[1]+4*p.r[1]*v*v);
}
static Coeff with_poles(double b0, double b1, double b2, Poles p) {
    return (Coeff){b0,b1,b2,-(p.r[0]+p.r[1])*cos(p.theta),p.r[0]*p.r[1]};
}
// The numerator whose squared magnitude is dc, nyquist and at (at w). The real part
// of e^{jw}·B(e^{jw}) is fixed by the first two; the imaginary part, (b0 - b2) sin w,
// supplies the rest.
static Coeff matched(Poles p, double dc, double nyquist, double at, double w) {
    double r0=sqrt(dc*pole_distance(p,0)), r1=sqrt(nyquist*pole_distance(p,M_PI));
    double c=cos(w/2), s=sin(w/2), re=r0*c*c-r1*s*s;
    double sum=(r0+r1)/2, difference=sqrt(fmax(0,at*pole_distance(p,w)-re*re))/sin(w);
    return with_poles((sum+difference)/2,(r0-r1)/2,(sum-difference)/2,p);
}
static bool has_gain(unsigned type) {
    return type<=EQFilterHighShelf || type==EQFilterLowShelf1 || type==EQFilterHighShelf1;
}
static Coeff coeff(EQFilter filter, double db, double rate) {
    double hz=filter.frequency;
    if (filter.disabled || hz >= rate * .49 || (has_gain(filter.type) && fabs(db) < 1e-10)) return (Coeff){1,0,0,0,0};
    double w=2*M_PI*hz/rate, q=filter.q, x=rate/(2*hz); // x: Nyquist relative to hz
    if (has_gain(filter.type)) {
        // Each prototype's cut is the exact inverse of its boost. Design the direction
        // whose poles are at or below hz (a high shelf's boost would put them above
        // Nyquist), then invert; the matched zeros are minimum phase, so this is stable.
        bool high=filter.type==EQFilterHighShelf || filter.type==EQFilterHighShelf1, invert=high ? db>0 : db<0;
        double a=pow(10,(high ? -fabs(db) : fabs(db))/40), s=sqrt(a);
        Coeff c;
        if (filter.type==EQFilterPeak)
            c=matched(matched_poles(w,a*q),1,quad(1,a/q,1,x)/quad(1,1/(a*q),1,x),a*a*a*a,w);
        else if (filter.type>=EQFilterLowShelf1) {
            // The low shelf is (s + a)/(s + 1/a), the high shelf a²(s + 1/a)/(s + a). One real
            // pole leaves the other at the origin. One pole cannot follow the analog shape
            // all the way to Nyquist: shelves up to 15 kHz stay within 0.6 dB at 44.1 kHz.
            double pole=high ? w*a : w/a, low=quad(0,1,a,x)/quad(0,1,1/a,x);
            Poles p={{exp(-pole),0},{-expm1(-pole),1},0};
            c=high ? matched(p,1,a*a*a*a/low,a*a,w) : matched(p,a*a*a*a,low,a*a,w);
        }
        else if (!high)
            c=matched(matched_poles(w/s,q),a*a*a*a,a*a*quad(1,s/q,a,x)/quad(a,s/q,1,x),a*a,w);
        else
            c=matched(matched_poles(w*s,q),1,a*a*quad(a,s/q,1,x)/quad(1,s/q,a,x),a*a,w);
        return invert ? (Coeff){1/c.b0,c.a1/c.b0,c.a2/c.b0,c.b1/c.b0,c.b2/c.b0} : c;
    }
    if (filter.type==EQFilterLowPass1 || filter.type==EQFilterHighPass1) {
        // 1/(s + 1) and s/(s + 1), with the second pole at the origin as in the 6 dB/octave
        // shelves. The high-pass has one zero at DC, for its slope, and matches the gain at hz.
        Poles p={{exp(-w),0},{-expm1(-w),1},0};
        if (filter.type==EQFilterLowPass1) return matched(p,1,1/quad(0,1,1,x),.5,w);
        double k=sqrt(pole_distance(p,w)/2)/(2*sin(w/2));
        return with_poles(k,-k,0,p);
    }
    if (filter.type==EQFilterAllPass) {
        // Unity magnitude at any rate; the bilinear form keeps the phase inversion at hz.
        double alpha=sin(w)/(2*q), a0=1+alpha;
        return (Coeff){(1-alpha)/a0,-2*cos(w)/a0,1,-2*cos(w)/a0,(1-alpha)/a0};
    }
    Poles p=matched_poles(w,q);
    double d=quad(1,1/q,1,x);
    switch (filter.type) {
    case EQFilterLowPass: return matched(p,1,1/d,q*q,w);
    case EQFilterHighPass: {
        // A double zero at DC keeps the 12 dB/octave slope; the gain matches at hz.
        double k=q*sqrt(pole_distance(p,w))/(4*sin(w/2)*sin(w/2));
        return with_poles(k,-2*k,k,p);
    }
    case EQFilterBandPass: return matched(p,0,x*x/(q*q*d),1,w); // 0 dB peak
    case EQFilterNotch: {
        // Zeros exactly at hz; unity at DC, where |A| is the pole distance.
        double k=sqrt(pole_distance(p,0))/(4*sin(w/2)*sin(w/2));
        return with_poles(k,-2*cos(w)*k,k,p);
    }
    default: return (Coeff){NAN,NAN,NAN,NAN,NAN}; // invalid callers must not look like unity
    }
}
static bool identity(Coeff a) {
    return a.b0==1 && a.b1==0 && a.b2==0 && a.a1==0 && a.a2==0;
}
// Peak protection looks ahead instead of jumping: the output is the input `latency`
// frames late, and its gain falls along a 1 ms ramp to arrive at each peak in time.
// Peaks are true peaks, read between samples at 8x by windowed-sinc interpolation, so
// the waveform a DAC reconstructs also stays at the ceiling: within 0.05 dB below
// 13 kHz at 44.1 kHz, and 0.2 dB at 20 kHz. Each frame's requirement covers the
// interpolated interval six to five frames back, plus two frames either side for the
// ramp. The minimum spans `window` requirements and the ramp averages `rampLength`
// of them, so every gain applied to a frame is at or below each requirement covering it.
static double bessel0(double x) {
    double sum=1, term=1;
    for (unsigned k=1;k<40;k++) { term*=(x/(2*k))*(x/(2*k)); sum+=term; }
    return sum;
}
static void limiter_init(Limiter *l, double rate) {
    l->rampLength=(unsigned)ceil(rate/1000);
    l->window=l->rampLength+5; l->latency=l->rampLength+7;
    l->release=1-exp(-1/(rate*.08));
    l->held=1; l->rampSum=l->rampLength;
    for (unsigned i=0;i<l->rampLength;i++) l->ramp[i]=1;
    // Kaiser-windowed sinc (beta 5). Phase k lies k/8 of a frame after tap 5, the frame
    // itself being phase 0; each phase has unity gain at DC.
    for (unsigned k=1;k<LimiterPhases;k++) {
        double *h=l->interpolator[k-1], sum=0, magnitude=0;
        for (unsigned j=0;j<LimiterTaps;j++) {
            double t=(double)j-(LimiterTaps/2-1)-(double)k/LimiterPhases, r=t/(LimiterTaps/2);
            h[j]=sin(M_PI*t)/(M_PI*t)*bessel0(5*sqrt(1-r*r))/bessel0(5);
            sum+=h[j];
        }
        for (unsigned j=0;j<LimiterTaps;j++) { h[j]/=sum; magnitude+=fabs(h[j]); }
        l->bound=fmax(l->bound,magnitude);
    }
}
// Takes this frame and returns, in place, the frame `latency` earlier, with its gain.
static double limit(Limiter *l, double samples[2], bool enabled, double ceiling) {
    unsigned h=l->historyIndex;
    double peak=0, requirement=1;
    for (unsigned c=0;c<2;c++) l->history[c][h]=l->history[c][h+LimiterTaps]=samples[c];
    l->historyIndex=(h+1)%LimiterTaps;
    if (enabled) {
        for (unsigned c=0;c<2;c++) {
            const double *x=&l->history[c][h+1]; // the doubled ring keeps the taps contiguous, oldest first
            double largest=0;
            for (unsigned j=0;j<LimiterTaps;j++) largest=fmax(largest,fabs(x[j]));
            if (largest*l->bound<=ceiling) continue; // nothing between these frames can reach the ceiling
            peak=fmax(peak,fabs(x[LimiterTaps/2-1]));
            for (unsigned k=0;k<LimiterPhases-1;k++) {
                double y=0;
                for (unsigned j=0;j<LimiterTaps;j++) y+=l->interpolator[k][j]*x[j];
                peak=fmax(peak,fabs(y));
            }
        }
        if (peak>ceiling) requirement=ceiling/peak;
    }
    // Sliding minimum: a queue of requirements, each smaller than those after it.
    unsigned n=l->frame++;
    while (l->minimumCount && l->minimum[(l->minimumHead+l->minimumCount-1)%LimiterCapacity]>=requirement) l->minimumCount--;
    unsigned tail=(l->minimumHead+l->minimumCount++)%LimiterCapacity;
    l->minimum[tail]=requirement; l->minimumFrame[tail]=n;
    if (n-l->minimumFrame[l->minimumHead]>=l->window) { l->minimumHead=(l->minimumHead+1)%LimiterCapacity; l->minimumCount--; }
    double least=l->minimum[l->minimumHead];
    // Instant attack, 80 ms release, never above the minimum.
    l->held=least<l->held ? least : l->held+(least-l->held)*l->release;
    l->rampSum+=l->held-l->ramp[l->rampIndex];
    l->ramp[l->rampIndex]=l->held;
    if (++l->rampIndex==l->rampLength) {
        l->rampIndex=0; l->rampSum=0;
        for (unsigned i=0;i<l->rampLength;i++) l->rampSum+=l->ramp[i]; // no drift
    }
    for (unsigned c=0;c<2;c++) {
        double next=samples[c];
        samples[c]=l->delayed[c][l->delayIndex];
        l->delayed[c][l->delayIndex]=next;
    }
    l->delayIndex=(l->delayIndex+1)%l->latency;
    return l->rampSum/l->rampLength;
}
EQ *eq_create(double rate, unsigned offset) {
    if (!isfinite(rate) || rate < 32000 || rate > 192000) return NULL;
    EQ *eq=calloc(1,sizeof(EQ));
    if (!eq) return NULL;
    eq->rate=rate; eq->offset=offset;
    eq->back=0; atomic_init(&eq->mailbox,1); eq->front=2;
    atomic_init(&eq->protectionEnabled,1);
    limiter_init(&eq->limiter,rate);
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
            !isfinite(f.q) || f.q<.05 || f.q>50 || (!f.disabled && f.frequency>=eq->rate*.49) || f.type>EQFilterHighPass1 || f.channel>EQChannelSide || (!has_gain(f.type) && f.gain!=0)) return false;
    }
    Settings *next=&eq->slots[eq->back];
    memcpy(next->filters,filters,sizeof(EQFilter)*count);
    next->count=count; next->preamp=preamp; next->bypass=bypass;
    next->amplitude=pow(10,preamp/20);
    next->bypassGainDB=bypassGainDB;
    next->bypassAmplitude=pow(10,bypassGainDB/20);
    next->stereo=*stereo;
    next->channelGain[0]=pow(10,stereo->leftTrimDB/20)*(1-fmax(0,stereo->balance))*(stereo->invertLeft ? -1 : 1);
    next->channelGain[1]=pow(10,stereo->rightTrimDB/20)*(1+fmin(0,stereo->balance))*(stereo->invertRight ? -1 : 1);
    double delays[2]={stereo->leftDelayMS*eq->rate/1000,stereo->rightDelayMS*eq->rate/1000};
    for (unsigned c=0;c<2;c++) {
        next->delayFrames[c]=(unsigned)delays[c];
        next->delayFraction[c]=delays[c]-next->delayFrames[c];
    }
    next->crossfeedCoefficient=1-exp(-2*M_PI*700/eq->rate);
    next->crossfeedDirect=1/(1+stereo->crossfeed);
    next->crossfeedOpposite=stereo->crossfeed/(1+stereo->crossfeed);
    next->hasStereoEffects=stereo->leftTrimDB!=0 || stereo->rightTrimDB!=0 || stereo->balance!=0 ||
        stereo->width!=1 || stereo->crossfeed!=0 || stereo->leftDelayMS!=0 || stereo->rightDelayMS!=0 ||
        stereo->invertLeft || stereo->invertRight || stereo->mono;
    // Fill the target's delay history before fading it in. This avoids a gap
    // when a new delay is longer than the normal 20 ms settings crossfade.
    next->warmupFrames=(unsigned)ceil(fmax(delays[0],delays[1]));
    if (stereo->crossfeed>0) next->warmupFrames+=(unsigned)ceil(eq->rate*.005);
    next->activeCount=0; next->hasMidSide=false;
    for (unsigned i=0;i<count;i++) {
        next->coefficients[i]=coeff(filters[i],filters[i].gain,eq->rate);
        if (identity(next->coefficients[i])) continue;
        next->active[next->activeCount++]=i;
        if (filters[i].channel>=EQChannelMid) next->hasMidSide=true;
    }
    // Publish; an update the callback has not taken yet is replaced.
    eq->back=atomic_exchange_explicit(&eq->mailbox,eq->back|Fresh,memory_order_acq_rel)&3;
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
        x.rightDelayMS!=y.rightDelayMS || x.invertLeft!=y.invertLeft || x.invertRight!=y.invertRight || x.mono!=y.mono ||
        x.swapChannels!=y.swapChannels) return false;
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
static bool within(double a, double b, double ratio) { return a<=b*ratio && b<=a*ratio; }
// Dragging a control sends many small in-place edits. Restarting the edited
// filter for each one drops slow bass until it rings up again. Measured against
// a restart at 44.1-192 kHz, carried state dips less and overshoots no more
// within these limits; larger frequency jumps can overshoot, so they restart.
static bool small_edit(EQFilter a, EQFilter b) {
    return a.type==b.type && a.channel==b.channel && a.disabled==b.disabled &&
           within(a.frequency,b.frequency,1.2599210498948732) && within(a.q,b.q,4) && fabs(a.gain-b.gain)<=3;
}
// The lanes a filter runs on: Left or Mid is lane 0, Right or Side lane 1, Stereo both.
static unsigned first_lane(unsigned channel) { return channel==EQChannelRight || channel==EQChannelSide; }
static unsigned last_lane(unsigned channel) { return channel!=EQChannelLeft && channel!=EQChannelMid; }
// Mid/Side filters mix the channels, so the lanes' history carries over together,
// along the prefix of filters that match in channel and coefficients (identity
// filters aside), and through a small in-place edit as in the per-channel walk.
// Each chain switches between L/R and M/S lanes at its own filters; a Stereo filter
// can meet them in different domains, and its state, linear in its input, converts
// exactly by L = M + S and R = M - S.
static void carry_mid_side(const Chain *old, Chain *next, double scale) {
    const Settings *a=&old->settings, *b=&next->settings;
    bool sameSlots=a->count==b->count, oldMidSide=false, newMidSide=false;
    unsigned before=0, after=0;
    while (before<a->count && after<b->count) {
        EQFilter x=a->filters[before], y=b->filters[after];
        bool oldActive=!identity(a->coefficients[before]), newActive=!identity(b->coefficients[after]);
        if (!(sameSlots && before==after && small_edit(x,y))) {
            if (!oldActive) { before++; continue; }
            if (!newActive) { after++; continue; }
            if (x.channel!=y.channel || !same_coefficients(a->coefficients[before],b->coefficients[after])) break;
        }
        if (oldActive && x.channel!=EQChannelStereo) oldMidSide=x.channel>=EQChannelMid;
        if (newActive && y.channel!=EQChannelStereo) newMidSide=y.channel>=EQChannelMid;
        if (oldActive && newActive) {
            double z1[2]={old->z1[0][before],old->z1[1][before]}, z2[2]={old->z2[0][before],old->z2[1][before]};
            if (oldMidSide!=newMidSide) {
                double k=newMidSide ? .5 : 1, p1=z1[0], q1=z1[1], p2=z2[0], q2=z2[1];
                z1[0]=(p1+q1)*k; z1[1]=(p1-q1)*k; z2[0]=(p2+q2)*k; z2[1]=(p2-q2)*k;
            }
            for (unsigned c=first_lane(y.channel);c<=last_lane(y.channel);c++) {
                next->z1[c][after]=z1[c]*scale;
                next->z2[c][after]=z2[c]*scale;
            }
        }
        before++; after++;
    }
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
    // insertion/removal moves its slots. A small in-place edit keeps its state
    // and the prefix; after any other edited coefficient, never copy history on
    // the channel whose state is being transferred.
    double scale=next->settings.amplitude/old->settings.amplitude;
    bool sameSlots=old->settings.count==next->settings.count;
    // Toggling the swap moves each input to the other channel's filters, so
    // history comes from the channel that was filtering the same input.
    bool crossed=old->settings.stereo.swapChannels!=next->settings.stereo.swapChannels;
    // With Mid/Side filters a swap toggle also reverses the side signal: restart.
    if (old->settings.hasMidSide || next->settings.hasMidSide) {
        if (!crossed) carry_mid_side(old,next,scale);
    } else for (unsigned c=0;c<2;c++) {
        unsigned from=crossed ? 1-c : c, before=0,after=0;
        while (before<old->settings.count && after<next->settings.count) {
            if (!crossed && sameSlots && before==after && small_edit(old->settings.filters[before],next->settings.filters[after])) {
                if (applies_to_channel(next->settings.filters[after],c) && !identity(next->settings.coefficients[after])) {
                    next->z1[c][after]=old->z1[c][before]*scale;
                    next->z2[c][after]=old->z2[c][before]*scale;
                }
                before++; after++; continue;
            }
            if (!applies_to_channel(old->settings.filters[before],from) || identity(old->settings.coefficients[before])) { before++; continue; }
            if (!applies_to_channel(next->settings.filters[after],c) || identity(next->settings.coefficients[after])) { after++; continue; }
            if (!same_coefficients(old->settings.coefficients[before],next->settings.coefficients[after])) break;
            next->z1[c][after]=old->z1[from][before]*scale;
            next->z2[c][after]=old->z2[from][before]*scale;
            before++; after++;
        }
    }
    eq->transitionFrame=0;
    eq->warmupRemaining=next->settings.warmupFrames;
    eq->transitioning=true;
}
// The lanes hold L and R until a Mid or Side filter needs M and S, and switch back
// at the next Left or Right filter. Identity filters never run, so they cannot
// switch either, and a chain without Mid/Side filters runs each channel exactly
// as an independent chain would.
static void run_filters(Chain *chain, const double dry[2], double wet[2]) {
    const Settings *settings=&chain->settings;
    double x[2]={dry[0]*settings->amplitude,dry[1]*settings->amplitude};
    bool midSide=false;
    for (unsigned i=0;i<settings->activeCount;i++) {
        unsigned b=settings->active[i], channel=settings->filters[b].channel;
        if (channel!=EQChannelStereo && (channel>=EQChannelMid)!=midSide) {
            double l=x[0], r=x[1];
            midSide=!midSide;
            if (midSide) { x[0]=(l+r)*.5; x[1]=(l-r)*.5; }
            else { x[0]=l+r; x[1]=l-r; }
        }
        Coeff a=settings->coefficients[b];
        for (unsigned c=first_lane(channel);c<=last_lane(channel);c++) {
            double y=a.b0*x[c]+chain->z1[c][b];
            chain->z1[c][b]=a.b1*x[c]-a.a1*y+chain->z2[c][b];
            chain->z2[c][b]=a.b2*x[c]-a.a2*y;
            x[c]=y;
        }
    }
    if (midSide) { wet[0]=x[0]+x[1]; wet[1]=x[0]-x[1]; }
    else { wet[0]=x[0]; wet[1]=x[1]; }
}
static void run_chain(Chain *chain, const double dry[2], double result[2]) {
    const Settings *settings=&chain->settings;
    const EQStereo *stereo=&settings->stereo;
    unsigned swap=stereo->swapChannels;
    double input[2]={dry[swap],dry[1-swap]}, wet[2];
    run_filters(chain,input,wet);
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
// After the input goes silent, filter state decays into subnormal limit cycles
// that never reach zero, and subnormal arithmetic is very slow on Intel. Flush
// state far below audibility (-600 dB) once per buffer.
static void flush_tiny_state(Chain *chain) {
    for (unsigned c=0;c<2;c++) {
        for (unsigned b=0;b<chain->settings.count;b++) {
            if (fabs(chain->z1[c][b])<1e-30) chain->z1[c][b]=0;
            if (fabs(chain->z2[c][b])<1e-30) chain->z2[c][b]=0;
        }
        if (fabs(chain->crossfeedLow[c])<1e-30) chain->crossfeedLow[c]=0;
    }
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
    if (atomic_load_explicit(&eq->mailbox,memory_order_relaxed)&Fresh) {
        eq->front=atomic_exchange_explicit(&eq->mailbox,eq->front,memory_order_acq_rel)&3;
        eq->target=eq->slots[eq->front]; eq->pending=true;
    }
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
    float peak=0;
    double minimumGain=1;
    for (unsigned f=0;f<outf[0];f++) {
        double samples[2], dry[2];
        // Convex, sample-counted crossfade: no coefficient interpolation and no
        // mid-fade resets when controls arrive rapidly. Latest pending edit wins.
        double mix=eq->transitioning && !eq->warmupRemaining ? (double)eq->transitionFrame/eq->transitionLength : 0;
        for (unsigned c=0;c<2;c++) {
            dry[c]=in[c][f*is[c]];
            if (!isfinite(dry[c])) { dry[c]=0; atomic_fetch_add_explicit(&eq->signalFaults,1,memory_order_relaxed); }
        }
        run_chain(&eq->chains[eq->active],dry,samples);
        if (eq->transitioning) {
            double next[2];
            run_chain(&eq->chains[1-eq->active],dry,next);
            for (unsigned c=0;c<2;c++) samples[c]=samples[c]*(1-mix)+next[c]*mix;
        }
        if (!isfinite(samples[0]) || !isfinite(samples[1]) || (!protectionEnabled &&
                (fabs(samples[0])>FLT_MAX || fabs(samples[1])>FLT_MAX))) {
            // Count a signal fault for the control thread and recover state
            // without allowing NaNs or float overflow to reach the device, even
            // when peak protection is off.
            for (unsigned bank=0;bank<2;bank++) reset_history(&eq->chains[bank]);
            samples[0]=samples[1]=0;
            atomic_fetch_add_explicit(&eq->signalFaults,1,memory_order_relaxed);
        }
        if (eq->transitioning) {
            if (eq->warmupRemaining) eq->warmupRemaining--;
            else if (++eq->transitionFrame>=eq->transitionLength) {
                eq->active=1-eq->active; eq->transitioning=false;
            }
        }
        // Off stops limiting new peaks. Reduction already applied releases as
        // usual instead of jumping back up within one sample, which clicks.
        double gain=limit(&eq->limiter,samples,protectionEnabled,.98);
        if (protectionEnabled) {
            // Frames delayed while protection was off, and rounding in the ramp,
            // must not pass the ceiling either.
            double over=fmax(fabs(samples[0]),fabs(samples[1]))*gain;
            if (over>.98) gain*=.98/over;
        }
        minimumGain=fmin(minimumGain,gain);
        for (unsigned c=0;c<2;c++) {
            double y=samples[c]*gain;
            out[c][f*os[c]]=(float)y;
            peak=fmaxf(peak,fabsf((float)y));
        }
    }
    for (unsigned bank=0;bank<2;bank++) flush_tiny_state(&eq->chains[bank]);
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
unsigned eq_latency(const EQ *eq) { return eq->limiter.latency; }
EQMeter eq_read_meter(EQ *eq) {
    float peak=atomic_exchange_explicit(&eq->meterPeak,0,memory_order_relaxed);
    float reduction=atomic_exchange_explicit(&eq->meterReduction,0,memory_order_relaxed);
    return (EQMeter){peak,atomic_load_explicit(&eq->protectionEnabled,memory_order_relaxed) ? reduction : 0};
}
unsigned eq_faults(EQ *eq) { return atomic_load_explicit(&eq->faults,memory_order_relaxed); }
unsigned eq_signal_faults(EQ *eq) { return atomic_load_explicit(&eq->signalFaults,memory_order_relaxed); }
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
static double norm(double complex z) { return creal(z)*creal(z)+cimag(z)*cimag(z); }
static double power_db(double power) { return 10*log10(fmax(1e-30,power)); }
// One frequency (w in radians per sample) of prepared filters. Independent channels
// add their filters' dB responses. Once Mid/Side filters mix the channels, the
// complex 2x2 matrix from the L/R inputs to the L/R outputs gives each measure.
static double response_at(double w, const EQFilter *filters, const Coeff *coefficients, unsigned count,
    double preamp, unsigned channel, bool mixed) {
    double c1=cos(w), s1=sin(w), c2=cos(2*w), s2=sin(2*w);
    if (!mixed) {
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
        return channel==EQChannelLeft ? left : channel==EQChannelRight ? right : fmax(left,right);
    }
    double complex e1=CMPLX(c1,-s1), e2=CMPLX(c2,-s2), t[2][2]={{1,0},{0,1}};
    for (unsigned i=0;i<count;i++) {
        Coeff a=coefficients[i];
        if (identity(a)) continue;
        double complex h=(a.b0+a.b1*e1+a.b2*e2)/(1+a.a1*e1+a.a2*e2);
        unsigned target=filters[i].channel;
        if (target<=EQChannelRight) {
            for (unsigned r=first_lane(target);r<=last_lane(target);r++) { t[r][0]*=h; t[r][1]*=h; }
            continue;
        }
        // Mid passes (h + 1)/2 of each input to its own output and (h - 1)/2 to the
        // other; Side passes (1 + h)/2 and (1 - h)/2.
        double complex same=(h+1)/2, across=target==EQChannelMid ? (h-1)/2 : (1-h)/2;
        for (unsigned c=0;c<2;c++) {
            double complex l=t[0][c], r=t[1][c];
            t[0][c]=same*l+across*r; t[1][c]=across*l+same*r;
        }
    }
    switch (channel) {
    case EQChannelLeft: case EQChannelRight: {
        unsigned r=channel-EQChannelLeft;
        return preamp+power_db(norm(t[r][0])+norm(t[r][1]));
    }
    case EQChannelMid: return preamp+power_db(norm((t[0][0]+t[0][1]+t[1][0]+t[1][1])/2));
    case EQChannelSide: return preamp+power_db(norm((t[0][0]-t[0][1]-t[1][0]+t[1][1])/2));
    default: {
        double l=cabs(t[0][0])+cabs(t[0][1]), r=cabs(t[1][0])+cabs(t[1][1]);
        return preamp+power_db(fmax(l*l,r*r));
    }
    }
}
double eq_response_filters_channel(double frequency, double rate, const EQFilter *filters, unsigned count, double preamp, unsigned channel) {
    double result;
    return eq_response_filters_channel_samples(&frequency,1,rate,filters,count,preamp,channel,&result) ? result : NAN;
}
bool eq_response_filters_channel_samples(const double *frequencies, unsigned frequencyCount, double rate,
    const EQFilter *filters, unsigned count, double preamp, unsigned channel, double *decibels) {
    if (count>EQMaxFilters || channel>EQChannelSide || !isfinite(rate) || rate<=0 || !isfinite(preamp)) return false;
    Coeff coefficients[EQMaxFilters];
    bool mixed=channel>=EQChannelMid;
    for (unsigned i=0;i<count;i++) {
        if (filters[i].channel>EQChannelSide) return false;
        coefficients[i]=coeff(filters[i],filters[i].gain,rate);
        if (filters[i].channel>=EQChannelMid && !identity(coefficients[i])) mixed=true;
    }
    for (unsigned f=0;f<frequencyCount;f++)
        decibels[f]=response_at(2*M_PI*frequencies[f]/rate,filters,coefficients,count,preamp,channel,mixed);
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
