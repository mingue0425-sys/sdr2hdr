import Foundation
import HDRCore
import Metal

/// The compact metric projection used by the V6 development report. The
/// existing V2 objective remains the objective; the diffuse-midtone values are
/// diagnostic-only additions.
public struct V6DevelopmentMetricSummary: Codable, Sendable {
    public let objective: Double
    public let luminanceError: Double
    public let absoluteNitError: Double
    public let midtoneError: Double
    public let diffuseWhiteError: Double
    public let highlightError: Double
    public let shadowError: Double
    public let chromaError: Double
    public let saturationError: Double
    public let temporalLuminanceError: Double
    public let highlightPumping: Double
    public let temporalFlicker: Double
    public let sceneCutOvershoot: Double
    public let sceneCutRecovery: Double
    public let nearBlackContrastLoss: Double
    public let clippingRatio: Double
    public let blackCrushRatio: Double
    public let shadowLiftRatio: Double
    public let highlightUnderReachRatio: Double
    public let highlightOvershootRatio: Double
    public let specularPeakUnderReach: Double
    public let specularPeakOvershoot: Double
    public let diffuseMidtoneError: Double
    public let diffuseMidtoneOvershoot: Double
    public let diffuseMidtoneOvershootP95: Double
    public let diffuseMidtoneSampleCount: Double
    public let referenceDiffuseWhiteNits: Double
    public let generatedDiffuseWhiteNits: Double
    public let overSaturationRatio: Double
    public let underSaturationRatio: Double

    init(_ metrics: V2MetricBreakdown) {
        objective = metrics.objective
        luminanceError = metrics.luminanceError
        absoluteNitError = metrics.absoluteNitError
        midtoneError = metrics.midtoneError
        diffuseWhiteError = metrics.diffuseWhiteError
        highlightError = metrics.highlightError
        shadowError = metrics.shadowError
        chromaError = metrics.chromaError
        saturationError = metrics.saturationError
        temporalLuminanceError = metrics.temporalLuminanceError
        highlightPumping = metrics.highlightPumping
        temporalFlicker = metrics.temporalFlicker
        sceneCutOvershoot = metrics.sceneCutOvershoot
        sceneCutRecovery = metrics.sceneCutRecovery
        nearBlackContrastLoss = metrics.nearBlackContrastLoss
        clippingRatio = metrics.clippingRatio
        blackCrushRatio = metrics.blackCrushRatio
        shadowLiftRatio = metrics.shadowLiftRatio
        highlightUnderReachRatio = metrics.highlightUnderReachRatio
        highlightOvershootRatio = metrics.highlightOvershootRatio
        specularPeakUnderReach = metrics.specularPeakUnderReach
        specularPeakOvershoot = metrics.specularPeakOvershoot
        diffuseMidtoneError = metrics.diffuseMidtoneError
        diffuseMidtoneOvershoot = metrics.diffuseMidtoneOvershoot
        diffuseMidtoneOvershootP95 = metrics.diffuseMidtoneOvershootP95
        diffuseMidtoneSampleCount = metrics.diffuseMidtoneSampleCount
        referenceDiffuseWhiteNits = metrics.referenceDiffuseWhiteNits
        generatedDiffuseWhiteNits = metrics.generatedDiffuseWhiteNits
        overSaturationRatio = metrics.overSaturationRatio
        underSaturationRatio = metrics.underSaturationRatio
    }
}

public struct V6DevelopmentVideoSummary: Codable, Sendable {
    public let pairID: String
    public let frameCount: Int
    public let sceneCount: Int
    public let metrics: V6DevelopmentMetricSummary

    init(_ video: V2VideoEvaluation) {
        pairID = video.pairID
        frameCount = video.frameCount
        sceneCount = video.sceneCount
        metrics = V6DevelopmentMetricSummary(video.metrics)
    }
}

public struct V6DevelopmentSplitSummary: Codable, Sendable {
    public let split: DatasetSplit
    public let label: String
    public let videoCount: Int
    public let frameCount: Int
    public let sceneCount: Int
    public let metrics: V6DevelopmentMetricSummary
    public let videos: [V6DevelopmentVideoSummary]

    init(_ evaluation: V2DatasetEvaluation) {
        split = evaluation.split
        label = evaluation.label
        videoCount = evaluation.videoCount
        frameCount = evaluation.frameCount
        sceneCount = evaluation.sceneCount
        metrics = V6DevelopmentMetricSummary(evaluation.metrics)
        videos = evaluation.videos.map(V6DevelopmentVideoSummary.init)
    }
}

