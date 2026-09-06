import Foundation

/// Development candidates for the V6 structural experiment. These values are
/// deliberately separate from the production preset table: selecting one
/// never creates or promotes a `calibratedV6` preset.
public enum HDRV6ToneCurveCandidate: String, CaseIterable, Codable, Sendable {
    case noLowMid = "v6-candidate-no-lowmid"
    case bandLimited035 = "v6-candidate-bandlimited-035"
    case bandLimited045 = "v6-candidate-bandlimited-045"
    case bandLimited055 = "v6-candidate-bandlimited-055"
    case bandLimited065 = "v6-candidate-bandlimited-065"
    case bandLimited075 = "v6-candidate-bandlimited-075"

    public var fadePosition: Float {
        switch self {
        case .noLowMid: return 0.55
        case .bandLimited035: return 0.35
        case .bandLimited045: return 0.45
        case .bandLimited055: return 0.55
        case .bandLimited065: return 0.65
        case .bandLimited075: return 0.75
        }
    }

    public var lowMidStrength: Float {
        self == .noLowMid ? 0 : HDRV6ToneCurveMath.defaultLowMidStrength
    }

    public var shortName: String {
        switch self {
        case .noLowMid: return "NO_LOWMID"
        case .bandLimited035: return "BANDLIMITED_035"
        case .bandLimited045: return "BANDLIMITED_045"
        case .bandLimited055: return "BANDLIMITED_055"
        case .bandLimited065: return "BANDLIMITED_065"
        case .bandLimited075: return "BANDLIMITED_075"
        }
    }

    /// Returns a development configuration carrying the exact calibrated V4
    /// parameters and only the new candidate revision/structure controls.
    public func configuration(base: HDRConfiguration = .calibratedV4) -> HDRConfiguration {
        var value = base
        value.toneCurveRevision = .sceneRelativeV6Candidate
        value.developmentLowMidFadePosition = fadePosition
        value.developmentLowMidStrength = lowMidStrength
        return value
    }
}

/// Scalar decomposition shared by the V6 reference implementation and the
/// dense curve harness. Contributions are in the same normalized luminance
/// domain as the Metal tone curve.
public struct HDRToneCurveScalarBreakdown: Codable, Equatable, Sendable {
    public let inputLuminance: Float
    public let expandedLuminance: Float
    public let lowMidContribution: Float
    public let shoulderContribution: Float
    public let shadowProtectionFactor: Float
    public let effectiveStrength: Float
    public let lowMidRise: Float
    public let lowMidFall: Float
    public let lowMidBand: Float
    public let lowMidFadeStart: Float
    public let shadowFloor: Float
    public let shadowTop: Float
    public let shoulderStart: Float
    public let shoulder: Float

    public init(
        inputLuminance: Float,
        expandedLuminance: Float,
        lowMidContribution: Float,
        shoulderContribution: Float,
        shadowProtectionFactor: Float,
        effectiveStrength: Float,
        lowMidRise: Float,
        lowMidFall: Float,
        lowMidBand: Float,
        lowMidFadeStart: Float,
        shadowFloor: Float,
        shadowTop: Float,
        shoulderStart: Float,
        shoulder: Float
    ) {
        self.inputLuminance = inputLuminance
        self.expandedLuminance = expandedLuminance
        self.lowMidContribution = lowMidContribution
        self.shoulderContribution = shoulderContribution
        self.shadowProtectionFactor = shadowProtectionFactor
        self.effectiveStrength = effectiveStrength
        self.lowMidRise = lowMidRise
        self.lowMidFall = lowMidFall
        self.lowMidBand = lowMidBand
        self.lowMidFadeStart = lowMidFadeStart
        self.shadowFloor = shadowFloor
        self.shadowTop = shadowTop
        self.shoulderStart = shoulderStart
        self.shoulder = shoulder
    }
}

/// The V6 structural curve math. It is intentionally independent of the
/// realtime processor; the processor and Metal shader mirror this arithmetic
/// for the development-only revision.
public enum HDRV6ToneCurveMath {
    public static let defaultLowMidStrength: Float = 0.08
    public static let shoulderMargin: Float = 0.0001

    public static func shoulderStart(configuration: HDRConfiguration = .calibratedV4) -> Float {
        0.68 - 0.20 * min(max(configuration.contrastStrength, 0), 1)
    }

