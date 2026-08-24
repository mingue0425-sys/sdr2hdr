import Foundation
import Metal

/// Optional GPU-side diagnostics. Input luminance is normalized to SDR
/// reference white. Output luminance is normalized to the configured output
/// peak (EDR headroom or PQ peak), so these values are comparable across
/// frames without a CPU pixel readback.
public struct HDRDebugStatistics: Equatable, Sendable {
    public let inputAverageLuminance: Float
    public let inputMaxLuminance: Float
    public let outputAverageLuminance: Float
    public let outputMaxLuminance: Float
    public let highlightPixelRatio: Float
    public let clippedPixelRatio: Float
    public let gpuDurationMilliseconds: Double?

    public init(
        inputAverageLuminance: Float,
        inputMaxLuminance: Float,
        outputAverageLuminance: Float,
        outputMaxLuminance: Float,
        highlightPixelRatio: Float,
        clippedPixelRatio: Float,
        gpuDurationMilliseconds: Double?
    ) {
        self.inputAverageLuminance = inputAverageLuminance
        self.inputMaxLuminance = inputMaxLuminance
        self.outputAverageLuminance = outputAverageLuminance
        self.outputMaxLuminance = outputMaxLuminance
        self.highlightPixelRatio = highlightPixelRatio
        self.clippedPixelRatio = clippedPixelRatio
        self.gpuDurationMilliseconds = gpuDurationMilliseconds
    }
}

internal struct HDRDebugStatsStorage {
    var inputLuminanceSum: UInt32 = 0
    var inputLuminanceMax: UInt32 = 0
    var outputLuminanceSum: UInt32 = 0
    var outputLuminanceMax: UInt32 = 0
    var highlightPixelCount: UInt32 = 0
    var clippedPixelCount: UInt32 = 0
    var pixelCount: UInt32 = 0
}

internal final class DebugStatisticsStore: @unchecked Sendable {
    private let lock = NSLock()
    private var latest: HDRDebugStatistics?

    var value: HDRDebugStatistics? {
        lock.lock()
        defer { lock.unlock() }
        return latest
    }

    func update(from buffer: MTLBuffer, width: Int, height: Int, commandBuffer: MTLCommandBuffer) {
        let storage = buffer.contents().assumingMemoryBound(to: HDRDebugStatsStorage.self).pointee
        let count = max(UInt32(1), storage.pixelCount)
        let gpuDuration: Double? = commandBuffer.gpuStartTime > 0 && commandBuffer.gpuEndTime >= commandBuffer.gpuStartTime
            ? (commandBuffer.gpuEndTime - commandBuffer.gpuStartTime) * 1_000
            : nil
        let scale: Float = 256
        let result = HDRDebugStatistics(
            inputAverageLuminance: Float(storage.inputLuminanceSum) / Float(count) / scale,
            inputMaxLuminance: Float(storage.inputLuminanceMax) / scale,
            outputAverageLuminance: Float(storage.outputLuminanceSum) / Float(count) / scale,
            outputMaxLuminance: Float(storage.outputLuminanceMax) / scale,
            highlightPixelRatio: Float(storage.highlightPixelCount) / Float(count),
            clippedPixelRatio: Float(storage.clippedPixelCount) / Float(count),
            gpuDurationMilliseconds: gpuDuration
        )
        lock.lock()
        latest = result
        lock.unlock()
        _ = width
        _ = height
    }
}

internal final class DebugBufferLifetime: @unchecked Sendable {
    let buffer: MTLBuffer

    init(buffer: MTLBuffer) {
        self.buffer = buffer
    }
}
