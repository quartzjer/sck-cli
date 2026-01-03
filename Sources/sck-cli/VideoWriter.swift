import Foundation
import AVFoundation
import CoreMedia

/// Manages video capture and .mov file writing using hardware HEVC encoding
final class VideoWriter: @unchecked Sendable {
    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private let captureDuration: Double?

    private var started = false
    private var captureStartTime: CMTime?
    private var frameCount: Int = 0
    private var lock = NSLock()

    /// Creates a video writer instance
    /// - Parameters:
    ///   - url: Output URL for the .mov file
    ///   - width: Video width in pixels
    ///   - height: Video height in pixels
    ///   - frameRate: Frame rate in Hz
    ///   - duration: Maximum duration in seconds (nil for indefinite)
    ///   - bitrate: Target bitrate in bits per second (default: 8 Mbps)
    /// - Throws: Error if writer cannot be created
    static func create(
        url: URL,
        width: Int,
        height: Int,
        frameRate: Double,
        duration: Double?,
        bitrate: Int = 8_000_000
    ) throws -> VideoWriter {
        let writer = try AVAssetWriter(url: url, fileType: .mov)

        let compression: [String: Any] = [
            AVVideoExpectedSourceFrameRateKey: Int(frameRate),
            AVVideoAllowFrameReorderingKey: false,
            AVVideoAverageBitRateKey: bitrate,
            // Make keyframes extremely rare
            AVVideoMaxKeyFrameIntervalKey: 30_000,
            AVVideoMaxKeyFrameIntervalDurationKey: 3_600
        ]

        let colorProps: [String: String] = [
            AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
            AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
            AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2
        ]

        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoColorPropertiesKey: colorProps,
            AVVideoCompressionPropertiesKey: compression
        ]

        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = true

        guard writer.canAdd(videoInput) else {
            throw NSError(domain: "VideoWriter", code: -1, userInfo: [NSLocalizedDescriptionKey: "Cannot add video input to writer"])
        }

        writer.add(videoInput)

        return VideoWriter(
            writer: writer,
            videoInput: videoInput,
            duration: duration
        )
    }

    private init(
        writer: AVAssetWriter,
        videoInput: AVAssetWriterInput,
        duration: Double?
    ) {
        self.writer = writer
        self.videoInput = videoInput
        self.captureDuration = duration
    }

    /// Appends a video frame from CMSampleBuffer
    /// - Parameter sampleBuffer: Sample buffer containing video frame
    func appendFrame(_ sampleBuffer: CMSampleBuffer) {
        guard CMSampleBufferDataIsReady(sampleBuffer) else { return }

        lock.lock()
        defer { lock.unlock() }

        if !started {
            started = true
            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            captureStartTime = pts
            writer.startWriting()
            writer.startSession(atSourceTime: pts)
            Stderr.print("[INFO] Started video recording to \(writer.outputURL.path)")
        }

        // Check duration limit if specified
        if let duration = captureDuration, let startTime = captureStartTime {
            let currentPTS = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            let elapsed = CMTimeGetSeconds(CMTimeSubtract(currentPTS, startTime))
            if elapsed >= duration {
                return
            }
        }

        if videoInput.isReadyForMoreMediaData {
            if videoInput.append(sampleBuffer) {
                frameCount += 1
            }
        }
    }

    /// Finishes writing and closes the video file
    /// - Parameter completion: Callback with result ((URL, frameCount) on success, error on failure)
    func finish(completion: @escaping @Sendable (Result<(URL, Int), Error>) -> Void) {
        lock.lock()
        let shouldFinish = started
        let finalFrameCount = frameCount
        lock.unlock()

        guard shouldFinish else {
            completion(.failure(NSError(domain: "VideoWriter", code: -2, userInfo: [NSLocalizedDescriptionKey: "No frames written"])))
            return
        }

        // Drain any remaining frames before marking finished
        while !videoInput.isReadyForMoreMediaData {
            Thread.sleep(forTimeInterval: 0.01)
        }

        videoInput.markAsFinished()
        let outputURL = writer.outputURL
        writer.finishWriting { @Sendable in
            if self.writer.status == .completed {
                completion(.success((outputURL, finalFrameCount)))
            } else {
                completion(.failure(self.writer.error ?? NSError(domain: "VideoWriter", code: -3, userInfo: [NSLocalizedDescriptionKey: "Unknown error"])))
            }
        }
    }
}