    public static func normalizedSceneAnchors(
        sceneShadowFloor: Float,
        sceneShadowTop: Float,
        sceneStatisticsValid: Bool
    ) -> (floor: Float, top: Float) {
        let floor = sceneStatisticsValid ? min(max(sceneShadowFloor, 0.001), 0.20) : 0.01
        var top = sceneStatisticsValid ? max(sceneShadowTop, floor + 0.025) : 0.1125
        top = min(top, 0.60)
        return (floor, top)
    }

    public static func breakdown(
        luminance: Float,
        configuration: HDRConfiguration,
        temporalAdaptation: Float = 1,
        sceneStatistics: HDRSceneStatistics? = nil
    ) -> HDRToneCurveScalarBreakdown {
        let peakRatio = configuration.peakNits / configuration.paperWhiteNits
        let y = min(max(luminance, 0), 1)
        let shoulderStart = Self.shoulderStart(configuration: configuration)
        let shoulderT = smoothStep(shoulderStart, 1, y)
        let shoulder = shoulderT * shoulderT * (3 - 2 * shoulderT)
        let strength = min(max(configuration.highlightStrength * temporalAdaptation, 0), 1)
        let statistics = sceneStatistics ?? .neutral
        let anchors = normalizedSceneAnchors(
            sceneShadowFloor: statistics.shadowFloor,
            sceneShadowTop: statistics.shadowTop,
            sceneStatisticsValid: sceneStatistics != nil
        )

        // The V4 shadow protection transition remains the shadow controller.
        // V6 clips the low-mid support endpoint below the shoulder only when a
        // pathological scene anchor would otherwise cross that boundary.
        let shadowTransition = smoothStep(anchors.floor, anchors.top, y)
        let supportTop = min(anchors.top, shoulderStart - shoulderMargin)
        let lowMidRise = smoothStep(anchors.floor, supportTop, y)
        let fadePosition = min(max(configuration.developmentLowMidFadePosition, 0), 1)
        let lowMidFadeStart = anchors.floor >= supportTop
            ? supportTop
            : supportTop + (shoulderStart - supportTop) * fadePosition
        let lowMidFall = 1 - smoothStep(lowMidFadeStart, shoulderStart, y)
        let lowMidBand = lowMidRise * lowMidFall
        let shadowWeight = 1 - shadowTransition
        let protection = 1 - 0.90 * min(max(configuration.shadowProtection, 0), 1) * shadowWeight
        let lowMidExpansion = (peakRatio - 1) * strength *
            min(max(configuration.developmentLowMidStrength, 0), 1) * lowMidBand * y
        let shoulderExpansion = (peakRatio - 1) * strength * shoulder * y
        let lowMidContribution = max(lowMidExpansion * protection, 0)
        let shoulderContribution = max(shoulderExpansion * protection, 0)
        let expanded = min(max(y + lowMidContribution + shoulderContribution, y), peakRatio)
        return HDRToneCurveScalarBreakdown(
            inputLuminance: y,
            expandedLuminance: expanded,
            lowMidContribution: lowMidContribution,
            shoulderContribution: shoulderContribution,
            shadowProtectionFactor: protection,
            effectiveStrength: strength,
            lowMidRise: lowMidRise,
            lowMidFall: lowMidFall,
            lowMidBand: lowMidBand,
            lowMidFadeStart: lowMidFadeStart,
            shadowFloor: anchors.floor,
            shadowTop: anchors.top,
            shoulderStart: shoulderStart,
            shoulder: shoulder
        )
    }

    public static func toneExpand(
        _ luminance: Float,
        configuration: HDRConfiguration,
        temporalAdaptation: Float = 1,
        sceneStatistics: HDRSceneStatistics? = nil
    ) -> Float {
        breakdown(
            luminance: luminance,
            configuration: configuration,
            temporalAdaptation: temporalAdaptation,
            sceneStatistics: sceneStatistics
        ).expandedLuminance
    }

    private static func smoothStep(_ edge0: Float, _ edge1: Float, _ value: Float) -> Float {
        let denominator = max(edge1 - edge0, 1e-6)
        let t = min(max((value - edge0) / denominator, 0), 1)
        return t * t * (3 - 2 * t)
    }
}

