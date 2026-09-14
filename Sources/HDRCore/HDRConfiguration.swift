import Foundation

/// The transfer/output convention expected by the consumer of an HDRFrame.
public enum HDROutputMode: String, CaseIterable, Codable, Hashable, Sendable {
    /// Linear extended RGB. 1.0 is SDR reference white and values above 1.0
    /// use display EDR headroom. The presentation layer supplies the matching
    /// extended color space to its CAMetalLayer/MTKView.
    case edr = "EDR"

    /// ST.2084/PQ RGB normalized to the absolute 0...10,000 nit PQ range.
    case pq = "PQ"
}

/// Policy used only when a CVPixelBuffer has no color attachments at all.
public enum HDRInputFallbackPolicy: String, CaseIterable, Codable, Hashable, Sendable {
    case bt709VideoRange
    case bt709FullRange
    case requireMetadata
}

/// Selects the spatial reconstruction used for 4:2:0 chroma planes. The
/// calibrated V4 preset remains on `.nearest`; the siting-aware mode is an
/// explicit development candidate until its synthetic and real-media error
/// measurements justify promotion.
public enum HDRChromaReconstructionMode: UInt32, CaseIterable, Codable, Sendable {
    case nearest = 0
    case sitingAwareBilinear = 1
}

/// Selects the analytical tone-expansion revision. Historical V1/V2 presets
/// remain on the frozen V2 curve; the rejected V3 candidate explicitly opts
/// into repaired shadow control, while the promoted V4 preset uses
/// scene-relative coordinates.
public enum HDRToneCurveRevision: UInt32, Sendable {
    case legacyV2 = 0
    case shadowProtectedV3 = 1
    /// V4 uses scene-relative percentile coordinates supplied by the causal
    /// runtime estimator.
    case sceneRelativeV4 = 2
    /// Development-only V6 candidate revision. This is never a production
    /// preset; it keeps the V4 parameters while bounding the low-mid term.
    case sceneRelativeV6Candidate = 3
    /// Development-only V6.2 candidate revision. It keeps the V4 tone curve
    /// and applies a bounded, source-statistics-only low-mid budget.
    case sceneAdaptiveV62Candidate = 4
}

/// Offline comparison strategies for the scene-statistics estimator. The
/// runtime V4 path uses `linear64`; the other layouts remain diagnostic-only.
public enum HDRSceneHistogramStrategy: String, CaseIterable, Codable, Sendable {
    case linear16
    case linear64
    case log64
    case shadowDense64

    /// The strategy used by the current V4 runtime after 8395ee4. Keeping it
    /// explicit lets diagnostics compare the old estimator and candidates
    /// without silently changing the production path.
    public static let production: HDRSceneHistogramStrategy = .linear64

    public var metalValue: UInt32 {
        switch self {
        case .linear16: return 0
        case .linear64: return 1
        case .log64: return 2
        case .shadowDense64: return 3
        }
    }

    public var binCount: Int {
        binCount(using: .calibrationV4)
    }

    public func binCount(using semantics: HDRSceneStatisticsSemanticDefinition) -> Int {
        self == .linear16 ? semantics.linear16HistogramBinCount : semantics.histogramBinCount
    }
}

/// Low-cost source-luminance statistics used by the V4 scene-relative shadow
/// controller. Values are linear BT.709 luminance normalized to SDR white.
/// The runtime estimator supplies these one frame late; offline calibration
/// feeds the same state transition after each frame.
public struct HDRSceneStatistics: Equatable, Sendable, Codable {
    public static var productionProxyWidth: Int { HDRSceneStatisticsSemanticDefinition.calibrationV4.proxyWidth }
    public static var productionProxyHeight: Int { HDRSceneStatisticsSemanticDefinition.calibrationV4.proxyHeight }
    /// The production estimator retains the existing 16x9 sample count but
    /// uses 64 linear bins so the shadow percentiles do not collapse every
    /// value below 0.0625 into one bucket.
    public static var productionHistogramBinCount: Int { HDRSceneStatisticsSemanticDefinition.calibrationV4.histogramBinCount }
    public var p01: Float
    public var p05: Float
    public var p10: Float
    public var p25: Float
    public var p50: Float
    public var p90: Float
    public var p99: Float

    public init(
        p01: Float,
        p05: Float,
        p10: Float,
        p25: Float,
        p50: Float,
        p90: Float,
        p99: Float
    ) {
        self.p01 = p01
        self.p05 = p05
        self.p10 = p10
        self.p25 = p25
        self.p50 = p50
        self.p90 = p90
        self.p99 = p99
    }

    public static func neutral(using semantics: HDRSceneStatisticsSemanticDefinition) -> HDRSceneStatistics {
        let values = semantics.neutralPercentiles
        return HDRSceneStatistics(
            p01: Float(values[0]), p05: Float(values[1]), p10: Float(values[2]),
            p25: Float(values[3]), p50: Float(values[4]), p90: Float(values[5]),
            p99: Float(values[6])
        )
    }

    public static var neutral: HDRSceneStatistics {
        neutral(using: .calibrationV4)
    }

    public init(
        samples: [Float],
        semantics: HDRSceneStatisticsSemanticDefinition = .calibrationV4
    ) {
        let finite = samples.filter { $0.isFinite }
            .map { min(max($0, Float(semantics.inputMinimum)), Float(semantics.inputMaximum)) }
            .sorted()
        func percentile(_ fraction: Double) -> Float {
            guard !finite.isEmpty else { return Float(semantics.emptyAverage) }
            let index = min(max(Int(Double(finite.count - 1) * fraction), 0), finite.count - 1)
            return finite[index]
        }
        let fractions = semantics.quantileFractions
        self.init(
            p01: percentile(fractions[0]), p05: percentile(fractions[1]), p10: percentile(fractions[2]),
            p25: percentile(fractions[3]), p50: percentile(fractions[4]), p90: percentile(fractions[5]),
            p99: percentile(fractions[6])
        )
    }

