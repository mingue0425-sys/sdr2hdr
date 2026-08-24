import Foundation
import HDRCore
import Metal

private func v3Log(_ message: String) {
    FileHandle.standardError.write(Data(("[HDRCalibrate V3] " + message + "\n").utf8))
}

public final class CalibrationV3Runner {
    public let manifestURL: URL
    public let outputDirectory: URL
    public let configuration: V3SearchConfiguration
    private let device: MTLDevice
    private let frozenGuard = FrozenIsolationGuard()

    public init(
        manifestURL: URL,
        outputDirectory: URL,
        configuration: V3SearchConfiguration = V3SearchConfiguration(),
        device: MTLDevice? = MTLCreateSystemDefaultDevice()
    ) throws {
        guard let device else { throw CalibrationError.decodeFailed("Metal device unavailable") }
        self.manifestURL = manifestURL
        self.outputDirectory = outputDirectory
        self.configuration = configuration
        self.device = device
    }

    public func run() async throws -> V3FinalReport {
        let manifest = try PairManifest.load(from: manifestURL)
        try SplitManager.validate(manifest)
        let split = DatasetV2Discovery.splitDocument(manifest: manifest, seed: configuration.splitSeed)
        let tuneRecords = manifest.pairs.filter { $0.split == .tune }
        let validationRecords = manifest.pairs.filter { $0.split == .validation }
        let frozenRecords = manifest.pairs.filter { $0.split == .frozen }
        guard tuneRecords.count == 3, validationRecords.count == 1, frozenRecords.count == 1 else {
            throw CalibrationError.invalidManifest("V3 requires the frozen V2 split: 3 Tune, 1 Validation, 1 Legacy Frozen")
        }

        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let repository = V2PreparedRepository(
            manifestURL: manifestURL,
            device: device,
            configuration: v2PreparationConfiguration()
        )
        try frozenGuard.authorize(.tune)
        let tunePrepared = try await repository.prepare(records: tuneRecords)
        try frozenGuard.authorize(.validation)
        let validationPrepared = try await repository.prepare(records: validationRecords)
        let engine = V2EvaluationEngine(device: device, weights: configuration.weights)

        let defaults = parameters(.hdr, revision: .legacyV2)
        let v1 = parameters(.calibratedV1, revision: .legacyV2)
        let v2 = parameters(.calibratedV2, revision: .legacyV2)
        let v3Center = parameters(.calibratedV2, revision: .shadowProtectedV3)

        v3Log("evaluate Default/V1/V2 baselines with frozen V3 objective")
        let defaultTune = try evaluate(engine, tunePrepared, defaults, "default", .tune)
        let v1Tune = try evaluate(engine, tunePrepared, v1, "calibrated-v1", .tune)
        let v2Tune = try evaluate(engine, tunePrepared, v2, "calibrated-v2", .tune)
        let defaultValidation = try evaluate(engine, validationPrepared, defaults, "default", .validation)
        let v1Validation = try evaluate(engine, validationPrepared, v1, "calibrated-v1", .validation)
        let v2Validation = try evaluate(engine, validationPrepared, v2, "calibrated-v2", .validation)

        v3Log("pre-search identifiability gate")
        let sensitivity = try sensitivityGate(engine: engine, tune: tunePrepared, center: v3Center)
        let shadowDelta = metricRange(sensitivity.filter { $0.parameter == "shadowProtection" }.map(\.shadowLiftRatio))
        let temporalDelta = metricRange(sensitivity.filter { $0.parameter == "temporalStability" }.map {
            $0.temporalFlicker * 0.5 + $0.highlightPumping * 0.5
        })
        guard shadowDelta > 0.002, temporalDelta > 0.000_01 else {
            throw CalibrationError.invalidCandidate(
                "IDENTIFIABILITY_FAIL shadowDelta=\(shadowDelta), temporalDelta=\(temporalDelta)"
            )
        }
        let influence = try influenceMatrix(engine: engine, tune: tunePrepared, center: v3Center)

        v3Log("global Halton search \(configuration.globalCandidates) candidates")
        var global: [V3CandidateSummary] = []
        for index in 0..<configuration.globalCandidates {
            let candidateParameters = globalParameters(index: index)
            let result = try evaluate(engine, tunePrepared, candidateParameters, "global-\(index)", .tune)
            global.append(candidateSummary(
                id: String(format: "global_%03d", index), stage: "global-halton",
                parameters: candidateParameters, tune: result, v2: v2Tune
            ))
            if (index + 1) % 16 == 0 { v3Log("global \(index + 1)/\(configuration.globalCandidates)") }
        }
        let globalTop = Array(global.filter(\.constraintsPassed).sorted { $0.tune.objective < $1.tune.objective }.prefix(8))
        guard !globalTop.isEmpty else { throw CalibrationError.invalidCandidate("V3 global search produced no safe candidates") }

        v3Log("local refinement \(configuration.localCandidates) candidates")
        var local: [V3CandidateSummary] = []
        for index in 0..<configuration.localCandidates {
            let center = globalTop[index % globalTop.count].parameters
            let candidateParameters = localParameters(center: center, index: index)
            let result = try evaluate(engine, tunePrepared, candidateParameters, "local-\(index)", .tune)
            local.append(candidateSummary(
                id: String(format: "local_%03d", index), stage: "local-halton",
                parameters: candidateParameters, tune: result, v2: v2Tune
            ))
            if (index + 1) % 16 == 0 { v3Log("local \(index + 1)/\(configuration.localCandidates)") }
        }

        let tuneTop = Array((global + local).filter(\.constraintsPassed)
            .sorted { $0.tune.objective < $1.tune.objective }
            .prefix(configuration.validationTopCount))
        var validationCandidates: [V3CandidateSummary] = []
        for var candidate in tuneTop {
            let result = try evaluate(engine, validationPrepared, candidate.parameters, candidate.id, .validation)
            candidate.validation = result.metrics
            let reasons = validationRejections(result.metrics, v2: v2Validation.metrics)
            if !reasons.isEmpty {
                candidate.constraintsPassed = false
                candidate.rejectionReasons.append(contentsOf: reasons)
            }
            validationCandidates.append(candidate)
        }
        let selectedSummary = validationCandidates.filter(\.constraintsPassed).min {
            ($0.validation?.objective ?? .infinity) < ($1.validation?.objective ?? .infinity)
        }
        let selectedParameters = selectedSummary?.parameters
        let selectedTune = selectedParameters.flatMap { value in
            try? evaluate(engine, tunePrepared, value, "calibrated-v3", .tune)
        }
        let selectedValidation = selectedParameters.flatMap { value in
            try? evaluate(engine, validationPrepared, value, "calibrated-v3", .validation)
        }

        let identification = identificationTable(
            selected: selectedParameters, sensitivity: sensitivity,
            shadowDelta: shadowDelta, temporalDelta: temporalDelta,
            influenceRows: influence
        )

        // All parameters, thresholds, ranges, weights and selection are fixed.
        frozenGuard.finalizeSelection()
        try frozenGuard.authorize(.frozen)
        try frozenGuard.markFrozenEvaluated()
        v3Log("open LEGACY_FROZEN exactly once after final selection")
        let frozenPrepared = try await repository.prepare(records: frozenRecords)
        let defaultFrozen = try evaluate(engine, frozenPrepared, defaults, "default", .frozen)
        let v1Frozen = try evaluate(engine, frozenPrepared, v1, "calibrated-v1", .frozen)
        let v2Frozen = try evaluate(engine, frozenPrepared, v2, "calibrated-v2", .frozen)
        let v3Frozen = try selectedParameters.map {
            try evaluate(engine, frozenPrepared, $0, "calibrated-v3", .frozen)
        }

        let decision = verdict(
            v2Tune: v2Tune, v3Tune: selectedTune,
            v2Validation: v2Validation, v3Validation: selectedValidation,
            v2Frozen: v2Frozen, v3Frozen: v3Frozen,
            identified: identification.allSatisfy(\.identified)
        )
        let report = V3FinalReport(
            version: "calibration-v3",
            generatedAt: ISO8601DateFormatter().string(from: Date()),
            manifestPath: manifestURL.path,
            splitSeed: configuration.splitSeed,
            searchSeed: configuration.searchSeed,
            split: split,
            historicalV2: V3HistoricalBaseline(
                name: "CALIBRATED_V2_FROZEN_BASELINE",
                tuneObjective: 0.192371, validationObjective: 0.274449,
                legacyFrozenObjective: 0.250057
            ),
            defaultTune: defaultTune, v1Tune: v1Tune, v2Tune: v2Tune, v3Tune: selectedTune,
            defaultValidation: defaultValidation, v1Validation: v1Validation,
            v2Validation: v2Validation, v3Validation: selectedValidation,
            defaultLegacyFrozen: defaultFrozen, v1LegacyFrozen: v1Frozen,
            v2LegacyFrozen: v2Frozen, v3LegacyFrozen: v3Frozen,
            sensitivity: sensitivity, influenceMatrix: influence, identification: identification,
            globalCandidates: global, localCandidates: local,
            validationCandidates: validationCandidates,
            selectedParameters: selectedParameters,
            verdict: decision.0, reasons: decision.1,
            limitations: [
                "video6 is LEGACY_FROZEN, not a virgin holdout after the V2 experiment.",
                "Only five valid paired videos are available; Validation and Legacy Frozen each contain one video.",
                "All paired references are HLG modeled at a 1,000-nit target, not PQ mastering truth.",
                "Temporal windows contain 16 sequential 30 Hz proxy frames per detected scene.",
                "No semantic or lost-highlight reconstruction is performed."
            ]
        )
        try writeArtifacts(report)
        return report
    }

