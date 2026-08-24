import CryptoKit
import Foundation
import HDRCore
import Metal

public enum CalibrationV4Verdict: String, Codable, Sendable {
    case promote = "PROMOTE_CALIBRATED_V4"
    case keepV2 = "KEEP_CALIBRATED_V2"
    case relativeShadowInsufficient = "RELATIVE_SHADOW_MODEL_INSUFFICIENT"
    case validationFail = "VALIDATION_FAIL"
    case transferGeneralizationFail = "TRANSFER_GENERALIZATION_FAIL"
    case virginFrozenFail = "VIRGIN_FROZEN_FAIL"
    case shadowGeneralizationFail = "SHADOW_GENERALIZATION_FAIL"
    case runtimeRegression = "RUNTIME_REGRESSION"
    case identifiabilityFail = "IDENTIFIABILITY_FAIL"
}

public struct V4SafetyThresholds: Codable, Sendable {
    public var shadowErrorTolerance: Double = 0.01
    public var shadowLiftTolerance: Double = 0.005
    public var temporalFlickerRelativeTolerance: Double = 0.05
    public var temporalFlickerAbsoluteTolerance: Double = 0.002
    public var highlightRelativeTolerance: Double = 0.05
    public var midtoneRelativeTolerance: Double = 0.05
    public var hueRelativeTolerance: Double = 0.05
    public var catastrophicSceneRegression: Double = 0.20
    public var frozenMinimumImprovement: Double = 0.05
    public var frozenPerVideoRegressionTolerance: Double = 0.02
    public var zeroTolerance: Double = 0.000001

    public init() {}
}

public struct V4ParameterBounds: Codable, Sendable {
    public var paperWhiteNits: ClosedRange<Float> = 190...245
    public var peakNits: ClosedRange<Float> = 900...1_500
    public var highlightStrength: ClosedRange<Float> = 0.42...0.86
    public var contrastStrength: ClosedRange<Float> = 0.50...0.95
    public var saturationCompensation: ClosedRange<Float> = 0.10...0.50
    public var shadowProtection: ClosedRange<Float> = 0.05...1.0
    public var temporalStability: ClosedRange<Float> = 0.20...0.98

    public init() {}
}

public struct V4CalibrationConfiguration: Codable, Sendable {
    public var version = "calibration-v4-scene-relative-shadow"
    public var splitSeed: UInt64 = 92
    public var searchSeed: UInt64 = 20_260_824
    public var globalCandidates: Int = 128
    public var localCandidates: Int = 64
    public var validationTopCount: Int = 8
    public var maxFramesPerScene: Int = 8
    public var confidenceThreshold: Double = 0.60
    public var referenceTargetPeakNits: Float = 1_000
    public var bounds = V4ParameterBounds()
    public var weights: V2ObjectiveWeights = {
        var value = V2ObjectiveWeights()
        value.shadow = 0.15
        value.temporal = 0.10
        return value
    }()
    /// Frozen before any Virgin Frozen access. This is part of the promotion
    /// protocol rather than an after-the-fact tuning knob.
    public var safety = V4SafetyThresholds()

    public init() {}
}

public struct V4SensitivityRecord: Codable, Sendable {
    public var parameter: String
    public var value: Float
    public var objective: Double
    public var shadowError: Double
    public var shadowLiftRatio: Double
    public var midtoneError: Double
    public var highlightError: Double
    public var temporalFlicker: Double
    public var highlightPumping: Double
    public var sceneCutRecovery: Double
}

public struct V4CandidateRecord: Codable, Sendable {
    public var id: String
    public var stage: String
    public var parameters: CalibrationParameters
    public var tune: V2DatasetEvaluation
    public var validation: V2DatasetEvaluation?
    public var constraintsPassed: Bool
    public var rejectionReasons: [String]
}

public struct V4FreezeArtifact: Codable, Sendable {
    public var version: String
    public var candidateID: String
    public var parameters: CalibrationParameters
    public var parameterHash: String
    public var codeHash: String
    public var manifestHash: String
    public var objectiveHash: String
    public var finalCandidateFrozen: Bool
    public var frozenOpened: Bool

    public init(
        version: String = "calibration-v4-freeze",
        candidateID: String,
        parameters: CalibrationParameters,
        parameterHash: String,
        codeHash: String,
        manifestHash: String,
        objectiveHash: String,
        finalCandidateFrozen: Bool,
        frozenOpened: Bool
    ) {
        self.version = version
        self.candidateID = candidateID
        self.parameters = parameters
        self.parameterHash = parameterHash
        self.codeHash = codeHash
        self.manifestHash = manifestHash
        self.objectiveHash = objectiveHash
        self.finalCandidateFrozen = finalCandidateFrozen
        self.frozenOpened = frozenOpened
    }
}

public final class V4FrozenExperimentGuard: @unchecked Sendable {
    private let lock = NSLock()
    private var finalCandidateFrozen = false
    private var opened = false

    public init() {}

    public func finalizeCandidate() {
        lock.lock()
        finalCandidateFrozen = true
        lock.unlock()
    }

    public func openVirginFrozenOnce() throws {
        lock.lock()
        defer { lock.unlock() }
        guard finalCandidateFrozen else {
            throw CalibrationError.invalidCandidate("Virgin Frozen requested before V4 candidate freeze")
        }
        guard !opened else {
            throw CalibrationError.invalidCandidate("V4 Virgin Frozen was already opened")
        }
        opened = true
    }
}

