import Foundation
import HDRCore
import Metal
import simd

private func v2Log(_ message: String) {
    FileHandle.standardError.write(Data(("[HDRCalibrate V2] " + message + "\n").utf8))
}

public enum V2TemporalStateIsolation {
    /// A temporal evaluator may be reused only for the exact same parameter
    /// configuration.  A missing or changed key requires a causal-history
    /// reset before evaluating the next configuration.
    public static func requiresReset(previousConfigurationKey: String?, currentConfigurationKey: String) -> Bool {
        previousConfigurationKey != currentConfigurationKey
    }
}

final class V2PreparedRepository {
    private let manifestURL: URL
    private let evaluator: PairEvaluator
    private var cache: [String: PreparedPair] = [:]
    private let preparationConfiguration: V6PreparationConfiguration
    private(set) var preparedEvaluationPlan: PreparedEvaluationPlan?

    init(
        manifestURL: URL,
        device: MTLDevice,
        configuration: V2SearchConfiguration,
        acceptedConfidenceThreshold: Double = 0.60
    ) {
        self.manifestURL = manifestURL
        self.preparationConfiguration = V6PreparationConfiguration(
            maxFramesPerScene: configuration.maxFramesPerScene,
            maxDecodedFrames: max(64, configuration.maxFramesPerScene * 16),
            alignmentConfidenceThreshold: 0,
            acceptedConfidenceThreshold: acceptedConfidenceThreshold,
            temporalFramesPerSecond: 30,
            temporalTargetFrameCount: V4TemporalWindowPolicy.v5.targetFrameCount,
            temporalMinimumFrameCount: V4TemporalWindowPolicy.v5.minimumRequiredFrameCount,
            temporalWarmupFrameCount: V4TemporalWindowPolicy.v5.warmupFrameCount,
            referenceTargetPeakNits: configuration.referenceTargetPeakNits,
            allowHLGModel: true,
            sdrPixelFormat: CalibrationPixelFormat.sdrNV12,
            hdrPixelFormat: CalibrationPixelFormat.hdrP010,
            matcherConfiguration: V6MatcherConfiguration(
                acceptedConfidenceThreshold: acceptedConfidenceThreshold
            )
        )
        self.preparedEvaluationPlan = nil
        self.evaluator = PairEvaluator(
            device: device,
            experiment: ExperimentConfig(
                seed: configuration.searchSeed,
                candidateCount: configuration.globalCandidates + configuration.localCandidates,
                maxFramesPerScene: configuration.maxFramesPerScene,
                alignmentConfidenceThreshold: 0,
                referenceTargetPeakNits: configuration.referenceTargetPeakNits,
                allowHLGModel: true
            ),
            matcherConfiguration: self.preparationConfiguration.matcherConfiguration
        )
    }

    func prepare(records: [PairRecord]) async throws -> [PreparedPair] {
        var result: [PreparedPair] = []
        for record in records {
            if let cached = cache[record.id] {
                result.append(cached)
                continue
            }
            guard preparedEvaluationPlan == nil else {
                throw CalibrationError.incompleteEvaluation(
                    "cannot prepare a new pair after PreparedEvaluationPlan was sealed"
                )
            }
            v2Log("decode/align \(record.id)")
            let prepared = try await evaluator.prepare(record: record, manifestURL: manifestURL)
            cache[record.id] = prepared
            result.append(prepared)
        }
        return result
    }

    /// Seal one immutable preparation plan after all requested records have
    /// been decoded.  The plan contains decisions only; the cached PreparedPair
    /// values retain the decoded buffers used by the evaluator.
    func sealPreparedEvaluationPlan(
        records: [PairRecord],
        inputHashes: [String: V6InputHashes],
        scope: String = "TUNE_VALIDATION"
    ) throws -> PreparedEvaluationPlan {
        let prepared = records.compactMap { cache[$0.id] }
        guard prepared.count == records.count else {
            throw CalibrationError.incompleteEvaluation(
                "cannot seal PreparedEvaluationPlan before every pair is prepared"
            )
        }
        let manifest = try? V4Manifest.load(from: manifestURL)
        let repositoryRoot = try V4SourceHasher.repositoryRoot(for: manifestURL)
        let plan = try V6PreparedEvaluationPlanBuilder.makePlan(
            preparedPairs: prepared,
            manifest: manifest,
            repositoryRoot: repositoryRoot,
            configuration: preparationConfiguration,
            inputHashes: inputHashes,
            scope: scope
        )
        try V6PreparedEvaluationPlanBuilder.validate(plan: plan, preparedPairs: prepared)
        if let installed = preparedEvaluationPlan {
            let installedHash = try V6PreparedEvaluationPlanHasher.sha256(installed)
            let nextHash = try V6PreparedEvaluationPlanHasher.sha256(plan)
            guard installedHash == nextHash else {
                throw CalibrationError.incompleteEvaluation(
                    "PreparedEvaluationPlan is immutable for this preparation repository"
                )
            }
            return installed
        }
        preparedEvaluationPlan = plan
        return plan
    }

    /// Install a plan produced by the preflight process.  This is deliberately
    /// a read-only hand-off: the repository may validate the already decoded
    /// material and the sealed input hashes, but it never selects frames or
    /// rebuilds the plan from the media a second time.
    func installPreparedEvaluationPlan(
        _ plan: PreparedEvaluationPlan,
        records: [PairRecord],
        inputHashes: [String: V6InputHashes]
    ) throws -> PreparedEvaluationPlan {
        guard plan.preparation.matcherConfigurationHash ==
                (try plan.preparation.matcherConfiguration.canonicalSHA256()),
              plan.pairs.allSatisfy({
                  $0.alignment.matcherConfigurationHash == plan.preparation.matcherConfigurationHash
              }) else {
            throw CalibrationError.incompleteEvaluation(
                "preflight PreparedEvaluationPlan matcher configuration hash differs at evaluator entry"
            )
        }
        guard plan.scope == "TUNE_VALIDATION" || plan.scope == "VIRGIN_FROZEN",
              plan.pairOrder == records.map(\.id) else {
            throw CalibrationError.incompleteEvaluation(
                "preflight PreparedEvaluationPlan scope/order does not match evaluator records"
            )
        }
        guard plan.preparation == preparationConfiguration else {
            throw CalibrationError.incompleteEvaluation(
                "preflight PreparedEvaluationPlan configuration differs at evaluator entry"
            )
        }
        for record in records {
            guard let planned = plan.pairPlan(for: record.id),
                  planned.split == record.split,
                  planned.inputHashes == inputHashes[record.id] else {
                throw CalibrationError.incompleteEvaluation(
                    "preflight PreparedEvaluationPlan input hash differs for \(record.id)"
                )
            }
        }
        if let installed = preparedEvaluationPlan {
            let installedHash = try V6PreparedEvaluationPlanHasher.sha256(installed)
            let incomingHash = try V6PreparedEvaluationPlanHasher.sha256(plan)
            guard installedHash == incomingHash else {
                throw CalibrationError.incompleteEvaluation(
                    "PreparedEvaluationPlan is immutable for this preparation repository"
                )
            }
            return installed
        }
        preparedEvaluationPlan = plan
        return plan
    }

