import Foundation
@preconcurrency import ScreenCaptureKit
import CoreImage
import CoreImage.CIFilterBuiltins
import Metal
import CoreMedia
import CoreVideo
import Dispatch
import AVFoundation
import ArgumentParser
import Darwin

final class Output: NSObject, SCStreamOutput, @unchecked Sendable {
    let sema = DispatchSemaphore(value: 0)
    private var screenshotCount = 0
    private var lastScreenshotTime: CFAbsoluteTime = 0
    private var captureStartTime: CFAbsoluteTime = 0
    private let screenshotInterval: CFAbsoluteTime
    private let maxFrames: Int // 0 means indefinite
    private let captureDuration: Double? // nil means use frame count

    private let systemAudioWriter: AVAssetWriter?
    private let systemAudioInput: AVAssetWriterInput?
    private var systemAudioSessionStarted = false
    private var systemFirstAudioTime: CMTime?

    private let microphoneWriter: AVAssetWriter?
    private let microphoneInput: AVAssetWriterInput?
    private var microphoneSessionStarted = false
    private var microphoneFirstAudioTime: CMTime?

    private var systemAudioFinished = false
    private var microphoneFinished = false
    private var systemAudioBufferCount = 0
    private var microphoneBufferCount = 0
    private let finishLock = NSLock()

    private let ciContext = CIContext(options: nil)
    private let captureAudio: Bool

    static func create(frameRate: Double, frames: Int, duration: Double?, captureAudio: Bool) -> Output? {
        var systemWriter: AVAssetWriter? = nil
        var microphoneWriter: AVAssetWriter? = nil

        if captureAudio {
            // System audio writer setup
            let systemAudioURL = URL(fileURLWithPath: "system_audio.m4a")
            if FileManager.default.fileExists(atPath: systemAudioURL.path) {
                do {
                    try FileManager.default.removeItem(at: systemAudioURL)
                } catch {
                    fputs("Failed to remove existing system_audio.m4a: \(error)\n", stderr)
                    return nil
                }
            }

            do {
                systemWriter = try AVAssetWriter(url: systemAudioURL, fileType: .m4a)
            } catch {
                fputs("Failed to create system audio writer: \(error)\n", stderr)
                return nil
            }

            // Microphone writer setup
            let microphoneURL = URL(fileURLWithPath: "microphone.m4a")
            if FileManager.default.fileExists(atPath: microphoneURL.path) {
                do {
                    try FileManager.default.removeItem(at: microphoneURL)
                } catch {
                    fputs("Failed to remove existing microphone.m4a: \(error)\n", stderr)
                    return nil
                }
            }

            do {
                microphoneWriter = try AVAssetWriter(url: microphoneURL, fileType: .m4a)
            } catch {
                fputs("Failed to create microphone writer: \(error)\n", stderr)
                return nil
            }
        }

        return Output(
            frameRate: frameRate,
            frames: frames,
            duration: duration,
            captureAudio: captureAudio,
            systemWriter: systemWriter,
            microphoneWriter: microphoneWriter
        )
    }