    /// Converts the normalized BT.709 luma signal used by the calibration
    /// proxy into the same linear-light samples used by the Metal estimator.
    public init(
        sdrBT709Signals: [Float],
        semantics: HDRSceneStatisticsSemanticDefinition = .calibrationV4,
        colorScience: HDRColorScienceSemanticDefinition = .calibrationV4
    ) {
        self.init(
            sdrSignals: sdrBT709Signals,
            transfer: .bt709,
            semantics: semantics,
            colorScience: colorScience
        )
    }

    /// Converts encoded SDR luma signals using an explicitly selected
    /// effective transfer model. The default preserves the PR #12 domain.
    public init(
        sdrSignals: [Float],
        transfer: HDRTransferFunction,
        semantics: HDRSceneStatisticsSemanticDefinition = .calibrationV4,
        colorScience: HDRColorScienceSemanticDefinition = .calibrationV4
    ) {
        self.init(samples: sdrSignals.map {
            HDRColorMath.inverseTransfer($0, function: transfer, colorScience: colorScience)
        }, semantics: semantics)
    }

    public static func linearAverage(
        sdrBT709Signals: [Float],
        semantics: HDRSceneStatisticsSemanticDefinition = .calibrationV4,
        colorScience: HDRColorScienceSemanticDefinition = .calibrationV4
    ) -> Float {
        linearAverage(
            sdrSignals: sdrBT709Signals,
            transfer: .bt709,
            semantics: semantics,
            colorScience: colorScience
        )
    }

    public static func linearAverage(
        sdrSignals: [Float],
        transfer: HDRTransferFunction,
        semantics: HDRSceneStatisticsSemanticDefinition = .calibrationV4,
        colorScience: HDRColorScienceSemanticDefinition = .calibrationV4
    ) -> Float {
        let values = sdrSignals.map {
            HDRColorMath.inverseTransfer($0, function: transfer, colorScience: colorScience)
        }.filter(\.isFinite)
        guard !values.isEmpty else { return Float(semantics.emptyAverage) }
        return min(
            max(values.reduce(0, +) / Float(values.count), Float(semantics.averageClampMinimum)),
            Float(semantics.averageClampMaximum)
        )
    }

    /// Converts the fixed 64-bin GPU histogram into percentile estimates. The
    /// sparse proxy remains intentionally low cost; the extra bins improve
    /// shadow ordering without changing the 16x9 sampling pattern.
    public init(
        histogram: [UInt32],
        semantics: HDRSceneStatisticsSemanticDefinition = .calibrationV4
    ) {
        self.init(histogram: histogram, strategy: .production, semantics: semantics)
    }

    /// Decodes the fixed storage layout using the strategy that encoded it.
    /// Linear16 still uses the first 16 slots of the shared 64-slot buffer;
    /// log and shadow-dense strategies use all 64 slots.
    public init(
        histogram: [UInt32],
        strategy: HDRSceneHistogramStrategy,
        semantics: HDRSceneStatisticsSemanticDefinition = .calibrationV4
    ) {
        let storage = Array(histogram.prefix(semantics.histogramBinCount)) +
            Array(repeating: 0, count: max(0, semantics.histogramBinCount - histogram.count))
        let bins = Array(storage.prefix(strategy.binCount(using: semantics)))
        let total = bins.reduce(0, +)
        func quantile(_ fraction: Double) -> Float {
            guard total > 0 else { return Float(semantics.emptyAverage) }
            let target = max(UInt64(1), UInt64(Double(total) * fraction))
            var cumulative: UInt64 = 0
            for (index, count) in bins.enumerated() {
                cumulative += UInt64(count)
                if cumulative >= target {
                    switch strategy {
                    case .linear16, .linear64:
                        return (Float(index) + Float(semantics.quantizationRounding)) / Float(bins.count)
                    case .log64:
                        let logCenter = Float(semantics.histogramLogMinimumExponent) +
                            (Float(index) + Float(semantics.quantizationRounding)) *
                            Float(semantics.histogramLogMaximumExponent - semantics.histogramLogMinimumExponent) /
                            Float(bins.count)
                        return pow(2, logCenter)
                    case .shadowDense64:
                        if index < semantics.shadowDenseLowerBinCount {
                            return (Float(index) + Float(semantics.quantizationRounding)) /
                                Float(semantics.shadowDenseLowerBinCount) * Float(semantics.shadowDenseBreakpoint)
                        }
                        return Float(semantics.shadowDenseBreakpoint) +
                            (Float(index - semantics.shadowDenseLowerBinCount) + Float(semantics.quantizationRounding)) /
                            Float(bins.count - semantics.shadowDenseLowerBinCount) * Float(semantics.shadowDenseUpperSpan)
                    }
                }
            }
            return 1
        }
        self.init(
            p01: quantile(semantics.quantileFractions[0]), p05: quantile(semantics.quantileFractions[1]), p10: quantile(semantics.quantileFractions[2]),
            p25: quantile(semantics.quantileFractions[3]), p50: quantile(semantics.quantileFractions[4]), p90: quantile(semantics.quantileFractions[5]),
            p99: quantile(semantics.quantileFractions[6])
        )
    }

    /// Exact CPU representation of the production estimator's input. The
    /// caller must provide the same 16x9 linear-light samples that the Metal
    /// estimator reads; no exact-percentile fallback is permitted here.
    public init(
        productionLinearSamples: [Float],
        semantics: HDRSceneStatisticsSemanticDefinition = .calibrationV4
    ) {
        self.init(linearSamples: productionLinearSamples, strategy: .production, semantics: semantics)
    }