public struct HDRV6ToneCurveSweepRow: Codable, Equatable, Sendable {
    public let inputLuminance: Float
    public let v2OutputLuminance: Float
    public let v4OutputLuminance: Float
    public let candidateOutputLuminance: Float
    public let v4LowMidContribution: Float
    public let candidateLowMidContribution: Float
    public let v4ShoulderContribution: Float
    public let candidateShoulderContribution: Float
    public let v4TotalGain: Float
    public let candidateTotalGain: Float
    public let v4ToV2Ratio: Float
    public let candidateToV2Ratio: Float
    public let candidateToV4Ratio: Float
    public let lowMidTransition: Float
    public let candidateLowMidRise: Float
    public let candidateLowMidFall: Float
    public let candidateLowMidBand: Float
    public let lowMidFadeStart: Float
    public let shoulderStart: Float
    public let shoulder: Float

    public init(
        inputLuminance: Float,
        v2OutputLuminance: Float,
        v4OutputLuminance: Float,
        candidateOutputLuminance: Float,
        v4LowMidContribution: Float,
        candidateLowMidContribution: Float,
        v4ShoulderContribution: Float,
        candidateShoulderContribution: Float,
        v4TotalGain: Float,
        candidateTotalGain: Float,
        v4ToV2Ratio: Float,
        candidateToV2Ratio: Float,
        candidateToV4Ratio: Float,
        lowMidTransition: Float,
        candidateLowMidRise: Float,
        candidateLowMidFall: Float,
        candidateLowMidBand: Float,
        lowMidFadeStart: Float,
        shoulderStart: Float,
        shoulder: Float
    ) {
        self.inputLuminance = inputLuminance
        self.v2OutputLuminance = v2OutputLuminance
        self.v4OutputLuminance = v4OutputLuminance
        self.candidateOutputLuminance = candidateOutputLuminance
        self.v4LowMidContribution = v4LowMidContribution
        self.candidateLowMidContribution = candidateLowMidContribution
        self.v4ShoulderContribution = v4ShoulderContribution
        self.candidateShoulderContribution = candidateShoulderContribution
        self.v4TotalGain = v4TotalGain
        self.candidateTotalGain = candidateTotalGain
        self.v4ToV2Ratio = v4ToV2Ratio
        self.candidateToV2Ratio = candidateToV2Ratio
        self.candidateToV4Ratio = candidateToV4Ratio
        self.lowMidTransition = lowMidTransition
        self.candidateLowMidRise = candidateLowMidRise
        self.candidateLowMidFall = candidateLowMidFall
        self.candidateLowMidBand = candidateLowMidBand
        self.lowMidFadeStart = lowMidFadeStart
        self.shoulderStart = shoulderStart
        self.shoulder = shoulder
    }
}

public struct HDRV6CurveInvariantReport: Codable, Equatable, Sendable {
    public let candidate: String
    public let sceneShadowFloor: Float
    public let sceneShadowTop: Float
    public let sampleCount: Int
    public let monotonic: Bool
    public let noDarkInversion: Bool
    public let exactBlack: Bool
    public let noNegativeExpansion: Bool
    public let finite: Bool
    public let continuous: Bool
    public let slopeSanity: Bool
    public let minSlope: Float
    public let maxSlope: Float
    public let maxSlopeJump: Float
    public let lowMidAtOrAboveShoulderMax: Float
    public let shoulderStart: Float
    public let lowMidFadeStart: Float
    public let allPassed: Bool

    public init(
        candidate: String,
        sceneShadowFloor: Float,
        sceneShadowTop: Float,
        sampleCount: Int,
        monotonic: Bool,
        noDarkInversion: Bool,
        exactBlack: Bool,
        noNegativeExpansion: Bool,
        finite: Bool,
        continuous: Bool,
        slopeSanity: Bool,
        minSlope: Float,
        maxSlope: Float,
        maxSlopeJump: Float,
        lowMidAtOrAboveShoulderMax: Float,
        shoulderStart: Float,
        lowMidFadeStart: Float
    ) {
        self.candidate = candidate
        self.sceneShadowFloor = sceneShadowFloor
        self.sceneShadowTop = sceneShadowTop
        self.sampleCount = sampleCount
        self.monotonic = monotonic
        self.noDarkInversion = noDarkInversion
        self.exactBlack = exactBlack
        self.noNegativeExpansion = noNegativeExpansion
        self.finite = finite
        self.continuous = continuous
        self.slopeSanity = slopeSanity
        self.minSlope = minSlope
        self.maxSlope = maxSlope
        self.maxSlopeJump = maxSlopeJump
        self.lowMidAtOrAboveShoulderMax = lowMidAtOrAboveShoulderMax
        self.shoulderStart = shoulderStart
        self.lowMidFadeStart = lowMidFadeStart
        allPassed = monotonic && noDarkInversion && exactBlack && noNegativeExpansion &&
            finite && continuous && slopeSanity && lowMidAtOrAboveShoulderMax <= 1e-6
    }
}

