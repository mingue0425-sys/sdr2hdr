import Foundation
import Metal

/// Layout for the DEBUG-only observation buffers. Production temporal control
/// remains the fixed 16x9/16-bin estimator in SDRToHDR.metal. These values are
/// intentionally separate so diagnostics cannot change the causal estimator.
public enum HDRDiagnosticHistogramLayout {
    public static let binCount = 64
    public static let groupCount = 12
    public static let valueCount = binCount * groupCount
    public static let luminanceRange: Float = 8
    public static let contributionRange: Float = 1

    public static let fullInputGroup = 0
    public static let fullToneExpandedGroup = 1
    public static let fullCoreEDRGroup = 2
    public static let lowMidContributionGroup = 3
    public static let shoulderContributionGroup = 4
    public static let shadowProtectionGroup = 5
    public static let roiInputGroup = 6
    public static let roiToneExpandedGroup = 7
    public static let roiCoreEDRGroup = 8
    public static let roiLowMidContributionGroup = 9
    public static let roiShoulderContributionGroup = 10
    public static let roiShadowProtectionGroup = 11

    public static func range(for group: Int) -> Float {
        switch group {
        case lowMidContributionGroup, shoulderContributionGroup, shadowProtectionGroup,
             roiLowMidContributionGroup, roiShoulderContributionGroup, roiShadowProtectionGroup:
            return contributionRange
        default:
            return luminanceRange
        }
    }
}

public enum HDRDiagnosticDetailLayout {
    public static let roiPixelCount = 0
    public static let roiRedSum = 1
    public static let roiGreenSum = 2
    public static let roiBlueSum = 3
    public static let roiChromaSum = 4
    public static let roiSaturationDeltaSum = 5
    public static let roiInputMax = 6
    public static let roiToneExpandedMax = 7
    public static let roiCoreEDRMax = 8

    public static let nearBlackBase = 16
    public static let nearBlackBandCount = 3
    public static let nearBlackStride = 9
    public static let nearBlackCountOffset = 0
    public static let nearBlackGainSumOffset = 1
    public static let nearBlackToneGainSumOffset = 2
    public static let nearBlackLiftedCountOffset = 3
    public static let nearBlackCrushedCountOffset = 4
    public static let nearBlackInputMinOffset = 5
    public static let nearBlackInputMaxOffset = 6
    public static let nearBlackCoreMinOffset = 7
    public static let nearBlackCoreMaxOffset = 8
    public static let valueCount = nearBlackBase + nearBlackBandCount * nearBlackStride
}

/// Optional GPU-side diagnostics. The historical fields are retained for
/// compatibility with the existing benchmark and DEBUG log output.
public struct HDRDebugStatistics: Equatable, Sendable {
    public let inputAverageLuminance: Float
    public let inputMaxLuminance: Float
    public let outputAverageLuminance: Float
    public let outputMaxLuminance: Float
    public let highlightPixelRatio: Float
    public let clippedPixelRatio: Float
    public let gpuDurationMilliseconds: Double?
    public let frameDiagnostic: HDRFrameDiagnosticSnapshot?

    public init(
        inputAverageLuminance: Float,
        inputMaxLuminance: Float,
        outputAverageLuminance: Float,
        outputMaxLuminance: Float,
        highlightPixelRatio: Float,
        clippedPixelRatio: Float,
        gpuDurationMilliseconds: Double?,
        frameDiagnostic: HDRFrameDiagnosticSnapshot? = nil
    ) {
        self.inputAverageLuminance = inputAverageLuminance
        self.inputMaxLuminance = inputMaxLuminance
        self.outputAverageLuminance = outputAverageLuminance
        self.outputMaxLuminance = outputMaxLuminance
        self.highlightPixelRatio = highlightPixelRatio
        self.clippedPixelRatio = clippedPixelRatio
        self.gpuDurationMilliseconds = gpuDurationMilliseconds
        self.frameDiagnostic = frameDiagnostic
    }
}

/// Keep the Metal struct scalar-only. The DEBUG histogram and detail arrays
/// are separate MTLBuffers because a Swift Array is not an inline buffer.
internal struct HDRDebugStatsStorage {
    var inputLuminanceSum: UInt32 = 0
    var inputLuminanceMax: UInt32 = 0
    var outputLuminanceSum: UInt32 = 0
    var outputLuminanceMax: UInt32 = 0
    var highlightPixelCount: UInt32 = 0
    var clippedPixelCount: UInt32 = 0
    var pixelCount: UInt32 = 0
    var toneExpandedLuminanceSum: UInt32 = 0
    var toneExpandedLuminanceMax: UInt32 = 0
    var coreLuminanceSum: UInt32 = 0
    var coreLuminanceMax: UInt32 = 0
    var lowMidContributionSum: UInt32 = 0
    var shoulderContributionSum: UInt32 = 0
    var shadowProtectionSum: UInt32 = 0
}

