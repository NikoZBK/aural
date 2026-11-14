#pragma once
#include "LocalTransport.h"
#include "DSP.h"
#ifdef __OBJC__
#import <AVFoundation/AVFoundation.h>
#endif
#pragma clang assume_nonnull begin

typedef struct ARRenderer ARRenderer;
typedef struct {
    uint64_t renderedFrames;
    uint32_t formatErrors, dspFaults, signalFaults;
    float inputPeak, outputPeak, reductionDB;
} ARRenderStats;
ARRenderer * _Nullable ar_renderer_create(ARLink *receiver);
void ar_renderer_destroy(ARRenderer *renderer);
bool ar_renderer_update(ARRenderer *renderer, double cutoff, bool bypass);
// Control thread only. Uses the same complete profile path as the Mac app.
bool ar_renderer_configure(ARRenderer *renderer, const EQFilter *filters, unsigned count,
    double preamp, bool bypass, const EQStereo *stereo, double bypassGainDB, bool peakProtection);
void ar_renderer_enable(ARRenderer *renderer, bool enabled);
ARRenderStats ar_renderer_stats(ARRenderer *renderer);
uint32_t ar_renderer_latency(ARRenderer *renderer);
OSStatus ar_renderer_render(ARRenderer *renderer, uint32_t frames, AudioBufferList *output);

#ifdef __OBJC__
// Construct on the control thread. The render block only calls C.
AVAudioSourceNode * _Nullable ARMakeSourceNode(ARRenderer * _Nonnull renderer);
#endif

#pragma clang assume_nonnull end
