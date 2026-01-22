// SPDX-License-Identifier: MIT
// Copyright 2026 sol pbc

import Foundation
@preconcurrency import ScreenCaptureKit
import ArgumentParser
import Darwin
import Dispatch
import CoreMedia
import CoreGraphics

// Global state for signal handling (must be accessible from C signal handler)
// These are intentionally global mutable state for async-signal-safe access
nonisolated(unsafe) private var globalAbortSemaphore: DispatchSemaphore?
nonisolated(unsafe) private var signalReceived = false
nonisolated(unsafe) private var receivedSignal: Int32 = 0
nonisolated(unsafe) private var streamErrorOccurred = false

// Restart configuration
private let maxRestarts = 10

private func signalHandler(signal: Int32) {
    if signalReceived {
        // Second signal - restore default handler and re-raise for immediate termination
        Darwin.signal(signal, SIG_DFL)
        Darwin.raise(signal)
    } else {
        signalReceived = true
        receivedSignal = signal
        Stderr.print("\n[INFO] Received signal \(signal), shutting down gracefully (send again to force quit)...")
        globalAbortSemaphore?.signal()
    }
}

/// JSONL output for a display source
struct DisplayInfo: Codable {
    let type: String
    let displayID: UInt32
    let width: Int
    let height: Int
    let x: Double
    let y: Double
    let frameRate: Double
    let filename: String
}

/// JSONL output for audio source
struct AudioInfo: Codable {
    let type: String
    let tracks: [AudioTrackInfo]
    let sampleRate: Int
    let channels: Int
    let filename: String
}

/// Audio track metadata
struct AudioTrackInfo: Codable {
    let name: String
}

/// Signals that can end or interrupt a capture session
enum CaptureSignal {
    case completion  // Duration elapsed or audio finished normally
    case abort       // Unrecoverable error occurred
    case restart     // Recoverable error (-3821), should restart streams
    case userSignal  // User interrupt (Ctrl-C)
}

/// Delegate to monitor SCStream lifecycle and errors - signals restart or abort depending on error type
final class StreamDelegate: NSObject, SCStreamDelegate, @unchecked Sendable {
    private let verbose: Bool
    private let displayID: CGDirectDisplayID
    private let abortSemaphore: DispatchSemaphore
    private let restartSemaphore: DispatchSemaphore

    init(verbose: Bool, displayID: CGDirectDisplayID, abortSemaphore: DispatchSemaphore, restartSemaphore: DispatchSemaphore) {
        self.verbose = verbose
        self.displayID = displayID
        self.abortSemaphore = abortSemaphore
        self.restartSemaphore = restartSemaphore
        super.init()
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        let nsError = error as NSError
        let domain = nsError.domain
        let code = nsError.code

        // Check for recoverable "system stopped stream" error (low disk space)
        // Error -3821: SCStreamErrorSystemStoppedStream
        if domain == "com.apple.ScreenCaptureKit.SCStreamErrorDomain" && code == -3821 {
            Stderr.print("\n[INFO] Display \(displayID) stream interrupted by system (low disk space?) - will restart...")
            if verbose {
                Stderr.print("[INFO] Display \(displayID) error -3821: System stopped the stream")
            }
            // Signal restart without marking as error - this is recoverable
            restartSemaphore.signal()
            return
        }

        // Check for "display unavailable" error (typically from sleep)
        if domain == "com.apple.ScreenCaptureKit.SCStreamErrorDomain" && code == -3815 {
            Stderr.print("\n[INFO] Display \(displayID) became unavailable (system sleep?) - aborting capture...")
            if verbose {
                Stderr.print("[INFO] Display \(displayID) error -3815: Failed to find any displays or windows to capture")
            }
        } else {
            Stderr.print("[ERROR] Display \(displayID) stream stopped with error: \(error)")
            if verbose {
                Stderr.print("[INFO] Display \(displayID) error details: \(error.localizedDescription)")
            }
        }
        // Mark that a stream error occurred and signal abort
        streamErrorOccurred = true
        abortSemaphore.signal()
    }
}