internal struct HDRDebugFrameContext: Sendable {
    let frameIndex: UInt64
    let timestampSeconds: Double?
    let preset: String
    let configurationGeneration: UInt64
    let configuration: HDRConfiguration
    let temporalAdaptation: Float
    let temporalSubmissionSequence: UInt64
    let sceneShadowFloor: Float
    let sceneShadowTop: Float
    let sceneStatisticsValid: Bool
    let roi: HDRDiagnosticROI?
}

internal final class DebugStatisticsStore: @unchecked Sendable {
    private let lock = NSLock()
    private var latest: HDRDebugStatistics?
    private var latestSnapshot: HDRFrameDiagnosticSnapshot?
    private var previousInputHistogram: [UInt32]?
    private var previousAverageLuminance: Float?
    private var previousFrameIndex: UInt64?

    var value: HDRDebugStatistics? {
        lock.lock()
        defer { lock.unlock() }
        return latest
    }

    var diagnosticValue: HDRFrameDiagnosticSnapshot? {
        lock.lock()
        defer { lock.unlock() }
        return latestSnapshot
    }

    func update(
        from buffers: DebugBufferLifetime,
        context: HDRDebugFrameContext,
        commandBuffer: MTLCommandBuffer,
        lastCompletedTemporalSequence: UInt64
    ) {
        let storage = buffers.stats.contents().assumingMemoryBound(to: HDRDebugStatsStorage.self).pointee
        let histogramPointer = buffers.histograms.contents().assumingMemoryBound(to: UInt32.self)
        let histograms = Array(UnsafeBufferPointer(
            start: histogramPointer,
            count: HDRDiagnosticHistogramLayout.valueCount
        ))
        let detailPointer = buffers.details.contents().assumingMemoryBound(to: UInt32.self)
        let details = Array(UnsafeBufferPointer(
            start: detailPointer,
            count: HDRDiagnosticDetailLayout.valueCount
        ))

        let count = max(UInt32(1), storage.pixelCount)
        let gpuDuration: Double? = commandBuffer.gpuStartTime > 0 && commandBuffer.gpuEndTime >= commandBuffer.gpuStartTime
            ? (commandBuffer.gpuEndTime - commandBuffer.gpuStartTime) * 1_000
            : nil
        let scale: Float = 256
        let oldStatistics = HDRDebugStatistics(
            inputAverageLuminance: Float(storage.inputLuminanceSum) / Float(count) / scale,
            inputMaxLuminance: Float(storage.inputLuminanceMax) / scale,
            outputAverageLuminance: Float(storage.outputLuminanceSum) / Float(count) / scale,
            outputMaxLuminance: Float(storage.outputLuminanceMax) / scale,
            highlightPixelRatio: Float(storage.highlightPixelCount) / Float(count),
            clippedPixelRatio: Float(storage.clippedPixelCount) / Float(count),
            gpuDurationMilliseconds: gpuDuration
        )

        let input = makeStatistics(
            group: HDRDiagnosticHistogramLayout.fullInputGroup,
            histograms: histograms,
            sampleCount: count,
            sum: storage.inputLuminanceSum,
            maximum: storage.inputLuminanceMax
        )
        let toneExpanded = makeStatistics(
            group: HDRDiagnosticHistogramLayout.fullToneExpandedGroup,
            histograms: histograms,
            sampleCount: count,
            sum: storage.toneExpandedLuminanceSum,
            maximum: storage.toneExpandedLuminanceMax
        )
        let core = makeStatistics(
            group: HDRDiagnosticHistogramLayout.fullCoreEDRGroup,
            histograms: histograms,
            sampleCount: count,
            sum: storage.coreLuminanceSum,
            maximum: storage.coreLuminanceMax
        )

        let sceneCut = makeSceneCutDiagnostic(
            currentAverage: input.average,
            currentHistogram: histogramSlice(
                group: HDRDiagnosticHistogramLayout.fullInputGroup,
                histograms: histograms
            ),
            frameIndex: context.frameIndex
        )

        let toneDiagnostic = HDRToneCurveDiagnostic(
            shoulderStart: 0.68 - 0.20 * min(max(context.configuration.contrastStrength, 0), 1),
            highlightStrengthEffective: min(max(context.configuration.highlightStrength * context.temporalAdaptation, 0), 1),
            lowMidExpansionContribution: makeStatistics(
                group: HDRDiagnosticHistogramLayout.lowMidContributionGroup,
                histograms: histograms,
                sampleCount: count,
                sum: storage.lowMidContributionSum,
                sumScale: 64,
                maximum: nil
            ).average,
            shoulderExpansionContribution: makeStatistics(
                group: HDRDiagnosticHistogramLayout.shoulderContributionGroup,
                histograms: histograms,
                sampleCount: count,
                sum: storage.shoulderContributionSum,
                sumScale: 64,
                maximum: nil
            ).average,
            shadowProtectionFactor: makeStatistics(
                group: HDRDiagnosticHistogramLayout.shadowProtectionGroup,
                histograms: histograms,
                sampleCount: count,
                sum: storage.shadowProtectionSum,
                sumScale: 64,
                maximum: nil
            ).average,
            temporalStrength: context.temporalAdaptation
        )

        let roi = makeROIDiagnostic(
            roi: context.roi,
            histograms: histograms,
            details: details,
            configuration: context.configuration
        )
        let nearBlack = makeNearBlackDiagnostics(details: details)
        let snapshot = HDRFrameDiagnosticSnapshot(
            frameIndex: context.frameIndex,
            timestampSeconds: context.timestampSeconds,
            preset: context.preset,
            configurationGeneration: context.configurationGeneration,
            input: input,
            sceneShadowFloor: context.sceneShadowFloor,
            sceneShadowTop: context.sceneShadowTop,
            sceneStatisticsValid: context.sceneStatisticsValid,
            temporalAdaptation: context.temporalAdaptation,
            temporalSubmissionSequence: context.temporalSubmissionSequence,
            lastCompletedTemporalSequence: lastCompletedTemporalSequence,
            toneCurve: toneDiagnostic,
            toneExpanded: toneExpanded,
            coreEDR: core,
            roi: roi,
            nearBlack: nearBlack,
            sceneCut: sceneCut
        )

        lock.lock()
        latestSnapshot = snapshot
        latest = oldStatistics.with(frameDiagnostic: snapshot)
        lock.unlock()
    }