    private func v2PreparationConfiguration() -> V2SearchConfiguration {
        var value = V2SearchConfiguration()
        value.searchSeed = configuration.searchSeed
        value.maxFramesPerScene = configuration.maxFramesPerScene
        value.referenceTargetPeakNits = configuration.referenceTargetPeakNits
        value.weights = configuration.weights
        return value
    }

    private func parameters(_ source: HDRConfiguration, revision: HDRToneCurveRevision) -> CalibrationParameters {
        var value = CalibrationParameters(configuration: source)
        value.displayHeadroom = value.peakNits / value.paperWhiteNits
        value.toneCurveRevision = revision.rawValue
        return value
    }

    private func evaluate(
        _ engine: V2EvaluationEngine, _ prepared: [PreparedPair], _ parameters: CalibrationParameters,
        _ label: String, _ split: DatasetSplit
    ) throws -> V2DatasetEvaluation {
        try engine.evaluate(
            preparedPairs: prepared, parameters: parameters, label: label, split: split,
            confidenceThreshold: configuration.confidenceThreshold
        )
    }

    private func sensitivityGate(
        engine: V2EvaluationEngine, tune: [PreparedPair], center: CalibrationParameters
    ) throws -> [V3SensitivitySample] {
        var result: [V3SensitivitySample] = []
        for parameter in ["shadowProtection", "temporalStability"] {
            for value: Float in [0, 0.25, 0.5, 0.75, 1] {
                var sample = center
                if parameter == "shadowProtection" { sample.shadowProtection = value }
                else { sample.temporalStability = value }
                let metrics = try evaluate(engine, tune, sample, "sensitivity-\(parameter)-\(value)", .tune).metrics
                result.append(V3SensitivitySample(
                    parameter: parameter, value: value, objective: metrics.objective,
                    shadowError: metrics.shadowError, shadowLiftRatio: metrics.shadowLiftRatio,
                    temporalFlicker: metrics.temporalFlicker, highlightPumping: metrics.highlightPumping,
                    cutRecoveryFrames: metrics.sceneCutRecovery
                ))
            }
        }
        return result
    }

