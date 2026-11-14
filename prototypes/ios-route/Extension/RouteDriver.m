// HAL property implementation adapted from ios27-media-device-passthrough.
// Copyright (c) 2026 nemut.ai. MIT-0; see ThirdParty/LICENSE-MIT-0.txt.
// Aural uses a C-only bounded transport in the real-time callback. Publication
// follows the SDK; no private APIs, NULL-registration, forced exit, or delayed kill.

#import "RouteDriver.h"
#import "LocalTransport.h"
#import "RouteRegistration.h"
#import <TargetConditionals.h>
#import <CoreAudio/AudioServerPlugIn.h>
#import <os/log.h>
#import <pthread.h>
#import <mach/mach_time.h>
#import <stdatomic.h>
#import <errno.h>

enum {
    kObjectID_PlugIn        = kAudioObjectPlugInObject,
    kObjectID_Device        = 2,
    kObjectID_Stream_Output = 3,
};

enum {
    kRouteStreamConfiguration    = 'slay',
    kRoutePreferredChannelLayout = 'srnd',
};

static const Float64  kSampleRate     = 48000.0;
static const UInt32   kChannelCount   = 2;
static const UInt32   kRingFrames     = 16384;

static os_log_t gLog;

static AudioServerPlugInDriverInterface   gInterface;
static AudioServerPlugInDriverInterface  *gInterfacePtr = &gInterface;
static AudioServerPlugInDriverRef         gDriverRef    = &gInterfacePtr;
static AudioServerPlugInHostRef           gHost         = NULL;

static pthread_mutex_t  gStateMutex = PTHREAD_MUTEX_INITIALIZER;
static UInt32           gRefCount   = 1;
static CFStringRef      gDeviceUID  = NULL;
static NSString *gDeviceDisplayName = @"Aural Route Probe";
static ARRegistration gRegistration;
static _Atomic bool gIORunning = false;
static _Atomic bool gStreamActive = true;
static _Atomic UInt64 gIOCount = 0;
static UInt32 gClients = 0;
static _Atomic bool gDeviceExposed = true;

static Float64  gZeroSampleTime = 0;
static UInt64   gZeroHostTime   = 0;
static UInt64   gAnchorHostTime = 0;
static UInt64   gPeriodCount    = 0;
static UInt64   gTimelineSeed   = 1;

static ARLink *gSender; // Created once before publication; lives for the process.
static _Atomic bool gCapture = false;
static Float64 gHostTicksPerFrame;

static void FourCCStr(uint32_t v, char out[5]) {
    out[0] = (char)((v >> 24) & 0xff);
    out[1] = (char)((v >> 16) & 0xff);
    out[2] = (char)((v >> 8) & 0xff);
    out[3] = (char)(v & 0xff);
    out[4] = 0;
    for (int i = 0; i < 4; i++) if (out[i] < 0x20 || out[i] > 0x7e) out[i] = '.';
}

static void log_property(const char *tag, AudioObjectID object, const AudioObjectPropertyAddress *address) {
    char selector[5], scope[5];
    FourCCStr(address->mSelector, selector);
    FourCCStr(address->mScope, scope);
    os_log(gLog, "%{public}s obj=%u sel=%{public}s scope=%{public}s el=%u",
           tag, (unsigned)object, selector, scope, (unsigned)address->mElement);
}

static AudioStreamBasicDescription RouteFormat(void) {
    AudioStreamBasicDescription f = {0};
    f.mSampleRate       = kSampleRate;
    f.mFormatID         = kAudioFormatLinearPCM;
    f.mFormatFlags      = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked;
    f.mBytesPerPacket   = 4 * kChannelCount;
    f.mFramesPerPacket  = 1;
    f.mBytesPerFrame    = 4 * kChannelCount;
    f.mChannelsPerFrame = kChannelCount;
    f.mBitsPerChannel   = 32;
    return f;
}

static HRESULT AR_QueryInterface(void *inDriver, REFIID inUUID, LPVOID *outInterface) {
    if (inDriver != gDriverRef || outInterface == NULL) return kAudioHardwareBadObjectError;
    CFUUIDRef req = CFUUIDCreateFromUUIDBytes(NULL, inUUID);
    CFUUIDRef iunknown = IUnknownUUID;
    CFUUIDRef plugin   = kAudioServerPlugInDriverInterfaceUUID;
    HRESULT rc = E_NOINTERFACE;
    if (CFEqual(req, iunknown) || CFEqual(req, plugin)) {
        pthread_mutex_lock(&gStateMutex);
        gRefCount++;
        pthread_mutex_unlock(&gStateMutex);
        *outInterface = gDriverRef;
        rc = S_OK;
    }
    CFRelease(req);
    return rc;
}

static ULONG AR_AddRef(void *inDriver) {
    if (inDriver != gDriverRef) return 0;
    pthread_mutex_lock(&gStateMutex);
    ULONG n = ++gRefCount;
    pthread_mutex_unlock(&gStateMutex);
    return n;
}