    /// Offline estimator comparison used by correctness diagnostics. It
    /// mirrors bucketed percentile behavior while keeping alternative layouts
    /// out of the production shader.
    public init(
        linearSamples: [Float],
        strategy: HDRSceneHistogramStrategy,
        semantics: HDRSceneStatisticsSemanticDefinition = .calibrationV4
    ) {
        let binCount = strategy.binCount(using: semantics)
        var bins = Array(repeating: UInt32(0), count: binCount)
        for value in linearSamples where value.isFinite {
            let bin: Int
            switch strategy {
            case .linear16, .linear64:
                let clamped = min(max(value, Float(semantics.inputMinimum)), Float(semantics.histogramUpperExclusive))
                bin = min(Int(clamped * Float(binCount)), binCount - 1)
            case .log64:
                let clamped = min(max(value, pow(2, Float(semantics.histogramLogMinimumExponent))), Float(semantics.inputMaximum))
                let normalized = (log2(clamped) - Float(semantics.histogramLogMinimumExponent)) /
                    Float(semantics.histogramLogMaximumExponent - semantics.histogramLogMinimumExponent)
                bin = min(max(Int(normalized * Float(binCount)), 0), binCount - 1)
            case .shadowDense64:
                let clamped = min(max(value, Float(semantics.inputMinimum)), Float(semantics.histogramUpperExclusive))
                if clamped < Float(semantics.shadowDenseBreakpoint) {
                    bin = min(Int(clamped / Float(semantics.shadowDenseBreakpoint) * Float(semantics.shadowDenseLowerBinCount)), semantics.shadowDenseLowerBinCount - 1)
                } else {
                    bin = min(semantics.shadowDenseLowerBinCount + Int((clamped - Float(semantics.shadowDenseBreakpoint)) /
                        Float(semantics.shadowDenseUpperSpan) * Float(binCount - semantics.shadowDenseLowerBinCount)), binCount - 1)
                }
            }
            bins[bin] &+= 1
        }
        let total = bins.reduce(0, +)
        func quantile(_ fraction: Double) -> Float {
            guard total > 0 else { return Float(semantics.emptyAverage) }
            let target = max(UInt64(1), UInt64(Double(total) * fraction))
            var cumulative: UInt64 = 0
            for (index, count) in bins.enumerated() {
                cumulative += UInt64(count)
                guard cumulative >= target else { continue }
                switch strategy {
                case .linear16, .linear64:
                    return (Float(index) + Float(semantics.quantizationRounding)) / Float(binCount)
                case .log64:
                    let logCenter = Float(semantics.histogramLogMinimumExponent) +
                        (Float(index) + Float(semantics.quantizationRounding)) *
                        Float(semantics.histogramLogMaximumExponent - semantics.histogramLogMinimumExponent) /
                        Float(binCount)
                    return pow(2, logCenter)
                case .shadowDense64:
                    if index < semantics.shadowDenseLowerBinCount {
                        return (Float(index) + Float(semantics.quantizationRounding)) /
                            Float(semantics.shadowDenseLowerBinCount) * Float(semantics.shadowDenseBreakpoint)
                    }
                    return Float(semantics.shadowDenseBreakpoint) +
                        (Float(index - semantics.shadowDenseLowerBinCount) + Float(semantics.quantizationRounding)) /
                        Float(binCount - semantics.shadowDenseLowerBinCount) * Float(semantics.shadowDenseUpperSpan)
                }
            }
            return 1
        }
        self.init(
            p01: quantile(semantics.quantileFractions[0]), p05: quantile(semantics.quantileFractions[1]), p10: quantile(semantics.quantileFractions[2]),
            p25: quantile(semantics.quantileFractions[3]), p50: quantile(semantics.quantileFractions[4]), p90: quantile(semantics.quantileFractions[5]),
            p99: quantile(semantics.quantileFractions[6])
        )
    }

    /// Quantizes a linear sample exactly as the production atomic estimator
    /// does before accumulating its shared luminance sum.
    public static func productionLinearAverage(
        linearSamples: [Float],
        semantics: HDRSceneStatisticsSemanticDefinition = .calibrationV4
    ) -> Float {
        let finite = linearSamples.filter(\.isFinite).map {
            min(max($0, Float(semantics.inputMinimum)), Float(semantics.inputMaximum))
        }
        guard !finite.isEmpty else { return Float(semantics.emptyAverage) }
        let quantized = finite.reduce(UInt64(0)) { partial, value in
            partial + UInt64(value * Float(semantics.quantizationMaximum) + Float(semantics.quantizationRounding))
        }
        return min(
            max(Float(quantized) / Float(finite.count) / Float(semantics.quantizationMaximum), Float(semantics.averageClampMinimum)),
            Float(semantics.averageClampMaximum)
        )
    }

    /// Returns the sparse positions used by the Metal estimator for a source
    /// grid. This is shared by the offline parity harness and tests.
    public static func productionSamplePositions(
        width: Int,
        height: Int,
        semantics: HDRSceneStatisticsSemanticDefinition = .calibrationV4
    ) -> [(x: Int, y: Int)] {
        guard width > 0, height > 0 else { return [] }
        return (0..<semantics.proxyHeight).flatMap { gy in
            (0..<semantics.proxyWidth).map { gx in
                (
                    min((gx * width + width / 2) / semantics.proxyWidth, width - 1),
                    min((gy * height + height / 2) / semantics.proxyHeight, height - 1)
                )
            }
        }
    }

    /// Relative coordinates for the shadow band. P05 is deliberately kept
    /// above the black floor and P10/P25 define a scene-dependent shoulder.
    /// The lower bound is clamped to avoid a degenerate interval in flat shots.
    public func shadowFloor(using semantics: HDRSceneStatisticsSemanticDefinition = .calibrationV4) -> Float {
        min(max(p05, Float(semantics.shadowFloorMinimum)), Float(semantics.shadowFloorMaximum))
    }

    public var shadowFloor: Float { shadowFloor(using: .calibrationV4) }

    public func shadowTop(using semantics: HDRSceneStatisticsSemanticDefinition = .calibrationV4) -> Float {
        let floor = shadowFloor(using: semantics)
        let candidate = max(
            p10 + Float(semantics.shadowTopInterpolation) * (p25 - p10),
            floor + Float(semantics.shadowTopMinimumDelta)
        )
        return min(max(candidate, floor + Float(semantics.shadowTopMinimumDelta)), Float(semantics.shadowTopMaximum))
    }

    public var shadowTop: Float { shadowTop(using: .calibrationV4) }

