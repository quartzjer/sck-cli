import Foundation
import AVFoundation
import CoreMedia

/// Manages audio capture and writing to M4A file with multiple tracks
final class AudioWriter: @unchecked Sendable {
    private let writer: AVAssetWriter
    private let systemInput: AVAssetWriterInput
    private let microphoneInput: AVAssetWriterInput
    private let finishLock = NSLock()

    private var sessionStarted = false
    private var firstAudioTime: CMTime?
    private var lastMediaTime: CMTime?
    private var systemFinished = false
    private var microphoneFinished = false
    private let duration: Double?
    var onComplete: (() -> Void)?

    /// Creates an audio writer with two separate tracks (system audio and microphone)
    /// - Parameters:
    ///   - url: File URL to write audio to
    ///   - duration: Maximum duration in seconds, or nil for indefinite
    /// - Throws: Error if writer creation fails
    static func create(
        url: URL,
        duration: Double?
    ) throws -> AudioWriter {
        // Remove existing file if present
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }

        return try AudioWriter(url: url, duration: duration)
    }

    private init(url: URL, duration: Double?) throws {
        self.writer = try AVAssetWriter(url: url, fileType: .m4a)
        self.duration = duration

        // Configure AAC audio format for M4A (mono tracks)
        let audioSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 64_000
        ]

        // Create separate inputs for system audio and microphone
        self.systemInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
        self.systemInput.expectsMediaDataInRealTime = true

        self.microphoneInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
        self.microphoneInput.expectsMediaDataInRealTime = true

        guard writer.canAdd(systemInput), writer.canAdd(microphoneInput) else {
            throw NSError(
                domain: "AudioWriter",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Cannot add audio inputs to writer"]
            )
        }

        writer.add(systemInput)
        writer.add(microphoneInput)
        writer.startWriting()
    }

    /// Appends a system audio buffer to the writer
    /// - Parameter sampleBuffer: Audio sample buffer from SCStream
    func appendSystemAudio(_ sampleBuffer: CMSampleBuffer) {
        append(sampleBuffer, to: systemInput) { [weak self] elapsed in
            self?.finishSystemAudio(elapsed: elapsed)
        }
    }

    /// Appends a microphone audio buffer to the writer
    /// - Parameter sampleBuffer: Audio sample buffer from SCStream
    func appendMicrophone(_ sampleBuffer: CMSampleBuffer) {
        append(sampleBuffer, to: microphoneInput) { [weak self] elapsed in
            self?.finishMicrophone(elapsed: elapsed)
        }
    }

    private func append(
        _ sampleBuffer: CMSampleBuffer,
        to input: AVAssetWriterInput,
        onFinish: @escaping (Double) -> Void
    ) {
        let currentTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        finishLock.lock()
        let finished = systemFinished && microphoneFinished
        finishLock.unlock()

        guard !finished else { return }

        // Start session on first buffer
        finishLock.lock()
        if !sessionStarted {
            writer.startSession(atSourceTime: .zero)
            sessionStarted = true
            firstAudioTime = currentTime
            Stderr.print("Started audio recording at \(CMTimeGetSeconds(currentTime))")
        }
        lastMediaTime = currentTime
        finishLock.unlock()

        guard let firstTime = firstAudioTime else { return }
        let mediaElapsed = CMTimeGetSeconds(CMTimeSubtract(currentTime, firstTime))

        // Check if we should continue recording
        if let duration = duration, mediaElapsed >= duration {
            // Duration exceeded, finish this track
            onFinish(mediaElapsed)
        } else if input.isReadyForMoreMediaData {
            // Still recording (indefinite or within duration)
            let adjustedTime = CMTimeSubtract(currentTime, firstTime)
            if let retimedBuffer = createRetimedSampleBuffer(sampleBuffer, newTime: adjustedTime) {
                input.append(retimedBuffer)
            }
        }
    }

    private func finishSystemAudio(elapsed: Double) {
        finishLock.lock()
        let alreadyFinished = systemFinished
        if !alreadyFinished {
            systemFinished = true
            Stderr.print("Finishing system audio track after \(String(format: "%.2f", elapsed)) seconds")
            systemInput.markAsFinished()
        }
        let bothFinished = systemFinished && microphoneFinished
        finishLock.unlock()

        if !alreadyFinished && bothFinished {
            finalizeWriter(elapsed: elapsed)
        }
    }

    private func finishMicrophone(elapsed: Double) {
        finishLock.lock()
        let alreadyFinished = microphoneFinished
        if !alreadyFinished {
            microphoneFinished = true
            Stderr.print("Finishing microphone track after \(String(format: "%.2f", elapsed)) seconds")
            microphoneInput.markAsFinished()
        }
        let bothFinished = systemFinished && microphoneFinished
        finishLock.unlock()

        if !alreadyFinished && bothFinished {
            finalizeWriter(elapsed: elapsed)
        }
    }

    private func finalizeWriter(elapsed: Double) {
        writer.finishWriting { [weak self] in
            guard let self = self else { return }
            Stderr.print("wrote \(self.writer.outputURL.lastPathComponent) (\(String(format: "%.1f", elapsed)) seconds, 2 tracks)")
            if self.writer.status == .failed {
                Stderr.print("audio writer error: \(String(describing: self.writer.error))")
            }
            self.onComplete?()
        }
    }

    /// Finishes all tracks and finalizes the writer (for graceful shutdown)
    /// This is idempotent - safe to call even if tracks are already finishing
    func finishAllTracks() {
        finishLock.lock()
        let systemAlreadyFinished = systemFinished
        let micAlreadyFinished = microphoneFinished
        let firstTime = firstAudioTime
        let lastTime = lastMediaTime
        if !systemFinished {
            systemFinished = true
            systemInput.markAsFinished()
        }
        if !microphoneFinished {
            microphoneFinished = true
            microphoneInput.markAsFinished()
        }
        finishLock.unlock()

        // Only finalize if we actually marked something as finished
        if !systemAlreadyFinished || !micAlreadyFinished {
            let elapsed: Double
            if let firstTime = firstTime, let lastTime = lastTime {
                elapsed = CMTimeGetSeconds(CMTimeSubtract(lastTime, firstTime))
            } else {
                elapsed = 0
            }
            finalizeWriter(elapsed: elapsed)
        }
    }

    /// Creates a new sample buffer with adjusted timing
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
}