    /// Install the preflight artifact first, then decode only its sealed
    /// identities.  No alignment, scene detection, representative selection,
    /// or confidence filtering is performed at evaluator entry.
    func materialize(
        records: [PairRecord],
        using plan: PreparedEvaluationPlan,
        inputHashes: [String: V6InputHashes]
    ) async throws -> [PreparedPair] {
        let installed = try installPreparedEvaluationPlan(
            plan, records: records, inputHashes: inputHashes
        )
        let manifest = try V4Manifest.load(from: manifestURL)
        var result: [PreparedPair] = []
        result.reserveCapacity(records.count)
        for record in records {
            guard let pairPlan = installed.pairPlan(for: record.id) else {
                throw CalibrationError.incompleteEvaluation(
                    "PreparedEvaluationPlan is missing \(record.id)"
                )
            }
            v2Log("materialize sealed plan \(record.id)")
            let prepared = try await evaluator.materialize(
                record: record,
                manifestURL: manifestURL,
                manifest: manifest,
                pairPlan: pairPlan,
                preparation: installed.preparation
            )
            cache[record.id] = prepared
            result.append(prepared)
        }
        try V6PreparedEvaluationPlanBuilder.validate(
            plan: installed, preparedPairs: result
        )
        return result
    }
}

final class V2EvaluationEngine {
    private let device: MTLDevice
    private let weights: V2ObjectiveWeights
    private var evaluators: [String: HDRCoreOfflineEvaluator] = [:]
    /// Temporal history belongs to a (pair, configuration) evaluation.  A
    /// cached evaluator may be reused for speed, but changing parameters must
    /// reset its causal state before the first frame of the new configuration.
    private var evaluatorConfigurationKeys: [String: String] = [:]
    private var preparedEvaluationPlan: PreparedEvaluationPlan?

    init(device: MTLDevice, weights: V2ObjectiveWeights) {
        self.device = device
        self.weights = weights
        self.preparedEvaluationPlan = nil
    }

    func installPreparedEvaluationPlan(
        _ plan: PreparedEvaluationPlan,
        expectedSHA256: String? = nil
    ) throws {
        let actualHash = try V6PreparedEvaluationPlanHasher.sha256(plan)
        if let expectedSHA256, actualHash != expectedSHA256 {
            throw CalibrationError.incompleteEvaluation(
                "PreparedEvaluationPlan hash mismatch before evaluator entry"
            )
        }
        if let installed = preparedEvaluationPlan {
            let installedHash = try V6PreparedEvaluationPlanHasher.sha256(installed)
            guard installedHash == actualHash else {
                throw CalibrationError.incompleteEvaluation(
                    "PreparedEvaluationPlan is immutable for this evaluator session"
                )
            }
            return
        }
        self.preparedEvaluationPlan = plan
    }

    func installPreparedEvaluationPlan(
        _ artifact: V6PreparedEvaluationPlanArtifact
    ) throws {
        guard try artifact.verified() else {
            throw CalibrationError.incompleteEvaluation(
                "PreparedEvaluationPlan artifact hash mismatch before evaluator entry"
            )
        }
        try installPreparedEvaluationPlan(artifact.plan, expectedSHA256: artifact.planSHA256)
    }

    func evaluate(
        preparedPairs: [PreparedPair],
        parameters: CalibrationParameters,
        label: String,
        split: DatasetSplit,
        confidenceThreshold: Double
    ) throws -> V2DatasetEvaluation {
        if let preparedEvaluationPlan {
            try V6PreparedEvaluationEntry.validatePairOrder(
                preparedPairs: preparedPairs,
                plan: preparedEvaluationPlan
            )
        }
        var videos: [V2VideoEvaluation] = []
        for prepared in preparedPairs {
            let configuration = try parameters.configuration()
            let configurationKey = try Self.configurationKey(parameters)
            let evaluator: HDRCoreOfflineEvaluator
            if let cached = evaluators[prepared.record.id] {
                evaluator = cached
                if V2TemporalStateIsolation.requiresReset(
                    previousConfigurationKey: evaluatorConfigurationKeys[prepared.record.id],
                    currentConfigurationKey: configurationKey
                ) {
                    evaluator.clearTemporalHistory()
                    evaluatorConfigurationKeys[prepared.record.id] = configurationKey
                }
            } else {
                let created = try HDRCoreOfflineEvaluator(device: device, configuration: configuration)
                evaluators[prepared.record.id] = created
                evaluatorConfigurationKeys[prepared.record.id] = configurationKey
                evaluator = created
            }
            let accepted: [PreparedMatch]
            if let preparedEvaluationPlan {
                // V6 evaluator entry is read-only with respect to frame
                // selection.  It can only consume the identities sealed by
                // preflight; no confidence filtering or representative
                // selection is recalculated here.
                accepted = try V6PreparedEvaluationEntry.acceptedMatches(
                    prepared: prepared,
                    plan: preparedEvaluationPlan
                )
            } else {
                accepted = prepared.matches.filter { $0.match.confidence >= confidenceThreshold }
                    .sorted { ($0.match.sdrSequencePosition ?? .max) < ($1.match.sdrSequencePosition ?? .max) }
            }
            guard !accepted.isEmpty else {
                throw CalibrationError.incompleteEvaluation("\(prepared.record.id): no accepted matched frames")
            }
            var frameData: [V2FrameData] = []
            frameData.reserveCapacity(accepted.count)
            for item in accepted {
                let generated = try evaluator.evaluateSpatiallyIndependent(
                    pixelBuffer: item.sdr.pixelBuffer,
                    timestampSeconds: item.match.sdrTimeSeconds,
                    configuration: configuration
                )
                frameData.append(V2FrameData(
                    reference: item.reference,
                    generated: generated,
                    sourceLuma: item.sourceLuma,
                    confidence: item.match.confidence
                ))
            }
            var scenes: [V2SceneEvaluation] = []
            for scene in prepared.scenes {
                let sceneFrames = zip(accepted, frameData).compactMap { item, data -> V2FrameData? in
                    guard let position = item.match.sdrSequencePosition else { return nil }
                    return scene.contains(sequencePosition: position) ? data : nil
                }
                guard !sceneFrames.isEmpty else { continue }
                scenes.append(V2MetricsEvaluator.evaluateScene(
                    pairID: prepared.record.id,
                    scene: scene,
                    frames: sceneFrames,
                    configuration: parameters,
                    weights: weights
                ))
            }
            guard !scenes.isEmpty else {
                throw CalibrationError.incompleteEvaluation("\(prepared.record.id): no scene received an accepted frame")
            }
            var videoMetrics = V2MetricsEvaluator.aggregate(scenes.map(\.metrics))
            let temporalWindows: [PreparedTemporalWindow]
            if let preparedEvaluationPlan {
                temporalWindows = try V6PreparedEvaluationEntry.temporalWindows(
                    prepared: prepared,
                    plan: preparedEvaluationPlan
                )
            } else {
                temporalWindows = prepared.temporalWindows.filter { window in
                    window.decision.accepted &&
                        (window.frames.first.map { $0.confidence >= confidenceThreshold } ?? false)
                }
            }
            let temporal = try evaluateTemporalWindows(
                temporalWindows,
                evaluator: evaluator,
                configuration: configuration
            )
            let oldTemporalContribution = videoMetrics.weightedContributions["temporal"] ?? 0
            let temporalContribution = weights.temporal * (
                temporal.luminance * 0.45 + temporal.highlight * 0.35 + temporal.flicker * 0.20
            )
            videoMetrics.temporalLuminanceError = temporal.luminance
            videoMetrics.highlightPumping = temporal.highlight
            videoMetrics.temporalFlicker = temporal.flicker
            videoMetrics.sceneCutOvershoot = temporal.cutOvershoot
            videoMetrics.sceneCutRecovery = temporal.cutRecovery
            videoMetrics.weightedContributions["temporal"] = temporalContribution
            videoMetrics.objective += temporalContribution - oldTemporalContribution
            videos.append(V2VideoEvaluation(
                pairID: prepared.record.id,
                split: split,
                frameCount: scenes.map(\.frameCount).reduce(0, +),
                sceneCount: scenes.count,
                alignment: V2MetricsEvaluator.alignmentStatistics(prepared: prepared),
                categories: V2MetricsEvaluator.categories(scenes: scenes),
                metrics: videoMetrics,
                scenes: scenes
            ))
        }
        let requestedIDs = Set(preparedPairs.map(\.record.id))
        let evaluatedIDs = Set(videos.map(\.pairID))
        guard !videos.isEmpty, requestedIDs == evaluatedIDs else {
            let missing = requestedIDs.subtracting(evaluatedIDs).sorted().joined(separator: ",")
            let extra = evaluatedIDs.subtracting(requestedIDs).sorted().joined(separator: ",")
            throw CalibrationError.incompleteEvaluation("requested/evaluated pair IDs differ; missing=[\(missing)] extra=[\(extra)]")
        }
        return V2DatasetEvaluation(
            label: label,
            split: split,
            videoCount: videos.count,
            frameCount: videos.map(\.frameCount).reduce(0, +),
            sceneCount: videos.map(\.sceneCount).reduce(0, +),
            metrics: V2MetricsEvaluator.aggregate(videos.map(\.metrics)),
            videos: videos
        )
    }