static ULONG AR_Release(void *inDriver) {
    if (inDriver != gDriverRef) return 0;
    pthread_mutex_lock(&gStateMutex);
    ULONG n = gRefCount > 0 ? --gRefCount : 0;
    pthread_mutex_unlock(&gStateMutex);
    return n;
}

static OSStatus AR_Initialize(AudioServerPlugInDriverRef inDriver,
                              AudioServerPlugInHostRef inHost) {
    if (inDriver != gDriverRef) return kAudioHardwareBadObjectError;
    pthread_mutex_lock(&gStateMutex);
    gHost = inHost;
    pthread_mutex_unlock(&gStateMutex);
    gAnchorHostTime = 0;
    os_log(gLog, "Initialize streamActive=%d ioRunning=%d", atomic_load(&gStreamActive), atomic_load(&gIORunning));
    return noErr;
}

static OSStatus AR_CreateDevice(AudioServerPlugInDriverRef d, CFDictionaryRef desc,
                                const AudioServerPlugInClientInfo *c, AudioObjectID *out) {
    (void)d; (void)desc; (void)c; (void)out;
    return kAudioHardwareUnsupportedOperationError;
}
static OSStatus AR_DestroyDevice(AudioServerPlugInDriverRef d, AudioObjectID id) {
    (void)d; (void)id;
    return kAudioHardwareUnsupportedOperationError;
}

static OSStatus AR_AddDeviceClient(AudioServerPlugInDriverRef d, AudioObjectID dev,
                                   const AudioServerPlugInClientInfo *info) {
    (void)d;
    if (dev != kObjectID_Device) return kAudioHardwareBadObjectError;
    os_log(gLog, "AddDeviceClient pid=%d bundle=%{public}@",
           info ? info->mProcessID : -1,
           info ? (__bridge NSString *)info->mBundleID : @"-");
    return noErr;
}

static OSStatus AR_RemoveDeviceClient(AudioServerPlugInDriverRef d, AudioObjectID dev,
                                      const AudioServerPlugInClientInfo *info) {
    (void)d; (void)info;
    if (dev != kObjectID_Device) return kAudioHardwareBadObjectError;
    os_log(gLog, "RemoveDeviceClient");
    return noErr;
}

static OSStatus AR_PerformDeviceConfigurationChange(AudioServerPlugInDriverRef d,
                                                    AudioObjectID dev, UInt64 action,
                                                    void *info) {
    (void)d; (void)dev; (void)action; (void)info;
    return noErr;
}
static OSStatus AR_AbortDeviceConfigurationChange(AudioServerPlugInDriverRef d,
                                                  AudioObjectID dev, UInt64 action,
                                                  void *info) {
    (void)d; (void)dev; (void)action; (void)info;
    return noErr;
}

static Boolean AR_HasProperty(AudioServerPlugInDriverRef d, AudioObjectID obj,
                              pid_t client, const AudioObjectPropertyAddress *addr) {
    (void)d; (void)client;
    if (!addr) return false;
    switch (obj) {
        case kObjectID_PlugIn:
            switch (addr->mSelector) {
                case kAudioObjectPropertyBaseClass:
                case kAudioObjectPropertyClass:
                case kAudioObjectPropertyOwner:
                case kAudioObjectPropertyManufacturer:
                case kAudioObjectPropertyOwnedObjects:
                case kAudioPlugInPropertyDeviceList:
                case kAudioPlugInPropertyTranslateUIDToDevice:
                    return true;
            }
            return false;
        case kObjectID_Device:
            switch (addr->mSelector) {
                case kAudioObjectPropertyBaseClass:
                case kAudioObjectPropertyClass:
                case kAudioObjectPropertyOwner:
                case kAudioObjectPropertyName:
                case kAudioObjectPropertyManufacturer:
                case kAudioObjectPropertyOwnedObjects:
                case kAudioDevicePropertyDeviceUID:
                case kAudioDevicePropertyModelUID:
                case kAudioDevicePropertyTransportType:
                case kAudioDevicePropertyRelatedDevices:
                case kAudioDevicePropertyClockDomain:
                case kAudioDevicePropertyDeviceIsAlive:
                case kAudioDevicePropertyDeviceIsRunning:
                case kAudioDevicePropertyDeviceCanBeDefaultDevice:
                case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
                case kAudioDevicePropertyLatency:
                case kAudioDevicePropertyStreams:
                case kAudioDevicePropertySafetyOffset:
                case kAudioDevicePropertyNominalSampleRate:
                case kAudioDevicePropertyAvailableNominalSampleRates:
                case kAudioDevicePropertyIsHidden:
                case kAudioDevicePropertyZeroTimeStampPeriod:
                case kAudioDevicePropertyPreferredChannelsForStereo:
                case kRouteStreamConfiguration:
                case kRoutePreferredChannelLayout:
                case kAudioObjectPropertyControlList:
                    return true;
            }
            return false;
        case kObjectID_Stream_Output:
            switch (addr->mSelector) {
                case kAudioObjectPropertyBaseClass:
                case kAudioObjectPropertyClass:
                case kAudioObjectPropertyOwner:
                case kAudioStreamPropertyIsActive:
                case kAudioStreamPropertyDirection:
                case kAudioStreamPropertyTerminalType:
                case kAudioStreamPropertyStartingChannel:
                case kAudioStreamPropertyLatency:
                case kAudioStreamPropertyVirtualFormat:
                case kAudioStreamPropertyPhysicalFormat:
                case kAudioStreamPropertyAvailableVirtualFormats:
                case kAudioStreamPropertyAvailablePhysicalFormats:
                    return true;
            }
            return false;
    }
    log_property("HAS-NO", obj, addr);
    return false;
}

