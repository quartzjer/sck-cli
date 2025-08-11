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
    
    private let audioDuration: Double = 10.0 // 10 seconds
    private var systemAudioFinished = false
    private var microphoneFinished = false
    private var systemAudioBufferCount = 0
    private var microphoneBufferCount = 0

    override init() {
        // System audio writer setup
        let systemAudioURL = URL(fileURLWithPath: "system_audio.m4a")
        if FileManager.default.fileExists(atPath: systemAudioURL.path) {
            try? FileManager.default.removeItem(at: systemAudioURL)
        }
        systemAudioWriter = try! AVAssetWriter(url: systemAudioURL, fileType: .m4a)
        
        // Microphone writer setup
        let microphoneURL = URL(fileURLWithPath: "microphone.m4a")
        if FileManager.default.fileExists(atPath: microphoneURL.path) {
            try? FileManager.default.removeItem(at: microphoneURL)
        }
        microphoneWriter = try! AVAssetWriter(url: microphoneURL, fileType: .m4a)
        
        // Use AAC format for M4A files
        let audioSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 128_000  // 128 kbps for good quality
        ]
        
        // System audio input setup
        systemAudioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
        systemAudioInput.expectsMediaDataInRealTime = true
        if systemAudioWriter.canAdd(systemAudioInput) {
            systemAudioWriter.add(systemAudioInput)
        }
        systemAudioWriter.startWriting()
        
        // Microphone input setup
        microphoneInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
        microphoneInput.expectsMediaDataInRealTime = true
        if microphoneWriter.canAdd(microphoneInput) {
            microphoneWriter.add(microphoneInput)
        }
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
                let ctx = CIContext(options: nil)
                let url = URL(fileURLWithPath: "capture_\(screenshotCount).png")
                
                if let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
                   let data = ctx.pngRepresentation(of: ci, format: .BGRA8, colorSpace: colorSpace) {
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
            guard !systemAudioFinished else { return }
            
            if !systemAudioSessionStarted {
                systemAudioWriter.startSession(atSourceTime: .zero)
                systemAudioSessionStarted = true
                systemFirstAudioTime = currentTime
                print("Started system audio recording at \(CMTimeGetSeconds(currentTime))")
            }
            
            guard let firstTime = systemFirstAudioTime else { return }
            let mediaElapsed = CMTimeGetSeconds(CMTimeSubtract(currentTime, firstTime))
            
            if mediaElapsed < audioDuration {
                if systemAudioInput.isReadyForMoreMediaData {
                    let adjustedTime = CMTimeSubtract(currentTime, firstTime)
                    if let retimedBuffer = createRetimedSampleBuffer(sb, newTime: adjustedTime) {
                        systemAudioInput.append(retimedBuffer)
                        systemAudioBufferCount += 1
                    }
                }
            } else if !systemAudioFinished {
                print("Finishing system audio recording after \(String(format: "%.2f", mediaElapsed)) seconds")
                systemAudioFinished = true
                systemAudioInput.markAsFinished()
                systemAudioWriter.finishWriting {
                    print("wrote system_audio.m4a (10 seconds)")
                    if self.systemAudioWriter.status == .failed {
                        print("System audio error: \(String(describing: self.systemAudioWriter.error))")
                    }
                    self.checkBothAudioFinished()
                }
            }
        } else {
            guard !microphoneFinished else { return }
            
            if !microphoneSessionStarted {
                microphoneWriter.startSession(atSourceTime: .zero)
                microphoneSessionStarted = true
                microphoneFirstAudioTime = currentTime
                print("Started microphone recording at \(CMTimeGetSeconds(currentTime))")
            }
            
            guard let firstTime = microphoneFirstAudioTime else { return }
            let mediaElapsed = CMTimeGetSeconds(CMTimeSubtract(currentTime, firstTime))
            
            if mediaElapsed < audioDuration {
                if microphoneInput.isReadyForMoreMediaData {
                    let adjustedTime = CMTimeSubtract(currentTime, firstTime)
                    if let retimedBuffer = createRetimedSampleBuffer(sb, newTime: adjustedTime) {
                        microphoneInput.append(retimedBuffer)
                        microphoneBufferCount += 1
                    }
                }
            } else if !microphoneFinished {
                print("Finishing microphone recording after \(String(format: "%.2f", mediaElapsed)) seconds")
                microphoneFinished = true
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
    
    private func checkBothAudioFinished() {
        if systemAudioFinished && microphoneFinished {
            sema.signal()
        }
    }
}

@MainActor
@main
struct SCKShot: AsyncParsableCommand {
    
    // Keep strong reference to output to prevent garbage collection
    static var streamOutput: Output?
    
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

        let out = Output()
        SCKShot.streamOutput = out  // Keep strong reference to prevent garbage collection
        
        try! stream.addStreamOutput(out, type: .screen, sampleHandlerQueue: .main)
        try! stream.addStreamOutput(out, type: .audio, sampleHandlerQueue: .main)
        
        // Add microphone output for macOS 15.0+
        if #available(macOS 15.0, *) {
            do {
                try stream.addStreamOutput(out, type: .microphone, sampleHandlerQueue: .main)
                print("Both system audio and microphone capture enabled")
            } catch {
                print("Could not enable microphone capture: \(error)")
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