    public func averageLuminance(using semantics: HDRSceneStatisticsSemanticDefinition = .calibrationV4) -> Float {
        min(max(p50, Float(semantics.averageClampMinimum)), Float(semantics.averageClampMaximum))
    }

    public var averageLuminance: Float { averageLuminance(using: .calibrationV4) }

    /// Causal percentile smoothing shared by the V4 scene state and the
    /// development-only V6.2 budget. It has no look-ahead and mirrors the
    /// scene-anchor transition's stability factor.
    public static func causalBlend(
        previous: HDRSceneStatistics,
        target: HDRSceneStatistics,
        stability: Float,
        sceneCut: Bool,
        deltaSeconds: Double? = nil,
        semantics: HDRSceneStatisticsSemanticDefinition = .calibrationV4
    ) -> HDRSceneStatistics {
        let alpha = sceneCut
            ? 1
            : deltaSeconds.map {
                HDRTemporalControlState.timeBasedAlpha(
                    stability: stability,
                    deltaSeconds: $0,
                    semantics: semantics
                )
            } ?? (1 - min(max(stability, 0), 1))
        func blend(_ lhs: Float, _ rhs: Float) -> Float {
            lhs + alpha * (rhs - lhs)
        }
        return HDRSceneStatistics(
            p01: blend(previous.p01, target.p01),
            p05: blend(previous.p05, target.p05),
            p10: blend(previous.p10, target.p10),
            p25: blend(previous.p25, target.p25),
            p50: blend(previous.p50, target.p50),
            p90: blend(previous.p90, target.p90),
            p99: blend(previous.p99, target.p99)
        )
    }

    public var isFinite: Bool {
        [p01, p05, p10, p25, p50, p90, p99].allSatisfy(\.isFinite)
    }
}

/// Pure, causal temporal-control state shared by the realtime processor and
/// offline calibration diagnostics.  The GPU estimator supplies a frame's
/// average/statistics after that frame has been rendered; callers therefore
/// apply this state before encoding the next frame.  Keeping the transition
/// here prevents the calibration harness from silently inventing a different
/// temporal model.
public struct HDRTemporalControlState: Equatable, Sendable, Codable {
    public private(set) var adaptation: Float
    public private(set) var shadowFloor: Float
    public private(set) var shadowTop: Float
    public private(set) var shadowStatisticsValid: Bool

    private var smoothedEstimate: Float
    private var previousAutomaticAverage: Float?
    private var lastAutomaticSequence: UInt64
    private var previousShadowAverage: Float?
    private var lastShadowSequence: UInt64
    private var previousAutomaticTimestamp: Double?
    private var previousShadowTimestamp: Double?
    private var lastAutomaticDelta: Double?
    private var lastShadowDelta: Double?
    private var semantics: HDRSceneStatisticsSemanticDefinition

    public init(semantics: HDRSceneStatisticsSemanticDefinition = .calibrationV4) {
        adaptation = 1
        self.semantics = semantics
        shadowFloor = HDRSceneStatistics.neutral.shadowFloor(using: semantics)
        shadowTop = HDRSceneStatistics.neutral.shadowTop(using: semantics)
        shadowStatisticsValid = false
        smoothedEstimate = 0.5
        previousAutomaticAverage = nil
        lastAutomaticSequence = 0
        previousShadowAverage = nil
        lastShadowSequence = 0
        previousAutomaticTimestamp = nil
        previousShadowTimestamp = nil
        lastAutomaticDelta = nil
        lastShadowDelta = nil
    }

    public var automaticSequence: UInt64 { lastAutomaticSequence }
    public var shadowSequence: UInt64 { lastShadowSequence }
    public var lastAutomaticDeltaSeconds: Double? { lastAutomaticDelta }
    public var lastShadowDeltaSeconds: Double? { lastShadowDelta }

    /// The reference frame duration preserves the old 60 Hz response when a
    /// caller has no media timestamp. Timestamped processing uses the same
    /// time constant with a real content delta instead of a frame-count alpha.
    public static var referenceFrameDurationSeconds: Double {
        HDRSceneStatisticsSemanticDefinition.calibrationV4.referenceFrameDurationSeconds
    }
    public static var maximumContinuousDeltaSeconds: Double {
        HDRSceneStatisticsSemanticDefinition.calibrationV4.maximumContinuousDeltaSeconds
    }

    public static func timeConstantSeconds(
        stability: Float,
        referenceFrameDurationSeconds: Double? = nil,
        semantics: HDRSceneStatisticsSemanticDefinition = .calibrationV4
    ) -> Double {
        let oneMinusStability = min(max(1 - stability, 0), 1)
        guard oneMinusStability > 0 else { return semantics.timeConstantFallbackSeconds }
        let frameDuration = referenceFrameDurationSeconds ?? semantics.referenceFrameDurationSeconds
        return max(
            frameDuration / -log(Double(max(oneMinusStability, Float(semantics.timeConstantStabilityFloor)))),
            semantics.timeConstantMinimumSeconds
        )
    }

    public static func timeBasedAlpha(
        stability: Float,
        deltaSeconds: Double,
        semantics: HDRSceneStatisticsSemanticDefinition = .calibrationV4
    ) -> Float {
        guard deltaSeconds.isFinite, deltaSeconds > 0 else { return 0 }
        let tau = timeConstantSeconds(stability: stability, semantics: semantics)
        return Float(1 - exp(-deltaSeconds / tau))
    }

    public mutating func reset() {
        self = HDRTemporalControlState(semantics: semantics)
    }

    public mutating func updateAverage(averageLuminance: Float, stability: Float, sceneCut: Bool) {
        guard averageLuminance.isFinite else { return }
        let target = Self.clampAverage(averageLuminance, semantics: semantics)
        applyAverage(
            target: target,
            stability: stability,
            sceneCut: sceneCut,
            deltaSeconds: semantics.referenceFrameDurationSeconds
        )
    }

