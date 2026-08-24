import CoreMedia
import CoreVideo
import Foundation
import HDRCore
import Metal
import simd

public struct ReferenceFrame {
    public let timestampSeconds: Double
    public let width: Int
    public let height: Int
    public let rgbNits: [SIMD3<Float>]
    public let lumaNits: [Float]

    public init(timestampSeconds: Double, width: Int, height: Int, rgbNits: [SIMD3<Float>]) {
        self.timestampSeconds = timestampSeconds
        self.width = width
        self.height = height
        self.rgbNits = rgbNits
        self.lumaNits = rgbNits.map { simd_dot($0, HDRColorMath.bt2020Luminance) }
    }
}

public struct GeneratedFrame {
    public let timestampSeconds: Double
    public let width: Int
    public let height: Int
    public let rgbNits: [SIMD3<Float>]
    public let lumaNits: [Float]

    public init(timestampSeconds: Double, width: Int, height: Int, rgbNits: [SIMD3<Float>]) {
        self.timestampSeconds = timestampSeconds
        self.width = width
        self.height = height
        self.rgbNits = rgbNits
        self.lumaNits = rgbNits.map { simd_dot($0, HDRColorMath.bt2020Luminance) }
    }
}

public enum HDRReferenceTransferMath {
    public static func decodeNits(signal: Float, transfer: ReferenceTransfer, targetPeakNits: Float = 1_000) -> Float {
        switch transfer {
        case .pq:
            return HDRColorMath.pqDecodeNits(signal: signal)
        case .hlg:
            return hlgDisplayNits(signal: signal, peakNits: targetPeakNits)
        case .unknown:
            return .nan
        }
    }

    public static func hlgDisplayNits(signal: Float, peakNits: Float = 1_000) -> Float {
        let a: Float = 0.17883277
        let b: Float = 1 - 4 * a
        let c: Float = 0.55991073
        let clamped = max(signal, 0)
        let scene = clamped <= 0.5
            ? (clamped * clamped) / 3
            : (exp((clamped - c) / a) + b) / 12
        let systemGamma = 1.2 + 0.42 * log10(max(peakNits, 100) / 1_000)
        return max(0, pow(max(scene, 0), systemGamma) * peakNits)
    }
}

public enum HDRReferenceDecoder {
    public static func decode(
        pixelBuffer: CVPixelBuffer,
        timestampSeconds: Double,
        width: Int = 32,
        height: Int = 18,
        transfer: ReferenceTransfer = .pq,
        referencePeakNits: Float = 1_000
    ) throws -> ReferenceFrame {
        let format = CVPixelBufferGetPixelFormatType(pixelBuffer)
        guard format == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange ||
                format == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange else {
            throw CalibrationError.unsupportedReference("expected P010 420, got \(format)")
        }
        let sourceWidth = CVPixelBufferGetWidth(pixelBuffer)
        let sourceHeight = CVPixelBufferGetHeight(pixelBuffer)
        guard sourceWidth > 0, sourceHeight > 0 else {
            throw CalibrationError.decodeFailed("invalid HDR dimensions")
        }
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let yBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0),
              let uvBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1) else {
            throw CalibrationError.decodeFailed("missing HDR P010 planes")
        }
        let yRowBytes = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        let uvRowBytes = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1)
        let fullRange = format == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
        var rgb = [SIMD3<Float>](repeating: .zero, count: width * height)

        for gy in 0..<height {
            let sourceY = min(sourceHeight - 1, gy * sourceHeight / height)
            let yRow = yBase.advanced(by: sourceY * yRowBytes).assumingMemoryBound(to: UInt16.self)
            let uvY = min(max(0, CVPixelBufferGetHeightOfPlane(pixelBuffer, 1) - 1), sourceY / 2)
            let uvRow = uvBase.advanced(by: uvY * uvRowBytes).assumingMemoryBound(to: UInt16.self)
            for gx in 0..<width {
                let sourceX = min(sourceWidth - 1, gx * sourceWidth / width)
                let uvX = min(max(0, CVPixelBufferGetWidthOfPlane(pixelBuffer, 1) - 1), sourceX / 2)
                let yCode = Float(yRow[sourceX] >> 6)
                let cbCode = Float(uvRow[uvX * 2] >> 6)
                let crCode = Float(uvRow[uvX * 2 + 1] >> 6)
                let y = fullRange ? yCode / 1023 : min(max((yCode - 64) / 876, 0), 1)
                let cb = fullRange ? (cbCode - 512) / 1023 : (cbCode - 512) / 896
                let cr = fullRange ? (crCode - 512) / 1023 : (crCode - 512) / 896
                let signal = SIMD3<Float>(
                    y + 1.4746 * cr,
                    y - 0.164553 * cb - 0.571353 * cr,
                    y + 1.8814 * cb
                )
                let decoded: SIMD3<Float>
                switch transfer {
                case .pq:
                    decoded = SIMD3<Float>(
                        HDRReferenceTransferMath.decodeNits(signal: signal.x, transfer: .pq),
                        HDRReferenceTransferMath.decodeNits(signal: signal.y, transfer: .pq),
                        HDRReferenceTransferMath.decodeNits(signal: signal.z, transfer: .pq)
                    )
                case .hlg:
                    decoded = SIMD3<Float>(
                        HDRReferenceTransferMath.decodeNits(signal: signal.x, transfer: .hlg, targetPeakNits: referencePeakNits),
                        HDRReferenceTransferMath.decodeNits(signal: signal.y, transfer: .hlg, targetPeakNits: referencePeakNits),
                        HDRReferenceTransferMath.decodeNits(signal: signal.z, transfer: .hlg, targetPeakNits: referencePeakNits)
                    )
                case .unknown:
                    throw CalibrationError.unsupportedReference("unknown transfer")
                }
                rgb[gy * width + gx] = SIMD3(
                    finiteOrZero(decoded.x), finiteOrZero(decoded.y), finiteOrZero(decoded.z)
                )
            }
        }
        return ReferenceFrame(timestampSeconds: timestampSeconds, width: width, height: height, rgbNits: rgb)
    }

    private static func finiteOrZero(_ value: Float) -> Float {
        value.isFinite ? max(value, 0) : 0
    }

}

