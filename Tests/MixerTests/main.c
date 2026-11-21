#include "Mixer.h"
#include "DSP.h"
#include <assert.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>

typedef struct { UInt32 count; AudioBuffer buffers[AMMaxSources]; } Inputs;
static void check_rate(double rate, bool bypass) {
    enum { Frames = 512 };
    float data[AMMaxSources][Frames * 2], output[Frames * 2], expected[Frames * 2], sum[Frames * 2];
    uint32_t offsets[AMMaxSources]; float gains[AMMaxSources];
    Inputs input = {.count = AMMaxSources};
    for (unsigned s = 0; s < AMMaxSources; s++) {
        offsets[s] = s * 2; gains[s] = s == 0 ? .25f : 1;
        input.buffers[s] = (AudioBuffer){2, sizeof(data[s]), data[s]};
        for (unsigned f = 0; f < Frames; f++) { data[s][f * 2] = .01f * (s + 1); data[s][f * 2 + 1] = -.007f * (s + 1); }
    }
    for (unsigned f = 0; f < Frames * 2; f++) {
        double value = 0; for (unsigned s = 0; s < AMMaxSources; s++) value += (double)data[s][f] * gains[s];
        sum[f] = value;
    }
    EQ *eq = eq_create(rate, 0), *reference = eq_create(rate, 0); assert(eq && reference);
    EQFilter filter = {1000, -4, 1.4, EQFilterPeak, false, EQChannelStereo};
    EQStereo stereo = eq_stereo_default(); stereo.crossfeed = .15; stereo.rightTrimDB = -1;
    assert(eq_update_filters_matched(eq, &filter, 1, -3, bypass, &stereo, -2));
    assert(eq_update_filters_matched(reference, &filter, 1, -3, bypass, &stereo, -2));
    AMMixer *m = am_create(rate, eq, offsets, AMMaxSources, gains); assert(m);
    AudioBufferList actual = {.mNumberBuffers = 1, .mBuffers = {{2, sizeof(output), output}}};
    AudioBufferList target = {.mNumberBuffers = 1, .mBuffers = {{2, sizeof(expected), expected}}};
    AudioBufferList summed = {.mNumberBuffers = 1, .mBuffers = {{2, sizeof(sum), sum}}};
    for (unsigned pass = 0; pass < 20; pass++) {
        am_process(m, (AudioBufferList *)&input, &actual); eq_process(reference, &summed, &target);
        for (unsigned f = 0; f < Frames * 2; f++) assert(fabs(output[f] - expected[f]) < 2e-7);
    }
    assert(am_counters(m).faults == 0 && am_counters(m).frames == 20 * Frames);
    assert(am_read_peak(m, 0) >= .0099 && am_read_peak(m, 0) == 0);
    assert(!am_set_gain(m, AMMaxSources, .5) && !am_set_gain(m, 0, NAN) && !am_set_gain(m, 0, 1.01));
    am_destroy(m); eq_destroy(eq); eq_destroy(reference);
}
// A device buffer longer than the mixer's scratch space must sound exactly as
// if it had been processed in one piece, with no seam and no fault.
static void check_long_buffer(void) {
    enum { Frames = AMMaxFrames * 2 + 300 };
    static float first[Frames * 2], second[Frames * 2], output[Frames * 2], expected[Frames * 2], sum[Frames * 2];
    uint32_t offsets[] = {0, 2}; float gains[] = {.5f, 1};
    for (unsigned f = 0; f < Frames * 2; f++) {
        first[f] = .2f * sinf(f * .013f); second[f] = .1f * cosf(f * .007f);
        sum[f] = (float)((double)first[f] * gains[0] + (double)second[f] * gains[1]);
    }
    EQ *eq = eq_create(48000, 0), *reference = eq_create(48000, 0); assert(eq && reference);
    EQFilter filter = {1000, -4, 1.4, EQFilterPeak, false, EQChannelStereo};
    EQStereo stereo = eq_stereo_default();
    assert(eq_update_filters_matched(eq, &filter, 1, -3, false, &stereo, 0));
    assert(eq_update_filters_matched(reference, &filter, 1, -3, false, &stereo, 0));
    AMMixer *m = am_create(48000, eq, offsets, 2, gains); assert(m);
    Inputs input = {.count = 2, .buffers = {{2, sizeof(first), first}, {2, sizeof(second), second}}};
    AudioBufferList actual = {.mNumberBuffers = 1, .mBuffers = {{2, sizeof(output), output}}};
    AudioBufferList target = {.mNumberBuffers = 1, .mBuffers = {{2, sizeof(expected), expected}}};
    AudioBufferList summed = {.mNumberBuffers = 1, .mBuffers = {{2, sizeof(sum), sum}}};
    for (unsigned pass = 0; pass < 3; pass++) {
        am_process(m, (AudioBufferList *)&input, &actual); eq_process(reference, &summed, &target);
        for (unsigned f = 0; f < Frames * 2; f++) assert(fabs(output[f] - expected[f]) < 2e-7);
    }
    assert(am_counters(m).faults == 0 && am_counters(m).frames == 3 * Frames && eq_faults(eq) == 0);
    AMDrain *drain = am_drain_create(); assert(drain);
    assert(am_drain_callback(0, NULL, &summed, NULL, NULL, NULL, drain) == noErr);
    assert(am_drain_counters(drain).faults == 0 && am_drain_counters(drain).frames == Frames);
    am_drain_destroy(drain); am_destroy(m); eq_destroy(eq); eq_destroy(reference);
}
int main(void) {
    check_long_buffer();
    for (unsigned i = 0; i < 6; i++) { double rates[] = {32000, 44100, 48000, 88200, 96000, 192000}; check_rate(rates[i], false); check_rate(rates[i], true); }
    uint32_t offsets[] = {0, 2}; float gains[] = {1, 1};
    EQ *eq = eq_create(48000, 0); assert(eq); eq_set_peak_protection(eq, false);
    AMMixer *m = am_create(48000, eq, offsets, 2, gains); assert(m);
    float source[512 * 2], peer[512 * 2], output[512 * 2];
    for (unsigned f = 0; f < 1024; f++) { source[f] = .2; peer[f] = .1; }
    Inputs input = {.count = 2, .buffers = {{2, sizeof(source), source}, {2, sizeof(peer), peer}}};
    AudioBufferList actual = {.mNumberBuffers = 1, .mBuffers = {{2, sizeof(output), output}}};
    assert(am_reset_gain(m, 0, 0));
    am_process(m, (AudioBufferList *)&input, &actual);
    // The first input sample appears after the existing EQ look-ahead. It must
    // already contain only the unaffected peer, never a ramp from unity.
    assert(fabs(output[eq_latency(eq) * 2] - .1) < 1e-6);
    EQMeter muted = eq_read_meter(eq);
    assert(fabs(muted.inputPeak - .1) < 1e-6 && muted.postEQPeak == muted.inputPeak);
    assert(am_set_gain(m, 0, .5));
    float previous = .1;
    for (unsigned pass = 0; pass < 4; pass++) {
        am_process(m, (AudioBufferList *)&input, &actual);
        for (unsigned f = 0; f < 512; f++) { assert(output[f * 2] >= previous - 1e-6); assert(output[f * 2] - previous < .001); previous = output[f * 2]; }
    }
    assert(fabs(previous - .2) < 1e-5);
    source[5] = NAN; source[7] = INFINITY;
    am_process(m, (AudioBufferList *)&input, &actual); assert(am_counters(m).signalFaults == 2);
    for (unsigned f = 0; f < 1024; f++) assert(isfinite(output[f]));
    // An empty callback is not a fault: the route would stop over it.
    AudioBufferList empty = actual; empty.mBuffers[0].mDataByteSize = 0;
    uint64_t mixed = am_counters(m).frames;
    am_process(m, (AudioBufferList *)&input, &empty);
    assert(am_counters(m).faults == 0 && am_counters(m).frames == mixed && eq_faults(eq) == 0);
    input.buffers[0].mDataByteSize--;
    am_process(m, (AudioBufferList *)&input, &actual); assert(am_counters(m).faults == 1);
    for (unsigned f = 0; f < 1024; f++) assert(output[f] == 0);
    am_destroy(m); eq_destroy(eq);
    puts("PASS nine-source mixing, six rates, EQ/stereo/Bypass equivalence, first-frame restored mute, smooth gain, peer isolation, meters, bounds and nonfinite samples");
}
