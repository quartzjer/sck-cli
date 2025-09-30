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
    private let screenshotInterval: CFAbsoluteTime = 1.0 // 1 second = 1Hz
    private let captureDuration: Double = 10.0

    private let systemAudioWriter: AVAssetWriter
    private let systemAudioInput: AVAssetWriterInput
    private var systemAudioSessionStarted = false
    private var systemFirstAudioTime: CMTime?

    private let microphoneWriter: AVAssetWriter
    private let microphoneInput: AVAssetWriterInput
    private var microphoneSessionStarted = false
    private var microphoneFirstAudioTime: CMTime?

    private var systemAudioFinished = false
    private var microphoneFinished = false
    private var systemAudioBufferCount = 0
    private var microphoneBufferCount = 0
    private let finishLock = NSLock()

    private let ciContext = CIContext(options: nil)

    static func create() -> Output? {
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

        let systemWriter: AVAssetWriter
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

        let microphoneWriter: AVAssetWriter
        do {
            microphoneWriter = try AVAssetWriter(url: microphoneURL, fileType: .m4a)
        } catch {
            fputs("Failed to create microphone writer: \(error)\n", stderr)
            return nil
        }

        return Output(systemWriter: systemWriter, microphoneWriter: microphoneWriter)
    }

    private init(systemWriter: AVAssetWriter, microphoneWriter: AVAssetWriter) {
        // Use AAC format for M4A files
        let audioSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 128_000  // 128 kbps for good quality
        ]

        self.systemAudioWriter = systemWriter
        self.microphoneWriter = microphoneWriter

        // System audio input setup
        self.systemAudioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
        systemAudioInput.expectsMediaDataInRealTime = true
        if systemAudioWriter.canAdd(systemAudioInput) {
            systemAudioWriter.add(systemAudioInput)
        }

        // Microphone input setup
        self.microphoneInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
        microphoneInput.expectsMediaDataInRealTime = true
        if microphoneWriter.canAdd(microphoneInput) {
            microphoneWriter.add(microphoneInput)
        }

        super.init()

        systemAudioWriter.startWriting()
        microphoneWriter.startWriting()
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
            
            // Stop capturing after 10 seconds
            let totalElapsed = currentTime - captureStartTime
            if totalElapsed >= captureDuration {
                return
            }
            
            // Capture screenshot at 1Hz interval
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
        let currentTime = CMSampleBufferGetPresentationTimeStamp(sb)

        if isSystemAudio {
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

            if mediaElapsed < captureDuration {
                if systemAudioInput.isReadyForMoreMediaData {
                    let adjustedTime = CMTimeSubtract(currentTime, firstTime)
                    if let retimedBuffer = createRetimedSampleBuffer(sb, newTime: adjustedTime) {
                        systemAudioInput.append(retimedBuffer)
                        systemAudioBufferCount += 1
                    }
                }
            } else {
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
                        if self.systemAudioWriter.status == .failed {
                            print("System audio error: \(String(describing: self.systemAudioWriter.error))")
                        }
                        self.checkBothAudioFinished()
                    }
                }
            }
        } else {
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

            if mediaElapsed < captureDuration {
                if microphoneInput.isReadyForMoreMediaData {
                    let adjustedTime = CMTimeSubtract(currentTime, firstTime)
                    if let retimedBuffer = createRetimedSampleBuffer(sb, newTime: adjustedTime) {
                        microphoneInput.append(retimedBuffer)
                        microphoneBufferCount += 1
                    }
                }
            } else {
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
                        if self.microphoneWriter.status == .failed {
                            print("Microphone error: \(String(describing: self.microphoneWriter.error))")
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

@MainActor
@main
struct SCKShot: AsyncParsableCommand {

    func run() async throws {
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
        
        // Always capture both system audio and microphone
        cfg.capturesAudio = true
        if #available(macOS 15.0, *) {
            cfg.captureMicrophone = true
            cfg.microphoneCaptureDeviceID = nil  // nil uses default microphone
        }

        // 4) Create stream and a frame/audio receiver
        let stream = SCStream(filter: filter, configuration: cfg, delegate: nil)

        guard let out = Output.create() else {
            fputs("Failed to initialize audio writers\n", stderr)
            Darwin.exit(1)
        }

        do {
            try stream.addStreamOutput(out, type: .screen, sampleHandlerQueue: .main)
            try stream.addStreamOutput(out, type: .audio, sampleHandlerQueue: .main)
        } catch {
            fputs("Failed to add stream outputs: \(error)\n", stderr)
            Darwin.exit(1)
        }

        // Add microphone output for macOS 15.0+
        if #available(macOS 15.0, *) {
            do {
                try stream.addStreamOutput(out, type: .microphone, sampleHandlerQueue: .main)
                print("Both system audio and microphone capture enabled")
            } catch {
                fputs("Could not enable microphone capture: \(error)\n", stderr)
                Darwin.exit(1)
            }
        } else {
            print("Microphone capture requires macOS 15.0 or later - system audio only")
        }

        // 5) Start capture
        try? await stream.startCapture()
        if #available(macOS 15.0, *) {
            print("Started capture - recording 10 seconds of both system audio and microphone...")
        } else {
            print("Started capture - recording 10 seconds of system audio...")
        }

        // Wait for 10 seconds of audio capture
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async {
                out.sema.wait()
                cont.resume()
            }
        }

        _ = try? await stream.stopCapture()
        Darwin.exit(0)
    }
}
