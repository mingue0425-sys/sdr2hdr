import Foundation

/// The transfer/output convention expected by the consumer of an HDRFrame.
public enum HDROutputMode: String, CaseIterable, Sendable {
    /// Linear extended RGB. 1.0 is SDR reference white and values above 1.0
    /// use display EDR headroom. The presentation layer supplies the matching
    /// extended color space to its CAMetalLayer/MTKView.
    case edr = "EDR"

    /// ST.2084/PQ RGB normalized to the absolute 0...10,000 nit PQ range.
    case pq = "PQ"
}

/// Policy used only when a CVPixelBuffer has no color attachments at all.
public enum HDRInputFallbackPolicy: String, CaseIterable, Sendable {
    case bt709VideoRange
    case bt709FullRange
    case requireMetadata
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
        self == .linear16 ? 16 : 64
    }
}

/// Low-cost source-luminance statistics used by the V4 scene-relative shadow
/// controller. Values are linear BT.709 luminance normalized to SDR white.
/// The runtime estimator supplies these one frame late; offline calibration
/// feeds the same state transition after each frame.
public struct HDRSceneStatistics: Equatable, Sendable, Codable {
    public static let productionProxyWidth = 16
    public static let productionProxyHeight = 9
    /// The production estimator retains the existing 16x9 sample count but
    /// uses 64 linear bins so the shadow percentiles do not collapse every
    /// value below 0.0625 into one bucket.
    public static let productionHistogramBinCount = 64
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

    public static let neutral = HDRSceneStatistics(
        p01: 0.002, p05: 0.01, p10: 0.025, p25: 0.20,
        p50: 0.50, p90: 0.90, p99: 1.0
    )

    public init(samples: [Float]) {
        let finite = samples.filter { $0.isFinite }.map { min(max($0, 0), 1) }.sorted()
        func percentile(_ fraction: Double) -> Float {
            guard !finite.isEmpty else { return 0 }
            let index = min(max(Int(Double(finite.count - 1) * fraction), 0), finite.count - 1)
            return finite[index]
        }
        self.init(
            p01: percentile(0.01), p05: percentile(0.05), p10: percentile(0.10),
            p25: percentile(0.25), p50: percentile(0.50), p90: percentile(0.90),
            p99: percentile(0.99)
        )
    }

    /// Converts the normalized BT.709 luma signal used by the calibration
    /// proxy into the same linear-light samples used by the Metal estimator.
    public init(sdrBT709Signals: [Float]) {
        self.init(samples: sdrBT709Signals.map { HDRColorMath.inverseBT709($0) })
    }

    public static func linearAverage(sdrBT709Signals: [Float]) -> Float {
        let values = sdrBT709Signals.map { HDRColorMath.inverseBT709($0) }.filter(\.isFinite)
        guard !values.isEmpty else { return 0.5 }
        return min(max(values.reduce(0, +) / Float(values.count), 0.001), 1)
    }

    /// Converts the fixed 64-bin GPU histogram into percentile estimates. The
    /// sparse proxy remains intentionally low cost; the extra bins improve
    /// shadow ordering without changing the 16x9 sampling pattern.
    public init(histogram: [UInt32]) {
        self.init(histogram: histogram, strategy: .production)
    }

    /// Decodes the fixed storage layout using the strategy that encoded it.
    /// Linear16 still uses the first 16 slots of the shared 64-slot buffer;
    /// log and shadow-dense strategies use all 64 slots.
    public init(histogram: [UInt32], strategy: HDRSceneHistogramStrategy) {
        let storage = Array(histogram.prefix(Self.productionHistogramBinCount)) +
            Array(repeating: 0, count: max(0, Self.productionHistogramBinCount - histogram.count))
        let bins = Array(storage.prefix(strategy.binCount))
        let total = bins.reduce(0, +)
        func quantile(_ fraction: Double) -> Float {
            guard total > 0 else { return 0 }
            let target = max(UInt64(1), UInt64(Double(total) * fraction))
            var cumulative: UInt64 = 0
            for (index, count) in bins.enumerated() {
                cumulative += UInt64(count)
                if cumulative >= target {
                    switch strategy {
                    case .linear16, .linear64:
                        return (Float(index) + 0.5) / Float(strategy.binCount)
                    case .log64:
                        let logCenter = -16 + (Float(index) + 0.5) * 16 / Float(strategy.binCount)
                        return pow(2, logCenter)
                    case .shadowDense64:
                        if index < 32 {
                            return (Float(index) + 0.5) / 32 * 0.125
                        }
                        return 0.125 + (Float(index - 32) + 0.5) / 32 * 0.875
                    }
                }
            }
            return 1
        }
        self.init(
            p01: quantile(0.01), p05: quantile(0.05), p10: quantile(0.10),
            p25: quantile(0.25), p50: quantile(0.50), p90: quantile(0.90),
            p99: quantile(0.99)
        )
    }

