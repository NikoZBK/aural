#include "RouteCore.h"
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

_Static_assert(ATOMIC_LLONG_LOCK_FREE == 2, "Audio queues require lock-free counters");
_Static_assert(__BYTE_ORDER__ == __ORDER_LITTLE_ENDIAN__, "Wire format requires little endian");
_Static_assert(sizeof(float) == 4, "Wire format requires float32");

struct ARRing {
    _Atomic uint64_t read, write;
    uint32_t capacity;
    float samples[];
};

ARRing *ar_ring_create(uint32_t capacity) {
    if (!capacity || capacity > ARSampleRate * 2) return NULL;
    ARRing *ring = calloc(1, sizeof(*ring) + (size_t)capacity * 2 * sizeof(float));
    if (ring) { ring->capacity = capacity; atomic_init(&ring->read, 0); atomic_init(&ring->write, 0); }
    return ring;
}
void ar_ring_destroy(ARRing *ring) { free(ring); }
uint32_t ar_ring_write(ARRing *ring, const float *samples, uint32_t frames) {
    uint64_t w = atomic_load_explicit(&ring->write, memory_order_relaxed);
    uint64_t r = atomic_load_explicit(&ring->read, memory_order_acquire);
    uint32_t available = ring->capacity - (uint32_t)(w - r);
    uint32_t count = frames < available ? frames : available;
    for (uint32_t i = 0; i < count; i++) {
        size_t slot = (size_t)((w + i) % ring->capacity) * 2;
        memcpy(ring->samples + slot, samples + (size_t)i * 2, 2 * sizeof(float));
    }
    atomic_store_explicit(&ring->write, w + count, memory_order_release);
    return count;
}
uint32_t ar_ring_read(ARRing *ring, float *samples, uint32_t frames) {
    uint64_t r = atomic_load_explicit(&ring->read, memory_order_relaxed);
    uint64_t w = atomic_load_explicit(&ring->write, memory_order_acquire);
    uint32_t available = (uint32_t)(w - r);
    uint32_t count = frames < available ? frames : available;
    for (uint32_t i = 0; i < count; i++) {
        size_t slot = (size_t)((r + i) % ring->capacity) * 2;
        memcpy(samples + (size_t)i * 2, ring->samples + slot, 2 * sizeof(float));
    }
    atomic_store_explicit(&ring->read, r + count, memory_order_release);
    return count;
}
uint32_t ar_ring_count(const ARRing *ring) {
    // A diagnostic observer is neither producer nor consumer. Clamp a snapshot
    // taken while the consumer advances; never publish unsigned underflow.
    uint64_t w = atomic_load_explicit(&ring->write, memory_order_acquire);
    uint64_t r = atomic_load_explicit(&ring->read, memory_order_acquire);
    return w >= r && w - r <= ring->capacity ? (uint32_t)(w - r) : 0;
}
void ar_ring_discard(ARRing *ring) {
    uint64_t w = atomic_load_explicit(&ring->write, memory_order_acquire);
    atomic_store_explicit(&ring->read, w, memory_order_release);
}

static const uint8_t magic[8] = { 'A', 'U', 'R', 'A', 'L', 'P', 'C', 'M' };
static void put32(uint8_t *p, uint32_t v) {
    for (unsigned i = 0; i < 4; i++) p[i] = (uint8_t)(v >> (i * 8));
}
static uint32_t get32(const uint8_t *p) {
    uint32_t v = 0;
    for (unsigned i = 0; i < 4; i++) v |= (uint32_t)p[i] << (i * 8);
    return v;
}
size_t ar_packet_encode(uint8_t *packet, const float *samples, uint32_t frames) {
    if (!frames || frames > ARPacketFrames) return 0;
    memcpy(packet, magic, sizeof(magic));
    put32(packet + 8, 1); put32(packet + 12, ARSampleRate);
    put32(packet + 16, ARChannels); put32(packet + 20, frames);
    size_t size = (size_t)frames * ARChannels * sizeof(float);
    memcpy(packet + ARHeaderBytes, samples, size);
    return ARHeaderBytes + size;
}
void ar_decoder_reset(ARDecoder *decoder) {
    decoder->used = 0; decoder->needed = ARHeaderBytes; decoder->failed = false;
}
bool ar_decoder_feed(ARDecoder *d, const void *bytes, size_t count,
                     ARPacketHandler handler, void *context) {
    if (d->failed) return false;
    const uint8_t *p = bytes;
    while (count) {
        size_t n = d->needed - d->used;
        if (n > count) n = count;
        memcpy(d->bytes + d->used, p, n);
        p += n; count -= n; d->used += n;
        if (d->used != d->needed) continue;
        uint32_t frames = get32(d->bytes + 20);
        if (d->needed == ARHeaderBytes) {
            if (memcmp(d->bytes, magic, 8) || get32(d->bytes + 8) != 1 ||
                get32(d->bytes + 12) != ARSampleRate || get32(d->bytes + 16) != ARChannels ||
                !frames || frames > ARPacketFrames) {
                d->failed = true; return false;
            }
            d->needed += (size_t)frames * ARChannels * sizeof(float);
        } else {
            // memcpy avoids type-punning byte storage as floats.
            float samples[ARPacketFrames * ARChannels];
            memcpy(samples, d->bytes + ARHeaderBytes, (size_t)frames * ARChannels * sizeof(float));
            handler(context, samples, frames);
            d->used = 0; d->needed = ARHeaderBytes;
        }
    }
    return true;
}