    private func histogramSlice(group: Int, histograms: [UInt32]) -> [UInt32] {
        let start = group * HDRDiagnosticHistogramLayout.binCount
        let end = min(start + HDRDiagnosticHistogramLayout.binCount, histograms.count)
        guard start < end else { return [] }
        return Array(histograms[start..<end])
    }

    private func makeStatistics(
        group: Int,
        histograms: [UInt32],
        sampleCount: UInt32,
        sum: UInt32?,
        sumScale: Float? = nil,
        maximum: UInt32?
    ) -> HDRLuminanceStatistics {
        let bins = histogramSlice(group: group, histograms: histograms)
        let total = bins.reduce(UInt64(0)) { $0 + UInt64($1) }
        guard total > 0 else { return .zero }

        func quantile(_ fraction: Double) -> Float {
            let target = max(UInt64(1), UInt64(ceil(Double(total) * fraction)))
            var cumulative: UInt64 = 0
            for (index, value) in bins.enumerated() {
                cumulative += UInt64(value)
                if cumulative >= target {
                    return (Float(index) + 0.5) * HDRDiagnosticHistogramLayout.range(for: group) /
                        Float(HDRDiagnosticHistogramLayout.binCount)
                }
            }
            return HDRDiagnosticHistogramLayout.range(for: group)
        }

        let average: Float
        if let sum {
            let scale: Float = sumScale ?? (
                group == HDRDiagnosticHistogramLayout.fullToneExpandedGroup ||
                    group == HDRDiagnosticHistogramLayout.fullCoreEDRGroup ? 16 : 256
            )
            average = Float(sum) / Float(max(sampleCount, 1)) / scale
        } else {
            average = bins.enumerated().reduce(Float(0)) { partial, item in
                let center = (Float(item.offset) + 0.5) * HDRDiagnosticHistogramLayout.range(for: group) /
                    Float(HDRDiagnosticHistogramLayout.binCount)
                return partial + center * Float(item.element)
            } / Float(total)
        }
        let maximumValue = maximum.map { Float($0) / 256 } ?? quantile(0.999)
        return HDRLuminanceStatistics(
            p01: finiteOrZero(quantile(0.01)),
            p05: finiteOrZero(quantile(0.05)),
            p50: finiteOrZero(quantile(0.50)),
            p90: finiteOrZero(quantile(0.90)),
            p95: finiteOrZero(quantile(0.95)),
            p99: finiteOrZero(quantile(0.99)),
            average: finiteOrZero(average),
            max: finiteOrZero(maximumValue)
        )
    }

