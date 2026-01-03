// SPDX-License-Identifier: MIT
// Copyright 2026 sol pbc

import Foundation
@preconcurrency import ScreenCaptureKit
import CoreMedia
import CoreVideo

/// Handles video capture for a single display by implementing SCStreamOutput protocol
final class VideoStreamOutput: NSObject, SCStreamOutput, @unchecked Sendable {
    let displayID: CGDirectDisplayID
    private let videoWriter: VideoWriter
    private let verbose: Bool
    private let maskDetector: WindowMaskDetector?
    private let displayBounds: CGRect

    // Verbose logging state
    private var frameCount: Int = 0
    private var lastMaskLogTime: Date?
    private let logLock = NSLock()

    /// Creates a video stream output for a single display
    /// - Parameters:
    ///   - displayID: The display ID this output handles
    ///   - videoURL: Output URL for video file
    ///   - width: Video width in pixels
    ///   - height: Video height in pixels
    ///   - frameRate: Frame rate for video
    ///   - duration: Capture duration in seconds
    ///   - verbose: Enable verbose logging
    ///   - maskDetector: Optional detector for windows to mask
    ///   - displayBounds: The display's bounds in global screen coordinates
    /// - Returns: VideoStreamOutput instance, or nil if writer creation fails
    static func create(
        displayID: CGDirectDisplayID,
        videoURL: URL,
        width: Int,
        height: Int,
        frameRate: Double,
        duration: Double?,
        verbose: Bool,
        maskDetector: WindowMaskDetector? = nil,
        displayBounds: CGRect = .zero
    ) -> VideoStreamOutput? {
        let videoWriter: VideoWriter
        do {
            videoWriter = try VideoWriter.create(
                url: videoURL,
                width: width,
                height: height,
                frameRate: frameRate,
                duration: duration
            )
        } catch {
            Stderr.print("[ERROR] Failed to create video writer for display \(displayID): \(error)")
            return nil
        }

        return VideoStreamOutput(
            displayID: displayID,
            videoWriter: videoWriter,
            verbose: verbose,
            maskDetector: maskDetector,
            displayBounds: displayBounds
        )
    }

    private init(
        displayID: CGDirectDisplayID,
        videoWriter: VideoWriter,
        verbose: Bool,
        maskDetector: WindowMaskDetector?,
        displayBounds: CGRect
    ) {
        self.displayID = displayID
        self.videoWriter = videoWriter
        self.verbose = verbose
        self.maskDetector = maskDetector
        self.displayBounds = displayBounds
        super.init()
    }

    /// SCStreamOutput callback for handling captured video frames
    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of outputType: SCStreamOutputType) {
        guard outputType == .screen else { return }

        if verbose {
            logLock.lock()
            frameCount += 1
            let pts = CMSampleBufferGetPresentationTimeStamp(sb)
            let timestamp = CMTimeGetSeconds(pts)
            logLock.unlock()
            Stderr.print("[INFO] Display \(displayID) frame #\(frameCount) at \(String(format: "%.3f", timestamp))s")
        }

        // Detect and mask windows
        if let detector = maskDetector {
            let maskedWindows = detector.detectWindows()

            // Verbose logging (at most once per second)
            if verbose && !maskedWindows.isEmpty {
                logLock.lock()
                let now = Date()
                let shouldLog = lastMaskLogTime == nil || now.timeIntervalSince(lastMaskLogTime!) >= 1.0
                if shouldLog {
                    lastMaskLogTime = now
                    logLock.unlock()
                    for window in maskedWindows {
                        let regionCount = window.visibleRegions.count
                        Stderr.print("[INFO] Masking: \(window.ownerName) window \(window.windowID) (\(regionCount) visible region\(regionCount == 1 ? "" : "s"))")
                    }
                } else {
                    logLock.unlock()
                }
            }

            // Apply mask to pixel buffer
            if !maskedWindows.isEmpty, let pixelBuffer = CMSampleBufferGetImageBuffer(sb) {
                let allRegions = maskedWindows.flatMap { $0.visibleRegions }
                FrameMasker.applyMask(to: pixelBuffer, regions: allRegions, displayBounds: displayBounds)
            }
        }

        videoWriter.appendFrame(sb)
    }

    /// Finishes video writing
    /// - Parameter completion: Callback with result (URL and frame count on success)
    func finish(completion: @escaping @Sendable (Result<(URL, Int), Error>) -> Void) {
        videoWriter.finish(completion: completion)
    }
}

/// Handles audio capture (system audio + microphone) by implementing SCStreamOutput protocol
final class AudioStreamOutput: NSObject, SCStreamOutput, @unchecked Sendable {
    let sema = DispatchSemaphore(value: 0)
    private let audioWriter: AudioWriter
    private let verbose: Bool
    private var completed = false
    private let completedLock = NSLock()

    // Verbose logging state
    private var systemAudioBufferCount: Int = 0
    private var microphoneBufferCount: Int = 0
    private var lastAudioLogTime: Date?
    private let logLock = NSLock()

    /// Creates an audio stream output
    /// - Parameters:
    ///   - audioURL: Output URL for audio file
    ///   - duration: Capture duration in seconds
    ///   - verbose: Enable verbose logging
    /// - Returns: AudioStreamOutput instance, or nil if writer creation fails
    static func create(
        audioURL: URL,
        duration: Double?,
        verbose: Bool
    ) -> AudioStreamOutput? {
        let audioWriter: AudioWriter
        do {
            audioWriter = try AudioWriter.create(
                url: audioURL,
                duration: duration,
                verbose: verbose
            )
        } catch {
            Stderr.print("[ERROR] Failed to create audio writer: \(error)")
            return nil
        }

        let output = AudioStreamOutput(
            audioWriter: audioWriter,
            verbose: verbose
        )

        // Wire up completion callback
        audioWriter.onComplete = { [weak output] in
            output?.completedLock.lock()
            output?.completed = true
            output?.completedLock.unlock()
            output?.sema.signal()
        }

        return output
    }

    private init(
        audioWriter: AudioWriter,
        verbose: Bool
    ) {
        self.audioWriter = audioWriter
        self.verbose = verbose
        super.init()
    }

    /// SCStreamOutput callback for handling captured audio
    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of outputType: SCStreamOutputType) {
        switch outputType {
        case .audio:
            if verbose {
                logLock.lock()
                systemAudioBufferCount += 1
                logAudioBuffersIfNeeded()
                logLock.unlock()
            }
            audioWriter.appendSystemAudio(sb)

        case .microphone:
            if verbose {
                logLock.lock()
                microphoneBufferCount += 1
                logAudioBuffersIfNeeded()
                logLock.unlock()
            }
            audioWriter.appendMicrophone(sb)

        default:
            return
        }
    }

    /// Logs audio buffer counts every ~1 second (must be called with logLock held)
    private func logAudioBuffersIfNeeded() {
        let now = Date()
        if let lastLog = lastAudioLogTime {
            if now.timeIntervalSince(lastLog) >= 1.0 {
                Stderr.print("[INFO] Audio buffers in last ~1s: system=\(systemAudioBufferCount), mic=\(microphoneBufferCount)")
                systemAudioBufferCount = 0
                microphoneBufferCount = 0
                lastAudioLogTime = now
            }
        } else {
            lastAudioLogTime = now
        }
    }

    /// Finishes audio writing (for graceful shutdown)
    /// Returns true if finish was initiated, false if already completed
    func finish() -> Bool {
        completedLock.lock()
        let alreadyCompleted = completed
        completedLock.unlock()

        if alreadyCompleted {
            return false
        }

        audioWriter.finishAllTracks()
        return true
    }
}