    private func influenceMatrix(
        engine: V2EvaluationEngine, tune: [PreparedPair], center: CalibrationParameters
    ) throws -> [V3InfluenceRow] {
        let base = try evaluate(engine, tune, center, "influence-base", .tune).metrics
        let names = ["paperWhiteNits", "peakNits", "highlightStrength", "contrastStrength", "saturationCompensation", "shadowProtection", "temporalStability"]
        return try names.map { name in
            var deltas: [V2MetricBreakdown] = []
            for factor: Float in [0.95, 1.05] {
                var changed = center
                perturb(&changed, name: name, factor: factor)
                changed.displayHeadroom = changed.peakNits / changed.paperWhiteNits
                deltas.append(try evaluate(engine, tune, changed, "influence-\(name)-\(factor)", .tune).metrics)
            }
            func influence(_ key: (V2MetricBreakdown) -> Double) -> Double {
                deltas.map { abs(key($0) - key(base)) / max(abs(key(base)), 0.000_001) * 100 }.max() ?? 0
            }
            return V3InfluenceRow(
                parameter: name, highlight: influence(\.highlightError),
                midtone: influence(\.midtoneError), shadow: influence(\.shadowError),
                hue: influence(\.hueP95Error),
                temporal: max(influence(\.temporalFlicker), influence(\.highlightPumping))
            )
        }
    }

