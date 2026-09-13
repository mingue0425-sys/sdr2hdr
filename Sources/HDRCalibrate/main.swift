import Foundation
import HDRCalibration
import HDRCore
import Metal

private struct CLI {
    let command: String
    let manifest: URL?
    let output: URL
    let candidate: URL?
    let preparedPlan: URL?
    let preparedFrozenPlan: URL?
    let preregistration: URL?
    let documentation: URL?
    let policy: SDRInputInterpretationPolicy?
    let policyWasProvided: Bool
    let seed: UInt64
    let seedWasProvided: Bool
    let root: URL?
    let dryRun: Bool
    let selectionCount: Int
    let selectionCountWasProvided: Bool
    let verifyOnly: Bool

    init(arguments: [String]) throws {
        guard arguments.count > 1 else { throw CLIError.usage }
        if arguments[1] == "--help" || arguments[1] == "-h" { throw CLIError.usage }
        command = arguments[1]
        var manifest: URL?
        var output = URL(fileURLWithPath: "results/calibration-report.json", relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
        var candidate: URL?
        var preparedPlan: URL?
        var preparedFrozenPlan: URL?
        var preregistration: URL?
        var documentation: URL?
        var policy: SDRInputInterpretationPolicy?
        var policyWasProvided = false
        var seed: UInt64 = 42
        var seedWasProvided = false
        var root: URL?
        var dryRun = false
        var selectionCount = 6
        var selectionCountWasProvided = false
        var verifyOnly = false
        var index = 2
        while index < arguments.count {
            switch arguments[index] {
            case "--manifest":
                guard index + 1 < arguments.count else { throw CLIError.usage }
                manifest = URL(
                    fileURLWithPath: arguments[index + 1],
                    relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                ).standardizedFileURL
                index += 2
            case "--output":
                guard index + 1 < arguments.count else { throw CLIError.usage }
                output = URL(
                    fileURLWithPath: arguments[index + 1],
                    relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                ).standardizedFileURL
                index += 2
            case "--candidate":
                guard index + 1 < arguments.count else { throw CLIError.usage }
                candidate = URL(
                    fileURLWithPath: arguments[index + 1],
                    relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                ).standardizedFileURL
                index += 2
            case "--prepared-plan":
                guard index + 1 < arguments.count else { throw CLIError.usage }
                preparedPlan = URL(
                    fileURLWithPath: arguments[index + 1],
                    relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                ).standardizedFileURL
                index += 2
            case "--prepared-frozen-plan":
                guard index + 1 < arguments.count else { throw CLIError.usage }
                preparedFrozenPlan = URL(
                    fileURLWithPath: arguments[index + 1],
                    relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                ).standardizedFileURL
                index += 2
            case "--preregistration":
                guard index + 1 < arguments.count else { throw CLIError.usage }
                preregistration = URL(
                    fileURLWithPath: arguments[index + 1],
                    relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                ).standardizedFileURL
                index += 2
            case "--documentation":
                guard index + 1 < arguments.count else { throw CLIError.usage }
                documentation = URL(
                    fileURLWithPath: arguments[index + 1],
                    relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                ).standardizedFileURL
                index += 2
            case "--policy":
                guard index + 1 < arguments.count,
                      let value = SDRInputInterpretationPolicy(rawValue: arguments[index + 1]) else {
                    throw CLIError.usage
                }
                policy = value
                policyWasProvided = true
                index += 2
            case "--seed":
                guard index + 1 < arguments.count, let value = UInt64(arguments[index + 1]) else { throw CLIError.usage }
                seed = value
                seedWasProvided = true
                index += 2
            case "--root":
                guard index + 1 < arguments.count else { throw CLIError.usage }
                root = URL(
                    fileURLWithPath: arguments[index + 1],
                    relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                ).standardizedFileURL
                index += 2
            case "--select":
                guard index + 1 < arguments.count, let value = Int(arguments[index + 1]), value > 0 else { throw CLIError.usage }
                selectionCount = value
                selectionCountWasProvided = true
                index += 2
            case "--dry-run":
                dryRun = true
                index += 1
            case "--verify-only":
                verifyOnly = true
                index += 1
            case "--help", "-h":
                throw CLIError.usage
            default:
                throw CLIError.unknownOption(arguments[index])
            }
        }
        self.manifest = manifest
        self.output = output
        self.candidate = candidate
        self.preparedPlan = preparedPlan
        self.preparedFrozenPlan = preparedFrozenPlan
        self.preregistration = preregistration
        self.documentation = documentation
        self.policy = policy
        self.policyWasProvided = policyWasProvided
        self.seed = seed
        self.seedWasProvided = seedWasProvided
        self.root = root
        self.dryRun = dryRun
        self.selectionCount = selectionCount
        self.selectionCountWasProvided = selectionCountWasProvided
        self.verifyOnly = verifyOnly
    }

    func requiredManifest() throws -> URL {
        guard let manifest else { throw CLIError.missingManifest }
        return manifest
    }

    func requiredRoot() throws -> URL {
        guard let root else { throw CLIError.missingRoot }
        return root
    }

    func requiredPreparedPlan() throws -> URL {
        guard let preparedPlan else { throw CLIError.missingPreparedPlan }
        return preparedPlan
    }

    func requiredPreregistration() throws -> URL {
        guard let preregistration else { throw CLIError.missingPreregistration }
        return preregistration
    }
}

private enum CLIError: Error, LocalizedError {
    case usage
    case missingManifest
    case missingRoot
    case missingCandidate
    case missingPreparedPlan
    case missingPreregistration
    case missingPolicy
    case unknownOption(String)

