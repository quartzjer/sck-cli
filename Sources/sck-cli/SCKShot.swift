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

private func signalHandler(signal: Int32) {
    if signalReceived {
        // Second signal - restore default handler and re-raise for immediate termination
        Darwin.signal(signal, SIG_DFL)
        Darwin.raise(signal)
    } else {
        signalReceived = true
        fputs("\nReceived signal \(signal), shutting down gracefully (send again to force quit)...\n", stderr)
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

/// Holds all components for a single display's capture stream
struct DisplayCapture: @unchecked Sendable {
    let displayID: CGDirectDisplayID
    let stream: SCStream
    let videoOutput: VideoStreamOutput
    let delegate: StreamDelegate
}

/// Delegate to monitor SCStream lifecycle and errors - signals abort on any error
final class StreamDelegate: NSObject, SCStreamDelegate, @unchecked Sendable {
    private let verbose: Bool
    private let displayID: CGDirectDisplayID
    private let abortSemaphore: DispatchSemaphore

    init(verbose: Bool, displayID: CGDirectDisplayID, abortSemaphore: DispatchSemaphore) {
        self.verbose = verbose
        self.displayID = displayID
        self.abortSemaphore = abortSemaphore
        super.init()
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        let nsError = error as NSError

        // Check for "display unavailable" error (typically from sleep)
        if nsError.domain == "com.apple.ScreenCaptureKit.SCStreamErrorDomain" && nsError.code == -3815 {
            fputs("\n[INFO] Display \(displayID) became unavailable (system sleep?) - aborting capture...\n", stderr)
            if verbose {
                fputs("[VERBOSE] Display \(displayID) error -3815: Failed to find any displays or windows to capture\n", stderr)
            }
        } else {
            fputs("[ERROR] Display \(displayID) stream stopped with error: \(error)\n", stderr)
            if verbose {
                fputs("[VERBOSE] Display \(displayID) error details: \(error.localizedDescription)\n", stderr)
            }
        }
        // Signal abort for any stream error
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

    func run() async throws {
        let captureDuration = length

        // Discover all displays
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
              !content.displays.isEmpty else {
            fputs("No displays found\n", stderr)
            Darwin.exit(1)
        }

        let displays = content.displays
        fputs("Found \(displays.count) display(s)\n", stderr)

        // Build list of video paths for all displays
        var videoPaths: [CGDirectDisplayID: String] = [:]
        for display in displays {
            videoPaths[display.displayID] = "\(outputBase)_\(display.displayID).mov"
        }

        // Check for existing output files
        for (_, path) in videoPaths {
            if FileManager.default.fileExists(atPath: path) {
                fputs("Error: \(path) already exists\n", stderr)
                Darwin.exit(1)
            }
        }
        let audioPath = "\(outputBase).m4a"
        if audio && FileManager.default.fileExists(atPath: audioPath) {
            fputs("Error: \(audioPath) already exists\n", stderr)
            Darwin.exit(1)
        }

        // Output JSONL metadata to stdout
        outputJSONL(displays: displays, videoPaths: videoPaths, audioPath: audio ? audioPath : nil, frameRate: frameRate)

        // Shared abort semaphore - any stream error or signal triggers abort
        let abortSemaphore = DispatchSemaphore(value: 0)

        // Install signal handlers for graceful shutdown
        globalAbortSemaphore = abortSemaphore
        signal(SIGINT, signalHandler)
        signal(SIGTERM, signalHandler)

        // Create audio output (attached to first display's stream)
        var audioOutput: AudioStreamOutput? = nil
        if audio {
            guard let ao = AudioStreamOutput.create(
                audioURL: URL(fileURLWithPath: audioPath),
                duration: captureDuration,
                verbose: verbose
            ) else {
                fputs("Failed to initialize audio output\n", stderr)
                Darwin.exit(1)
            }
            audioOutput = ao
        }

        // Create capture pipeline for each display
        var captures: [DisplayCapture] = []

        for (index, display) in displays.enumerated() {
            let videoPath = videoPaths[display.displayID]!

            // Create video output for this display
            guard let videoOutput = VideoStreamOutput.create(
                displayID: display.displayID,
                videoURL: URL(fileURLWithPath: videoPath),
                width: display.width,
                height: display.height,
                frameRate: frameRate,
                duration: captureDuration,
                verbose: verbose
            ) else {
                fputs("Failed to initialize video output for display \(display.displayID)\n", stderr)
                Darwin.exit(1)
            }

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

            let delegate = StreamDelegate(verbose: verbose, displayID: display.displayID, abortSemaphore: abortSemaphore)
            let stream = SCStream(filter: filter, configuration: cfg, delegate: delegate)

            // Add stream outputs
            do {
                try stream.addStreamOutput(videoOutput, type: .screen, sampleHandlerQueue: .main)

                if captureAudioOnThisStream, let ao = audioOutput {
                    try stream.addStreamOutput(ao, type: .audio, sampleHandlerQueue: .main)
                    if #available(macOS 15.0, *) {
                        try stream.addStreamOutput(ao, type: .microphone, sampleHandlerQueue: .main)
                    }
                }
            } catch {
                fputs("Failed to add stream outputs for display \(display.displayID): \(error)\n", stderr)
                Darwin.exit(1)
            }

            captures.append(DisplayCapture(
                displayID: display.displayID,
                stream: stream,
                videoOutput: videoOutput,
                delegate: delegate
            ))

            fputs("  Display \(display.displayID): \(display.width)x\(display.height) → \(videoPath)\n", stderr)
        }

        // Start all streams
        for capture in captures {
            do {
                try await capture.stream.startCapture()
                if verbose {
                    fputs("[VERBOSE] Stream for display \(capture.displayID) started\n", stderr)
                }
            } catch {
                fputs("Failed to start capture for display \(capture.displayID): \(error)\n", stderr)
                Darwin.exit(1)
            }
        }

        // Print status message
        printStatusMessage(audio: audio, captureDuration: captureDuration, frameRate: frameRate, displayCount: displays.count)

        // Wait for capture to complete
        await waitForCompletion(audio: audio, captureDuration: captureDuration, audioOutput: audioOutput, abortSemaphore: abortSemaphore)

        // Stop all streams
        for capture in captures {
            _ = try? await capture.stream.stopCapture()
        }

        // Finish audio writer (for graceful shutdown on signal)
        if let ao = audioOutput {
            let needsWait = ao.finish()
            if needsWait {
                // Wait for audio completion
                await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                    DispatchQueue.global().async {
                        ao.sema.wait()
                        cont.resume()
                    }
                }
            }
        }

        // Finish all video writers
        for capture in captures {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                capture.videoOutput.finish { result in
                    switch result {
                    case .success(let url):
                        fputs("Video saved to \(url.path)\n", stderr)
                    case .failure(let error):
                        fputs("Failed to finish video for display \(capture.displayID): \(error)\n", stderr)
                    }
                    cont.resume()
                }
            }
        }

        Darwin.exit(0)
    }

    private func printStatusMessage(audio: Bool, captureDuration: Double?, frameRate: Double, displayCount: Int) {
        let displayText = displayCount == 1 ? "1 display" : "\(displayCount) displays"

        if audio {
            if let duration = captureDuration {
                if #available(macOS 15.0, *) {
                    fputs("Started capture - recording \(displayText) for \(String(format: "%.1f", duration)) seconds at \(String(format: "%.1f", frameRate)) Hz with audio...\n", stderr)
                } else {
                    fputs("Started capture - recording \(displayText) for \(String(format: "%.1f", duration)) seconds at \(String(format: "%.1f", frameRate)) Hz with system audio only...\n", stderr)
                }
            } else {
                fputs("Started capture - recording \(displayText) indefinitely at \(String(format: "%.1f", frameRate)) Hz with audio (Ctrl-C to stop)...\n", stderr)
            }
        } else {
            if let duration = captureDuration {
                fputs("Started capture - recording \(displayText) for \(String(format: "%.1f", duration)) seconds at \(String(format: "%.1f", frameRate)) Hz...\n", stderr)
            } else {
                fputs("Started capture - recording \(displayText) indefinitely at \(String(format: "%.1f", frameRate)) Hz (Ctrl-C to stop)...\n", stderr)
            }
        }
    }

    private func waitForCompletion(audio: Bool, captureDuration: Double?, audioOutput: AudioStreamOutput?, abortSemaphore: DispatchSemaphore) async {
        // Create a completion semaphore that can be signaled by any completion path
        let completionSema = DispatchSemaphore(value: 0)

        if audio, let ao = audioOutput {
            // Wait for either audio completion or abort signal
            DispatchQueue.global().async {
                ao.sema.wait()
                completionSema.signal()
            }
            DispatchQueue.global().async {
                abortSemaphore.wait()
                completionSema.signal()
            }

            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                DispatchQueue.global().async {
                    completionSema.wait()
                    cont.resume()
                }
            }
        } else if let duration = captureDuration {
            // Timer-driven completion for video-only, but also watch for abort
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                DispatchQueue.global().async {
                    _ = abortSemaphore.wait(timeout: .now() + duration)
                    cont.resume()
                }
            }
        } else {
            // Indefinite capture until user interrupts or abort
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                DispatchQueue.global().async {
                    abortSemaphore.wait()
                    cont.resume()
                }
            }
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
                print(json)
            }
        }

        // Output audio info if enabled
        if let audioPath = audioPath {
            let info = AudioInfo(
                type: "audio",
                tracks: [
                    AudioTrackInfo(name: "system"),
                    AudioTrackInfo(name: "microphone")
                ],
                sampleRate: 48000,
                channels: 1,
                filename: audioPath
            )
            if let data = try? encoder.encode(info), let json = String(data: data, encoding: .utf8) {
                print(json)
            }
        }
    }
}