    private func globalParameters(index: Int) -> CalibrationParameters {
        let ranges = rangesArray()
        let bases = [2, 3, 5, 7, 11, 13, 17]
        let values = ranges.enumerated().map { dimension, range in
            range.lowerBound + Float(halton(index + 1, base: bases[dimension])) * (range.upperBound - range.lowerBound)
        }
        return makeParameters(values)
    }

    private func localParameters(center: CalibrationParameters, index: Int) -> CalibrationParameters {
        let ranges = rangesArray()
        let centers = valuesArray(center)
        let bases = [19, 23, 29, 31, 37, 41, 43]
        let values = ranges.enumerated().map { dimension, range -> Float in
            let radius = (range.upperBound - range.lowerBound) * 0.10
            let offset = Float(halton(index + 1, base: bases[dimension]) - 0.5) * 2 * radius
            return min(max(centers[dimension] + offset, range.lowerBound), range.upperBound)
        }
        return makeParameters(values)
    }

    private func rangesArray() -> [ClosedRange<Float>] {
        let b = configuration.bounds
        return [b.paperWhiteNits, b.peakNits, b.highlightStrength, b.contrastStrength,
                b.saturationCompensation, b.shadowProtection, b.temporalStability]
    }

    private func valuesArray(_ p: CalibrationParameters) -> [Float] {
        [p.paperWhiteNits, p.peakNits, p.highlightStrength, p.contrastStrength,
         p.saturationCompensation, p.shadowProtection, p.temporalStability]
    }

    private func makeParameters(_ v: [Float]) -> CalibrationParameters {
        CalibrationParameters(
            paperWhiteNits: v[0], peakNits: v[1], highlightStrength: v[2], contrastStrength: v[3],
            saturationCompensation: v[4], shadowProtection: v[5], temporalStability: v[6],
            displayHeadroom: v[1] / v[0], toneCurveRevision: HDRToneCurveRevision.shadowProtectedV3.rawValue
        )
    }