public struct V6DevelopmentSkippedPair: Codable, Sendable {
    public let pairID: String
    public let split: DatasetSplit
    public let reason: String

    init(pairID: String, split: DatasetSplit, reason: String) {
        self.pairID = pairID
        self.split = split
        self.reason = reason
    }
}

public struct V6DevelopmentCandidateResult: Codable, Sendable {
    public let candidate: String
    public let shortName: String
    public let fadePosition: Float
    public let lowMidStrength: Float
    public let invariantPass: Bool
    public let invariantReports: [HDRV6CurveInvariantReport]
    public let tune: V6DevelopmentSplitSummary?
    public let validation: V6DevelopmentSplitSummary?
    public let evaluationStatus: String

    init(
        candidate: String,
        shortName: String,
        fadePosition: Float,
        lowMidStrength: Float,
        invariantPass: Bool,
        invariantReports: [HDRV6CurveInvariantReport],
        tune: V6DevelopmentSplitSummary?,
        validation: V6DevelopmentSplitSummary?,
        evaluationStatus: String
    ) {
        self.candidate = candidate
        self.shortName = shortName
        self.fadePosition = fadePosition
        self.lowMidStrength = lowMidStrength
        self.invariantPass = invariantPass
        self.invariantReports = invariantReports
        self.tune = tune
        self.validation = validation
        self.evaluationStatus = evaluationStatus
    }
}

public struct V6ToneCurveDevelopmentReport: Codable, Sendable {
    public let schemaVersion: String
    public let manifestPath: String
    public let allowedSplits: [DatasetSplit]
    public let allowedPairIDs: [String]
    public let preparedPairIDs: [String]
    public let skippedPairs: [V6DevelopmentSkippedPair]
    public let protectedMediaAccessed: Bool
    public let objectiveEvaluationsOutsideAllowedSplits: Int
    public let candidates: [V6DevelopmentCandidateResult]

    init(
        manifestPath: String,
        allowedPairIDs: [String],
        preparedPairIDs: [String],
        skippedPairs: [V6DevelopmentSkippedPair],
        candidates: [V6DevelopmentCandidateResult]
    ) {
        schemaVersion = "v6-tone-curve-development-1"
        self.manifestPath = manifestPath
        allowedSplits = [.tune, .validation]
        self.allowedPairIDs = allowedPairIDs
        self.preparedPairIDs = preparedPairIDs
        self.skippedPairs = skippedPairs
        protectedMediaAccessed = false
        objectiveEvaluationsOutsideAllowedSplits = 0
        self.candidates = candidates
    }

    public var tunePairCount: Int {
        candidates.compactMap(\.tune).first?.videoCount ?? 0
    }

    public var validationPairCount: Int {
        candidates.compactMap(\.validation).first?.videoCount ?? 0
    }
}

