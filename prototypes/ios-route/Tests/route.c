#include "RouteCore.h"
#include "LocalTransport.h"
#include "ProbeRenderer.h"
#include "RouteRegistration.h"
#include <arpa/inet.h>
#include <assert.h>
#include <errno.h>
#include <math.h>
#include <pthread.h>
#include <sched.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

static void registration_tests(void) {
    ARRegistration registration = {0};
    assert(atomic_is_lock_free(&registration.value));
    assert(!ar_registration_ready(&registration));
    uint64_t first = ar_registration_begin(&registration);
    assert(!ar_registration_ready(&registration));
    assert(ar_registration_finish(&registration, first, true));
    assert(ar_registration_ready(&registration));

    uint64_t second = ar_registration_begin(&registration);
    assert(second != first && !ar_registration_ready(&registration));
    assert(!ar_registration_interrupt(&registration, first));
    assert(!ar_registration_finish(&registration, first, true));
    assert(ar_registration_finish(&registration, second, true));
    assert(!ar_registration_interrupt(&registration, first));
    assert(ar_registration_ready(&registration));
    assert(ar_registration_interrupt(&registration, second));
    assert(!ar_registration_ready(&registration));
    assert(!ar_registration_finish(&registration, second, true));

    uint64_t third = ar_registration_begin(&registration);
    assert(ar_registration_interrupt(&registration, third));
    assert(!ar_registration_finish(&registration, third, true));
    assert(!ar_registration_ready(&registration));
    uint64_t fourth = ar_registration_begin(&registration);
    assert(!ar_registration_finish(&registration, fourth, false));
    assert(!ar_registration_ready(&registration));
    uint64_t fifth = ar_registration_begin(&registration);
    assert(!ar_registration_interrupt(&registration, fourth));
    assert(ar_registration_finish(&registration, fifth, true));
    assert(ar_registration_ready(&registration));
    puts("PASS repeated route publication, stale callbacks, interruption during publication and API failure");
}

