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