public final class HDRCoreOfflineEvaluator {
    private let device: MTLDevice
    private let processor: HDRProcessor
    private let gridWidth: Int
    private let gridHeight: Int
    private var readbackTexture: MTLTexture?

    public init(device: MTLDevice, configuration: HDRConfiguration, gridWidth: Int = 32, gridHeight: Int = 18) throws {
        self.device = device
        self.processor = try HDRProcessor(device: device, configuration: configuration)
        self.processor.automaticTemporalEstimationEnabled = false
        self.gridWidth = gridWidth
        self.gridHeight = gridHeight
        self.readbackTexture = nil
    }

    public func evaluate(
        pixelBuffer: CVPixelBuffer,
        timestampSeconds: Double,
        configuration: HDRConfiguration,
        averageLuminance: Float? = nil,
        sceneCut: Bool = false
    ) throws -> GeneratedFrame {
        try processor.update(configuration: configuration)
        if let averageLuminance {
            processor.updateTemporalEstimate(averageLuminance: averageLuminance, sceneCut: sceneCut)
        }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        try processor.prepare(width: width, height: height)
        let commandBuffer = try processor.makeCommandBuffer()
        let frame = try processor.process(
            pixelBuffer: pixelBuffer,
            timestamp: CMTime(seconds: timestampSeconds, preferredTimescale: 600),
            commandBuffer: commandBuffer
        )
        let stagingTexture = try makeReadbackTexture(width: width, height: height)
        guard let blit = commandBuffer.makeBlitCommandEncoder() else {
            throw CalibrationError.decodeFailed("could not create offline readback blit encoder")
        }
        blit.copy(
            from: frame.texture,
            sourceSlice: 0,
            sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: width, height: height, depth: 1),
            to: stagingTexture,
            destinationSlice: 0,
            destinationLevel: 0,
            destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
        )
        blit.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        guard commandBuffer.status == .completed else {
            throw CalibrationError.decodeFailed(commandBuffer.error?.localizedDescription ?? "HDRCore command buffer failed")
        }
        var values = [Float16](repeating: 0, count: width * height * 4)
        stagingTexture.getBytes(
            &values,
            bytesPerRow: width * MemoryLayout<Float16>.size * 4,
            from: MTLRegionMake2D(0, 0, width, height),
            mipmapLevel: 0
        )
        var rgb = [SIMD3<Float>](repeating: .zero, count: gridWidth * gridHeight)
        for gy in 0..<gridHeight {
            let y = min(height - 1, gy * height / gridHeight)
            for gx in 0..<gridWidth {
                let x = min(width - 1, gx * width / gridWidth)
                let offset = (y * width + x) * 4
                rgb[gy * gridWidth + gx] = SIMD3(
                    max(Float(values[offset]), 0) * configuration.paperWhiteNits,
                    max(Float(values[offset + 1]), 0) * configuration.paperWhiteNits,
                    max(Float(values[offset + 2]), 0) * configuration.paperWhiteNits
                )
            }
        }
        return GeneratedFrame(timestampSeconds: timestampSeconds, width: gridWidth, height: gridHeight, rgbNits: rgb)
    }

    public func resetTemporalState(averageLuminance: Float = 0.5) {
        processor.resetTemporalState(averageLuminance: averageLuminance)
    }

    /// Applies a source-statistics update after a frame has been processed.
    /// This ordering mirrors HDRProcessor's asynchronous runtime estimator:
    /// frame N is rendered with state from N-1, then N updates state for N+1.
    public func updateSceneStatistics(sdrBT709Signals: [Float], sceneCut: Bool = false) {
        processor.updateSceneStatistics(
            HDRSceneStatistics(sdrBT709Signals: sdrBT709Signals),
            sceneCut: sceneCut
        )
    }

    public func updateTemporalEstimate(averageLuminance: Float, sceneCut: Bool = false) {
        processor.updateTemporalEstimate(averageLuminance: averageLuminance, sceneCut: sceneCut)
    }


    public func clearTemporalHistory() {
        processor.clearTemporalHistory()
    }

    public var temporalAdaptation: Float { processor.temporalAdaptation }

    private func makeReadbackTexture(width: Int, height: Int) throws -> MTLTexture {
        if let readbackTexture,
           readbackTexture.width == width,
           readbackTexture.height == height {
            return readbackTexture
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.storageMode = .shared
        descriptor.usage = [.shaderRead, .shaderWrite]
        guard let created = device.makeTexture(descriptor: descriptor) else {
            throw CalibrationError.decodeFailed("could not allocate offline shared readback texture")
        }
        readbackTexture = created
        return created
    }
}
