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
    private let verbose: Bool

    // Verbose logging state
    private var frameCount: Int = 0
    private var systemAudioBufferCount: Int = 0
    private var microphoneBufferCount: Int = 0
    private var lastAudioLogTime: Date?
    private let logLock = NSLock()

    /// Creates a stream output coordinator
    /// - Parameters:
    ///   - videoURL: Output URL for video file
    ///   - audioURL: Output URL for audio file
    ///   - width: Video width in pixels
    ///   - height: Video height in pixels
    ///   - frameRate: Frame rate for video
    ///   - duration: Capture duration in seconds
    ///   - captureAudio: Whether to capture audio
    ///   - verbose: Enable verbose logging
    /// - Returns: StreamOutput instance, or nil if writer creation fails
    static func create(
        videoURL: URL,
        audioURL: URL,
        width: Int,
        height: Int,
        frameRate: Double,
        duration: Double?,
        captureAudio: Bool,
        verbose: Bool
    ) -> StreamOutput? {
        var audioWriter: AudioWriter? = nil

        if captureAudio {
            do {
                audioWriter = try AudioWriter.create(
                    url: audioURL,
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
            audioWriter: audioWriter,
            verbose: verbose
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
        audioWriter: AudioWriter?,
        verbose: Bool
    ) {
        self.videoWriter = videoWriter
        self.captureAudio = captureAudio
        self.audioWriter = audioWriter
        self.verbose = verbose
        super.init()
    }

    /// SCStreamOutput callback for handling captured frames and audio
    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of outputType: SCStreamOutputType) {
        switch outputType {
        case .screen:
            if verbose {
                logLock.lock()
                frameCount += 1
                let pts = CMSampleBufferGetPresentationTimeStamp(sb)
                let timestamp = CMTimeGetSeconds(pts)
                logLock.unlock()
                print("[VERBOSE] Frame #\(frameCount) received at \(String(format: "%.3f", timestamp))s")
            }
            videoWriter.appendFrame(sb)

        case .audio:
            if verbose {
                logLock.lock()
                systemAudioBufferCount += 1
                logAudioBuffersIfNeeded()
                logLock.unlock()
            }
            audioWriter?.appendSystemAudio(sb)

        case .microphone:
            if verbose {
                logLock.lock()
                microphoneBufferCount += 1
                logAudioBuffersIfNeeded()
                logLock.unlock()
            }
            audioWriter?.appendMicrophone(sb)

        default:
            return
        }
    }

    /// Logs audio buffer counts every ~1 second (must be called with logLock held)
    private func logAudioBuffersIfNeeded() {
        let now = Date()
        if let lastLog = lastAudioLogTime {
            if now.timeIntervalSince(lastLog) >= 1.0 {
                print("[VERBOSE] Audio buffers in last ~1s: system=\(systemAudioBufferCount), mic=\(microphoneBufferCount)")
                systemAudioBufferCount = 0
                microphoneBufferCount = 0
                lastAudioLogTime = now
            }
        } else {
            lastAudioLogTime = now
        }
    }

    /// Finishes video writing
    /// - Parameter completion: Callback with result
    func finishVideo(completion: @escaping (Result<URL, Error>) -> Void) {
        videoWriter.finish(completion: completion)
    }
}