import Foundation
import HDRCalibration
import Metal

private struct CLI {
    let command: String
    let manifest: URL?
    let output: URL
    let candidate: URL?
    let preparedPlan: URL?
    let preparedFrozenPlan: URL?
    let seed: UInt64
    let root: URL?
    let dryRun: Bool
    let selectionCount: Int

    init(arguments: [String]) throws {
        guard arguments.count > 1 else { throw CLIError.usage }
        if arguments[1] == "--help" || arguments[1] == "-h" { throw CLIError.usage }
        command = arguments[1]
        var manifest: URL?
        var output = URL(fileURLWithPath: "results/calibration-report.json", relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
        var candidate: URL?
        var preparedPlan: URL?
        var preparedFrozenPlan: URL?
        var seed: UInt64 = 42
        var root: URL?
        var dryRun = false
        var selectionCount = 6
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
            case "--seed":
                guard index + 1 < arguments.count, let value = UInt64(arguments[index + 1]) else { throw CLIError.usage }
                seed = value
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
                index += 2
            case "--dry-run":
                dryRun = true
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
        self.seed = seed
        self.root = root
        self.dryRun = dryRun
        self.selectionCount = selectionCount
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
}

private enum CLIError: Error, LocalizedError {
    case usage
    case missingManifest
    case missingRoot
    case missingCandidate
    case missingPreparedPlan
    case unknownOption(String)

    var errorDescription: String? {
        switch self {
        case .usage: return Self.usageText
        case .missingManifest: return "--manifest is required"
        case .missingRoot: return "--root is required"
        case .missingCandidate: return "--candidate is required"
        case .missingPreparedPlan: return "--prepared-plan is required"
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
      HDRCalibrate v2-run          --manifest data_video/manifest-v2.json --seed 20260823 --output results/data-video-v2-final.json
      HDRCalibrate v3-run          --manifest data_video/manifest-v2.json --seed 20260824 --output results/data-video-v3-final.json
      HDRCalibrate v4-run          --manifest data_video/manifest-v4.json --prepared-plan results/v6-prepared-evaluation-plan.json --prepared-frozen-plan /path/to/admitted-v6-frozen-plan.json --seed 20260824 --output results/data-video-v4-final.json
      HDRCalibrate correctness-review --manifest data_video/manifest-v4.json [--prepared-frozen-plan /path/to/admitted-v6-frozen-plan.json] --output results/correctness-review-fixes.json
      HDRCalibrate matcher-diagnostic --manifest data_video/manifest-v4.json --output results/v6-matcher-diagnostic.json
      HDRCalibrate verify-prepared-plan --prepared-plan results/v6-prepared-evaluation-plan.json
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

private func run(arguments: [String]) async throws {
    let cli = try CLI(arguments: arguments)
    if cli.command == "verify-prepared-plan" {
        let artifact = try V6PreparedEvaluationPlanLoader.loadSealed(
            from: try cli.requiredPreparedPlan()
        )
        guard artifact.plan.preparation == .v6 else {
            throw CalibrationError.incompleteEvaluation(
                "PreparedEvaluationPlan does not use the current fully sealed V6 preparation configuration"
            )
        }
        print("PreparedEvaluationPlan verified: \(artifact.planSHA256)")
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

    if cli.command == "v2-run" {
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

    if cli.command == "v3-run" {
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