    private static func configurationKey(_ parameters: CalibrationParameters) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(parameters), as: UTF8.self)
    }

    private func evaluateTemporalWindows(
        _ windows: [PreparedTemporalWindow],
        evaluator: HDRCoreOfflineEvaluator,
        configuration: HDRConfiguration
    ) throws -> (luminance: Double, highlight: Double, flicker: Double, cutOvershoot: Double, cutRecovery: Double) {
        var values: [(Double, Double, Double)] = []
        var overshoots: [Double] = []
        var recoveries: [Double] = []
        for window in windows {
            evaluator.clearTemporalHistory()
            evaluator.automaticTemporalEstimationEnabled = true
            var frames: [V2FrameData] = []
            frames.reserveCapacity(window.frames.count)
            var adaptations: [Float] = []
            for item in window.frames {
                let generated = try evaluator.evaluate(
                    pixelBuffer: item.sdr.pixelBuffer,
                    timestampSeconds: item.sdr.descriptor.timestampSeconds,
                    configuration: configuration,
                    averageLuminance: nil,
                    sceneCut: false
                )
                adaptations.append(generated.temporalAdaptationUsed)
                frames.append(V2FrameData(
                    reference: item.reference, generated: generated,
                    sourceLuma: item.sourceLuma, confidence: item.confidence
                ))
            }
            let metric = V2MetricsEvaluator.temporalMetrics(frames)
            values.append(metric)
            if adaptations.count > 1 {
                let settled = adaptations.suffix(min(4, adaptations.count)).reduce(0, +) / Float(min(4, adaptations.count))
                overshoots.append(Double(abs(adaptations[0] - settled)))
                let tolerance = max(abs(settled) * 0.005, 0.0005)
                let recovered = adaptations.firstIndex { abs($0 - settled) <= tolerance } ?? adaptations.count
                recoveries.append(Double(recovered))
            }
        }
        func average(_ key: ((Double, Double, Double)) -> Double) -> Double {
            values.isEmpty ? 0 : values.map(key).reduce(0, +) / Double(values.count)
        }
        return (
            average { $0.0 }, average { $0.1 }, average { $0.2 },
            overshoots.isEmpty ? 0 : overshoots.reduce(0, +) / Double(overshoots.count),
            recoveries.isEmpty ? 0 : recoveries.reduce(0, +) / Double(recoveries.count)
        )
    }

    func diagnostics(
        preparedPairs: [PreparedPair],
        defaultParameters: CalibrationParameters,
        v1Parameters: CalibrationParameters,
        candidateParameters: CalibrationParameters,
        confidenceThreshold: Double
    ) throws -> V2Diagnostics {
        struct Sample {
            var input: Double
            var reference: Double
            var baseline: Double
            var v1: Double
            var v2: Double
            var baselineHue: Double
            var v1Hue: Double
            var v2Hue: Double
            var baselineChroma: Double
            var v1Chroma: Double
            var v2Chroma: Double
            var baselineSaturation: Double
            var v1Saturation: Double
            var v2Saturation: Double
        }
        var samples: [Sample] = []
        for prepared in preparedPairs {
            let accepted = prepared.matches.filter { $0.match.confidence >= confidenceThreshold }
            let baselineEvaluator = try HDRCoreOfflineEvaluator(
                device: device, configuration: try defaultParameters.configuration()
            )
            let v1Evaluator = try HDRCoreOfflineEvaluator(
                device: device, configuration: try v1Parameters.configuration()
            )
            let candidateEvaluator = try HDRCoreOfflineEvaluator(
                device: device, configuration: try candidateParameters.configuration()
            )
            baselineEvaluator.clearTemporalHistory()
            v1Evaluator.clearTemporalHistory()
            candidateEvaluator.clearTemporalHistory()
            for item in accepted {
                let baseline = try baselineEvaluator.evaluateSpatiallyIndependent(
                    pixelBuffer: item.sdr.pixelBuffer, timestampSeconds: item.match.sdrTimeSeconds,
                    configuration: try defaultParameters.configuration()
                )
                let v1 = try v1Evaluator.evaluateSpatiallyIndependent(
                    pixelBuffer: item.sdr.pixelBuffer, timestampSeconds: item.match.sdrTimeSeconds,
                    configuration: try v1Parameters.configuration()
                )
                let v2 = try candidateEvaluator.evaluateSpatiallyIndependent(
                    pixelBuffer: item.sdr.pixelBuffer, timestampSeconds: item.match.sdrTimeSeconds,
                    configuration: try candidateParameters.configuration()
                )
                for index in 0..<min(item.reference.rgbNits.count, item.sourceLuma.count, baseline.rgbNits.count, v1.rgbNits.count, v2.rgbNits.count) {
                    let referenceRGB = item.reference.rgbNits[index]
                    let refICtCp = PerceptualColorV2.ictcp(rgbNits: referenceRGB)
                    let refChroma = hypot(refICtCp.y, refICtCp.z)
                    func colorValues(_ rgb: SIMD3<Float>) -> (Double, Double, Double) {
                        let value = PerceptualColorV2.ictcp(rgbNits: rgb)
                        let chroma = hypot(value.y, value.z)
                        return (
                            PerceptualColorV2.hueError(reference: referenceRGB, generated: rgb),
                            abs(chroma - refChroma),
                            chroma / max(value.x, 0.01) / max(refChroma / max(refICtCp.x, 0.01), 0.01)
                        )
                    }
                    let b = colorValues(baseline.rgbNits[index])
                    let one = colorValues(v1.rgbNits[index])
                    let two = colorValues(v2.rgbNits[index])
                    samples.append(Sample(
                        input: Double(item.sourceLuma[index]), reference: Double(item.reference.lumaNits[index]),
                        baseline: Double(baseline.lumaNits[index]), v1: Double(v1.lumaNits[index]), v2: Double(v2.lumaNits[index]),
                        baselineHue: b.0, v1Hue: one.0, v2Hue: two.0,
                        baselineChroma: b.1, v1Chroma: one.1, v2Chroma: two.1,
                        baselineSaturation: b.2, v1Saturation: one.2, v2Saturation: two.2
                    ))
                }
            }
        }
        let mapping = binned(samples: samples, bins: 16) { sample in
            (sample.input, sample.reference, sample.baseline, sample.v1, sample.v2)
        }
        let hue = binned(samples: samples, bins: 16) { sample in
            (sample.input, 0, sample.baselineHue, sample.v1Hue, sample.v2Hue)
        }
        let chroma = binned(samples: samples, bins: 16) { sample in
            (sample.input, 0, sample.baselineChroma, sample.v1Chroma, sample.v2Chroma)
        }
        let saturation = binned(samples: samples, bins: 16) { sample in
            (sample.input, 1, sample.baselineSaturation, sample.v1Saturation, sample.v2Saturation)
        }
        let percentiles: [Double] = [0.01, 0.10, 0.25, 0.50, 0.75, 0.90, 0.95, 0.99, 0.999]
        let percentileCurves = percentiles.map { fraction in
            V2DiagnosticPoint(
                x: fraction * 100,
                reference: V2MetricsEvaluator.percentile(samples.map(\.reference), fraction),
                defaultBaseline: V2MetricsEvaluator.percentile(samples.map(\.baseline), fraction),
                calibratedV1: V2MetricsEvaluator.percentile(samples.map(\.v1), fraction),
                candidateV2: V2MetricsEvaluator.percentile(samples.map(\.v2), fraction)
            )
        }
        return V2Diagnostics(
            luminanceMapping: mapping,
            percentileCurves: percentileCurves,
            hueErrorByLuminance: hue,
            chromaErrorByLuminance: chroma,
            saturationRatioByLuminance: saturation
        )
    }

    private func binned<T>(
        samples: [T],
        bins: Int,
        value: (T) -> (Double, Double, Double, Double, Double)
    ) -> [V2DiagnosticPoint] {
        (0..<bins).compactMap { bin in
            let lower = Double(bin) / Double(bins)
            let upper = Double(bin + 1) / Double(bins)
            let values = samples.map(value).filter { $0.0 >= lower && ($0.0 < upper || bin == bins - 1) }
            guard !values.isEmpty else { return nil }
            func average(_ key: ((Double, Double, Double, Double, Double)) -> Double) -> Double {
                values.map(key).reduce(0, +) / Double(values.count)
            }
            return V2DiagnosticPoint(
                x: (lower + upper) * 0.5,
                reference: average { $0.1 }, defaultBaseline: average { $0.2 },
                calibratedV1: average { $0.3 }, candidateV2: average { $0.4 }
            )
        }
    }

    private func sceneCutMetrics(_ scenes: [V2SceneEvaluation]) -> (overshoot: Double, recovery: Double) {
        guard scenes.count > 1 else { return (0, 0) }
        var errors: [Double] = []
        for index in 1..<scenes.count {
            let reference = log((scenes[index].referenceLuminance.p50 + 1) / (scenes[index - 1].referenceLuminance.p50 + 1))
            let generated = log((scenes[index].generatedLuminance.p50 + 1) / (scenes[index - 1].generatedLuminance.p50 + 1))
            errors.append(abs(reference - generated))
        }
        return (errors.reduce(0, +) / Double(errors.count), 0)
    }
}

