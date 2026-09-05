import Foundation
import HDRCore
import Metal

public struct V61SignedErrorSummary: Codable, Equatable, Sendable {
    public let sampleCount: Int
    public let meanSignedError: Double
    public let medianSignedError: Double
    public let p05: Double
    public let p50: Double
    public let p95: Double
    public let positiveErrorMean: Double
    public let negativeErrorMean: Double
    public let overPredictionRatio: Double
    public let underPredictionRatio: Double
    public let mae: Double
    public let rmse: Double
    public let p95AbsoluteError: Double
    public let meanSignedLogError: Double
    public let logMAE: Double

    public init(values: [Double], signedLogValues: [Double] = []) {
        let finite = values.filter { $0.isFinite }
        let sorted = finite.sorted()
        let positive = finite.filter { $0 > 0 }
        let negative = finite.filter { $0 < 0 }
        self.sampleCount = finite.count
        self.meanSignedError = V61ErrorAttributionMath.average(finite)
        self.medianSignedError = V61ErrorAttributionMath.percentile(sorted, 0.50)
        self.p05 = V61ErrorAttributionMath.percentile(sorted, 0.05)
        self.p50 = V61ErrorAttributionMath.percentile(sorted, 0.50)
        self.p95 = V61ErrorAttributionMath.percentile(sorted, 0.95)
        self.positiveErrorMean = V61ErrorAttributionMath.average(positive)
        self.negativeErrorMean = V61ErrorAttributionMath.average(negative)
        self.overPredictionRatio = finite.isEmpty ? 0 : Double(positive.count) / Double(finite.count)
        self.underPredictionRatio = finite.isEmpty ? 0 : Double(negative.count) / Double(finite.count)
        self.mae = V61ErrorAttributionMath.average(finite.map(abs))
        self.rmse = finite.isEmpty
            ? 0
            : sqrt(finite.map { $0 * $0 }.reduce(0, +) / Double(finite.count))
        let absolute = finite.map(abs).sorted()
        self.p95AbsoluteError = V61ErrorAttributionMath.percentile(absolute, 0.95)
        let logs = signedLogValues.filter { $0.isFinite }
        self.meanSignedLogError = V61ErrorAttributionMath.average(logs)
        self.logMAE = V61ErrorAttributionMath.average(logs.map(abs))
    }

    init(signedValues: [Double], signedLogValues: [Double]) {
        self.init(values: signedValues, signedLogValues: signedLogValues)
    }
}

public struct V61CandidateErrorSummary: Codable, Equatable, Sendable {
    public let sampleCount: Int
    public let signedError: V61SignedErrorSummary
    public let meanSignedLogError: Double
    public let meanSourceLuminance: Double
    public let meanReferenceLuminance: Double
    public let meanCandidateLuminance: Double
    public let meanLowMidContribution: Double
    public let meanShoulderContribution: Double
    public let meanTotalExpansion: Double
    public let meanTemporalAdaptation: Double
    public let meanShadowFloor: Double
    public let meanShadowTop: Double
    public let sceneStatisticsValidRatio: Double
    public let meanLowMidTransition: Double
    public let lowMidTransitionP50: Double
    public let lowMidTransitionP95: Double
    public let lowMidFullyActivatedRatio: Double
}

public struct V61LuminanceBinResult: Codable, Equatable, Sendable {
    public let label: String
    public let lowerBound: Double
    public let upperBound: Double
    public let sampleCount: Int
    public let v2: V61CandidateErrorSummary
    public let v4: V61CandidateErrorSummary
    public let noLowMid: V61CandidateErrorSummary
    public let bl045: V61CandidateErrorSummary
    public let v2MinusReference: V61SignedErrorSummary
    public let v4MinusReference: V61SignedErrorSummary
    public let v4MinusV2: V61SignedErrorSummary
}

public struct V61CorrelationResult: Codable, Equatable, Sendable {
    public let sampleCount: Int
    public let pearson: Double?
    public let spearman: Double?
    public let estimable: Bool
    public let unavailableReason: String?

    public init(
        sampleCount: Int,
        pearson: Double?,
        spearman: Double?,
        estimable: Bool = true,
        unavailableReason: String? = nil
    ) {
        self.sampleCount = sampleCount
        self.pearson = pearson
        self.spearman = spearman
        self.estimable = estimable
        self.unavailableReason = unavailableReason
    }
}

public struct V61ContributionCorrelationReport: Codable, Equatable, Sendable {
    public let split: DatasetSplit
    public let scope: String
    public let candidate: String
    public let lowMidVsSignedError: V61CorrelationResult
    public let shoulderVsSignedError: V61CorrelationResult
    public let totalExpansionVsSignedError: V61CorrelationResult
}

public struct V61SceneAnchorCorrelationReport: Codable, Equatable, Sendable {
    public let split: DatasetSplit
    public let scope: String
    public let candidate: String
    public let shadowTopVsSignedMidtoneError: V61CorrelationResult
    public let shadowTopVsLowMidContribution: V61CorrelationResult
    public let shadowFloorVsSignedMidtoneError: V61CorrelationResult
}

public struct V61TemporalCorrelationReport: Codable, Equatable, Sendable {
    public let split: DatasetSplit
    public let candidate: String
    public let sampleCount: Int
    public let uniqueTemporalAdaptationCount: Int
    public let meanTemporalAdaptation: Double
    public let minimumTemporalAdaptation: Double
    public let maximumTemporalAdaptation: Double
    public let temporalAdaptationVsSignedError: V61CorrelationResult
}

public struct V61SceneCandidateResult: Codable, Equatable, Sendable {
    public let spatialObjective: Double
    public let signedAllError: V61SignedErrorSummary
    public let signedMidtoneError: V61SignedErrorSummary
    public let highlightError: Double
    public let shadowError: Double
    public let meanLowMidContribution: Double
    public let meanShoulderContribution: Double
    public let meanTotalExpansion: Double
    public let meanTemporalAdaptation: Double
    public let meanShadowFloor: Double
    public let meanShadowTop: Double
    public let sceneStatisticsValidRatio: Double
    public let weightedContributions: [String: Double]
}

public struct V61SceneResult: Codable, Equatable, Sendable {
    public let pairID: String
    public let sceneID: String
    public let split: DatasetSplit
    public let transfer: String
    public let categories: [String]
    public let frameCount: Int
    public let sampleCount: Int
    public let averageSourceLuminance: Double
    public let sourceP01: Double
    public let sourceP99: Double
    public let sourceDynamicRangeStops: Double
    public let v2: V61SceneCandidateResult
    public let v4: V61SceneCandidateResult
    public let noLowMid: V61SceneCandidateResult
    public let bl045: V61SceneCandidateResult
}

public struct V61TransferCandidateResult: Codable, Equatable, Sendable {
    public let officialObjective: Double
    public let highlightError: Double
    public let shadowError: Double
    public let signedMidtoneError: V61SignedErrorSummary
}

public struct V61TransferResult: Codable, Equatable, Sendable {
    public let split: DatasetSplit
    public let transfer: String
    public let videoCount: Int
    public let sceneCount: Int
    public let sampleCount: Int
    public let v2: V61TransferCandidateResult
    public let v4: V61TransferCandidateResult
    public let noLowMid: V61TransferCandidateResult
    public let bl045: V61TransferCandidateResult
}

