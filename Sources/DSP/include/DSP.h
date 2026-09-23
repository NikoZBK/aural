#pragma once
#include <CoreAudio/CoreAudio.h>
#include <stdbool.h>
#pragma clang assume_nonnull begin
typedef struct EQ EQ;
enum { EQBands = 10, EQMaxFilters = 32 };
typedef struct { double frequency, gain, q; unsigned type; } EQFilter;
// type: 0 = peaking, 1 = low shelf, 2 = high shelf (Q-based RBJ filters).
bool eq_update_filters(EQ *eq, const EQFilter *filters, unsigned count, double preamp, bool bypass);
double eq_response_filters(double frequency, double rate, const EQFilter *filters, unsigned count, double preamp);
extern const double EQFrequencies[EQBands];
EQ * _Nullable eq_create(double sampleRate, unsigned inputOffset);
void eq_destroy(EQ *eq);
// Single control-thread producer; the audio callback is the sole consumer.
bool eq_update(EQ *eq, const double *gains, double preamp, bool bypass);
void eq_process(EQ *eq, const AudioBufferList *input, AudioBufferList *output);
OSStatus eq_callback(AudioObjectID device, const AudioTimeStamp * _Nonnull now,
    const AudioBufferList * _Nonnull input, const AudioTimeStamp * _Nonnull inputTime,
    AudioBufferList * _Nonnull output, const AudioTimeStamp * _Nonnull outputTime, void * _Nullable context);
OSStatus eq_enable_tap_input(AudioObjectID device, AudioDeviceIOProcID _Nonnull proc, unsigned streamCount);
float eq_peak(EQ *eq);
unsigned eq_faults(EQ *eq);
double eq_response(double frequency, double sampleRate, const double *gains, double preamp);

#pragma clang assume_nonnull end