public struct V4FinalReport: Codable, Sendable {
    public var version: String
    public var generatedAt: String
    public var manifestPath: String
    public var configuration: V4CalibrationConfiguration
    public var split: V2SplitDocument
    public var transferByPair: [String: String]
    public var baseline: [String: V2DatasetEvaluation]
    public var shadowAudit: [String: V2DatasetEvaluation]
    public var sensitivity: [V4SensitivityRecord]
    public var globalCandidates: [V4CandidateRecord]
    public var localCandidates: [V4CandidateRecord]
    public var validationCandidates: [V4CandidateRecord]
    public var selectedCandidate: V4CandidateRecord?
    public var freeze: V4FreezeArtifact?
    public var frozen: [String: V2DatasetEvaluation]
    public var transferAnalysis: [String: [String: V2MetricBreakdown]]
    public var familyAnalysis: [String: [String: V2MetricBreakdown]]
    public var verdict: CalibrationV4Verdict
    public var reasons: [String]
    public var limitations: [String]
}

private struct V4FrozenComparison: Codable, Sendable {
    var defaultEvaluation: V2DatasetEvaluation
    var v1Evaluation: V2DatasetEvaluation
    var v2Evaluation: V2DatasetEvaluation
    var v4Evaluation: V2DatasetEvaluation
}

public final class CalibrationV4Runner {
    public let manifestURL: URL
    public let outputDirectory: URL
    public let configuration: V4CalibrationConfiguration

    private let device: MTLDevice
    private let frozenGuard = V4FrozenExperimentGuard()

    public init(
        manifestURL: URL,
        outputDirectory: URL,
        configuration: V4CalibrationConfiguration = V4CalibrationConfiguration(),
        device: MTLDevice? = MTLCreateSystemDefaultDevice()
    ) throws {
        guard let device else { throw CalibrationError.decodeFailed("Metal device unavailable") }
        self.manifestURL = manifestURL
        self.outputDirectory = outputDirectory
        self.configuration = configuration
        self.device = device
    }

