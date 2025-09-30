import Foundation
@preconcurrency import ScreenCaptureKit
import CoreMedia
import Dispatch

/// Coordinates screen and audio capture by implementing SCStreamOutput protocol
final class StreamOutput: NSObject, SCStreamOutput, @unchecked Sendable {
    let sema = DispatchSemaphore(value: 0)

    private let screenCapture: ScreenCapture
    private let audioWriter: AudioWriter?
    private let captureAudio: Bool

    /// Creates a stream output coordinator
    /// - Parameters:
    ///   - frameRate: Frame rate for screenshots
    ///   - frames: Number of frames to capture
    ///   - duration: Capture duration in seconds
    ///   - captureAudio: Whether to capture audio
    /// - Returns: StreamOutput instance, or nil if audio writer creation fails
    static func create(
        frameRate: Double,
        frames: Int,
        duration: Double?,
        captureAudio: Bool
    ) -> StreamOutput? {
        var writer: AudioWriter? = nil

        if captureAudio {
            do {
                writer = try AudioWriter.create(
                    url: URL(fileURLWithPath: "audio.m4a"),
                    duration: duration
                )
            } catch {
                fputs("Failed to create audio writer: \(error)\n", stderr)
                return nil
            }
        }

        let output = StreamOutput(
            frameRate: frameRate,
            frames: frames,
            duration: duration,
            captureAudio: captureAudio,
            audioWriter: writer
        )

        // Wire up completion callback
        writer?.onComplete = { [weak output] in
            output?.sema.signal()
        }

        return output
    }

    private init(
        frameRate: Double,
        frames: Int,
        duration: Double?,
        captureAudio: Bool,
        audioWriter: AudioWriter?
    ) {
        self.screenCapture = ScreenCapture(frameRate: frameRate, frames: frames, duration: duration)
        self.captureAudio = captureAudio
        self.audioWriter = audioWriter
        super.init()
    }

    /// SCStreamOutput callback for handling captured frames and audio
    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of outputType: SCStreamOutputType) {
        switch outputType {
        case .screen:
            guard let imgBuf = sb.imageBuffer else { return }
            screenCapture.captureFrame(imgBuf)

        case .audio:
            audioWriter?.appendSystemAudio(sb)

        case .microphone:
            audioWriter?.appendMicrophone(sb)

        default:
            return
        }
    }
}