public struct HDRV6AnchorSweepRow: Codable, Equatable, Sendable {
    public let name: String
    public let floor: Float
    public let top: Float
    public let candidate: String
    public let lowMidFadeStart: Float
    public let lowMidBandAtGrid: [Float]

    public init(
        name: String,
        floor: Float,
        top: Float,
        candidate: String,
        lowMidFadeStart: Float,
        lowMidBandAtGrid: [Float]
    ) {
        self.name = name
        self.floor = floor
        self.top = top
        self.candidate = candidate
        self.lowMidFadeStart = lowMidFadeStart
        self.lowMidBandAtGrid = lowMidBandAtGrid
    }
}

public struct HDRV6ToneCurveCandidateAudit: Codable, Sendable {
    public let candidate: String
    public let shortName: String
    public let fadePosition: Float
    public let lowMidStrength: Float
    public let observedSceneFloor: Float
    public let observedSceneTop: Float
    public let requiredGrid: [HDRV6ToneCurveSweepRow]
    public let denseSweep: [HDRV6ToneCurveSweepRow]
    public let invariants: [HDRV6CurveInvariantReport]
    public let anchorSweep: [HDRV6AnchorSweepRow]

    public init(
        candidate: String,
        shortName: String,
        fadePosition: Float,
        lowMidStrength: Float,
        observedSceneFloor: Float,
        observedSceneTop: Float,
        requiredGrid: [HDRV6ToneCurveSweepRow],
        denseSweep: [HDRV6ToneCurveSweepRow],
        invariants: [HDRV6CurveInvariantReport],
        anchorSweep: [HDRV6AnchorSweepRow]
    ) {
        self.candidate = candidate
        self.shortName = shortName
        self.fadePosition = fadePosition
        self.lowMidStrength = lowMidStrength
        self.observedSceneFloor = observedSceneFloor
        self.observedSceneTop = observedSceneTop
        self.requiredGrid = requiredGrid
        self.denseSweep = denseSweep
        self.invariants = invariants
        self.anchorSweep = anchorSweep
    }
}

public struct HDRV6ToneCurveAuditArtifact: Codable, Sendable {
    public let schemaVersion: String
    public let denseSampleCount: Int
    public let temporalAdaptation: Float
    public let observedSceneFloor: Float
    public let observedSceneTop: Float
    public let candidates: [HDRV6ToneCurveCandidateAudit]

    public init(
        schemaVersion: String = "v6-tone-curve-audit-1",
        denseSampleCount: Int,
        temporalAdaptation: Float,
        observedSceneFloor: Float,
        observedSceneTop: Float,
        candidates: [HDRV6ToneCurveCandidateAudit]
    ) {
        self.schemaVersion = schemaVersion
        self.denseSampleCount = denseSampleCount
        self.temporalAdaptation = temporalAdaptation
        self.observedSceneFloor = observedSceneFloor
        self.observedSceneTop = observedSceneTop
        self.candidates = candidates
    }
}

/// Dense scalar and anchor sweeps used before any paired media evaluation.
public enum HDRV6ToneCurveDevelopment {
    public static let requiredLuminanceGrid: [Float] = [
        0.000, 0.005, 0.010, 0.020, 0.030, 0.040, 0.050, 0.060,
        0.080, 0.100, 0.150, 0.200, 0.250, 0.300, 0.350, 0.400,
        0.450, 0.500, 0.550, 0.600, 0.700, 0.800, 0.900, 1.000
    ]

    public static let anchorGrid: [Float] = [
        0.02, 0.03, 0.04, 0.05, 0.06, 0.08, 0.10, 0.20, 0.30, 0.40, 0.50
    ]

    public static let anchorFamilies: [(name: String, floor: Float, top: Float)] = [
        ("dark", 0.005, 0.030),
        ("test6-like", 0.03125, 0.05625),
        ("moderate", 0.030, 0.120),
        ("wide", 0.050, 0.250)
    ]