public final class CalibrationV2Runner {
    public let manifestURL: URL
    public let outputDirectory: URL
    public let configuration: V2SearchConfiguration
    private let device: MTLDevice
    private let guardrail = FrozenIsolationGuard()

    public init(
        manifestURL: URL,
        outputDirectory: URL,
        configuration: V2SearchConfiguration = V2SearchConfiguration(),
        device: MTLDevice? = MTLCreateSystemDefaultDevice()
    ) throws {
        guard let device else { throw CalibrationError.decodeFailed("Metal device unavailable") }
        self.manifestURL = manifestURL
        self.outputDirectory = outputDirectory
        self.configuration = configuration
        self.device = device
    }

    public func run() async throws -> V2FinalReport {
        let manifest = try PairManifest.load(from: manifestURL)
        try SplitManager.validate(manifest)
        let split = DatasetV2Discovery.splitDocument(manifest: manifest, seed: configuration.splitSeed)
        let tuneRecords = manifest.pairs.filter { $0.split == .tune }
        let validationRecords = manifest.pairs.filter { $0.split == .validation }
        let frozenRecords = manifest.pairs.filter { $0.split == .frozen }
        guard tuneRecords.count >= 2, !validationRecords.isEmpty, !frozenRecords.isEmpty else {
            throw CalibrationError.invalidManifest("V2 requires at least 2 tune, 1 validation, and 1 frozen video")
        }

        let audit = try DatasetV2Discovery.audit(rootURL: manifestURL.deletingLastPathComponent())
        try write(audit, name: "data-video-v2-dataset-audit.json")
        try write(split, name: "data-video-v2-split.json")

        let repository = V2PreparedRepository(manifestURL: manifestURL, device: device, configuration: configuration)
        try guardrail.authorize(.tune)
        let tunePrepared = try await repository.prepare(records: tuneRecords)
        try guardrail.authorize(.validation)
        let validationPrepared = try await repository.prepare(records: validationRecords)
        let engine = V2EvaluationEngine(device: device, weights: configuration.weights)
        let defaultParameters = calibrationParameters(.hdr)
        let v1Parameters = calibrationParameters(.calibratedV1)

        v2Log("evaluate default/v1 tune and validation baselines")
        let defaultTune = try engine.evaluate(preparedPairs: tunePrepared, parameters: defaultParameters, label: "default", split: .tune, confidenceThreshold: configuration.alignmentSearchThreshold)
        let v1Tune = try engine.evaluate(preparedPairs: tunePrepared, parameters: v1Parameters, label: "calibrated-v1", split: .tune, confidenceThreshold: configuration.alignmentSearchThreshold)
        let defaultValidation = try engine.evaluate(preparedPairs: validationPrepared, parameters: defaultParameters, label: "default", split: .validation, confidenceThreshold: configuration.alignmentSearchThreshold)
        let v1Validation = try engine.evaluate(preparedPairs: validationPrepared, parameters: v1Parameters, label: "calibrated-v1", split: .validation, confidenceThreshold: configuration.alignmentSearchThreshold)

        var global: [V2CandidateEvaluation] = []
        for index in 0..<configuration.globalCandidates {
            let parameters = globalParameters(index: index, bounds: configuration.bounds)
            let tune = try engine.evaluate(preparedPairs: tunePrepared, parameters: parameters, label: "global-\(index)", split: .tune, confidenceThreshold: configuration.alignmentSearchThreshold)
            global.append(candidate(id: String(format: "global_%03d", index), stage: "global-halton", parameters: parameters, tune: tune, baseline: v1Tune))
            if (index + 1) % 16 == 0 { v2Log("global search \(index + 1)/\(configuration.globalCandidates)") }
        }
        let globalTop = global.filter(\.constraintsPassed).sorted { $0.tune!.metrics.objective < $1.tune!.metrics.objective }.prefix(8)
        guard !globalTop.isEmpty else { throw CalibrationError.invalidCandidate("global search produced no safe candidates") }

        var local: [V2CandidateEvaluation] = []
        let centers = Array(globalTop)
        for index in 0..<configuration.localCandidates {
            let center = centers[index % centers.count].parameters
            let parameters = localParameters(center: center, index: index, bounds: configuration.bounds)
            let tune = try engine.evaluate(preparedPairs: tunePrepared, parameters: parameters, label: "local-\(index)", split: .tune, confidenceThreshold: configuration.alignmentSearchThreshold)
            local.append(candidate(id: String(format: "local_%03d", index), stage: "local-halton-refinement", parameters: parameters, tune: tune, baseline: v1Tune))
            if (index + 1) % 16 == 0 { v2Log("local search \(index + 1)/\(configuration.localCandidates)") }
        }

        var tuneTop = (global + local).filter(\.constraintsPassed).sorted { $0.tune!.metrics.objective < $1.tune!.metrics.objective }
        tuneTop = Array(tuneTop.prefix(configuration.validationTopCount))
        var validationCandidates: [V2CandidateEvaluation] = []
        for var item in tuneTop {
            let validation = try engine.evaluate(preparedPairs: validationPrepared, parameters: item.parameters, label: item.id, split: .validation, confidenceThreshold: configuration.alignmentSearchThreshold)
            item.validation = validation
            let stable60 = item.tune?.metrics.objective ?? .infinity
            let stable70 = try engine.evaluate(preparedPairs: tunePrepared, parameters: item.parameters, label: item.id + "-confidence70", split: .tune, confidenceThreshold: 0.70).metrics.objective
            item.stabilityScore = abs(stable70 - stable60) / max(stable60, 1e-9)
            if !validationSafety(candidate: validation, v1: v1Validation) {
                item.constraintsPassed = false
                item.notes.append("validation safety regression")
            }
            validationCandidates.append(item)
        }
        let selected = validationCandidates.filter(\.constraintsPassed).min { lhs, rhs in
            selectionScore(lhs, v1: v1Validation) < selectionScore(rhs, v1: v1Validation)
        }
        let selectedParameters = selected?.parameters

        var alignmentSensitivity: [V2AlignmentSensitivityReport] = []
        var bootstrap: V2BootstrapReport?
        var sensitivity: V2SensitivityReport?
        var categories: [V2CategoryResult] = []
        var diagnostics: V2Diagnostics?
        if let selectedParameters {
            alignmentSensitivity = try [
                alignmentSensitivityReport(engine: engine, prepared: tunePrepared, split: .tune, defaultParameters: defaultParameters, v1Parameters: v1Parameters, candidate: selectedParameters),
                alignmentSensitivityReport(engine: engine, prepared: validationPrepared, split: .validation, defaultParameters: defaultParameters, v1Parameters: v1Parameters, candidate: selectedParameters)
            ]
            let candidateTune = selected!.tune!
            let candidateValidation = selected!.validation!
            bootstrap = bootstrapReport(defaults: [defaultTune, defaultValidation], v1: [v1Tune, v1Validation], candidate: [candidateTune, candidateValidation])
            sensitivity = try sensitivityReport(engine: engine, tune: tunePrepared, validation: validationPrepared, parameters: selectedParameters)
            categories = categoryReport(defaults: [defaultTune, defaultValidation], v1: [v1Tune, v1Validation], candidate: [candidateTune, candidateValidation])
            diagnostics = try engine.diagnostics(preparedPairs: tunePrepared + validationPrepared, defaultParameters: defaultParameters, v1Parameters: v1Parameters, candidateParameters: selectedParameters, confidenceThreshold: configuration.alignmentSearchThreshold)
        }

        // All search, thresholds, weights, ranking and parameters are now fixed.
        guardrail.finalizeSelection()
        try guardrail.authorize(.frozen)
        try guardrail.markFrozenEvaluated()
        let frozenPrepared = try await repository.prepare(records: frozenRecords)
        let defaultFrozen = try engine.evaluate(preparedPairs: frozenPrepared, parameters: defaultParameters, label: "default", split: .frozen, confidenceThreshold: configuration.alignmentSearchThreshold)
        let v1Frozen = try engine.evaluate(preparedPairs: frozenPrepared, parameters: v1Parameters, label: "calibrated-v1", split: .frozen, confidenceThreshold: configuration.alignmentSearchThreshold)
        let candidateFrozen = try selectedParameters.map {
            try engine.evaluate(preparedPairs: frozenPrepared, parameters: $0, label: "candidate-v2", split: .frozen, confidenceThreshold: configuration.alignmentSearchThreshold)
        }
        if let selectedParameters, let candidateFrozen {
            alignmentSensitivity.append(try alignmentSensitivityReport(engine: engine, prepared: frozenPrepared, split: .frozen, defaultParameters: defaultParameters, v1Parameters: v1Parameters, candidate: selectedParameters))
            let frozenBootstrap = bootstrapReport(defaults: [defaultFrozen], v1: [v1Frozen], candidate: [candidateFrozen])
            bootstrap?.comparisons.append(contentsOf: frozenBootstrap.comparisons)
        }

        let decision = verdict(
            selected: selected,
            defaultTune: defaultTune, v1Tune: v1Tune,
            defaultValidation: defaultValidation, v1Validation: v1Validation,
            defaultFrozen: defaultFrozen, v1Frozen: v1Frozen,
            candidateFrozen: candidateFrozen,
            alignmentSensitivity: alignmentSensitivity
        )
        let report = V2FinalReport(
            version: "calibration-v2",
            generatedAt: ISO8601DateFormatter().string(from: Date()),
            reproducibility: try ReproducibilityV2.collect(manifestURL: manifestURL, configuration: configuration, device: device),
            split: split,
            defaultTune: defaultTune, v1Tune: v1Tune, candidateTune: selected?.tune,
            defaultValidation: defaultValidation, v1Validation: v1Validation, candidateValidation: selected?.validation,
            defaultFrozen: defaultFrozen, v1Frozen: v1Frozen, candidateFrozen: candidateFrozen,
            globalCandidates: global, localCandidates: local, validationCandidates: validationCandidates,
            selectedParameters: selectedParameters,
            alignmentSensitivity: alignmentSensitivity,
            bootstrap: bootstrap,
            sensitivity: sensitivity,
            categories: categories,
            diagnostics: diagnostics,
            verdict: decision.verdict,
            promotionReasons: decision.reasons,
            limitations: [
                "Five valid pairs are still below the preferred 10+ video dataset.",
                "Validation and frozen each contain one video; their video-level bootstrap CI is degenerate.",
                "All references are HLG and use an explicit 1,000-nit system-gamma model, not PQ mastering truth.",
                "Semantic lost-highlight reconstruction is outside this inverse tone-expansion engine."
            ]
        )
        try writeArtifacts(report: report, audit: audit, split: split, prepared: tunePrepared + validationPrepared + frozenPrepared)
        return report
    }