    public func run() async throws -> V4FinalReport {
        let manifest = try V4Manifest.load(from: manifestURL)
        try validateV4Split(manifest)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        let transferByPair = try await probeTransfers(manifest)
        let records = makeLegacyRecords(manifest)
        let tuneV4 = records.filter { $0.split == .tune }
        let validationV4 = records.filter { $0.split == .validation }
        let virginIDs = Set(manifest.pairs.filter(\.virginFrozen).map(\.id))
        let virginV4 = records.filter { $0.split == .frozen && virginIDs.contains($0.id) }

        let repository = V2PreparedRepository(
            manifestURL: manifestURL,
            device: device,
            configuration: preparationConfiguration()
        )
        log(String(format: "prepare Tune %d + Validation %d; Virgin Frozen remains sealed", tuneV4.count, validationV4.count))
        let tunePrepared = try await repository.prepare(records: tuneV4)
        let validationPrepared = try await repository.prepare(records: validationV4)
        let engine = V2EvaluationEngine(device: device, weights: configuration.weights)

        let defaults = parameters(.hdr, revision: .legacyV2)
        let v1 = parameters(.calibratedV1, revision: .legacyV2)
        let v2 = parameters(.calibratedV2, revision: .legacyV2)
        let v3Absolute = parameters(.calibratedV3Candidate, revision: .shadowProtectedV3)
        let v4Center = parameters(.calibratedV2, revision: .sceneRelativeV4)

        let defaultTune = try evaluate(engine, tunePrepared, defaults, "default-tune", .tune, manifest)
        let v1Tune = try evaluate(engine, tunePrepared, v1, "v1-tune", .tune, manifest)
        let v2Tune = try evaluate(engine, tunePrepared, v2, "v2-tune", .tune, manifest)
        let defaultValidation = try evaluate(engine, validationPrepared, defaults, "default-validation", .validation, manifest)
        let v1Validation = try evaluate(engine, validationPrepared, v1, "v1-validation", .validation, manifest)
        let v2Validation = try evaluate(engine, validationPrepared, v2, "v2-validation", .validation, manifest)

        // V3 reproduction and the fixed-parameter absolute-vs-relative A/B
        // happen only on Tune/Validation. No Virgin Frozen pixels are read.
        let v3Tune = try evaluate(engine, tunePrepared, v3Absolute, "v3-absolute-tune", .tune, manifest)
        let v3Validation = try evaluate(engine, validationPrepared, v3Absolute, "v3-absolute-validation", .validation, manifest)
        let relativeTune = try evaluate(engine, tunePrepared, v4Center, "v4-relative-center-tune", .tune, manifest)
        let relativeValidation = try evaluate(engine, validationPrepared, v4Center, "v4-relative-center-validation", .validation, manifest)

        let baseline = [
            "default-tune": defaultTune, "v1-tune": v1Tune, "v2-tune": v2Tune,
            "v3-absolute-tune": v3Tune, "v4-relative-center-tune": relativeTune,
            "default-validation": defaultValidation, "v1-validation": v1Validation,
            "v2-validation": v2Validation, "v3-absolute-validation": v3Validation,
            "v4-relative-center-validation": relativeValidation
        ]
        try writeJSON(baseline, name: "data-video-v4-baseline.json")

        let sensitivity = try sensitivitySweep(engine: engine, tune: tunePrepared, center: v4Center, manifest: manifest)
        let shadowAudit = [
            "v3-absolute-tune": v3Tune, "v3-absolute-validation": v3Validation,
            "v4-relative-tune": relativeTune, "v4-relative-validation": relativeValidation
        ]
        try writeJSON(shadowAudit, name: "data-video-v4-shadow-audit.json")
        try writeJSON(sensitivity, name: "data-video-v4-sensitivity.json")

        let sensitivityGate = validateSensitivity(sensitivity)
        guard sensitivityGate.passed else {
            let report = makeFailureReport(
                manifest: manifest, transferByPair: transferByPair, baseline: baseline,
                shadowAudit: shadowAudit, sensitivity: sensitivity,
                reason: sensitivityGate.reason, verdict: .identifiabilityFail
            )
            try writeArtifacts(report)
            return report
        }

        log(String(format: "scene-relative sensitivity passed; global Halton search %d", configuration.globalCandidates))
        var global: [V4CandidateRecord] = []
        for index in 0..<configuration.globalCandidates {
            let candidate = globalParameters(index: index)
            let metrics = try evaluate(engine, tunePrepared, candidate, "v4-global-" + String(index), .tune, manifest)
            global.append(candidateRecord(
                id: String(format: "global_%03d", index), stage: "global-halton",
                parameters: candidate, tune: metrics, baseline: v2Tune
            ))
            if (index + 1) % 16 == 0 { log(String(format: "global %d/%d", index + 1, configuration.globalCandidates)) }
        }
        let globalTop = Array(global.filter(\.constraintsPassed).sorted { $0.tune.metrics.objective < $1.tune.metrics.objective }.prefix(8))
        guard !globalTop.isEmpty else {
            let report = makeFailureReport(
                manifest: manifest, transferByPair: transferByPair, baseline: baseline,
                shadowAudit: shadowAudit, sensitivity: sensitivity,
                reason: "No global V4 candidate passed Tune safety gates", verdict: .validationFail,
                global: global
            )
            try writeArtifacts(report)
            return report
        }

        log(String(format: "local refinement %d", configuration.localCandidates))
        var local: [V4CandidateRecord] = []
        for index in 0..<configuration.localCandidates {
            let center = globalTop[index % globalTop.count].parameters
            let candidate = localParameters(center: center, index: index)
            let metrics = try evaluate(engine, tunePrepared, candidate, "v4-local-" + String(index), .tune, manifest)
            local.append(candidateRecord(
                id: String(format: "local_%03d", index), stage: "local-halton",
                parameters: candidate, tune: metrics, baseline: v2Tune
            ))
            if (index + 1) % 16 == 0 { log(String(format: "local %d/%d", index + 1, configuration.localCandidates)) }
        }
        try writeJSON(["global": global, "local": local], name: "data-video-v4-search.json")

        let tuneTop = Array((global + local).filter(\.constraintsPassed)
            .sorted { $0.tune.metrics.objective < $1.tune.metrics.objective }
            .prefix(configuration.validationTopCount))
        var validationCandidates: [V4CandidateRecord] = []
        for var candidate in tuneTop {
            let validation = try evaluate(engine, validationPrepared, candidate.parameters, candidate.id, .validation, manifest)
            candidate.validation = validation
            let reasons = validationRejections(validation, baseline: v2Validation)
            if !reasons.isEmpty {
                candidate.constraintsPassed = false
                candidate.rejectionReasons.append(contentsOf: reasons)
            }
            validationCandidates.append(candidate)
        }
        try writeJSON(validationCandidates, name: "data-video-v4-validation.json")

        guard let selected = validationCandidates.filter(\.constraintsPassed).min(by: {
            ($0.validation?.metrics.objective ?? .infinity) < ($1.validation?.metrics.objective ?? .infinity)
        }), let selectedValidation = selected.validation else {
            let report = makeFailureReport(
                manifest: manifest, transferByPair: transferByPair, baseline: baseline,
                shadowAudit: shadowAudit, sensitivity: sensitivity,
                reason: "No V4 candidate passed Validation safety and objective gates", verdict: .validationFail,
                global: global, local: local, validation: validationCandidates
            )
            try writeArtifacts(report)
            return report
        }

        let selectedTune = selected.tune
        let candidate = selected.parameters
        let parameterHash = sha256(try encode(candidate))
        let manifestHash = sha256(try Data(contentsOf: manifestURL))
        let objectiveHash = sha256(try encode(configuration))
        let codeHash = sourceCodeHash()
        let initialFreeze = V4FreezeArtifact(
            candidateID: selected.id, parameters: candidate,
            parameterHash: parameterHash, codeHash: codeHash,
            manifestHash: manifestHash, objectiveHash: objectiveHash,
            finalCandidateFrozen: true, frozenOpened: false
        )
        frozenGuard.finalizeCandidate()
        try writeJSON(selected, name: "calibrated-v4-candidate.json")
        try writeJSON(initialFreeze, name: "calibrated-v4-freeze.json")
        log("candidate " + selected.id + " frozen; opening exactly three Virgin Frozen pairs once")

        try frozenGuard.openVirginFrozenOnce()
        let frozenRecords = records.filter { record in
            virginV4.contains(where: { $0.id == record.id })
        }
        guard frozenRecords.count == 3 else {
            throw CalibrationError.invalidManifest("V4 requires exactly three Virgin Frozen records, found " + String(frozenRecords.count))
        }
        let frozenPrepared = try await repository.prepare(records: frozenRecords)
        let frozenDefault = try evaluate(engine, frozenPrepared, defaults, "default-virgin-frozen", .frozen, manifest)
        let frozenV1 = try evaluate(engine, frozenPrepared, v1, "v1-virgin-frozen", .frozen, manifest)
        let frozenV2 = try evaluate(engine, frozenPrepared, v2, "v2-virgin-frozen", .frozen, manifest)
        let frozenV4 = try evaluate(engine, frozenPrepared, candidate, "v4-virgin-frozen", .frozen, manifest)
        let frozen = [
            "default": frozenDefault, "calibratedV1": frozenV1,
            "calibratedV2": frozenV2, "calibratedV4": frozenV4
        ]
        try writeJSON(frozen, name: "data-video-v4-frozen.json")

        let finalFreeze = V4FreezeArtifact(
            candidateID: initialFreeze.candidateID, parameters: initialFreeze.parameters,
            parameterHash: initialFreeze.parameterHash, codeHash: initialFreeze.codeHash,
            manifestHash: initialFreeze.manifestHash, objectiveHash: initialFreeze.objectiveHash,
            finalCandidateFrozen: true, frozenOpened: true
        )
        try writeJSON(finalFreeze, name: "calibrated-v4-freeze.json")

        let transferAnalysis = transferAnalysis(
            evaluations: ["v2": frozenV2, "v4": frozenV4], records: frozenRecords, transferByPair: transferByPair
        )
        let familyAnalysis = familyAnalysis(
            evaluations: ["v2": frozenV2, "v4": frozenV4], manifest: manifest
        )
        let decision = finalVerdict(
            tuneV2: v2Tune, tuneV4: selectedTune,
            validationV2: v2Validation, validationV4: selectedValidation,
            frozenV2: frozenV2, frozenV4: frozenV4
        )
        let report = V4FinalReport(
            version: configuration.version,
            generatedAt: ISO8601DateFormatter().string(from: Date()),
            manifestPath: manifestURL.path,
            configuration: configuration,
            split: splitDocument(manifest),
            transferByPair: transferByPair,
            baseline: baseline,
            shadowAudit: shadowAudit,
            sensitivity: sensitivity,
            globalCandidates: global,
            localCandidates: local,
            validationCandidates: validationCandidates,
            selectedCandidate: selected,
            freeze: finalFreeze,
            frozen: frozen,
            transferAnalysis: transferAnalysis,
            familyAnalysis: familyAnalysis,
            verdict: decision.0,
            reasons: decision.1,
            limitations: [
                "Virgin Frozen metrics were opened once only after candidate, code, manifest and objective hashes were frozen.",
                "The three Virgin Frozen pairs are a small holdout; family/transfer confidence intervals are limited.",
                "Reference HDR creative grading and SDR information loss are not recoverable detail ground truth.",
                "Runtime scene statistics use a 16x9, 16-bin causal GPU estimator; offline uses the same one-frame-late state transition."
            ]
        )
        try writeArtifacts(report)
        return report
    }