    /// Exact CPU representation of the production estimator's input. The
    /// caller must provide the same 16x9 linear-light samples that the Metal
    /// estimator reads; no exact-percentile fallback is permitted here.
    public init(productionLinearSamples: [Float]) {
        self.init(linearSamples: productionLinearSamples, strategy: .production)
    }

    /// Offline estimator comparison used by correctness diagnostics. It
    /// mirrors bucketed percentile behavior while keeping alternative layouts
    /// out of the production shader.
    public init(linearSamples: [Float], strategy: HDRSceneHistogramStrategy) {
        let binCount: Int
        switch strategy {
        case .linear16:
            binCount = 16
        case .linear64, .log64, .shadowDense64:
            binCount = 64
        }
        var bins = Array(repeating: UInt32(0), count: binCount)
        for value in linearSamples where value.isFinite {
            let bin: Int
            switch strategy {
            case .linear16, .linear64:
                let clamped = min(max(value, 0), 0.999999)
                bin = min(Int(clamped * Float(binCount)), binCount - 1)
            case .log64:
                let clamped = min(max(value, pow(2, -16)), 1)
                let normalized = (log2(clamped) + 16) / 16
                bin = min(max(Int(normalized * Float(binCount)), 0), binCount - 1)
            case .shadowDense64:
                let clamped = min(max(value, 0), 0.999999)
                if clamped < 0.125 {
                    bin = min(Int(clamped / 0.125 * 32), 31)
                } else {
                    bin = min(32 + Int((clamped - 0.125) / 0.875 * 32), 63)
                }
            }
            bins[bin] &+= 1
        }
        let total = bins.reduce(0, +)
        func quantile(_ fraction: Double) -> Float {
            guard total > 0 else { return 0 }
            let target = max(UInt64(1), UInt64(Double(total) * fraction))
            var cumulative: UInt64 = 0
            for (index, count) in bins.enumerated() {
                cumulative += UInt64(count)
                guard cumulative >= target else { continue }
                switch strategy {
                case .linear16, .linear64:
                    return (Float(index) + 0.5) / Float(binCount)
                case .log64:
                    let logCenter = -16 + (Float(index) + 0.5) * 16 / Float(binCount)
                    return pow(2, logCenter)
                case .shadowDense64:
                    if index < 32 {
                        return (Float(index) + 0.5) / 32 * 0.125
                    }
                    return 0.125 + (Float(index - 32) + 0.5) / 32 * 0.875
                }
            }
            return 1
        }
        self.init(
            p01: quantile(0.01), p05: quantile(0.05), p10: quantile(0.10),
            p25: quantile(0.25), p50: quantile(0.50), p90: quantile(0.90),
            p99: quantile(0.99)
        )
    }

    /// Quantizes a linear sample exactly as the production atomic estimator
    /// does before accumulating its shared luminance sum.
    public static func productionLinearAverage(linearSamples: [Float]) -> Float {
        let finite = linearSamples.filter(\.isFinite).map { min(max($0, 0), 1) }
        guard !finite.isEmpty else { return 0.5 }
        let quantized = finite.reduce(UInt64(0)) { partial, value in
            partial + UInt64(value * 65535 + 0.5)
        }
        return min(max(Float(quantized) / Float(finite.count) / 65535, 0.001), 1)
    }

    /// Returns the sparse positions used by the Metal estimator for a source
    /// grid. This is shared by the offline parity harness and tests.
    public static func productionSamplePositions(width: Int, height: Int) -> [(x: Int, y: Int)] {
        guard width > 0, height > 0 else { return [] }
        return (0..<productionProxyHeight).flatMap { gy in
            (0..<productionProxyWidth).map { gx in
                (
                    min((gx * width + width / 2) / productionProxyWidth, width - 1),
                    min((gy * height + height / 2) / productionProxyHeight, height - 1)
                )
            }
        }
    }

    /// Relative coordinates for the shadow band. P05 is deliberately kept
    /// above the black floor and P10/P25 define a scene-dependent shoulder.
    /// The lower bound is clamped to avoid a degenerate interval in flat shots.
    public var shadowFloor: Float {
        min(max(p05, 0.001), 0.20)
    }

    public var shadowTop: Float {
        let candidate = max(p10 + 0.5 * (p25 - p10), shadowFloor + 0.025)
        return min(max(candidate, shadowFloor + 0.025), 0.60)
    }

    public var averageLuminance: Float {
        min(max(p50, 0.001), 1)
    }

