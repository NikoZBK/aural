#include "Mixer.h"
#include "DSP.h"
#include <assert.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>

typedef struct { UInt32 count; AudioBuffer buffers[AMMaxSources]; } Inputs;
static double seconds(void) {
    struct timespec now; clock_gettime(CLOCK_MONOTONIC, &now);
    return now.tv_sec + now.tv_nsec * 1e-9;
}
static int compare(const void *a, const void *b) {
    double x = *(const double *)a, y = *(const double *)b;
    return (x > y) - (x < y);
}
int main(void) {
    enum { Samples = 2000, MaxFrames = 512 };
    const unsigned counts[] = {10, 31, 64}, blocks[] = {128, 512};
    const double rates[] = {48000, 192000};
    float data[AMMaxSources][MaxFrames * 2], output[MaxFrames * 2];
    uint32_t offsets[AMMaxSources]; float gains[AMMaxSources];
    for (unsigned s = 0; s < AMMaxSources; s++) {
        offsets[s] = 2 * s; gains[s] = .5;
        for (unsigned f = 0; f < MaxFrames * 2; f++) data[s][f] = .005f * sinf(f * .2f + s);
    }
    for (unsigned r = 0; r < 2; r++) for (unsigned b = 0; b < 2; b++) for (unsigned c = 0; c < 3; c++) {
        unsigned frames = blocks[b], filters = counts[c];
        Inputs input = {.count = AMMaxSources};
        for (unsigned s = 0; s < AMMaxSources; s++) input.buffers[s] = (AudioBuffer){2, frames * 2 * sizeof(float), data[s]};
        AudioBufferList destination = {.mNumberBuffers = 1, .mBuffers = {{2, frames * 2 * sizeof(float), output}}};
        EQ *eq = eq_create(rates[r], 0); assert(eq);
        EQFilter settings[64];
        for (unsigned i = 0; i < filters; i++) settings[i] = (EQFilter){30 * pow(500, (double)i / (filters - 1)), i % 2 ? -2 : 2, 1.4, EQFilterPeak, false, EQChannelStereo};
        assert(eq_update_filters(eq, settings, filters, -6, false));
        AMMixer *mixer = am_create(rates[r], eq, offsets, AMMaxSources, gains); assert(mixer);
        for (unsigned i = 0; i < 100; i++) am_process(mixer, (AudioBufferList *)&input, &destination);
        double elapsed[Samples];
        for (unsigned i = 0; i < Samples; i++) {
            assert(am_set_gain(mixer, i % AMMaxSources, i % 2 ? .25 : .75));
            double start = seconds(); am_process(mixer, (AudioBufferList *)&input, &destination);
            elapsed[i] = (seconds() - start) * 1e6;
        }
        assert(am_counters(mixer).faults == 0 && eq_faults(eq) == 0);
        qsort(elapsed, Samples, sizeof(double), compare);
        printf("MIXER 9 inputs %u filters %.0fHz %u frames median=%.2fus p95=%.2fus max=%.2fus deadline=%.2fus\n",
               filters, rates[r], frames, elapsed[Samples / 2], elapsed[Samples * 95 / 100], elapsed[Samples - 1], frames * 1e6 / rates[r]);
        am_destroy(mixer); eq_destroy(eq);
    }
}
