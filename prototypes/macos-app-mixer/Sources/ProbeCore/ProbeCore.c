#include "ProbeCore.h"
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <mach/mach_time.h>
#include <stddef.h>
#include <libproc.h>
#include <errno.h>

enum { ProbeLayoutCapacity = 32 };
struct ProbeEngine {
    double rate, nanosecondsPerTick;
    unsigned sourceCount, phase, phaseFrames, rampFrames, settleFrames;
    uint32_t offsets[ProbeMaxSources], playbackMask;
    int captureTriggerSource;
    atomic_uint gainBits[ProbeMaxSources], requestedPhase;
    float gain[ProbeMaxSources], target[ProbeMaxSources], step[ProbeMaxSources];
    unsigned remaining[ProbeMaxSources], captured[ProbeMaxPhases];
    float *capture;
    atomic_bool processed, captureComplete[ProbeMaxPhases];
    unsigned inputCount, outputCount;
    ProbeBufferInfo inputLayout[ProbeLayoutCapacity], outputLayout[ProbeLayoutCapacity];
    atomic_uint_fast64_t callbacks, frames, invalidBuffers, nonfiniteSamples, silentSourceFrames, maxTicks;
};
struct ProbeTone { double phase, increment, amplitude; };
struct ProbeDrain {
    double nanosecondsPerTick;
    atomic_uint_fast64_t callbacks, frames, invalidBuffers, maxTicks;
};

static unsigned float_bits(float value) { unsigned bits; memcpy(&bits, &value, sizeof(bits)); return bits; }
static float bits_float(unsigned bits) { float value; memcpy(&value, &bits, sizeof(value)); return value; }
static float *capture_at(const ProbeEngine *e, unsigned phase, unsigned source, unsigned channel) {
    return e->capture + (((size_t)phase * (ProbeMaxSources + 1) + source) * 2 + channel) * ProbeCaptureFrames;
}
static float *channel(const AudioBufferList *list, unsigned index, unsigned *stride, unsigned *frames) {
    if (!list) return NULL;
    for (unsigned b = 0; b < list->mNumberBuffers; b++) {
        const AudioBuffer *buffer = &list->mBuffers[b];
        if (index < buffer->mNumberChannels) {
            if (!buffer->mNumberChannels || buffer->mDataByteSize % (sizeof(float) * buffer->mNumberChannels)) return NULL;
            *stride = buffer->mNumberChannels;
            *frames = buffer->mDataByteSize / (sizeof(float) * *stride);
            return buffer->mData ? (float *)buffer->mData + index : NULL;
        }
        index -= buffer->mNumberChannels;
    }
    return NULL;
}
static void clear_output(AudioBufferList *output) {
    if (output) for (unsigned b = 0; b < output->mNumberBuffers; b++)
        if (output->mBuffers[b].mData) memset(output->mBuffers[b].mData, 0, output->mBuffers[b].mDataByteSize);
}

