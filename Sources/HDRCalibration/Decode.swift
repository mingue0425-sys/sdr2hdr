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
    /// Causal temporal value that was encoded into this frame's shader
    /// parameters. The evaluator's current temporal state after `evaluate`
    /// belongs to the next frame because GPU completion updates it.
    public let temporalAdaptationUsed: Float
    public let sceneShadowFloorUsed: Float
    public let sceneShadowTopUsed: Float
    public let sceneStatisticsValidUsed: Bool

    public init(
        timestampSeconds: Double,
        width: Int,
        height: Int,
        rgbNits: [SIMD3<Float>],
        temporalAdaptationUsed: Float = 1,
        sceneShadowFloorUsed: Float = HDRSceneStatistics.neutral.shadowFloor,
        sceneShadowTopUsed: Float = HDRSceneStatistics.neutral.shadowTop,
        sceneStatisticsValidUsed: Bool = false
    ) {
        self.timestampSeconds = timestampSeconds
        self.width = width
        self.height = height
        self.rgbNits = rgbNits
        self.lumaNits = rgbNits.map { simd_dot($0, HDRColorMath.bt2020Luminance) }
        self.temporalAdaptationUsed = temporalAdaptationUsed
        self.sceneShadowFloorUsed = sceneShadowFloorUsed
        self.sceneShadowTopUsed = sceneShadowTopUsed
        self.sceneStatisticsValidUsed = sceneStatisticsValidUsed
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
        hlgDisplayRGBNits(signal: SIMD3(repeating: signal), peakNits: peakNits).x
    }

    /// BT.2100 HLG inverse OETF followed by the display-side OOTF. The OOTF
    /// is a vector operation: system gamma is derived from BT.2020 scene
    /// luminance and applied as one gain to RGB, preserving hue/chroma ratios.
    public static func hlgDisplayRGBNits(signal: SIMD3<Float>, peakNits: Float = 1_000) -> SIMD3<Float> {
        let a: Float = 0.17883277
        let b: Float = 1 - 4 * a
        let c: Float = 0.55991073
        func inverseOETF(_ value: Float) -> Float {
            let clamped = min(max(value, 0), 1)
            return clamped <= 0.5
                ? (clamped * clamped) / 3
                : (exp((clamped - c) / a) + b) / 12
        }
        let scene = SIMD3(
            inverseOETF(signal.x), inverseOETF(signal.y), inverseOETF(signal.z)
        )
        let sceneLuminance = max(simd_dot(scene, HDRColorMath.bt2020Luminance), 0)
        let systemGamma = 1.2 + 0.42 * log10(max(peakNits, 100) / 1_000)
        let ootfGain = sceneLuminance > 0
            ? pow(sceneLuminance, systemGamma - 1)
            : 0
        let display = scene * ootfGain * max(peakNits, 1)
        return SIMD3(
            display.x.isFinite ? max(display.x, 0) : 0,
            display.y.isFinite ? max(display.y, 0) : 0,
            display.z.isFinite ? max(display.z, 0) : 0
        )
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
                    decoded = HDRReferenceTransferMath.hlgDisplayRGBNits(
                        signal: signal, peakNits: referencePeakNits
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
        // Offline evaluation must execute the same causal GPU estimator as
        // production. It waits only because calibration needs a readback;
        // the estimator itself remains the production 16x9/16-bin path.
        self.processor.automaticTemporalEstimationEnabled = true
        self.gridWidth = gridWidth
        self.gridHeight = gridHeight
        self.readbackTexture = nil
    }

    public var automaticTemporalEstimationEnabled: Bool {
        get { processor.automaticTemporalEstimationEnabled }
        set { processor.automaticTemporalEstimationEnabled = newValue }
    }

    public func evaluate(
        pixelBuffer: CVPixelBuffer,
        timestampSeconds: Double,
        configuration: HDRConfiguration,
        averageLuminance: Float? = nil,
        sceneCut: Bool = false
    ) throws -> GeneratedFrame {
        try processor.update(configuration: configuration)
        if let averageLuminance, !processor.automaticTemporalEstimationEnabled {
            processor.updateTemporalEstimate(averageLuminance: averageLuminance, sceneCut: sceneCut)
        }
        let temporalAdaptationUsed = processor.temporalAdaptation
        let sceneShadowUsed = processor.sceneShadowCoordinates
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
        return GeneratedFrame(
            timestampSeconds: timestampSeconds,
            width: gridWidth,
            height: gridHeight,
            rgbNits: rgb,
            temporalAdaptationUsed: temporalAdaptationUsed,
            sceneShadowFloorUsed: sceneShadowUsed.floor,
            sceneShadowTopUsed: sceneShadowUsed.top,
            sceneStatisticsValidUsed: sceneShadowUsed.valid
        )
    }

    /// Evaluates a sparse spatial sample with neutral, non-evolving temporal
    /// state. Sparse alignment samples are not consecutive video frames and
    /// must never be fed through the production temporal controller as if they
    /// formed a causal sequence.
    public func evaluateSpatiallyIndependent(
        pixelBuffer: CVPixelBuffer,
        timestampSeconds: Double,
        configuration: HDRConfiguration
    ) throws -> GeneratedFrame {
        let previousAutomatic = automaticTemporalEstimationEnabled
        automaticTemporalEstimationEnabled = false
        clearTemporalHistory()
        defer {
            clearTemporalHistory()
            automaticTemporalEstimationEnabled = previousAutomatic
        }
        return try evaluate(
            pixelBuffer: pixelBuffer,
            timestampSeconds: timestampSeconds,
            configuration: configuration
        )
    }

    public func resetTemporalState(averageLuminance: Float = 0.5) {
        processor.resetTemporalState(averageLuminance: averageLuminance)
    }

    /// Applies a production-compatible source-statistics update after a frame
    /// has been processed. Callers must provide the same 16x9 linear-light
    /// samples used by the runtime estimator; the shared histogram quantizer
    /// is used rather than exact CPU percentiles.
    public func updateSceneStatistics(sdrBT709Signals: [Float], sceneCut: Bool = false) {
        processor.updateSceneStatistics(
            HDRSceneStatistics(productionLinearSamples: sdrBT709Signals.map { HDRColorMath.inverseBT709($0) }),
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

    public var sceneShadowCoordinates: (floor: Float, top: Float, valid: Bool) {
        processor.sceneShadowCoordinates
    }

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