    private func validateV4Split(_ manifest: V4Manifest) throws {
        let tune = manifest.pairs.filter { $0.split == .tune }
        let validation = manifest.pairs.filter { $0.split == .validation }
        let virgin = manifest.pairs.filter { $0.split == .frozen && $0.virginFrozen }
        guard tune.count == 5, validation.count == 3, virgin.count == 3 else {
            throw CalibrationError.invalidManifest(
                String(format: "V4 expected Tune=5, Validation=3, Virgin Frozen=3; got %d, %d, %d", tune.count, validation.count, virgin.count)
            )
        }
    }

    private func splitDocument(_ manifest: V4Manifest) -> V2SplitDocument {
        V2SplitDocument(
            splitSeed: configuration.splitSeed,
            algorithm: "manifest-video-group-fixed-v4-family-balanced",
            tune: manifest.pairs.filter { $0.split == .tune }.map(\.id),
            validation: manifest.pairs.filter { $0.split == .validation }.map(\.id),
            frozen: manifest.pairs.filter { $0.split == .frozen }.map(\.id),
            frozenAccessPolicy: "Virgin Frozen objective is opened once after final candidate freeze"
        )
    }

    private func preparationConfiguration() -> V2SearchConfiguration {
        var value = V2SearchConfiguration()
        value.searchSeed = configuration.searchSeed
        value.maxFramesPerScene = configuration.maxFramesPerScene
        value.referenceTargetPeakNits = configuration.referenceTargetPeakNits
        value.weights = configuration.weights
        value.alignmentSearchThreshold = 0
        return value
    }

    private func makeLegacyRecords(_ manifest: V4Manifest) -> [PairRecord] {
        manifest.pairs.map { pair in
            let urls = pair.resolvedURLs(relativeTo: manifestURL, roots: manifest.roots)
            return PairRecord(
                id: pair.id,
                sdr: urls.sdr.path,
                hdr: urls.hdr.path,
                license: pair.license,
                source: pair.source,
                expectedRelation: .sameMaster,
                notes: pair.notes,
                split: pair.split
            )
        }
    }

    private func probeTransfers(_ manifest: V4Manifest) async throws -> [String: String] {
        var result: [String: String] = [:]
        for pair in manifest.pairs {
            let urls = pair.resolvedURLs(relativeTo: manifestURL, roots: manifest.roots)
            let metadata = try await MetadataProbe.probe(url: urls.hdr)
            result[pair.id] = metadata.color.referenceTransfer == .pq ? "PQ" :
                metadata.color.referenceTransfer == .hlg ? "HLG" : "UNKNOWN"
        }
        return result
    }

    private func parameters(_ source: HDRConfiguration, revision: HDRToneCurveRevision) -> CalibrationParameters {
        var value = CalibrationParameters(configuration: source)
        value.displayHeadroom = value.peakNits / value.paperWhiteNits
        value.toneCurveRevision = revision.rawValue
        return value
    }

    private func evaluate(
        _ engine: V2EvaluationEngine,
        _ prepared: [PreparedPair],
        _ parameters: CalibrationParameters,
        _ label: String,
        _ split: DatasetSplit,
        _ manifest: V4Manifest
    ) throws -> V2DatasetEvaluation {
        let raw = try engine.evaluate(
            preparedPairs: prepared, parameters: parameters, label: label,
            split: split, confidenceThreshold: configuration.confidenceThreshold
        )
        return familyBalanced(raw, manifest: manifest)
    }

