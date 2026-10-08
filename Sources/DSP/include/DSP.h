#pragma once
#include <CoreAudio/CoreAudio.h>
#include <stdbool.h>
#pragma clang assume_nonnull begin
typedef struct EQ EQ;
enum { EQBands = 10, EQMaxFilters = 32 };
enum { EQFilterPeak, EQFilterLowShelf, EQFilterHighShelf, EQFilterLowPass,
       EQFilterHighPass, EQFilterBandPass, EQFilterNotch, EQFilterAllPass };
// disabled defaults to false for existing C initializers. Gain applies only to EQ/shelves.
enum { EQChannelStereo, EQChannelLeft, EQChannelRight };
typedef struct { double frequency, gain, q; unsigned type; bool disabled; unsigned channel; } EQFilter;
// width=1 is neutral; use eq_stereo_default() instead of a zero initializer.
// Balance attenuates the opposite side, crossfeed is a normalized 700 Hz blend,
// and mono sums before per-channel correction. Delays use linear interpolation.
typedef struct {
    double leftTrimDB, rightTrimDB, balance, width, crossfeed, leftDelayMS, rightDelayMS;
    bool invertLeft, invertRight, mono;
} EQStereo;
EQStereo eq_stereo_default(void);
bool eq_update_filters_stereo(EQ *eq, const EQFilter *filters, unsigned count, double preamp, bool bypass, const EQStereo *stereo);
// Level-matched Bypass: the dry signal plays at bypassGainDB (-24...+12 dB).
// 0 dB is the unmatched Bypass used by eq_update_filters_stereo.
bool eq_update_filters_matched(EQ *eq, const EQFilter *filters, unsigned count, double preamp, bool bypass,
    const EQStereo *stereo, double bypassGainDB);
bool eq_update_filters(EQ *eq, const EQFilter *filters, unsigned count, double preamp, bool bypass);
double eq_response_filters(double frequency, double rate, const EQFilter *filters, unsigned count, double preamp);
// Stereo returns the larger L/R response for conservative automatic headroom.
double eq_response_filters_channel(double frequency, double rate, const EQFilter *filters, unsigned count, double preamp, unsigned channel);
// Control/UI thread only: prepare coefficients once for an entire frequency grid.
// Returns false for an invalid rate, channel, preamp, or excessive filter count.
bool eq_response_filters_channel_samples(const double *frequencies, unsigned frequencyCount, double rate,
    const EQFilter *filters, unsigned count, double preamp, unsigned channel, double *decibels);
extern const double EQFrequencies[EQBands];
EQ * _Nullable eq_create(double sampleRate, unsigned inputOffset);
void eq_destroy(EQ *eq);
// Enabled by default. A control-thread change takes effect at the next buffer,
// independently of filter updates and Bypass. Off stops limiting new peaks, and
// attenuation already applied releases smoothly (80 ms time constant) to none.
void eq_set_peak_protection(EQ *eq, bool enabled);
// Single control-thread producer; the audio callback is the sole consumer.
bool eq_update(EQ *eq, const double *gains, double preamp, bool bypass);
void eq_process(EQ *eq, const AudioBufferList *input, AudioBufferList *output);
OSStatus eq_callback(AudioObjectID device, const AudioTimeStamp * _Nonnull now,
    const AudioBufferList * _Nonnull input, const AudioTimeStamp * _Nonnull inputTime,
    AudioBufferList * _Nonnull output, const AudioTimeStamp * _Nonnull outputTime, void * _Nullable context);
OSStatus eq_enable_tap_input(AudioObjectID device, AudioDeviceIOProcID _Nonnull proc, unsigned streamCount);
float eq_peak(EQ *eq);
typedef struct { float peak, reductionDB; } EQMeter;
// Single control-thread reader: maxima since the previous read, then reset.
// Output level and gain reduction are independent interval measurements.
EQMeter eq_read_meter(EQ *eq);
// Malformed buffers that no audio can pass through: the route is broken.
unsigned eq_faults(EQ *eq);
// Samples the callback contained without stopping: non-finite input replaced
// by silence, and non-finite or overflowing output that reset filter history.
// One playing app can cause these; they say nothing about the route.
unsigned eq_signal_faults(EQ *eq);
double eq_response(double frequency, double sampleRate, const double *gains, double preamp);

#pragma clang assume_nonnull end
