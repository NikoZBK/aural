#include "LocalTransport.h"
#include <arpa/inet.h>
#include <dispatch/dispatch.h>
#include <errno.h>
#include <fcntl.h>
#include <mach/mach_time.h>
#include <netinet/tcp.h>
#include <os/log.h>
#include <poll.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

struct ARLink {
    bool sender, diagnosticSink;
    ARRing *ring;
    dispatch_queue_t queue;
    dispatch_source_t timer;
    int listener, socket;
    struct in_addr ipv4;
    bool connecting;
    uint64_t connectionStarted, pendingStarted;
    mach_timebase_info_data_t timebase;
    uint8_t packet[ARPacketBytes];
    size_t packetLength, packetOffset;
    uint32_t packetFrames;
    ARDecoder decoder;
    _Atomic bool active, connected;
    _Atomic int error;
    _Atomic uint64_t transferred, dropped, underrun, protocolErrors, connections, generation;
    // Accessed only by the receiver's audio thread.
    uint64_t renderGeneration;
    bool primed;
};

static void report_error(ARLink *link, int code) {
    int previous = atomic_exchange(&link->error, code);
    if (previous != code) os_log_error(OS_LOG_DEFAULT, "Aural route %{public}s: errno=%d",
                                     link->sender ? "sender" : "receiver", code);
}
static double elapsed(ARLink *link, uint64_t then) {
    return (double)(mach_absolute_time() - then) * link->timebase.numer / link->timebase.denom / 1e9;
}
static int make_socket(void) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    int one = 1, size = 65536;
    int flags = fcntl(fd, F_GETFL);
    if (flags < 0 || fcntl(fd, F_SETFL, flags | O_NONBLOCK) < 0 ||
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one)) < 0 ||
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one)) < 0 ||
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one)) < 0 ||
        setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &size, sizeof(size)) < 0 ||
        setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &size, sizeof(size)) < 0) {
        int code = errno; close(fd); errno = code; return -1;
    }
    return fd;
}
static struct sockaddr_in address(const ARLink *link) {
    struct sockaddr_in a = {0};
    a.sin_len = sizeof(a); a.sin_family = AF_INET;
    a.sin_port = htons(ARPort); a.sin_addr = link->ipv4;
    return a;
}
static void disconnect_peer(ARLink *link) {
    atomic_store(&link->connected, false);
    if (link->socket >= 0) { close(link->socket); link->socket = -1; }
    link->connecting = false;
    link->packetLength = link->packetOffset = link->packetFrames = 0;
    ar_decoder_reset(&link->decoder);
    atomic_fetch_add(&link->generation, 1);
    if (link->sender) ar_ring_discard(link->ring); // This worker owns the consumer.
}
static void connected(ARLink *link) {
    link->connecting = false;
    if (link->sender) ar_ring_discard(link->ring);
    atomic_fetch_add(&link->generation, 1);
    atomic_fetch_add(&link->connections, 1);
    atomic_store(&link->connected, true);
}
static void connect_sender(ARLink *link) {
    if (link->socket < 0) {
        // Connection refusals remain visible; retries are limited to once/second.
        if (link->connectionStarted && elapsed(link, link->connectionStarted) < 1) return;
        link->connectionStarted = mach_absolute_time();
        link->socket = make_socket();
        if (link->socket < 0) { report_error(link, errno); return; }
        struct sockaddr_in a = address(link);
        if (connect(link->socket, (struct sockaddr *)&a, sizeof(a)) == 0) {
            connected(link); return;
        }
        if (errno != EINPROGRESS) { report_error(link, errno); disconnect_peer(link); return; }
        link->connecting = true;
    }
    if (!link->connecting) return;
    struct pollfd p = { .fd = link->socket, .events = POLLOUT };
    int result = poll(&p, 1, 0);
    if (result < 0 && errno != EINTR) { report_error(link, errno); disconnect_peer(link); return; }
    if (result > 0) {
        int code = 0; socklen_t size = sizeof(code);
        if (getsockopt(link->socket, SOL_SOCKET, SO_ERROR, &code, &size) < 0) code = errno;
        if (code) { report_error(link, code); disconnect_peer(link); return; }
        connected(link);
    } else if (elapsed(link, link->connectionStarted) > 2) {
        report_error(link, ETIMEDOUT); disconnect_peer(link);
    }
}
static void pump_sender(ARLink *link) {
    connect_sender(link);
    if (!atomic_load(&link->connected)) return;
    for (unsigned packet = 0; packet < 8; packet++) {
        if (link->packetOffset == link->packetLength) {
            float samples[ARPacketFrames * ARChannels];
            uint32_t frames = ar_ring_read(link->ring, samples, ARPacketFrames);
            if (!frames) return;
            link->packetLength = ar_packet_encode(link->packet, samples, frames);
            link->packetOffset = 0; link->packetFrames = frames;
            link->pendingStarted = mach_absolute_time();
        }
        ssize_t sent = send(link->socket, link->packet + link->packetOffset,
                            link->packetLength - link->packetOffset, 0);
        if (sent > 0) {
            link->packetOffset += (size_t)sent;
            if (link->packetOffset == link->packetLength) atomic_fetch_add(&link->transferred, link->packetFrames);
        } else if (sent < 0 && (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR)) {
            if (elapsed(link, link->pendingStarted) > .5) {
                report_error(link, ETIMEDOUT); disconnect_peer(link);
            }
            return;
        } else { report_error(link, sent == 0 ? EPIPE : errno); disconnect_peer(link); return; }
    }
}
static void receive_packet(void *context, const float *samples, uint32_t frames) {
    ARLink *link = context;
    uint32_t accepted = link->diagnosticSink ? frames : ar_ring_write(link->ring, samples, frames);
    atomic_fetch_add(&link->transferred, frames);
    atomic_fetch_add(&link->dropped, frames - accepted);
}
static void pump_receiver(ARLink *link) {
    if (link->socket < 0) {
        int fd = accept(link->listener, NULL, NULL);
        if (fd < 0) {
            if (errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR) report_error(link, errno);
            return;
        }
        int flags = fcntl(fd, F_GETFL), one = 1;
        if (flags < 0 || fcntl(fd, F_SETFL, flags | O_NONBLOCK) < 0 ||
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one)) < 0) {
            report_error(link, errno); close(fd); return;
        }
        link->socket = fd; connected(link);
    }
    for (unsigned packet = 0; packet < 8; packet++) {
        uint8_t bytes[ARPacketBytes];
        ssize_t count = recv(link->socket, bytes, sizeof(bytes), 0);
        if (count > 0) {
            if (!ar_decoder_feed(&link->decoder, bytes, (size_t)count, receive_packet, link)) {
                atomic_fetch_add(&link->protocolErrors, 1);
                report_error(link, EPROTO); disconnect_peer(link); return;
            }
        } else if (count == 0) { disconnect_peer(link); return; }
        else if (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR) return;
        else { report_error(link, errno); disconnect_peer(link); return; }
    }
}

