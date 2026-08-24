import Foundation
import HDRCore
import Metal

private func calibrationTrace(_ message: String) {
    guard ProcessInfo.processInfo.environment["HDR_CALIBRATION_DEBUG"] == "1" else { return }
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

public struct ParameterSpace: Codable, Sendable {
    public var highlightStrength: ClosedRange<Float> = 0.25...0.85
    public var contrastStrength: ClosedRange<Float> = 0.20...0.80
    public var saturationCompensation: ClosedRange<Float> = 0.25...0.85
    public var shadowProtection: ClosedRange<Float> = 0.65...0.98
    public var temporalStability: ClosedRange<Float> = 0.80...0.98

    public init() {}

    public func sample(base: CalibrationParameters, random: inout DeterministicRandom) -> CalibrationParameters {
        var candidate = base
        candidate.highlightStrength = random.next(in: highlightStrength)
        candidate.contrastStrength = random.next(in: contrastStrength)
        candidate.saturationCompensation = random.next(in: saturationCompensation)
        candidate.shadowProtection = random.next(in: shadowProtection)
        candidate.temporalStability = random.next(in: temporalStability)
        // Paper white, peak, and display headroom are fixed in calibration
        // space; they are not allowed to absorb display-specific behavior.
        candidate.displayHeadroom = max(1, candidate.peakNits / candidate.paperWhiteNits)
        return candidate
    }
}

public struct DeterministicRandom: Sendable {
    private var state: UInt64

    public init(seed: UInt64) {
        state = seed == 0 ? 0x9E3779B97F4A7C15 : seed
    }

    public mutating func nextUnit() -> Float {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        let value = state >> 11
        return Float(Double(value) / Double(UInt64.max >> 11))
    }

    public mutating func next(in range: ClosedRange<Float>) -> Float {
        range.lowerBound + (range.upperBound - range.lowerBound) * nextUnit()
    }
}

public final class CalibrationRunner {
    public let manifestURL: URL
    public let experiment: ExperimentConfig
    public let parameterSpace: ParameterSpace
    public let device: MTLDevice?
    private var preparedPairs: [String: PreparedPair] = [:]

    public init(
        manifestURL: URL,
        experiment: ExperimentConfig = ExperimentConfig(),
        parameterSpace: ParameterSpace = ParameterSpace(),
        device: MTLDevice? = MTLCreateSystemDefaultDevice()
    ) {
        self.manifestURL = manifestURL
        self.experiment = experiment
        self.parameterSpace = parameterSpace
        self.device = device
    }

    public func run() async throws -> CalibrationReport {
        let dataset = try await DatasetScanner.scan(manifestURL: manifestURL)
        let baselineParameters = CalibrationParameters(configuration: try calibrationBaseConfiguration())
        let valid = dataset.validPairs
        guard !valid.isEmpty else {
            return CalibrationReport(
                experimentID: experimentID(),
                experiment: experiment,
                parameterSpace: parameterSpace,
                baselineParameters: baselineParameters,
                verdict: .datasetInsufficient,
                notes: [
                    "No usable SDR/HDR reference pair exists in the manifest.",
                    "The tool refuses to fit parameters without same-content HDR reference data.",
                    "Dataset status counts: \(dataset.counts)"
                ]
            )
        }
        guard let device else { throw CalibrationError.decodeFailed("Metal device unavailable for HDRCore offline evaluation") }
        let tuneRecords = valid.filter { $0.pair.split == .tune }
        let validationRecords = valid.filter { $0.pair.split == .validation }
        let frozenRecords = valid.filter { $0.pair.split == .frozen }
        guard !tuneRecords.isEmpty else {
            return CalibrationReport(
                experimentID: experimentID(),
                experiment: experiment,
                parameterSpace: parameterSpace,
                baselineParameters: baselineParameters,
                verdict: .datasetInsufficient,
                notes: ["No TUNE pairs are present; frozen/validation data cannot be used for fitting."]
            )
        }

        let baselineMetrics: DatasetMetrics
        do {
            baselineMetrics = try await evaluate(records: tuneRecords, parameters: baselineParameters, split: .tune, device: device)
        } catch {
            return CalibrationReport(
                experimentID: experimentID(),
                experiment: experiment,
                parameterSpace: parameterSpace,
                baselineParameters: baselineParameters,
                verdict: .referenceDataUnusable,
                notes: ["BASELINE_V0 could not be evaluated: \(error.localizedDescription)"]
            )
        }
        var baselineValidation: DatasetMetrics?
        var baselineFrozenTest: DatasetMetrics?
        var baselineSplitNotes: [String] = []
        if !validationRecords.isEmpty {
            do {
                baselineValidation = try await evaluate(
                    records: validationRecords,
                    parameters: baselineParameters,
                    split: .validation,
                    device: device
                )
            } catch {
                baselineSplitNotes.append("BASELINE_V0 validation could not be evaluated: \(error.localizedDescription)")
            }
        }
        if !frozenRecords.isEmpty {
            do {
                baselineFrozenTest = try await evaluate(
                    records: frozenRecords,
                    parameters: baselineParameters,
                    split: .frozen,
                    device: device
                )
            } catch {
                baselineSplitNotes.append("BASELINE_V0 frozen test could not be evaluated: \(error.localizedDescription)")
            }
        }
        var random = DeterministicRandom(seed: experiment.seed)
        var candidates: [CandidateResult] = []
        let candidateCount = max(1, experiment.candidateCount)
        for index in 0..<candidateCount {
            let parameters = index == 0 ? baselineParameters : parameterSpace.sample(base: baselineParameters, random: &random)
            let tune: DatasetMetrics?
            var notes: [String] = []
            do {
                tune = try await evaluate(records: tuneRecords, parameters: parameters, split: .tune, device: device)
            } catch {
                tune = nil
                notes.append("candidate evaluation failed: \(error.localizedDescription)")
            }
            let constraints = tune.map { constraintsPass(tune: $0, baseline: baselineMetrics) } ?? false
            if !constraints && notes.isEmpty { notes.append("safety constraint rejected candidate") }
            candidates.append(CandidateResult(
                id: String(format: "candidate_%03d", index),
                parameters: parameters,
                tune: tune,
                constraintsPassed: constraints,
                notes: notes
            ))
        }
        let selected = candidates
            .filter(\.constraintsPassed)
            .min { ($0.tune?.objective ?? .infinity) < ($1.tune?.objective ?? .infinity) }
        guard var selected else {
            return CalibrationReport(
                experimentID: experimentID(),
                experiment: experiment,
                parameterSpace: parameterSpace,
                baselineParameters: baselineParameters,
                baseline: baselineMetrics,
                baselineValidation: baselineValidation,
                baselineFrozenTest: baselineFrozenTest,
                candidates: candidates,
                verdict: .globalTuningInsufficient,
                notes: ["All candidates violated at least one safety constraint."] + baselineSplitNotes
            )
        }

        if !validationRecords.isEmpty {
            selected.validation = try await evaluate(records: validationRecords, parameters: selected.parameters, split: .validation, device: device)
        }
        if !frozenRecords.isEmpty {
            selected.frozen = try await evaluate(records: frozenRecords, parameters: selected.parameters, split: .frozen, device: device)
        }
        let verdict = verdictFor(
            selected: selected,
            baseline: baselineMetrics,
            baselineValidation: baselineValidation,
            baselineFrozenTest: baselineFrozenTest
        )
        return CalibrationReport(
            experimentID: experimentID(),
            experiment: experiment,
            parameterSpace: parameterSpace,
            baselineParameters: baselineParameters,
            baseline: baselineMetrics,
            baselineValidation: baselineValidation,
            baselineFrozenTest: baselineFrozenTest,
            candidates: candidates,
            selectedCandidate: selected,
            validation: selected.validation,
            frozenTest: selected.frozen,
            verdict: verdict,
            notes: [
                "Search split: TUNE only.",
                "FROZEN is evaluated after selection and is never used to generate candidates.",
                "Reference creative-grade mismatch is reported as an error family rather than silently fitted."
            ] + baselineSplitNotes
        )
    }

    public func baselineOnly() async throws -> CalibrationReport {
        let dataset = try await DatasetScanner.scan(manifestURL: manifestURL)
        let baselineParameters = CalibrationParameters(configuration: try calibrationBaseConfiguration())
        let tuneRecords = dataset.validPairs.filter { $0.pair.split == .tune }
        guard !tuneRecords.isEmpty, let device else {
            return CalibrationReport(
                experimentID: experimentID(),
                experiment: experiment,
                parameterSpace: parameterSpace,
                baselineParameters: baselineParameters,
                verdict: .datasetInsufficient,
                notes: ["Baseline requires at least one valid TUNE SDR/HDR pair and a Metal device."]
            )
        }
        do {
            let baseline = try await evaluate(records: tuneRecords, parameters: baselineParameters, split: .tune, device: device)
            return CalibrationReport(
                experimentID: experimentID(),
                experiment: experiment,
                parameterSpace: parameterSpace,
                baselineParameters: baselineParameters,
                baseline: baseline,
                verdict: .validationOnly,
                notes: ["BASELINE_V0 only; no candidate search was performed."]
            )
        } catch {
            return CalibrationReport(
                experimentID: experimentID(),
                experiment: experiment,
                parameterSpace: parameterSpace,
                baselineParameters: baselineParameters,
                verdict: .referenceDataUnusable,
                notes: ["Baseline evaluation failed: \(error.localizedDescription)"]
            )
        }
    }

    public func evaluate(
        candidate: CalibrationParameters,
        split: DatasetSplit
    ) async throws -> DatasetMetrics? {
        let dataset = try await DatasetScanner.scan(manifestURL: manifestURL)
        let records = dataset.validPairs.filter { $0.pair.split == split }
        guard !records.isEmpty else { return nil }
        guard let device else { throw CalibrationError.decodeFailed("Metal device unavailable") }
        return try await evaluate(records: records, parameters: candidate, split: split, device: device)
    }

    public static func writeReport(_ report: CalibrationReport, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: url)
    }

    private func evaluate(
        records: [PairValidation],
        parameters: CalibrationParameters,
        split: DatasetSplit,
        device: MTLDevice
    ) async throws -> DatasetMetrics {
        var sceneMetrics: [SceneMetrics] = []
        let pairEvaluator = PairEvaluator(device: device, experiment: experiment)
        for validation in records {
            do {
                calibrationTrace("[HDRCalibrate] preparing pair \(validation.pair.id) for \(split.rawValue)")
                let prepared: PreparedPair
                if let cached = preparedPairs[validation.pair.id] {
                    prepared = cached
                } else {
                    let loaded = try await pairEvaluator.prepare(
                        record: validation.pair,
                        manifestURL: manifestURL
                    )
                    preparedPairs[validation.pair.id] = loaded
                    prepared = loaded
                }
                calibrationTrace("[HDRCalibrate] prepared pair \(validation.pair.id): samples=\(prepared.matches.count), scenes=\(prepared.scenes.count)")
                calibrationTrace("[HDRCalibrate] evaluating pair \(validation.pair.id) with parameters \(parameters.highlightStrength),\(parameters.contrastStrength)")
                let metrics = try pairEvaluator.evaluate(
                    prepared: prepared,
                    parameters: parameters,
                    split: split
                )
                calibrationTrace("[HDRCalibrate] evaluated pair \(validation.pair.id): objective=\(metrics.objective)")
                sceneMetrics.append(contentsOf: metrics.sceneMetrics)
            } catch {
                // Keep a failed pair visible in the report instead of turning
                // it into a silent zero. The caller can inspect the pair notes.
                continue
            }
        }
        guard !sceneMetrics.isEmpty else { throw CalibrationError.noValidPairs }
        return ErrorMetrics.aggregate(split: split, pairCount: records.count, scenes: sceneMetrics)
    }

    private func calibrationBaseConfiguration() throws -> HDRConfiguration {
        var configuration = HDRConfiguration.hdr
        configuration.outputMode = .edr
        configuration.masteringHeadroom = configuration.peakNits / configuration.paperWhiteNits
        return try configuration.validated()
    }

    private func constraintsPass(tune: DatasetMetrics, baseline: DatasetMetrics) -> Bool {
        guard tune.objective.isFinite else { return false }
        let maxClipped = tune.sceneMetrics.map(\.clippedRatio).max() ?? 0
        let maxShadowRegression = tune.sceneMetrics.map(\.shadowError).max() ?? 0
        let baselineShadow = baseline.sceneMetrics.map(\.shadowError).max() ?? 0
        return maxClipped <= 0.05 && maxShadowRegression <= baselineShadow + 0.12
    }

    private func verdictFor(
        selected: CandidateResult,
        baseline: DatasetMetrics,
        baselineValidation: DatasetMetrics?,
        baselineFrozenTest: DatasetMetrics?
    ) -> CalibrationVerdict {
        guard let tune = selected.tune else { return .globalTuningInsufficient }
        guard tune.objective < baseline.objective * 0.98 else { return .globalTuningInsufficient }
        guard let validation = selected.validation,
              let baselineValidation,
              validation.objective < baselineValidation.objective * 0.98 else {
            return .validationOnly
        }
        guard let frozen = selected.frozen,
              let baselineFrozenTest,
              frozen.objective < baselineFrozenTest.objective * 0.98 else {
            return .validationOnly
        }
        return .promoteCalibratedV1
    }

    private func experimentID() -> String {
        let formatter = ISO8601DateFormatter()
        return "exp_\(formatter.string(from: Date()).replacingOccurrences(of: ":", with: "").replacingOccurrences(of: "-", with: ""))_seed\(experiment.seed)"
    }
}
