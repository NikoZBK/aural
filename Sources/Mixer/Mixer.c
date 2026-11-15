#include "Mixer.h"
#include "DSP.h"
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <float.h>
#include <stddef.h>
#include <libproc.h>
#include <errno.h>
#include <dlfcn.h>

struct AMMixer {
    EQ *eq;
    unsigned count, offsets[AMMaxSources], rampFrames;
    atomic_uint requested[AMMaxSources], epoch[AMMaxSources];
    unsigned seen[AMMaxSources], remaining[AMMaxSources];
    float gain[AMMaxSources], target[AMMaxSources], step[AMMaxSources];
    _Atomic float peak[AMMaxSources];
    atomic_uint faults, signalFaults;
    atomic_uint_fast64_t frames;
    float scratch[AMMaxFrames * 2];
};
_Static_assert(ATOMIC_INT_LOCK_FREE == 2, "Mixer control requires lock-free integers");
static unsigned bits(float value) { unsigned result; memcpy(&result, &value, sizeof(result)); return result; }
static float number(unsigned value) { float result; memcpy(&result, &value, sizeof(result)); return result; }
static bool valid_gain(float value) { return isfinite(value) && value >= 0 && value <= 1; }
static void silence(AudioBufferList *output) {
    if (output) for (unsigned b = 0; b < output->mNumberBuffers; b++)
        if (output->mBuffers[b].mData) memset(output->mBuffers[b].mData, 0, output->mBuffers[b].mDataByteSize);
}
AMMixer *am_create(double rate, EQ *eq, const uint32_t *offsets, unsigned count, const float *gains) {
    if (!eq || !offsets || !gains || !count || count > AMMaxSources || !isfinite(rate) || rate < 32000 || rate > 192000) return NULL;
    AMMixer *m = calloc(1, sizeof(*m));
    if (!m) return NULL;
    m->eq = eq; m->count = count; m->rampFrames = (unsigned)(rate * .02);
    for (unsigned i = 0; i < count; i++) {
        if (offsets[i] > 1024 || !valid_gain(gains[i])) { free(m); return NULL; }
        for (unsigned j = 0; j < i; j++) if (abs((int)offsets[i] - (int)offsets[j]) < 2) { free(m); return NULL; }
        m->offsets[i] = offsets[i]; m->gain[i] = m->target[i] = gains[i];
        atomic_init(&m->requested[i], bits(gains[i])); atomic_init(&m->epoch[i], 0); atomic_init(&m->peak[i], 0);
    }
    atomic_init(&m->faults, 0); atomic_init(&m->signalFaults, 0); atomic_init(&m->frames, 0);
    if (!atomic_is_lock_free(&m->frames) || !atomic_is_lock_free(&m->peak[0])) { free(m); return NULL; }
    // Prefault scratch pages before IO starts.
    volatile float *pages = m->scratch;
    for (unsigned i = 0; i < AMMaxFrames * 2; i += 1024) pages[i] = 0;
    return m;
}
void am_destroy(AMMixer *m) { free(m); }
bool am_set_gain(AMMixer *m, unsigned slot, float gain) {
    if (!m || slot >= m->count || !valid_gain(gain)) return false;
    atomic_store_explicit(&m->requested[slot], bits(gain), memory_order_release); return true;
}
bool am_reset_gain(AMMixer *m, unsigned slot, float gain) {
    if (!am_set_gain(m, slot, gain)) return false;
    atomic_fetch_add_explicit(&m->epoch[slot], 1, memory_order_release); return true;
}
static const float *channel(const AudioBufferList *list, unsigned channelIndex, unsigned *stride, unsigned *frames) {
    for (unsigned b = 0; b < list->mNumberBuffers; b++) {
        const AudioBuffer *buffer = &list->mBuffers[b];
        if (channelIndex < buffer->mNumberChannels) {
            unsigned bytes = sizeof(float) * buffer->mNumberChannels;
            if (!bytes || buffer->mDataByteSize % bytes) return NULL;
            *stride = buffer->mNumberChannels; *frames = buffer->mDataByteSize / bytes;
            return buffer->mData ? (const float *)buffer->mData + channelIndex : NULL;
        }
        channelIndex -= buffer->mNumberChannels;
    }
    return NULL;
}
void am_process(AMMixer *m, const AudioBufferList *input, AudioBufferList *output) {
    if (!m) { silence(output); return; }
    unsigned outputFrames = 0, outputStride = 0;
    const float *out = output && output->mNumberBuffers <= 32 ? channel(output, 0, &outputStride, &outputFrames) : NULL;
    // An empty buffer carries nothing to mix and is not a fault, as in eq_process.
    if (out && !outputFrames) return;
    if (!input || input->mNumberBuffers > 32 || !out) {
        silence(output); atomic_fetch_add_explicit(&m->faults, 1, memory_order_relaxed); return;
    }
    const float *in[AMMaxSources][2] = {{0}};
    unsigned strides[AMMaxSources][2] = {{0}};
    float peaks[AMMaxSources] = {0};
    for (unsigned s = 0; s < m->count; s++) {
        for (unsigned c = 0; c < 2; c++) {
            unsigned frames = 0;
            in[s][c] = channel(input, m->offsets[s] + c, &strides[s][c], &frames);
            if (!strides[s][c] || (in[s][c] && frames != outputFrames)) {
                silence(output); atomic_fetch_add_explicit(&m->faults, 1, memory_order_relaxed); return;
            }
        }
        unsigned epoch = atomic_load_explicit(&m->epoch[s], memory_order_acquire);
        float desired = number(atomic_load_explicit(&m->requested[s], memory_order_acquire));
        if (epoch != m->seen[s]) {
            m->seen[s] = epoch; m->gain[s] = m->target[s] = desired; m->remaining[s] = 0;
        } else if (desired != m->target[s]) {
            m->target[s] = desired; m->remaining[s] = m->rampFrames;
            m->step[s] = (desired - m->gain[s]) / m->rampFrames;
        }
    }
    // A device buffer longer than the scratch space is mixed and equalized in
    // consecutive pieces. Each piece writes its own window of the output, so
    // every output buffer must span the same frames.
    bool pieces = outputFrames > AMMaxFrames;
    struct { UInt32 mNumberBuffers; AudioBuffer mBuffers[32]; } part = {output->mNumberBuffers};
    if (pieces) for (unsigned b = 0; b < output->mNumberBuffers; b++) {
        const AudioBuffer *buffer = &output->mBuffers[b];
        if (!buffer->mNumberChannels || buffer->mDataByteSize != (uint64_t)outputFrames * buffer->mNumberChannels * sizeof(float)) {
            silence(output); atomic_fetch_add_explicit(&m->faults, 1, memory_order_relaxed); return;
        }
    }
    unsigned bad = 0;
    for (unsigned base = 0; base < outputFrames; base += AMMaxFrames) {
        unsigned count = outputFrames - base < AMMaxFrames ? outputFrames - base : AMMaxFrames;
        for (unsigned f = 0; f < count; f++) {
            double mixed[2] = {0};
            for (unsigned s = 0; s < m->count; s++) {
                if (m->remaining[s]) { m->gain[s] += m->step[s]; if (!--m->remaining[s]) m->gain[s] = m->target[s]; }
                for (unsigned c = 0; c < 2; c++) {
                    float value = in[s][c] ? in[s][c][(size_t)(base + f) * strides[s][c]] : 0;
                    if (!isfinite(value)) { value = 0; bad++; }
                    peaks[s] = fmaxf(peaks[s], fabsf(value));
                    mixed[c] += (double)value * m->gain[s];
                }
            }
            for (unsigned c = 0; c < 2; c++) {
                if (!isfinite(mixed[c]) || fabs(mixed[c]) > FLT_MAX) { mixed[c] = 0; bad++; }
                m->scratch[2 * f + c] = (float)mixed[c];
            }
        }
        AudioBufferList stereo = {.mNumberBuffers = 1, .mBuffers = {{2, count * 2 * sizeof(float), m->scratch}}};
        if (!pieces) { eq_process(m->eq, &stereo, output); break; }
        for (unsigned b = 0; b < output->mNumberBuffers; b++) {
            const AudioBuffer *buffer = &output->mBuffers[b];
            size_t frame = buffer->mNumberChannels * sizeof(float);
            part.mBuffers[b] = (AudioBuffer){buffer->mNumberChannels, (UInt32)(count * frame),
                buffer->mData ? (char *)buffer->mData + base * frame : NULL};
        }
        eq_process(m->eq, &stereo, (AudioBufferList *)&part);
    }
    for (unsigned s = 0; s < m->count; s++) {
        float previous = atomic_load_explicit(&m->peak[s], memory_order_relaxed);
        while (peaks[s] > previous && !atomic_compare_exchange_weak_explicit(&m->peak[s], &previous, peaks[s], memory_order_relaxed, memory_order_relaxed)) { }
    }
    atomic_fetch_add_explicit(&m->signalFaults, bad, memory_order_relaxed);
    atomic_fetch_add_explicit(&m->frames, outputFrames, memory_order_relaxed);
}
OSStatus am_callback(AudioObjectID device, const AudioTimeStamp *now, const AudioBufferList *input,
    const AudioTimeStamp *inputTime, AudioBufferList *output, const AudioTimeStamp *outputTime, void *context) {
    if (!context) { silence(output); return kAudioHardwareIllegalOperationError; }
    am_process(context, input, output); return noErr;
}
AMCounters am_counters(const AMMixer *m) {
    return (AMCounters){atomic_load(&m->frames), atomic_load(&m->faults), atomic_load(&m->signalFaults)};
}
float am_read_peak(AMMixer *m, unsigned slot) { return slot < m->count ? atomic_exchange_explicit(&m->peak[slot], 0, memory_order_relaxed) : 0; }