public struct V61OfficialVideoResult: Codable, Equatable, Sendable {
    public let pairID: String
    public let objective: Double
    public let highlightError: Double
    public let shadowError: Double
    public let weightedContributions: [String: Double]
}

public struct V61OfficialSplitResult: Codable, Equatable, Sendable {
    public let split: DatasetSplit
    public let videoCount: Int
    public let frameCount: Int
    public let sceneCount: Int
    public let objective: Double
    public let weightedContributions: [String: Double]
    public let videos: [V61OfficialVideoResult]
}

public struct V61OfficialCandidateResult: Codable, Equatable, Sendable {
    public let candidate: String
    public let tune: V61OfficialSplitResult?
    public let validation: V61OfficialSplitResult?
}

public struct V61ObjectiveDecomposition: Codable, Equatable, Sendable {
    public let split: DatasetSplit
    public let baselineObjective: Double
    public let noLowMidObjective: Double
    public let bl045Objective: Double
    public let baselineComponents: [String: Double]
    public let noLowMidComponents: [String: Double]
    public let bl045Components: [String: Double]
    public let noLowMidComponentDeltas: [String: Double]
    public let bl045ComponentDeltas: [String: Double]
    public let noLowMidReportedDelta: Double
    public let bl045ReportedDelta: Double
    public let noLowMidDeltaSum: Double
    public let bl045DeltaSum: Double
    public let noLowMidSumMatchesReported: Bool
    public let bl045SumMatchesReported: Bool
}

public struct V61StrengthResponsePoint: Codable, Equatable, Sendable {
    public let split: DatasetSplit
    public let scale: Double
    public let effectiveCoefficient: Double
    public let sampleCount: Int
    public let toneOnlyObjective: Double
    public let meanSignedError: V61SignedErrorSummary
    public let signedMidtoneError: V61SignedErrorSummary
    public let highlightError: Double
    public let shadowError: Double
}

public struct V61SceneStrengthResponse: Codable, Equatable, Sendable {
    public let pairID: String
    public let sceneID: String
    public let split: DatasetSplit
    public let points: [V61StrengthResponsePoint]
}

public struct V61StrengthResponseReport: Codable, Equatable, Sendable {
    public let scales: [Double]
    public let productionCoefficient: Double
    public let tune: [V61StrengthResponsePoint]
    public let validation: [V61StrengthResponsePoint]
    public let scenes: [V61SceneStrengthResponse]
}

public struct V61MetricAudit: Codable, Equatable, Sendable {
    public let errorDefinition: String
    public let errorUnits: String
    public let sourceLuminanceDomain: String
    public let diffuseSourceRange: String
    public let binMask: String
    public let samplePairing: String
    public let sceneWeighting: String
    public let v2IsGroundTruth: Bool
    public let signedCompanionPreservesDirection: Bool
    public let existingAbsoluteMetricRetained: Bool
}

public struct V61SkippedPair: Codable, Equatable, Sendable {
    public let pairID: String
    public let split: DatasetSplit
    public let reason: String
}

public struct V61ErrorAttributionReport: Codable, Sendable {
    public let schemaVersion: String
    public let productionCommit: String
    public let manifestPath: String
    public let allowedSplits: [DatasetSplit]
    public let allowedPairIDs: [String]
    public let preparedPairIDs: [String]
    public let skippedPairs: [V61SkippedPair]
    public let protectedMediaAccessed: Bool
    public let objectiveEvaluationsOutsideAllowedSplits: Int
    public let frozenObjectiveEvaluations: Int
    public let virginFrozenObjectiveEvaluations: Int
    public let sourceLuminanceBinEdges: [Double]
    public let luminanceBins: [V61LuminanceBinResult]
    public let sceneBreakdown: [V61SceneResult]
    public let transferBreakdown: [V61TransferResult]
    public let contributionCorrelations: [V61ContributionCorrelationReport]
    public let sceneAnchorCorrelations: [V61SceneAnchorCorrelationReport]
    public let temporalCorrelations: [V61TemporalCorrelationReport]
    public let objectiveDecompositions: [V61ObjectiveDecomposition]
    public let strengthResponse: V61StrengthResponseReport
    public let metricAudit: V61MetricAudit

    init(
        manifestPath: String,
        allowedPairIDs: [String],
        preparedPairIDs: [String],
        skippedPairs: [V61SkippedPair],
        luminanceBins: [V61LuminanceBinResult],
        sceneBreakdown: [V61SceneResult],
        transferBreakdown: [V61TransferResult],
        contributionCorrelations: [V61ContributionCorrelationReport],
        sceneAnchorCorrelations: [V61SceneAnchorCorrelationReport],
        temporalCorrelations: [V61TemporalCorrelationReport],
        objectiveDecompositions: [V61ObjectiveDecomposition],
        strengthResponse: V61StrengthResponseReport
    ) {
        schemaVersion = "v6.1-error-attribution-1"
        productionCommit = "d97c3d3c8fbf71447ff8b94a7fa7a77c5d25bebf"
        self.manifestPath = manifestPath
        allowedSplits = [.tune, .validation]
        self.allowedPairIDs = allowedPairIDs
        self.preparedPairIDs = preparedPairIDs
        self.skippedPairs = skippedPairs
        protectedMediaAccessed = false
        objectiveEvaluationsOutsideAllowedSplits = 0
        frozenObjectiveEvaluations = 0
        virginFrozenObjectiveEvaluations = 0
        sourceLuminanceBinEdges = V61ErrorAttributionMath.sourceLuminanceBinEdges
        self.luminanceBins = luminanceBins
        self.sceneBreakdown = sceneBreakdown
        self.transferBreakdown = transferBreakdown
        self.contributionCorrelations = contributionCorrelations
        self.sceneAnchorCorrelations = sceneAnchorCorrelations
        self.temporalCorrelations = temporalCorrelations
        self.objectiveDecompositions = objectiveDecompositions
        self.strengthResponse = strengthResponse
        metricAudit = V61MetricAudit(
            errorDefinition: "candidate HDR luminance minus paired HDR reference luminance",
            errorUnits: "raw HDR nits; signed log1p companion is retained in summaries",
            sourceLuminanceDomain: "linear BT.709 SDR luminance",
            diffuseSourceRange: "0.15 <= Y <= 0.45",
            binMask: "lower inclusive; upper exclusive except final [0.75, 1.00]",
            samplePairing: "same aligned 32x18 source/reference grid by index",
            sceneWeighting: "scene spatial metrics use the existing V2 equal scene mean; signed/bin aggregates are sample-weighted",
            v2IsGroundTruth: false,
            signedCompanionPreservesDirection: true,
            existingAbsoluteMetricRetained: true
        )
    }
}

public enum V61ErrorAttributionMath {
    public static let sourceLuminanceBinEdges: [Double] = [
        0.00, 0.01, 0.02, 0.05, 0.10, 0.15, 0.20,
        0.30, 0.40, 0.50, 0.60, 0.75, 1.00
    ]

