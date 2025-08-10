import Foundation
@preconcurrency import ScreenCaptureKit
import CoreImage
import CoreImage.CIFilterBuiltins
import Metal
import CoreMedia
import CoreVideo
import Dispatch

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

        // 4) Create stream and a frame receiver
        let stream = SCStream(filter: filter, configuration: cfg, delegate: nil)

        final class Output: NSObject, SCStreamOutput {
            let sema = DispatchSemaphore(value: 0)
            func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of outputType: SCStreamOutputType) {
                guard outputType == .screen, let imgBuf = sb.imageBuffer else { return }
                // Write PNG to disk
                let ci = CIImage(cvImageBuffer: imgBuf)
                let ctx = CIContext(options: nil)
                let url = URL(fileURLWithPath: "capture.png")
                if let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
                   let data = ctx.pngRepresentation(of: ci, format: .BGRA8, colorSpace: colorSpace) {
                    try? data.write(to: url)
                    print("wrote \(url.path)")
                }
                sema.signal()
            }
        }

        let out = Output()
        try! stream.addStreamOutput(out, type: .screen, sampleHandlerQueue: .main)

        // 5) Start, await one frame, then stop
        try? await stream.startCapture()

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            out.sema.signal() // no-op if already signaled; keep continuity simple
            // Resume when first frame handler signals
            DispatchQueue.main.async {
                // If a frame already arrived, this will have been signaled
                _ = out.sema.wait(timeout: .now())
                cont.resume()
            }
        }

        _ = try? await stream.stopCapture()
        exit(0)
    }
}