    @discardableResult
    public mutating func updateAutomaticAverage(
        averageLuminance: Float,
        stability: Float,
        sequence: UInt64,
        timestampSeconds: Double? = nil
    ) -> Bool {
        guard averageLuminance.isFinite, sequence > lastAutomaticSequence else { return false }
        lastAutomaticSequence = sequence
        let target = Self.clampAverage(averageLuminance, semantics: semantics)
        let sceneCut = Self.isSceneCut(previous: previousAutomaticAverage, current: target, semantics: semantics)
        previousAutomaticAverage = target
        let timing = Self.timing(
            timestampSeconds: timestampSeconds,
            previousTimestamp: &previousAutomaticTimestamp,
            semantics: semantics
        )
        lastAutomaticDelta = timing.deltaSeconds
        applyAverage(
            target: target,
            stability: stability,
            sceneCut: sceneCut || timing.discontinuity,
            deltaSeconds: timing.deltaSeconds
        )
        return sceneCut || timing.discontinuity
    }

    public mutating func updateStatistics(
        _ statistics: HDRSceneStatistics,
        stability: Float,
        sceneCut: Bool
    ) {
        guard statistics.isFinite else { return }
        applyStatistics(
            statistics,
            stability: stability,
            sceneCut: sceneCut || !shadowStatisticsValid,
            deltaSeconds: semantics.referenceFrameDurationSeconds
        )
    }

    @discardableResult
    public mutating func updateAutomaticStatistics(
        _ statistics: HDRSceneStatistics,
        averageLuminance: Float,
        stability: Float,
        sequence: UInt64,
        timestampSeconds: Double? = nil
    ) -> Bool {
        guard statistics.isFinite, averageLuminance.isFinite, sequence > lastShadowSequence else { return false }
        lastShadowSequence = sequence
        let target = Self.clampAverage(averageLuminance, semantics: semantics)
        let sceneCut = Self.isSceneCut(previous: previousShadowAverage, current: target, semantics: semantics)
        previousShadowAverage = target
        let timing = Self.timing(
            timestampSeconds: timestampSeconds,
            previousTimestamp: &previousShadowTimestamp,
            semantics: semantics
        )
        lastShadowDelta = timing.deltaSeconds
        applyStatistics(
            statistics,
            stability: stability,
            sceneCut: sceneCut || timing.discontinuity || !shadowStatisticsValid,
            deltaSeconds: timing.deltaSeconds
        )
        return sceneCut || timing.discontinuity
    }

    public static func isSceneCut(
        previous: Float?,
        current: Float,
        semantics: HDRSceneStatisticsSemanticDefinition = .calibrationV4
    ) -> Bool {
        guard let previous else { return true }
        let minimum = Float(semantics.sceneCutLuminanceFloor)
        let threshold = Float(semantics.sceneCutLog2Threshold)
        return abs(log2(max(current, minimum) / max(previous, minimum))) > threshold
    }

    private mutating func applyAverage(
        target: Float,
        stability: Float,
        sceneCut: Bool,
        deltaSeconds: Double
    ) {
        if sceneCut {
            smoothedEstimate = target
        } else {
            let alpha = Self.timeBasedAlpha(stability: stability, deltaSeconds: deltaSeconds, semantics: semantics)
            smoothedEstimate += alpha * (target - smoothedEstimate)
        }
        adaptation = Self.adaptation(for: smoothedEstimate, semantics: semantics)
    }

    private mutating func applyStatistics(
        _ statistics: HDRSceneStatistics,
        stability: Float,
        sceneCut: Bool,
        deltaSeconds: Double
    ) {
        let targetFloor = statistics.shadowFloor(using: semantics)
        let targetTop = statistics.shadowTop(using: semantics)
        let alpha = Self.timeBasedAlpha(stability: stability, deltaSeconds: deltaSeconds, semantics: semantics)
        if sceneCut {
            shadowFloor = targetFloor
            shadowTop = targetTop
        } else {
            shadowFloor += alpha * (targetFloor - shadowFloor)
            shadowTop += alpha * (targetTop - shadowTop)
        }
        shadowTop = max(shadowTop, shadowFloor + Float(semantics.shadowTopMinimumDelta))
        shadowStatisticsValid = true
    }

    public static func adaptation(
        for smoothedAverage: Float,
        semantics: HDRSceneStatisticsSemanticDefinition = .calibrationV4
    ) -> Float {
        min(
            max(
                Float(semantics.adaptationBase) +
                    Float(semantics.adaptationCoefficient) * (Float(semantics.adaptationAverageCenter) - smoothedAverage),
                Float(semantics.adaptationMinimum)
            ),
            Float(semantics.adaptationMaximum)
        )
    }

    private static func clampAverage(
        _ value: Float,
        semantics: HDRSceneStatisticsSemanticDefinition = .calibrationV4
    ) -> Float {
        min(max(value, Float(semantics.averageClampMinimum)), Float(semantics.averageClampMaximum))
    }

    private static func timing(
        timestampSeconds: Double?,
        previousTimestamp: inout Double?,
        semantics: HDRSceneStatisticsSemanticDefinition = .calibrationV4
    ) -> (deltaSeconds: Double, discontinuity: Bool) {
        guard let timestampSeconds, timestampSeconds.isFinite else {
            return (semantics.referenceFrameDurationSeconds, false)
        }
        guard let previous = previousTimestamp else {
            previousTimestamp = timestampSeconds
            return (semantics.referenceFrameDurationSeconds, false)
        }
        let delta = timestampSeconds - previous
        previousTimestamp = timestampSeconds
        guard delta > 0, delta.isFinite else {
            // A repeated or reversed media timestamp is a discontinuity. The
            // caller's seek/reset path also clears this state explicitly.
            return (0, true)
        }
        if delta > semantics.maximumContinuousDeltaSeconds {
            return (delta, true)
        }
        return (delta, false)
    }
}

public enum HDRConfigurationError: Error, LocalizedError, Equatable, Sendable {
    case nonFinite(String)
    case mustBePositive(String)
    case peakMustExceedPaperWhite
    case valueOutOfRange(String)