@main
struct SCKShot: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sck-cli",
        abstract: "Capture video and audio using ScreenCaptureKit",
        discussion: """
        Captures screen video from all displays at a specified frame rate and optionally records system audio and microphone input.
        Creates one video file per display: <output>_<displayID>.mov
        Creates one audio file: <output>.m4a
        """
    )

    @Argument(help: "Output base filename (e.g., 'capture' creates capture_<displayID>.mov and capture.m4a)")
    var outputBase: String

    @Option(name: [.customShort("r"), .long], help: "Frame rate in Hz (frames per second)")
    var frameRate: Double = 1.0

    @Option(name: [.customShort("l"), .long], help: "Capture duration in seconds")
    var length: Double?

    @Flag(name: .long, inversion: .prefixedNo, help: "Enable audio capture (system audio and microphone)")
    var audio: Bool = true

    @Flag(name: .shortAndLong, help: "Enable verbose logging")
    var verbose: Bool = false

    @Option(name: .long, parsing: .upToNextOption, help: "App name(s) to mask (can specify multiple times)")
    var mask: [String] = []

    func run() async throws {
        // Configure unbuffered I/O for immediate output visibility
        Stdout.setUnbuffered()
        Stderr.setUnbuffered()

        let captureDuration = length

        // Discover all displays
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
              !content.displays.isEmpty else {
            Stderr.print("[ERROR] No displays found")
            Darwin.exit(1)
        }

        let displays = content.displays
        Stderr.print("[INFO] Found \(displays.count) display(s)")

        // Create mask detector if apps specified
        let maskDetector: WindowMaskDetector? = mask.isEmpty ? nil : WindowMaskDetector(appNames: mask)
        if let detector = maskDetector {
            Stderr.print("[INFO] Masking enabled for apps: \(mask.joined(separator: ", "))")
            if verbose {
                let initialWindows = detector.detectWindows()
                for window in initialWindows {
                    let regionCount = window.visibleRegions.count
                    Stderr.print("[INFO] Found window to mask: \(window.ownerName) window \(window.windowID) (\(regionCount) visible region\(regionCount == 1 ? "" : "s"))")
                }
            }
        }

        // Build list of video paths for all displays
        var videoPaths: [CGDirectDisplayID: String] = [:]
        for display in displays {
            videoPaths[display.displayID] = "\(outputBase)_\(display.displayID).mov"
        }

        // Check for existing output files
        for (_, path) in videoPaths {
            if FileManager.default.fileExists(atPath: path) {
                Stderr.print("[ERROR] \(path) already exists")
                Darwin.exit(1)
            }
        }
        let audioPath = "\(outputBase).m4a"
        if audio && FileManager.default.fileExists(atPath: audioPath) {
            Stderr.print("[ERROR] \(audioPath) already exists")
            Darwin.exit(1)
        }

        // Output JSONL metadata to stdout
        outputJSONL(displays: displays, videoPaths: videoPaths, audioPath: audio ? audioPath : nil, frameRate: frameRate)

        // Install signal handlers for graceful shutdown
        signal(SIGINT, signalHandler)
        signal(SIGTERM, signalHandler)

        // Create audio output (attached to first display's stream) - created once, reused across restarts
        var audioOutput: AudioStreamOutput? = nil
        if audio {
            guard let ao = AudioStreamOutput.create(
                audioURL: URL(fileURLWithPath: audioPath),
                duration: captureDuration,
                verbose: verbose
            ) else {
                Stderr.print("[ERROR] Failed to initialize audio output")
                Darwin.exit(1)
            }
            audioOutput = ao
        }

        // Create video outputs for each display - created once, reused across restarts
        let sampleQueue = DispatchQueue(label: "com.sck-cli.samples", qos: .userInteractive)
        var videoOutputs: [VideoStreamOutput] = []

        for display in displays {
            let videoPath = videoPaths[display.displayID]!
            let displayBounds = CGDisplayBounds(display.displayID)
            guard let videoOutput = VideoStreamOutput.create(
                displayID: display.displayID,
                videoURL: URL(fileURLWithPath: videoPath),
                width: display.width,
                height: display.height,
                frameRate: frameRate,
                duration: captureDuration,
                verbose: verbose,
                maskDetector: maskDetector,
                displayBounds: displayBounds
            ) else {
                Stderr.print("[ERROR] Failed to initialize video output for display \(display.displayID)")
                Darwin.exit(1)
            }
            videoOutputs.append(videoOutput)
            Stderr.print("[INFO]   Display \(display.displayID): \(display.width)x\(display.height) → \(videoPath)")
        }

        // Main capture loop with restart support
        var restartCount = 0
        var currentStreams: [SCStream] = []

        captureLoop: while true {
            // Create fresh semaphores for each capture attempt
            let abortSemaphore = DispatchSemaphore(value: 0)
            let restartSemaphore = DispatchSemaphore(value: 0)
            globalAbortSemaphore = abortSemaphore

            // Create streams for all displays (reusing outputs)
            do {
                currentStreams = try createStreams(
                    displays: displays,
                    videoOutputs: videoOutputs,
                    audioOutput: audioOutput,
                    audio: audio,
                    sampleQueue: sampleQueue,
                    abortSemaphore: abortSemaphore,
                    restartSemaphore: restartSemaphore
                )
            } catch {
                Stderr.print("[ERROR] Failed to create streams: \(error)")
                streamErrorOccurred = true
                break captureLoop
            }

            // Start all streams
            for (index, stream) in currentStreams.enumerated() {
                do {
                    try await stream.startCapture()
                    if verbose {
                        Stderr.print("[INFO] Stream for display \(displays[index].displayID) started")
                    }
                } catch {
                    Stderr.print("[ERROR] Failed to start capture for display \(displays[index].displayID): \(error)")
                    streamErrorOccurred = true
                    break captureLoop
                }
            }

            // Print status message (only on first iteration)
            if restartCount == 0 {
                printStatusMessage(audio: audio, captureDuration: captureDuration, frameRate: frameRate, displayCount: displays.count)
            } else {
                Stderr.print("[INFO] Capture resumed (restart #\(restartCount))")
            }

            // Wait for a signal (completion, abort, restart, or user signal)
            let signal = await waitForSignal(
                audio: audio,
                captureDuration: captureDuration,
                audioOutput: audioOutput,
                abortSemaphore: abortSemaphore,
                restartSemaphore: restartSemaphore
            )

            // Stop all streams (may already be stopped due to error)
            for (index, stream) in currentStreams.enumerated() {
                do {
                    try await stream.stopCapture()
                    if verbose {
                        Stderr.print("[INFO] Stream for display \(displays[index].displayID) stopped")
                    }
                } catch {
                    if verbose {
                        Stderr.print("[INFO] Display \(displays[index].displayID) stopCapture: \(error.localizedDescription)")
                    }
                }
            }

            // Handle the signal
            switch signal {
            case .completion:
                // Normal completion - exit loop
                break captureLoop

            case .abort:
                // Unrecoverable error - exit loop
                break captureLoop

            case .userSignal:
                // User interrupted - exit loop
                break captureLoop

            case .restart:
                // Recoverable error - restart streams
                restartCount += 1
                if restartCount > maxRestarts {
                    Stderr.print("[ERROR] Too many restarts (\(maxRestarts)), giving up")
                    streamErrorOccurred = true
                    break captureLoop
                }
                // Brief delay to let system settle
                try await Task.sleep(nanoseconds: 100_000_000) // 100ms
                continue captureLoop
            }
        }

        // Finish audio writer (for graceful shutdown on signal)
        if let ao = audioOutput {
            let needsWait = ao.finish()
            if needsWait {
                // Wait for audio completion with timeout to prevent hanging
                let timedOut = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
                    DispatchQueue.global().async {
                        let result = ao.sema.wait(timeout: .now() + 5.0)
                        cont.resume(returning: result == .timedOut)
                    }
                }
                if timedOut {
                    Stderr.print("[WARNING] Audio finalization timed out after 5 seconds")
                }
            }
        }

        // Finish all video writers
        var videoWriteErrors: [CGDirectDisplayID] = []
        for (index, videoOutput) in videoOutputs.enumerated() {
            let displayID = displays[index].displayID
            let result: Result<(URL, Int), Error> = await withCheckedContinuation { cont in
                videoOutput.finish { result in
                    cont.resume(returning: result)
                }
            }
            switch result {
            case .success((let url, let frameCount)):
                Stderr.print("[INFO] Saved video to \(url.path) (\(frameCount) frames)")
            case .failure(let error):
                Stderr.print("[ERROR] Failed to finish video for display \(displayID): \(error)")
                videoWriteErrors.append(displayID)
            }
        }

        // Log restart summary if any occurred
        if restartCount > 0 {
            Stderr.print("[INFO] Completed with \(restartCount) restart(s) due to system interruptions")
        }

        // Determine exit code based on what happened
        let exitCode: Int32
        if streamErrorOccurred || !videoWriteErrors.isEmpty {
            // Stream error or video write failure
            exitCode = 1
        } else if signalReceived {
            // Signal-triggered shutdown: exit with 128 + signal number (Unix convention)
            exitCode = 128 + receivedSignal
        } else {
            // Normal completion (duration elapsed or audio finished) - even if restarts occurred
            exitCode = 0
        }
        Darwin.exit(exitCode)
    }

    /// Creates SCStream instances for all displays, reusing existing outputs
    /// Returns array of streams (matching order of displays/videoOutputs)
    private func createStreams(
        displays: [SCDisplay],
        videoOutputs: [VideoStreamOutput],
        audioOutput: AudioStreamOutput?,
        audio: Bool,
        sampleQueue: DispatchQueue,
        abortSemaphore: DispatchSemaphore,
        restartSemaphore: DispatchSemaphore
    ) throws -> [SCStream] {
        var streams: [SCStream] = []

        for (index, display) in displays.enumerated() {
            // Configure stream for this display
            let filter = SCContentFilter(display: display, excludingWindows: [])
            let cfg = SCStreamConfiguration()
            cfg.width = display.width
            cfg.height = display.height
            cfg.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange // NV12
            cfg.minimumFrameInterval = CMTimeMake(value: 1, timescale: Int32(frameRate))
            cfg.colorSpaceName = CGColorSpace.sRGB
            cfg.showsCursor = true
            cfg.scalesToFit = false
            cfg.sampleRate = 48_000
            cfg.channelCount = 1

            // Only capture audio on first display's stream
            let captureAudioOnThisStream = audio && index == 0
            cfg.capturesAudio = captureAudioOnThisStream
            if #available(macOS 15.0, *), captureAudioOnThisStream {
                cfg.captureMicrophone = true
                cfg.microphoneCaptureDeviceID = nil
            }

            let delegate = StreamDelegate(
                verbose: verbose,
                displayID: display.displayID,
                abortSemaphore: abortSemaphore,
                restartSemaphore: restartSemaphore
            )
            let stream = SCStream(filter: filter, configuration: cfg, delegate: delegate)

            // Add stream outputs (reuse existing)
            try stream.addStreamOutput(videoOutputs[index], type: .screen, sampleHandlerQueue: sampleQueue)

            if captureAudioOnThisStream, let ao = audioOutput {
                try stream.addStreamOutput(ao, type: .audio, sampleHandlerQueue: sampleQueue)
                if #available(macOS 15.0, *) {
                    try stream.addStreamOutput(ao, type: .microphone, sampleHandlerQueue: sampleQueue)
                }
            }

            streams.append(stream)
        }

        return streams
    }

    private func printStatusMessage(audio: Bool, captureDuration: Double?, frameRate: Double, displayCount: Int) {
        let displayText = displayCount == 1 ? "1 display" : "\(displayCount) displays"

        if audio {
            if let duration = captureDuration {
                if #available(macOS 15.0, *) {
                    Stderr.print("[INFO] Started capture - recording \(displayText) for \(String(format: "%.1f", duration)) seconds at \(String(format: "%.1f", frameRate)) Hz with audio...")
                } else {
                    Stderr.print("[INFO] Started capture - recording \(displayText) for \(String(format: "%.1f", duration)) seconds at \(String(format: "%.1f", frameRate)) Hz with system audio only...")
                }
            } else {
                Stderr.print("[INFO] Started capture - recording \(displayText) indefinitely at \(String(format: "%.1f", frameRate)) Hz with audio (Ctrl-C to stop)...")
            }
        } else {
            if let duration = captureDuration {
                Stderr.print("[INFO] Started capture - recording \(displayText) for \(String(format: "%.1f", duration)) seconds at \(String(format: "%.1f", frameRate)) Hz...")
            } else {
                Stderr.print("[INFO] Started capture - recording \(displayText) indefinitely at \(String(format: "%.1f", frameRate)) Hz (Ctrl-C to stop)...")
            }
        }
    }

    /// Waits for one of several capture-ending signals
    /// Returns which signal was received first
    private func waitForSignal(
        audio: Bool,
        captureDuration: Double?,
        audioOutput: AudioStreamOutput?,
        abortSemaphore: DispatchSemaphore,
        restartSemaphore: DispatchSemaphore
    ) async -> CaptureSignal {
        // Use a helper class to make the result-setting logic Sendable
        final class SignalResult: @unchecked Sendable {
            private let lock = NSLock()
            private var resultSet = false
            private let continuation: CheckedContinuation<CaptureSignal, Never>

            init(continuation: CheckedContinuation<CaptureSignal, Never>) {
                self.continuation = continuation
            }

            func setResult(_ signal: CaptureSignal) {
                lock.lock()
                if !resultSet {
                    resultSet = true
                    lock.unlock()
                    continuation.resume(returning: signal)
                } else {
                    lock.unlock()
                }
            }
        }

        return await withCheckedContinuation { (cont: CheckedContinuation<CaptureSignal, Never>) in
            let result = SignalResult(continuation: cont)

            // Watch for abort signal
            DispatchQueue.global().async {
                abortSemaphore.wait()
                // Check if this was triggered by user signal or error
                if signalReceived {
                    result.setResult(.userSignal)
                } else {
                    result.setResult(.abort)
                }
            }

            // Watch for restart signal
            DispatchQueue.global().async {
                restartSemaphore.wait()
                result.setResult(.restart)
            }

            // Watch for audio completion (if audio enabled)
            if audio, let ao = audioOutput {
                DispatchQueue.global().async {
                    ao.sema.wait()
                    result.setResult(.completion)
                }
            } else if let duration = captureDuration {
                // Timer-driven completion for video-only
                DispatchQueue.global().asyncAfter(deadline: .now() + duration) {
                    result.setResult(.completion)
                }
            }
            // If no audio and no duration, only abort/restart/signal can end capture
        }
    }

    /// Outputs JSONL to stdout for each display and audio source
    private func outputJSONL(displays: [SCDisplay], videoPaths: [CGDirectDisplayID: String], audioPath: String?, frameRate: Double) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys

        // Output one line per display
        for display in displays {
            let bounds = CGDisplayBounds(display.displayID)
            let info = DisplayInfo(
                type: "display",
                displayID: display.displayID,
                width: display.width,
                height: display.height,
                x: bounds.origin.x,
                y: bounds.origin.y,
                frameRate: frameRate,
                filename: videoPaths[display.displayID] ?? ""
            )
            if let data = try? encoder.encode(info), let json = String(data: data, encoding: .utf8) {
                Stdout.print(json)
            }
        }

        // Output audio info if enabled
        if let audioPath = audioPath {
            var tracks = [AudioTrackInfo(name: "system")]
            if #available(macOS 15.0, *) {
                tracks.append(AudioTrackInfo(name: "microphone"))
            }
            let info = AudioInfo(
                type: "audio",
                tracks: tracks,
                sampleRate: 48000,
                channels: 1,
                filename: audioPath
            )
            if let data = try? encoder.encode(info), let json = String(data: data, encoding: .utf8) {
                Stdout.print(json)
            }
        }
    }
}