    private func familyBalanced(_ evaluation: V2DatasetEvaluation, manifest: V4Manifest) -> V2DatasetEvaluation {
        let families = Dictionary(grouping: evaluation.videos) { video in
            manifest.pairs.first(where: { $0.id == video.pairID })?.contentFamily ?? "UNCLASSIFIED"
        }
        let familyMetrics = families.values.map { V2MetricsEvaluator.aggregate($0.map(\.metrics)) }
        var balanced = evaluation
        balanced.metrics = V2MetricsEvaluator.aggregate(familyMetrics)
        return balanced
    }

    private func sensitivitySweep(
        engine: V2EvaluationEngine,
        tune: [PreparedPair],
        center: CalibrationParameters,
        manifest: V4Manifest
    ) throws -> [V4SensitivityRecord] {
        var result: [V4SensitivityRecord] = []
        for value in [Float(0), 0.25, 0.5, 0.75, 1] {
            var parameters = center
            parameters.shadowProtection = value
            let metrics = try evaluate(engine, tune, parameters, "v4-sensitivity-shadow-(value)", .tune, manifest).metrics
            result.append(V4SensitivityRecord(
                parameter: "shadowProtection", value: value,
                objective: metrics.objective, shadowError: metrics.shadowError,
                shadowLiftRatio: metrics.shadowLiftRatio, midtoneError: metrics.midtoneError,
                highlightError: metrics.highlightError, temporalFlicker: metrics.temporalFlicker,
                highlightPumping: metrics.highlightPumping, sceneCutRecovery: metrics.sceneCutRecovery
            ))
        }
        for value in [Float(0), 0.25, 0.5, 0.75, 1] {
            var parameters = center
            parameters.temporalStability = value
            let metrics = try evaluate(engine, tune, parameters, "v4-sensitivity-temporal-(value)", .tune, manifest).metrics
            result.append(V4SensitivityRecord(
                parameter: "temporalStability", value: value,
                objective: metrics.objective, shadowError: metrics.shadowError,
                shadowLiftRatio: metrics.shadowLiftRatio, midtoneError: metrics.midtoneError,
                highlightError: metrics.highlightError, temporalFlicker: metrics.temporalFlicker,
                highlightPumping: metrics.highlightPumping, sceneCutRecovery: metrics.sceneCutRecovery
            ))
        }
        return result
    }

    private func validateSensitivity(_ values: [V4SensitivityRecord]) -> (passed: Bool, reason: String) {
        let shadows = values.filter { $0.parameter == "shadowProtection" }.sorted { $0.value < $1.value }
        let temporals = values.filter { $0.parameter == "temporalStability" }
        let shadowDelta = (shadows.map(\.shadowLiftRatio).max() ?? 0) - (shadows.map(\.shadowLiftRatio).min() ?? 0)
        let temporalDelta = (temporals.map { $0.temporalFlicker + $0.highlightPumping }.max() ?? 0) -
            (temporals.map { $0.temporalFlicker + $0.highlightPumping }.min() ?? 0)
        let monotonic = zip(shadows, shadows.dropFirst()).allSatisfy { $0.1.shadowLiftRatio <= $0.0.shadowLiftRatio + 0.01 }
        guard shadowDelta > 0.002, monotonic else {
            return (false, String(format: "scene-relative shadowProtection sensitivity is dead or non-monotonic (delta=%.6f)", shadowDelta))
        }
        guard temporalDelta > 0.00001 else {
            return (false, String(format: "temporalStability remains unidentified after causal sequential evaluation (delta=%.6f)", temporalDelta))
        }
        return (true, "scene-relative shadow and causal temporal controls are identifiable")
    }

    private func globalParameters(index: Int) -> CalibrationParameters {
        let bounds = configuration.bounds
        let ranges = [bounds.paperWhiteNits, bounds.peakNits, bounds.highlightStrength,
                      bounds.contrastStrength, bounds.saturationCompensation,
                      bounds.shadowProtection, bounds.temporalStability]
        let bases = [2, 3, 5, 7, 11, 13, 17]
        let values = ranges.enumerated().map { dimension, range in
            range.lowerBound + Float(halton(index + 1, base: bases[dimension])) * (range.upperBound - range.lowerBound)
        }
        return makeParameters(values)
    }

    private func localParameters(center: CalibrationParameters, index: Int) -> CalibrationParameters {
        let bounds = configuration.bounds
        let ranges = [bounds.paperWhiteNits, bounds.peakNits, bounds.highlightStrength,
                      bounds.contrastStrength, bounds.saturationCompensation,
                      bounds.shadowProtection, bounds.temporalStability]
        let centers = [center.paperWhiteNits, center.peakNits, center.highlightStrength,
                       center.contrastStrength, center.saturationCompensation,
                       center.shadowProtection, center.temporalStability]
        let bases = [19, 23, 29, 31, 37, 41, 43]
        let values = ranges.enumerated().map { dimension, range -> Float in
            let radius = (range.upperBound - range.lowerBound) * 0.10
            let offset = Float(halton(index + 1, base: bases[dimension]) - 0.5) * 2 * radius
            return min(max(centers[dimension] + offset, range.lowerBound), range.upperBound)
        }
        return makeParameters(values)
    }

    private func makeParameters(_ values: [Float]) -> CalibrationParameters {
        CalibrationParameters(
            paperWhiteNits: values[0], peakNits: values[1],
            highlightStrength: values[2], contrastStrength: values[3],
            saturationCompensation: values[4], shadowProtection: values[5],
            temporalStability: values[6], displayHeadroom: values[1] / values[0],
            toneCurveRevision: HDRToneCurveRevision.sceneRelativeV4.rawValue
        )
    }

