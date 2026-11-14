#import "RouteDriver.h"
#include <assert.h>
#include <errno.h>
#include <stdio.h>
#include <unistd.h>

static void wait_for_connection(ARRouteDriver *driver, ARLink *receiver, bool expected) {
    for (unsigned i = 0; i < 400; i++) {
        if (driver.transportStats.connected == expected &&
            ar_link_stats(receiver).connected == expected) return;
        usleep(5000);
    }
    fprintf(stderr, "Driver transport did not become %s (sender errno=%d, receiver errno=%d)\n",
            expected ? "connected" : "disconnected", driver.transportStats.error,
            ar_link_stats(receiver).error);
    abort();
}

int main(void) {
    @autoreleasepool {
        ARLink *receiver = ar_link_create(false);
        assert(receiver && ar_link_start(receiver) == 0);
        ARRouteDriver *driver = ARRouteDriver.shared;
        assert([driver.receiverIPv4 isEqualToString:@"127.0.0.1"]);
        // Preparation must connect before publication or any audio callback.
        assert([driver prepareTransport] == 0);
        wait_for_connection(driver, receiver, true);
        assert(driver.transportStats.transferredFrames == 0);
        assert(ar_link_stats(receiver).transferredFrames == 0);
        assert(!driver.registered && [driver startCapture] == ENODEV);
        uint64_t connections = ar_link_stats(receiver).connections;
        assert([driver prepareTransport] == 0); // Duplicate preparation preserves the peer.
        wait_for_connection(driver, receiver, true);
        assert(ar_link_stats(receiver).connections == connections);
        [driver stopCapture];
        wait_for_connection(driver, receiver, false);
        assert(!driver.transportStats.active);
        assert([driver prepareTransport] == 0);
        wait_for_connection(driver, receiver, true);
        assert(ar_link_stats(receiver).connections == connections + 1);
        assert(driver.transportStats.transferredFrames == 0);
        [driver stopCapture];
        wait_for_connection(driver, receiver, false);
        ar_link_destroy(receiver);
        puts("PASS driver connects before publication/audio, blocks premature capture, preserves duplicate preparation and reconnects after stop");
    }
    return 0;
}
