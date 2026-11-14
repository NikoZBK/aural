#pragma once
#include <CoreAudio/CoreAudio.h>
#include <stdbool.h>
#include <stdint.h>
#pragma clang assume_nonnull begin
typedef struct EQ EQ;
typedef struct AMMixer AMMixer;
enum { AMMaxApps = 8, AMMaxSources = 9, AMMaxFrames = 8192 };
// Borrows the EQ engine. The route removes its callback before destroying either.
AMMixer * _Nullable am_create(double rate, EQ *eq, const uint32_t *offsets, unsigned count, const float *gains);
void am_destroy(AMMixer *mixer);
bool am_set_gain(AMMixer *mixer, unsigned slot, float gain);
// Control queue only, while this tap's process list is empty. Prevents a new
// owner's first sample from ramping from the preceding owner's gain.
bool am_reset_gain(AMMixer *mixer, unsigned slot, float gain);
void am_process(AMMixer *mixer, const AudioBufferList *input, AudioBufferList *output);
OSStatus am_callback(AudioObjectID device, const AudioTimeStamp *now, const AudioBufferList *input,
    const AudioTimeStamp *inputTime, AudioBufferList *output, const AudioTimeStamp *outputTime, void * _Nullable context);
typedef struct { uint64_t frames; unsigned faults, signalFaults; } AMCounters;
AMCounters am_counters(const AMMixer *mixer);
float am_read_peak(AMMixer *mixer, unsigned slot);
// Control-thread HAL helpers. None are called from the audio callback.
OSStatus am_enable_inputs(AudioObjectID device, AudioDeviceIOProcID callback, const uint32_t *enabled, unsigned count);
OSStatus am_stream_channels(AudioObjectID device, uint32_t *channels, unsigned capacity, unsigned *count);
OSStatus am_update_tap(AudioObjectID tap, const void *description);
OSStatus am_set_taps(AudioObjectID aggregate, CFArrayRef tapUIDs);
int am_process_path(pid_t pid, char *path, unsigned capacity);
typedef struct { int32_t pid; uint32_t uid; uint64_t seconds, microseconds; } AMProcessIdentity;
int am_process_identity(pid_t pid, AMProcessIdentity *identity);
// Explicitly experimental Safari/WebKit attribution, with runtime availability.
int am_responsible_pid(pid_t pid, pid_t *responsible);
typedef struct AMDrain AMDrain;
AMDrain * _Nullable am_drain_create(void);
void am_drain_destroy(AMDrain *drain);
OSStatus am_drain_callback(AudioObjectID device, const AudioTimeStamp *now, const AudioBufferList *input,
    const AudioTimeStamp *inputTime, AudioBufferList *output, const AudioTimeStamp *outputTime, void * _Nullable context);
AMCounters am_drain_counters(const AMDrain *drain);
#pragma clang assume_nonnull end