/// Tune/Validation-only evaluator for the V6 structural family. It decodes
/// the requested V4 manifest but filters the records in memory before any
/// validation, path resolution, or media operation. No protected split is
/// passed to PairEvaluator or V2EvaluationEngine.
public enum V6ToneCurveDevelopmentRunner {
    public static func run(
        manifestURL: URL,
        outputURL: URL? = nil,
        device suppliedDevice: MTLDevice? = MTLCreateSystemDefaultDevice()
    ) async throws -> V6ToneCurveDevelopmentReport {
        guard let device = suppliedDevice else {
            throw CalibrationError.decodeFailed("Metal device unavailable")
        }

        let manifestData = try Data(contentsOf: manifestURL)
        let sourceManifest = try JSONDecoder().decode(V4Manifest.self, from: manifestData)
        let allowedV4Pairs = sourceManifest.pairs.filter {
            ($0.split == .tune || $0.split == .validation) && !$0.virginFrozen
        }
        guard !allowedV4Pairs.isEmpty else {
            throw CalibrationError.incompleteEvaluation("no non-protected Tune/Validation pairs in manifest")
        }

        // Validate only the filtered development manifest. Calling
        // V4Manifest.load on the source manifest would enumerate all records,
        // including records outside this development scope.
        let safeManifest = V4Manifest(
            version: sourceManifest.version,
            pairs: allowedV4Pairs,
            roots: sourceManifest.roots
        )
        try safeManifest.validate(relativeTo: manifestURL)

        let records = allowedV4Pairs.map { pair -> PairRecord in
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
        var skipped: [V6DevelopmentSkippedPair] = []
        for record in records {
            do {
                print("[V6Development] prepare \(record.id)")
                prepared.append(try await evaluator.prepare(record: record, manifestURL: manifestURL))
            } catch {
                skipped.append(V6DevelopmentSkippedPair(
                    pairID: record.id,
                    split: record.split,
                    reason: String(describing: error)
                ))
                print("[V6Development] skip \(record.id): \(error)")
            }
        }
        guard !prepared.isEmpty else {
            throw CalibrationError.incompleteEvaluation("no Tune/Validation pair could be prepared")
        }

        let weights = V4CalibrationConfiguration().weights
        let tunePrepared = prepared.filter { $0.record.split == .tune }
        let validationPrepared = prepared.filter { $0.record.split == .validation }
        var results: [V6DevelopmentCandidateResult] = []

        func evaluate(
            _ engine: V2EvaluationEngine,
            preparedPairs: [PreparedPair],
            parameters: CalibrationParameters,
            candidateLabel: String,
            split: DatasetSplit
        ) throws -> V6DevelopmentSplitSummary? {
            guard !preparedPairs.isEmpty else { return nil }
            let evaluation = try engine.evaluate(
                preparedPairs: preparedPairs,
                parameters: parameters,
                label: candidateLabel + "-" + split.rawValue,
                split: split,
                confidenceThreshold: experiment.alignmentConfidenceThreshold
            )
            return V6DevelopmentSplitSummary(evaluation)
        }

        let invariantReports: (HDRV6ToneCurveCandidate) -> [HDRV6CurveInvariantReport] = { candidate in
            HDRV6ToneCurveDevelopment.anchorFamilies.map { anchor in
                HDRV6ToneCurveDevelopment.invariantReport(
                    candidate: candidate,
                    sceneShadowFloor: anchor.floor,
                    sceneShadowTop: anchor.top
                )
            }
        }

        let baselineParameters = CalibrationParameters(configuration: .calibratedV4)
        let baselineEngine = V2EvaluationEngine(device: device, weights: weights)
        results.append(V6DevelopmentCandidateResult(
            candidate: "v4-baseline",
            shortName: "V4_BASELINE",
            fadePosition: 0,
            lowMidStrength: 0.08,
            invariantPass: true,
            invariantReports: [],
            tune: try evaluate(baselineEngine, preparedPairs: tunePrepared, parameters: baselineParameters, candidateLabel: "v4-baseline", split: .tune),
            validation: try evaluate(baselineEngine, preparedPairs: validationPrepared, parameters: baselineParameters, candidateLabel: "v4-baseline", split: .validation),
            evaluationStatus: "evaluated"
        ))

        for candidate in HDRV6ToneCurveCandidate.allCases {
            let reports = invariantReports(candidate)
            let invariantPass = reports.allSatisfy(\.allPassed)
            guard invariantPass else {
                results.append(V6DevelopmentCandidateResult(
                    candidate: candidate.rawValue,
                    shortName: candidate.shortName,
                    fadePosition: candidate.fadePosition,
                    lowMidStrength: candidate.lowMidStrength,
                    invariantPass: false,
                    invariantReports: reports,
                    tune: nil,
                    validation: nil,
                    evaluationStatus: "rejected-hard-invariant"
                ))
                continue
            }
            let parameters = CalibrationParameters(configuration: candidate.configuration())
            let engine = V2EvaluationEngine(device: device, weights: weights)
            results.append(V6DevelopmentCandidateResult(
                candidate: candidate.rawValue,
                shortName: candidate.shortName,
                fadePosition: candidate.fadePosition,
                lowMidStrength: candidate.lowMidStrength,
                invariantPass: true,
                invariantReports: reports,
                tune: try evaluate(engine, preparedPairs: tunePrepared, parameters: parameters, candidateLabel: candidate.rawValue, split: .tune),
                validation: try evaluate(engine, preparedPairs: validationPrepared, parameters: parameters, candidateLabel: candidate.rawValue, split: .validation),
                evaluationStatus: "evaluated"
            ))
        }

        let report = V6ToneCurveDevelopmentReport(
            manifestPath: manifestURL.standardizedFileURL.path,
            allowedPairIDs: records.map(\.id),
            preparedPairIDs: prepared.map { $0.record.id },
            skippedPairs: skipped,
            candidates: results
        )
        if let outputURL {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encoder.encode(report).write(to: outputURL, options: .atomic)
        }
        return report
    }
}
