import Foundation
import AVFoundation
import CoreMedia

/// Manages audio capture and writing to M4A file
final class AudioWriter: @unchecked Sendable {
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let audioType: String
    private let finishLock = NSLock()

    private var sessionStarted = false
    private var firstAudioTime: CMTime?
    private var bufferCount = 0
    private var isFinished = false
    private let duration: Double?
    var onComplete: (() -> Void)?

    /// Creates an audio writer for the specified file
    /// - Parameters:
    ///   - url: File URL to write audio to
    ///   - audioType: Description for logging (e.g., "system audio", "microphone")
    ///   - duration: Maximum duration in seconds, or nil for indefinite
    /// - Throws: Error if writer creation fails
    static func create(
        url: URL,
        audioType: String,
        duration: Double?
    ) throws -> AudioWriter {
        // Remove existing file if present
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }

        return try AudioWriter(
            url: url,
            audioType: audioType,
            duration: duration
        )
    }

    private init(
        url: URL,
        audioType: String,
        duration: Double?
    ) throws {
        self.writer = try AVAssetWriter(url: url, fileType: .m4a)
        self.audioType = audioType
        self.duration = duration

        // Configure AAC audio format for M4A
        let audioSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 128_000
        ]

        self.input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
        self.input.expectsMediaDataInRealTime = true

        guard writer.canAdd(input) else {
            throw NSError(
                domain: "AudioWriter",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Cannot add audio input to writer"]
            )
        }

        writer.add(input)
        writer.startWriting()
    }

    /// Appends an audio buffer to the writer
    /// - Parameter sampleBuffer: Audio sample buffer from SCStream
    func append(_ sampleBuffer: CMSampleBuffer) {
        let currentTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        finishLock.lock()
        let finished = isFinished
        finishLock.unlock()

        guard !finished else { return }

        // Start session on first buffer
        if !sessionStarted {
            writer.startSession(atSourceTime: .zero)
            sessionStarted = true
            firstAudioTime = currentTime
            print("Started \(audioType) recording at \(CMTimeGetSeconds(currentTime))")
        }

        guard let firstTime = firstAudioTime else { return }
        let mediaElapsed = CMTimeGetSeconds(CMTimeSubtract(currentTime, firstTime))

        // Check if we should continue recording
        if let duration = duration, mediaElapsed < duration {
            // Still recording
            if input.isReadyForMoreMediaData {
                let adjustedTime = CMTimeSubtract(currentTime, firstTime)
                if let retimedBuffer = createRetimedSampleBuffer(sampleBuffer, newTime: adjustedTime) {
                    input.append(retimedBuffer)
                    bufferCount += 1
                }
            }
        } else if duration != nil {
            // Duration exceeded, finish writing
            finishLock.lock()
            let alreadyFinished = isFinished
            if !alreadyFinished {
                isFinished = true
            }
            finishLock.unlock()

            if !alreadyFinished {
                print("Finishing \(audioType) recording after \(String(format: "%.2f", mediaElapsed)) seconds")
                input.markAsFinished()
                writer.finishWriting { [weak self] in
                    guard let self = self else { return }
                    print("wrote \(self.writer.outputURL.lastPathComponent) (10 seconds)")
                    if self.writer.status == .failed {
                        print("\(self.audioType) error: \(String(describing: self.writer.error))")
                    }
                    self.onComplete?()
                }
            }
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