    public static func denseLuminanceGrid(sampleCount: Int = 1_000) -> [Float] {
        guard sampleCount > 0 else { return [0] }
        return (0...sampleCount).map { Float($0) / Float(sampleCount) }
    }

    public static func scalarSweep(
        candidate: HDRV6ToneCurveCandidate,
        temporalAdaptationV2: Float = 0.965,
        temporalAdaptationV4: Float = 0.965,
        temporalAdaptationV6: Float = 0.965,
        sceneShadowFloor: Float = 0.03125,
        sceneShadowTop: Float = 0.05625,
        sceneStatisticsValid: Bool = true,
        luminances: [Float] = denseLuminanceGrid()
    ) -> [HDRV6ToneCurveSweepRow] {
        let v2 = HDRConfiguration.calibratedV2
        let v4 = HDRConfiguration.calibratedV4
        let v6 = candidate.configuration()
        let statistics = makeStatistics(
            floor: sceneShadowFloor,
            top: sceneShadowTop,
            valid: sceneStatisticsValid
        )
        return luminances.map { y in
            let v2Output = HDRReference.toneExpand(
                y,
                configuration: v2,
                temporalAdaptation: temporalAdaptationV2
            )
            let v4Breakdown = v4Breakdown(
                luminance: y,
                configuration: v4,
                temporalAdaptation: temporalAdaptationV4,
                sceneShadowFloor: sceneShadowFloor,
                sceneShadowTop: sceneShadowTop,
                sceneStatisticsValid: sceneStatisticsValid
            )
            let v4Output = HDRReference.toneExpand(
                y,
                configuration: v4,
                temporalAdaptation: temporalAdaptationV4,
                sceneStatistics: sceneStatisticsValid ? statistics : nil
            )
            let v6 = HDRV6ToneCurveMath.breakdown(
                luminance: y,
                configuration: v6,
                temporalAdaptation: temporalAdaptationV6,
                sceneStatistics: sceneStatisticsValid ? statistics : nil
            )
            return HDRV6ToneCurveSweepRow(
                inputLuminance: y,
                v2OutputLuminance: v2Output,
                v4OutputLuminance: v4Output,
                candidateOutputLuminance: v6.expandedLuminance,
                v4LowMidContribution: v4Breakdown.lowMidContribution,
                candidateLowMidContribution: v6.lowMidContribution,
                v4ShoulderContribution: v4Breakdown.shoulderContribution,
                candidateShoulderContribution: v6.shoulderContribution,
                v4TotalGain: v4Output / max(y, 1e-6),
                candidateTotalGain: v6.expandedLuminance / max(y, 1e-6),
                v4ToV2Ratio: v4Output / max(v2Output, 1e-6),
                candidateToV2Ratio: v6.expandedLuminance / max(v2Output, 1e-6),
                candidateToV4Ratio: v6.expandedLuminance / max(v4Output, 1e-6),
                lowMidTransition: v4Breakdown.lowMidTransition,
                candidateLowMidRise: v6.lowMidRise,
                candidateLowMidFall: v6.lowMidFall,
                candidateLowMidBand: v6.lowMidBand,
                lowMidFadeStart: v6.lowMidFadeStart,
                shoulderStart: v6.shoulderStart,
                shoulder: v6.shoulder
            )
        }
    }

    public static func anchorSweep(
        candidate: HDRV6ToneCurveCandidate,
        temporalAdaptation: Float = 0.965,
        anchors: [(name: String, floor: Float, top: Float)] = anchorFamilies,
        luminances: [Float] = anchorGrid
    ) -> [HDRV6AnchorSweepRow] {
        let configuration = candidate.configuration()
        return anchors.map { anchor in
            let statistics = makeStatistics(floor: anchor.floor, top: anchor.top, valid: true)
            let rows = luminances.map {
                HDRV6ToneCurveMath.breakdown(
                    luminance: $0,
                    configuration: configuration,
                    temporalAdaptation: temporalAdaptation,
                    sceneStatistics: statistics
                ).lowMidBand
            }
            let representative = HDRV6ToneCurveMath.breakdown(
                luminance: 0.30,
                configuration: configuration,
                temporalAdaptation: temporalAdaptation,
                sceneStatistics: statistics
            )
            return HDRV6AnchorSweepRow(
                name: anchor.name,
                floor: representative.shadowFloor,
                top: representative.shadowTop,
                candidate: candidate.rawValue,
                lowMidFadeStart: representative.lowMidFadeStart,
                lowMidBandAtGrid: rows
            )
        }
    }