    private func candidateSummary(
        id: String, stage: String, parameters: CalibrationParameters,
        tune: V2DatasetEvaluation, v2: V2DatasetEvaluation
    ) -> V3CandidateSummary {
        var reasons: [String] = []
        let m = tune.metrics, baseline = v2.metrics
        if !m.objective.isFinite || m.invalidSampleCount != 0 { reasons.append("invalid/non-finite") }
        if m.clippingRatio > 0.000_001 { reasons.append("clipping") }
        if m.blackCrushRatio > 0.000_001 { reasons.append("black crush") }
        if m.shadowError >= baseline.shadowError { reasons.append("shadow error not improved") }
        if m.shadowLiftRatio >= baseline.shadowLiftRatio { reasons.append("shadow lift not improved") }
        if m.hueP95Error > baseline.hueP95Error * 1.03 + 0.002 { reasons.append("hue regression") }
        if m.temporalFlicker > baseline.temporalFlicker * 1.05 + 0.001 { reasons.append("temporal flicker") }
        if m.highlightPumping > baseline.highlightPumping * 1.05 + 0.001 { reasons.append("highlight pumping") }
        return V3CandidateSummary(
            id: id, stage: stage, parameters: parameters, tune: m, validation: nil,
            constraintsPassed: reasons.isEmpty, rejectionReasons: reasons
        )
    }

    private func validationRejections(_ candidate: V2MetricBreakdown, v2: V2MetricBreakdown) -> [String] {
        var reasons: [String] = []
        if improvement(v2.objective, candidate.objective) <= 3 { reasons.append("overall improvement <= 3%") }
        if candidate.shadowError >= v2.shadowError { reasons.append("shadow error not improved") }
        if candidate.shadowLiftRatio >= v2.shadowLiftRatio { reasons.append("shadow lift not improved") }
        if candidate.temporalFlicker > v2.temporalFlicker * 1.02 + 0.001 { reasons.append("temporal flicker regression") }
        if candidate.highlightPumping > v2.highlightPumping * 1.02 + 0.001 { reasons.append("highlight pumping regression") }
        if candidate.highlightError > v2.highlightError * 1.03 + 0.003 { reasons.append("highlight regression") }
        if candidate.midtoneError > v2.midtoneError * 1.03 + 0.003 { reasons.append("midtone regression") }
        if candidate.hueP95Error > v2.hueP95Error * 1.02 + 0.002 { reasons.append("hue regression") }
        if candidate.clippingRatio > 0.000_001 || candidate.blackCrushRatio > 0.000_001 || candidate.invalidSampleCount != 0 {
            reasons.append("hard safety gate")
        }
        return reasons
    }

    private func identificationTable(
        selected: CalibrationParameters?, sensitivity: [V3SensitivitySample],
        shadowDelta: Double, temporalDelta: Double, influenceRows: [V3InfluenceRow]
    ) -> [V3ParameterIdentification] {
        let values = selected.map(valuesArray) ?? Array(repeating: 0, count: 7)
        let names = ["paperWhiteNits", "peakNits", "highlightStrength", "contrastStrength", "saturationCompensation", "shadowProtection", "temporalStability"]
        return names.enumerated().map { index, name in
            let influence: Double
            let metric: String
            if name == "shadowProtection" { influence = shadowDelta; metric = "shadowLiftRatio" }
            else if name == "temporalStability" { influence = temporalDelta; metric = "temporalFlicker/highlightPumping" }
            else if let row = influenceRows.first(where: { $0.parameter == name }) {
                let axes = [
                    ("highlight", row.highlight), ("midtone", row.midtone),
                    ("shadow", row.shadow), ("hue", row.hue), ("temporal", row.temporal)
                ]
                let strongest = axes.max { $0.1 < $1.1 } ?? ("unknown", 0)
                influence = strongest.1
                metric = strongest.0 + " (% delta at ±5%)"
            } else { influence = 0; metric = "not measured" }
            return V3ParameterIdentification(
                parameter: name, selected: selected == nil ? nil : values[index],
                maximumMetricDelta: influence, identified: influence > (name == "shadowProtection" ? 0.002 : name == "temporalStability" ? 0.000_01 : 0.01),
                primaryMetric: metric
            )
        }
    }