static OSStatus AR_IsPropertySettable(AudioServerPlugInDriverRef d, AudioObjectID obj,
                                      pid_t client, const AudioObjectPropertyAddress *addr,
                                      Boolean *outSettable) {
    (void)d; (void)client;
    if (!addr || !outSettable) return kAudioHardwareIllegalOperationError;
    *outSettable = false;
    if (obj == kObjectID_Device && addr->mSelector == kAudioDevicePropertyNominalSampleRate) {
        *outSettable = true;
    }
    if (obj == kObjectID_Stream_Output && addr->mSelector == kAudioStreamPropertyIsActive) {
        *outSettable = true;
    }
    return noErr;
}

#define RAR_SIZE(n)  do { if (outSize) *outSize = (n); return noErr; } while (0)

static OSStatus AR_GetPropertyDataSize(AudioServerPlugInDriverRef d, AudioObjectID obj,
                                       pid_t client, const AudioObjectPropertyAddress *addr,
                                       UInt32 qualSize, const void *qual, UInt32 *outSize) {
    (void)d; (void)client; (void)qualSize; (void)qual;
    if (!addr || !outSize) return kAudioHardwareIllegalOperationError;

    switch (obj) {
        case kObjectID_PlugIn:
            switch (addr->mSelector) {
                case kAudioObjectPropertyBaseClass:
                case kAudioObjectPropertyClass:              RAR_SIZE(sizeof(AudioClassID));
                case kAudioObjectPropertyOwner:              RAR_SIZE(sizeof(AudioObjectID));
                case kAudioObjectPropertyManufacturer:        RAR_SIZE(sizeof(CFStringRef));
                case kAudioObjectPropertyOwnedObjects:
                case kAudioPlugInPropertyDeviceList:
                    RAR_SIZE(atomic_load(&gDeviceExposed) ? sizeof(AudioObjectID) : 0);
                case kAudioPlugInPropertyTranslateUIDToDevice: RAR_SIZE(sizeof(AudioObjectID));
            }
            break;
        case kObjectID_Device:
            switch (addr->mSelector) {
                case kAudioObjectPropertyBaseClass:
                case kAudioObjectPropertyClass:              RAR_SIZE(sizeof(AudioClassID));
                case kAudioObjectPropertyOwner:              RAR_SIZE(sizeof(AudioObjectID));
                case kAudioObjectPropertyName:
                case kAudioObjectPropertyManufacturer:
                case kAudioDevicePropertyDeviceUID:
                case kAudioDevicePropertyModelUID:            RAR_SIZE(sizeof(CFStringRef));
                case kAudioObjectPropertyOwnedObjects:
                case kAudioDevicePropertyStreams:
                    RAR_SIZE(addr->mScope == kAudioObjectPropertyScopeInput
                             ? 0u : (UInt32)sizeof(AudioObjectID));
                case kAudioDevicePropertyTransportType:
                case kAudioDevicePropertyClockDomain:
                case kAudioDevicePropertyDeviceIsAlive:
                case kAudioDevicePropertyDeviceIsRunning:
                case kAudioDevicePropertyDeviceCanBeDefaultDevice:
                case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
                case kAudioDevicePropertyLatency:
                case kAudioDevicePropertySafetyOffset:
                case kAudioDevicePropertyIsHidden:
                case kAudioDevicePropertyZeroTimeStampPeriod: RAR_SIZE(sizeof(UInt32));
                case kAudioDevicePropertyRelatedDevices:      RAR_SIZE(sizeof(AudioObjectID));
                case kAudioDevicePropertyNominalSampleRate:   RAR_SIZE(sizeof(Float64));
                case kAudioDevicePropertyAvailableNominalSampleRates:
                                                              RAR_SIZE(sizeof(AudioValueRange));
                case kAudioDevicePropertyPreferredChannelsForStereo:
                                                              RAR_SIZE(2 * sizeof(UInt32));
                case kRouteStreamConfiguration:
                    RAR_SIZE(addr->mScope == kAudioObjectPropertyScopeInput
                             ? (UInt32)offsetof(AudioBufferList, mBuffers)
                             : (UInt32)(offsetof(AudioBufferList, mBuffers) + sizeof(AudioBuffer)));
                case kRoutePreferredChannelLayout:
                    RAR_SIZE(offsetof(AudioChannelLayout, mChannelDescriptions));
                case kAudioObjectPropertyControlList:
                    RAR_SIZE(0);
            }
            break;
        case kObjectID_Stream_Output:
            switch (addr->mSelector) {
                case kAudioObjectPropertyBaseClass:
                case kAudioObjectPropertyClass:              RAR_SIZE(sizeof(AudioClassID));
                case kAudioObjectPropertyOwner:              RAR_SIZE(sizeof(AudioObjectID));
                case kAudioStreamPropertyIsActive:
                case kAudioStreamPropertyDirection:
                case kAudioStreamPropertyTerminalType:
                case kAudioStreamPropertyStartingChannel:
                case kAudioStreamPropertyLatency:            RAR_SIZE(sizeof(UInt32));
                case kAudioStreamPropertyVirtualFormat:
                case kAudioStreamPropertyPhysicalFormat:
                                            RAR_SIZE(sizeof(AudioStreamBasicDescription));
                case kAudioStreamPropertyAvailableVirtualFormats:
                case kAudioStreamPropertyAvailablePhysicalFormats:
                                            RAR_SIZE(sizeof(AudioStreamRangedDescription));
            }
            break;
    }
    log_property("SIZE-UNKNOWN", obj, addr);
    return kAudioHardwareUnknownPropertyError;
}