    public var errorDescription: String? {
        switch self {
        case .nonFinite(let name):
            return "HDR configuration value is not finite: \(name)"
        case .mustBePositive(let name):
            return "HDR configuration value must be greater than zero: \(name)"
        case .peakMustExceedPaperWhite:
            return "peakNits must be greater than paperWhiteNits"
        case .valueOutOfRange(let name):
            return "HDR configuration value is outside its supported range: \(name)"
        }
    }
}

/// Parameters shared by all tone-mapping presets. Changing this value does
/// not recreate Metal libraries or pipeline states.
public struct HDRConfiguration: Sendable, Equatable {
    public var paperWhiteNits: Float
    public var peakNits: Float

    /// 0...1. Controls how much of the configured headroom is used by the
    /// upper part of the SDR signal. It is not a brightness multiplier.
    public var highlightStrength: Float

    /// 0...1. Moves the shoulder transition earlier and makes the highlight
    /// expansion steeper while keeping shadows anchored.
    public var contrastStrength: Float

    /// 0...1. Reduces chroma as luminance gain grows and when a channel would
    /// exceed the configured output range.
    public var saturationCompensation: Float

    /// 0...1. Limits expansion and chroma changes in the shadow region.
    public var shadowProtection: Float

    /// 0...1. Controls the default asynchronous causal luminance estimator.
    /// Explicit estimates remain available for offline parity and controlled
    /// scene-boundary updates.
    public var temporalStability: Float

    public var outputMode: HDROutputMode
    public var toneCurveRevision: HDRToneCurveRevision
    /// Explicit strategy for the causal scene histogram. The calibrated V4
    /// production preset uses `linear64`; other strategies are diagnostic
    /// candidates unless a caller explicitly selects them.
    public var sceneHistogramStrategy: HDRSceneHistogramStrategy

    /// Spatial reconstruction for 4:2:0 chroma planes. This is independent of
    /// luma normalization, tone expansion, temporal adaptation, and the scene
    /// histogram estimator.
    public var chromaReconstructionMode: HDRChromaReconstructionMode

    /// Content/mastering-domain linear headroom. In EDR mode, 1.0 is diffuse
    /// SDR reference white and this value is the largest content signal the
    /// core may emit. Physical display headroom is presentation state and must
    /// not be written into this configuration.
    public var masteringHeadroom: Float

    /// Content ceiling used by the EDR output contract. A preset may describe
    /// a mastering peak above its requested EDR headroom; EDR output is
    /// bounded by the smaller value. PQ output retains the configured peak.
    public var effectiveOutputHeadroom: Float {
        let peakRatio = peakNits / paperWhiteNits
        return outputMode == .edr ? min(peakRatio, masteringHeadroom) : peakRatio
    }

    public var effectivePeakNits: Float {
        paperWhiteNits * effectiveOutputHeadroom
    }

    /// Source-compatible alias retained for clients built against V1/V2.
    /// Despite its legacy name this is content/mastering headroom, never the
    /// current NSScreen EDR value.
    @available(*, deprecated, renamed: "masteringHeadroom")
    public var displayHeadroom: Float {
        get { masteringHeadroom }
        set { masteringHeadroom = newValue }
    }

    public var inputFallbackPolicy: HDRInputFallbackPolicy

    /// Versioned interpretation for an explicitly BT.709-tagged SDR source.
    /// Source transfer metadata remains separate and authoritative for sRGB,
    /// explicit gamma, and linear inputs.
    public var sdrInterpretationPolicy: SDRInputInterpretationPolicy

    /// Explicit behavior when a source has no transfer metadata.
    public var untaggedSDRFallback: SDRUntaggedFallbackPolicy

    /// Normalized BT.1886 reference-display parameters used when the selected
    /// SDR policy is `bt1886ReferenceDisplay`.
    public var bt1886Parameters: BT1886TransferParameters

    /// Color arithmetic consumed by both the CPU reference and production
    /// Metal path.  Calibration binds this exact value through its metric and
    /// runner semantic identities.
    public var colorScience: HDRColorScienceSemanticDefinition

    /// Tone arithmetic consumed by both the CPU reference and production
    /// Metal path.  This prevents renderer literals from becoming an
    /// unsealed calibration input.
    public var toneMapping: HDRToneMappingSemanticDefinition

    /// Development-only V6 structural controls. They are ignored by every
    /// revision except `sceneRelativeV6Candidate`, so calibrated V4 retains
    /// its exact production arithmetic and output.
    public var developmentLowMidFadePosition: Float
    public var developmentLowMidStrength: Float

    /// Development-only V6.2 scene-adaptive expansion controls. They are
    /// ignored by every revision except `sceneAdaptiveV62Candidate`; the
    /// production V4 branch never reads them.
    public var developmentExpansionController: HDRV62ExpansionController
    public var developmentExpansionMinimumBudget: Float
    public var developmentExpansionHighlightLow: Float
    public var developmentExpansionHighlightHigh: Float
    public var developmentExpansionRangeLow: Float
    public var developmentExpansionRangeHigh: Float
    public var developmentExpansionMidtoneLow: Float
    public var developmentExpansionMidtoneHigh: Float
    public var developmentExpansionCombinedHighlightWeight: Float
    public var developmentExpansionCombinedRangeWeight: Float
    public var developmentExpansionCombinedMidtoneWeight: Float

