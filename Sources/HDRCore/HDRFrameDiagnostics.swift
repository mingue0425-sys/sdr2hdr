import Foundation

/// A luminance summary captured by the DEBUG observation path. Values are
/// linear luminance relative to SDR reference white, so values above 1.0 are
/// meaningful in the tone-expanded and core EDR stages.
public struct HDRLuminanceStatistics: Codable, Equatable, Sendable {
    public let p01: Float
    public let p05: Float
    public let p50: Float
    public let p90: Float
    public let p95: Float
    public let p99: Float
    public let average: Float
    public let max: Float

    public init(
        p01: Float,
        p05: Float,
        p50: Float,
        p90: Float,
        p95: Float,
        p99: Float,
        average: Float,
        max: Float
    ) {
        self.p01 = p01
        self.p05 = p05
        self.p50 = p50
        self.p90 = p90
        self.p95 = p95
        self.p99 = p99
        self.average = average
        self.max = max
    }

    public static let zero = HDRLuminanceStatistics(
        p01: 0, p05: 0, p50: 0, p90: 0, p95: 0, p99: 0, average: 0, max: 0
    )
}

public struct HDRToneCurveDiagnostic: Codable, Equatable, Sendable {
    public let shoulderStart: Float
    public let highlightStrengthEffective: Float
    public let lowMidExpansionContribution: Float
    public let shoulderExpansionContribution: Float
    public let shadowProtectionFactor: Float
    public let temporalStrength: Float

    public init(
        shoulderStart: Float,
        highlightStrengthEffective: Float,
        lowMidExpansionContribution: Float,
        shoulderExpansionContribution: Float,
        shadowProtectionFactor: Float,
        temporalStrength: Float
    ) {
        self.shoulderStart = shoulderStart
        self.highlightStrengthEffective = highlightStrengthEffective
        self.lowMidExpansionContribution = lowMidExpansionContribution
        self.shoulderExpansionContribution = shoulderExpansionContribution
        self.shadowProtectionFactor = shadowProtectionFactor
        self.temporalStrength = temporalStrength
    }
}

public struct HDRNearBlackBandDiagnostic: Codable, Equatable, Sendable {
    public let threshold: Float
    public let sampleCount: UInt64
    /// Mean core-EDR luminance gain (core Y / input Y) in this band.
    public let meanGain: Float
    /// Mean tone-expanded luminance gain (tone-expanded Y / input Y) in this band.
    public let meanToneGain: Float
    /// Ratio of the output luminance range to the input luminance range for
    /// the band. A value below 1 indicates contrast compression.
    public let contrastRatioPreservation: Float
    public let liftedPixelRatio: Float
    public let crushedPixelRatio: Float

    public init(
        threshold: Float,
        sampleCount: UInt64,
        meanGain: Float,
        meanToneGain: Float,
        contrastRatioPreservation: Float,
        liftedPixelRatio: Float,
        crushedPixelRatio: Float
    ) {
        self.threshold = threshold
        self.sampleCount = sampleCount
        self.meanGain = meanGain
        self.meanToneGain = meanToneGain
        self.contrastRatioPreservation = contrastRatioPreservation
        self.liftedPixelRatio = liftedPixelRatio
        self.crushedPixelRatio = crushedPixelRatio
    }
}

public struct HDRSceneCutDiagnostic: Codable, Equatable, Sendable {
    public let averageLuminance: Float
    public let previousAverageLuminance: Float?
    public let stopDelta: Float?
    /// Half-L1 distance between normalized 64-bin input histograms, in 0...1.
    public let histogramDistance: Float?
    public let sceneCutDecision: Bool

    public init(
        averageLuminance: Float,
        previousAverageLuminance: Float?,
        stopDelta: Float?,
        histogramDistance: Float?,
        sceneCutDecision: Bool
    ) {
        self.averageLuminance = averageLuminance
        self.previousAverageLuminance = previousAverageLuminance
        self.stopDelta = stopDelta
        self.histogramDistance = histogramDistance
        self.sceneCutDecision = sceneCutDecision
    }
}