    private func candidateRecord(
        id: String, stage: String, parameters: CalibrationParameters,
        tune: V2DatasetEvaluation, baseline: V2DatasetEvaluation
    ) -> V4CandidateRecord {
        var reasons: [String] = []
        let metrics = tune.metrics
        if !metrics.objective.isFinite || metrics.invalidSampleCount != 0 { reasons.append("invalid/non-finite") }
        if metrics.clippingRatio > configuration.safety.zeroTolerance { reasons.append("clipping") }
        if metrics.blackCrushRatio > configuration.safety.zeroTolerance { reasons.append("black crush") }
        if metrics.shadowError > baseline.metrics.shadowError + configuration.safety.shadowErrorTolerance { reasons.append("shadow safety") }
        if metrics.shadowLiftRatio > baseline.metrics.shadowLiftRatio + configuration.safety.shadowLiftTolerance { reasons.append("shadow lift safety") }
        if metrics.temporalFlicker > baseline.metrics.temporalFlicker * (1 + configuration.safety.temporalFlickerRelativeTolerance) + configuration.safety.temporalFlickerAbsoluteTolerance {
            reasons.append("temporal flicker")
        }
        if perVideoCatastrophic(candidate: tune, baseline: baseline) > 0 { reasons.append("catastrophic per-video regression") }
        return V4CandidateRecord(
            id: id, stage: stage, parameters: parameters, tune: tune,
            validation: nil, constraintsPassed: reasons.isEmpty, rejectionReasons: reasons
        )
    }

    private func validationRejections(_ candidate: V2DatasetEvaluation, baseline: V2DatasetEvaluation) -> [String] {
        var reasons: [String] = []
        let m = candidate.metrics
        let b = baseline.metrics
        if m.objective >= b.objective { reasons.append("Validation objective is not better than V2") }
        if m.shadowError > b.shadowError + configuration.safety.shadowErrorTolerance { reasons.append("shadow error regression") }
        if m.shadowLiftRatio > b.shadowLiftRatio + configuration.safety.shadowLiftTolerance { reasons.append("shadow lift regression") }
        if m.temporalFlicker > b.temporalFlicker * (1 + configuration.safety.temporalFlickerRelativeTolerance) + configuration.safety.temporalFlickerAbsoluteTolerance { reasons.append("temporal flicker regression") }
        if m.highlightError > b.highlightError * (1 + configuration.safety.highlightRelativeTolerance) + 0.005 { reasons.append("highlight regression") }
        if m.midtoneError > b.midtoneError * (1 + configuration.safety.midtoneRelativeTolerance) + 0.005 { reasons.append("midtone regression") }
        if m.hueP95Error > b.hueP95Error * (1 + configuration.safety.hueRelativeTolerance) + 0.002 { reasons.append("hue regression") }
        if m.clippingRatio > configuration.safety.zeroTolerance || m.blackCrushRatio > configuration.safety.zeroTolerance || m.invalidSampleCount != 0 { reasons.append("hard safety gate") }
        if perVideoCatastrophic(candidate: candidate, baseline: baseline) > 0 { reasons.append("catastrophic per-video regression") }
        return reasons
    }

    private func perVideoCatastrophic(candidate: V2DatasetEvaluation, baseline: V2DatasetEvaluation) -> Int {
        var count = 0
        for video in candidate.videos {
            guard let reference = baseline.videos.first(where: { $0.pairID == video.pairID }) else { continue }
            if video.metrics.objective > reference.metrics.objective * (1 + configuration.safety.catastrophicSceneRegression) ||
                video.metrics.shadowError > reference.metrics.shadowError * (1 + configuration.safety.catastrophicSceneRegression) + configuration.safety.shadowErrorTolerance {
                count += 1
            }
        }
        return count
    }

    private func finalVerdict(
        tuneV2: V2DatasetEvaluation, tuneV4: V2DatasetEvaluation,
        validationV2: V2DatasetEvaluation, validationV4: V2DatasetEvaluation,
        frozenV2: V2DatasetEvaluation, frozenV4: V2DatasetEvaluation
    ) -> (CalibrationV4Verdict, [String]) {
        let tuneImprovement = improvement(tuneV2.metrics.objective, tuneV4.metrics.objective)
        let validationImprovement = improvement(validationV2.metrics.objective, validationV4.metrics.objective)
        let frozenImprovement = improvement(frozenV2.metrics.objective, frozenV4.metrics.objective)
        var reasons = [
            String(format: "Tune V4 vs V2: %.2f%%", tuneImprovement),
            String(format: "Validation V4 vs V2: %.2f%%", validationImprovement),
            String(format: "Virgin Frozen V4 vs V2: %.2f%%", frozenImprovement),
            String(format: "Virgin Frozen shadow V2=%.6f V4=%.6f", frozenV2.metrics.shadowError, frozenV4.metrics.shadowError)
        ]
        guard tuneImprovement > 0, validationImprovement > 0 else {
            return (.validationFail, reasons + ["Tune/Validation improvement gate failed."])
        }
        guard frozenImprovement >= configuration.safety.frozenMinimumImprovement else {
            return (.virginFrozenFail, reasons + ["Virgin Frozen improvement is below the pre-registered 5% gate."])
        }
        guard frozenV4.metrics.shadowError <= frozenV2.metrics.shadowError + configuration.safety.shadowErrorTolerance,
              frozenV4.metrics.shadowLiftRatio <= frozenV2.metrics.shadowLiftRatio + configuration.safety.shadowLiftTolerance else {
            return (.shadowGeneralizationFail, reasons + ["Virgin Frozen shadow gate failed."])
        }
        guard frozenV4.metrics.clippingRatio <= configuration.safety.zeroTolerance,
              frozenV4.metrics.blackCrushRatio <= configuration.safety.zeroTolerance,
              frozenV4.metrics.invalidSampleCount == 0 else {
            return (.keepV2, reasons + ["Virgin Frozen hard safety gate failed."])
        }
        let perVideoRegressions = zip(
            frozenV2.videos.sorted { $0.pairID < $1.pairID },
            frozenV4.videos.sorted { $0.pairID < $1.pairID }
        ).filter { pair in
            pair.1.metrics.objective > pair.0.metrics.objective * (1 + configuration.safety.frozenPerVideoRegressionTolerance)
        }.count
        guard perVideoRegressions == 0 else {
            return (.virginFrozenFail, reasons + ["Virgin Frozen per-video regression count=" + String(perVideoRegressions)])
        }
        reasons.append("All V4 promotion gates passed; candidate is eligible for promotion.")
        return (.promote, reasons)
    }