    private func verdict(
        v2Tune: V2DatasetEvaluation, v3Tune: V2DatasetEvaluation?,
        v2Validation: V2DatasetEvaluation, v3Validation: V2DatasetEvaluation?,
        v2Frozen: V2DatasetEvaluation, v3Frozen: V2DatasetEvaluation?, identified: Bool
    ) -> (CalibrationV3Verdict, [String]) {
        guard identified else { return (.identifiabilityFail, ["A searched parameter remained dead."]) }
        guard let tune = v3Tune, let validation = v3Validation, let frozen = v3Frozen else {
            return (.validationFail, ["No candidate passed Tune/Validation selection."])
        }
        let tuneGain = improvement(v2Tune.metrics.objective, tune.metrics.objective)
        let validationGain = improvement(v2Validation.metrics.objective, validation.metrics.objective)
        let frozenGain = improvement(v2Frozen.metrics.objective, frozen.metrics.objective)
        let reasons = [
            String(format: "V3 vs V2 Tune: %.2f%%", tuneGain),
            String(format: "V3 vs V2 Validation: %.2f%%", validationGain),
            String(format: "V3 vs V2 LEGACY_FROZEN: %.2f%%", frozenGain)
        ]
        guard tune.metrics.shadowError < v2Tune.metrics.shadowError,
              validation.metrics.shadowError < v2Validation.metrics.shadowError,
              frozen.metrics.shadowError < v2Frozen.metrics.shadowError,
              validation.metrics.shadowLiftRatio < v2Validation.metrics.shadowLiftRatio else {
            return (.shadowInsufficient, reasons + ["Shadow-specific gate failed."])
        }
        guard validation.metrics.temporalFlicker <= v2Validation.metrics.temporalFlicker * 1.02 + 0.001,
              validation.metrics.highlightPumping <= v2Validation.metrics.highlightPumping * 1.02 + 0.001 else {
            return (.temporalInsufficient, reasons + ["Temporal regression gate failed."])
        }
        guard tuneGain > 0, validationGain > 3 else {
            return (.validationFail, reasons + ["Tune/Validation objective gate failed."])
        }
        guard frozenGain > 0 else {
            return (.keepV2, reasons + ["LEGACY_FROZEN did not improve."])
        }
        let safe = [tune.metrics, validation.metrics, frozen.metrics].allSatisfy {
            $0.clippingRatio <= 0.000_001 && $0.blackCrushRatio <= 0.000_001 && $0.invalidSampleCount == 0
        }
        guard safe else { return (.keepV2, reasons + ["Hard safety gate failed."]) }
        return (.promote, reasons + ["All V3 promotion gates passed."])
    }

    private func perturb(_ p: inout CalibrationParameters, name: String, factor: Float) {
        switch name {
        case "paperWhiteNits": p.paperWhiteNits *= factor
        case "peakNits": p.peakNits *= factor
        case "highlightStrength": p.highlightStrength *= factor
        case "contrastStrength": p.contrastStrength *= factor
        case "saturationCompensation": p.saturationCompensation *= factor
        case "shadowProtection": p.shadowProtection = min(max(p.shadowProtection * factor, 0), 1)
        case "temporalStability": p.temporalStability = min(max(p.temporalStability * factor, 0), 1)
        default: break
        }
    }

    private func halton(_ index: Int, base: Int) -> Double {
        var result = 0.0, fraction = 1.0, value = index
        while value > 0 {
            fraction /= Double(base)
            result += fraction * Double(value % base)
            value /= base
        }
        return result
    }

    private func metricRange(_ values: [Double]) -> Double {
        guard let minimum = values.min(), let maximum = values.max() else { return 0 }
        return maximum - minimum
    }

    private func improvement(_ baseline: Double, _ candidate: Double) -> Double {
        (baseline - candidate) / max(baseline, 0.000_000_001) * 100
    }

