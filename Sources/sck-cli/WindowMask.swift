// SPDX-License-Identifier: MIT
// Copyright 2026 sol pbc

import Foundation
import CoreGraphics
import CoreVideo

/// Represents a window that should be masked during capture
struct MaskedWindow {
    let windowID: CGWindowID
    let ownerName: String
    let bounds: CGRect  // Global screen coordinates (top-left origin)
    let visibleRegions: [CGRect]  // Portions not covered by windows above
}

/// Detects windows belonging to specified applications for masking
final class WindowMaskDetector: @unchecked Sendable {
    private let targetAppNames: Set<String>  // Lowercase for case-insensitive matching

    /// Creates a detector for the specified app names
    /// - Parameter appNames: Application names to match (case-insensitive, exact match)
    init(appNames: [String]) {
        self.targetAppNames = Set(appNames.map { $0.lowercased() })
    }

    /// Detects all on-screen windows belonging to target applications with visible regions
    /// - Returns: Array of windows matching target app names, with occlusion calculated
    func detectWindows() -> [MaskedWindow] {
        guard let windowList = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }

        // Collect all window bounds in z-order (front to back)
        var allWindowBounds: [CGRect] = []
        var result: [MaskedWindow] = []

        for window in windowList {
            // Only consider normal layer windows (layer 0)
            guard let layer = window[kCGWindowLayer as String] as? Int, layer == 0 else {
                continue
            }

            // Extract window bounds
            guard let boundsDict = window[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary) else {
                continue
            }

            // Check if this is a target window
            if let ownerName = window[kCGWindowOwnerName as String] as? String,
               targetAppNames.contains(ownerName.lowercased()) {
                let windowID = window[kCGWindowNumber as String] as? CGWindowID ?? 0

                // Calculate visible regions by subtracting all windows above this one
                var visibleRegions = [bounds]
                for coveringBounds in allWindowBounds {
                    visibleRegions = visibleRegions.flatMap { subtractRect(from: $0, subtracting: coveringBounds) }
                }

                // Only include if there are visible regions
                if !visibleRegions.isEmpty {
                    result.append(MaskedWindow(
                        windowID: windowID,
                        ownerName: ownerName,
                        bounds: bounds,
                        visibleRegions: visibleRegions
                    ))
                }
            }

            // Track this window's bounds for occlusion of windows below
            allWindowBounds.append(bounds)
        }

        return result
    }
}

/// Subtracts one rectangle from another, returning the remaining visible portions
/// - Parameters:
///   - source: The original rectangle
///   - cover: The rectangle to subtract
/// - Returns: Array of rectangles representing the non-overlapping portions (0-4 rects)
private func subtractRect(from source: CGRect, subtracting cover: CGRect) -> [CGRect] {
    let intersection = source.intersection(cover)

    // No intersection - source is fully visible
    if intersection.isNull || intersection.isEmpty {
        return [source]
    }

    // Full coverage - source is fully hidden
    if intersection == source {
        return []
    }

    var result: [CGRect] = []

    // Top strip (above the intersection)
    if intersection.minY > source.minY {
        result.append(CGRect(
            x: source.minX,
            y: source.minY,
            width: source.width,
            height: intersection.minY - source.minY
        ))
    }

    // Bottom strip (below the intersection)
    if intersection.maxY < source.maxY {
        result.append(CGRect(
            x: source.minX,
            y: intersection.maxY,
            width: source.width,
            height: source.maxY - intersection.maxY
        ))
    }

    // Left strip (between top and bottom of intersection)
    if intersection.minX > source.minX {
        result.append(CGRect(
            x: source.minX,
            y: intersection.minY,
            width: intersection.minX - source.minX,
            height: intersection.height
        ))
    }

    // Right strip (between top and bottom of intersection)
    if intersection.maxX < source.maxX {
        result.append(CGRect(
            x: intersection.maxX,
            y: intersection.minY,
            width: source.maxX - intersection.maxX,
            height: intersection.height
        ))
    }

    return result
}

/// Applies black masking to visible regions of target windows in a pixel buffer
enum FrameMasker {
    /// Applies black mask to specified regions in an NV12 pixel buffer
    /// - Parameters:
    ///   - pixelBuffer: The CVPixelBuffer to modify (NV12 format)
    ///   - regions: Regions to mask in global screen coordinates
    ///   - displayBounds: The display's bounds in global screen coordinates
    static func applyMask(to pixelBuffer: CVPixelBuffer, regions: [CGRect], displayBounds: CGRect) {
        guard !regions.isEmpty else { return }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        // Lock the pixel buffer for read-write access
        let lockFlags = CVPixelBufferLockFlags(rawValue: 0)
        guard CVPixelBufferLockBaseAddress(pixelBuffer, lockFlags) == kCVReturnSuccess else {
            return
        }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, lockFlags) }

        // Get Y plane (plane 0)
        guard let yPlane = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) else { return }
        let yBytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)

        // Get UV plane (plane 1)
        guard let uvPlane = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1) else { return }
        let uvBytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1)

        let yBuffer = yPlane.assumingMemoryBound(to: UInt8.self)
        let uvBuffer = uvPlane.assumingMemoryBound(to: UInt8.self)

        for region in regions {
            // Convert from global screen coordinates to display-local coordinates
            let localX = region.origin.x - displayBounds.origin.x
            let localY = region.origin.y - displayBounds.origin.y

            // Clamp to display bounds
            let minX = max(0, Int(localX))
            let minY = max(0, Int(localY))
            let maxX = min(width, Int(localX + region.width))
            let maxY = min(height, Int(localY + region.height))

            // Skip if region is outside display
            if minX >= maxX || minY >= maxY { continue }

            // Fill Y plane with 0 (black luma for full-range)
            for y in minY..<maxY {
                let rowStart = yBuffer + y * yBytesPerRow + minX
                memset(rowStart, 0, maxX - minX)
            }

            // Fill UV plane with 128 (neutral chroma)
            // UV plane is half resolution in both dimensions
            let uvMinX = minX / 2
            let uvMinY = minY / 2
            let uvMaxX = (maxX + 1) / 2
            let uvMaxY = (maxY + 1) / 2

            for y in uvMinY..<uvMaxY {
                let rowStart = uvBuffer + y * uvBytesPerRow + uvMinX * 2
                let count = (uvMaxX - uvMinX) * 2
                // Fill with alternating 128 values (Cb=128, Cr=128)
                memset(rowStart, 128, count)
            }
        }
    }
}