    private func makeSceneCutDiagnostic(
        currentAverage: Float,
        currentHistogram: [UInt32],
        frameIndex: UInt64
    ) -> HDRSceneCutDiagnostic? {
        lock.lock()
        defer { lock.unlock() }

        let isNewer = previousFrameIndex.map { frameIndex >= $0 } ?? true
        guard isNewer else { return nil }
        let previousAverage = previousAverageLuminance
        let previousHistogram = previousInputHistogram
        previousFrameIndex = frameIndex
        previousAverageLuminance = currentAverage
        previousInputHistogram = currentHistogram

        guard let previousAverage, let previousHistogram else {
            return HDRSceneCutDiagnostic(
                averageLuminance: currentAverage,
                previousAverageLuminance: nil,
                stopDelta: nil,
                histogramDistance: nil,
                sceneCutDecision: false
            )
        }
        let stopDelta = log2(max(currentAverage, 0.001) / max(previousAverage, 0.001))
        let currentTotal = max(1, currentHistogram.reduce(0, +))
        let previousTotal = max(1, previousHistogram.reduce(0, +))
        let distance = zip(currentHistogram, previousHistogram).reduce(Float(0)) { partial, pair in
            partial + abs(Float(pair.0) / Float(currentTotal) - Float(pair.1) / Float(previousTotal))
        } * 0.5
        let decision = abs(stopDelta) > 1.25
        return HDRSceneCutDiagnostic(
            averageLuminance: currentAverage,
            previousAverageLuminance: previousAverage,
            stopDelta: finiteOrNil(stopDelta),
            histogramDistance: finiteOrNil(distance),
            sceneCutDecision: decision
        )
    }

    private func makeROIDiagnostic(
        roi: HDRDiagnosticROI?,
        histograms: [UInt32],
        details: [UInt32],
        configuration: HDRConfiguration
    ) -> HDRROIProbeDiagnostic? {
        guard let roi, !roi.isEmpty else { return nil }
        let count = details[safe: HDRDiagnosticDetailLayout.roiPixelCount] ?? 0
        guard count > 0 else { return nil }
        let input = makeStatistics(
            group: HDRDiagnosticHistogramLayout.roiInputGroup,
            histograms: histograms,
            sampleCount: count,
            sum: nil,
            maximum: details[safe: HDRDiagnosticDetailLayout.roiInputMax]
        )
        let tone = makeStatistics(
            group: HDRDiagnosticHistogramLayout.roiToneExpandedGroup,
            histograms: histograms,
            sampleCount: count,
            sum: nil,
            maximum: details[safe: HDRDiagnosticDetailLayout.roiToneExpandedMax]
        )
        let core = makeStatistics(
            group: HDRDiagnosticHistogramLayout.roiCoreEDRGroup,
            histograms: histograms,
            sampleCount: count,
            sum: nil,
            maximum: details[safe: HDRDiagnosticDetailLayout.roiCoreEDRMax]
        )
        let lowMid = makeStatistics(
            group: HDRDiagnosticHistogramLayout.roiLowMidContributionGroup,
            histograms: histograms,
            sampleCount: count,
            sum: nil,
            maximum: nil
        ).average
        let shoulder = makeStatistics(
            group: HDRDiagnosticHistogramLayout.roiShoulderContributionGroup,
            histograms: histograms,
            sampleCount: count,
            sum: nil,
            maximum: nil
        ).average
        let protection = makeStatistics(
            group: HDRDiagnosticHistogramLayout.roiShadowProtectionGroup,
            histograms: histograms,
            sampleCount: count,
            sum: nil,
            maximum: nil
        ).average
        let red = details[safe: HDRDiagnosticDetailLayout.roiRedSum].map { Float($0) / Float(count) / 32 }
        let green = details[safe: HDRDiagnosticDetailLayout.roiGreenSum].map { Float($0) / Float(count) / 32 }
        let blue = details[safe: HDRDiagnosticDetailLayout.roiBlueSum].map { Float($0) / Float(count) / 32 }
        let chroma = details[safe: HDRDiagnosticDetailLayout.roiChromaSum].map { Float($0) / Float(count) / 256 }
        let saturationDelta = details[safe: HDRDiagnosticDetailLayout.roiSaturationDeltaSum].map {
            Float($0) / Float(count) / 256 - 0.5
        }
        return HDRROIProbeDiagnostic(
            roi: roi,
            input: input,
            toneExpanded: tone,
            coreEDR: core,
            lowMidExpansionContribution: lowMid,
            shoulderExpansionContribution: shoulder,
            shadowProtectionFactor: protection,
            presentation: HDRPresentationDiagnostic(
                masteringHeadroom: configuration.masteringHeadroom,
                physicalDisplayHeadroom: nil,
                mappedEDRAverage: nil,
                mappedEDRMax: nil
            ),
            meanRed: finiteOrNil(red),
            meanGreen: finiteOrNil(green),
            meanBlue: finiteOrNil(blue),
            meanChroma: finiteOrNil(chroma),
            saturationDelta: finiteOrNil(saturationDelta)
        )
    }