    private func makeFailureReport(
        manifest: V4Manifest,
        transferByPair: [String: String],
        baseline: [String: V2DatasetEvaluation],
        shadowAudit: [String: V2DatasetEvaluation],
        sensitivity: [V4SensitivityRecord],
        reason: String,
        verdict: CalibrationV4Verdict,
        global: [V4CandidateRecord] = [],
        local: [V4CandidateRecord] = [],
        validation: [V4CandidateRecord] = []
    ) -> V4FinalReport {
        V4FinalReport(
            version: configuration.version,
            generatedAt: ISO8601DateFormatter().string(from: Date()),
            manifestPath: manifestURL.path,
            configuration: configuration,
            split: splitDocument(manifest),
            transferByPair: transferByPair,
            baseline: baseline,
            shadowAudit: shadowAudit,
            sensitivity: sensitivity,
            globalCandidates: global, localCandidates: local,
            validationCandidates: validation, selectedCandidate: nil,
            freeze: nil, frozen: [:], transferAnalysis: [:], familyAnalysis: [:],
            verdict: verdict, reasons: [reason], limitations: [
                "Virgin Frozen remained sealed because V4 preconditions were not satisfied."
            ]
        )
    }

    private func transferAnalysis(
        evaluations: [String: V2DatasetEvaluation], records: [PairRecord], transferByPair: [String: String]
    ) -> [String: [String: V2MetricBreakdown]] {
        var result: [String: [String: V2MetricBreakdown]] = [:]
        for (label, evaluation) in evaluations {
            var grouped: [String: [V2MetricBreakdown]] = [:]
            for video in evaluation.videos {
                grouped[transferByPair[video.pairID] ?? "UNKNOWN", default: []].append(video.metrics)
            }
            result[label] = grouped.mapValues { V2MetricsEvaluator.aggregate($0) }
        }
        _ = records
        return result
    }

    private func familyAnalysis(
        evaluations: [String: V2DatasetEvaluation], manifest: V4Manifest
    ) -> [String: [String: V2MetricBreakdown]] {
        let familyByID = Dictionary(uniqueKeysWithValues: manifest.pairs.compactMap { pair -> (String, String)? in
            guard let family = pair.contentFamily, !family.isEmpty else { return nil }
            return (pair.id, family)
        })
        return evaluations.mapValues { evaluation in
            var grouped: [String: [V2MetricBreakdown]] = [:]
            for video in evaluation.videos {
                grouped[familyByID[video.pairID] ?? "UNKNOWN", default: []].append(video.metrics)
            }
            return grouped.mapValues { V2MetricsEvaluator.aggregate($0) }
        }
    }

    private func writeArtifacts(_ report: V4FinalReport) throws {
        try writeJSON(report, name: "data-video-v4-final.json")
        let markdown = makeMarkdown(report)
        try markdown.write(to: outputDirectory.appendingPathComponent("data-video-v4-report.md"), atomically: true, encoding: .utf8)
    }

    /*
    private func makeMarkdown(_ report: V4FinalReport) -> String {
        func metric(_ key: String, _ value: V2DatasetEvaluation?) -> String {
            guard let value else { return "NOT MEASURED" }
            switch key {
            case "objective": return String(format: "%.6f", value.metrics.objective)
            case "shadow": return String(format: "%.6f", value.metrics.shadowError)
            case "shadowLift": return String(format: "%.6f", value.metrics.shadowLiftRatio)
            case "highlight": return String(format: "%.6f", value.metrics.highlightError)
            case "midtone": return String(format: "%.6f", value.metrics.midtoneError)
            default: return "NOT MEASURED"
            }
        }
        let selected = report.selectedCandidate?.parameters
        let reasons = report.reasons.map { "- ($0)" }.joined(separator: "\n")
        return """
        # SDR→HDR Calibrated V4

        Verdict: `(report.verdict.rawValue)`

        ## Protocol

        - Manifest: `(report.manifestPath)`
        - Split seed: (report.configuration.splitSeed)
        - Search seed: (report.configuration.searchSeed)
        - Global/local candidates: (report.configuration.globalCandidates)/(report.configuration.localCandidates)
        - Aggregation: video → content-family balanced mean
        - Virgin Frozen: sealed until candidate/code/objective hashes were frozen; opened once after selection.

        ## V2 vs V4

        | Split | V2 objective | V4 objective | V2 shadow | V4 shadow | V2 shadow lift | V4 shadow lift |
        |---|---:|---:|---:|---:|---:|---:|
        | Tune | (metric("objective", report.baseline["v2-tune"])) | (metric("objective", report.selectedCandidate?.tune)) | (metric("shadow", report.baseline["v2-tune"])) | (metric("shadow", report.selectedCandidate?.tune)) | (metric("shadowLift", report.baseline["v2-tune"])) | (metric("shadowLift", report.selectedCandidate?.tune)) |
        | Validation | (metric("objective", report.baseline["v2-validation"])) | (metric("objective", report.selectedCandidate?.validation)) | (metric("shadow", report.baseline["v2-validation"])) | (metric("shadow", report.selectedCandidate?.validation)) | (metric("shadowLift", report.baseline["v2-validation"])) | (metric("shadowLift", report.selectedCandidate?.validation)) |
        | Virgin Frozen | (metric("objective", report.frozen["calibratedV2"])) | (metric("objective", report.frozen["calibratedV4"])) | (metric("shadow", report.frozen["calibratedV2"])) | (metric("shadow", report.frozen["calibratedV4"])) | (metric("shadowLift", report.frozen["calibratedV2"])) | (metric("shadowLift", report.frozen["calibratedV4"])) |

        ## Selected parameters

        (selected.map { "`\(String(describing: $0))`" } ?? "NOT SELECTED")

        ## Decision

        (reasons)

        ## Limitations

        (report.limitations.map { "- ($0)" }.joined(separator: "\n"))
        """
    }

    */

