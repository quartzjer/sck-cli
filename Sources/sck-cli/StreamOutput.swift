import Foundation
@preconcurrency import ScreenCaptureKit
import CoreMedia
import Dispatch

/// Coordinates video and audio capture by implementing SCStreamOutput protocol
final class StreamOutput: NSObject, SCStreamOutput, @unchecked Sendable {
    let sema = DispatchSemaphore(value: 0)

    private let videoWriter: VideoWriter
    private let audioWriter: AudioWriter?
    private let captureAudio: Bool

    /// Creates a stream output coordinator
    /// - Parameters:
    ///   - videoURL: Output URL for video file
    ///   - width: Video width in pixels
    ///   - height: Video height in pixels
    ///   - frameRate: Frame rate for video
    ///   - duration: Capture duration in seconds
    ///   - captureAudio: Whether to capture audio
    /// - Returns: StreamOutput instance, or nil if writer creation fails
    static func create(
        videoURL: URL,
        width: Int,
        height: Int,
        frameRate: Double,
        duration: Double?,
        captureAudio: Bool
    ) -> StreamOutput? {
        var audioWriter: AudioWriter? = nil

        if captureAudio {
            do {
                audioWriter = try AudioWriter.create(
                    url: URL(fileURLWithPath: "audio.m4a"),
                    duration: duration
                )
            } catch {
                fputs("Failed to create audio writer: \(error)\n", stderr)
                return nil
            }
        }

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
            fputs("Failed to create video writer: \(error)\n", stderr)
            return nil
        }

        let output = StreamOutput(
            videoWriter: videoWriter,
            captureAudio: captureAudio,
            audioWriter: audioWriter
        )

        // Wire up completion callback
        audioWriter?.onComplete = { [weak output] in
            output?.sema.signal()
        }

        return output
    }

    private init(
        videoWriter: VideoWriter,
        captureAudio: Bool,
        audioWriter: AudioWriter?
    ) {
        self.videoWriter = videoWriter
        self.captureAudio = captureAudio
        self.audioWriter = audioWriter
        super.init()
    }

    /// SCStreamOutput callback for handling captured frames and audio
    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of outputType: SCStreamOutputType) {
        switch outputType {
        case .screen:
            videoWriter.appendFrame(sb)

        case .audio:
            audioWriter?.appendSystemAudio(sb)

        case .microphone:
            audioWriter?.appendMicrophone(sb)

        default:
            return
        }
    }

    /// Finishes video writing
    /// - Parameter completion: Callback with result
    func finishVideo(completion: @escaping (Result<URL, Error>) -> Void) {
        videoWriter.finish(completion: completion)
    }
}