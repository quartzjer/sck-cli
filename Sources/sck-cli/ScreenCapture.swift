import Foundation
import CoreImage
import CoreVideo

/// Manages screenshot capture and PNG file writing
final class ScreenCapture: @unchecked Sendable {
    private let ciContext = CIContext(options: nil)
    private let screenshotInterval: CFAbsoluteTime
    private let maxFrames: Int // 0 means indefinite
    private let captureDuration: Double? // nil means use frame count

    private var screenshotCount = 0
    private var lastScreenshotTime: CFAbsoluteTime = 0
    private var captureStartTime: CFAbsoluteTime = 0

    /// Creates a screen capture manager
    /// - Parameters:
    ///   - frameRate: Frames per second to capture
    ///   - frames: Maximum number of frames (0 for indefinite)
    ///   - duration: Maximum duration in seconds (nil to use frame count)
    init(frameRate: Double, frames: Int, duration: Double?) {
        self.screenshotInterval = 1.0 / frameRate
        self.maxFrames = frames
        self.captureDuration = duration
    }

    /// Captures a screenshot from the provided image buffer
    /// - Parameter imageBuffer: CVImageBuffer from SCStream
    func captureFrame(_ imageBuffer: CVImageBuffer) {
        let currentTime = CFAbsoluteTimeGetCurrent()

        // Initialize timing on first screenshot
        if screenshotCount == 0 {
            captureStartTime = currentTime
            lastScreenshotTime = currentTime
        }

        // Check if we should stop based on duration or frame count
        let totalElapsed = currentTime - captureStartTime
        if let duration = captureDuration, totalElapsed >= duration {
            return
        }
        if maxFrames > 0 && screenshotCount >= maxFrames {
            return
        }

        // Capture screenshot at specified interval
        if screenshotCount == 0 || (currentTime - lastScreenshotTime) >= screenshotInterval {
            let ci = CIImage(cvImageBuffer: imageBuffer)
            let url = URL(fileURLWithPath: "capture_\(screenshotCount).png")

            if let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
               let data = ciContext.pngRepresentation(of: ci, format: .BGRA8, colorSpace: colorSpace) {
                try? data.write(to: url)
                print("wrote \(url.path)")
            }

            screenshotCount += 1
            lastScreenshotTime = currentTime
        }
    }
}