static void ring_tests(void) {
    ARRing *ring = ar_ring_create(4); assert(ring);
    float input[] = {1,-1,2,-2,3,-3,4,-4,5,-5}, out[10] = {0};
    assert(ar_ring_write(ring, input, 5) == 4); // Reject overflow; preserve unread data.
    assert(ar_ring_read(ring, out, 3) == 3 && memcmp(input, out, 6 * sizeof(float)) == 0);
    assert(ar_ring_write(ring, input, 3) == 3);
    assert(ar_ring_read(ring, out, 4) == 4 && out[0] == 4 && out[2] == 1 && out[6] == 3);
    assert(ar_ring_count(ring) == 0);
    assert(ar_ring_write(ring, input, 4) == 4);
    ar_ring_discard(ring); assert(ar_ring_read(ring, out, 4) == 0);
    ar_ring_destroy(ring);
    puts("PASS bounded stereo ring, wraparound, overflow and consumer discard");
}
static void *produce(void *context) {
    ARRing *ring = context;
    for (unsigned i = 1; i <= 200000; i++) {
        float frame[2] = {(float)i, -(float)i};
        while (ar_ring_write(ring, frame, 1) == 0) sched_yield();
    }
    return NULL;
}
static void concurrency_test(void) {
    ARRing *ring = ar_ring_create(257); assert(ring);
    pthread_t thread; assert(pthread_create(&thread, NULL, produce, ring) == 0);
    for (unsigned i = 1; i <= 200000; i++) {
        float frame[2];
        while (ar_ring_read(ring, frame, 1) == 0) sched_yield();
        assert(frame[0] == (float)i && frame[1] == -(float)i);
    }
    assert(pthread_join(thread, NULL) == 0); ar_ring_destroy(ring);
    puts("PASS concurrent producer/consumer, 200000 stereo frames");
}
typedef struct { unsigned packets; uint32_t frames; float first, last; } Decoded;
static void decoded(void *context, const float *samples, uint32_t frames) {
    Decoded *d = context; d->packets++; d->frames += frames;
    d->first = samples[0]; d->last = samples[frames * 2 - 1];
}
static void packet_tests(void) {
    uint8_t packet[ARPacketBytes], both[ARPacketBytes * 2];
    float samples[ARPacketFrames * 2];
    for (unsigned i = 0; i < ARPacketFrames * 2; i++) samples[i] = (float)i / 10000;
    size_t size = ar_packet_encode(packet, samples, ARPacketFrames); assert(size == ARPacketBytes);
    for (size_t split = 0; split <= size; split++) {
        ARDecoder decoder; ar_decoder_reset(&decoder); Decoded result = {0};
        assert(ar_decoder_feed(&decoder, packet, split, decoded, &result));
        assert(ar_decoder_feed(&decoder, packet + split, size - split, decoded, &result));
        assert(result.packets == 1 && result.frames == ARPacketFrames && result.first == samples[0] && result.last == samples[ARPacketFrames*2-1]);
    }
    memcpy(both, packet, size); memcpy(both + size, packet, size);
    ARDecoder decoder; ar_decoder_reset(&decoder); Decoded result = {0};
    for (size_t i = 0; i < size * 2; i++) assert(ar_decoder_feed(&decoder, both + i, 1, decoded, &result));
    assert(result.packets == 2);
    const unsigned corrupt[] = {0,8,12,16,20,23};
    for (unsigned i = 0; i < sizeof(corrupt)/sizeof(corrupt[0]); i++) {
        uint8_t bad[ARPacketBytes]; memcpy(bad, packet, size); bad[corrupt[i]] ^= 0xFF;
        ar_decoder_reset(&decoder); result = (Decoded){0};
        assert(!ar_decoder_feed(&decoder, bad, size, decoded, &result));
        assert(result.packets == 0);
        assert(!ar_decoder_feed(&decoder, packet, size, decoded, &result)); // Fail closed until reset.
    }
    assert(ar_packet_encode(packet, samples, 0) == 0);
    assert(ar_packet_encode(packet, samples, ARPacketFrames + 1) == 0);
    puts("PASS every TCP split boundary, bytewise/coalesced packets and malformed headers");
}
static void wait_connected(ARLink *a, ARLink *b) {
    for (unsigned i = 0; i < 1000; i++) {
        if (ar_link_stats(a).connected && ar_link_stats(b).connected) return;
        usleep(5000);
    }
    fprintf(stderr, "Connection timed out: receiver errno=%d sender errno=%d\n", ar_link_stats(a).error, ar_link_stats(b).error);
    abort();
}
static void wait_frames(ARLink *link, uint64_t frames) {
    for (unsigned i = 0; i < 1000; i++) {
        if (ar_link_stats(link).transferredFrames >= frames) return;
        usleep(5000);
    }
    fprintf(stderr, "Audio transport timed out\n"); abort();
}
static void render_tones(ARLink *sender, ARLink *receiver, ARRenderer *renderer, bool bypass) {
    enum { Frames = 8192 };
    float input[Frames * 2];
    for (unsigned i = 0; i < Frames; i++) {
        input[i*2] = .1 * sin(2*M_PI*6000*i/ARSampleRate);
        input[i*2+1] = .05 * sin(2*M_PI*200*i/ARSampleRate);
    }
    assert(ar_renderer_update(renderer, 1000, bypass));
    uint64_t target = ar_link_stats(receiver).transferredFrames + Frames;
    ar_link_push(sender, input, Frames); wait_frames(receiver, target);
    double power[2] = {0};
    for (unsigned block = 0; block < 32; block++) {
        float left[256], right[256];
        struct { UInt32 count; AudioBuffer buffers[2]; } output = {2, {{1,sizeof(left),left},{1,sizeof(right),right}}};
        assert(ar_renderer_render(renderer, 256, (AudioBufferList *)&output) == 0);
        if (block >= 16) for (unsigned i = 0; i < 256; i++) {
            assert(isfinite(left[i]) && isfinite(right[i]));
            power[0] += left[i]*left[i]; power[1] += right[i]*right[i];
        }
    }
    double leftGain = 10*log10(power[0]/4096/(.1*.1/2));
    double rightGain = 10*log10(power[1]/4096/(.05*.05/2));
    if (bypass) assert(fabs(leftGain) < .1 && fabs(rightGain) < .15);
    else assert(leftGain < -25 && fabs(rightGain) < .15);
    ARRenderStats stats = ar_renderer_stats(renderer);
    assert(stats.dspFaults == 0 && stats.signalFaults == 0 && stats.formatErrors == 0);
    printf("PASS real TCP → Aural DSP → stereo renderer (%s, L %.2f dB / R %.2f dB)\n", bypass ? "bypass" : "1 kHz low-pass", leftGain, rightGain);
}
static void render_profile_tones(ARLink *sender, ARLink *receiver, ARRenderer *renderer, bool bypass) {
    // Exercise the production profile API through real transport and rendered PCM.
    EQFilter filters[] = {{6000, -12, 1.4, EQFilterPeak, false, EQChannelLeft},
                          {200, 3, 1.4, EQFilterPeak, false, EQChannelRight}};
    EQStereo stereo = eq_stereo_default(); stereo.leftTrimDB = -2; stereo.rightTrimDB = -4;
    assert(ar_renderer_configure(renderer, filters, 2, -3, bypass, &stereo, -9, true));
    // Rejected changes must retain the complete last valid configuration.
    assert(!ar_renderer_configure(renderer, filters, 2, NAN, bypass, &stereo, -9, false));
    assert(!ar_renderer_configure(renderer, filters, 2, -3, bypass, &stereo, 13, false));
    enum { Frames = 8192 };
    float input[Frames * 2];
    for (unsigned i = 0; i < Frames; i++) {
        input[i * 2] = .1 * sin(2 * M_PI * 6000 * i / ARSampleRate);
        input[i * 2 + 1] = .05 * sin(2 * M_PI * 200 * i / ARSampleRate);
    }
    uint64_t target = ar_link_stats(receiver).transferredFrames + Frames;
    ar_link_push(sender, input, Frames); wait_frames(receiver, target);
    double power[2] = {0};
    for (unsigned block = 0; block < 32; block++) {
        float left[256], right[256];
        struct { UInt32 count; AudioBuffer buffers[2]; } output = {2, {{1,sizeof(left),left},{1,sizeof(right),right}}};
        assert(ar_renderer_render(renderer, 256, (AudioBufferList *)&output) == 0);
        if (block >= 16) for (unsigned i = 0; i < 256; i++) { power[0] += left[i]*left[i]; power[1] += right[i]*right[i]; }
    }
    double leftGain = 10 * log10(power[0] / 4096 / (.1 * .1 / 2));
    double rightGain = 10 * log10(power[1] / 4096 / (.05 * .05 / 2));
    assert(fabs(leftGain - (bypass ? -9 : -17)) < .2);
    assert(fabs(rightGain - (bypass ? -9 : -4)) < .2);
    ARRenderStats stats = ar_renderer_stats(renderer);
    assert(stats.dspFaults == 0 && stats.signalFaults == 0 && stats.formatErrors == 0);
    printf("PASS full profile → TCP → DSP PCM (%s, L %.2f / R %.2f dB), rejected updates preserve audio\n", bypass ? "level-matched bypass" : "channel filters, trims and preamp", leftGain, rightGain);
}
static void socket_tests(void) {
    ARLink *receiver = ar_link_create(false), *sender = ar_link_create(true); assert(receiver && sender);
    int startError = ar_link_start(receiver);
    if (startError) { fprintf(stderr, "Loopback listen failed: %s (%d)\n", strerror(startError), startError); abort(); }
    assert(ar_link_start(sender) == 0);
    wait_connected(receiver, sender);
    float scratch[2]; ar_link_read(receiver, scratch, 1); // Consume the connection generation before audio arrives.
    ARRenderer *renderer = ar_renderer_create(receiver); assert(renderer);
    ar_renderer_enable(renderer, true);
    render_tones(sender, receiver, renderer, false);
    render_tones(sender, receiver, renderer, true);
    render_profile_tones(sender, receiver, renderer, false);
    render_profile_tones(sender, receiver, renderer, true);
    assert(!ar_renderer_update(renderer, NAN, false));
    assert(!ar_renderer_update(renderer, 99, false));
    assert(!ar_renderer_update(renderer, 18001, false));
    float left[256], right[256];
    struct { UInt32 count; AudioBuffer buffers[2]; } output = {2, {{1,sizeof(left),left},{1,sizeof(right),right}}};
    assert(ar_renderer_render(renderer, 256, (AudioBufferList *)&output) == 0);
    assert(ar_link_stats(receiver).underrunFrames > 0);
    ar_renderer_enable(renderer, false);
    assert(ar_renderer_render(renderer, 256, (AudioBufferList *)&output) == 0);
    for (unsigned i = 0; i < 256; i++) assert(left[i] == 0 && right[i] == 0);
    ar_renderer_destroy(renderer);
    ar_link_stop(sender);
    for (unsigned i = 0; i < 1000 && ar_link_stats(receiver).connected; i++) usleep(5000);
    assert(!ar_link_stats(receiver).connected);
    // A complete but invalid protocol header must disconnect the peer.
    int fd = socket(AF_INET, SOCK_STREAM, 0); assert(fd >= 0);
    struct sockaddr_in address = {.sin_len=sizeof(address), .sin_family=AF_INET, .sin_port=htons(ARPort)};
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    assert(connect(fd, (struct sockaddr *)&address, sizeof(address)) == 0);
    uint8_t invalid[ARHeaderBytes] = {0}; assert(send(fd, invalid, sizeof(invalid), 0) == sizeof(invalid));
    for (unsigned i = 0; i < 1000 && ar_link_stats(receiver).protocolErrors == 0; i++) usleep(5000);
    assert(ar_link_stats(receiver).protocolErrors == 1); close(fd);
    ar_link_stop(receiver);
    assert(ar_link_start(receiver) == 0); assert(ar_link_start(sender) == 0);
    wait_connected(receiver, sender);
    ar_link_destroy(sender); ar_link_destroy(receiver);
    puts("PASS underrun accounting, disabled silence, malformed-peer rejection and transport restart");
}
static void transport_sink_test(bool configured) {
    const char *ipv4 = getenv("AURAL_TEST_IPV4");
    if (!ipv4) ipv4 = "127.0.0.1";
    ARLink *sink = configured ? ar_link_create_transport_sink_at_ipv4(ipv4) : ar_link_create_transport_sink();
    ARLink *sender = configured ? ar_link_create_sender_to_ipv4(ipv4) : ar_link_create(true);
    assert(sink && sender);
    int started = ar_link_start(sink);
    if (started) fprintf(stderr, "Cannot bind test sink on %s: %s\n", configured ? ipv4 : "127.0.0.1", strerror(started));
    assert(started == 0);
    float input[8192 * ARChannels];
    for (unsigned i = 0; i < sizeof(input)/sizeof(input[0]); i++) input[i] = .1f;
    uint64_t target = 0;
    for (unsigned connection = 1; connection <= 2; connection++) {
        assert(ar_link_start(sender) == 0); wait_connected(sink, sender);
        // More than the queue capacity without any renderer or consumer.
        for (unsigned batch = 0; batch < 5; batch++) {
            target += 8192;
            ar_link_push(sender, input, 8192); wait_frames(sink, target);
        }
        ARLinkStats stats = ar_link_stats(sink);
        assert(stats.transferredFrames == target && stats.connections == connection);
        assert(stats.bufferedFrames == 0 && stats.droppedFrames == 0 && stats.underrunFrames == 0);
        assert(stats.error == 0 && stats.protocolErrors == 0);
        ar_link_stop(sender);
        for (unsigned i = 0; i < 1000 && ar_link_stats(sink).connected; i++) usleep(5000);
        assert(!ar_link_stats(sink).connected);
    }
    ar_link_destroy(sender); ar_link_destroy(sink);
    printf("PASS %s sink counts/discards beyond queue capacity and reconnects without a renderer\n",
           configured ? "explicit endpoint" : "default transport-only");
    if (configured) printf("Verified endpoint: %s:%d\n", ipv4, ARPort);
}
static void endpoint_tests(void) {
    const char *invalid[] = {"", "localhost", "192.168.18.11:47103", "256.0.0.1", "0.0.0.0",
                            "8.8.8.8", "224.0.0.1", "192.168.18.255", "10.0.0.0", "172.32.0.1"};
    for (unsigned i = 0; i < sizeof(invalid)/sizeof(invalid[0]); i++) {
        errno = 0; assert(ar_link_create_sender_to_ipv4(invalid[i]) == NULL && errno == EINVAL);
        errno = 0; assert(ar_link_create_transport_sink_at_ipv4(invalid[i]) == NULL && errno == EINVAL);
    }
    const char *valid[] = {"127.0.0.1", "192.168.18.11", "10.1.2.3", "172.16.0.1", "172.31.255.254"};
    for (unsigned i = 0; i < sizeof(valid)/sizeof(valid[0]); i++) {
        ARLink *sender = ar_link_create_sender_to_ipv4(valid[i]); assert(sender); ar_link_destroy(sender);
    }
    puts("PASS numeric local endpoint validation; invalid configuration fails explicitly");
}
int main(int argc, char **argv) {
    registration_tests(); ring_tests(); concurrency_test(); packet_tests(); endpoint_tests();
    if (argc == 2 && strcmp(argv[1], "--sockets") == 0) {
        socket_tests(); transport_sink_test(false); transport_sink_test(true);
    }
    else puts("Socket integration omitted; pass --sockets to exercise loopback transport.");
    return 0;
}
