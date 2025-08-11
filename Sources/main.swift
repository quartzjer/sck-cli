import Foundation
@preconcurrency import ScreenCaptureKit
import CoreImage
import CoreImage.CIFilterBuiltins
import Metal
import CoreMedia
import CoreVideo
import Dispatch
import AVFoundation

@main
struct SCKShot {
    static func main() async {
        // 1) Discover displays
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
              let display = content.displays.first else {
            fputs("No displays found\n", stderr); exit(1)
        }

        // 2) Build a content filter for the chosen display
        let filter = SCContentFilter(display: display, excludingWindows: [])

        // 3) Configure a 1-frame stream
        let cfg = SCStreamConfiguration()
        cfg.width  = display.width
        cfg.height = display.height
        cfg.pixelFormat = kCVPixelFormatType_32BGRA
        cfg.capturesAudio = true
        cfg.captureMicrophone = true
        cfg.sampleRate = 48_000
        cfg.channelCount = 2

        // 4) Create stream and a frame/audio receiver
        let stream = SCStream(filter: filter, configuration: cfg, delegate: nil)

        final class Output: NSObject, SCStreamOutput, @unchecked Sendable {
            let sema = DispatchSemaphore(value: 0)
            var screenWritten = false
            var audioWritten = false

            private let audioWriter: AVAssetWriter
            private let audioInput: AVAssetWriterInput
            private var audioSessionStarted = false

            override init() {
                let audioURL = URL(fileURLWithPath: "audio.m4a")
                audioWriter = try! AVAssetWriter(url: audioURL, fileType: .m4a)
                let audioSettings: [String: Any] = [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: 48_000,
                    AVNumberOfChannelsKey: 2
                ]
                audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
                audioInput.expectsMediaDataInRealTime = true
                if audioWriter.canAdd(audioInput) {
                    audioWriter.add(audioInput)
                }
                audioWriter.startWriting()
            }

            func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of outputType: SCStreamOutputType) {
                switch outputType {
                case .screen:
                    guard let imgBuf = sb.imageBuffer else { return }
                    // Write PNG to disk
                    let ci = CIImage(cvImageBuffer: imgBuf)
                    let ctx = CIContext(options: nil)
                    let url = URL(fileURLWithPath: "capture.png")
                    if let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
                       let data = ctx.pngRepresentation(of: ci, format: .BGRA8, colorSpace: colorSpace) {
                        try? data.write(to: url)
                        print("wrote \(url.path)")
                    }
                    screenWritten = true
                case .audio:
                    if !audioSessionStarted {
                        audioWriter.startSession(atSourceTime: CMSampleBufferGetPresentationTimeStamp(sb))
                        audioSessionStarted = true
                    }
                    if audioInput.isReadyForMoreMediaData {
                        audioInput.append(sb)
                        audioInput.markAsFinished()
                        audioWriter.finishWriting {
                            print("wrote audio.m4a")
                        }
                        audioWritten = true
                    }
                default:
                    return
                }
                if screenWritten && audioWritten {
                    sema.signal()
                }
            }
        }

        let out = Output()
        try! stream.addStreamOutput(out, type: .screen, sampleHandlerQueue: .main)
        try! stream.addStreamOutput(out, type: .audio, sampleHandlerQueue: .main)

        // 5) Start, await one frame and audio sample, then stop
        try? await stream.startCapture()

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