    /// Causal percentile smoothing shared by the V4 scene state and the
    /// development-only V6.2 budget. It has no look-ahead and mirrors the
    /// scene-anchor transition's stability factor.
    public static func causalBlend(
        previous: HDRSceneStatistics,
        target: HDRSceneStatistics,
        stability: Float,
        sceneCut: Bool,
        deltaSeconds: Double? = nil
    ) -> HDRSceneStatistics {
        let alpha = sceneCut
            ? 1
            : deltaSeconds.map {
                HDRTemporalControlState.timeBasedAlpha(
                    stability: stability,
                    deltaSeconds: $0
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

    public init() {
        adaptation = 1
        shadowFloor = HDRSceneStatistics.neutral.shadowFloor
        shadowTop = HDRSceneStatistics.neutral.shadowTop
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
    public static let referenceFrameDurationSeconds = 1.0 / 60.0
    public static let maximumContinuousDeltaSeconds = 0.5

    public static func timeConstantSeconds(
        stability: Float,
        referenceFrameDurationSeconds: Double = Self.referenceFrameDurationSeconds
    ) -> Double {
        let oneMinusStability = min(max(1 - stability, 0), 1)
        guard oneMinusStability > 0 else { return 1_000_000 }
        return max(referenceFrameDurationSeconds / -log(Double(max(oneMinusStability, 1e-6))), 1e-6)
    }

    public static func timeBasedAlpha(stability: Float, deltaSeconds: Double) -> Float {
        guard deltaSeconds.isFinite, deltaSeconds > 0 else { return 0 }
        let tau = timeConstantSeconds(stability: stability)
        return Float(1 - exp(-deltaSeconds / tau))
    }

    public mutating func reset() {
        self = HDRTemporalControlState()
    }

    public mutating func updateAverage(averageLuminance: Float, stability: Float, sceneCut: Bool) {
        guard averageLuminance.isFinite else { return }
        let target = Self.clampAverage(averageLuminance)
        applyAverage(
            target: target,
            stability: stability,
            sceneCut: sceneCut,
            deltaSeconds: Self.referenceFrameDurationSeconds
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
        let target = Self.clampAverage(averageLuminance)
        let sceneCut = Self.isSceneCut(previous: previousAutomaticAverage, current: target)
        previousAutomaticAverage = target
        let timing = Self.timing(
            timestampSeconds: timestampSeconds,
            previousTimestamp: &previousAutomaticTimestamp
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
            deltaSeconds: Self.referenceFrameDurationSeconds
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
        let target = Self.clampAverage(averageLuminance)
        let sceneCut = Self.isSceneCut(previous: previousShadowAverage, current: target)
        previousShadowAverage = target
        let timing = Self.timing(
            timestampSeconds: timestampSeconds,
            previousTimestamp: &previousShadowTimestamp
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

    public static func isSceneCut(previous: Float?, current: Float) -> Bool {
        guard let previous else { return true }
        return abs(log2(max(current, 0.001) / max(previous, 0.001))) > 1.25
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
            let alpha = Self.timeBasedAlpha(stability: stability, deltaSeconds: deltaSeconds)
            smoothedEstimate += alpha * (target - smoothedEstimate)
        }
        adaptation = Self.adaptation(for: smoothedEstimate)
    }

    private mutating func applyStatistics(
        _ statistics: HDRSceneStatistics,
        stability: Float,
        sceneCut: Bool,
        deltaSeconds: Double
    ) {
        let targetFloor = statistics.shadowFloor
        let targetTop = statistics.shadowTop
        let alpha = Self.timeBasedAlpha(stability: stability, deltaSeconds: deltaSeconds)
        if sceneCut {
            shadowFloor = targetFloor
            shadowTop = targetTop
        } else {
            shadowFloor += alpha * (targetFloor - shadowFloor)
            shadowTop += alpha * (targetTop - shadowTop)
        }
        shadowTop = max(shadowTop, shadowFloor + 0.025)
        shadowStatisticsValid = true
    }

    public static func adaptation(for smoothedAverage: Float) -> Float {
        min(max(0.94 + 0.12 * (0.5 - smoothedAverage), 0.90), 1.06)
    }

    private static func clampAverage(_ value: Float) -> Float {
        min(max(value, 0.001), 1)
    }

    private static func timing(
        timestampSeconds: Double?,
        previousTimestamp: inout Double?
    ) -> (deltaSeconds: Double, discontinuity: Bool) {
        guard let timestampSeconds, timestampSeconds.isFinite else {
            return (Self.referenceFrameDurationSeconds, false)
        }
        guard let previous = previousTimestamp else {
            previousTimestamp = timestampSeconds
            return (Self.referenceFrameDurationSeconds, false)
        }
        let delta = timestampSeconds - previous
        previousTimestamp = timestampSeconds
        guard delta > 0, delta.isFinite else {
            // A repeated or reversed media timestamp is a discontinuity. The
            // caller's seek/reset path also clears this state explicitly.
            return (0, true)
        }
        if delta > Self.maximumContinuousDeltaSeconds {
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
        inputFallbackPolicy: HDRInputFallbackPolicy = .bt709VideoRange,
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
        self.inputFallbackPolicy = inputFallbackPolicy
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
