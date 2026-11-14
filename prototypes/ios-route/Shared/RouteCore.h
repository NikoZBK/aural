#pragma once
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#pragma clang assume_nonnull begin

enum { ARSampleRate = 48000, ARChannels = 2, ARPacketFrames = 2048,
       ARHeaderBytes = 24, ARPacketBytes = ARHeaderBytes + ARPacketFrames * 2 * sizeof(float),
       ARBufferFrames = 16384, ARPrerollFrames = 2048, ARPort = 47103 };

// One producer and one consumer. Only the consumer may discard frames.
// Full queues reject new frames; they never overwrite samples being read.
typedef struct ARRing ARRing;
ARRing * _Nullable ar_ring_create(uint32_t capacity);
void ar_ring_destroy(ARRing *ring);
uint32_t ar_ring_write(ARRing *ring, const float *stereo, uint32_t frames);
uint32_t ar_ring_read(ARRing *ring, float *stereo, uint32_t frames);
uint32_t ar_ring_count(const ARRing *ring);
void ar_ring_discard(ARRing *ring);

// Explicit little-endian header; payload is IEEE float32, little-endian.
// The prototype runs only on little-endian Apple platforms.
size_t ar_packet_encode(uint8_t *packet, const float *stereo, uint32_t frames);
typedef struct {
    uint8_t bytes[ARPacketBytes];
    size_t used, needed;
    bool failed;
} ARDecoder;
typedef void (*ARPacketHandler)(void *context, const float *stereo, uint32_t frames);
void ar_decoder_reset(ARDecoder *decoder);
// An invalid header fails the connection; no scanning ahead for another magic.
bool ar_decoder_feed(ARDecoder *decoder, const void *bytes, size_t count,
                     ARPacketHandler handler, void *context);

#pragma clang assume_nonnull end
