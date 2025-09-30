import Foundation
@preconcurrency import ScreenCaptureKit
import CoreMedia
import Dispatch

/// Coordinates screen and audio capture by implementing SCStreamOutput protocol
final class StreamOutput: NSObject, SCStreamOutput, @unchecked Sendable {
    let sema = DispatchSemaphore(value: 0)

    private let screenCapture: ScreenCapture
    private let systemAudioWriter: AudioWriter?
    private let microphoneWriter: AudioWriter?

    private let finishLock = NSLock()
    private var systemAudioFinished = false
    private var microphoneFinished = false
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
        var systemWriter: AudioWriter? = nil
        var microphoneWriter: AudioWriter? = nil

        if captureAudio {
            do {
                systemWriter = try AudioWriter.create(
                    url: URL(fileURLWithPath: "system_audio.m4a"),
                    audioType: "system audio",
                    duration: duration
                )

                microphoneWriter = try AudioWriter.create(
                    url: URL(fileURLWithPath: "microphone.m4a"),
                    audioType: "microphone",
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
            systemWriter: systemWriter,
            microphoneWriter: microphoneWriter
        )

        // Wire up completion callbacks
        systemWriter?.onComplete = { [weak output] in
            output?.markSystemAudioFinished()
        }
        microphoneWriter?.onComplete = { [weak output] in
            output?.markMicrophoneFinished()
        }

        return output
    }

    private init(
        frameRate: Double,
        frames: Int,
        duration: Double?,
        captureAudio: Bool,
        systemWriter: AudioWriter?,
        microphoneWriter: AudioWriter?
    ) {
        self.screenCapture = ScreenCapture(frameRate: frameRate, frames: frames, duration: duration)
        self.captureAudio = captureAudio
        self.systemAudioWriter = systemWriter
        self.microphoneWriter = microphoneWriter
        super.init()
    }

    /// SCStreamOutput callback for handling captured frames and audio
    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of outputType: SCStreamOutputType) {
        switch outputType {
        case .screen:
            guard let imgBuf = sb.imageBuffer else { return }
            screenCapture.captureFrame(imgBuf)

        case .audio:
            systemAudioWriter?.append(sb)

        case .microphone:
            microphoneWriter?.append(sb)

        default:
            return
        }
    }

    /// Checks if both audio streams have finished and signals completion
    private func checkBothAudioFinished() {
        finishLock.lock()
        defer { finishLock.unlock() }

        if systemAudioFinished && microphoneFinished {
            sema.signal()
        }
    }

    /// Marks system audio as finished
    func markSystemAudioFinished() {
        finishLock.lock()
        systemAudioFinished = true
        finishLock.unlock()
        checkBothAudioFinished()
    }

    /// Marks microphone as finished
    func markMicrophoneFinished() {
        finishLock.lock()
        microphoneFinished = true
        finishLock.unlock()
        checkBothAudioFinished()
    }
}