    public init(
        paperWhiteNits: Float = 203,
        peakNits: Float = 1_000,
        highlightStrength: Float = 0.55,
        contrastStrength: Float = 0.50,
        saturationCompensation: Float = 0.55,
        shadowProtection: Float = 0.85,
        temporalStability: Float = 0.90,
        outputMode: HDROutputMode = .edr,
        displayHeadroom: Float = 4.0,
        toneCurveRevision: HDRToneCurveRevision = .legacyV2,
        sceneHistogramStrategy: HDRSceneHistogramStrategy = .production,
        chromaReconstructionMode: HDRChromaReconstructionMode = .nearest,
        inputFallbackPolicy: HDRInputFallbackPolicy = .bt709VideoRange,
        sdrInterpretationPolicy: SDRInputInterpretationPolicy = .bt709SourceLinear,
        untaggedSDRFallback: SDRUntaggedFallbackPolicy = .assumeBT709SourceLinear,
        bt1886Parameters: BT1886TransferParameters = .idealReference,
        colorScience: HDRColorScienceSemanticDefinition = .calibrationV4,
        toneMapping: HDRToneMappingSemanticDefinition = .calibrationV4,
        developmentLowMidFadePosition: Float = 0.55,
        developmentLowMidStrength: Float = 0.08,
        developmentExpansionController: HDRV62ExpansionController = .compactCombined,
        developmentExpansionMinimumBudget: Float = 0.35,
        developmentExpansionHighlightLow: Float = 0.05,
        developmentExpansionHighlightHigh: Float = 0.35,
        developmentExpansionRangeLow: Float = 1.0,
        developmentExpansionRangeHigh: Float = 3.5,
        developmentExpansionMidtoneLow: Float = 0.15,
        developmentExpansionMidtoneHigh: Float = 0.55,
        developmentExpansionCombinedHighlightWeight: Float = 0.40,
        developmentExpansionCombinedRangeWeight: Float = 0.35,
        developmentExpansionCombinedMidtoneWeight: Float = 0.25
    ) {
        self.paperWhiteNits = paperWhiteNits
        self.peakNits = peakNits
        self.highlightStrength = highlightStrength
        self.contrastStrength = contrastStrength
        self.saturationCompensation = saturationCompensation
        self.shadowProtection = shadowProtection
        self.temporalStability = temporalStability
        self.outputMode = outputMode
        self.masteringHeadroom = displayHeadroom
        self.toneCurveRevision = toneCurveRevision
        self.sceneHistogramStrategy = sceneHistogramStrategy
        self.chromaReconstructionMode = chromaReconstructionMode
        self.inputFallbackPolicy = inputFallbackPolicy
        self.sdrInterpretationPolicy = sdrInterpretationPolicy
        self.untaggedSDRFallback = untaggedSDRFallback
        self.bt1886Parameters = bt1886Parameters
        self.colorScience = colorScience
        self.toneMapping = toneMapping
        self.developmentLowMidFadePosition = developmentLowMidFadePosition
        self.developmentLowMidStrength = developmentLowMidStrength
        self.developmentExpansionController = developmentExpansionController
        self.developmentExpansionMinimumBudget = developmentExpansionMinimumBudget
        self.developmentExpansionHighlightLow = developmentExpansionHighlightLow
        self.developmentExpansionHighlightHigh = developmentExpansionHighlightHigh
        self.developmentExpansionRangeLow = developmentExpansionRangeLow
        self.developmentExpansionRangeHigh = developmentExpansionRangeHigh
        self.developmentExpansionMidtoneLow = developmentExpansionMidtoneLow
        self.developmentExpansionMidtoneHigh = developmentExpansionMidtoneHigh
        self.developmentExpansionCombinedHighlightWeight = developmentExpansionCombinedHighlightWeight
        self.developmentExpansionCombinedRangeWeight = developmentExpansionCombinedRangeWeight
        self.developmentExpansionCombinedMidtoneWeight = developmentExpansionCombinedMidtoneWeight
    }

    public static let natural = HDRConfiguration(
        paperWhiteNits: 203,
        peakNits: 600,
        highlightStrength: 0.34,
        contrastStrength: 0.38,
        saturationCompensation: 0.62,
        shadowProtection: 0.90,
        temporalStability: 0.92,
        outputMode: .edr,
        displayHeadroom: 3.0
    )

    public static let hdr = HDRConfiguration(
        paperWhiteNits: 203,
        peakNits: 1_000,
        highlightStrength: 0.55,
        contrastStrength: 0.50,
        saturationCompensation: 0.55,
        shadowProtection: 0.85,
        temporalStability: 0.90,
        outputMode: .edr,
        displayHeadroom: 4.0
    )

    public static let vivid = HDRConfiguration(
        paperWhiteNits: 203,
        peakNits: 1_500,
        highlightStrength: 0.70,
        contrastStrength: 0.64,
        saturationCompensation: 0.42,
        shadowProtection: 0.78,
        temporalStability: 0.88,
        outputMode: .edr,
        displayHeadroom: 7.0
    )

    /// Offline-calibrated V1 preset retained for historical A/B comparison.
    /// Its headroom is mastering intent, not display capability.
    public static let calibratedV1 = HDRConfiguration(
        paperWhiteNits: 203,
        peakNits: 1_000,
        highlightStrength: 0.7680667,
        contrastStrength: 0.72261286,
        saturationCompensation: 0.26359826,
        shadowProtection: 0.94007397,
        temporalStability: 0.8719273,
        outputMode: .edr,
        displayHeadroom: 4.9261084
    )

    /// Historical video-level calibrated V2 preset retained for A/B comparison
    /// and reproduction. Runtime display mapping is a separate presentation
    /// operation and never mutates this signal curve.
    public static let calibratedV2 = HDRConfiguration(
        paperWhiteNits: 222.02173,
        peakNits: 1_080.554,
        highlightStrength: 0.5913241,
        contrastStrength: 0.81415236,
        saturationCompensation: 0.22561,
        shadowProtection: 0.86211497,
        temporalStability: 0.85478514,
        outputMode: .edr,
        displayHeadroom: 4.8668838
    )

    /// Rejected V3 experiment candidate retained for reproducible A/B and
    /// runtime measurements. It is intentionally not named `calibratedV3` and
    /// must not replace the promoted calibratedV4 preset.
    public static let calibratedV3Candidate = HDRConfiguration(
        paperWhiteNits: 235,
        peakNits: 1_203.3646,
        highlightStrength: 0.55232275,
        contrastStrength: 0.8612941,
        saturationCompensation: 0.27276167,
        shadowProtection: 0.46563143,
        temporalStability: 0.65599275,
        outputMode: .edr,
        displayHeadroom: 5.1207004,
        toneCurveRevision: .shadowProtectedV3
    )