    public static func audit(
        temporalAdaptation: Float = 0.965,
        sceneShadowFloor: Float = 0.03125,
        sceneShadowTop: Float = 0.05625,
        denseSampleCount: Int = 1_000
    ) -> HDRV6ToneCurveAuditArtifact {
        let candidates = HDRV6ToneCurveCandidate.allCases.map { candidate in
            HDRV6ToneCurveCandidateAudit(
                candidate: candidate.rawValue,
                shortName: candidate.shortName,
                fadePosition: candidate.fadePosition,
                lowMidStrength: candidate.lowMidStrength,
                observedSceneFloor: sceneShadowFloor,
                observedSceneTop: sceneShadowTop,
                requiredGrid: scalarSweep(
                    candidate: candidate,
                    temporalAdaptationV2: temporalAdaptation,
                    temporalAdaptationV4: temporalAdaptation,
                    temporalAdaptationV6: temporalAdaptation,
                    sceneShadowFloor: sceneShadowFloor,
                    sceneShadowTop: sceneShadowTop,
                    luminances: requiredLuminanceGrid
                ),
                denseSweep: scalarSweep(
                    candidate: candidate,
                    temporalAdaptationV2: temporalAdaptation,
                    temporalAdaptationV4: temporalAdaptation,
                    temporalAdaptationV6: temporalAdaptation,
                    sceneShadowFloor: sceneShadowFloor,
                    sceneShadowTop: sceneShadowTop,
                    luminances: denseLuminanceGrid(sampleCount: denseSampleCount)
                ),
                invariants: anchorFamilies.map { anchor in
                    invariantReport(
                        candidate: candidate,
                        sceneShadowFloor: anchor.floor,
                        sceneShadowTop: anchor.top,
                        sampleCount: denseSampleCount
                    )
                },
                anchorSweep: anchorSweep(
                    candidate: candidate,
                    temporalAdaptation: temporalAdaptation
                )
            )
        }
        return HDRV6ToneCurveAuditArtifact(
            denseSampleCount: max(denseSampleCount, 1) + 1,
            temporalAdaptation: temporalAdaptation,
            observedSceneFloor: sceneShadowFloor,
            observedSceneTop: sceneShadowTop,
            candidates: candidates
        )
    }

    public static func invariantReport(
        candidate: HDRV6ToneCurveCandidate,
        sceneShadowFloor: Float = 0.03125,
        sceneShadowTop: Float = 0.05625,
        sceneStatisticsValid: Bool = true,
        sampleCount: Int = 1_000
    ) -> HDRV6CurveInvariantReport {
        let configuration = candidate.configuration()
        let statistics = makeStatistics(
            floor: sceneShadowFloor,
            top: sceneShadowTop,
            valid: sceneStatisticsValid
        )
        let count = max(sampleCount, 1)
        let values = (0...count).map { Float($0) / Float(count) }
        let breakdowns = values.map {
            HDRV6ToneCurveMath.breakdown(
                luminance: $0,
                configuration: configuration,
                temporalAdaptation: 0.965,
                sceneStatistics: sceneStatisticsValid ? statistics : nil
            )
        }
        let outputs = breakdowns.map(\.expandedLuminance)
        let finite = outputs.allSatisfy(\.isFinite)
        let monotonic = zip(outputs, outputs.dropFirst()).allSatisfy { $0.1 + 1e-7 >= $0.0 }
        let noDarkInversion = zip(values, outputs).allSatisfy { $0.1 + 1e-7 >= $0.0 }
        let exactBlack = outputs.first == 0
        let noNegativeExpansion = zip(values, outputs).allSatisfy { $0.1 + 1e-7 >= $0.0 }
        let slopes = zip(outputs, outputs.dropFirst()).map { ($0.1 - $0.0) * Float(count) }
        let slopeJumps = zip(slopes, slopes.dropFirst()).map { abs($0.1 - $0.0) }
        let minSlope = slopes.min() ?? 0
        let maxSlope = slopes.max() ?? 0
        let maxSlopeJump = slopeJumps.max() ?? 0
        let slopeSanity = finite && minSlope >= -0.001 && maxSlope <= 25 && maxSlopeJump <= 10

        let shoulderStart = HDRV6ToneCurveMath.shoulderStart(configuration: configuration)
        let representative = HDRV6ToneCurveMath.breakdown(
            luminance: 0.30,
            configuration: configuration,
            temporalAdaptation: 0.965,
            sceneStatistics: sceneStatisticsValid ? statistics : nil
        )
        let continuityPoints = [
            representative.shadowFloor,
            representative.shadowTop,
            representative.lowMidFadeStart,
            shoulderStart
        ]
        let continuity = continuityPoints.allSatisfy { point in
            let epsilon: Float = 0.00001
            let left = HDRV6ToneCurveMath.toneExpand(
                max(point - epsilon, 0),
                configuration: configuration,
                temporalAdaptation: 0.965,
                sceneStatistics: sceneStatisticsValid ? statistics : nil
            )
            let right = HDRV6ToneCurveMath.toneExpand(
                min(point + epsilon, 1),
                configuration: configuration,
                temporalAdaptation: 0.965,
                sceneStatistics: sceneStatisticsValid ? statistics : nil
            )
            return left.isFinite && right.isFinite && abs(right - left) < 0.001
        }
        let lowMidAtOrAboveShoulder = breakdowns
            .filter { $0.inputLuminance + 1e-7 >= $0.shoulderStart }
            .map(\.lowMidContribution)
            .max() ?? 0
        return HDRV6CurveInvariantReport(
            candidate: candidate.rawValue,
            sceneShadowFloor: representative.shadowFloor,
            sceneShadowTop: representative.shadowTop,
            sampleCount: count + 1,
            monotonic: monotonic,
            noDarkInversion: noDarkInversion,
            exactBlack: exactBlack,
            noNegativeExpansion: noNegativeExpansion,
            finite: finite,
            continuous: continuity,
            slopeSanity: slopeSanity,
            minSlope: minSlope,
            maxSlope: maxSlope,
            maxSlopeJump: maxSlopeJump,
            lowMidAtOrAboveShoulderMax: lowMidAtOrAboveShoulder,
            shoulderStart: shoulderStart,
            lowMidFadeStart: representative.lowMidFadeStart
        )
    }