    public static func binIndex(_ value: Double) -> Int? {
        guard value.isFinite, value >= sourceLuminanceBinEdges.first!,
              value <= sourceLuminanceBinEdges.last! else { return nil }
        for index in 0..<(sourceLuminanceBinEdges.count - 1) {
            let lower = sourceLuminanceBinEdges[index]
            let upper = sourceLuminanceBinEdges[index + 1]
            if value >= lower && (value < upper || (index == sourceLuminanceBinEdges.count - 2 && value <= upper)) {
                return index
            }
        }
        return nil
    }

    public static func isAllowedDevelopmentPair(
        split: DatasetSplit,
        virginFrozen: Bool
    ) -> Bool {
        (split == .tune || split == .validation) && !virginFrozen
    }

    public static func referenceDirectionCase(
        v2SignedError: Double,
        v4SignedError: Double,
        tolerance: Double = 1e-9
    ) -> String {
        if v2SignedError < -tolerance && abs(v4SignedError) <= tolerance {
            return "V2_UNDER_REFERENCE_V4_NEAR_REFERENCE"
        }
        if abs(v2SignedError) <= tolerance && v4SignedError > tolerance {
            return "V2_NEAR_REFERENCE_V4_OVER_REFERENCE"
        }
        if v2SignedError < -tolerance && v4SignedError > tolerance {
            return "V2_UNDER_REFERENCE_V4_OVER_REFERENCE"
        }
        return "SCENE_OR_SIGNAL_DEPENDENT"
    }

    public static func average(_ values: [Double]) -> Double {
        let finite = values.filter { $0.isFinite }
        return finite.isEmpty ? 0 : finite.reduce(0, +) / Double(finite.count)
    }

    public static func percentile(_ values: [Double], _ fraction: Double) -> Double {
        let sorted = values.filter { $0.isFinite }.sorted()
        guard !sorted.isEmpty else { return 0 }
        let position = min(max(Int(Double(sorted.count - 1) * fraction), 0), sorted.count - 1)
        return sorted[position]
    }

    public static func pearson(_ lhs: [Double], _ rhs: [Double]) -> V61CorrelationResult {
        let pairs = zip(lhs, rhs).filter { $0.0.isFinite && $0.1.isFinite }
        guard pairs.count > 1 else {
            return V61CorrelationResult(
                sampleCount: pairs.count,
                pearson: nil,
                spearman: nil,
                estimable: false,
                unavailableReason: "fewer than two finite pairs"
            )
        }
        let left = pairs.map(\.0)
        let right = pairs.map(\.1)
        let lm = average(left)
        let rm = average(right)
        var numerator = 0.0
        var leftVariance = 0.0
        var rightVariance = 0.0
        for index in left.indices {
            let l = left[index] - lm
            let r = right[index] - rm
            numerator += l * r
            leftVariance += l * l
            rightVariance += r * r
        }
        let denominator = sqrt(leftVariance * rightVariance)
        let estimable = denominator > 1e-12
        let pearson = estimable ? numerator / denominator : nil
        let spearman = estimable ? rankCorrelation(left, right) : nil
        return V61CorrelationResult(
            sampleCount: pairs.count,
            pearson: pearson,
            spearman: spearman,
            estimable: estimable,
            unavailableReason: estimable ? nil : "zero variance in at least one input"
        )
    }

    public static func weightedComponentSum(_ components: [String: Double]) -> Double {
        components.values.filter { $0.isFinite }.reduce(0, +)
    }

    private static func rankCorrelation(_ lhs: [Double], _ rhs: [Double]) -> Double? {
        guard lhs.count == rhs.count, lhs.count > 1 else { return nil }
        let left = ranks(lhs)
        let right = ranks(rhs)
        return linearPearson(left, right)
    }

    private static func linearPearson(_ lhs: [Double], _ rhs: [Double]) -> Double? {
        guard lhs.count == rhs.count, lhs.count > 1 else { return nil }
        let lm = average(lhs)
        let rm = average(rhs)
        var numerator = 0.0
        var leftVariance = 0.0
        var rightVariance = 0.0
        for index in lhs.indices {
            let l = lhs[index] - lm
            let r = rhs[index] - rm
            numerator += l * r
            leftVariance += l * l
            rightVariance += r * r
        }
        let denominator = sqrt(leftVariance * rightVariance)
        return denominator > 1e-12 ? numerator / denominator : nil
    }

    private static func ranks(_ values: [Double]) -> [Double] {
        let sorted = values.enumerated().sorted { $0.element < $1.element }
        var result = Array(repeating: 0.0, count: values.count)
        var start = 0
        while start < sorted.count {
            var end = start + 1
            while end < sorted.count && sorted[end].element == sorted[start].element {
                end += 1
            }
            let averageRank = (Double(start) + Double(end - 1)) / 2.0 + 1.0
            for index in start..<end {
                result[sorted[index].offset] = averageRank
            }
            start = end
        }
        return result
    }
}

private struct V61Definition {
    let key: String
    let label: String
    let configuration: HDRConfiguration
}

private struct V61SceneKey: Hashable {
    let pairID: String
    let sceneID: String
}

private struct V61TransferKey: Hashable {
    let split: DatasetSplit
    let transfer: String
}

private struct V61OutputSample {
    let luma: Double
    let lowMidContribution: Double
    let shoulderContribution: Double
    let totalExpansion: Double
    let temporalAdaptation: Double
    let shadowFloor: Double
    let shadowTop: Double
    let sceneStatisticsValid: Bool
    let lowMidTransition: Double
}

private struct V61PixelRecord {
    let pairID: String
    let sceneID: String
    let split: DatasetSplit
    let transfer: String
    let categories: [String]
    let frameIndex: Int
    let timestampSeconds: Double
    let sourceLuminance: Double
    let referenceLuminance: Double
    let outputs: [String: V61OutputSample]
}

private struct V61FrameBundle {
    let key: V61SceneKey
    let split: DatasetSplit
    let transfer: String
    let categories: [String]
    let frameIndex: Int
    let timestampSeconds: Double
    let sourceLuma: [Float]
    let reference: ReferenceFrame
    let outputs: [String: GeneratedFrame]
    let confidence: Double
}

private struct V61ScalarMetricValues {
    let toneOnlyObjective: Double
    let signedAll: V61SignedErrorSummary
    let signedMidtone: V61SignedErrorSummary
    let highlightError: Double
    let shadowError: Double
}

private struct V61PreparedContext {
    let allowedPairs: [V4PairRecord]
    let records: [PairRecord]
    let prepared: [PreparedPair]
    let skipped: [V61SkippedPair]
}

