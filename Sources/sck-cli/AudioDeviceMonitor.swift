// SPDX-License-Identifier: MIT
// Copyright 2026 sol pbc

import Foundation
import CoreAudio

/// Monitors CoreAudio for default device changes and signals when they occur
final class AudioDeviceMonitor: @unchecked Sendable {
    private let semaphore: DispatchSemaphore
    private let queue = DispatchQueue(label: "com.sck-cli.device-monitor")
    private let lock = NSLock()
    private var isMonitoring = false
    private var initialInputDeviceID: AudioDeviceID?
    private var initialOutputDeviceID: AudioDeviceID?
    private let verbose: Bool

    // Track which device changed for reporting
    private(set) var inputDeviceChanged = false
    private(set) var outputDeviceChanged = false

    init(semaphore: DispatchSemaphore, verbose: Bool = false) {
        self.semaphore = semaphore
        self.verbose = verbose
    }

    /// Starts monitoring for default input and output device changes
    /// Returns true if monitoring started successfully
    func start() -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard !isMonitoring else { return true }

        // Capture initial device IDs
        initialInputDeviceID = getDefaultDeviceID(forInput: true)
        initialOutputDeviceID = getDefaultDeviceID(forInput: false)

        if verbose {
            if let inputID = initialInputDeviceID {
                Stderr.print("[INFO] Monitoring input device ID: \(inputID)")
            }
            if let outputID = initialOutputDeviceID {
                Stderr.print("[INFO] Monitoring output device ID: \(outputID)")
            }
        }

        // Add listener for default input device changes
        var inputAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let inputStatus = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &inputAddress,
            queue,
            { [weak self] _, _ in
                self?.handleDeviceChange(isInput: true)
            }
        )

        if inputStatus != noErr {
            Stderr.print("[WARNING] Failed to add input device listener (status: \(inputStatus))")
            return false
        }

        // Add listener for default output device changes
        var outputAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let outputStatus = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &outputAddress,
            queue,
            { [weak self] _, _ in
                self?.handleDeviceChange(isInput: false)
            }
        )

        if outputStatus != noErr {
            Stderr.print("[WARNING] Failed to add output device listener (status: \(outputStatus))")
            // Remove input listener since we failed to add output
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &inputAddress,
                queue,
                { _, _ in }
            )
            return false
        }

        isMonitoring = true
        return true
    }

    /// Stops monitoring and removes listeners
    func stop() {
        lock.lock()
        defer { lock.unlock() }

        guard isMonitoring else { return }

        var inputAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var outputAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        // Remove listeners (ignore errors - we're cleaning up)
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &inputAddress,
            queue,
            { _, _ in }
        )

        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &outputAddress,
            queue,
            { _, _ in }
        )

        isMonitoring = false
    }

    private func handleDeviceChange(isInput: Bool) {
        lock.lock()

        // Check if device actually changed (not just a spurious notification)
        let currentID = getDefaultDeviceID(forInput: isInput)
        let initialID = isInput ? initialInputDeviceID : initialOutputDeviceID

        // Only trigger if the device ID actually changed
        if currentID == initialID {
            lock.unlock()
            return
        }

        // Mark which device changed
        if isInput {
            inputDeviceChanged = true
        } else {
            outputDeviceChanged = true
        }

        lock.unlock()

        let deviceType = isInput ? "input" : "output"
        Stderr.print("\n[INFO] Default \(deviceType) device changed, stopping capture...")

        if verbose {
            Stderr.print("[INFO] \(deviceType.capitalized) device ID changed from \(initialID ?? 0) to \(currentID ?? 0)")
        }

        // Signal the abort semaphore
        semaphore.signal()
    }

    private func getDefaultDeviceID(forInput: Bool) -> AudioDeviceID? {
        var deviceID = AudioDeviceID()
        var propertySize = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: forInput ? kAudioHardwarePropertyDefaultInputDevice : kAudioHardwarePropertyDefaultOutputDevice,
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

        return deviceID
    }

    deinit {
        stop()
    }
}