    /// Production HDR preset promoted from the successfully validated V4
    /// candidate. Its headroom is mastering intent, not display capability.
    public static let calibratedV4 = HDRConfiguration(
        paperWhiteNits: 190,
        peakNits: 1008.6863,
        highlightStrength: 0.6208221,
        contrastStrength: 0.90542316,
        saturationCompensation: 0.43140942,
        shadowProtection: 0.4755874,
        temporalStability: 0.7308984,
        outputMode: .edr,
        displayHeadroom: 5.308875,
        toneCurveRevision: .sceneRelativeV4,
        sceneHistogramStrategy: .production
    )

    public func validated() throws -> HDRConfiguration {
        let finiteValues: [(String, Float)] = [
            ("paperWhiteNits", paperWhiteNits),
            ("peakNits", peakNits),
            ("highlightStrength", highlightStrength),
            ("contrastStrength", contrastStrength),
            ("saturationCompensation", saturationCompensation),
            ("shadowProtection", shadowProtection),
            ("temporalStability", temporalStability),
            ("masteringHeadroom", masteringHeadroom),
            ("developmentLowMidFadePosition", developmentLowMidFadePosition),
            ("developmentLowMidStrength", developmentLowMidStrength),
            ("developmentExpansionMinimumBudget", developmentExpansionMinimumBudget),
            ("developmentExpansionHighlightLow", developmentExpansionHighlightLow),
            ("developmentExpansionHighlightHigh", developmentExpansionHighlightHigh),
            ("developmentExpansionRangeLow", developmentExpansionRangeLow),
            ("developmentExpansionRangeHigh", developmentExpansionRangeHigh),
            ("developmentExpansionMidtoneLow", developmentExpansionMidtoneLow),
            ("developmentExpansionMidtoneHigh", developmentExpansionMidtoneHigh),
            ("developmentExpansionCombinedHighlightWeight", developmentExpansionCombinedHighlightWeight),
            ("developmentExpansionCombinedRangeWeight", developmentExpansionCombinedRangeWeight),
            ("developmentExpansionCombinedMidtoneWeight", developmentExpansionCombinedMidtoneWeight)
        ]
        for (name, value) in finiteValues where !value.isFinite {
            throw HDRConfigurationError.nonFinite(name)
        }
        guard paperWhiteNits > 0 else {
            throw HDRConfigurationError.mustBePositive("paperWhiteNits")
        }
        guard peakNits > paperWhiteNits else {
            throw HDRConfigurationError.peakMustExceedPaperWhite
        }
        guard bt1886Parameters.isValid else {
            throw HDRConfigurationError.valueOutOfRange("bt1886Parameters")
        }
        guard colorScience.isValid else {
            throw HDRConfigurationError.valueOutOfRange("colorScience")
        }
        guard toneMapping.isValid else {
            throw HDRConfigurationError.valueOutOfRange("toneMapping")
        }
        guard peakNits <= 10_000 else {
            throw HDRConfigurationError.valueOutOfRange("peakNits (maximum 10,000)")
        }
        guard paperWhiteNits <= 2_000 else {
            throw HDRConfigurationError.valueOutOfRange("paperWhiteNits (maximum 2,000)")
        }
        guard (0...1).contains(highlightStrength) else {
            throw HDRConfigurationError.valueOutOfRange("highlightStrength (0...1)")
        }
        guard (0...1).contains(contrastStrength) else {
            throw HDRConfigurationError.valueOutOfRange("contrastStrength (0...1)")
        }
        guard (0...1).contains(saturationCompensation) else {
            throw HDRConfigurationError.valueOutOfRange("saturationCompensation (0...1)")
        }
        guard (0...1).contains(shadowProtection) else {
            throw HDRConfigurationError.valueOutOfRange("shadowProtection (0...1)")
        }
        guard (0...1).contains(temporalStability) else {
            throw HDRConfigurationError.valueOutOfRange("temporalStability (0...1)")
        }
        guard masteringHeadroom >= 1, masteringHeadroom <= 64 else {
            throw HDRConfigurationError.valueOutOfRange("masteringHeadroom (1...64)")
        }
        guard (0...1).contains(developmentLowMidFadePosition) else {
            throw HDRConfigurationError.valueOutOfRange("developmentLowMidFadePosition (0...1)")
        }
        guard (0...1).contains(developmentLowMidStrength) else {
            throw HDRConfigurationError.valueOutOfRange("developmentLowMidStrength (0...1)")
        }
        guard (0...1).contains(developmentExpansionMinimumBudget) else {
            throw HDRConfigurationError.valueOutOfRange("developmentExpansionMinimumBudget (0...1)")
        }
        guard (0...1).contains(developmentExpansionHighlightLow),
              (0...1).contains(developmentExpansionHighlightHigh),
              developmentExpansionHighlightHigh >= developmentExpansionHighlightLow else {
            throw HDRConfigurationError.valueOutOfRange("developmentExpansion highlight range")
        }
        guard developmentExpansionRangeLow.isFinite,
              developmentExpansionRangeHigh.isFinite,
              developmentExpansionRangeLow >= 0,
              developmentExpansionRangeHigh >= developmentExpansionRangeLow else {
            throw HDRConfigurationError.valueOutOfRange("developmentExpansion dynamic-range range")
        }
        guard (0...1).contains(developmentExpansionMidtoneLow),
              (0...1).contains(developmentExpansionMidtoneHigh),
              developmentExpansionMidtoneHigh >= developmentExpansionMidtoneLow else {
            throw HDRConfigurationError.valueOutOfRange("developmentExpansion midtone range")
        }
        guard developmentExpansionCombinedHighlightWeight >= 0,
              developmentExpansionCombinedRangeWeight >= 0,
              developmentExpansionCombinedMidtoneWeight >= 0,
              developmentExpansionCombinedHighlightWeight +
                developmentExpansionCombinedRangeWeight +
                developmentExpansionCombinedMidtoneWeight > 0 else {
            throw HDRConfigurationError.valueOutOfRange("developmentExpansion combined weights")
        }
        return self
    }
}
