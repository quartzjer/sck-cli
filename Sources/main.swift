import Foundation
@preconcurrency import ScreenCaptureKit
import CoreImage
import CoreImage.CIFilterBuiltins
import Metal
import CoreMedia
import CoreVideo
import Dispatch
import AVFoundation

final class Output: NSObject, SCStreamOutput, @unchecked Sendable {
    let sema = DispatchSemaphore(value: 0)
    var screenWritten = false
    
    private let audioWriter: AVAssetWriter
    private let audioInput: AVAssetWriterInput
    private var audioSessionStarted = false
    private var firstAudioTime: CMTime?
    private let audioDuration: Double = 10.0 // 10 seconds
    private var audioFinished = false
    private var audioBufferCount = 0

    override init() {
        // Save as M4A with AAC codec (widely supported, good compression)
        let audioURL = URL(fileURLWithPath: "audio.m4a")
        
        // Remove existing file if it exists
        if FileManager.default.fileExists(atPath: audioURL.path) {
            try? FileManager.default.removeItem(at: audioURL)
        }
        
        audioWriter = try! AVAssetWriter(url: audioURL, fileType: .m4a)
        
        // Use AAC format for M4A file
        let audioSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 128_000  // 128 kbps for good quality
        ]
        
        audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
        audioInput.expectsMediaDataInRealTime = true
        if audioWriter.canAdd(audioInput) {
            audioWriter.add(audioInput)
        }
        audioWriter.startWriting()
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
            guard !screenWritten, let imgBuf = sb.imageBuffer else { return }
            // Write PNG to disk (only once)
            let ci = CIImage(cvImageBuffer: imgBuf)
            let ctx = CIContext(options: nil)
            let url = URL(fileURLWithPath: "capture.png")
            if let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
               let data = ctx.pngRepresentation(of: ci, format: .BGRA8, colorSpace: colorSpace) {
                try? data.write(to: url)
                print("wrote \(url.path)")
            }
            screenWritten = true
        case .audio, .microphone:
            guard !audioFinished else { return }
            
            let currentTime = CMSampleBufferGetPresentationTimeStamp(sb)
            
            if !audioSessionStarted {
                // Start session at zero time and store first timestamp for retiming  
                audioWriter.startSession(atSourceTime: .zero)
                audioSessionStarted = true
                firstAudioTime = currentTime
                let source = outputType == .audio ? "system audio" : "microphone"
                print("Started \(source) recording at \(CMTimeGetSeconds(currentTime))")
            }
            
            guard !audioFinished, let firstTime = firstAudioTime else { return }
            let mediaElapsed = CMTimeGetSeconds(CMTimeSubtract(currentTime, firstTime))
            
            if mediaElapsed < audioDuration {
                if audioInput.isReadyForMoreMediaData {
                    // Create retimed sample buffer relative to zero
                    let adjustedTime = CMTimeSubtract(currentTime, firstTime)
                    if let retimedBuffer = createRetimedSampleBuffer(sb, newTime: adjustedTime) {
                        audioInput.append(retimedBuffer)
                        audioBufferCount += 1
                    }
                }
                
                // Only print occasionally to reduce output noise  
                if Int(mediaElapsed) % 2 == 0 && Int(mediaElapsed * 10) % 10 == 0 {  // Every 2 seconds
                    print("Audio recording: \(String(format: "%.1f", mediaElapsed))/\(audioDuration) seconds")
                }
            } else if !audioFinished {
                // Reached duration based on media time, finish writing
                print("Media time: Finishing audio recording after \(String(format: "%.2f", mediaElapsed)) seconds")
                audioFinished = true
                audioInput.markAsFinished()
                audioWriter.finishWriting {
                    print("wrote audio.m4a (10 seconds)")
                    if self.audioWriter.status == .failed {
                        print("Error: \(String(describing: self.audioWriter.error))")
                    }
                    self.sema.signal()
                }
            }
        default:
            return
        }
    }
}

@MainActor
@main
struct SCKShot {
    // Keep strong reference to output to prevent garbage collection
    static var streamOutput: Output?
    
    static func main() async {
        // 1) Discover displays
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
              let display = content.displays.first else {
            fputs("No displays found\n", stderr); exit(1)
        }

        // 2) Build a content filter for the chosen display
        let filter = SCContentFilter(display: display, excludingWindows: [])

        // 3) Configure stream for screenshot and audio capture
        let cfg = SCStreamConfiguration()
        cfg.width  = display.width
        cfg.height = display.height
        cfg.pixelFormat = kCVPixelFormatType_32BGRA
        cfg.capturesAudio = true  // Capture system audio
        cfg.sampleRate = 48_000
        cfg.channelCount = 2
        
        // For macOS 15.0+, also enable microphone capture
        // Note: Disabled due to potential audio format conflicts when mixing sources
        // if #available(macOS 15.0, *) {
        //     cfg.captureMicrophone = true
        //     cfg.microphoneCaptureDeviceID = nil  // nil uses default microphone
        // }

        // 4) Create stream and a frame/audio receiver
        let stream = SCStream(filter: filter, configuration: cfg, delegate: nil)

        let out = Output()
        streamOutput = out  // Keep strong reference to prevent garbage collection
        
        try! stream.addStreamOutput(out, type: .screen, sampleHandlerQueue: .main)
        try! stream.addStreamOutput(out, type: .audio, sampleHandlerQueue: .main)
        
        // Add microphone output for macOS 15.0+ (disabled due to format conflicts)
        // if #available(macOS 15.0, *) {
        //     do {
        //         try stream.addStreamOutput(out, type: .microphone, sampleHandlerQueue: .main)
        //         print("Microphone capture enabled")
        //     } catch {
        //         print("Could not enable microphone capture: \(error)")
        //     }
        // }

        // 5) Start capture
        try? await stream.startCapture()
        print("Started capture - recording 10 seconds of audio...")

        // Wait for 10 seconds of audio capture
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async {
                out.sema.wait()
                cont.resume()
            }
        }

        _ = try? await stream.stopCapture()
        exit(0)
    }
}