    private func calibrationParameters(_ configuration: HDRConfiguration) -> CalibrationParameters {
        var value = CalibrationParameters(configuration: configuration)
        value.displayHeadroom = value.peakNits / value.paperWhiteNits
        return value
    }

    private func globalParameters(index: Int, bounds: V2ParameterBounds) -> CalibrationParameters {
        let n = index + 1
        let values = zip([2, 3, 5, 7, 11, 13, 17], [
            bounds.paperWhiteNits, bounds.peakNits, bounds.highlightStrength, bounds.contrastStrength,
            bounds.saturationCompensation, bounds.shadowProtection, bounds.temporalStability
        ]).map { base, range in
            range.lowerBound + Float(halton(n, base: base)) * (range.upperBound - range.lowerBound)
        }
        return makeParameters(values)
    }

    private func localParameters(center: CalibrationParameters, index: Int, bounds: V2ParameterBounds) -> CalibrationParameters {
        let ranges = [bounds.paperWhiteNits, bounds.peakNits, bounds.highlightStrength, bounds.contrastStrength, bounds.saturationCompensation, bounds.shadowProtection, bounds.temporalStability]
        let centers: [Float] = [center.paperWhiteNits, center.peakNits, center.highlightStrength, center.contrastStrength, center.saturationCompensation, center.shadowProtection, center.temporalStability]
        let bases = [19, 23, 29, 31, 37, 41, 43]
        let values = (0..<7).map { dimension -> Float in
            let range = ranges[dimension]
            let radius = (range.upperBound - range.lowerBound) * 0.12
            let offset = Float(halton(index + 1, base: bases[dimension]) - 0.5) * 2 * radius
            return min(max(centers[dimension] + offset, range.lowerBound), range.upperBound)
        }
        return makeParameters(values)
    }