ProbeDrain *probe_drain_create(void) {
    ProbeDrain *drain = calloc(1, sizeof(*drain));
    if (!drain) return NULL;
    atomic_init(&drain->callbacks, 0); atomic_init(&drain->frames, 0);
    atomic_init(&drain->invalidBuffers, 0); atomic_init(&drain->maxTicks, 0);
    mach_timebase_info_data_t timebase;
    if (!atomic_is_lock_free(&drain->callbacks) || mach_timebase_info(&timebase) != KERN_SUCCESS) {
        free(drain); return NULL;
    }
    drain->nanosecondsPerTick = (double)timebase.numer / timebase.denom;
    return drain;
}
void probe_drain_destroy(ProbeDrain *drain) { free(drain); }
void probe_drain_process(ProbeDrain *drain, const AudioBufferList *input, AudioBufferList *output) {
    uint64_t start = mach_absolute_time();
    // A guard must never render anything, including on an unexpected layout.
    clear_output(output);
    bool valid = !output || output->mNumberBuffers == 0;
    unsigned frames = 0;
    if (input && input->mNumberBuffers) {
        valid = valid && (input->mNumberBuffers == 1 || input->mNumberBuffers == 2);
        if (valid) {
            unsigned expectedChannels = input->mNumberBuffers == 1 ? 2 : 1;
            for (unsigned b = 0; b < input->mNumberBuffers; b++) {
                const AudioBuffer *buffer = &input->mBuffers[b];
                unsigned bytesPerFrame = sizeof(float) * expectedChannels;
                unsigned count = buffer->mDataByteSize / bytesPerFrame;
                if (buffer->mNumberChannels != expectedChannels || buffer->mDataByteSize % bytesPerFrame ||
                    count > ProbeMaxCallbackFrames || (b && count != frames)) valid = false;
                if (!b) frames = count;
            }
        }
    }
    atomic_fetch_add_explicit(&drain->callbacks, 1, memory_order_relaxed);
    if (valid) atomic_fetch_add_explicit(&drain->frames, frames, memory_order_relaxed);
    else atomic_fetch_add_explicit(&drain->invalidBuffers, 1, memory_order_relaxed);
    uint64_t ticks = mach_absolute_time() - start;
    if (ticks > atomic_load_explicit(&drain->maxTicks, memory_order_relaxed)) atomic_store_explicit(&drain->maxTicks, ticks, memory_order_relaxed);
}
OSStatus probe_drain_callback(AudioObjectID device, const AudioTimeStamp *now, const AudioBufferList *input,
    const AudioTimeStamp *inputTime, AudioBufferList *output, const AudioTimeStamp *outputTime, void *context) {
    if (!context) { clear_output(output); return kAudioHardwareIllegalOperationError; }
    probe_drain_process(context, input, output); return noErr;
}
ProbeCounters probe_drain_counters(const ProbeDrain *drain) {
    return (ProbeCounters){.callbacks=atomic_load(&drain->callbacks), .frames=atomic_load(&drain->frames),
        .invalidBuffers=atomic_load(&drain->invalidBuffers),
        .maximumCallbackNanoseconds=(uint64_t)(atomic_load(&drain->maxTicks) * drain->nanosecondsPerTick)};
}