public struct HDRDiagnosticROI: Codable, Equatable, Sendable {
    public let x: Float
    public let y: Float
    public let width: Float
    public let height: Float

    public init(x: Float, y: Float, width: Float, height: Float) {
        let minX = min(max(x.isFinite ? x : 0, 0), 1)
        let minY = min(max(y.isFinite ? y : 0, 0), 1)
        let maxX = min(max((x + width).isFinite ? x + width : minX, minX), 1)
        let maxY = min(max((y + height).isFinite ? y + height : minY, minY), 1)
        self.x = minX
        self.y = minY
        self.width = maxX - minX
        self.height = maxY - minY
    }

    public var isEmpty: Bool { width <= 0 || height <= 0 }
}

public struct HDRPresentationDiagnostic: Codable, Equatable, Sendable {
    public let masteringHeadroom: Float
    public let physicalDisplayHeadroom: Float?
    public let mappedEDRAverage: Float?
    public let mappedEDRMax: Float?

    public init(
        masteringHeadroom: Float,
        physicalDisplayHeadroom: Float?,
        mappedEDRAverage: Float?,
        mappedEDRMax: Float?
    ) {
        self.masteringHeadroom = masteringHeadroom
        self.physicalDisplayHeadroom = physicalDisplayHeadroom
        self.mappedEDRAverage = mappedEDRAverage
        self.mappedEDRMax = mappedEDRMax
    }

    public static let unavailable = HDRPresentationDiagnostic(
        masteringHeadroom: 1,
        physicalDisplayHeadroom: nil,
        mappedEDRAverage: nil,
        mappedEDRMax: nil
    )
}

public struct HDRROIProbeDiagnostic: Codable, Equatable, Sendable {
    public let roi: HDRDiagnosticROI
    public let input: HDRLuminanceStatistics
    public let toneExpanded: HDRLuminanceStatistics
    public let coreEDR: HDRLuminanceStatistics
    public let lowMidExpansionContribution: Float
    public let shoulderExpansionContribution: Float
    public let shadowProtectionFactor: Float
    public let presentation: HDRPresentationDiagnostic
    public let meanRed: Float?
    public let meanGreen: Float?
    public let meanBlue: Float?
    public let meanChroma: Float?
    public let saturationDelta: Float?

    public init(
        roi: HDRDiagnosticROI,
        input: HDRLuminanceStatistics,
        toneExpanded: HDRLuminanceStatistics,
        coreEDR: HDRLuminanceStatistics,
        lowMidExpansionContribution: Float,
        shoulderExpansionContribution: Float,
        shadowProtectionFactor: Float,
        presentation: HDRPresentationDiagnostic,
        meanRed: Float?,
        meanGreen: Float?,
        meanBlue: Float?,
        meanChroma: Float?,
        saturationDelta: Float?
    ) {
        self.roi = roi
        self.input = input
        self.toneExpanded = toneExpanded
        self.coreEDR = coreEDR
        self.lowMidExpansionContribution = lowMidExpansionContribution
        self.shoulderExpansionContribution = shoulderExpansionContribution
        self.shadowProtectionFactor = shadowProtectionFactor
        self.presentation = presentation
        self.meanRed = meanRed
        self.meanGreen = meanGreen
        self.meanBlue = meanBlue
        self.meanChroma = meanChroma
        self.saturationDelta = saturationDelta
    }
}

