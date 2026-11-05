import Foundation
import Metal

/// Builds the admitted Virgin Frozen `PreparedEvaluationPlan`.
///
/// This decodes and aligns Virgin Frozen media exactly as the Tune/Validation
/// plan was prepared (same preparation settings, same matcher, same
/// confidence gate) and seals the resulting decisions. It never constructs
/// the objective evaluator, never renders a candidate, and never compares a
/// candidate against a reference, so the holdout stays objective-unexposed.
/// The plan is validated with the same sealed contract that `v4-run` and
/// `correctness-review` apply before accepting it.
public enum V6FrozenPlanPreparation {
    public static let scope = "VIRGIN_FROZEN"

    public struct Result: Sendable {
        public let planURL: URL
        public let planSHA256: String
        public let pairIDs: [String]
        public let acceptedFrameCount: Int
    }

    /// The holdout set, in manifest order: identical to v4-run's
    /// `virginManifestRecords`. Any pair already marked as evaluated or
    /// consumed makes the request fail instead of being silently dropped.
    static func virginRecords(_ manifest: V4Manifest) throws -> [V4PairRecord] {
        let records = manifest.pairs.filter {
            $0.split == .frozen && $0.virginFrozen && !V6VirginHoldoutPolicy.isExcluded($0.id)
        }
        guard !records.isEmpty else {
            throw CalibrationError.invalidManifest("manifest has no Virgin Frozen pairs to prepare")
        }
        if let spent = records.first(where: { $0.objectiveEvaluated != false || $0.consumed != false }) {
            throw CalibrationError.invalidManifest(
                "Virgin Frozen pair \(spent.id) is already evaluated or consumed; it cannot be admitted"
            )
        }
        return records
    }

    public static func run(
        manifestURL: URL,
        auditURL: URL,
        tuneValidationPlanURL: URL,
        outputURL: URL
    ) async throws -> Result {
        let lockURL = manifestURL.deletingLastPathComponent().appendingPathComponent("dataset-v4-lock.json")
        _ = try V4DatasetEvidenceValidator.validate(
            manifestURL: manifestURL, auditURL: auditURL, lockURL: lockURL, mediaScope: .tuneValidationOnly
        )
        let audit = try JSONDecoder().decode(V4DatasetAuditReport.self, from: Data(contentsOf: auditURL))
        let manifest = try V4Manifest.load(from: manifestURL)
        _ = try V4CalibrationConfiguration(manifest: manifest)
        let tuneValidation = try V6PreparedEvaluationPlanLoader.loadSealed(from: tuneValidationPlanURL)
        guard tuneValidation.plan.scope == V6PreparedEvaluationPlanOrdering.tuneValidationScope else {
            throw CalibrationError.incompleteEvaluation("--prepared-plan must be the sealed TUNE_VALIDATION plan")
        }

        let manifestRecords = try virginRecords(manifest)
        let pairRecords = manifestRecords.map { pair -> PairRecord in
            let urls = pair.resolvedURLs(relativeTo: manifestURL, roots: manifest.roots)
            return PairRecord(
                id: pair.id, sdr: urls.sdr.path, hdr: urls.hdr.path,
                license: pair.license, source: pair.source,
                expectedRelation: pair.expectedRelation.legacyRelation(),
                notes: pair.notes, split: pair.split
            )
        }
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw CalibrationError.decodeFailed("Metal device unavailable for Frozen plan preparation")
        }
        let repository = V2PreparedRepository(
            manifestURL: manifestURL,
            device: device,
            configuration: V4CorrectnessReview.preparationSearchConfiguration(),
            acceptedConfidenceThreshold: V4CalibrationConfiguration().confidenceThreshold
        )
        let inputHashes = V6PreparedEvaluationPlanBuilder.makeInputHashes(audit: audit)
        let prepared = try await repository.prepare(records: pairRecords)
        let plan = try repository.sealPreparedEvaluationPlan(
            records: pairRecords, inputHashes: inputHashes, scope: scope
        )
        try V6PreparedEvaluationPlanBuilder.validate(plan: plan, preparedPairs: prepared)
        try V6PreparedEvaluationPlanBuilder.validateSealedContract(
            plan: plan, scope: scope, records: manifestRecords,
            inputHashes: inputHashes, preparation: tuneValidation.plan.preparation
        )

        let artifact = try V6PreparedEvaluationPlanArtifact(plan: plan)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try encoder.encode(artifact).write(to: outputURL)
        try Data((artifact.planSHA256 + "\n").utf8)
            .write(to: outputURL.deletingPathExtension().appendingPathExtension("sha256"))
        // Round-trip through the loader v4-run uses.
        let reloaded = try V6PreparedEvaluationPlanLoader.loadSealed(from: outputURL)
        guard reloaded.planSHA256 == artifact.planSHA256 else {
            throw CalibrationError.incompleteEvaluation("Frozen plan did not round-trip through the sealed loader")
        }
        return Result(
            planURL: outputURL,
            planSHA256: artifact.planSHA256,
            pairIDs: plan.pairOrder,
            acceptedFrameCount: plan.pairs.reduce(0) { $0 + $1.alignment.acceptedFrameCount }
        )
    }
}
