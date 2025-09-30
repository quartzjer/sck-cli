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
            // Both audio files are ready - now merge them into stereo
            mergeAudioFiles()
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

    /// Merges system and microphone audio files into a single stereo file
    /// Uses ffmpeg to combine: microphone -> left channel, system audio -> right channel
    private func mergeAudioFiles() {
        print("Merging audio files into stereo (mic=left, system=right)...")

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        task.arguments = [
            "ffmpeg",
            "-y",  // Overwrite output file
            "-i", "microphone.m4a",
            "-i", "system_audio.m4a",
            "-filter_complex",
            "[0:a]pan=stereo|c0=c0|c1=c0[left];[1:a]pan=stereo|c0=c1|c1=c1[right];[left][right]amerge=inputs=2[out]",
            "-map", "[out]",
            "-ac", "2",
            "-c:a", "aac",
            "-b:a", "128k",
            "audio.m4a"
        ]

        do {
            try task.run()
            task.waitUntilExit()

            if task.terminationStatus == 0 {
                print("Successfully created audio.m4a (stereo: mic=left, system=right)")
                // Clean up individual files
                try? FileManager.default.removeItem(atPath: "microphone.m4a")
                try? FileManager.default.removeItem(atPath: "system_audio.m4a")
            } else {
                print("Warning: ffmpeg merge failed with status \(task.terminationStatus)")
                print("Keeping separate audio files: microphone.m4a and system_audio.m4a")
            }
        } catch {
            print("Warning: Could not run ffmpeg to merge audio: \(error)")
            print("Keeping separate audio files: microphone.m4a and system_audio.m4a")
        }
    }
}