public enum V61ErrorAttributionRunner {
    public static func run(
        manifestURL: URL,
        outputURL: URL? = nil,
        device suppliedDevice: MTLDevice? = MTLCreateSystemDefaultDevice()
    ) async throws -> V61ErrorAttributionReport {
        guard let device = suppliedDevice else {
            throw CalibrationError.decodeFailed("Metal device unavailable")
        }

        let context = try await prepareContext(manifestURL: manifestURL, device: device)
        let definitions = definitions()
        let weights = V4CalibrationConfiguration().weights
        let official = try evaluateOfficial(
            preparedPairs: context.prepared,
            definitions: definitions,
            weights: weights,
            device: device
        )
        let (records, frames) = try collectSamples(
            preparedPairs: context.prepared,
            definitions: definitions,
            device: device,
            categoriesByPairID: Dictionary(uniqueKeysWithValues: context.allowedPairs.map { ($0.id, $0.contentCategory) })
        )

        let report = V61ErrorAttributionReport(
            manifestPath: manifestURL.standardizedFileURL.path,
            allowedPairIDs: context.records.map(\.id),
            preparedPairIDs: context.prepared.map { $0.record.id },
            skippedPairs: context.skipped,
            luminanceBins: makeBins(records),
            sceneBreakdown: makeSceneBreakdown(
                frames: frames,
                records: records,
                definitions: definitions,
                weights: weights
            ),
            transferBreakdown: makeTransferBreakdown(
                records: records,
                official: official
            ),
            contributionCorrelations: makeContributionCorrelations(records: records),
            sceneAnchorCorrelations: makeSceneAnchorCorrelations(records: records),
            temporalCorrelations: makeTemporalCorrelations(records: records),
            objectiveDecompositions: makeObjectiveDecompositions(official: official),
            strengthResponse: makeStrengthResponse(records: records, frames: frames, weights: weights),
        )
        if let outputURL {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try FileManager.default.createDirectory(
                at: outputURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try encoder.encode(report).write(to: outputURL, options: .atomic)
        }
        return report
    }

    private static func definitions() -> [V61Definition] {
        [
            V61Definition(key: "v2", label: "calibrated-v2", configuration: .calibratedV2),
            V61Definition(key: "v4", label: "calibrated-v4", configuration: .calibratedV4),
            V61Definition(
                key: "no-lowmid",
                label: HDRV6ToneCurveCandidate.noLowMid.shortName,
                configuration: HDRV6ToneCurveCandidate.noLowMid.configuration()
            ),
            V61Definition(
                key: "bl045",
                label: HDRV6ToneCurveCandidate.bandLimited045.shortName,
                configuration: HDRV6ToneCurveCandidate.bandLimited045.configuration()
            )
        ]
    }

    private static func prepareContext(manifestURL: URL, device: MTLDevice) async throws -> V61PreparedContext {
        let manifestData = try Data(contentsOf: manifestURL)
        let sourceManifest = try JSONDecoder().decode(V4Manifest.self, from: manifestData)
        let allowedPairs = sourceManifest.pairs.filter {
            V61ErrorAttributionMath.isAllowedDevelopmentPair(
                split: $0.split,
                virginFrozen: $0.virginFrozen
            )
        }
        guard !allowedPairs.isEmpty else {
            throw CalibrationError.incompleteEvaluation("no non-protected Tune/Validation pairs in manifest")
        }
        let safeManifest = V4Manifest(
            version: sourceManifest.version,
            pairs: allowedPairs,
            roots: sourceManifest.roots
        )
        try safeManifest.validate(relativeTo: manifestURL)
        let records = allowedPairs.map { pair -> PairRecord in
            let urls = pair.resolvedURLs(relativeTo: manifestURL, roots: sourceManifest.roots)
            return PairRecord(
                id: pair.id,
                sdr: urls.sdr.path,
                hdr: urls.hdr.path,
                license: pair.license,
                source: pair.source,
                expectedRelation: pair.expectedRelation.legacyRelation(),
                notes: pair.notes,
                split: pair.split
            )
        }
        let experiment = ExperimentConfig(
            seed: 20_260_905,
            candidateCount: 1,
            maxFramesPerScene: 8,
            alignmentConfidenceThreshold: 0,
            referenceTargetPeakNits: 1_000,
            allowHLGModel: true
        )
        let evaluator = PairEvaluator(device: device, experiment: experiment)
        var prepared: [PreparedPair] = []
        var skipped: [V61SkippedPair] = []
        for record in records {
            do {
                print("[V61Attribution] prepare \(record.id)")
                prepared.append(try await evaluator.prepare(record: record, manifestURL: manifestURL))
            } catch {
                skipped.append(V61SkippedPair(
                    pairID: record.id,
                    split: record.split,
                    reason: String(describing: error)
                ))
                print("[V61Attribution] skip \(record.id): \(error)")
            }
        }
        guard !prepared.isEmpty else {
            throw CalibrationError.incompleteEvaluation("no allowed pair could be prepared")
        }
        return V61PreparedContext(
            allowedPairs: allowedPairs,
            records: records,
            prepared: prepared,
            skipped: skipped
        )
    }

    private static func evaluateOfficial(
        preparedPairs: [PreparedPair],
        definitions: [V61Definition],
        weights: V2ObjectiveWeights,
        device: MTLDevice
    ) throws -> [String: V61OfficialCandidateResult] {
        let tune = preparedPairs.filter { $0.record.split == .tune }
        let validation = preparedPairs.filter { $0.record.split == .validation }
        var result: [String: V61OfficialCandidateResult] = [:]
        for definition in definitions {
            let parameters = CalibrationParameters(configuration: definition.configuration)
            let engine = V2EvaluationEngine(device: device, weights: weights)
            let tuneEvaluation = tune.isEmpty
                ? nil
                : try engine.evaluate(
                    preparedPairs: tune,
                    parameters: parameters,
                    label: "v6.1-\(definition.key)-tune",
                    split: .tune,
                    confidenceThreshold: 0
                )
            let validationEvaluation = validation.isEmpty
                ? nil
                : try engine.evaluate(
                    preparedPairs: validation,
                    parameters: parameters,
                    label: "v6.1-\(definition.key)-validation",
                    split: .validation,
                    confidenceThreshold: 0
                )
            result[definition.key] = V61OfficialCandidateResult(
                candidate: definition.label,
                tune: tuneEvaluation.map(V61OfficialSplitResult.init),
                validation: validationEvaluation.map(V61OfficialSplitResult.init)
            )
        }
        return result
    }

    private static func collectSamples(
        preparedPairs: [PreparedPair],
        definitions: [V61Definition],
        device: MTLDevice,
        categoriesByPairID: [String: [String]]
    ) throws -> ([V61PixelRecord], [V61FrameBundle]) {
        var records: [V61PixelRecord] = []
        var frames: [V61FrameBundle] = []
        for prepared in preparedPairs {
            let accepted = prepared.matches
                .filter { $0.match.confidence >= 0 }
                .sorted { ($0.match.sdrSequencePosition ?? .max) < ($1.match.sdrSequencePosition ?? .max) }
            var evaluators: [String: HDRCoreOfflineEvaluator] = [:]
            let categories = categoriesByPairID[prepared.record.id] ?? []
            for definition in definitions {
                evaluators[definition.key] = try HDRCoreOfflineEvaluator(
                    device: device,
                    configuration: definition.configuration
                )
            }
            for item in accepted {
                let sourceLinearLuma = try OfflinePixelSampler.linearLumaGrid(
                    pixelBuffer: item.sdr.pixelBuffer,
                    width: item.reference.width,
                    height: item.reference.height
                )
                guard sourceLinearLuma.count == item.sourceLuma.count else {
                    throw CalibrationError.decodeFailed(
                        "source linear luminance grid shape mismatch for \(prepared.record.id)"
                    )
                }
                let scene = prepared.scenes.first { scene in
                    guard let position = item.match.sdrSequencePosition else { return false }
                    return scene.contains(sequencePosition: position)
                }
                let sceneID = scene?.id ?? "unassigned"
                var generated: [String: GeneratedFrame] = [:]
                for definition in definitions {
                    guard let evaluator = evaluators[definition.key] else { continue }
                    generated[definition.key] = try evaluator.evaluateSpatiallyIndependent(
                        pixelBuffer: item.sdr.pixelBuffer,
                        timestampSeconds: item.match.sdrTimeSeconds,
                        configuration: definition.configuration
                    )
                }
                guard let referenceOutput = generated["v4"] else { continue }
                let scalarBreakdowns = definitions.reduce(into: [String: [HDRToneCurveScalarBreakdown?]]()) { partial, definition in
                    guard let output = generated[definition.key] else { return }
                    partial[definition.key] = sourceLinearLuma.map { source in
                        scalarBreakdown(
                            key: definition.key,
                            source: source,
                            output: output,
                            configuration: definition.configuration
                        )
                    }
                }
                let frame = V61FrameBundle(
                    key: V61SceneKey(pairID: prepared.record.id, sceneID: sceneID),
                    split: prepared.record.split,
                    transfer: prepared.referenceTransfer.canonicalName,
                    categories: categories,
                    frameIndex: item.sdr.index,
                    timestampSeconds: item.match.sdrTimeSeconds,
                    // This diagnostic scene metric is evaluated in the same
                    // linear source domain as the signed/bin attribution.
                    // Official objective decomposition remains sourced from
                    // V2EvaluationEngine above and is unchanged.
                    sourceLuma: sourceLinearLuma,
                    reference: item.reference,
                    outputs: generated,
                    confidence: item.match.confidence
                )
                frames.append(frame)
                let count = min(sourceLinearLuma.count, item.reference.lumaNits.count, referenceOutput.lumaNits.count)
                for index in 0..<count {
                    var outputSamples: [String: V61OutputSample] = [:]
                    for definition in definitions {
                        guard let output = generated[definition.key] else { continue }
                        let scalar = scalarBreakdowns[definition.key]?[index]
                        outputSamples[definition.key] = V61OutputSample(
                            luma: Double(output.lumaNits[index]),
                            lowMidContribution: Double(scalar?.lowMidContribution ?? 0),
                            shoulderContribution: Double(scalar?.shoulderContribution ?? 0),
                            totalExpansion: Double((scalar?.lowMidContribution ?? 0) + (scalar?.shoulderContribution ?? 0)),
                            temporalAdaptation: Double(output.temporalAdaptationUsed),
                            shadowFloor: Double(output.sceneShadowFloorUsed),
                            shadowTop: Double(output.sceneShadowTopUsed),
                            sceneStatisticsValid: output.sceneStatisticsValidUsed,
                            lowMidTransition: Double(scalar?.lowMidRise ?? 0)
                        )
                    }
                    records.append(V61PixelRecord(
                        pairID: prepared.record.id,
                        sceneID: sceneID,
                        split: prepared.record.split,
                        transfer: prepared.referenceTransfer.canonicalName,
                        categories: categories,
                        frameIndex: item.sdr.index,
                        timestampSeconds: item.match.sdrTimeSeconds,
                        sourceLuminance: Double(sourceLinearLuma[index]),
                        referenceLuminance: Double(item.reference.lumaNits[index]),
                        outputs: outputSamples
                    ))
                }
            }
        }
        return (records, frames)
    }

    private static func scalarBreakdown(
        key: String,
        source: Float,
        output: GeneratedFrame,
        configuration: HDRConfiguration
    ) -> HDRToneCurveScalarBreakdown? {
        switch key {
        case "v4":
            return HDRDiagnosticToneSweep.v4Breakdown(
                luminance: source,
                configuration: configuration,
                temporalAdaptation: output.temporalAdaptationUsed,
                sceneShadowFloor: output.sceneShadowFloorUsed,
                sceneShadowTop: output.sceneShadowTopUsed,
                sceneStatisticsValid: output.sceneStatisticsValidUsed,
                lowMidCoefficient: 0.08
            )
        case "no-lowmid", "bl045":
            let statistics = output.sceneStatisticsValidUsed
                ? HDRSceneStatistics(
                    p01: output.sceneShadowFloorUsed,
                    p05: output.sceneShadowFloorUsed,
                    p10: output.sceneShadowFloorUsed,
                    p25: 2 * output.sceneShadowTopUsed - output.sceneShadowFloorUsed,
                    p50: 0.42,
                    p90: 0.88,
                    p99: 1
                )
                : nil
            return HDRV6ToneCurveMath.breakdown(
                luminance: source,
                configuration: configuration,
                temporalAdaptation: output.temporalAdaptationUsed,
                sceneStatistics: statistics
            )
        default:
            return nil
        }
    }

    private static func makeBins(_ records: [V61PixelRecord]) -> [V61LuminanceBinResult] {
        let edges = V61ErrorAttributionMath.sourceLuminanceBinEdges
        return (0..<(edges.count - 1)).map { index in
            let lower = edges[index]
            let upper = edges[index + 1]
            let selected = records.filter { value in
                value.sourceLuminance >= lower &&
                    (value.sourceLuminance < upper || (index == edges.count - 2 && value.sourceLuminance <= upper))
            }
            return V61LuminanceBinResult(
                label: String(format: "[%.2f, %.2f%@", lower, upper, index == edges.count - 2 ? "]" : ")"),
                lowerBound: lower,
                upperBound: upper,
                sampleCount: selected.count,
                v2: candidateSummary(selected, key: "v2"),
                v4: candidateSummary(selected, key: "v4"),
                noLowMid: candidateSummary(selected, key: "no-lowmid"),
                bl045: candidateSummary(selected, key: "bl045"),
                v2MinusReference: signedSummary(selected.map { $0.outputs["v2"]!.luma - $0.referenceLuminance }),
                v4MinusReference: signedSummary(selected.map { $0.outputs["v4"]!.luma - $0.referenceLuminance }),
                v4MinusV2: signedSummary(selected.map { $0.outputs["v4"]!.luma - $0.outputs["v2"]!.luma })
            )
        }
    }

    private static func candidateSummary(_ records: [V61PixelRecord], key: String) -> V61CandidateErrorSummary {
        let values = records.compactMap { record -> (Double, V61OutputSample, Double)? in
            guard let output = record.outputs[key] else { return nil }
            let error = output.luma - record.referenceLuminance
            guard error.isFinite else { return nil }
            let logError = log((output.luma + 1) / (record.referenceLuminance + 1))
            return (error, output, logError)
        }
        let errors = values.map(\.0)
        let logs = values.map(\.2)
        let outputValues = values.map { $0.1 }
        let signed = V61SignedErrorSummary(signedValues: errors, signedLogValues: logs)
        let transitions = outputValues.map(\.lowMidTransition)
        return V61CandidateErrorSummary(
            sampleCount: values.count,
            signedError: signed,
            meanSignedLogError: V61ErrorAttributionMath.average(logs),
            meanSourceLuminance: V61ErrorAttributionMath.average(records.map(\.sourceLuminance)),
            meanReferenceLuminance: V61ErrorAttributionMath.average(records.map(\.referenceLuminance)),
            meanCandidateLuminance: V61ErrorAttributionMath.average(outputValues.map(\.luma)),
            meanLowMidContribution: V61ErrorAttributionMath.average(outputValues.map(\.lowMidContribution)),
            meanShoulderContribution: V61ErrorAttributionMath.average(outputValues.map(\.shoulderContribution)),
            meanTotalExpansion: V61ErrorAttributionMath.average(outputValues.map(\.totalExpansion)),
            meanTemporalAdaptation: V61ErrorAttributionMath.average(outputValues.map(\.temporalAdaptation)),
            meanShadowFloor: V61ErrorAttributionMath.average(outputValues.map(\.shadowFloor)),
            meanShadowTop: V61ErrorAttributionMath.average(outputValues.map(\.shadowTop)),
            sceneStatisticsValidRatio: outputValues.isEmpty
                ? 0
                : Double(outputValues.filter { $0.sceneStatisticsValid }.count) / Double(outputValues.count),
            meanLowMidTransition: V61ErrorAttributionMath.average(transitions),
            lowMidTransitionP50: V61ErrorAttributionMath.percentile(transitions, 0.50),
            lowMidTransitionP95: V61ErrorAttributionMath.percentile(transitions, 0.95),
            lowMidFullyActivatedRatio: transitions.isEmpty ? 0 : Double(transitions.filter { $0 >= 0.99 }.count) / Double(transitions.count)
        )
    }

    private static func signedSummary(_ values: [Double]) -> V61SignedErrorSummary {
        V61SignedErrorSummary(values: values)
    }

    private static func makeSceneBreakdown(
        frames: [V61FrameBundle],
        records: [V61PixelRecord],
        definitions: [V61Definition],
        weights: V2ObjectiveWeights
    ) -> [V61SceneResult] {
        let keys: [V61SceneKey] = Array(Set(frames.map { $0.key })).sorted {
            $0.pairID == $1.pairID ? $0.sceneID < $1.sceneID : $0.pairID < $1.pairID
        }
        return keys.compactMap { key in
            let sceneFrames = frames.filter { $0.key == key }
            let sceneRecords = records.filter { $0.pairID == key.pairID && $0.sceneID == key.sceneID }
            guard let first = sceneFrames.first, !sceneRecords.isEmpty else { return nil }
            let tags = Array(Set(first.categories)).sorted()
            let scene = SceneRange(id: key.sceneID, startSample: 0, endSample: 0, tags: tags)
            func result(for definition: V61Definition) -> V61SceneCandidateResult {
                let analyses = sceneFrames.compactMap { frame -> V2FrameData? in
                    guard let generated = frame.outputs[definition.key] else { return nil }
                    return V2FrameData(
                        reference: frame.reference,
                        generated: generated,
                        sourceLuma: frame.sourceLuma,
                        confidence: frame.confidence
                    )
                }
                let metric = V2MetricsEvaluator.evaluateScene(
                    pairID: key.pairID,
                    scene: scene,
                    frames: analyses,
                    configuration: CalibrationParameters(configuration: definition.configuration),
                    weights: weights
                ).metrics
                let summary = candidateSummary(sceneRecords, key: definition.key)
                return V61SceneCandidateResult(
                    spatialObjective: metric.objective,
                    signedAllError: summary.signedError,
                    signedMidtoneError: candidateSummary(
                        sceneRecords.filter { V61ErrorAttributionMath.diffuseRange.contains($0.sourceLuminance) },
                        key: definition.key
                    ).signedError,
                    highlightError: metric.highlightError,
                    shadowError: metric.shadowError,
                    meanLowMidContribution: summary.meanLowMidContribution,
                    meanShoulderContribution: summary.meanShoulderContribution,
                    meanTotalExpansion: summary.meanTotalExpansion,
                    meanTemporalAdaptation: summary.meanTemporalAdaptation,
                    meanShadowFloor: summary.meanShadowFloor,
                    meanShadowTop: summary.meanShadowTop,
                    sceneStatisticsValidRatio: summary.sceneStatisticsValidRatio,
                    weightedContributions: metric.weightedContributions
                )
            }
            let sourceValues = sceneRecords.map(\.sourceLuminance)
            let sourceP01 = V61ErrorAttributionMath.percentile(sourceValues, 0.01)
            let sourceP99 = V61ErrorAttributionMath.percentile(sourceValues, 0.99)
            return V61SceneResult(
                pairID: key.pairID,
                sceneID: key.sceneID,
                split: first.split,
                transfer: first.transfer,
                categories: tags,
                frameCount: sceneFrames.count,
                sampleCount: sceneRecords.count,
                averageSourceLuminance: V61ErrorAttributionMath.average(sourceValues),
                sourceP01: sourceP01,
                sourceP99: sourceP99,
                sourceDynamicRangeStops: log2(max(sourceP99, 1e-6) / max(sourceP01, 1e-6)),
                v2: result(for: definitions[0]),
                v4: result(for: definitions[1]),
                noLowMid: result(for: definitions[2]),
                bl045: result(for: definitions[3])
            )
        }
    }

    private static func makeTransferBreakdown(
        records: [V61PixelRecord],
        official: [String: V61OfficialCandidateResult]
    ) -> [V61TransferResult] {
        let groups: [V61TransferKey] = Array(Set(records.map {
            V61TransferKey(split: $0.split, transfer: $0.transfer)
        })).sorted {
            if $0.split.rawValue != $1.split.rawValue { return $0.split.rawValue < $1.split.rawValue }
            return $0.transfer < $1.transfer
        }
        return groups.map { group in
            let split = group.split
            let transfer = group.transfer
            let selected = records.filter { $0.split == split && $0.transfer == transfer }
            let pairIDs = Set(selected.map(\.pairID))
            func result(key: String) -> V61TransferCandidateResult {
                let videos = official[key].flatMap { split == .tune ? $0.tune?.videos : $0.validation?.videos } ?? []
                let videoRows = videos.filter { pairIDs.contains($0.pairID) }
                return V61TransferCandidateResult(
                    officialObjective: V61ErrorAttributionMath.average(videoRows.map(\.objective)),
                    highlightError: V61ErrorAttributionMath.average(videoRows.map(\.highlightError)),
                    shadowError: V61ErrorAttributionMath.average(videoRows.map(\.shadowError)),
                    signedMidtoneError: candidateSummary(
                        selected.filter { V61ErrorAttributionMath.diffuseRange.contains($0.sourceLuminance) },
                        key: key
                    ).signedError
                )
            }
            return V61TransferResult(
                split: split,
                transfer: transfer,
                videoCount: pairIDs.count,
                sceneCount: Set(selected.map { V61SceneKey(pairID: $0.pairID, sceneID: $0.sceneID) }).count,
                sampleCount: selected.count,
                v2: result(key: "v2"),
                v4: result(key: "v4"),
                noLowMid: result(key: "no-lowmid"),
                bl045: result(key: "bl045")
            )
        }
    }

    private static func makeContributionCorrelations(
        records: [V61PixelRecord]
    ) -> [V61ContributionCorrelationReport] {
        DatasetSplit.allCases.filter { $0 != .frozen }.flatMap { split in
            let selected = records.filter { $0.split == split }
            let scopes: [String] = ["all", "diffuse-midtone-0.15-0.45"]
            return scopes.flatMap { scope -> [V61ContributionCorrelationReport] in
                let scoped = scope == "all"
                    ? selected
                    : selected.filter { V61ErrorAttributionMath.diffuseRange.contains($0.sourceLuminance) }
                let keys: [String] = ["v4", "no-lowmid", "bl045"]
                return keys.map { key in
                    let low: [(Double, Double)] = scoped.compactMap { record in
                        guard let output = record.outputs[key] else { return nil }
                        return (output.lowMidContribution, output.luma - record.referenceLuminance)
                    }
                    let shoulder: [(Double, Double)] = scoped.compactMap { record in
                        guard let output = record.outputs[key] else { return nil }
                        return (output.shoulderContribution, output.luma - record.referenceLuminance)
                    }
                    let total: [(Double, Double)] = scoped.compactMap { record in
                        guard let output = record.outputs[key] else { return nil }
                        return (output.totalExpansion, output.luma - record.referenceLuminance)
                    }
                    return V61ContributionCorrelationReport(
                        split: split,
                        scope: scope,
                        candidate: key,
                        lowMidVsSignedError: V61ErrorAttributionMath.pearson(
                            low.map(\.0), low.map(\.1)
                        ),
                        shoulderVsSignedError: V61ErrorAttributionMath.pearson(
                            shoulder.map(\.0), shoulder.map(\.1)
                        ),
                        totalExpansionVsSignedError: V61ErrorAttributionMath.pearson(
                            total.map(\.0), total.map(\.1)
                        )
                    )
                }
            }
        }
    }

    private static func makeSceneAnchorCorrelations(
        records: [V61PixelRecord]
    ) -> [V61SceneAnchorCorrelationReport] {
        DatasetSplit.allCases.filter { $0 != .frozen }.flatMap { split -> [V61SceneAnchorCorrelationReport] in
            let selected = records.filter {
                $0.split == split && V61ErrorAttributionMath.diffuseRange.contains($0.sourceLuminance)
            }
            let keys: [String] = ["v4", "no-lowmid", "bl045"]
            return keys.map { key in
                let shadowTopSigned: [(Double, Double)] = selected.compactMap { record in
                    guard let output = record.outputs[key] else { return nil }
                    return (output.shadowTop, output.luma - record.referenceLuminance)
                }
                let shadowTopLow: [(Double, Double)] = selected.compactMap { record in
                    guard let output = record.outputs[key] else { return nil }
                    return (output.shadowTop, output.lowMidContribution)
                }
                let shadowFloorSigned: [(Double, Double)] = selected.compactMap { record in
                    guard let output = record.outputs[key] else { return nil }
                    return (output.shadowFloor, output.luma - record.referenceLuminance)
                }
                return V61SceneAnchorCorrelationReport(
                    split: split,
                    scope: "diffuse-midtone-0.15-0.45",
                    candidate: key,
                    shadowTopVsSignedMidtoneError: V61ErrorAttributionMath.pearson(
                        shadowTopSigned.map(\.0), shadowTopSigned.map(\.1)
                    ),
                    shadowTopVsLowMidContribution: V61ErrorAttributionMath.pearson(
                        shadowTopLow.map(\.0), shadowTopLow.map(\.1)
                    ),
                    shadowFloorVsSignedMidtoneError: V61ErrorAttributionMath.pearson(
                        shadowFloorSigned.map(\.0), shadowFloorSigned.map(\.1)
                    )
                )
            }
        }
    }

    private static func makeTemporalCorrelations(
        records: [V61PixelRecord]
    ) -> [V61TemporalCorrelationReport] {
        DatasetSplit.allCases.filter { $0 != .frozen }.flatMap { split -> [V61TemporalCorrelationReport] in
            let selected = records.filter { $0.split == split }
            let keys: [String] = ["v4", "no-lowmid", "bl045"]
            return keys.map { key in
                let pairs: [(Double, Double)] = selected.compactMap { record in
                    guard let output = record.outputs[key] else { return nil }
                    return (output.temporalAdaptation, output.luma - record.referenceLuminance)
                }
                let adaptation = pairs.map(\.0)
                let errors = pairs
                return V61TemporalCorrelationReport(
                    split: split,
                    candidate: key,
                    sampleCount: errors.count,
                    uniqueTemporalAdaptationCount: Set(adaptation.map { Int(($0 * 1_000_000).rounded()) }).count,
                    meanTemporalAdaptation: V61ErrorAttributionMath.average(adaptation),
                    minimumTemporalAdaptation: adaptation.min() ?? 0,
                    maximumTemporalAdaptation: adaptation.max() ?? 0,
                    temporalAdaptationVsSignedError: V61ErrorAttributionMath.pearson(
                        errors.map(\.0), errors.map(\.1)
                    )
                )
            }
        }
    }

    private static func makeObjectiveDecompositions(
        official: [String: V61OfficialCandidateResult]
    ) -> [V61ObjectiveDecomposition] {
        DatasetSplit.allCases.filter { $0 != .frozen }.compactMap { split in
            guard let base = official["v4"]?.split(split),
                  let no = official["no-lowmid"]?.split(split),
                  let bl = official["bl045"]?.split(split) else { return nil }
            let baseComponents = base.weightedContributions
            let noComponents = no.weightedContributions
            let blComponents = bl.weightedContributions
            let noDelta = componentDeltas(base: baseComponents, candidate: noComponents)
            let blDelta = componentDeltas(base: baseComponents, candidate: blComponents)
            let noReported = no.objective - base.objective
            let blReported = bl.objective - base.objective
            let noSum = V61ErrorAttributionMath.weightedComponentSum(noDelta)
            let blSum = V61ErrorAttributionMath.weightedComponentSum(blDelta)
            return V61ObjectiveDecomposition(
                split: split,
                baselineObjective: base.objective,
                noLowMidObjective: no.objective,
                bl045Objective: bl.objective,
                baselineComponents: baseComponents,
                noLowMidComponents: noComponents,
                bl045Components: blComponents,
                noLowMidComponentDeltas: noDelta,
                bl045ComponentDeltas: blDelta,
                noLowMidReportedDelta: noReported,
                bl045ReportedDelta: blReported,
                noLowMidDeltaSum: noSum,
                bl045DeltaSum: blSum,
                noLowMidSumMatchesReported: abs(noSum - noReported) <= 1e-9,
                bl045SumMatchesReported: abs(blSum - blReported) <= 1e-9
            )
        }
    }

    private static func componentDeltas(
        base: [String: Double],
        candidate: [String: Double]
    ) -> [String: Double] {
        let keys = Set(base.keys).union(candidate.keys)
        return Dictionary(uniqueKeysWithValues: keys.sorted().map {
            ($0, (candidate[$0] ?? 0) - (base[$0] ?? 0))
        })
    }

    private static func makeStrengthResponse(
        records: [V61PixelRecord],
        frames: [V61FrameBundle],
        weights: V2ObjectiveWeights
    ) -> V61StrengthResponseReport {
        let scales = [0.0, 0.25, 0.50, 0.75, 1.0]
        let tuneRecords = records.filter { $0.split == .tune }
        let validationRecords = records.filter { $0.split == .validation }
        let sceneKeys: [V61SceneKey] = Array(Set(frames.map { $0.key })).sorted {
            $0.pairID == $1.pairID ? $0.sceneID < $1.sceneID : $0.pairID < $1.pairID
        }
        let scenes: [V61SceneStrengthResponse] = sceneKeys.map { key in
            V61SceneStrengthResponse(
                pairID: key.pairID,
                sceneID: key.sceneID,
                split: records.first(where: { $0.pairID == key.pairID && $0.sceneID == key.sceneID })?.split ?? .tune,
                points: makeStrengthPoints(
                    records: records.filter { $0.pairID == key.pairID && $0.sceneID == key.sceneID },
                    split: records.first(where: { $0.pairID == key.pairID && $0.sceneID == key.sceneID })?.split ?? .tune,
                    scales: scales,
                    weights: weights
                )
            )
        }
        return V61StrengthResponseReport(
            scales: scales,
            productionCoefficient: 0.08,
            tune: makeStrengthPoints(records: tuneRecords, split: .tune, scales: scales, weights: weights),
            validation: makeStrengthPoints(records: validationRecords, split: .validation, scales: scales, weights: weights),
            scenes: scenes
        )
    }

    private static func makeStrengthPoints(
        records: [V61PixelRecord],
        split: DatasetSplit,
        scales: [Double],
        weights: V2ObjectiveWeights
    ) -> [V61StrengthResponsePoint] {
        scales.map { scale in
            let output = records.map { record -> Double in
                let v4 = record.outputs["v4"]!
                let breakdown = HDRDiagnosticToneSweep.v4Breakdown(
                    luminance: Float(record.sourceLuminance),
                    configuration: .calibratedV4,
                    temporalAdaptation: Float(v4.temporalAdaptation),
                    sceneShadowFloor: Float(v4.shadowFloor),
                    sceneShadowTop: Float(v4.shadowTop),
                    sceneStatisticsValid: v4.sceneStatisticsValid,
                    lowMidCoefficient: Float(0.08 * scale)
                )
                return Double(breakdown.expandedLuminance * HDRConfiguration.calibratedV4.paperWhiteNits)
            }
            let metrics = scalarMetrics(records: records, generated: output, weights: weights)
            return V61StrengthResponsePoint(
                split: split,
                scale: scale,
                effectiveCoefficient: 0.08 * scale,
                sampleCount: metrics.signedAll.sampleCount,
                toneOnlyObjective: metrics.toneOnlyObjective,
                meanSignedError: metrics.signedAll,
                signedMidtoneError: metrics.signedMidtone,
                highlightError: metrics.highlightError,
                shadowError: metrics.shadowError
            )
        }
    }

    private static func scalarMetrics(
        records: [V61PixelRecord],
        generated: [Double],
        weights: V2ObjectiveWeights
    ) -> V61ScalarMetricValues {
        let count = min(records.count, generated.count)
        let reference = (0..<count).map { records[$0].referenceLuminance }
        let values = Array(generated.prefix(count))
        let signed = values.indices.map { values[$0] - reference[$0] }
        let signedLog = values.indices.map { log((values[$0] + 1) / (reference[$0] + 1)) }
        let signedAll = V61SignedErrorSummary(signedValues: signed, signedLogValues: signedLog)
        let midIndices = (0..<count).filter { V61ErrorAttributionMath.diffuseRange.contains(records[$0].sourceLuminance) }
        let midSigned = V61SignedErrorSummary(
            signedValues: midIndices.map { signed[$0] },
            signedLogValues: midIndices.map { signedLog[$0] }
        )
        let luma = averageAbsLog(reference, values)
        let absoluteNits = V61ErrorAttributionMath.average(values.indices.map { abs(values[$0] - reference[$0]) / 1_000 })
        let midtone = percentileRegionError(reference, values, lower: 0.10, upper: 0.90)
        let diffuseWhite = percentileRegionError(reference, values, lower: 0.75, upper: 0.95)
        let highlight = percentileRegionError(reference, values, lower: 0.90, upper: 1.00)
        let shadow = percentileRegionError(reference, values, lower: 0.00, upper: 0.10)
        let toneOnlyObjective =
            weights.luminance * luma +
            weights.absoluteNits * absoluteNits +
            weights.midtone * midtone +
            weights.diffuseWhite * diffuseWhite +
            weights.highlight * highlight +
            weights.shadow * shadow
        return V61ScalarMetricValues(
            toneOnlyObjective: toneOnlyObjective,
            signedAll: signedAll,
            signedMidtone: midSigned,
            highlightError: highlight,
            shadowError: shadow
        )
    }

    private static func averageAbsLog(_ lhs: [Double], _ rhs: [Double]) -> Double {
        let count = min(lhs.count, rhs.count)
        guard count > 0 else { return 0 }
        return V61ErrorAttributionMath.average((0..<count).map {
            abs(log((rhs[$0] + 1) / (lhs[$0] + 1)))
        })
    }

    private static func percentileRegionError(
        _ reference: [Double],
        _ generated: [Double],
        lower: Double,
        upper: Double
    ) -> Double {
        let count = min(reference.count, generated.count)
        guard count > 0 else { return 0 }
        let sorted = reference.sorted()
        let low = V61ErrorAttributionMath.percentile(sorted, lower)
        let high = V61ErrorAttributionMath.percentile(sorted, upper)
        let indices = (0..<count).filter { reference[$0] >= low && reference[$0] <= high }
        guard !indices.isEmpty else { return 0 }
        return V61ErrorAttributionMath.average(indices.map {
            abs(log((generated[$0] + 1) / (reference[$0] + 1)))
        })
    }
}

private extension V61OfficialSplitResult {
    init(_ evaluation: V2DatasetEvaluation) {
        split = evaluation.split
        videoCount = evaluation.videoCount
        frameCount = evaluation.frameCount
        sceneCount = evaluation.sceneCount
        objective = evaluation.metrics.objective
        weightedContributions = evaluation.metrics.weightedContributions
        videos = evaluation.videos.map {
            V61OfficialVideoResult(
                pairID: $0.pairID,
                objective: $0.metrics.objective,
                highlightError: $0.metrics.highlightError,
                shadowError: $0.metrics.shadowError,
                weightedContributions: $0.metrics.weightedContributions
            )
        }
    }

    func split(_ value: DatasetSplit) -> V61OfficialSplitResult? {
        value == .tune ? self : nil
    }
}

private extension V61OfficialCandidateResult {
    func split(_ value: DatasetSplit) -> V61OfficialSplitResult? {
        switch value {
        case .tune: return tune
        case .validation: return validation
        case .frozen: return nil
        }
    }
}

private extension V61ErrorAttributionMath {
    static let diffuseRange: ClosedRange<Double> = 0.15...0.45
}