#undef RAR_SIZE

#define PUT(type, value) \
    do { if (inDataSize < sizeof(type)) return kAudioHardwareBadPropertySizeError; \
         *((type *)outData) = (value); *outDataSize = sizeof(type); return noErr; } while (0)

static OSStatus AR_GetPropertyData(AudioServerPlugInDriverRef d, AudioObjectID obj,
                                   pid_t client, const AudioObjectPropertyAddress *addr,
                                   UInt32 qualSize, const void *qual,
                                   UInt32 inDataSize, UInt32 *outDataSize, void *outData) {
    (void)d; (void)client;
    if (!addr || !outDataSize || !outData) return kAudioHardwareIllegalOperationError;

    switch (obj) {
        case kObjectID_PlugIn:
            switch (addr->mSelector) {
                case kAudioObjectPropertyBaseClass: PUT(AudioClassID, kAudioObjectClassID);
                case kAudioObjectPropertyClass:     PUT(AudioClassID, kAudioPlugInClassID);
                case kAudioObjectPropertyOwner:     PUT(AudioObjectID, kAudioObjectUnknown);
                case kAudioObjectPropertyManufacturer:
                    PUT(CFStringRef, (CFStringRef)CFRetain(CFSTR("Aural")));
                case kAudioObjectPropertyOwnedObjects:
                case kAudioPlugInPropertyDeviceList:
                    if (!atomic_load(&gDeviceExposed) || inDataSize < sizeof(AudioObjectID)) {
                        *outDataSize = 0;
                        return noErr;
                    }
                    ((AudioObjectID *)outData)[0] = kObjectID_Device;
                    *outDataSize = sizeof(AudioObjectID);
                    return noErr;
                case kAudioPlugInPropertyTranslateUIDToDevice: {
                    if (qualSize != sizeof(CFStringRef) || !qual)
                        return kAudioHardwareBadPropertySizeError;
                    CFStringRef want = *((CFStringRef *)qual);
                    AudioObjectID r = kAudioObjectUnknown;
                    if (atomic_load(&gDeviceExposed) && gDeviceUID && want && CFEqual(want, gDeviceUID)) {
                        r = kObjectID_Device;
                    }
                    PUT(AudioObjectID, r);
                }
            }
            break;

        case kObjectID_Device:
            switch (addr->mSelector) {
                case kAudioObjectPropertyBaseClass: PUT(AudioClassID, kAudioObjectClassID);
                case kAudioObjectPropertyClass:     PUT(AudioClassID, kAudioDeviceClassID);
                case kAudioObjectPropertyOwner:     PUT(AudioObjectID, kObjectID_PlugIn);
                case kAudioObjectPropertyName:
                    PUT(CFStringRef, (CFStringRef)CFRetain((__bridge CFStringRef)gDeviceDisplayName));
                case kAudioObjectPropertyManufacturer:
                    PUT(CFStringRef, (CFStringRef)CFRetain(CFSTR("Aural")));
                case kAudioDevicePropertyDeviceUID:
                    PUT(CFStringRef, gDeviceUID ? (CFStringRef)CFRetain(gDeviceUID)
                                                : (CFStringRef)CFRetain(CFSTR("")));
                case kAudioDevicePropertyModelUID:
                    PUT(CFStringRef, (CFStringRef)CFRetain(CFSTR("local.aural.route-probe.model")));
                case kAudioDevicePropertyTransportType:
                    PUT(UInt32, kAudioDeviceTransportTypeRemoteStreaming);
                case kAudioDevicePropertyRelatedDevices:
                    if (inDataSize < sizeof(AudioObjectID)) { *outDataSize = 0; return noErr; }
                    ((AudioObjectID *)outData)[0] = kObjectID_Device;
                    *outDataSize = sizeof(AudioObjectID);
                    return noErr;
                case kAudioDevicePropertyClockDomain:       PUT(UInt32, 0);
                case kAudioDevicePropertyDeviceIsAlive:     PUT(UInt32, 1);
                case kAudioDevicePropertyDeviceIsRunning:   PUT(UInt32, gIORunning ? 1 : 0);
                case kAudioDevicePropertyDeviceCanBeDefaultDevice:       PUT(UInt32, 0);
                case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice: PUT(UInt32, 0);
                case kAudioDevicePropertyLatency:           PUT(UInt32, 0);
                case kAudioObjectPropertyOwnedObjects:
                case kAudioDevicePropertyStreams: {
                    AudioObjectID ids[1];
                    UInt32 n = 0;
                    if (addr->mScope != kAudioObjectPropertyScopeInput) {
                        ids[n++] = kObjectID_Stream_Output;
                    }
                    UInt32 fit = inDataSize / (UInt32)sizeof(AudioObjectID);
                    if (fit > n) fit = n;
                    for (UInt32 i = 0; i < fit; i++) ((AudioObjectID *)outData)[i] = ids[i];
                    *outDataSize = fit * (UInt32)sizeof(AudioObjectID);
                    return noErr;
                }
                case kAudioDevicePropertySafetyOffset:      PUT(UInt32, 512);
                case kAudioDevicePropertyNominalSampleRate: PUT(Float64, kSampleRate);
                case kAudioDevicePropertyAvailableNominalSampleRates: {
                    if (inDataSize < sizeof(AudioValueRange)) { *outDataSize = 0; return noErr; }
                    AudioValueRange *r = (AudioValueRange *)outData;
                    r[0].mMinimum = kSampleRate;
                    r[0].mMaximum = kSampleRate;
                    *outDataSize = sizeof(AudioValueRange);
                    return noErr;
                }
                case kAudioDevicePropertyIsHidden:          PUT(UInt32, 0);
                case kAudioDevicePropertyZeroTimeStampPeriod: PUT(UInt32, kRingFrames);
                case kAudioDevicePropertyPreferredChannelsForStereo: {
                    if (inDataSize < 2 * sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
                    ((UInt32 *)outData)[0] = 1;
                    ((UInt32 *)outData)[1] = 2;
                    *outDataSize = 2 * sizeof(UInt32);
                    return noErr;
                }
                case kRouteStreamConfiguration: {
                    AudioBufferList *bl = (AudioBufferList *)outData;
                    if (addr->mScope == kAudioObjectPropertyScopeInput) {
                        size_t need = offsetof(AudioBufferList, mBuffers);
                        if (inDataSize < need) return kAudioHardwareBadPropertySizeError;
                        bl->mNumberBuffers = 0;
                        *outDataSize = (UInt32)need;
                        return noErr;
                    }
                    size_t need = offsetof(AudioBufferList, mBuffers) + sizeof(AudioBuffer);
                    if (inDataSize < need) return kAudioHardwareBadPropertySizeError;
                    bl->mNumberBuffers = 1;
                    bl->mBuffers[0].mNumberChannels = kChannelCount;
                    bl->mBuffers[0].mDataByteSize = 0;
                    bl->mBuffers[0].mData = NULL;
                    *outDataSize = (UInt32)need;
                    return noErr;
                }
                case kAudioObjectPropertyControlList:
                    *outDataSize = 0;
                    return noErr;
                case kRoutePreferredChannelLayout: {
                    size_t need = offsetof(AudioChannelLayout, mChannelDescriptions);
                    if (inDataSize < need) return kAudioHardwareBadPropertySizeError;
                    AudioChannelLayout *cl = (AudioChannelLayout *)outData;
                    cl->mChannelLayoutTag = kAudioChannelLayoutTag_Stereo;
                    cl->mChannelBitmap = 0;
                    cl->mNumberChannelDescriptions = 0;
                    *outDataSize = (UInt32)need;
                    return noErr;
                }
            }
            break;

        case kObjectID_Stream_Output:
            switch (addr->mSelector) {
                case kAudioObjectPropertyBaseClass: PUT(AudioClassID, kAudioObjectClassID);
                case kAudioObjectPropertyClass:     PUT(AudioClassID, kAudioStreamClassID);
                case kAudioObjectPropertyOwner:     PUT(AudioObjectID, kObjectID_Device);
                case kAudioStreamPropertyIsActive:  PUT(UInt32, atomic_load(&gStreamActive) ? 1 : 0);
                case kAudioStreamPropertyDirection:
                    PUT(UInt32, 0);
                case kAudioStreamPropertyTerminalType:
                    PUT(UInt32, kAudioStreamTerminalTypeSpeaker);
                case kAudioStreamPropertyStartingChannel: PUT(UInt32, 1);
                case kAudioStreamPropertyLatency:         PUT(UInt32, 0);
                case kAudioStreamPropertyVirtualFormat:
                case kAudioStreamPropertyPhysicalFormat:
                    PUT(AudioStreamBasicDescription, RouteFormat());
                case kAudioStreamPropertyAvailableVirtualFormats:
                case kAudioStreamPropertyAvailablePhysicalFormats: {
                    if (inDataSize < sizeof(AudioStreamRangedDescription)) { *outDataSize = 0; return noErr; }
                    AudioStreamRangedDescription *r = (AudioStreamRangedDescription *)outData;
                    r[0].mFormat = RouteFormat();
                    r[0].mSampleRateRange.mMinimum = kSampleRate;
                    r[0].mSampleRateRange.mMaximum = kSampleRate;
                    *outDataSize = sizeof(AudioStreamRangedDescription);
                    return noErr;
                }
            }
            break;
    }
    log_property("DATA-UNKNOWN", obj, addr);
    return kAudioHardwareUnknownPropertyError;
}

#undef PUT

static OSStatus AR_SetPropertyData(AudioServerPlugInDriverRef d, AudioObjectID obj,
                                   pid_t client, const AudioObjectPropertyAddress *addr,
                                   UInt32 qualSize, const void *qual,
                                   UInt32 inDataSize, const void *inData) {
    (void)client; (void)qualSize; (void)qual;
    if (d != gDriverRef) return kAudioHardwareBadObjectError;
    if (!addr) return kAudioHardwareIllegalOperationError;
    log_property("SET", obj, addr);

    if (obj == kObjectID_Stream_Output && addr->mSelector == kAudioStreamPropertyIsActive) {
        if (inDataSize != sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
        if (!inData) return kAudioHardwareIllegalOperationError;
        if (!gHost || !gHost->PropertiesChanged) return kAudioHardwareNotReadyError;
        bool active = *((const UInt32 *)inData) != 0;
        bool previous = atomic_exchange_explicit(&gStreamActive, active, memory_order_acq_rel);
        os_log(gLog, "Stream active requested=%d previous=%d", active, previous);
        if (active == previous) return noErr;

        // This is an AudioStream property, not a device layout/format change.
        // Notify after storing, outside any lock: the host can query it immediately.
        AudioObjectPropertyAddress changed = {kAudioStreamPropertyIsActive,
            kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
        OSStatus status = gHost->PropertiesChanged(gHost, obj, 1, &changed);
        if (status != noErr) {
            os_log_error(gLog, "Stream active notification failed: OSStatus=%d", (int)status);
        }
        return status;
    }
    if (obj == kObjectID_Device && addr->mSelector == kAudioDevicePropertyNominalSampleRate) {
        if (!inData || inDataSize < sizeof(Float64)) return kAudioHardwareBadPropertySizeError;
        Float64 want = *((const Float64 *)inData);
        if (want > kSampleRate - 1.0 && want < kSampleRate + 1.0) return noErr;
        return kAudioHardwareIllegalOperationError;
    }

    return kAudioHardwareUnknownPropertyError;
}

static OSStatus AR_StartIO(AudioServerPlugInDriverRef d, AudioObjectID dev, UInt32 client) {
    (void)d; (void)client;
    if (dev != kObjectID_Device) return kAudioHardwareBadObjectError;
    pthread_mutex_lock(&gStateMutex);
    if (gClients++ > 0) {
        UInt32 clients = gClients;
        pthread_mutex_unlock(&gStateMutex);
        os_log(gLog, "StartIO additional client: clients=%u streamActive=%d", clients, atomic_load(&gStreamActive));
        return noErr;
    }
    gIORunning = true;
    gTimelineSeed++;
    gAnchorHostTime = 0;
    gZeroSampleTime = 0;
    gZeroHostTime = 0;
    gPeriodCount = 0;
    pthread_mutex_unlock(&gStateMutex);
    os_log(gLog, "StartIO clients=1 streamActive=%d", atomic_load(&gStreamActive));
    return noErr;
}

static OSStatus AR_StopIO(AudioServerPlugInDriverRef d, AudioObjectID dev, UInt32 client) {
    (void)d; (void)client;
    if (dev != kObjectID_Device) return kAudioHardwareBadObjectError;
    pthread_mutex_lock(&gStateMutex);
    if (gClients > 0) gClients--;
    gIORunning = gClients > 0;
    UInt32 clients = gClients;
    pthread_mutex_unlock(&gStateMutex);
    os_log(gLog, "StopIO frames=%llu clients=%u streamActive=%d", (unsigned long long)gIOCount,
           clients, atomic_load(&gStreamActive));
    return noErr;
}

static OSStatus AR_GetZeroTimeStamp(AudioServerPlugInDriverRef d, AudioObjectID dev,
                                    UInt32 client, Float64 *outSampleTime,
                                    UInt64 *outHostTime, UInt64 *outSeed) {
    (void)d; (void)client;
    if (dev != kObjectID_Device) return kAudioHardwareBadObjectError;

    const Float64 hostTicksPerFrame = gHostTicksPerFrame;
    const Float64 hostTicksPerRing = hostTicksPerFrame * (Float64)kRingFrames;

    UInt64 now = mach_absolute_time();

    if (gAnchorHostTime == 0) {
        gAnchorHostTime = now;
        gPeriodCount = 0;
    }
    gPeriodCount = (UInt64)((Float64)(now - gAnchorHostTime) / hostTicksPerRing);
    Float64 st = (Float64)(gPeriodCount * (UInt64)kRingFrames);
    UInt64 ht = gAnchorHostTime + (UInt64)(((Float64)gPeriodCount) * hostTicksPerRing);
    gZeroSampleTime = st;
    gZeroHostTime = ht;

    if (outSampleTime) *outSampleTime = st;
    if (outHostTime)   *outHostTime   = ht;
    if (outSeed)       *outSeed       = gTimelineSeed;
    return noErr;
}

static OSStatus AR_WillDoIOOperation(AudioServerPlugInDriverRef d, AudioObjectID dev,
                                     UInt32 client, UInt32 op,
                                     Boolean *outWillDo, Boolean *outWillDoInPlace) {
    (void)d; (void)client;
    if (dev != kObjectID_Device) return kAudioHardwareBadObjectError;
    Boolean will = false, inPlace = true;
    switch (op) {
        case kAudioServerPlugInIOOperationWriteMix:
            will = true;
            break;
        default:
            will = false;
            break;
    }
    if (outWillDo) *outWillDo = will;
    if (outWillDoInPlace) *outWillDoInPlace = inPlace;
    return noErr;
}

static OSStatus AR_BeginIOOperation(AudioServerPlugInDriverRef d, AudioObjectID dev,
                                    UInt32 client, UInt32 op, UInt32 frames,
                                    const AudioServerPlugInIOCycleInfo *cycle) {
    (void)d; (void)dev; (void)client; (void)op; (void)frames; (void)cycle;
    return noErr;
}

static OSStatus AR_DoIOOperation(AudioServerPlugInDriverRef d, AudioObjectID dev,
                                 AudioObjectID stream, UInt32 client, UInt32 op,
                                 UInt32 frames, const AudioServerPlugInIOCycleInfo *cycle,
                                 void *ioMainBuffer, void *ioSecondaryBuffer) {
    (void)d; (void)stream; (void)client; (void)ioSecondaryBuffer;
    if (dev != kObjectID_Device) return kAudioHardwareBadObjectError;
    if (!ioMainBuffer || frames == 0) return noErr;

    if (op != kAudioServerPlugInIOOperationWriteMix) return noErr;

    gIOCount += frames;

    if (atomic_load_explicit(&gCapture, memory_order_acquire) &&
        atomic_load_explicit(&gStreamActive, memory_order_acquire) &&
        ar_registration_ready(&gRegistration)) {
        ar_link_push(gSender, ioMainBuffer, frames);
    }
    return noErr;
}

static OSStatus AR_EndIOOperation(AudioServerPlugInDriverRef d, AudioObjectID dev,
                                  UInt32 client, UInt32 op, UInt32 frames,
                                  const AudioServerPlugInIOCycleInfo *cycle) {
    (void)d; (void)dev; (void)client; (void)op; (void)frames; (void)cycle;
    return noErr;
}

static void FillInterfaceOnce(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gInterface._reserved                        = NULL;
        gInterface.QueryInterface                   = AR_QueryInterface;
        gInterface.AddRef                           = AR_AddRef;
        gInterface.Release                          = AR_Release;
        gInterface.Initialize                       = AR_Initialize;
        gInterface.CreateDevice                     = AR_CreateDevice;
        gInterface.DestroyDevice                    = AR_DestroyDevice;
        gInterface.AddDeviceClient                  = AR_AddDeviceClient;
        gInterface.RemoveDeviceClient               = AR_RemoveDeviceClient;
        gInterface.PerformDeviceConfigurationChange = AR_PerformDeviceConfigurationChange;
        gInterface.AbortDeviceConfigurationChange   = AR_AbortDeviceConfigurationChange;
        gInterface.HasProperty                      = AR_HasProperty;
        gInterface.IsPropertySettable               = AR_IsPropertySettable;
        gInterface.GetPropertyDataSize              = AR_GetPropertyDataSize;
        gInterface.GetPropertyData                  = AR_GetPropertyData;
        gInterface.SetPropertyData                  = AR_SetPropertyData;
        gInterface.StartIO                          = AR_StartIO;
        gInterface.StopIO                           = AR_StopIO;
        gInterface.GetZeroTimeStamp                 = AR_GetZeroTimeStamp;
        gInterface.WillDoIOOperation                = AR_WillDoIOOperation;
        gInterface.BeginIOOperation                 = AR_BeginIOOperation;
        gInterface.DoIOOperation                    = AR_DoIOOperation;
        gInterface.EndIOOperation                   = AR_EndIOOperation;
    });
}

static NSString *gReceiverIPv4 = @"127.0.0.1";
static int gSenderCreationError = ENOMEM;

// Withdraw the stopped HAL device before a later registration exposes it again.
// Keep the discoverable media endpoint and UID stable. Notify outside the lock:
// the host can reenter immediately to enumerate the now-empty device list.
static OSStatus AR_WithdrawDevice(void) {
    if (!atomic_exchange(&gDeviceExposed, false)) return noErr;
    pthread_mutex_lock(&gStateMutex);
    AudioServerPlugInHostRef host = gHost;
    pthread_mutex_unlock(&gStateMutex);
    if (!host) {
        os_log(gLog, "HAL withdrawal: no initialized host; device list is empty.");
        return noErr;
    }
    const AudioObjectPropertyAddress addresses[] = {
        {kAudioPlugInPropertyDeviceList, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain},
        {kAudioObjectPropertyOwnedObjects, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain},
    };
    // The host may immediately reenter property getters. Do not hold our lock.
    OSStatus result = host->PropertiesChanged(host, kObjectID_PlugIn, 2, addresses);
    if (result != noErr) {
        os_log_error(gLog, "HAL withdrawal notification failed: status=%d", (int)result);
    } else {
        os_log(gLog, "HAL withdrawal notified: device list is empty status=0");
    }
    return result;
}

@implementation ARRouteDriver

+ (ARRouteDriver *)shared {
    static ARRouteDriver *driver;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gLog = os_log_create("local.aural.route-probe", "driver");
        driver = [[ARRouteDriver alloc] init];
        id displayName = [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleDisplayName"];
        if ([displayName isKindOfClass:NSString.class] && [displayName length] > 0) {
            gDeviceDisplayName = [displayName copy];
        } else {
            os_log(gLog, "No bundle display name; using the standalone probe name.");
        }
#if DEBUG
        id configured = [NSBundle.mainBundle objectForInfoDictionaryKey:@"AuralDiagnosticReceiverIPv4"];
        if (configured && ![configured isKindOfClass:NSString.class]) {
            gSenderCreationError = EINVAL;
            os_log_error(gLog, "Invalid diagnostic endpoint configuration type.");
        } else {
            if ([configured length] > 0) gReceiverIPv4 = [configured copy];
            gSender = ar_link_create_sender_to_ipv4(gReceiverIPv4.UTF8String);
            gSenderCreationError = gSender ? 0 : errno;
        }
#else
        gSender = ar_link_create(true);
        gSenderCreationError = gSender ? 0 : ENOMEM;
#endif
        os_log(gLog, "Receiver endpoint: %{public}@:%d creation errno=%d", gReceiverIPv4, ARPort, gSenderCreationError);
        mach_timebase_info_data_t timebase;
        mach_timebase_info(&timebase);
        gHostTicksPerFrame = 1e9 / kSampleRate * timebase.denom / timebase.numer;
        FillInterfaceOnce();
    });
    return driver;
}
- (uint64_t)framesDelivered { return atomic_load(&gIOCount); }
- (BOOL)registered { return ar_registration_ready(&gRegistration); }
- (ARLinkStats)transportStats { return gSender ? ar_link_stats(gSender) : (ARLinkStats){.error = gSenderCreationError}; }
- (NSString *)receiverIPv4 { return gReceiverIPv4; }
- (NSString *)deviceDisplayName { return gDeviceDisplayName; }

