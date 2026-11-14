#include "LocalTransport.h"
#include <errno.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

static volatile sig_atomic_t stopping;
static void stop_signal(int value) { stopping = value; }
static void timestamp(void) {
    time_t now = time(NULL);
    struct tm components;
    char text[32];
    localtime_r(&now, &components);
    strftime(text, sizeof(text), "%Y-%m-%dT%H:%M:%S%z", &components);
    printf("%s ", text);
}

int main(int argc, char **argv) {
    char *end = NULL;
    long seconds = argc == 3 ? strtol(argv[2], &end, 10) : 0;
    if (argc != 3 || !end || *end || seconds < 1 || seconds > 1800) {
        fprintf(stderr, "Usage: network-sink <local IPv4> <seconds: 1..1800>\n"); return 2;
    }
    ARLink *sink = ar_link_create_transport_sink_at_ipv4(argv[1]);
    if (!sink) { fprintf(stderr, "Invalid sink endpoint: %s\n", strerror(errno)); return 2; }
    int result = ar_link_start(sink);
    if (result) {
        fprintf(stderr, "Could not listen: %s\n", strerror(result)); ar_link_destroy(sink); return 1;
    }
    signal(SIGINT, stop_signal); signal(SIGTERM, stop_signal);
    setvbuf(stdout, NULL, _IOLBF, 0);
    timestamp(); printf("Listening on %s:%d for %ld seconds; validating and discarding PCM, no recording/playback.\n", argv[1], ARPort, seconds);
    for (long elapsed = 0; elapsed < seconds && !stopping; elapsed++) {
        ARLinkStats stats = ar_link_stats(sink);
        timestamp(); printf("connected=%d connections=%llu frames=%llu buffered=%u dropped=%llu protocolErrors=%llu errno=%d\n",
            stats.connected, (unsigned long long)stats.connections, (unsigned long long)stats.transferredFrames,
            stats.bufferedFrames, (unsigned long long)stats.droppedFrames,
            (unsigned long long)stats.protocolErrors, stats.error);
        if (stats.error) { result = 1; break; }
        sleep(1);
    }
    ar_link_destroy(sink);
    timestamp(); puts("Sink stopped; listener closed.");
    return result;
}
