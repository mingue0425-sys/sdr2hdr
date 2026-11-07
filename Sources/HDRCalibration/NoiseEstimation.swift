import CoreVideo
import Foundation

/// Immerkær's fast noise-variance estimator (CVIU 1996): convolve with the
/// difference of two Laplacians, N = [1 -2 1; -2 4 -2; 1 -2 1], which cancels
/// locally linear structure, and convert the mean absolute response to a
/// Gaussian standard deviation:
///     sigma = sqrt(pi/2) / (6 (W-2)(H-2)) * sum |I * N|
/// Edges inflate the estimate slightly; the robustness study uses it only to
/// scale the gain-guidance tolerance per clip.
public enum ImmerkaerNoiseEstimator {
    /// `values` row-major, `width` x `height`, any unit; sigma is in the same unit.
    public static func sigma(_ values: [Float], width: Int, height: Int) -> Double {
        guard width >= 3, height >= 3, values.count >= width * height else { return 0 }
        var sum = 0.0
        for y in 1..<(height - 1) {
            let above = (y - 1) * width, row = y * width, below = (y + 1) * width
            for x in 1..<(width - 1) {
                let top: Float = values[above + x - 1] - 2 * values[above + x] + values[above + x + 1]
                let middle: Float = -2 * values[row + x - 1] + 4 * values[row + x] - 2 * values[row + x + 1]
                let bottom: Float = values[below + x - 1] - 2 * values[below + x] + values[below + x + 1]
                let response = top + middle + bottom
                sum += Double(abs(response))
            }
        }
        return (Double.pi / 2).squareRoot() / (6 * Double(width - 2) * Double(height - 2)) * sum
    }

    /// Video-range luma signal (0...1 over codes 16...235) of an 8-bit NV12
    /// buffer's Y plane, sigma in signal units (one code = 1/219).
    public static func lumaSignalSigma(_ buffer: CVPixelBuffer) -> Double? {
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
              CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) else { return nil }
        let width = CVPixelBufferGetWidthOfPlane(buffer, 0)
        let height = CVPixelBufferGetHeightOfPlane(buffer, 0)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        var values = [Float](repeating: 0, count: width * height)
        for y in 0..<height {
            let row = base.advanced(by: y * stride).assumingMemoryBound(to: UInt8.self)
            for x in 0..<width { values[y * width + x] = (Float(row[x]) - 16) / 219 }
        }
        return sigma(values, width: width, height: height)
    }
}

/// Codec blocking: mean absolute luma step across `block`-pixel boundaries
/// (both axes) divided by the mean step between all other adjacent pixels.
/// Natural content is ~1; transform-block artifacts push it above 1. Only
/// meaningful while the block grid is aligned with the frame (no rescale
/// after decode).
public enum BlockinessEstimator {
    public static func ratio(_ values: [Float], width: Int, height: Int, block: Int = 8) -> Double {
        guard width > block, height > block, block >= 2, values.count >= width * height else { return 1 }
        var boundary = 0.0, boundaryCount = 0.0, interior = 0.0, interiorCount = 0.0
        for y in 0..<height {
            let row = y * width
            for x in 1..<width {
                let step = Double(abs(values[row + x] - values[row + x - 1]))
                if x % block == 0 { boundary += step; boundaryCount += 1 } else { interior += step; interiorCount += 1 }
            }
        }
        for y in 1..<height {
            let row = y * width, above = (y - 1) * width
            let isBoundary = y % block == 0
            for x in 0..<width {
                let step = Double(abs(values[row + x] - values[above + x]))
                if isBoundary { boundary += step; boundaryCount += 1 } else { interior += step; interiorCount += 1 }
            }
        }
        let interiorMean = interior / max(interiorCount, 1)
        guard interiorMean > 1e-9 else { return 1 }
        return (boundary / max(boundaryCount, 1)) / interiorMean
    }
}

/// Bit-depth banding: fraction of unused 8-bit codes between the 1st and
/// 99th luma percentile. Natural 8-bit content fills its range (~0); luma
/// quantized to 6 bits leaves three of every four codes empty (~0.75).
public enum HistogramGapEstimator {
    public static func gapFraction(codes: [UInt8]) -> Double {
        guard !codes.isEmpty else { return 0 }
        var histogram = [Int](repeating: 0, count: 256)
        for code in codes { histogram[Int(code)] += 1 }
        let lowTarget = codes.count / 100, highTarget = codes.count - codes.count / 100
        var cumulative = 0, low = 0, high = 255
        for code in 0..<256 {
            cumulative += histogram[code]
            if cumulative > lowTarget { low = code; break }
        }
        cumulative = 0
        for code in 0..<256 {
            cumulative += histogram[code]
            if cumulative >= highTarget { high = code; break }
        }
        guard high > low else { return 0 }
        let empty = (low...high).filter { histogram[$0] == 0 }.count
        return Double(empty) / Double(high - low + 1)
    }
}

/// Luma statistics of one 8-bit NV12 frame used to set the guidance tolerance.
public struct LumaArtifactStatistics: Codable, Sendable, Equatable {
    public let noiseSigma: Double
    public let blockiness: Double
    public let histogramGapFraction: Double

    public init(noiseSigma: Double, blockiness: Double, histogramGapFraction: Double) {
        self.noiseSigma = noiseSigma
        self.blockiness = blockiness
        self.histogramGapFraction = histogramGapFraction
    }

    public static func measure(_ buffer: CVPixelBuffer) -> LumaArtifactStatistics? {
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
              CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) else { return nil }
        let width = CVPixelBufferGetWidthOfPlane(buffer, 0)
        let height = CVPixelBufferGetHeightOfPlane(buffer, 0)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        var codes = [UInt8](repeating: 0, count: width * height)
        var signal = [Float](repeating: 0, count: width * height)
        for y in 0..<height {
            let row = base.advanced(by: y * stride).assumingMemoryBound(to: UInt8.self)
            for x in 0..<width {
                codes[y * width + x] = row[x]
                signal[y * width + x] = (Float(row[x]) - 16) / 219
            }
        }
        return LumaArtifactStatistics(
            noiseSigma: ImmerkaerNoiseEstimator.sigma(signal, width: width, height: height),
            blockiness: BlockinessEstimator.ratio(signal, width: width, height: height),
            histogramGapFraction: HistogramGapEstimator.gapFraction(codes: codes)
        )
    }
}