    private static func makeStatistics(floor: Float, top: Float, valid: Bool) -> HDRSceneStatistics {
        let normalizedFloor = valid ? min(max(floor, 0.001), 0.20) : 0.01
        let normalizedTop = valid ? min(max(top, normalizedFloor + 0.025), 0.60) : 0.1125
        return HDRSceneStatistics(
            p01: normalizedFloor,
            p05: normalizedFloor,
            p10: normalizedFloor,
            p25: 2 * normalizedTop - normalizedFloor,
            p50: 0.42,
            p90: 0.88,
            p99: 1
        )
    }

    private static func v4Breakdown(
        luminance: Float,
        configuration: HDRConfiguration,
        temporalAdaptation: Float,
        sceneShadowFloor: Float,
        sceneShadowTop: Float,
        sceneStatisticsValid: Bool
    ) -> (
        lowMidContribution: Float,
        shoulderContribution: Float,
        lowMidTransition: Float
    ) {
        let y = min(max(luminance, 0), 1)
        let shoulderStart = HDRV6ToneCurveMath.shoulderStart(configuration: configuration)
        let t = smoothStep(shoulderStart, 1, y)
        let shoulder = t * t * (3 - 2 * t)
        let anchors = HDRV6ToneCurveMath.normalizedSceneAnchors(
            sceneShadowFloor: sceneShadowFloor,
            sceneShadowTop: sceneShadowTop,
            sceneStatisticsValid: sceneStatisticsValid
        )
        let transition = smoothStep(anchors.floor, anchors.top, y)
        let peakRatio = configuration.peakNits / configuration.paperWhiteNits
        let strength = min(max(configuration.highlightStrength * temporalAdaptation, 0), 1)
        let protection = 1 - 0.90 * min(max(configuration.shadowProtection, 0), 1) * (1 - transition)
        let lowMid = max((peakRatio - 1) * strength * 0.08 * transition * y * protection, 0)
        let shoulderTerm = max((peakRatio - 1) * strength * shoulder * y * protection, 0)
        return (lowMid, shoulderTerm, transition)
    }

    private static func smoothStep(_ edge0: Float, _ edge1: Float, _ value: Float) -> Float {
        let denominator = max(edge1 - edge0, 1e-6)
        let t = min(max((value - edge0) / denominator, 0), 1)
        return t * t * (3 - 2 * t)
    }
}