ProbeEngine *probe_create(double rate, const uint32_t *offsets, unsigned count, uint32_t mask) {
    if (!isfinite(rate) || rate < 32000 || rate > 192000 || !offsets || !count || count > ProbeMaxSources || (mask >> count)) return NULL;
    ProbeEngine *e = calloc(1, sizeof(*e));
    if (!e) return NULL;
    e->capture = calloc((size_t)ProbeMaxPhases * (ProbeMaxSources + 1) * 2 * ProbeCaptureFrames, sizeof(float));
    if (!e->capture) { free(e); return NULL; }
    // Touch every capture page before starting IO; calloc alone leaves lazy pages.
    volatile float *pages = e->capture;
    size_t sampleCount = (size_t)ProbeMaxPhases * (ProbeMaxSources + 1) * 2 * ProbeCaptureFrames;
    for (size_t i = 0; i < sampleCount; i += 1024) pages[i] = 0;
    e->captureTriggerSource = -1;
    e->rate = rate; e->sourceCount = count; e->playbackMask = mask; e->phase = ProbeMaxPhases;
    e->rampFrames = (unsigned)(rate * .02);
    mach_timebase_info_data_t timebase;
    if (mach_timebase_info(&timebase) != KERN_SUCCESS) { probe_destroy(e); return NULL; }
    e->nanosecondsPerTick = (double)timebase.numer / timebase.denom;
    atomic_init(&e->requestedPhase, 0); atomic_init(&e->processed, false);
    for (unsigned p = 0; p < ProbeMaxPhases; p++) atomic_init(&e->captureComplete[p], false);
    atomic_init(&e->callbacks, 0); atomic_init(&e->frames, 0); atomic_init(&e->invalidBuffers, 0);
    atomic_init(&e->nonfiniteSamples, 0); atomic_init(&e->silentSourceFrames, 0); atomic_init(&e->maxTicks, 0);
    for (unsigned s = 0; s < count; s++) {
        if (offsets[s] > 1024) { probe_destroy(e); return NULL; }
        for (unsigned previous = 0; previous < s; previous++)
            if (abs((int)offsets[s] - (int)offsets[previous]) < 2) { probe_destroy(e); return NULL; }
        e->offsets[s] = offsets[s]; e->gain[s] = e->target[s] = 1;
        atomic_init(&e->gainBits[s], float_bits(1));
    }
    if (!atomic_is_lock_free(&e->processed) || !atomic_is_lock_free(&e->gainBits[0]) || !atomic_is_lock_free(&e->frames)) { probe_destroy(e); return NULL; }
    return e;
}
void probe_destroy(ProbeEngine *e) { if (e) { free(e->capture); free(e); } }
bool probe_capture_on_signal(ProbeEngine *e, unsigned source) {
    if (!e || source >= e->sourceCount || atomic_load(&e->processed)) return false;
    e->captureTriggerSource = (int)source; return true;
}
bool probe_prime_gain(ProbeEngine *e, unsigned source, float gain) {
    if (!e || source >= e->sourceCount || !isfinite(gain) || gain < 0 || gain > 1 || atomic_load(&e->processed)) return false;
    e->gain[source] = e->target[source] = gain; e->step[source] = 0; e->remaining[source] = 0;
    atomic_store(&e->gainBits[source], float_bits(gain)); return true;
}
bool probe_set_gain(ProbeEngine *e, unsigned source, float gain) {
    if (!e || source >= e->sourceCount || !isfinite(gain) || gain < 0 || gain > 1) return false;
    atomic_store_explicit(&e->gainBits[source], float_bits(gain), memory_order_release);
    return true;
}
static bool request_phase(ProbeEngine *e, unsigned phase, bool immediate) {
    if (!e || phase >= ProbeMaxPhases) return false;
    atomic_store_explicit(&e->requestedPhase, phase | (immediate ? 0x100u : 0), memory_order_release);
    return true;
}
bool probe_set_phase(ProbeEngine *e, unsigned phase) { return request_phase(e, phase, false); }
bool probe_set_phase_immediate(ProbeEngine *e, unsigned phase) { return request_phase(e, phase, true); }
void probe_process(ProbeEngine *e, const AudioBufferList *input, AudioBufferList *output) {
    if (!e) { clear_output(output); return; }
    atomic_store_explicit(&e->processed, true, memory_order_relaxed);
    uint64_t start = mach_absolute_time();
    e->inputCount = input ? input->mNumberBuffers : 0;
    e->outputCount = output ? output->mNumberBuffers : 0;
    for (unsigned side = 0; side < 2; side++) {
        const AudioBufferList *list = side ? output : input;
        ProbeBufferInfo *layout = side ? e->outputLayout : e->inputLayout;
        for (unsigned b = 0; list && b < list->mNumberBuffers && b < ProbeLayoutCapacity; b++) {
            const AudioBuffer *buffer = &list->mBuffers[b];
            layout[b] = (ProbeBufferInfo){buffer->mNumberChannels, buffer->mDataByteSize, buffer->mData != NULL};
        }
    }
    unsigned outStride[2] = {0}, outFrames[2] = {0};
    float *out[2] = {channel(output, 0, &outStride[0], &outFrames[0]), channel(output, 1, &outStride[1], &outFrames[1])};
    clear_output(output);
    if (!out[0] || !out[1] || outFrames[0] != outFrames[1]) { atomic_fetch_add(&e->invalidBuffers, 1); return; }
    unsigned frames = outFrames[0];
    if (!frames || frames > ProbeMaxCallbackFrames) { atomic_fetch_add(&e->invalidBuffers, 1); return; }
    float *in[ProbeMaxSources][2]; unsigned strides[ProbeMaxSources][2], lengths[ProbeMaxSources][2];
    unsigned channels = 0;
    if (input) for (unsigned b = 0; b < input->mNumberBuffers; b++) {
        unsigned count = input->mBuffers[b].mNumberChannels;
        if (!count || count > 1024 || input->mBuffers[b].mDataByteSize % (sizeof(float) * count)) {
            atomic_fetch_add(&e->invalidBuffers, 1); return;
        }
        channels += count;
    }
    for (unsigned s = 0; s < e->sourceCount; s++) {
        if (e->offsets[s] + 1 >= channels) { atomic_fetch_add(&e->invalidBuffers, 1); return; }
        for (unsigned c = 0; c < 2; c++) {
            strides[s][c] = lengths[s][c] = 0;
            in[s][c] = channel(input, e->offsets[s] + c, &strides[s][c], &lengths[s][c]);
            if (in[s][c] && lengths[s][c] != frames) { atomic_fetch_add(&e->invalidBuffers, 1); return; }
        }
        float next = bits_float(atomic_load_explicit(&e->gainBits[s], memory_order_acquire));
        if (next != e->target[s]) {
            e->target[s] = next; e->remaining[s] = e->rampFrames;
            e->step[s] = (next - e->gain[s]) / e->rampFrames;
        }
    }
    unsigned requested = atomic_load_explicit(&e->requestedPhase, memory_order_acquire), phase = requested & 255u;
    if (phase != e->phase) {
        e->phase = phase; e->phaseFrames = 0;
        e->settleFrames = requested & 0x100u ? 0 : (unsigned)(e->rate * .25);
    }
    unsigned capturedBefore = e->captured[phase];
    uint64_t bad = 0, silent = 0;
    for (unsigned f = 0; f < frames; f++, e->phaseFrames++) {
        float mixed[2] = {0};
        // Let the tap clocks and 20 ms gain ramp settle before retaining a sample.
        bool retain = e->phaseFrames >= e->settleFrames && e->captured[phase] < ProbeCaptureFrames;
        unsigned at = e->captured[phase];
        if (retain && at == 0 && e->captureTriggerSource >= 0) {
            unsigned source = (unsigned)e->captureTriggerSource;
            bool audible = false;
            for (unsigned c = 0; c < 2; c++) {
                float value = in[source][c] ? in[source][c][f * strides[source][c]] : 0;
                if (isfinite(value) && fabsf(value) > 1e-6f) audible = true;
            }
            retain = audible;
        }
        for (unsigned s = 0; s < e->sourceCount; s++) {
            if (e->remaining[s]) {
                e->gain[s] += e->step[s];
                if (!--e->remaining[s]) e->gain[s] = e->target[s];
            }
            for (unsigned c = 0; c < 2; c++) {
                float sample = in[s][c] ? in[s][c][f * strides[s][c]] : 0;
                if (!in[s][c]) silent++;
                if (!isfinite(sample)) { sample = 0; bad++; }
                if (retain) capture_at(e, phase, s, c)[at] = sample;
                if (e->playbackMask & (1u << s)) mixed[c] += sample * e->gain[s];
            }
        }
        for (unsigned c = 0; c < 2; c++) {
            if (!isfinite(mixed[c])) { mixed[c] = 0; bad++; }
            out[c][f * outStride[c]] = mixed[c];
            if (retain) capture_at(e, phase, e->sourceCount, c)[at] = mixed[c];
        }
        if (retain) e->captured[phase]++;
    }
    if (capturedBefore < ProbeCaptureFrames && e->captured[phase] == ProbeCaptureFrames)
        atomic_store_explicit(&e->captureComplete[phase], true, memory_order_release);
    atomic_fetch_add_explicit(&e->callbacks, 1, memory_order_relaxed);
    atomic_fetch_add_explicit(&e->frames, frames, memory_order_relaxed);
    atomic_fetch_add_explicit(&e->nonfiniteSamples, bad, memory_order_relaxed);
    atomic_fetch_add_explicit(&e->silentSourceFrames, silent, memory_order_relaxed);
    uint64_t ticks = mach_absolute_time() - start;
    if (ticks > atomic_load_explicit(&e->maxTicks, memory_order_relaxed)) atomic_store_explicit(&e->maxTicks, ticks, memory_order_relaxed);
}
OSStatus probe_callback(AudioObjectID device, const AudioTimeStamp *now, const AudioBufferList *input,
    const AudioTimeStamp *inputTime, AudioBufferList *output, const AudioTimeStamp *outputTime, void *context) {
    probe_process(context, input, output); return noErr;
}
ProbeCounters probe_counters(const ProbeEngine *e) {
    return (ProbeCounters){atomic_load(&e->callbacks), atomic_load(&e->frames), atomic_load(&e->invalidBuffers),
        atomic_load(&e->nonfiniteSamples), atomic_load(&e->silentSourceFrames), (uint64_t)(atomic_load(&e->maxTicks) * e->nanosecondsPerTick)};
}
unsigned probe_buffer_count(const ProbeEngine *e, bool input) { return input ? e->inputCount : e->outputCount; }
ProbeBufferInfo probe_buffer_info(const ProbeEngine *e, bool input, unsigned index) {
    unsigned count = input ? e->inputCount : e->outputCount;
    if (index >= count || index >= ProbeLayoutCapacity) return (ProbeBufferInfo){0};
    return input ? e->inputLayout[index] : e->outputLayout[index];
}
OSStatus probe_enable_inputs(AudioObjectID device, AudioDeviceIOProcID callback, const uint32_t *enabled, unsigned count) {
    if (!enabled || !count || count > 1024) return kAudioHardwareIllegalOperationError;
    size_t size = offsetof(AudioHardwareIOProcStreamUsage, mStreamIsOn) + count * sizeof(UInt32);
    AudioHardwareIOProcStreamUsage *usage = calloc(1, size);
    if (!usage) return kAudioHardwareUnspecifiedError;
    usage->mIOProc = (void *)callback; usage->mNumberStreams = count;
    for (unsigned i = 0; i < count; i++) usage->mStreamIsOn[i] = enabled[i];
    AudioObjectPropertyAddress property = {kAudioDevicePropertyIOProcStreamUsage, kAudioObjectPropertyScopeInput, kAudioObjectPropertyElementMain};
    OSStatus result = AudioObjectSetPropertyData(device, &property, 0, NULL, (UInt32)size, usage);
    free(usage); return result;
}
OSStatus probe_device_for_uid(CFStringRef uid, AudioObjectID *device) {
    AudioObjectPropertyAddress property = {kAudioHardwarePropertyTranslateUIDToDevice, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
    UInt32 size = sizeof(*device);
    return AudioObjectGetPropertyData(kAudioObjectSystemObject, &property, sizeof(uid), &uid, &size, device);
}
int probe_process_path(pid_t pid, char *path, unsigned capacity) {
    errno = 0;
    int size = proc_pidpath(pid, path, capacity);
    return size > 0 ? size : -(errno ? errno : EIO);
}
OSStatus probe_stream_channels(AudioObjectID device, bool input, uint32_t *channels, unsigned capacity, unsigned *count) {
    AudioObjectPropertyAddress property = {kAudioDevicePropertyStreamConfiguration,
        input ? kAudioObjectPropertyScopeInput : kAudioObjectPropertyScopeOutput, kAudioObjectPropertyElementMain};
    UInt32 size = 0;
    OSStatus status = AudioObjectGetPropertyDataSize(device, &property, 0, NULL, &size);
    if (status != noErr) return status;
    if (size < offsetof(AudioBufferList, mBuffers) || size > 65536) return kAudioHardwareBadPropertySizeError;
    AudioBufferList *list = calloc(1, size);
    if (!list) return kAudioHardwareUnspecifiedError;
    status = AudioObjectGetPropertyData(device, &property, 0, NULL, &size, list);
    if (status == noErr) {
        unsigned n = list->mNumberBuffers;
        if (n > capacity || offsetof(AudioBufferList, mBuffers) + (size_t)n * sizeof(AudioBuffer) > size) status = kAudioHardwareBadPropertySizeError;
        else { for (unsigned i = 0; i < n; i++) channels[i] = list->mBuffers[i].mNumberChannels; *count = n; }
    }
    free(list); return status;
}
OSStatus probe_update_tap(AudioObjectID tap, const void *description) {
    AudioObjectPropertyAddress property = {kAudioTapPropertyDescription, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
    return AudioObjectSetPropertyData(tap, &property, 0, NULL, sizeof(description), &description);
}
OSStatus probe_set_taps(AudioObjectID aggregate, CFArrayRef tapUIDs) {
    AudioObjectPropertyAddress property = {kAudioAggregateDevicePropertyTapList, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
    return AudioObjectSetPropertyData(aggregate, &property, 0, NULL, sizeof(tapUIDs), &tapUIDs);
}
bool probe_capture_ready(const ProbeEngine *e, unsigned phase) {
    return phase < ProbeMaxPhases && atomic_load_explicit(&e->captureComplete[phase], memory_order_acquire);
}
unsigned probe_capture_count(const ProbeEngine *e, unsigned phase) { return phase < ProbeMaxPhases ? e->captured[phase] : 0; }
double probe_rms(const ProbeEngine *e, unsigned phase, unsigned source, unsigned channelIndex) {
    if (phase >= ProbeMaxPhases || source > e->sourceCount || channelIndex > 1 || !e->captured[phase]) return NAN;
    unsigned count = e->captured[phase]; const float *data = capture_at(e, phase, source, channelIndex); double sum = 0;
    for (unsigned i = 0; i < count; i++) sum += (double)data[i] * data[i];
    return sqrt(sum / count);
}
double probe_tone_amplitude(const ProbeEngine *e, unsigned phase, unsigned source, unsigned channelIndex, double frequency) {
    if (phase >= ProbeMaxPhases || source > e->sourceCount || channelIndex > 1 || e->captured[phase] < 2 || !isfinite(frequency) || frequency <= 0 || frequency >= e->rate / 2) return NAN;
    unsigned count = e->captured[phase]; const float *data = capture_at(e, phase, source, channelIndex); double real = 0, imag = 0, weight = 0;
    for (unsigned i = 0; i < count; i++) {
        double window = .5 - .5 * cos(2 * M_PI * i / (count - 1));
        double angle = 2 * M_PI * frequency * i / e->rate;
        real += data[i] * window * cos(angle); imag += data[i] * window * sin(angle); weight += window;
    }
    return 2 * hypot(real, imag) / weight;
}
ProbeComparison probe_compare(const ProbeEngine *e, unsigned phase, uint32_t mask, unsigned reference, double tolerance) {
    ProbeComparison result = {0};
    if (phase >= ProbeMaxPhases || reference >= e->sourceCount || (mask >> e->sourceCount) || !isfinite(tolerance) || tolerance < 0) return result;
    result.comparedFrames = e->captured[phase];
    for (unsigned i = 0; i < result.comparedFrames; i++) {
        bool mismatch = false;
        for (unsigned c = 0; c < 2; c++) {
            double mixed = 0;
            for (unsigned s = 0; s < e->sourceCount; s++) if (mask & (1u << s)) mixed += capture_at(e, phase, s, c)[i];
            double error = fabs(mixed - capture_at(e, phase, reference, c)[i]);
            if (error > result.maximumDifference) result.maximumDifference = error;
            if (error > tolerance) mismatch = true;
        }
        if (mismatch) result.mismatchedFrames++;
    }
    return result;
}
ProbeRenderCheck probe_render_check(const ProbeEngine *e, unsigned phase, const float *gains, unsigned count, unsigned measuredSource) {
    ProbeRenderCheck result = {0};
    if (phase >= ProbeMaxPhases || !e->captured[phase] || count != e->sourceCount || measuredSource >= count) return result;
    for (unsigned s = 0; s < count; s++) if (!isfinite(gains[s]) || gains[s] < 0 || gains[s] > 1) return result;
    double inputPower = 0, outputPower = 0, errorPower = 0, cross = 0;
    unsigned frames = e->captured[phase];
    for (unsigned i = 0; i < frames; i++) for (unsigned c = 0; c < 2; c++) {
        double expected = 0, other = 0;
        for (unsigned s = 0; s < count; s++) {
            double value = capture_at(e, phase, s, c)[i] * (double)gains[s];
            expected += value;
            if (s != measuredSource) other += value;
        }
        double input = capture_at(e, phase, measuredSource, c)[i];
        double output = capture_at(e, phase, e->sourceCount, c)[i];
        double error = output - expected;
        inputPower += input * input; outputPower += output * output;
        errorPower += error * error; cross += (output - other) * input;
    }
    if (inputPower <= 0 || !isfinite(inputPower) || !isfinite(outputPower) || !isfinite(errorPower) || !isfinite(cross)) return result;
    result.valid = true; result.frames = frames;
    result.inputRMS = sqrt(inputPower / (frames * 2)); result.outputRMS = sqrt(outputPower / (frames * 2));
    result.errorRMS = sqrt(errorPower / (frames * 2)); result.observedGain = cross / inputPower;
    return result;
}
double probe_unity_error(const ProbeEngine *e, unsigned phase, uint32_t mask, unsigned reference, int lag) {
    if (phase >= ProbeMaxPhases || reference >= e->sourceCount || !e->captured[phase] || (mask >> e->sourceCount)) return NAN;
    int count = (int)e->captured[phase]; double sum = 0; unsigned samples = 0;
    for (int i = 0; i < count; i++) {
        int j = i + lag; if (j < 0 || j >= count) continue;
        for (unsigned c = 0; c < 2; c++) {
            double mixed = 0;
            for (unsigned s = 0; s < e->sourceCount; s++) if (mask & (1u << s)) mixed += capture_at(e, phase, s, c)[i];
            double error = mixed - capture_at(e, phase, reference, c)[j]; sum += error * error; samples++;
        }
    }
    return samples ? sqrt(sum / samples) : NAN;
}
ProbeTone *probe_tone_create(double rate, double frequency, double amplitude) {
    if (!isfinite(rate) || rate < 32000 || rate > 192000 || !isfinite(frequency) || frequency <= 0 || frequency >= rate / 2 || !isfinite(amplitude) || amplitude <= 0 || amplitude > .01) return NULL;
    ProbeTone *tone = calloc(1, sizeof(*tone));
    if (tone) { tone->increment = 2 * M_PI * frequency / rate; tone->amplitude = amplitude; }
    return tone;
}
void probe_tone_destroy(ProbeTone *tone) { free(tone); }
OSStatus probe_tone_callback(AudioObjectID device, const AudioTimeStamp *now, const AudioBufferList *input,
    const AudioTimeStamp *inputTime, AudioBufferList *output, const AudioTimeStamp *outputTime, void *context) {
    ProbeTone *tone = context; clear_output(output);
    unsigned stride[2] = {0}, frames[2] = {0};
    float *out[2] = {channel(output, 0, &stride[0], &frames[0]), channel(output, 1, &stride[1], &frames[1])};
    if (!tone || !out[0] || !out[1] || frames[0] != frames[1]) return noErr;
    for (unsigned f = 0; f < frames[0]; f++) {
        float sample = (float)(sin(tone->phase) * tone->amplitude);
        tone->phase += tone->increment; if (tone->phase >= 2 * M_PI) tone->phase -= 2 * M_PI;
        out[0][f * stride[0]] = sample; out[1][f * stride[1]] = sample;
    }
    return noErr;
}