    private func makeParameters(_ values: [Float]) -> CalibrationParameters {
        CalibrationParameters(
            paperWhiteNits: values[0], peakNits: values[1], highlightStrength: values[2],
            contrastStrength: values[3], saturationCompensation: values[4], shadowProtection: values[5],
            temporalStability: values[6], displayHeadroom: values[1] / values[0]
        )
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

    private func candidate(id: String, stage: String, parameters: CalibrationParameters, tune: V2DatasetEvaluation, baseline: V2DatasetEvaluation) -> V2CandidateEvaluation {
        let safe = tune.metrics.objective.isFinite &&
            tune.metrics.clippingRatio <= max(0.05, baseline.metrics.clippingRatio + 0.02) &&
            tune.metrics.blackCrushRatio <= baseline.metrics.blackCrushRatio + 0.05 &&
            tune.metrics.hueP95Error <= baseline.metrics.hueP95Error * 1.10 + 0.01 &&
            tune.metrics.invalidSampleCount == 0
        return V2CandidateEvaluation(id: id, stage: stage, parameters: parameters, tune: tune, validation: nil, constraintsPassed: safe, stabilityScore: nil, notes: safe ? [] : ["tune safety constraint rejected"])
    }

    private func validationSafety(candidate: V2DatasetEvaluation, v1: V2DatasetEvaluation) -> Bool {
        candidate.metrics.objective < v1.metrics.objective &&
            candidate.metrics.shadowError <= v1.metrics.shadowError * 1.10 + 0.01 &&
            candidate.metrics.hueP95Error <= v1.metrics.hueP95Error * 1.10 + 0.01 &&
            candidate.metrics.clippingRatio <= max(0.05, v1.metrics.clippingRatio + 0.02) &&
            candidate.metrics.blackCrushRatio <= v1.metrics.blackCrushRatio + 0.03 &&
            candidate.metrics.temporalFlicker <= v1.metrics.temporalFlicker * 1.15 + 0.01
    }

    private func selectionScore(_ candidate: V2CandidateEvaluation, v1: V2DatasetEvaluation) -> Double {
        guard let validation = candidate.validation, let tune = candidate.tune else { return .infinity }
        let worstRegression = zip(validation.videos, v1.videos).map { $0.metrics.objective - $1.metrics.objective }.max() ?? 0
        return validation.metrics.objective + max(worstRegression, 0) * 2 + (candidate.stabilityScore ?? 0) * 0.1 + tune.metrics.objective * 0.05
    }

    private func alignmentSensitivityReport(
        engine: V2EvaluationEngine,
        prepared: [PreparedPair],
        split: DatasetSplit,
        defaultParameters: CalibrationParameters,
        v1Parameters: CalibrationParameters,
        candidate: CalibrationParameters
    ) throws -> V2AlignmentSensitivityReport {
        var points: [V2AlignmentSensitivityPoint] = []
        for threshold in configuration.alignmentSensitivityThresholds {
            let baseline: V2DatasetEvaluation
            let v1: V2DatasetEvaluation
            let v2: V2DatasetEvaluation
            do {
                baseline = try engine.evaluate(preparedPairs: prepared, parameters: defaultParameters, label: "default", split: split, confidenceThreshold: threshold)
                v1 = try engine.evaluate(preparedPairs: prepared, parameters: v1Parameters, label: "v1", split: split, confidenceThreshold: threshold)
                v2 = try engine.evaluate(preparedPairs: prepared, parameters: candidate, label: "v2", split: split, confidenceThreshold: threshold)
            } catch {
                points.append(V2AlignmentSensitivityPoint(
                    threshold: threshold,
                    baselineObjective: nil,
                    v1Objective: nil,
                    candidateObjective: nil,
                    candidateVsV1ImprovementPercent: nil,
                    evaluatedFrames: 0,
                    failureReason: error.localizedDescription
                ))
                continue
            }
            let improvement: Double?
            if v1.metrics.objective > 0 {
                let old = v1.metrics.objective
                let new = v2.metrics.objective
                improvement = (old - new) / old * 100
            } else { improvement = nil }
            points.append(V2AlignmentSensitivityPoint(
                threshold: threshold,
                baselineObjective: baseline.metrics.objective,
                v1Objective: v1.metrics.objective,
                candidateObjective: v2.metrics.objective,
                candidateVsV1ImprovementPercent: improvement,
                evaluatedFrames: v2.frameCount,
                failureReason: nil
            ))
        }
        let highConfidence = points.filter { $0.threshold >= 0.70 && $0.evaluatedFrames > 0 }
        let robust = !highConfidence.isEmpty && highConfidence.allSatisfy { ($0.candidateVsV1ImprovementPercent ?? -1) > 0 }
        return V2AlignmentSensitivityReport(
            split: split,
            points: points,
            robust: robust,
            notes: highConfidence.isEmpty ? ["No frames survived >=0.70; alignment sensitivity is inconclusive."] : []
        )
    }

    private func bootstrapReport(defaults: [V2DatasetEvaluation], v1: [V2DatasetEvaluation], candidate: [V2DatasetEvaluation]) -> V2BootstrapReport {
        let defaultVideos = defaults.flatMap(\.videos)
        let v1Videos = v1.flatMap(\.videos)
        let candidateVideos = candidate.flatMap(\.videos)
        return V2BootstrapReport(comparisons: [
            bootstrap(name: "v2_vs_default", baseline: defaultVideos, candidate: candidateVideos),
            bootstrap(name: "v2_vs_calibrated_v1", baseline: v1Videos, candidate: candidateVideos)
        ], notes: ["Video-level paired resampling only; frames/scenes are not treated as independent samples."])
    }

    private func bootstrap(name: String, baseline: [V2VideoEvaluation], candidate: [V2VideoEvaluation]) -> V2BootstrapComparison {
        let baselineByID = Dictionary(uniqueKeysWithValues: baseline.map { ($0.pairID, $0.metrics.objective) })
        let paired = candidate.compactMap { item -> (Double, Double)? in baselineByID[item.pairID].map { ($0, item.metrics.objective) } }
        guard !paired.isEmpty else {
            return V2BootstrapComparison(comparison: name, videoCount: 0, resamples: 0, meanImprovementPercent: 0, medianImprovementPercent: 0, lower95Percent: 0, upper95Percent: 0, probabilityCandidateBetter: 0, statisticallyLimited: true)
        }
        let stableNameHash = name.unicodeScalars.reduce(UInt64(14_695_981_039_346_656_037)) { value, scalar in
            (value ^ UInt64(scalar.value)) &* 1_099_511_628_211
        }
        var random = DeterministicRandom(seed: configuration.searchSeed ^ stableNameHash)
        var samples: [Double] = []
        for _ in 0..<configuration.bootstrapSamples {
            var values: [Double] = []
            for _ in paired.indices {
                let index = min(paired.count - 1, Int(random.nextUnit() * Float(paired.count)))
                let pair = paired[index]
                values.append((pair.0 - pair.1) / max(pair.0, 1e-9) * 100)
            }
            samples.append(values.reduce(0, +) / Double(values.count))
        }
        let direct = paired.map { ($0.0 - $0.1) / max($0.0, 1e-9) * 100 }.sorted()
        return V2BootstrapComparison(
            comparison: name, videoCount: paired.count, resamples: configuration.bootstrapSamples,
            meanImprovementPercent: direct.reduce(0, +) / Double(direct.count),
            medianImprovementPercent: V2MetricsEvaluator.percentile(direct, 0.5),
            lower95Percent: V2MetricsEvaluator.percentile(samples, 0.025),
            upper95Percent: V2MetricsEvaluator.percentile(samples, 0.975),
            probabilityCandidateBetter: Double(samples.filter { $0 > 0 }.count) / Double(samples.count),
            statisticallyLimited: paired.count < 5
        )
    }

    private func sensitivityReport(engine: V2EvaluationEngine, tune: [PreparedPair], validation: [PreparedPair], parameters: CalibrationParameters) throws -> V2SensitivityReport {
        let baseTune = try engine.evaluate(preparedPairs: tune, parameters: parameters, label: "sensitivity-base", split: .tune, confidenceThreshold: configuration.alignmentSearchThreshold)
        let baseValidation = try engine.evaluate(preparedPairs: validation, parameters: parameters, label: "sensitivity-base", split: .validation, confidenceThreshold: configuration.alignmentSearchThreshold)
        let baselineObjective = combinedObjective([baseTune, baseValidation])
        let names = ["paperWhiteNits", "peakNits", "highlightStrength", "contrastStrength", "saturationCompensation", "shadowProtection", "temporalStability"]
        var points: [V2SensitivityPoint] = []
        for name in names {
            for percent in [-5.0, -2.0, 2.0, 5.0] {
                var changed = parameters
                perturb(&changed, name: name, factor: Float(1 + percent / 100))
                changed.displayHeadroom = changed.peakNits / changed.paperWhiteNits
                _ = try changed.configuration()
                let tuneResult = try engine.evaluate(preparedPairs: tune, parameters: changed, label: "sensitivity", split: .tune, confidenceThreshold: configuration.alignmentSearchThreshold)
                let validationResult = try engine.evaluate(preparedPairs: validation, parameters: changed, label: "sensitivity", split: .validation, confidenceThreshold: configuration.alignmentSearchThreshold)
                let objective = combinedObjective([tuneResult, validationResult])
                points.append(V2SensitivityPoint(parameter: name, perturbationPercent: percent, objective: objective, deltaPercent: (objective - baselineObjective) / max(baselineObjective, 1e-9) * 100))
            }
        }
        let maximum = points.map { abs($0.deltaPercent) }.max() ?? 0
        return V2SensitivityReport(baselineObjective: baselineObjective, points: points, maximumAbsoluteDeltaPercent: maximum, plateauLike: maximum < 10)
    }

    private func perturb(_ value: inout CalibrationParameters, name: String, factor: Float) {
        switch name {
        case "paperWhiteNits": value.paperWhiteNits *= factor
        case "peakNits": value.peakNits *= factor
        case "highlightStrength": value.highlightStrength *= factor
        case "contrastStrength": value.contrastStrength *= factor
        case "saturationCompensation": value.saturationCompensation *= factor
        case "shadowProtection": value.shadowProtection *= factor
        case "temporalStability": value.temporalStability *= factor
        default: break
        }
    }

    private func combinedObjective(_ values: [V2DatasetEvaluation]) -> Double {
        let videos = values.flatMap(\.videos)
        return videos.isEmpty ? .infinity : videos.map { $0.metrics.objective }.reduce(0, +) / Double(videos.count)
    }

    private func categoryReport(defaults: [V2DatasetEvaluation], v1: [V2DatasetEvaluation], candidate: [V2DatasetEvaluation]) -> [V2CategoryResult] {
        let defaultVideos = defaults.flatMap(\.videos), v1Videos = v1.flatMap(\.videos), candidateVideos = candidate.flatMap(\.videos)
        let categories = Set(candidateVideos.flatMap(\.categories))
        return categories.sorted().compactMap { category in
            let ids = Set(candidateVideos.filter { $0.categories.contains(category) }.map(\.pairID))
            guard !ids.isEmpty else { return nil }
            func average(_ videos: [V2VideoEvaluation]) -> Double {
                let values = videos.filter { ids.contains($0.pairID) }.map { $0.metrics.objective }
                return values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)
            }
            let d = average(defaultVideos), one = average(v1Videos), two = average(candidateVideos)
            return V2CategoryResult(category: category, videoCount: ids.count, defaultObjective: d, v1Objective: one, candidateObjective: two, candidateVsV1ImprovementPercent: one > 0 ? (one - two) / one * 100 : 0)
        }
    }