/// Complete observation-only data for one processed frame. The fields map to
/// the causal stages directly: input -> tone expansion -> HDRCore output ->
/// presentation mapping. This type is never consulted by the production
/// shader path.
public struct HDRFrameDiagnosticSnapshot: Codable, Equatable, Sendable {
    public let frameIndex: UInt64
    public let timestampSeconds: Double?
    public let preset: String
    public let configurationGeneration: UInt64
    public let input: HDRLuminanceStatistics
    public let sceneShadowFloor: Float
    public let sceneShadowTop: Float
    public let sceneStatisticsValid: Bool
    public let temporalAdaptation: Float
    public let temporalSubmissionSequence: UInt64
    public let lastCompletedTemporalSequence: UInt64
    public let toneCurve: HDRToneCurveDiagnostic
    public let toneExpanded: HDRLuminanceStatistics
    public let coreEDR: HDRLuminanceStatistics
    public let presentation: HDRPresentationDiagnostic
    public let roi: HDRROIProbeDiagnostic?
    public let nearBlack: [HDRNearBlackBandDiagnostic]
    public let sceneCut: HDRSceneCutDiagnostic?

    public init(
        frameIndex: UInt64,
        timestampSeconds: Double?,
        preset: String,
        configurationGeneration: UInt64,
        input: HDRLuminanceStatistics,
        sceneShadowFloor: Float,
        sceneShadowTop: Float,
        sceneStatisticsValid: Bool,
        temporalAdaptation: Float,
        temporalSubmissionSequence: UInt64,
        lastCompletedTemporalSequence: UInt64,
        toneCurve: HDRToneCurveDiagnostic,
        toneExpanded: HDRLuminanceStatistics,
        coreEDR: HDRLuminanceStatistics,
        presentation: HDRPresentationDiagnostic = .unavailable,
        roi: HDRROIProbeDiagnostic? = nil,
        nearBlack: [HDRNearBlackBandDiagnostic] = [],
        sceneCut: HDRSceneCutDiagnostic? = nil
    ) {
        self.frameIndex = frameIndex
        self.timestampSeconds = timestampSeconds
        self.preset = preset
        self.configurationGeneration = configurationGeneration
        self.input = input
        self.sceneShadowFloor = sceneShadowFloor
        self.sceneShadowTop = sceneShadowTop
        self.sceneStatisticsValid = sceneStatisticsValid
        self.temporalAdaptation = temporalAdaptation
        self.temporalSubmissionSequence = temporalSubmissionSequence
        self.lastCompletedTemporalSequence = lastCompletedTemporalSequence
        self.toneCurve = toneCurve
        self.toneExpanded = toneExpanded
        self.coreEDR = coreEDR
        self.presentation = presentation
        self.roi = roi
        self.nearBlack = nearBlack
        self.sceneCut = sceneCut
    }

    public func withPresentation(_ value: HDRPresentationDiagnostic) -> HDRFrameDiagnosticSnapshot {
        withPresentation(value, roiPresentation: nil)
    }

    public func withPresentation(
        _ value: HDRPresentationDiagnostic,
        roiPresentation: HDRPresentationDiagnostic?
    ) -> HDRFrameDiagnosticSnapshot {
        let updatedROI = roi.map { probe in
            HDRROIProbeDiagnostic(
                roi: probe.roi,
                input: probe.input,
                toneExpanded: probe.toneExpanded,
                coreEDR: probe.coreEDR,
                lowMidExpansionContribution: probe.lowMidExpansionContribution,
                shoulderExpansionContribution: probe.shoulderExpansionContribution,
                shadowProtectionFactor: probe.shadowProtectionFactor,
                presentation: roiPresentation ?? probe.presentation,
                meanRed: probe.meanRed,
                meanGreen: probe.meanGreen,
                meanBlue: probe.meanBlue,
                meanChroma: probe.meanChroma,
                saturationDelta: probe.saturationDelta
            )
        }
        return HDRFrameDiagnosticSnapshot(
            frameIndex: frameIndex,
            timestampSeconds: timestampSeconds,
            preset: preset,
            configurationGeneration: configurationGeneration,
            input: input,
            sceneShadowFloor: sceneShadowFloor,
            sceneShadowTop: sceneShadowTop,
            sceneStatisticsValid: sceneStatisticsValid,
            temporalAdaptation: temporalAdaptation,
            temporalSubmissionSequence: temporalSubmissionSequence,
            lastCompletedTemporalSequence: lastCompletedTemporalSequence,
            toneCurve: toneCurve,
            toneExpanded: toneExpanded,
            coreEDR: coreEDR,
            presentation: value,
            roi: updatedROI,
            nearBlack: nearBlack,
            sceneCut: sceneCut
        )
    }