OSStatus am_enable_inputs(AudioObjectID device, AudioDeviceIOProcID callback, const uint32_t *enabled, unsigned count) {
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
OSStatus am_stream_channels(AudioObjectID device, uint32_t *channels, unsigned capacity, unsigned *count) {
    AudioObjectPropertyAddress property = {kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeInput, kAudioObjectPropertyElementMain};
    UInt32 size = 0; OSStatus status = AudioObjectGetPropertyDataSize(device, &property, 0, NULL, &size);
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
OSStatus am_update_tap(AudioObjectID tap, const void *description) {
    AudioObjectPropertyAddress property = {kAudioTapPropertyDescription, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
    return AudioObjectSetPropertyData(tap, &property, 0, NULL, sizeof(description), &description);
}
OSStatus am_set_taps(AudioObjectID aggregate, CFArrayRef tapUIDs) {
    AudioObjectPropertyAddress property = {kAudioAggregateDevicePropertyTapList, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
    return AudioObjectSetPropertyData(aggregate, &property, 0, NULL, sizeof(tapUIDs), &tapUIDs);
}
int am_process_path(pid_t pid, char *path, unsigned capacity) {
    errno = 0; int size = proc_pidpath(pid, path, capacity); return size > 0 ? size : -(errno ? errno : EIO);
}
int am_process_identity(pid_t pid, AMProcessIdentity *identity) {
    if (pid <= 0) return EINVAL;
    struct proc_bsdinfo info = {0}; errno = 0;
    if (proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, sizeof(info)) != sizeof(info)) return errno ? errno : EIO;
    if (info.pbi_pid != (uint32_t)pid) return ESRCH;
    *identity = (AMProcessIdentity){pid, info.pbi_uid, info.pbi_start_tvsec, info.pbi_start_tvusec}; return 0;
}
int am_responsible_pid(pid_t pid, pid_t *responsible) {
    if (pid <= 0) return EINVAL;
    typedef pid_t (*Lookup)(pid_t);
    Lookup lookup = (Lookup)dlsym(RTLD_DEFAULT, "responsibility_get_pid_responsible_for_pid");
    if (!lookup) return ENOSYS;
    pid_t value = lookup(pid); if (value <= 0) return ESRCH; *responsible = value; return 0;
}
struct AMDrain { atomic_uint_fast64_t frames; atomic_uint faults; };
AMDrain *am_drain_create(void) {
    AMDrain *d = calloc(1, sizeof(*d));
    if (d) { atomic_init(&d->frames, 0); atomic_init(&d->faults, 0); }
    return d;
}
void am_drain_destroy(AMDrain *d) { free(d); }
OSStatus am_drain_callback(AudioObjectID device, const AudioTimeStamp *now, const AudioBufferList *input,
    const AudioTimeStamp *inputTime, AudioBufferList *output, const AudioTimeStamp *outputTime, void *context) {
    silence(output);
    if (!context) return kAudioHardwareIllegalOperationError;
    AMDrain *d = context;
    bool valid = !output || output->mNumberBuffers == 0;
    unsigned frames = 0;
    if (input && input->mNumberBuffers) {
        valid = valid && (input->mNumberBuffers == 1 || input->mNumberBuffers == 2);
        if (valid) for (unsigned b = 0; b < input->mNumberBuffers; b++) {
            const AudioBuffer *buffer = &input->mBuffers[b];
            unsigned channels = input->mNumberBuffers == 1 ? 2 : 1, bytes = sizeof(float) * channels;
            unsigned count = buffer->mDataByteSize / bytes;
            if (buffer->mNumberChannels != channels || buffer->mDataByteSize % bytes || (b && count != frames)) valid = false;
            frames = count;
        }
    }
    if (valid) atomic_fetch_add_explicit(&d->frames, frames, memory_order_relaxed);
    else atomic_fetch_add_explicit(&d->faults, 1, memory_order_relaxed);
    return noErr;
}
AMCounters am_drain_counters(const AMDrain *d) { return (AMCounters){atomic_load(&d->frames), atomic_load(&d->faults), 0}; }
