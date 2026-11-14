#include "ProbeRenderer.h"
#include <math.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

enum { RenderCapacity = 8192 };
struct ARRenderer {
    ARLink *link;
    EQ *eq;
    _Atomic bool enabled;
    _Atomic uint64_t frames;
    _Atomic uint32_t formatErrors;
    _Atomic float inputPeak;
    float input[RenderCapacity * 2];
};
ARRenderer *ar_renderer_create(ARLink *link) {
    ARRenderer *r = calloc(1, sizeof(*r));
    if (!r) return NULL;
    r->eq = eq_create(ARSampleRate, 0);
    if (!r->eq) { free(r); return NULL; }
    r->link = link;
    atomic_init(&r->enabled, false); atomic_init(&r->frames, 0);
    atomic_init(&r->formatErrors, 0); atomic_init(&r->inputPeak, 0);
    if (!ar_renderer_update(r, 1000, false)) { eq_destroy(r->eq); free(r); return NULL; }
    return r;
}
void ar_renderer_destroy(ARRenderer *r) { eq_destroy(r->eq); free(r); }
bool ar_renderer_update(ARRenderer *r, double cutoff, bool bypass) {
    if (!isfinite(cutoff) || cutoff < 100 || cutoff > 18000) return false;
    EQFilter filter = {cutoff, 0, M_SQRT1_2, EQFilterLowPass, false, EQChannelStereo};
    return eq_update_filters(r->eq, &filter, 1, 0, bypass);
}
bool ar_renderer_configure(ARRenderer *r, const EQFilter *filters, unsigned count,
    double preamp, bool bypass, const EQStereo *stereo, double bypassGainDB, bool peakProtection) {
    if (!eq_update_filters_matched(r->eq, filters, count, preamp, bypass, stereo, bypassGainDB)) return false;
    eq_set_peak_protection(r->eq, peakProtection);
    return true;
}
void ar_renderer_enable(ARRenderer *r, bool enabled) { atomic_store(&r->enabled, enabled); }
ARRenderStats ar_renderer_stats(ARRenderer *r) {
    EQMeter meter = eq_read_meter(r->eq);
    return (ARRenderStats){ atomic_load(&r->frames), atomic_load(&r->formatErrors),
        eq_faults(r->eq), eq_signal_faults(r->eq), atomic_exchange(&r->inputPeak, 0), meter.peak, meter.reductionDB };
}
uint32_t ar_renderer_latency(ARRenderer *r) { return eq_latency(r->eq); }
static void silence(AudioBufferList *output) {
    for (uint32_t i = 0; i < output->mNumberBuffers; i++)
        if (output->mBuffers[i].mData) memset(output->mBuffers[i].mData, 0, output->mBuffers[i].mDataByteSize);
}
OSStatus ar_renderer_render(ARRenderer *r, uint32_t frames, AudioBufferList *output) {
    if (!atomic_load(&r->enabled)) { silence(output); return 0; }
    bool valid = frames > 0 && frames <= RenderCapacity && output->mNumberBuffers == 2;
    for (uint32_t i = 0; valid && i < 2; i++) {
        AudioBuffer b = output->mBuffers[i];
        valid = b.mNumberChannels == 1 && b.mData && b.mDataByteSize == frames * sizeof(float);
    }
    if (!valid) { atomic_fetch_add(&r->formatErrors, 1); silence(output); return -50; }
    ar_link_read(r->link, r->input, frames);
    float peak = 0;
    for (uint32_t i = 0; i < frames * 2; i++) if (isfinite(r->input[i])) peak = fmaxf(peak, fabsf(r->input[i]));
    float held = atomic_load(&r->inputPeak);
    while (held < peak && !atomic_compare_exchange_weak(&r->inputPeak, &held, peak)) {}
    AudioBufferList input = {1, {{2, frames * 2 * sizeof(float), r->input}}};
    eq_process(r->eq, &input, output);
    atomic_fetch_add(&r->frames, frames);
    return 0;
}