    var errorDescription: String? {
        switch self {
        case .usage: return Self.usageText
        case .missingManifest: return "--manifest is required"
        case .missingRoot: return "--root is required"
        case .missingCandidate: return "--candidate is required"
        case .missingPreparedPlan: return "--prepared-plan is required"
        case .missingPreregistration: return "--preregistration is required"
        case .missingPolicy: return "--policy is required for causal prepared-plan verification"
        case .unknownOption(let option): return "unknown option: \(option)\n\n\(Self.usageText)"
        }
    }

    static let usageText = """
    Usage:
      HDRCalibrate validate-dataset --manifest dataset/manifest.json --output results/dataset.json
      HDRCalibrate align           --manifest dataset/manifest.json --output results/alignment.json
      HDRCalibrate baseline        --manifest dataset/manifest.json --output results/baseline.json
      HDRCalibrate search          --manifest dataset/manifest.json --seed 42 --output results/calibration.json
      HDRCalibrate validate        --manifest dataset/manifest.json --candidate results/candidate.json
      HDRCalibrate frozen-test     --manifest dataset/manifest.json --candidate results/candidate.json
      HDRCalibrate run             --manifest dataset/manifest.json --seed 42 --output results/calibration.json
      HDRCalibrate v2-audit        --manifest data_video/manifest-v2.json --output results/data-video-v2-dataset-audit.json
      HDRCalibrate v2-run-development --manifest data_video/manifest-v2.json --seed 20260823 --output results/data-video-v2-final.json
      HDRCalibrate v3-run-development --manifest data_video/manifest-v2.json --seed 20260824 --output results/data-video-v3-final.json
      HDRCalibrate v4-run-development --manifest data_video/manifest-v4.json --prepared-plan results/v6-prepared-evaluation-plan.json --prepared-frozen-plan /path/to/admitted-v6-frozen-plan.json --seed 20260824 --output results/data-video-v4-final.json
      HDRCalibrate correctness-review --manifest data_video/manifest-v4.json [--prepared-frozen-plan /path/to/admitted-v6-frozen-plan.json] --output results/correctness-review-fixes.json
      HDRCalibrate matcher-diagnostic --manifest data_video/manifest-v4.json --output results/v6-matcher-diagnostic.json
      HDRCalibrate v6-curve-audit --output /tmp/v6-tone-curve-audit.json
      HDRCalibrate v6-evaluate --manifest data_video/visual-regression/v6-development-manifest.json --output /tmp/v6-development-evaluation.json
      HDRCalibrate v6-1-attribution --manifest data_video/visual-regression/v6-development-manifest.json --output /tmp/v6.1-error-attribution.json
      HDRCalibrate v6-2-adaptive --manifest data_video/visual-regression/v6-development-manifest.json --output /tmp/v6.2-scene-adaptive.json
      HDRCalibrate preregister-v2 --output results/calibration-rebase-preregistration-v2.json (retired; rejects)
      HDRCalibrate preregister-v3 --output results/calibration-rebase-preregistration-v3.json (audit-invalidated; rejects)
      HDRCalibrate preregister-v4 --output results/calibration-rebase-preregistration-v4.json [--documentation docs/PR13_EXECUTION_BOUND_PREREGISTRATION_V4.md]
      HDRCalibrate run-preregistered --verify-only --preregistration results/calibration-rebase-preregistration-v4.json
      HDRCalibrate verify-prepared-plan --manifest data_video/manifest-v4.json --prepared-plan results/v6-prepared-evaluation-plan.json --policy bt709SourceLinear
      HDRCalibrate verify-prepared-plan-structure --prepared-plan results/v6-prepared-evaluation-plan.json
      HDRCalibrate dataset-audit   --manifest data_video/manifest-v4.json --output results/dataset-v4-final.json
      HDRCalibrate dataset-audit-preflight --manifest data_video/manifest-v4.json --output results/dataset-v4-final.json
      HDRCalibrate dataset-import-live --root "/path/to/LIVE" --manifest data_video/manifest-v4.json --select 6 [--dry-run]

    The calibration tool never treats a missing or non-PQ HDR reference as ground truth.
    """
}

private func writeDatasetReport(_ report: DatasetReport, output: URL) throws {
    try DatasetScanner.write(report, to: output)
    print("dataset report: \(output.path)")
    print("pairs: \(report.pairs.count), valid: \(report.validPairs.count), status: \(report.counts)")
}

private func loadCalibrationReport(from url: URL) throws -> CalibrationReport {
    try JSONDecoder().decode(CalibrationReport.self, from: Data(contentsOf: url))
}

private func verifyPreparedPlanCausally(cli: CLI) async throws {
    let manifestURL = try cli.requiredManifest()
    let planURL = try cli.requiredPreparedPlan()
    guard let policy = cli.policy else { throw CLIError.missingPolicy }
    let planHash = try await V6PreparedPlanCausalVerifier.verify(
        manifestURL: manifestURL,
        preparedPlanURL: planURL,
        preparationConfiguration: V6PreparationConfiguration.v6.forInterpretationPolicy(policy)
    )
    print("PreparedEvaluationPlan causally verified: \(planHash)")
    print("CAUSAL_PROVENANCE_VERIFIED_BY_CURRENT_IMPLEMENTATION")
}

private func run(arguments: [String]) async throws {
    let cli = try CLI(arguments: arguments)
    if cli.command == "preregister-v2" {
        throw CalibrationError.incompleteEvaluation(
            "SearchDefinitionHashV2 is audit-invalidated; use preregister-v4 after semantic closure"
        )
    }
    if cli.command == "preregister-v3" {
        throw CalibrationError.incompleteEvaluation(
            "SearchDefinitionHashV3 is audit-invalidated; preregister-v4 is the current generator"
        )
    }
    if cli.command == "preregister-v4" {
        let artifact = try PreregisteredCalibrationExperimentV4.current()
        try artifact.validateAgainstCurrentSemantics()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.nonConformingFloatEncodingStrategy = .throw
        try FileManager.default.createDirectory(
            at: cli.output.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try encoder.encode(artifact).write(to: cli.output, options: .atomic)
        if let documentation = cli.documentation {
            try FileManager.default.createDirectory(
                at: documentation.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try artifact.writeHumanReadableDocumentation(to: documentation)
        }
        print("ColorScienceDefinitionHash: \(artifact.colorScienceDefinitionHash)")
        print("PolicyDefinitionHashV4: \(artifact.policyDefinitionHashV4)")
        print("PreparationDefinitionHashV4: \(artifact.preparationDefinitionHashV4)")
        print("MetricDefinitionHashV4: \(artifact.metricDefinitionHashV4)")
        print("GateDefinitionHash: \(artifact.gateDefinitionHash)")
        print("SearchAlgorithmDefinitionHashV4: \(artifact.searchAlgorithmDefinitionHashV4)")
        print("RunnerDefinitionHash: \(artifact.runnerDefinitionHash)")
        print("SearchDefinitionHashV4: \(artifact.searchDefinitionHashV4)")
        print("CorpusDefinitionHash: NOT_YET_CREATED")
        print("ExperimentBindingHash: NOT_YET_CREATED")
        print("preregistration: \(cli.output.path)")
        return
    }
    if cli.command == "run-preregistered" {
        guard cli.verifyOnly else {
            throw PreregisteredCalibrationExecutionError.mediaExecutionDisabledForVerification
        }
        // A preregistered execution accepts no semantic CLI override.  Track
        // whether a flag was supplied instead of comparing against parser
        // defaults, so even an override equal to a legacy default is rejected.
        guard !cli.seedWasProvided,
              !cli.selectionCountWasProvided,
              !cli.policyWasProvided,
              cli.manifest == nil,
              cli.candidate == nil,
              cli.preparedPlan == nil,
              cli.preparedFrozenPlan == nil,
              cli.root == nil,
              !cli.dryRun else {
            throw PreregisteredCalibrationExecutionError.preregistrationMismatch
        }
        let preregistrationURL = cli.preregistration ?? URL(
            fileURLWithPath: "results/calibration-rebase-preregistration-v4.json",
            relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        ).standardizedFileURL
        let artifact = try JSONDecoder().decode(
            PreregisteredCalibrationExperimentV4.self,
            from: Data(contentsOf: preregistrationURL)
        )
        let runner = try PreregisteredCalibrationRunnerV4(experiment: artifact)
        let runtimes = try runner.verifyOnly()
        print("preregistered execution binding: PASS")
        print("runtime derived from seal: YES")
        print("runtime semantic identity match: PASS")
        print("candidate policies: \(runtimes.map { $0.policy.rawValue }.joined(separator: ", "))")
        print("global/local candidates per policy: \(runtimes[0].globalCandidates)/\(runtimes[0].localCandidates)")
        print("budget per policy: \(runtimes[0].totalCandidatesPerPolicy)")
        print("shortlist: \(runtimes[0].shortlistSize)")
        print("objective evaluations: 0")
        print("media execution: NOT RUN")
        return
    }
    if cli.command == "verify-prepared-plan" {
        try await verifyPreparedPlanCausally(cli: cli)
        return
    }
    if cli.command == "verify-prepared-plan-structure" {
        let artifact = try V6PreparedEvaluationPlanArtifact.load(
            from: try cli.requiredPreparedPlan()
        )
        guard try artifact.verified() else {
            throw CalibrationError.incompleteEvaluation("PreparedEvaluationPlan artifact hash mismatch")
        }
        print("PreparedEvaluationPlan structural hash: \(artifact.planSHA256)")
        print("STRUCTURAL_INTEGRITY_ONLY")
        print("CAUSAL_PROVENANCE_NOT_PROVEN")
        return
    }
    if cli.command == "dataset-import-live" {
        let root = try cli.requiredRoot()
        let manifest = try cli.requiredManifest()
        _ = try await V4LiveImporter.importDataset(
            rootURL: root,
            manifestURL: manifest,
            outputDirectory: cli.output.deletingLastPathComponent(),
            selectionCount: cli.selectionCount,
            dryRun: cli.dryRun
        )
        return
    }
    if cli.command == "correctness-review" {
        let manifestURL = try cli.requiredManifest()
        let report = try await V4CorrectnessReview.run(
            manifestURL: manifestURL,
            outputDirectory: cli.output.deletingLastPathComponent(),
            preparedFrozenPlanURL: cli.preparedFrozenPlan
        )
        print("correctness verdict: \(report.verdict)")
        print("Tune structural completeness: \(report.tune.evaluatedVideoCount)/\(report.tune.requestedVideoCount)")
        print("Validation structural completeness: \(report.validation.evaluatedVideoCount)/\(report.validation.requestedVideoCount)")
        print("Virgin Frozen objective: NOT MEASURED")
        print("correctness report: \(cli.output.deletingLastPathComponent().appendingPathComponent("correctness-review-fixes.json").path)")
        guard report.verdict == "CORRECTNESS_READY_FOR_V6" else {
            throw CalibrationError.incompleteEvaluation(
                "correctness-review did not reach CORRECTNESS_READY_FOR_V6: \(report.verdict)"
            )
        }
        return
    }
    if cli.command == "matcher-diagnostic" {
        let report = try await V6MatcherDiagnostics.run(
            manifestURL: try cli.requiredManifest(), outputURL: cli.output
        )
        print("V6 matcher diagnostics: \(report.pairs.count) Tune/Validation pairs")
        print("Frozen files accessed: \(report.frozenFilesAccessed)")
        print("matcher diagnostic report: \(cli.output.path)")
        return
    }
    if cli.command == "v2-audit" {
        let manifestURL = try cli.requiredManifest()
        let manifest = try PairManifest.load(from: manifestURL)
        let audit = try DatasetV2Discovery.audit(rootURL: manifestURL.deletingLastPathComponent())
        let split = DatasetV2Discovery.splitDocument(manifest: manifest, seed: 92)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: cli.output.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(audit).write(to: cli.output)
        try encoder.encode(split).write(to: cli.output.deletingLastPathComponent().appendingPathComponent("data-video-v2-split.json"))
        print("V2 audit: valid=\(audit.validPairCount), rejected=\(audit.rejectedGroupCount)")
        return
    }

    if cli.command == "v6-curve-audit" {
        let audit = HDRV6ToneCurveDevelopment.audit()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: cli.output.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(audit).write(to: cli.output, options: .atomic)
        print("V6 curve audit: candidates=\(audit.candidates.count), dense samples=\(audit.denseSampleCount)")
        print("V6 curve audit: \(cli.output.path)")
        return
    }

    if cli.command == "v6-evaluate" {
        let report = try await V6ToneCurveDevelopmentRunner.run(
            manifestURL: try cli.requiredManifest(),
            outputURL: cli.output
        )
        print("V6 development evaluation: Tune pairs=\(report.tunePairCount), Validation pairs=\(report.validationPairCount)")
        print("V6 development evaluation: \(cli.output.path)")
        return
    }

    if cli.command == "v6-1-attribution" {
        let report = try await V61ErrorAttributionRunner.run(
            manifestURL: try cli.requiredManifest(),
            outputURL: cli.output
        )
        print("V6.1 attribution: Tune/Validation pairs=\(report.preparedPairIDs.count), scenes=\(report.sceneBreakdown.count)")
        print("V6.1 attribution: Frozen objective evaluations=\(report.frozenObjectiveEvaluations)")
        print("V6.1 attribution report: \(cli.output.path)")
        return
    }

    if cli.command == "v6-2-adaptive" {
        let report = try await V62SceneAdaptiveExpansionRunner.run(
            manifestURL: try cli.requiredManifest(),
            outputURL: cli.output
        )
        print("V6.2 scene-adaptive evaluation: scenes=\(report.demandScenes.count), candidates=\(report.candidates.count)")
        print("V6.2 verdict: \(report.verdict)")
        print("V6.2 protected objective evaluations=\(report.frozenObjectiveEvaluations + report.virginFrozenObjectiveEvaluations)")
        print("V6.2 report: \(cli.output.path)")
        return
    }

    if cli.command == "v2-run" || cli.command == "v3-run" {
        throw CalibrationError.incompleteEvaluation(
            "legacy search entry points are development-only; use the explicit -development command, never preregistered calibration"
        )
    }

    if cli.command == "v2-run-development" {
        let manifestURL = try cli.requiredManifest()
        var configuration = V2SearchConfiguration()
        configuration.searchSeed = cli.seed
        let runner = try CalibrationV2Runner(
            manifestURL: manifestURL,
            outputDirectory: cli.output.deletingLastPathComponent(),
            configuration: configuration
        )
        let report = try await runner.run()
        print("V2 verdict: \(report.verdict.rawValue)")
        print("V2 report: \(cli.output.path)")
        return
    }

    if cli.command == "v3-run-development" {
        let manifestURL = try cli.requiredManifest()
        var configuration = V3SearchConfiguration()
        configuration.searchSeed = cli.seed
        let runner = try CalibrationV3Runner(
            manifestURL: manifestURL,
            outputDirectory: cli.output.deletingLastPathComponent(),
            configuration: configuration
        )
        let report = try await runner.run()
        print("V3 verdict: \(report.verdict.rawValue)")
        print("V3 report: \(cli.output.path)")
        return
    }

    if cli.command == "v4-run" {
        throw CalibrationError.incompleteEvaluation(
            "v4-run is a legacy development entry point; use run-preregistered with a V4 artifact"
        )
    }

    if cli.command == "v4-run-development" {
        let manifestURL = try cli.requiredManifest()
        var configuration = V4CalibrationConfiguration()
        configuration.searchSeed = cli.seed
        let runner = try CalibrationV4Runner(
            manifestURL: manifestURL,
            outputDirectory: cli.output.deletingLastPathComponent(),
            configuration: configuration,
            preparedEvaluationPlanURL: try cli.requiredPreparedPlan(),
            preparedFrozenPlanURL: cli.preparedFrozenPlan
        )
        let report = try await runner.run()
        print("V4 verdict: \(report.verdict.rawValue)")
        print("V4 report: \(cli.output.path)")
        return
    }

    if cli.command == "validate-dataset" {
        let report = try await DatasetScanner.scan(manifestURL: try cli.requiredManifest())
        try writeDatasetReport(report, output: cli.output)
        return
    }

    if cli.command == "dataset-audit" || cli.command == "dataset-audit-v4" {
        let manifestURL = try cli.requiredManifest()
        let report = try await V4DatasetAuditor.audit(manifestURL: manifestURL)
        try V4ReportWriter.write(report, to: cli.output)
        let main = report.pairs.filter { $0.suitability == .mainCalibration }.count
        let conditional = report.pairs.filter { $0.suitability == .conditional || $0.suitability == .diagnosticOnly }.count
        let rejected = report.pairs.filter { $0.suitability == .reject }.count
        print("V4 dataset audit: pairs=\(report.pairs.count), main=\(main), conditional=\(conditional), rejected=\(rejected)")
        print("V4 virgin frozen pairs: \(report.diversity.virginFrozenPairs); objective evaluation: NOT PERFORMED")
        print("V4 structural dataset verdict: \(report.verdict.rawValue)")
        print("V4 readiness scope: DATASET_INTEGRITY_ONLY (Pre-V6 holdout readiness is evaluated separately by correctness-review)")
        print("V4 report: \(cli.output.path)")
        return
    }

    if cli.command == "dataset-audit-preflight" {
        let manifestURL = try cli.requiredManifest()
        let auditURL = cli.output
        let lockURL = manifestURL.deletingLastPathComponent().appendingPathComponent("dataset-v4-lock.json")
        let evidence = try V4DatasetEvidenceValidator.validate(
            manifestURL: manifestURL,
            auditURL: auditURL,
            lockURL: lockURL,
            mediaScope: .tuneValidationOnly
        )
        print("V6 preflight audit evidence: manifest=\(evidence.manifestHash), lock=\(evidence.lockHash), audit=\(evidence.auditHash)")
        print("V6 preflight audit: Tune/Validation media validated; Virgin Frozen media not opened")
        return
    }

    if cli.command == "align" {
        let manifestURL = try cli.requiredManifest()
        let dataset = try await DatasetScanner.scan(manifestURL: manifestURL)
        var aligned: [PairAlignmentReport] = []
        for validation in dataset.validPairs {
            let urls = validation.pair.resolvedURLs(relativeTo: manifestURL)
            do {
                let sdr = try await FrameReader.read(url: urls.sdr, pixelFormat: CalibrationPixelFormat.sdrNV12, maxFrames: 240)
                let hdr = try await FrameReader.read(url: urls.hdr, pixelFormat: CalibrationPixelFormat.hdrP010, maxFrames: 240)
                let result = TemporalAligner.align(sdr: sdr, hdr: hdr)
                aligned.append(PairAlignmentReport(pairID: validation.pair.id, result: result))
            } catch {
                aligned.append(PairAlignmentReport(
                    pairID: validation.pair.id,
                    result: AlignmentResult(status: "REJECT", coarseOffsetSeconds: 0, matches: [], rejectedFrames: 0, medianConfidence: 0, notes: [error.localizedDescription])
                ))
            }
        }
        try FileManager.default.createDirectory(at: cli.output.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(AlignmentReportDocument(manifestPath: manifestURL.path, pairs: aligned)).write(to: cli.output)
        print("alignment report: \(cli.output.path), pairs: \(aligned.count)")
        return
    }

    let manifest = try cli.requiredManifest()
    let experiment = ExperimentConfig(seed: cli.seed)
    let runner = CalibrationRunner(manifestURL: manifest, experiment: experiment)

    switch cli.command {
    case "baseline":
        let baselineOnly = try await runner.baselineOnly()
        try CalibrationRunner.writeReport(baselineOnly, to: cli.output)
        try CalibrationReportWriter.writeCSV(baselineOnly, to: cli.output.deletingPathExtension().appendingPathExtension("csv"))
        try CalibrationReportWriter.writeHTML(baselineOnly, to: cli.output.deletingPathExtension().appendingPathExtension("html"))
        print("baseline verdict: \(baselineOnly.verdict.rawValue)")
    case "search", "run":
        let report = try await runner.run()
        try CalibrationRunner.writeReport(report, to: cli.output)
        try CalibrationReportWriter.writeCSV(report, to: cli.output.deletingPathExtension().appendingPathExtension("csv"))
        try CalibrationReportWriter.writeHTML(report, to: cli.output.deletingPathExtension().appendingPathExtension("html"))
        print("calibration verdict: \(report.verdict.rawValue)")
        print("report: \(cli.output.path)")
    case "validate", "frozen-test":
        guard let candidateURL = cli.candidate else { throw CLIError.missingCandidate }
        let report = try loadCalibrationReport(from: candidateURL)
        guard let parameters = report.selectedCandidate?.parameters else {
            print("verdict: DATASET_INSUFFICIENT (candidate contains no selected parameters)")
            return
        }
        let split: DatasetSplit = cli.command == "validate" ? .validation : .frozen
        let metrics = try await runner.evaluate(candidate: parameters, split: split)
        print("split: \(split.rawValue)")
        if let metrics {
            print(String(format: "objective: %.6f, scenes: %d, pairs: %d", metrics.objective, metrics.sceneCount, metrics.pairCount))
        } else {
            print("metrics: NOT MEASURED (no pairs in split)")
        }
    default:
        throw CLIError.unknownOption(cli.command)
    }
}

@main
struct HDRCalibrateMain {
    static func main() async {
        do {
            try await run(arguments: CommandLine.arguments)
        } catch CLIError.usage {
            print(CLIError.usageText)
        } catch {
            fputs("HDRCalibrate error: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
}