    public func formattedText() -> String {
        func stats(_ value: HDRLuminanceStatistics) -> String {
            "P01=\(value.p01), P05=\(value.p05), P50=\(value.p50), P90=\(value.p90), P95=\(value.p95), P99=\(value.p99), avg=\(value.average), max=\(value.max)"
        }
        func optional<T: CustomStringConvertible>(_ value: T?) -> String {
            value.map { String(describing: $0) } ?? "NOT_MEASURED"
        }
        var lines = [
            "preset: \(preset)",
            "frame: \(frameIndex), timestamp: \(timestampSeconds.map { String(format: "%.6f", $0) } ?? "NOT_MEASURED"), configurationGeneration: \(configurationGeneration)",
            "INPUT \(stats(input))",
            "SCENE shadowFloor=\(sceneShadowFloor), shadowTop=\(sceneShadowTop), valid=\(sceneStatisticsValid)",
            "TEMPORAL adaptation=\(temporalAdaptation), submission=\(temporalSubmissionSequence), lastCompleted=\(lastCompletedTemporalSequence)",
            "TONE shoulderStart=\(toneCurve.shoulderStart), effectiveStrength=\(toneCurve.highlightStrengthEffective), lowMidContribution=\(toneCurve.lowMidExpansionContribution), shoulderContribution=\(toneCurve.shoulderExpansionContribution), shadowProtectionFactor=\(toneCurve.shadowProtectionFactor), temporalStrength=\(toneCurve.temporalStrength)",
            "TONE_EXPANDED \(stats(toneExpanded))",
            "CORE_EDR \(stats(coreEDR))",
            "PRESENTATION masteringHeadroom=\(presentation.masteringHeadroom), physicalDisplayHeadroom=\(optional(presentation.physicalDisplayHeadroom)), mapped avg=\(optional(presentation.mappedEDRAverage)), mapped max=\(optional(presentation.mappedEDRMax))"
        ]
        if let roi {
            lines.append("ROI x=\(roi.roi.x), y=\(roi.roi.y), w=\(roi.roi.width), h=\(roi.roi.height)")
            lines.append("ROI INPUT \(stats(roi.input))")
            lines.append("ROI TONE_EXPANDED \(stats(roi.toneExpanded))")
            lines.append("ROI CORE_EDR \(stats(roi.coreEDR))")
            lines.append("ROI TONE lowMid=\(roi.lowMidExpansionContribution), shoulder=\(roi.shoulderExpansionContribution), shadowProtection=\(roi.shadowProtectionFactor)")
            lines.append("ROI RGB=\(optional(roi.meanRed)),\(optional(roi.meanGreen)),\(optional(roi.meanBlue)), chroma=\(optional(roi.meanChroma)), saturationDelta=\(optional(roi.saturationDelta))")
            lines.append("ROI PRESENTATION avg=\(optional(roi.presentation.mappedEDRAverage)), max=\(optional(roi.presentation.mappedEDRMax))")
        }
        for band in nearBlack {
            lines.append("NEAR_BLACK <\(band.threshold) count=\(band.sampleCount), toneGain=\(band.meanToneGain), coreGain=\(band.meanGain), contrast=\(band.contrastRatioPreservation), lifted=\(band.liftedPixelRatio), crushed=\(band.crushedPixelRatio)")
        }
        if let sceneCut {
            lines.append("SCENE_CUT average=\(sceneCut.averageLuminance), previous=\(optional(sceneCut.previousAverageLuminance)), stopDelta=\(optional(sceneCut.stopDelta)), histogramDistance=\(optional(sceneCut.histogramDistance)), decision=\(sceneCut.sceneCutDecision)")
        }
        return lines.joined(separator: "\n")
    }
}
