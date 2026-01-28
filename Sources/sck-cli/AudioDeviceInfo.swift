// SPDX-License-Identifier: MIT
// Copyright 2026 sol pbc

import Foundation
import CoreAudio

/// Metadata about an audio input device
struct AudioDeviceMetadata {
    let deviceName: String?
    let deviceUID: String?
    let manufacturer: String?
    let transportType: String?
}

/// Queries CoreAudio for default input device information
func getDefaultInputDeviceInfo() -> AudioDeviceMetadata? {
    // Get the default input device ID
    var deviceID = AudioDeviceID()
    var propertySize = UInt32(MemoryLayout<AudioDeviceID>.size)
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultInputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    let status = AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject),
        &address,
        0,
        nil,
        &propertySize,
        &deviceID
    )

    guard status == noErr, deviceID != kAudioDeviceUnknown else {
        return nil
    }

    // Query device properties
    let deviceName = getStringProperty(deviceID: deviceID, selector: kAudioDevicePropertyDeviceNameCFString)
    let deviceUID = getStringProperty(deviceID: deviceID, selector: kAudioDevicePropertyDeviceUID)
    let manufacturer = getStringProperty(deviceID: deviceID, selector: kAudioObjectPropertyManufacturer)
    let transportType = getTransportType(deviceID: deviceID)

    return AudioDeviceMetadata(
        deviceName: deviceName,
        deviceUID: deviceUID,
        manufacturer: manufacturer,
        transportType: transportType
    )
}

/// Gets a string property from an audio device
private func getStringProperty(deviceID: AudioDeviceID, selector: AudioObjectPropertySelector) -> String? {
    var address = AudioObjectPropertyAddress(
        mSelector: selector,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    var propertySize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    var value: Unmanaged<CFString>?

    let status = withUnsafeMutablePointer(to: &value) { ptr in
        AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &propertySize,
            ptr
        )
    }

    guard status == noErr, let unmanagedValue = value else {
        return nil
    }

    // CoreAudio returns a +1 reference, so we take ownership
    return unmanagedValue.takeRetainedValue() as String
}

/// Gets the transport type and converts to human-readable string
private func getTransportType(deviceID: AudioDeviceID) -> String? {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyTransportType,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    var propertySize = UInt32(MemoryLayout<UInt32>.size)
    var transportType: UInt32 = 0

    let status = AudioObjectGetPropertyData(
        deviceID,
        &address,
        0,
        nil,
        &propertySize,
        &transportType
    )

    guard status == noErr else {
        return nil
    }

    return transportTypeToString(transportType)
}

/// Converts transport type constant to human-readable string
private func transportTypeToString(_ type: UInt32) -> String {
    switch type {
    case kAudioDeviceTransportTypeBuiltIn:
        return "built-in"
    case kAudioDeviceTransportTypeUSB:
        return "usb"
    case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
        return "bluetooth"
    case kAudioDeviceTransportTypeFireWire:
        return "firewire"
    case kAudioDeviceTransportTypePCI:
        return "pci"
    case kAudioDeviceTransportTypeVirtual:
        return "virtual"
    case kAudioDeviceTransportTypeAggregate:
        return "aggregate"
    case kAudioDeviceTransportTypeAVB:
        return "avb"
    case kAudioDeviceTransportTypeThunderbolt:
        return "thunderbolt"
    case kAudioDeviceTransportTypeAirPlay:
        return "airplay"
    case kAudioDeviceTransportTypeHDMI:
        return "hdmi"
    case kAudioDeviceTransportTypeDisplayPort:
        return "displayport"
    case kAudioDeviceTransportTypeContinuityCaptureWired:
        return "continuity-wired"
    case kAudioDeviceTransportTypeContinuityCaptureWireless:
        return "continuity-wireless"
    default:
        // Return the FourCC code as string for unknown types
        let bytes = withUnsafeBytes(of: type.bigEndian) { Array($0) }
        if let str = String(bytes: bytes, encoding: .ascii), str.allSatisfy({ $0.isASCII && !$0.isWhitespace }) {
            return str.trimmingCharacters(in: .whitespaces).lowercased()
        }
        return "unknown"
    }
}