    private init(
        frameRate: Double,
        frames: Int,
        duration: Double?,
        captureAudio: Bool,
        systemWriter: AVAssetWriter?,
        microphoneWriter: AVAssetWriter?
    ) {
        self.screenshotInterval = 1.0 / frameRate
        self.maxFrames = frames
        self.captureDuration = duration
        self.captureAudio = captureAudio
        self.systemAudioWriter = systemWriter
        self.microphoneWriter = microphoneWriter

        if captureAudio, let systemWriter = systemWriter, let microphoneWriter = microphoneWriter {
            // Use AAC format for M4A files
            let audioSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 128_000  // 128 kbps for good quality
            ]

            // System audio input setup
            let sysInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            sysInput.expectsMediaDataInRealTime = true
            if systemWriter.canAdd(sysInput) {
                systemWriter.add(sysInput)
            }
            self.systemAudioInput = sysInput

            // Microphone input setup
            let micInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            micInput.expectsMediaDataInRealTime = true
            if microphoneWriter.canAdd(micInput) {
                microphoneWriter.add(micInput)
            }
            self.microphoneInput = micInput

            super.init()

            systemWriter.startWriting()
            microphoneWriter.startWriting()
        } else {
            self.systemAudioInput = nil
            self.microphoneInput = nil
            super.init()
        }
    }
    
    private func createRetimedSampleBuffer(_ sampleBuffer: CMSampleBuffer, newTime: CMTime) -> CMSampleBuffer? {
        var newSampleBuffer: CMSampleBuffer?
        var timingInfo = CMSampleTimingInfo(
            duration: CMSampleBufferGetDuration(sampleBuffer),
            presentationTimeStamp: newTime,
            decodeTimeStamp: CMTime.invalid
        )
        
        let status = CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault,
            sampleBuffer: sampleBuffer,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timingInfo,
            sampleBufferOut: &newSampleBuffer
        )
        
        return status == noErr ? newSampleBuffer : nil
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of outputType: SCStreamOutputType) {
        switch outputType {
        case .screen:
            guard let imgBuf = sb.imageBuffer else { return }

            let currentTime = CFAbsoluteTimeGetCurrent()

            // Initialize timing on first screenshot
            if screenshotCount == 0 {
                captureStartTime = currentTime
                lastScreenshotTime = currentTime
            }

            // Check if we should stop based on duration or frame count
            let totalElapsed = currentTime - captureStartTime
            if let duration = captureDuration, totalElapsed >= duration {
                return
            }
            if maxFrames > 0 && screenshotCount >= maxFrames {
                return
            }

            // Capture screenshot at specified interval
            if screenshotCount == 0 || (currentTime - lastScreenshotTime) >= screenshotInterval {

                let ci = CIImage(cvImageBuffer: imgBuf)
                let url = URL(fileURLWithPath: "capture_\(screenshotCount).png")

                if let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
                   let data = ciContext.pngRepresentation(of: ci, format: .BGRA8, colorSpace: colorSpace) {
                    try? data.write(to: url)
                    print("wrote \(url.path)")
                }

                screenshotCount += 1
                lastScreenshotTime = currentTime
            }
        case .audio:
            handleAudioBuffer(sb, isSystemAudio: true)
        case .microphone:
            handleAudioBuffer(sb, isSystemAudio: false)
        default:
            return
        }
    }
    
    private func handleAudioBuffer(_ sb: CMSampleBuffer, isSystemAudio: Bool) {
        guard captureAudio else { return }
        let currentTime = CMSampleBufferGetPresentationTimeStamp(sb)

        if isSystemAudio {
            guard let systemAudioWriter = systemAudioWriter,
                  let systemAudioInput = systemAudioInput else { return }

            finishLock.lock()
            let finished = systemAudioFinished
            finishLock.unlock()
            guard !finished else { return }

            if !systemAudioSessionStarted {
                systemAudioWriter.startSession(atSourceTime: .zero)
                systemAudioSessionStarted = true
                systemFirstAudioTime = currentTime
                print("Started system audio recording at \(CMTimeGetSeconds(currentTime))")
            }

            guard let firstTime = systemFirstAudioTime else { return }
            let mediaElapsed = CMTimeGetSeconds(CMTimeSubtract(currentTime, firstTime))

            if let duration = captureDuration, mediaElapsed < duration {
                if systemAudioInput.isReadyForMoreMediaData {
                    let adjustedTime = CMTimeSubtract(currentTime, firstTime)
                    if let retimedBuffer = createRetimedSampleBuffer(sb, newTime: adjustedTime) {
                        systemAudioInput.append(retimedBuffer)
                        systemAudioBufferCount += 1
                    }
                }
            } else if captureDuration != nil {
                finishLock.lock()
                let alreadyFinished = systemAudioFinished
                if !alreadyFinished {
                    systemAudioFinished = true
                }
                finishLock.unlock()

                if !alreadyFinished {
                    print("Finishing system audio recording after \(String(format: "%.2f", mediaElapsed)) seconds")
                    systemAudioInput.markAsFinished()
                    systemAudioWriter.finishWriting {
                        print("wrote system_audio.m4a (10 seconds)")
                        if self.systemAudioWriter?.status == .failed {
                            print("System audio error: \(String(describing: self.systemAudioWriter?.error))")
                        }
                        self.checkBothAudioFinished()
                    }
                }
            }
        } else {
            guard let microphoneWriter = microphoneWriter,
                  let microphoneInput = microphoneInput else { return }

            finishLock.lock()
            let finished = microphoneFinished
            finishLock.unlock()
            guard !finished else { return }

            if !microphoneSessionStarted {
                microphoneWriter.startSession(atSourceTime: .zero)
                microphoneSessionStarted = true
                microphoneFirstAudioTime = currentTime
                print("Started microphone recording at \(CMTimeGetSeconds(currentTime))")
            }

            guard let firstTime = microphoneFirstAudioTime else { return }
            let mediaElapsed = CMTimeGetSeconds(CMTimeSubtract(currentTime, firstTime))

            if let duration = captureDuration, mediaElapsed < duration {
                if microphoneInput.isReadyForMoreMediaData {
                    let adjustedTime = CMTimeSubtract(currentTime, firstTime)
                    if let retimedBuffer = createRetimedSampleBuffer(sb, newTime: adjustedTime) {
                        microphoneInput.append(retimedBuffer)
                        microphoneBufferCount += 1
                    }
                }
            } else if captureDuration != nil {
                finishLock.lock()
                let alreadyFinished = microphoneFinished
                if !alreadyFinished {
                    microphoneFinished = true
                }
                finishLock.unlock()

                if !alreadyFinished {
                    print("Finishing microphone recording after \(String(format: "%.2f", mediaElapsed)) seconds")
                    microphoneInput.markAsFinished()
                    microphoneWriter.finishWriting {
                        print("wrote microphone.m4a (10 seconds)")
                        if self.microphoneWriter?.status == .failed {
                            print("Microphone error: \(String(describing: self.microphoneWriter?.error))")
                        }
                        self.checkBothAudioFinished()
                    }
                }
            }
        }
    }
    
    private func checkBothAudioFinished() {
        finishLock.lock()
        defer { finishLock.unlock() }

        if systemAudioFinished && microphoneFinished {
            sema.signal()
        }
    }
}

