// Exercise the real HAL callbacks with a small host. Including the implementation
// keeps test access out of the extension's production interface.
#import "../Extension/RouteDriver.m"
#include <assert.h>
#include <stdio.h>
#include <unistd.h>

static UInt32 notifications;
static UInt32 withdrawals;
static OSStatus notificationResult;
static const AudioObjectPropertyAddress activeAddress = {
    kAudioStreamPropertyIsActive, kAudioObjectPropertyScopeGlobal,
    kAudioObjectPropertyElementMain
};

static UInt32 read_active(void) {
    UInt32 active = 99, size = 0;
    assert((*gDriverRef)->GetPropertyData(gDriverRef, kObjectID_Stream_Output,
        0, &activeAddress, 0, NULL, sizeof(active), &size, &active) == noErr);
    assert(size == sizeof(active));
    return active;
}

static OSStatus properties_changed(AudioServerPlugInHostRef host, AudioObjectID object,
                                    UInt32 count, const AudioObjectPropertyAddress *addresses) {
    assert(host && addresses);
    if (object == kObjectID_PlugIn) {
        assert(count == 2);
        assert(addresses[0].mSelector == kAudioPlugInPropertyDeviceList);
        assert(addresses[1].mSelector == kAudioObjectPropertyOwnedObjects);
        for (UInt32 i = 0; i < count; i++) {
            assert(addresses[i].mScope == kAudioObjectPropertyScopeGlobal);
            assert(addresses[i].mElement == kAudioObjectPropertyElementMain);
            UInt32 size = 99;
            assert((*gDriverRef)->GetPropertyDataSize(gDriverRef, object, 0,
                &addresses[i], 0, NULL, &size) == noErr && size == 0);
        }
        assert(!atomic_load(&gCapture));
        withdrawals++;
        return noErr;
    }
    assert(object == kObjectID_Stream_Output && count == 1);
    assert(addresses[0].mSelector == activeAddress.mSelector);
    assert(addresses[0].mScope == activeAddress.mScope);
    assert(addresses[0].mElement == activeAddress.mElement);
    // Host callbacks may reenter the driver. Notification must follow the change
    // and must not hold a lock that a property query needs.
    assert(read_active() <= 1);
    notifications++;
    return notificationResult;
}

static OSStatus set_active(UInt32 active) {
    return (*gDriverRef)->SetPropertyData(gDriverRef, kObjectID_Stream_Output,
        0, &activeAddress, 0, NULL, sizeof(active), &active);
}

static void wait_for_frames(ARLink *receiver, uint64_t frames) {
    for (unsigned i = 0; i < 400; i++) {
        if (ar_link_stats(receiver).transferredFrames == frames) return;
        usleep(5000);
    }
    fprintf(stderr, "Expected %llu frames, got %llu\n", (unsigned long long)frames,
            (unsigned long long)ar_link_stats(receiver).transferredFrames);
    abort();
}

int main(void) {
    @autoreleasepool {
        ARRouteDriver *driver = ARRouteDriver.shared;
        AudioServerPlugInHostInterface host = {.PropertiesChanged = properties_changed};
        assert((*gDriverRef)->Initialize(gDriverRef, &host) == noErr);
        Boolean settable = false;
        assert((*gDriverRef)->IsPropertySettable(gDriverRef, kObjectID_Stream_Output,
            0, &activeAddress, &settable) == noErr && settable);
        assert(read_active() == 1);
        assert(set_active(0) == noErr);
        assert(read_active() == 0 && notifications == 1);
        assert(set_active(0) == noErr && notifications == 1);

        UInt32 enabled = 1;
        assert((*gDriverRef)->SetPropertyData(gDriverRef, kObjectID_Stream_Output,
            0, &activeAddress, 0, NULL, sizeof(enabled) - 1, &enabled)
            == kAudioHardwareBadPropertySizeError);
        assert(AR_SetPropertyData(gDriverRef, kObjectID_Stream_Output,
            0, &activeAddress, 0, NULL, sizeof(enabled), NULL)
            == kAudioHardwareIllegalOperationError);
        assert(read_active() == 0 && notifications == 1);
        // A repeated host initialization must not silently undo a stream setting.
        assert((*gDriverRef)->Initialize(gDriverRef, &host) == noErr);
        assert(read_active() == 0 && notifications == 1);
        assert(set_active(7) == noErr); // Core Audio defines any nonzero value as enabled.
        assert(read_active() == 1 && notifications == 2);

        // Explicitly surface a failed host notification; never claim success.
        notificationResult = kAudioHardwareUnspecifiedError;
        assert(set_active(0) == notificationResult && notifications == 3);
        assert(read_active() == 0);
        notificationResult = noErr;

        ARLink *receiver = ar_link_create_transport_sink();
        assert(receiver && ar_link_start(receiver) == 0);
        assert([driver prepareTransport] == 0);
        for (unsigned i = 0; i < 400 && !driver.transportStats.connected; i++) usleep(5000);
        assert(driver.transportStats.connected);
        // iOS publication is unavailable on macOS. Set only its readiness input
        // for this callback test; this does not simulate system route selection.
        uint64_t token = ar_registration_begin(&gRegistration);
        assert(ar_registration_finish(&gRegistration, token, true));
        assert([driver startCapture] == 0);
        float samples[256 * ARChannels] = {0};
        AudioServerPlugInIOCycleInfo cycle = {0};
        for (unsigned i = 0; i < 64; i++) {
            assert((*gDriverRef)->DoIOOperation(gDriverRef, kObjectID_Device,
                kObjectID_Stream_Output, 0, kAudioServerPlugInIOOperationWriteMix,
                256, &cycle, samples, NULL) == noErr);
        }
        ARLinkStats disabled = driver.transportStats;
        assert(disabled.bufferedFrames == 0 && disabled.transferredFrames == 0);
        assert(set_active(1) == noErr);
        assert((*gDriverRef)->DoIOOperation(gDriverRef, kObjectID_Device,
            kObjectID_Stream_Output, 0, kAudioServerPlugInIOOperationWriteMix,
            256, &cycle, samples, NULL) == noErr);
        wait_for_frames(receiver, 256);
        assert(set_active(0) == noErr);
        assert((*gDriverRef)->DoIOOperation(gDriverRef, kObjectID_Device,
            kObjectID_Stream_Output, 0, kAudioServerPlugInIOOperationWriteMix,
            256, &cycle, samples, NULL) == noErr);
        assert(driver.transportStats.bufferedFrames == 0);
        assert(driver.transportStats.transferredFrames == 256);
        assert(set_active(1) == noErr);
        assert((*gDriverRef)->DoIOOperation(gDriverRef, kObjectID_Device,
            kObjectID_Stream_Output, 0, kAudioServerPlugInIOOperationWriteMix,
            256, &cycle, samples, NULL) == noErr);
        wait_for_frames(receiver, 512);
        assert(ar_link_stats(receiver).droppedFrames == 0);
        [driver stopCapture];
        assert(withdrawals == 1);
        ar_link_destroy(receiver);
        puts("PASS real HAL stream enable/disable round-trip, validation, notifications, reinitialization and PCM gating");
    }
    return 0;
}