ARLink *ar_link_create(bool sender) {
    ARLink *link = calloc(1, sizeof(*link));
    if (!link) return NULL;
    link->sender = sender; link->listener = link->socket = -1;
    link->ipv4.s_addr = htonl(INADDR_LOOPBACK);
    link->ring = ar_ring_create(ARBufferFrames);
    link->queue = dispatch_queue_create(sender ? "aural.route.send" : "aural.route.receive", DISPATCH_QUEUE_SERIAL);
    if (!link->ring || !link->queue) {
        if (link->queue) dispatch_release(link->queue);
        ar_ring_destroy(link->ring); free(link); return NULL;
    }
    mach_timebase_info(&link->timebase);
    ar_decoder_reset(&link->decoder);
    atomic_init(&link->active, false); atomic_init(&link->connected, false); atomic_init(&link->error, 0);
    atomic_init(&link->transferred, 0); atomic_init(&link->dropped, 0); atomic_init(&link->underrun, 0);
    atomic_init(&link->protocolErrors, 0); atomic_init(&link->connections, 0); atomic_init(&link->generation, 0);
    return link;
}
ARLink *ar_link_create_transport_sink(void) {
    ARLink *link = ar_link_create(false);
    if (link) link->diagnosticSink = true; // Immutable before the worker starts.
    return link;
}
static ARLink *create_at_ipv4(bool sender, const char *ipv4) {
    struct in_addr parsed;
    if (inet_pton(AF_INET, ipv4, &parsed) != 1) {
        os_log_error(OS_LOG_DEFAULT, "Aural diagnostic endpoint is not a numeric IPv4 address.");
        errno = EINVAL; return NULL;
    }
    uint32_t host = ntohl(parsed.s_addr);
    bool local = (host >> 24) == 127 || (host >> 24) == 10 ||
                 (host >> 20) == 0xAC1 || (host >> 16) == 0xC0A8;
    // Restrict this diagnostic to explicit local hosts, never a wildcard,
    // public address, multicast address or conventional /24 broadcast.
    if (!local || (host & 0xFF) == 0 || (host & 0xFF) == 255) {
        os_log_error(OS_LOG_DEFAULT, "Aural diagnostic endpoint must be a local unicast IPv4 host.");
        errno = EINVAL; return NULL;
    }
    ARLink *link = sender ? ar_link_create(true) : ar_link_create_transport_sink();
    if (!link) { errno = ENOMEM; return NULL; }
    link->ipv4 = parsed;
    return link;
}
ARLink *ar_link_create_sender_to_ipv4(const char *ipv4) { return create_at_ipv4(true, ipv4); }
ARLink *ar_link_create_transport_sink_at_ipv4(const char *ipv4) { return create_at_ipv4(false, ipv4); }
int ar_link_start(ARLink *link) {
    __block int result = 0;
    dispatch_sync(link->queue, ^{
        if (atomic_load(&link->active)) return;
        atomic_store(&link->error, 0);
        if (!link->sender) {
            link->listener = make_socket();
            if (link->listener < 0) { result = errno; report_error(link, result); return; }
            struct sockaddr_in a = address(link);
            if (bind(link->listener, (struct sockaddr *)&a, sizeof(a)) < 0 || listen(link->listener, 1) < 0) {
                result = errno; report_error(link, result); close(link->listener); link->listener = -1; return;
            }
        }
        link->connectionStarted = 0;
        link->timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, link->queue);
        if (!link->timer) {
            result = ENOMEM; report_error(link, result);
            if (link->listener >= 0) { close(link->listener); link->listener = -1; }
            return;
        }
        dispatch_source_set_timer(link->timer, DISPATCH_TIME_NOW, 5 * NSEC_PER_MSEC, NSEC_PER_MSEC);
        dispatch_source_set_event_handler(link->timer, ^{
            if (link->sender) pump_sender(link); else pump_receiver(link);
        });
        atomic_store(&link->active, true);
        dispatch_resume(link->timer);
    });
    return result;
}
void ar_link_stop(ARLink *link) {
    dispatch_sync(link->queue, ^{
        atomic_store(&link->active, false);
        if (link->timer) { dispatch_source_cancel(link->timer); dispatch_release(link->timer); link->timer = NULL; }
        disconnect_peer(link);
        if (link->listener >= 0) { close(link->listener); link->listener = -1; }
    });
}
void ar_link_destroy(ARLink *link) {
    ar_link_stop(link); dispatch_release(link->queue); ar_ring_destroy(link->ring); free(link);
}
ARLinkStats ar_link_stats(const ARLink *link) {
    return (ARLinkStats){ atomic_load(&link->active), atomic_load(&link->connected), atomic_load(&link->error),
        ar_ring_count(link->ring), atomic_load(&link->transferred), atomic_load(&link->dropped),
        atomic_load(&link->underrun), atomic_load(&link->protocolErrors), atomic_load(&link->connections) };
}
void ar_link_push(ARLink *link, const float *samples, uint32_t frames) {
    if (!atomic_load(&link->connected)) return;
    uint32_t accepted = ar_ring_write(link->ring, samples, frames);
    atomic_fetch_add(&link->dropped, frames - accepted);
}
uint32_t ar_link_read(ARLink *link, float *samples, uint32_t frames) {
    memset(samples, 0, (size_t)frames * ARChannels * sizeof(float));
    uint64_t generation = atomic_load(&link->generation);
    if (generation != link->renderGeneration || !atomic_load(&link->connected)) {
        ar_ring_discard(link->ring); link->primed = false; link->renderGeneration = generation;
        return 0;
    }
    if (!link->primed) {
        if (ar_ring_count(link->ring) < ARPrerollFrames) return 0;
        link->primed = true;
    }
    uint32_t read = ar_ring_read(link->ring, samples, frames);
    if (read < frames) { atomic_fetch_add(&link->underrun, frames - read); link->primed = false; }
    return read;
}