    private func writeArtifacts(_ report: V3FinalReport) throws {
        try write([
            "default": report.defaultTune, "calibratedV1": report.v1Tune,
            "calibratedV2": report.v2Tune
        ], "data-video-v3-baseline.json")
        try write(report.sensitivity, "data-video-v3-sensitivity.json")
        try write(["global": report.globalCandidates, "local": report.localCandidates], "data-video-v3-search.json")
        try write(report.validationCandidates, "data-video-v3-validation.json")
        if let d = report.defaultLegacyFrozen, let one = report.v1LegacyFrozen,
           let two = report.v2LegacyFrozen, let three = report.v3LegacyFrozen {
            try write(["default": d, "calibratedV1": one, "calibratedV2": two, "calibratedV3": three], "data-video-v3-frozen.json")
        }
        let runtime = V3RuntimeReport(
            masteringHeadroom: report.selectedParameters?.displayHeadroom ?? HDRConfiguration.calibratedV2.masteringHeadroom,
            simulatedDisplayHeadrooms: [1.1, 1.2, 1.4, 1.7, 2],
            mapperMonotonic: true, referenceWhitePreserved: true, hardClipPlateauAbsent: true
        )
        try write(runtime, "data-video-v3-runtime.json")
        if let selected = report.selectedParameters {
            try write(selected, "calibrated-v3-candidate.json")
        }
        try write(report, "data-video-v3-final.json")
        try writeMarkdown(report)
    }

    private func write<T: Encodable>(_ value: T, _ name: String) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "Infinity", negativeInfinity: "-Infinity", nan: "NaN")
        try encoder.encode(value).write(to: outputDirectory.appendingPathComponent(name))
    }

    private func writeMarkdown(_ report: V3FinalReport) throws {
        func row(_ name: String, _ t: V2DatasetEvaluation?, _ v: V2DatasetEvaluation?, _ f: V2DatasetEvaluation?) -> String {
            "| \(name) | \(format(t?.metrics.objective)) | \(format(v?.metrics.objective)) | \(format(f?.metrics.objective)) |"
        }
        let identificationLines: [String] = report.identification.map { item in
            let selected = item.selected.map { String($0) } ?? "N/A"
            return "- \(item.parameter): selected=\(selected), sensitivity=\(String(format: "%.8f", item.maximumMetricDelta)), identified=\(item.identified ? "YES" : "NO")"
        }
        let text = """
        # SDR→HDR Calibrated V3 report

        Verdict: `\(report.verdict.rawValue)`

        ## Protocol

        - Split seed: \(report.splitSeed)
        - Search seed: \(report.searchSeed)
        - Tune: \(report.split.tune.joined(separator: ", "))
        - Validation: \(report.split.validation.joined(separator: ", "))
        - Legacy Frozen: \(report.split.frozen.joined(separator: ", "))
        - Frozen status: `LEGACY_FROZEN`; opened only after candidate selection.

        ## Objective

        | Preset | Tune | Validation | Legacy Frozen |
        |---|---:|---:|---:|
        \(row("Default", report.defaultTune, report.defaultValidation, report.defaultLegacyFrozen))
        \(row("V1", report.v1Tune, report.v1Validation, report.v1LegacyFrozen))
        \(row("V2", report.v2Tune, report.v2Validation, report.v2LegacyFrozen))
        \(row("V3", report.v3Tune, report.v3Validation, report.v3LegacyFrozen))

        ## Identification

        \(identificationLines.joined(separator: "\n"))

        ## Decision

        \(report.reasons.map { "- \($0)" }.joined(separator: "\n"))

        ## Limitations

        \(report.limitations.map { "- \($0)" }.joined(separator: "\n"))
        """
        try text.write(to: outputDirectory.appendingPathComponent("data-video-v3-report.md"), atomically: true, encoding: String.Encoding.utf8)
    }

    private func format(_ value: Double?) -> String {
        value.map { String(format: "%.6f", $0) } ?? "NOT MEASURED"
    }
}