- (OSStatus)publishWithDeviceUID:(NSString *)uid {
    if (!gSender) return gSenderCreationError == ENOMEM ? kAudio_MemFullError : kAudioHardwareIllegalOperationError;
    if (gDeviceUID) {
        // Never replace a UID while the audio server may be reading it.
        if (!CFEqual(gDeviceUID, (__bridge CFStringRef)uid)) return kAudioHardwareIllegalOperationError;
    } else {
        gDeviceUID = CFBridgingRetain([uid copy]);
    }
    // Registration must expose exactly one device. Initialize's host scans the
    // object graph; preserve both the stable UID and local object IDs.
    if (!atomic_exchange(&gDeviceExposed, true)) {
        os_log(gLog, "Restoring HAL device list for registration.");
    }
    // Publish for each real-time delivery start, even when iOS retains this process.
    // Keep generation and readiness in one atomic so an older callback cannot
    // invalidate a new publication or race a successful API return.
    uint64_t token = ar_registration_begin(&gRegistration);
#if TARGET_OS_IOS
    OSStatus result = AudioServerPlugInRegisterMediaDeviceExtension(gDriverRef, ^{
        if (ar_registration_interrupt(&gRegistration, token)) {
            os_log_error(gLog, "Audio server invalidated route publication %llu.", (unsigned long long)(token / 4));
        }
    });
#else
    // Allows syntax checking the shared HAL implementation with Command Line Tools.
    // This path never substitutes for an iPhone build or a device routing test.
    OSStatus result = kAudioHardwareUnsupportedOperationError;
#endif
    if (!ar_registration_finish(&gRegistration, token, result == noErr) && result == noErr) {
        result = kAudioHardwareNotRunningError;
    }
    os_log(gLog, "Publish route driver: generation=%llu status=%d", (unsigned long long)(token / 4), (int)result);
    return result;
}
- (int)prepareTransport {
    if (!gSender) return gSenderCreationError;
    return ar_link_start(gSender);
}
- (int)startCapture {
    if (!gSender) return gSenderCreationError;
    if (!ar_registration_ready(&gRegistration)) {
        os_log_error(gLog, "Cannot capture without a ready route publication.");
        return ENODEV;
    }
    if (!ar_link_stats(gSender).connected) {
        os_log_error(gLog, "Cannot capture without a connected receiver.");
        return ENOTCONN;
    }
    atomic_store_explicit(&gCapture, true, memory_order_release);
    return 0;
}
- (void)stopCapture {
    atomic_store_explicit(&gCapture, false, memory_order_release);
    if (gSender) ar_link_stop(gSender);
    AR_WithdrawDevice(); // A failure is explicitly logged; it is not a confirmed withdrawal.
}
@end
