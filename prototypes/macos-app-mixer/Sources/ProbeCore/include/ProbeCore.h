#pragma once
#include <CoreAudio/CoreAudio.h>
#include <stdbool.h>
#include <stdint.h>
#pragma clang assume_nonnull begin

enum { ProbeMaxSources = 8, ProbeMaxPhases = 12, ProbeCaptureFrames = 32768, ProbeMaxCallbackFrames = 8192 };
typedef struct ProbeEngine ProbeEngine;
typedef struct ProbeTone ProbeTone;
typedef struct ProbeDrain ProbeDrain;
typedef struct {
    uint64_t callbacks, frames, invalidBuffers, nonfiniteSamples, silentSourceFrames;
    uint64_t maximumCallbackNanoseconds;
} ProbeCounters;

// Input-only guard reader: discard the selected tap without retaining PCM or
// rendering audio. Its lifetime is independent of the playback aggregate.
ProbeDrain * _Nullable probe_drain_create(void);
void probe_drain_destroy(ProbeDrain *drain);
void probe_drain_process(ProbeDrain *drain, const AudioBufferList * _Nullable input, AudioBufferList * _Nullable output);
OSStatus probe_drain_callback(AudioObjectID device, const AudioTimeStamp *now, const AudioBufferList *input,
    const AudioTimeStamp *inputTime, AudioBufferList *output, const AudioTimeStamp *outputTime, void * _Nullable context);
ProbeCounters probe_drain_counters(const ProbeDrain *drain);

// All allocation and analysis occurs outside the callback. Captures stay in RAM;
// callers export statistics, never recorded audio.
ProbeEngine * _Nullable probe_create(double rate, const uint32_t *channelOffsets, unsigned sourceCount, uint32_t playbackMask);
void probe_destroy(ProbeEngine *engine);
// Control thread only, before starting IO: restore gains without an initial ramp from unity.
bool probe_capture_on_signal(ProbeEngine *engine, unsigned source);
bool probe_prime_gain(ProbeEngine *engine, unsigned source, float gain);
bool probe_set_gain(ProbeEngine *engine, unsigned source, float gain);
bool probe_set_phase(ProbeEngine *engine, unsigned phase);
bool probe_set_phase_immediate(ProbeEngine *engine, unsigned phase);
void probe_process(ProbeEngine *engine, const AudioBufferList * _Nullable input, AudioBufferList * _Nullable output);
OSStatus probe_callback(AudioObjectID device, const AudioTimeStamp *now, const AudioBufferList *input,
    const AudioTimeStamp *inputTime, AudioBufferList *output, const AudioTimeStamp *outputTime, void * _Nullable context);
ProbeCounters probe_counters(const ProbeEngine *engine);
typedef struct { uint32_t channels, bytes, dataPresent; } ProbeBufferInfo;
// Last callback layout; inspect only after removing the callback.
unsigned probe_buffer_count(const ProbeEngine *engine, bool input);
ProbeBufferInfo probe_buffer_info(const ProbeEngine *engine, bool input, unsigned index);
OSStatus probe_enable_inputs(AudioObjectID device, AudioDeviceIOProcID callback, const uint32_t *enabled, unsigned count);
OSStatus probe_device_for_uid(CFStringRef uid, AudioObjectID *device);
int probe_process_path(pid_t pid, char *path, unsigned capacity);
typedef struct { int32_t pid; uint32_t uid; uint64_t startSeconds, startMicroseconds; } ProbeProcessIdentity;
// Control-thread process metadata. Return errno values; never called by IO.
int probe_process_identity(pid_t pid, ProbeProcessIdentity *identity);
// Undocumented OS query for explicitly opted-in prototype experiments only.
int probe_experimental_responsible_pid(pid_t pid, pid_t *responsible);
OSStatus probe_stream_channels(AudioObjectID device, bool input, uint32_t *channels, unsigned capacity, unsigned *count);
OSStatus probe_update_tap(AudioObjectID tap, const void *description);
OSStatus probe_set_taps(AudioObjectID aggregate, CFArrayRef tapUIDs);
// Analysis requires callback removal, or a true capture_ready result for that
// immutable phase. capture_ready itself is safe while IO runs.
bool probe_capture_ready(const ProbeEngine *engine, unsigned phase);
unsigned probe_capture_count(const ProbeEngine *engine, unsigned phase);
double probe_rms(const ProbeEngine *engine, unsigned phase, unsigned source, unsigned channel);
double probe_tone_amplitude(const ProbeEngine *engine, unsigned phase, unsigned source, unsigned channel, double frequency);
typedef struct { uint32_t comparedFrames, mismatchedFrames; double maximumDifference; } ProbeComparison;
ProbeComparison probe_compare(const ProbeEngine *engine, unsigned phase, uint32_t sourceMask, unsigned reference, double tolerance);
typedef struct {
    bool valid;
    uint32_t frames;
    double inputRMS, outputRMS, errorRMS, observedGain;
} ProbeRenderCheck;
// Compare rendered audio with a weighted sum of the very same input samples.
// This works for changing music; comparing RMS across different passages does not.
ProbeRenderCheck probe_render_check(const ProbeEngine *engine, unsigned phase, const float *gains, unsigned count, unsigned measuredSource);
double probe_unity_error(const ProbeEngine *engine, unsigned phase, uint32_t sourceMask, unsigned reference, int lag);

ProbeTone * _Nullable probe_tone_create(double rate, double frequency, double amplitude);
void probe_tone_destroy(ProbeTone *tone);
OSStatus probe_tone_callback(AudioObjectID device, const AudioTimeStamp *now, const AudioBufferList *input,
    const AudioTimeStamp *inputTime, AudioBufferList *output, const AudioTimeStamp *outputTime, void * _Nullable context);
#pragma clang assume_nonnull end
