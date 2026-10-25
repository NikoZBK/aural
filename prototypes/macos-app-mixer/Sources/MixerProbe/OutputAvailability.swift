import CoreAudio

// Bluetooth may stop the stream before DeviceIsAlive or the device list changes.
// This is only used while probing this exact saved output, never as a blanket
// rule for permissions, aggregate creation, or unrelated HAL operations.
func isTransientOutputRead(_ status: OSStatus) -> Bool {
    [kAudioHardwareBadDeviceError, kAudioHardwareBadObjectError, kAudioHardwareBadStreamError,
     kAudioHardwareUnknownPropertyError, kAudioHardwareNotReadyError, kAudioHardwareNotRunningError].contains(status)
}
