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

/// Selects the analytical tone-expansion revision. Existing presets remain on
/// the frozen V2 curve; V3 candidates explicitly opt into repaired shadow
/// control so historical A/B comparisons stay meaningful.
public enum HDRToneCurveRevision: UInt32, Sendable {
    case legacyV2 = 0
    case shadowProtectedV3 = 1
    /// V4 uses scene-relative percentile coordinates supplied by the causal
    /// runtime estimator. Existing presets intentionally remain on legacyV2.
    case sceneRelativeV4 = 2
}

/// Low-cost source-luminance statistics used by the V4 scene-relative shadow
/// controller. Values are linear BT.709 luminance normalized to SDR white.
/// The runtime estimator supplies these one frame late; offline calibration
/// feeds the same state transition after each frame.
public struct HDRSceneStatistics: Equatable, Sendable, Codable {
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

    /// Converts the fixed 16-bin GPU histogram into percentile estimates. The
    /// estimator is deliberately coarse; its purpose is a stable control
    /// signal, not a diagnostic-quality histogram.
    public init(histogram: [UInt32]) {
        let bins = Array(histogram.prefix(16)) + Array(repeating: 0, count: max(0, 16 - histogram.count))
        let total = bins.reduce(0, +)
        func quantile(_ fraction: Double) -> Float {
            guard total > 0 else { return 0 }
            let target = UInt64(Double(total) * fraction)
            var cumulative: UInt64 = 0
            for (index, count) in bins.enumerated() {
                cumulative += UInt64(count)
                if cumulative >= target {
                    return (Float(index) + 0.5) / 16
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

    public var isFinite: Bool {
        [p01, p05, p10, p25, p50, p90, p99].allSatisfy(\.isFinite)
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

    /// 0...1. Used by the optional external luminance-estimate adaptation
    /// hook. The default pipeline has no automatic exposure adaptation.
    public var temporalStability: Float

    public var outputMode: HDROutputMode
    public var toneCurveRevision: HDRToneCurveRevision

    /// Content/mastering-domain linear headroom. In EDR mode, 1.0 is diffuse
    /// SDR reference white and this value is the largest content signal the
    /// core may emit. Physical display headroom is presentation state and must
    /// not be written into this configuration.
    public var masteringHeadroom: Float

    /// Source-compatible alias retained for clients built against V1/V2.
    /// Despite its legacy name this is content/mastering headroom, never the
    /// current NSScreen EDR value.
    @available(*, deprecated, renamed: "masteringHeadroom")
    public var displayHeadroom: Float {
        get { masteringHeadroom }
        set { masteringHeadroom = newValue }
    }

    public var inputFallbackPolicy: HDRInputFallbackPolicy

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
        inputFallbackPolicy: HDRInputFallbackPolicy = .bt709VideoRange
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
        self.inputFallbackPolicy = inputFallbackPolicy
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

    /// Offline-calibrated candidate promoted from the local data_video
    /// experiment. Its headroom is mastering intent, not display capability.
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

    /// Video-level calibrated preset promoted by the data_video V2 experiment.
    /// Selection used Tune and Validation only; the guarded Frozen video was
    /// decoded after these values were final. Runtime display mapping is a
    /// separate presentation operation and never mutates this signal curve.
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
    /// must not replace the promoted calibratedV2 preset.
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

    public func validated() throws -> HDRConfiguration {
        let finiteValues: [(String, Float)] = [
            ("paperWhiteNits", paperWhiteNits),
            ("peakNits", peakNits),
            ("highlightStrength", highlightStrength),
            ("contrastStrength", contrastStrength),
            ("saturationCompensation", saturationCompensation),
            ("shadowProtection", shadowProtection),
            ("temporalStability", temporalStability),
            ("masteringHeadroom", masteringHeadroom)
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
        return self
    }
}