@main
struct SCKShot: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sck-cli",
        abstract: "Capture screenshots and audio using ScreenCaptureKit",
        discussion: """
        Captures screenshots at a specified frame rate and optionally records system audio and microphone input.
        By default, captures at 1 Hz for 10 seconds with audio enabled.
        """
    )

    @Option(name: [.customShort("r"), .long], help: "Frame rate in Hz (screenshots per second)")
    var frameRate: Double = 1.0

    @Option(name: [.customShort("n"), .long], help: "Number of frames to capture (0 for indefinite)")
    var frames: Int = 10

    @Option(name: [.customShort("d"), .long], help: "Duration in seconds (ignored if frames is non-zero)")
    var duration: Double?

    @Flag(name: .long, inversion: .prefixedNo, help: "Enable audio capture (system audio and microphone)")
    var audio: Bool = true

    func run() async throws {
        // Calculate capture duration from frames if not explicitly set
        let captureDuration: Double? = if frames > 0 {
            Double(frames) / frameRate
        } else {
            duration
        }

        // 1) Discover displays
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
              let display = content.displays.first else {
            fputs("No displays found\n", stderr); Darwin.exit(1)
        }

        // 2) Build a content filter for the chosen display
        let filter = SCContentFilter(display: display, excludingWindows: [])

        // 3) Configure stream for screenshot and audio capture
        let cfg = SCStreamConfiguration()
        cfg.width  = display.width
        cfg.height = display.height
        cfg.pixelFormat = kCVPixelFormatType_32BGRA
        cfg.sampleRate = 48_000
        cfg.channelCount = 2

        // Configure audio capture based on flag
        cfg.capturesAudio = audio
        if #available(macOS 15.0, *), audio {
            cfg.captureMicrophone = true
            cfg.microphoneCaptureDeviceID = nil  // nil uses default microphone
        }

        // 4) Create stream and a frame/audio receiver
        let stream = SCStream(filter: filter, configuration: cfg, delegate: nil)

        guard let out = Output.create(
            frameRate: frameRate,
            frames: frames,
            duration: captureDuration,
            captureAudio: audio
        ) else {
            fputs("Failed to initialize output\n", stderr)
            Darwin.exit(1)
        }

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

        // 5) Start capture
        try? await stream.startCapture()

        // Print status message
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
            if captureDuration != nil {
                print("Started capture - \(frames) frame(s) at \(String(format: "%.1f", frameRate)) Hz...")
            } else {
                print("Started capture - indefinite frames at \(String(format: "%.1f", frameRate)) Hz (Ctrl-C to stop)...")
            }
        }

        // Wait for capture to complete (audio determines completion if enabled)
        if audio {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                DispatchQueue.global().async {
                    out.sema.wait()
                    cont.resume()
                }
            }
        } else if let duration = captureDuration {
            // For video-only with duration, wait for the specified time
            try? await Task.sleep(for: .seconds(duration))
        } else {
            // For indefinite video-only capture, wait forever (user must Ctrl-C)
            try? await Task.sleep(for: .seconds(Double.greatestFiniteMagnitude))
        }

        _ = try? await stream.stopCapture()
        Darwin.exit(0)
    }
}