    private func verdict(
        selected: V2CandidateEvaluation?,
        defaultTune: V2DatasetEvaluation, v1Tune: V2DatasetEvaluation,
        defaultValidation: V2DatasetEvaluation, v1Validation: V2DatasetEvaluation,
        defaultFrozen: V2DatasetEvaluation, v1Frozen: V2DatasetEvaluation,
        candidateFrozen: V2DatasetEvaluation?,
        alignmentSensitivity: [V2AlignmentSensitivityReport]
    ) -> (verdict: CalibrationV2Verdict, reasons: [String]) {
        guard let selected, let candidateTune = selected.tune, let candidateValidation = selected.validation, let candidateFrozen else {
            return (.keepV1, ["No candidate passed Tune/Validation safety selection."])
        }
        var reasons: [String] = []
        func improvement(_ old: Double, _ new: Double) -> Double {
            V4PromotionMath.improvementRatio(baseline: old, candidate: new)
        }
        let tuneDefault = improvement(defaultTune.metrics.objective, candidateTune.metrics.objective)
        let tuneV1 = improvement(v1Tune.metrics.objective, candidateTune.metrics.objective)
        let validationDefault = improvement(defaultValidation.metrics.objective, candidateValidation.metrics.objective)
        let validationV1 = improvement(v1Validation.metrics.objective, candidateValidation.metrics.objective)
        let frozenDefault = improvement(defaultFrozen.metrics.objective, candidateFrozen.metrics.objective)
        let frozenV1 = improvement(v1Frozen.metrics.objective, candidateFrozen.metrics.objective)
        reasons.append(String(format: "Tune improvement: %.2f%% vs default, %.2f%% vs v1", tuneDefault * 100, tuneV1 * 100))
        reasons.append(String(format: "Validation improvement: %.2f%% vs default, %.2f%% vs v1", validationDefault * 100, validationV1 * 100))
        reasons.append(String(format: "Frozen improvement: %.2f%% vs default, %.2f%% vs v1", frozenDefault * 100, frozenV1 * 100))
        let metricsSafe = candidateFrozen.metrics.shadowError <= v1Frozen.metrics.shadowError * 1.10 + 0.01 &&
            candidateFrozen.metrics.hueP95Error <= v1Frozen.metrics.hueP95Error * 1.10 + 0.01 &&
            candidateFrozen.metrics.clippingRatio <= max(0.05, v1Frozen.metrics.clippingRatio + 0.02) &&
            candidateFrozen.metrics.blackCrushRatio <= v1Frozen.metrics.blackCrushRatio + 0.03 &&
            candidateFrozen.metrics.temporalFlicker <= v1Frozen.metrics.temporalFlicker * 1.15 + 0.01
        let alignmentRobust = alignmentSensitivity.filter { $0.split != .frozen }.allSatisfy(\.robust)
        if tuneDefault > 0, tuneV1 > 0, validationDefault > 0, validationV1 > 0,
           frozenDefault > 0, frozenV1 >= 0.05, metricsSafe, alignmentRobust {
            return (.promote, reasons + ["All promotion gates passed."])
        }
        if frozenV1 > 0 && metricsSafe {
            return (.keepV1, reasons + ["Candidate improved but did not clear every 5%/alignment promotion gate."])
        }
        return (.reject, reasons + ["Frozen or safety regression failed the promotion gate."])
    }

