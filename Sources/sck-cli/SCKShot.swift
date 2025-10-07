import Foundation
@preconcurrency import ScreenCaptureKit
import ArgumentParser
import Darwin
import Dispatch
import CoreMedia

@available(macOS 10.15, macCatalyst 13, iOS 13, tvOS 13, watchOS 6, *)
@main
struct SCKShot: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sck-cli",
        abstract: "Capture video and audio using ScreenCaptureKit",
        discussion: """
        Captures screen video at a specified frame rate and optionally records system audio and microphone input.
        Requires an output filename. Specify duration with --length in seconds.
        """
    )

    @Argument(help: "Output base filename (e.g., 'capture' creates capture.mov and capture.m4a)")
    var outputBase: String

    @Option(name: [.customShort("r"), .long], help: "Frame rate in Hz (frames per second)")
    var frameRate: Double = 1.0

    @Option(name: [.customShort("l"), .long], help: "Capture duration in seconds")
    var length: Double?

    @Flag(name: .long, inversion: .prefixedNo, help: "Enable audio capture (system audio and microphone)")
    var audio: Bool = true

    func run() async throws {
        let captureDuration = length

        // Check for existing output files
        let videoPath = "\(outputBase).mov"
        let audioPath = "\(outputBase).m4a"
        if FileManager.default.fileExists(atPath: videoPath) {
            fputs("Error: \(videoPath) already exists\n", stderr)
            Darwin.exit(1)
        }
        if audio && FileManager.default.fileExists(atPath: audioPath) {
            fputs("Error: \(audioPath) already exists\n", stderr)
            Darwin.exit(1)
        }

        // Discover displays
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
              let display = content.displays.first else {
            fputs("No displays found\n", stderr)
            Darwin.exit(1)
        }

        // Build content filter for the chosen display
        let filter = SCContentFilter(display: display, excludingWindows: [])

        // Configure stream for video and audio capture
        let cfg = SCStreamConfiguration()
        cfg.width  = display.width
        cfg.height = display.height
        cfg.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange // NV12
        cfg.minimumFrameInterval = CMTimeMake(value: 1, timescale: Int32(frameRate))
        cfg.colorSpaceName = CGColorSpace.sRGB
        cfg.showsCursor = true
        cfg.scalesToFit = false  // Avoid resampling - use exact captured size
        cfg.sampleRate = 48_000
        cfg.channelCount = 1

        // Configure audio capture based on flag
        cfg.capturesAudio = audio
        if #available(macOS 15.0, *), audio {
            cfg.captureMicrophone = true
            cfg.microphoneCaptureDeviceID = nil  // nil uses default microphone
        }

        // Create stream and output handler
        let stream = SCStream(filter: filter, configuration: cfg, delegate: nil)

        guard let out = StreamOutput.create(
            videoURL: URL(fileURLWithPath: "\(outputBase).mov"),
            audioURL: URL(fileURLWithPath: "\(outputBase).m4a"),
            width: display.width,
            height: display.height,
            frameRate: frameRate,
            duration: captureDuration,
            captureAudio: audio
        ) else {
            fputs("Failed to initialize output\n", stderr)
            Darwin.exit(1)
        }

        // Add stream outputs
        do {
            try stream.addStreamOutput(out, type: .screen, sampleHandlerQueue: .main)
            if audio {
                try stream.addStreamOutput(out, type: .audio, sampleHandlerQueue: .main)
            }
        } catch {
            fputs("Failed to add stream outputs: \(error)\n", stderr)
            Darwin.exit(1)
        }

        // Add microphone output for macOS 15.0+ if audio is enabled
        if #available(macOS 15.0, *), audio {
            do {
                try stream.addStreamOutput(out, type: .microphone, sampleHandlerQueue: .main)
                print("Both system audio and microphone capture enabled")
            } catch {
                fputs("Could not enable microphone capture: \(error)\n", stderr)
                Darwin.exit(1)
            }
        } else if audio {
            print("Microphone capture requires macOS 15.0 or later - system audio only")
        }

        // Start capture
        try? await stream.startCapture()

        // Print status message
        printStatusMessage(audio: audio, captureDuration: captureDuration, frameRate: frameRate)

        // Wait for capture to complete
        await waitForCompletion(audio: audio, captureDuration: captureDuration, output: out)

        _ = try? await stream.stopCapture()

        // Finish video writing
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            out.finishVideo { result in
                switch result {
                case .success(let url):
                    print("Video saved to \(url.path)")
                case .failure(let error):
                    fputs("Failed to finish video: \(error)\n", stderr)
                }
                cont.resume()
            }
        }

        Darwin.exit(0)
    }

    private func printStatusMessage(audio: Bool, captureDuration: Double?, frameRate: Double) {
        if audio {
            if let duration = captureDuration {
                if #available(macOS 15.0, *) {
                    print("Started capture - recording \(String(format: "%.1f", duration)) seconds at \(String(format: "%.1f", frameRate)) Hz with audio...")
                } else {
                    print("Started capture - recording \(String(format: "%.1f", duration)) seconds at \(String(format: "%.1f", frameRate)) Hz with system audio only...")
                }
            } else {
                print("Started capture - recording indefinitely at \(String(format: "%.1f", frameRate)) Hz with audio (Ctrl-C to stop)...")
            }
        } else {
            if let duration = captureDuration {
                print("Started capture - recording \(String(format: "%.1f", duration)) seconds at \(String(format: "%.1f", frameRate)) Hz...")
            } else {
                print("Started capture - indefinitely at \(String(format: "%.1f", frameRate)) Hz (Ctrl-C to stop)...")
            }
        }
    }

    private func waitForCompletion(audio: Bool, captureDuration: Double?, output: StreamOutput) async {
        if audio {
            // Audio-driven completion
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                DispatchQueue.global().async {
                    output.sema.wait()
                    cont.resume()
                }
            }
        } else if let duration = captureDuration {
            // Timer-driven completion for video-only
            try? await Task.sleep(for: .seconds(duration))
        } else {
            // Indefinite capture until user interrupts
            try? await Task.sleep(for: .seconds(Double.greatestFiniteMagnitude))
        }
    }
}