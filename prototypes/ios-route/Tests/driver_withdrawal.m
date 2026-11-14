// Test the real plug-in's removal contract, not iOS route-selection policy.
#import "../Extension/RouteDriver.m"
#include <assert.h>
#include <stdio.h>

static UInt32 notifications;
static OSStatus notificationResult;
static const AudioObjectPropertyAddress listAddress = {
    kAudioPlugInPropertyDeviceList, kAudioObjectPropertyScopeGlobal,
    kAudioObjectPropertyElementMain
};

static void check_device_list(bool present) {
    const AudioObjectPropertySelector selectors[] = {
        kAudioPlugInPropertyDeviceList, kAudioObjectPropertyOwnedObjects
    };
    for (unsigned i = 0; i < 2; i++) {
        AudioObjectPropertyAddress address = listAddress;
        address.mSelector = selectors[i];
        UInt32 size = 99;
        assert((*gDriverRef)->GetPropertyDataSize(gDriverRef, kObjectID_PlugIn,
            0, &address, 0, NULL, &size) == noErr);
        assert(size == (present ? sizeof(AudioObjectID) : 0));
        AudioObjectID object = 999;
        assert((*gDriverRef)->GetPropertyData(gDriverRef, kObjectID_PlugIn,
            0, &address, 0, NULL, sizeof(object), &size, &object) == noErr);
        assert(size == (present ? sizeof(object) : 0));
        assert(object == (present ? kObjectID_Device : 999));
        // A zero-capacity read must not write any object IDs.
        assert((*gDriverRef)->GetPropertyData(gDriverRef, kObjectID_PlugIn,
            0, &address, 0, NULL, 0, &size, &object) == noErr && size == 0);
        assert(object == (present ? kObjectID_Device : 999));
    }
    AudioObjectPropertyAddress translation = listAddress;
    translation.mSelector = kAudioPlugInPropertyTranslateUIDToDevice;
    CFStringRef uid = CFSTR("41555241-4C52-4F55-A000-000000000001");
    AudioObjectID object = 999;
    UInt32 size = 0;
    assert((*gDriverRef)->GetPropertyData(gDriverRef, kObjectID_PlugIn,
        0, &translation, sizeof(uid), &uid, sizeof(object), &size, &object) == noErr);
    assert(size == sizeof(object));
    assert(object == (present ? kObjectID_Device : kAudioObjectUnknown));
}

static OSStatus properties_changed(AudioServerPlugInHostRef host, AudioObjectID object,
                                    UInt32 count, const AudioObjectPropertyAddress *addresses) {
    assert(host && object == kObjectID_PlugIn && count == 2);
    assert(addresses[0].mSelector == kAudioPlugInPropertyDeviceList);
    assert(addresses[1].mSelector == kAudioObjectPropertyOwnedObjects);
    for (unsigned i = 0; i < count; i++) {
        assert(addresses[i].mScope == kAudioObjectPropertyScopeGlobal);
        assert(addresses[i].mElement == kAudioObjectPropertyElementMain);
    }
    // Reentrant reads must already see removal; no driver lock may be held.
    check_device_list(false);
    ULONG references = (*gDriverRef)->AddRef(gDriverRef);
    assert((*gDriverRef)->Release(gDriverRef) == references - 1);
    assert(!atomic_load(&gCapture));
    notifications++;
    return notificationResult;
}

int main(void) {
    @autoreleasepool {
        ARRouteDriver *driver = ARRouteDriver.shared;
        // Discovery and the actual HAL property must agree after product renaming.
        gDeviceDisplayName = @"Aural";
        AudioObjectPropertyAddress nameAddress = listAddress;
        nameAddress.mSelector = kAudioObjectPropertyName;
        CFStringRef name = NULL;
        UInt32 nameSize = 0;
        assert((*gDriverRef)->GetPropertyData(gDriverRef, kObjectID_Device, 0,
            &nameAddress, 0, NULL, sizeof(name), &nameSize, &name) == noErr);
        assert(nameSize == sizeof(name) && CFEqual(name, (__bridge CFStringRef)driver.deviceDisplayName));
        assert(CFEqual(name, CFSTR("Aural")));
        CFRelease(name);
        NSString *uid = @"41555241-4C52-4F55-A000-000000000001";
        assert(!gHost);
        [driver stopCapture]; // Stopping before the first host initialization is safe.
        check_device_list(false);
        // Host publication deliberately fails: this harness cannot stand in for
        // the iPhone registration API. It can inspect the actual exposed graph.
        assert([driver publishWithDeviceUID:uid] == kAudioHardwareUnsupportedOperationError);
        assert(!driver.registered);
        check_device_list(true);
        AudioServerPlugInHostInterface host = {.PropertiesChanged = properties_changed};
        assert((*gDriverRef)->Initialize(gDriverRef, &host) == noErr);
        [driver stopCapture];
        check_device_list(false);
        assert(notifications == 1);
        [driver stopCapture];
        assert(notifications == 1); // Delivery stop followed by deactivation is idempotent.

        CFStringRef originalUID = gDeviceUID;
        AudioServerPlugInDriverRef originalDriver = gDriverRef;
        atomic_store(&gStreamActive, false);
        assert([driver publishWithDeviceUID:uid] == kAudioHardwareUnsupportedOperationError);
        assert(!driver.registered && [driver startCapture] == ENODEV);
        check_device_list(true);
        assert(gDeviceUID == originalUID && gDriverRef == originalDriver);
        assert(!atomic_load(&gStreamActive)); // Only the host controls this stream state.
        assert((*gDriverRef)->Initialize(gDriverRef, &host) == noErr);
        check_device_list(true);

        notificationResult = kAudioHardwareUnspecifiedError;
        assert(AR_WithdrawDevice() == notificationResult);
        assert(notifications == 2);
        check_device_list(false);
        // Failure is surfaced, without pretending the host accepted removal.
        assert([driver publishWithDeviceUID:@"different-uid"] == kAudioHardwareIllegalOperationError);
        check_device_list(false);
        puts("PASS default HAL withdrawal, pre-initialization stop, UID lookup, stable identity, reentrant notification, repeated stop and notification failure");
    }
    return 0;
}