    private func writeArtifacts(report: V2FinalReport, audit: V2DatasetAudit, split: V2SplitDocument, prepared: [PreparedPair]) throws {
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        try write(audit, name: "data-video-v2-dataset-audit.json")
        try write(split, name: "data-video-v2-split.json")
        try write(Dictionary(uniqueKeysWithValues: prepared.map { ($0.record.id, V2MetricsEvaluator.alignmentStatistics(prepared: $0)) }), name: "data-video-v2-alignment.json")
        try write(["defaultTune": report.defaultTune, "v1Tune": report.v1Tune], name: "data-video-v2-baseline.json")
        try write(["global": report.globalCandidates, "local": report.localCandidates], name: "data-video-v2-search.json")
        try write(report.validationCandidates, name: "data-video-v2-validation.json")
        try write(["default": report.defaultFrozen, "v1": report.v1Frozen, "candidate": report.candidateFrozen], name: "data-video-v2-frozen.json")
        try write(report.bootstrap, name: "data-video-v2-bootstrap.json")
        try write(report.sensitivity, name: "data-video-v2-sensitivity.json")
        try write(report.categories, name: "data-video-v2-category-analysis.json")
        try write(report.diagnostics, name: "data-video-v2-diagnostics.json")
        try write(report, name: "data-video-v2-final.json")
        let export = V2PresetExport(
            version: "calibrated-v2", promoted: report.verdict == .promote,
            verdict: report.verdict.rawValue, parameters: report.selectedParameters,
            sourceReport: "data-video-v2-final.json"
        )
        try write(export, name: "calibrated-v2.json")
        try writeMarkdown(report)
        try writeDiagnosticsCSV(report.diagnostics)
    }

    private func write<T: Encodable>(_ value: T, name: String) throws {
        let url = outputDirectory.appendingPathComponent(name)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "Infinity", negativeInfinity: "-Infinity", nan: "NaN")
        try encoder.encode(value).write(to: url)
    }

    private func writeMarkdown(_ report: V2FinalReport) throws {
        func value(_ evaluation: V2DatasetEvaluation?) -> String { evaluation.map { String(format: "%.6f", $0.metrics.objective) } ?? "NOT MEASURED" }
        let text = """
        # SDR→HDR Calibrated V2 report

        Verdict: `\(report.verdict.rawValue)`

        ## Split

        - Tune: \(report.split.tune.joined(separator: ", "))
        - Validation: \(report.split.validation.joined(separator: ", "))
        - Frozen: \(report.split.frozen.joined(separator: ", "))

        ## Objectives

        | Split | Default | Calibrated V1 | Candidate V2 |
        |---|---:|---:|---:|
        | Tune | \(value(report.defaultTune)) | \(value(report.v1Tune)) | \(value(report.candidateTune)) |
        | Validation | \(value(report.defaultValidation)) | \(value(report.v1Validation)) | \(value(report.candidateValidation)) |
        | Frozen | \(value(report.defaultFrozen)) | \(value(report.v1Frozen)) | \(value(report.candidateFrozen)) |

        ## Decision

        \(report.promotionReasons.map { "- " + $0 }.joined(separator: "\n"))

        ## Limitations

        \(report.limitations.map { "- " + $0 }.joined(separator: "\n"))
        """
        try text.data(using: .utf8)?.write(to: outputDirectory.appendingPathComponent("data-video-v2-report.md"))
    }

    private func writeDiagnosticsCSV(_ diagnostics: V2Diagnostics?) throws {
        guard let diagnostics else { return }
        var rows = ["curve,x,reference,default,calibrated_v1,candidate_v2"]
        func append(_ label: String, _ points: [V2DiagnosticPoint]) {
            rows += points.map { "\(label),\($0.x),\($0.reference),\($0.defaultBaseline),\($0.calibratedV1),\($0.candidateV2)" }
        }
        append("luminance_mapping", diagnostics.luminanceMapping)
        append("percentiles", diagnostics.percentileCurves)
        append("hue_error", diagnostics.hueErrorByLuminance)
        append("chroma_error", diagnostics.chromaErrorByLuminance)
        append("saturation_ratio", diagnostics.saturationRatioByLuminance)
        try rows.joined(separator: "\n").appending("\n").data(using: .utf8)?.write(to: outputDirectory.appendingPathComponent("data-video-v2-diagnostics.csv"))
    }
}

private struct V2PresetExport: Codable {
    let version: String
    let promoted: Bool
    let verdict: String
    let parameters: CalibrationParameters?
    let sourceReport: String
}
