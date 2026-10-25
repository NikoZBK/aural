#include "ProbeCore.h"
#include <assert.h>
#include <math.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>

static AudioBufferList *buffers(unsigned count) {
    AudioBufferList *list = calloc(1, offsetof(AudioBufferList, mBuffers) + count * sizeof(AudioBuffer));
    assert(list); list->mNumberBuffers = count; return list;
}
static void close_enough(double actual, double expected) { assert(isfinite(actual) && fabs(actual - expected) < 1e-6); }
static void run_frames(ProbeEngine *engine, AudioBufferList *input, AudioBufferList *output, unsigned loops) {
    for (unsigned i = 0; i < loops; i++) probe_process(engine, input, output);
}

int main(void) {
    enum { Frames = 256 };
    ProbeDrain *drain = probe_drain_create(); assert(drain);
    float discarded[Frames * 2], unexpected[Frames * 2];
    for (unsigned i = 0; i < Frames * 2; i++) { discarded[i] = .5; unexpected[i] = 1; }
    AudioBufferList *drainIn = buffers(1), *drainOut = buffers(0);
    drainIn->mBuffers[0] = (AudioBuffer){2, sizeof(discarded), discarded};
    probe_drain_process(drain, drainIn, drainOut);
    ProbeCounters drainCount = probe_drain_counters(drain);
    assert(drainCount.frames == Frames && drainCount.callbacks == 1 && drainCount.invalidBuffers == 0);
    for (unsigned i = 0; i < Frames * 2; i++) close_enough(discarded[i], .5);
    // Empty input is expected when the selected output is absent. Discarding
    // does not inspect PCM or dereference absent data, including silent buffers.
    drainIn->mBuffers[0].mData = NULL;
    probe_drain_process(drain, drainIn, NULL);
    probe_drain_process(drain, NULL, NULL);
    assert(probe_drain_counters(drain).frames == Frames * 2);
    drainIn->mBuffers[0].mDataByteSize--;
    probe_drain_process(drain, drainIn, NULL);
    assert(probe_drain_counters(drain).invalidBuffers == 1);
    free(drainIn); free(drainOut);
    drainIn = buffers(2); drainOut = buffers(1);
    for (unsigned i = 0; i < 2; i++) drainIn->mBuffers[i] = (AudioBuffer){1, sizeof(discarded) / 2, discarded + i * Frames};
    probe_drain_process(drain, drainIn, NULL);
    assert(probe_drain_counters(drain).frames == Frames * 3);
    drainIn->mBuffers[1].mDataByteSize -= sizeof(float);
    probe_drain_process(drain, drainIn, NULL);
    assert(probe_drain_counters(drain).invalidBuffers == 2);
    drainIn->mBuffers[1].mDataByteSize += sizeof(float);
    drainOut->mBuffers[0] = (AudioBuffer){2, sizeof(unexpected), unexpected};
    probe_drain_process(drain, drainIn, drainOut);
    for (unsigned i = 0; i < Frames * 2; i++) close_enough(unexpected[i], 0);
    assert(probe_drain_counters(drain).invalidBuffers == 3);
    drainIn->mBuffers[0] = (AudioBuffer){1, (ProbeMaxCallbackFrames + 1) * sizeof(float), NULL};
    probe_drain_process(drain, drainIn, NULL);
    assert(probe_drain_counters(drain).invalidBuffers == 4);
    probe_drain_destroy(drain); free(drainIn); free(drainOut);
    puts("PASS input-only standby reader: interleaved/planar layouts, no PCM writes or retention, absent input, malformed buffers, frame bounds and unexpected output silencing");
    unsigned offsets[] = {0, 2};
    assert(!probe_create(48000, offsets, 0, 0));
    assert(!probe_create(48000, offsets, ProbeMaxSources + 1, 0));
    assert(!probe_create(48000, offsets, 2, 4));
    assert(!probe_create(NAN, offsets, 2, 3));
    unsigned overlap[] = {0, 1}; assert(!probe_create(48000, overlap, 2, 3));

    for (unsigned rate = 32000; rate <= 192000; rate += 32000) {
        float input[Frames * 4], output[Frames * 2];
        for (unsigned f = 0; f < Frames; f++) {
            input[4*f] = .1f; input[4*f+1] = .2f; input[4*f+2] = -.05f; input[4*f+3] = .07f;
        }
        AudioBufferList *in = buffers(1), *out = buffers(1);
        in->mBuffers[0] = (AudioBuffer){4, sizeof(input), input};
        out->mBuffers[0] = (AudioBuffer){2, sizeof(output), output};
        ProbeEngine *e = probe_create(rate, offsets, 2, 3); assert(e);
        run_frames(e, in, out, 400);
        close_enough(output[0], .05); close_enough(output[1], .27);
        assert(probe_capture_count(e, 0) == ProbeCaptureFrames && probe_capture_ready(e, 0));
        assert(!probe_prime_gain(e, 0, 0));
        close_enough(probe_rms(e, 0, 0, 0), .1);
        close_enough(probe_rms(e, 0, 2, 1), .27);
        assert(!probe_set_gain(e, 2, 1) && !probe_set_gain(e, 0, NAN) && !probe_set_gain(e, 0, 1.01));
        assert(!probe_set_phase(e, ProbeMaxPhases));
        assert(probe_set_gain(e, 0, .5) && probe_set_phase(e, 1));
        probe_process(e, in, out);
        assert(output[0] < .05f && output[0] > 0); // The first frame ramps; it never jumps to its target.
        run_frames(e, in, out, 400);
        close_enough(output[0], 0); close_enough(output[1], .17);
        float expectedGains[] = {.5, 1};
        ProbeRenderCheck measured = probe_render_check(e, 1, expectedGains, 2, 0);
        assert(measured.valid && measured.frames == ProbeCaptureFrames);
        close_enough(measured.observedGain, .5); close_enough(measured.errorRMS, 0);
        expectedGains[0] = .25;
        assert(probe_render_check(e, 1, expectedGains, 2, 0).errorRMS > .01);
        expectedGains[0] = NAN;
        assert(!probe_render_check(e, 1, expectedGains, 2, 0).valid);
        assert(!probe_render_check(e, 1, expectedGains, 1, 0).valid);
        assert(probe_set_gain(e, 0, 0) && probe_set_phase(e, 2));
        run_frames(e, in, out, 400);
        close_enough(output[0], -.05); close_enough(output[1], .07);
        in->mBuffers[0].mDataByteSize--;
        probe_process(e, in, out); close_enough(output[0], 0);
        assert(probe_counters(e).invalidBuffers == 1);
        in->mBuffers[0].mDataByteSize++;
        input[2] = NAN;
        probe_process(e, in, out); assert(isfinite(output[0]) && probe_counters(e).nonfiniteSamples == 1);
        probe_destroy(e); free(in); free(out);
    }
    puts("PASS bounded configuration, disjoint channels, interleaved summing, six rates, gain smoothing, independent mute, capture metrics, same-sample render/gain analysis, malformed buffers and nonfinite samples");

    float restoredInput[Frames * 2], restoredOutput[Frames * 2];
    for (unsigned i = 0; i < Frames * 2; i++) restoredInput[i] = .5;
    AudioBufferList *restoredIn = buffers(1), *restoredOut = buffers(1);
    restoredIn->mBuffers[0] = (AudioBuffer){2, sizeof(restoredInput), restoredInput};
    restoredOut->mBuffers[0] = (AudioBuffer){2, sizeof(restoredOutput), restoredOutput};
    unsigned restoredOffset = 0;
    for (unsigned muted = 0; muted < 2; muted++) {
        ProbeEngine *restored = probe_create(44100, &restoredOffset, 1, 1); assert(restored);
        assert(!probe_capture_ready(restored, 0));
        assert(!probe_prime_gain(restored, 1, .5) && !probe_prime_gain(restored, 0, NAN));
        assert(probe_prime_gain(restored, 0, muted ? 0 : .25));
        probe_process(restored, restoredIn, restoredOut);
        for (unsigned i = 0; i < Frames * 2; i++) close_enough(restoredOutput[i], muted ? 0 : .125);
        assert(!probe_prime_gain(restored, 0, 1));
        run_frames(restored, restoredIn, restoredOut, 200);
        assert(probe_capture_ready(restored, 0));
        close_enough(probe_rms(restored, 0, 1, 0), muted ? 0 : .125);
        probe_destroy(restored);
    }
    ProbeEngine *quiet = probe_create(48000, &restoredOffset, 1, 1); assert(quiet);
    assert(probe_capture_on_signal(quiet, 0) && probe_prime_gain(quiet, 0, 0));
    for (unsigned i = 0; i < Frames * 2; i++) restoredInput[i] = 0;
    run_frames(quiet, restoredIn, restoredOut, 400);
    assert(probe_capture_count(quiet, 0) == 0 && !probe_capture_ready(quiet, 0));
    assert(!probe_capture_on_signal(quiet, 0));
    for (unsigned i = 0; i < Frames * 2; i++) restoredInput[i] = .25;
    run_frames(quiet, restoredIn, restoredOut, 200);
    assert(probe_capture_ready(quiet, 0));
    float mutedGain = 0;
    ProbeRenderCheck afterQuiet = probe_render_check(quiet, 0, &mutedGain, 1, 0);
    assert(afterQuiet.valid); close_enough(afterQuiet.observedGain, 0); close_enough(afterQuiet.errorRMS, 0);
    probe_destroy(quiet);
    free(restoredIn); free(restoredOut);
    puts("PASS first-frame restored attenuation/mute, post-start priming rejection, quiet-app capture deferral and acquire/release capture publication");

    float left[Frames], right[Frames], sourceLeft[Frames], sourceRight[Frames], hardware[Frames];
    for (unsigned f = 0; f < Frames; f++) { sourceLeft[f] = .12; sourceRight[f] = -.09; hardware[f] = .9; }
    AudioBufferList *in = buffers(3), *out = buffers(2);
    in->mBuffers[0] = (AudioBuffer){1, sizeof(hardware), hardware};
    in->mBuffers[1] = (AudioBuffer){1, sizeof(sourceLeft), sourceLeft};
    in->mBuffers[2] = (AudioBuffer){1, sizeof(sourceRight), sourceRight};
    out->mBuffers[0] = (AudioBuffer){1, sizeof(left), left}; out->mBuffers[1] = (AudioBuffer){1, sizeof(right), right};
    unsigned offset = 1; ProbeEngine *e = probe_create(48000, &offset, 1, 1); assert(e);
    probe_process(e, in, out); close_enough(left[0], .12); close_enough(right[0], -.09);
    in->mBuffers[1].mData = NULL;
    probe_process(e, in, out); close_enough(left[0], 0); close_enough(right[0], -.09);
    assert(probe_counters(e).silentSourceFrames == Frames);
    probe_destroy(e); free(in); free(out);
    assert(!probe_tone_create(48000, 24000, .005) && !probe_tone_create(48000, 1000, .02));
    // Immediate capture must include the ownership transition, not discard it
    // with the normal gain-ramp settling interval.
    in = buffers(1); out = buffers(1);
    float comparisonInput[Frames * 6], comparisonOutput[Frames * 2];
    for (unsigned f = 0; f < Frames; f++) {
        for (unsigned c = 0; c < 2; c++) {
            comparisonInput[f*6+c] = .125f;
            comparisonInput[f*6+2+c] = .0625f;
            comparisonInput[f*6+4+c] = .1875f;
        }
    }
    in->mBuffers[0] = (AudioBuffer){6, sizeof(comparisonInput), comparisonInput};
    out->mBuffers[0] = (AudioBuffer){2, sizeof(comparisonOutput), comparisonOutput};
    unsigned comparisonOffsets[] = {0, 2, 4};
    e = probe_create(48000, comparisonOffsets, 3, 3); assert(e);
    assert(probe_set_phase_immediate(e, 1)); probe_process(e, in, out);
    assert(probe_capture_count(e, 1) == Frames);
    ProbeComparison matched = probe_compare(e, 1, 3, 2, .000002);
    assert(matched.comparedFrames == Frames && matched.mismatchedFrames == 0);
    comparisonInput[4] = .25f;
    assert(probe_set_phase_immediate(e, 2)); probe_process(e, in, out);
    ProbeComparison mismatch = probe_compare(e, 2, 3, 2, .000002);
    assert(mismatch.mismatchedFrames == 1); close_enough(mismatch.maximumDifference, .0625);
    assert(probe_buffer_count(e, true) == 1);
    ProbeBufferInfo layout = probe_buffer_info(e, true, 0);
    assert(layout.channels == 6 && layout.bytes == sizeof(comparisonInput) && layout.dataPresent);
    assert(probe_buffer_info(e, true, 33).channels == 0);
    assert(probe_set_phase_immediate(e, 3));
    in->mBuffers[0].mDataByteSize = sizeof(float) * 6;
    out->mBuffers[0].mDataByteSize = sizeof(float) * 2;
    probe_process(e, in, out);
    assert(isnan(probe_tone_amplitude(e, 3, 0, 0, 431))); // One sample has no Hann window.
    float *oversized = calloc((ProbeMaxCallbackFrames + 1) * 2, sizeof(float)); assert(oversized);
    out->mBuffers[0] = (AudioBuffer){2, (ProbeMaxCallbackFrames + 1) * 2 * sizeof(float), oversized};
    probe_process(e, in, out); assert(probe_counters(e).invalidBuffers == 1); free(oversized);
    probe_destroy(e); free(in); free(out);
    puts("PASS immediate transition capture, exact mismatch detection, layout telemetry and one-sample analysis guard");
    puts("PASS planar layout, hardware-input exclusion, silent source telemetry and quiet-tone bounds");
    return 0;
}