    private func makeMarkdown(_ report: V4FinalReport) -> String {
        func metric(_ key: String, _ value: V2DatasetEvaluation?) -> String {
            guard let value else { return "NOT MEASURED" }
            switch key {
            case "objective": return String(format: "%.6f", value.metrics.objective)
            case "shadow": return String(format: "%.6f", value.metrics.shadowError)
            case "shadowLift": return String(format: "%.6f", value.metrics.shadowLiftRatio)
            case "highlight": return String(format: "%.6f", value.metrics.highlightError)
            case "midtone": return String(format: "%.6f", value.metrics.midtoneError)
            default: return "NOT MEASURED"
            }
        }
        let selected = report.selectedCandidate.map { String(describing: $0.parameters) } ?? "NOT SELECTED"
        let reasons = report.reasons.map { "- " + $0 }.joined(separator: "\n")
        let limitations = report.limitations.map { "- " + $0 }.joined(separator: "\n")
        let lines = [
            "# SDR to HDR Calibrated V4",
            "",
            "Verdict: " + report.verdict.rawValue,
            "",
            "## Protocol",
            "",
            "- Manifest: " + report.manifestPath,
            "- Split seed: " + String(report.configuration.splitSeed),
            "- Search seed: " + String(report.configuration.searchSeed),
            "- Global/local candidates: " + String(report.configuration.globalCandidates) + "/" + String(report.configuration.localCandidates),
            "- Aggregation: video to content-family balanced mean",
            "- Virgin Frozen: sealed until candidate, code, manifest and objective hashes were frozen; opened once after selection.",
            "",
            "## V2 vs V4",
            "",
            "| Split | V2 objective | V4 objective | V2 shadow | V4 shadow | V2 shadow lift | V4 shadow lift |",
            "|---|---:|---:|---:|---:|---:|---:|",
            "| Tune | " + metric("objective", report.baseline["v2-tune"]) + " | " + metric("objective", report.selectedCandidate?.tune) + " | " + metric("shadow", report.baseline["v2-tune"]) + " | " + metric("shadow", report.selectedCandidate?.tune) + " | " + metric("shadowLift", report.baseline["v2-tune"]) + " | " + metric("shadowLift", report.selectedCandidate?.tune) + " |",
            "| Validation | " + metric("objective", report.baseline["v2-validation"]) + " | " + metric("objective", report.selectedCandidate?.validation) + " | " + metric("shadow", report.baseline["v2-validation"]) + " | " + metric("shadow", report.selectedCandidate?.validation) + " | " + metric("shadowLift", report.baseline["v2-validation"]) + " | " + metric("shadowLift", report.selectedCandidate?.validation) + " |",
            "| Virgin Frozen | " + metric("objective", report.frozen["calibratedV2"]) + " | " + metric("objective", report.frozen["calibratedV4"]) + " | " + metric("shadow", report.frozen["calibratedV2"]) + " | " + metric("shadow", report.frozen["calibratedV4"]) + " | " + metric("shadowLift", report.frozen["calibratedV2"]) + " | " + metric("shadowLift", report.frozen["calibratedV4"]) + " |",
            "",
            "## Selected parameters",
            "",
            selected,
            "",
            "## Decision",
            "",
            reasons,
            "",
            "## Limitations",
            "",
            limitations
        ]
        return lines.joined(separator: "\n")
    }

    private func writeJSON<T: Encodable>(_ value: T, name: String) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "Infinity", negativeInfinity: "-Infinity", nan: "NaN")
        try encoder.encode(value).write(to: outputDirectory.appendingPathComponent(name))
    }

    private func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "Infinity", negativeInfinity: "-Infinity", nan: "NaN")
        return try encoder.encode(value)
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func sourceCodeHash() -> String {
        let paths = [
            "Sources/HDRCore/HDRConfiguration.swift", "Sources/HDRCore/HDRReference.swift",
            "Sources/HDRCore/HDRProcessor.swift", "Sources/HDRCore/MetalContext.swift",
            "Sources/HDRCore/Shaders/SDRToHDR.metal", "Sources/HDRCalibration/Decode.swift",
            "Sources/HDRCalibration/V2Runner.swift", "Sources/HDRCalibration/V4Calibration.swift"
        ]
        var data = Data()
        for path in paths {
            let url = URL(fileURLWithPath: path, relativeTo: manifestURL.deletingLastPathComponent())
            data.append(Data(path.utf8))
            data.append((try? Data(contentsOf: url)) ?? Data())
        }
        return sha256(data)
    }

    private func halton(_ index: Int, base: Int) -> Double {
        var result = 0.0
        var fraction = 1.0
        var value = index
        while value > 0 {
            fraction /= Double(base)
            result += fraction * Double(value % base)
            value /= base
        }
        return result
    }

    private func improvement(_ baseline: Double, _ candidate: Double) -> Double {
        (baseline - candidate) / max(baseline, 0.000000001) * 100
    }

    private func log(_ message: String) {
        FileHandle.standardError.write(Data(("[HDRCalibrate V4] " + message + "\n").utf8))
    }
}
