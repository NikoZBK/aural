#pragma once
#include "RouteCore.h"
#pragma clang assume_nonnull begin

typedef struct ARLink ARLink;
typedef struct {
    bool active, connected;
    int error;
    uint32_t bufferedFrames;
    uint64_t transferredFrames, droppedFrames, underrunFrames, protocolErrors, connections;
} ARLinkStats;

// Control-thread APIs. Stop must precede destroy; stop the renderer before destroy.
ARLink * _Nullable ar_link_create(bool sender);
// Diagnostic receiver: validate/count packets, then discard their samples on
// the transport worker. No renderer or audio session is needed; never plays PCM.
ARLink * _Nullable ar_link_create_transport_sink(void);
// Diagnostic endpoint controls: numeric loopback or RFC1918 IPv4 only. The
// address is immutable for the link's lifetime. Invalid input returns EINVAL.
ARLink * _Nullable ar_link_create_sender_to_ipv4(const char *ipv4);
ARLink * _Nullable ar_link_create_transport_sink_at_ipv4(const char *ipv4);
void ar_link_destroy(ARLink *link);
int ar_link_start(ARLink *link);
void ar_link_stop(ARLink *link);
ARLinkStats ar_link_stats(const ARLink *link);
// Sender: the driver calls push. Receiver: the audio renderer calls read.
// No allocation, locks, sockets, logging, Objective-C, or Swift in these APIs.
void ar_link_push(ARLink *link, const float *stereo, uint32_t frames);
uint32_t ar_link_read(ARLink *link, float *stereo, uint32_t frames);

#pragma clang assume_nonnull end