    private func makeNearBlackDiagnostics(details: [UInt32]) -> [HDRNearBlackBandDiagnostic] {
        let thresholds: [Float] = [0.01, 0.02, 0.05]
        return thresholds.enumerated().map { band, threshold in
            let start = HDRDiagnosticDetailLayout.nearBlackBase + band * HDRDiagnosticDetailLayout.nearBlackStride
            let count = details[safe: start + HDRDiagnosticDetailLayout.nearBlackCountOffset] ?? 0
            guard count > 0 else {
                return HDRNearBlackBandDiagnostic(
                    threshold: threshold, sampleCount: 0, meanGain: 0,
                    meanToneGain: 0, contrastRatioPreservation: 0,
                    liftedPixelRatio: 0, crushedPixelRatio: 0
                )
            }
            let gain = Float(details[safe: start + HDRDiagnosticDetailLayout.nearBlackGainSumOffset] ?? 0) /
                Float(count) / 32
            let toneGain = Float(details[safe: start + HDRDiagnosticDetailLayout.nearBlackToneGainSumOffset] ?? 0) /
                Float(count) / 32
            let inputMin = details[safe: start + HDRDiagnosticDetailLayout.nearBlackInputMinOffset] ?? UInt32.max
            let inputMax = details[safe: start + HDRDiagnosticDetailLayout.nearBlackInputMaxOffset] ?? 0
            let coreMin = details[safe: start + HDRDiagnosticDetailLayout.nearBlackCoreMinOffset] ?? UInt32.max
            let coreMax = details[safe: start + HDRDiagnosticDetailLayout.nearBlackCoreMaxOffset] ?? 0
            let inputRange = inputMax > inputMin ? Float(inputMax - inputMin) : 0
            let coreRange = coreMax > coreMin ? Float(coreMax - coreMin) : 0
            let contrast: Float
            if inputRange > 0 {
                contrast = min(max(coreRange / inputRange, 0), 4)
            } else {
                contrast = coreRange == 0 ? 1 : 0
            }
            let lifted = Float(details[safe: start + HDRDiagnosticDetailLayout.nearBlackLiftedCountOffset] ?? 0) / Float(count)
            let crushed = Float(details[safe: start + HDRDiagnosticDetailLayout.nearBlackCrushedCountOffset] ?? 0) / Float(count)
            return HDRNearBlackBandDiagnostic(
                threshold: threshold,
                sampleCount: UInt64(count),
                meanGain: finiteOrZero(gain),
                meanToneGain: finiteOrZero(toneGain),
                contrastRatioPreservation: finiteOrZero(contrast),
                liftedPixelRatio: finiteOrZero(lifted),
                crushedPixelRatio: finiteOrZero(crushed)
            )
        }
    }

    private func finiteOrZero(_ value: Float) -> Float {
        value.isFinite ? value : 0
    }

    private func finiteOrNil(_ value: Float?) -> Float? {
        guard let value, value.isFinite else { return nil }
        return value
    }
}

internal final class DebugBufferLifetime: @unchecked Sendable {
    let stats: MTLBuffer
    let histograms: MTLBuffer
    let details: MTLBuffer

    init(stats: MTLBuffer, histograms: MTLBuffer, details: MTLBuffer) {
        self.stats = stats
        self.histograms = histograms
        self.details = details
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

private extension HDRDebugStatistics {
    func with(frameDiagnostic: HDRFrameDiagnosticSnapshot) -> HDRDebugStatistics {
        HDRDebugStatistics(
            inputAverageLuminance: inputAverageLuminance,
            inputMaxLuminance: inputMaxLuminance,
            outputAverageLuminance: outputAverageLuminance,
            outputMaxLuminance: outputMaxLuminance,
            highlightPixelRatio: highlightPixelRatio,
            clippedPixelRatio: clippedPixelRatio,
            gpuDurationMilliseconds: gpuDurationMilliseconds,
            frameDiagnostic: frameDiagnostic
        )
    }
}
