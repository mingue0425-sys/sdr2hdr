import CoreVideo
import Foundation
import HDRCore
import Metal

public struct V62ScalarDemandPoint: Codable, Sendable {
    public let scale: Double
    public let effectiveLowMidCoefficient: Double
    public let toneOnlyObjective: Double
    public let signedError: V61SignedErrorSummary
    public let signedDiffuseMidtoneError: V61SignedErrorSummary
    public let highlightError: Double
    public let shadowError: Double
}

public struct V62SceneDemand: Codable, Sendable {
    public let pairID: String
    public let sceneID: String
    public let split: DatasetSplit
    public let transfer: String
    public let contentFamily: String
    public let categories: [String]
    public let sampleCount: Int
    public let features: HDRV62SceneFeatures
    public let points: [V62ScalarDemandPoint]
    public let bestScale: Double
    public let secondBestScale: Double?
    public let bestObjective: Double
    public let objectiveGap: Double
    public let objectiveCurvature: Double
    public let acceptableScaleLow: Double
    public let acceptableScaleHigh: Double
    public let reliabilityWeight: Double
}

public struct V62FeatureCorrelation: Codable, Sendable {
    public let split: DatasetSplit
    public let feature: String
    public let target: String
    public let result: V61CorrelationResult
}

public struct V62MatchedSceneComparison: Codable, Sendable {
    public let leftPairID: String
    public let leftSceneID: String
    public let leftTransfer: String
    public let rightPairID: String
    public let rightSceneID: String
    public let rightTransfer: String
    public let featureDistance: Double
    public let leftBestScale: Double
    public let rightBestScale: Double
    public let bestScaleDifference: Double
}

public struct V62TransferStratum: Codable, Sendable {
    public let split: DatasetSplit
    public let transfer: String
    public let candidate: String
    public let sceneCount: Int
    public let objective: Double
    public let diffuseSignedError: Double
    public let diffusePositiveOvershoot: Double
    public let diffuseNegativeUndershoot: Double
    public let highlightError: Double
    public let shadowError: Double
}

public struct V62FamilyRobustness: Codable, Sendable {
    public let family: String
    public let split: DatasetSplit
    public let candidate: String
    public let sceneCount: Int
    public let objective: Double
    public let demandPredictionRMSE: Double?
    public let fitExcludedFamily: Bool
}

public struct V62BudgetStability: Codable, Sendable {
    public let candidate: String
    public let sceneCount: Int
    public let meanFrameDelta: Double
    public let p95FrameDelta: Double
    public let maximumFrameDelta: Double
    public let sceneCutRecoveryMeasured: Bool
}

public struct V62CandidateResult: Codable, Sendable {
    public let candidate: String
    public let shortName: String
    public let controller: HDRV62ExpansionController?
    public let parameters: HDRV62ControllerParameters?
    public let tune: V2DatasetEvaluation?
    public let validation: V2DatasetEvaluation?
}

public struct V62SceneAdaptiveExpansionReport: Codable, Sendable {
    public let schemaVersion: String
    public let productionCommit: String
    public let manifestPath: String
    public let allowedSplits: [DatasetSplit]
    public let allowedPairIDs: [String]
    public let preparedPairIDs: [String]
    public let skippedPairs: [V61SkippedPair]
    public let protectedMediaAccessed: Bool
    public let frozenObjectiveEvaluations: Int
    public let virginFrozenObjectiveEvaluations: Int
    public let objectiveEvaluationsOutsideAllowedSplits: Int
    public let demandScales: [Double]
    public let demandScenes: [V62SceneDemand]
    public let featureCorrelations: [V62FeatureCorrelation]
    public let matchedSceneComparisons: [V62MatchedSceneComparison]
    public let observableTransferLeaveOneOutAccuracy: Double?
    public let transferStratification: [V62TransferStratum]
    public let familyRobustness: [V62FamilyRobustness]
    public let budgetStability: [V62BudgetStability]
    public let candidates: [V62CandidateResult]
    public let parameterFreezeNote: String
    public let verdict: String

    init(
        manifestPath: String,
        allowedPairIDs: [String],
        preparedPairIDs: [String],
        skippedPairs: [V61SkippedPair],
        demandScenes: [V62SceneDemand],
        featureCorrelations: [V62FeatureCorrelation],
        matchedSceneComparisons: [V62MatchedSceneComparison],
        observableTransferLeaveOneOutAccuracy: Double?,
        transferStratification: [V62TransferStratum],
        familyRobustness: [V62FamilyRobustness],
        budgetStability: [V62BudgetStability],
        candidates: [V62CandidateResult],
        parameterFreezeNote: String,
        verdict: String
    ) {
        schemaVersion = "v6.2-scene-adaptive-expansion-1"
        productionCommit = "d97c3d3c8fbf71447ff8b94a7fa7a77c5d25bebf"
        self.manifestPath = manifestPath
        allowedSplits = [.tune, .validation]
        self.allowedPairIDs = allowedPairIDs
        self.preparedPairIDs = preparedPairIDs
        self.skippedPairs = skippedPairs
        protectedMediaAccessed = false
        frozenObjectiveEvaluations = 0
        virginFrozenObjectiveEvaluations = 0
        objectiveEvaluationsOutsideAllowedSplits = 0
        demandScales = [0, 0.125, 0.25, 0.375, 0.50, 0.625, 0.75, 0.875, 1.0]
        self.demandScenes = demandScenes
        self.featureCorrelations = featureCorrelations
        self.matchedSceneComparisons = matchedSceneComparisons
        self.observableTransferLeaveOneOutAccuracy = observableTransferLeaveOneOutAccuracy
        self.transferStratification = transferStratification
        self.familyRobustness = familyRobustness
        self.budgetStability = budgetStability
        self.candidates = candidates
        self.parameterFreezeNote = parameterFreezeNote
        self.verdict = verdict
    }
}

private struct V62Frame {
    let pairID: String
    let sceneID: String
    let split: DatasetSplit
    let transfer: String
    let categories: [String]
    let timestampSeconds: Double
    let pixelBuffer: CVPixelBuffer
    let reference: ReferenceFrame
    let sourceLuma: [Float]
    /// The exact 16x9/16-bin causal estimator input for this frame.  Scene
    /// feature aggregates must use this grid rather than the denser metric
    /// sampling grid, otherwise the offline controller fit observes a signal
    /// that production cannot observe.
    let featureLuma: [Float]
    let frameStatistics: HDRSceneStatistics
    let confidence: Double
}

private struct V62SceneContext {
    let pairID: String
    let sceneID: String
    let split: DatasetSplit
    let transfer: String
    let contentFamily: String
    let categories: [String]
    let alignment: V2AlignmentStatistics
    let statistics: HDRSceneStatistics
    let features: HDRV62SceneFeatures
    let frames: [V62Frame]
}

private struct V62PreparedContext {
    let allowedPairs: [V4PairRecord]
    let preparedPairs: [PreparedPair]
    let skipped: [V61SkippedPair]
}

private struct V62ScalarValues {
    let objective: Double
    let signedAll: V61SignedErrorSummary
    let signedDiffuse: V61SignedErrorSummary
    let highlightError: Double
    let shadowError: Double
}

/// Tune/Validation-only scene-adaptive development runner.  The reference
/// transfer is used for offline stratification only; it is never passed to a
/// runtime controller or encoded in a candidate configuration.
public enum V62SceneAdaptiveExpansionRunner {
    public static func run(
        manifestURL: URL,
        outputURL: URL? = nil,
        device suppliedDevice: MTLDevice? = MTLCreateSystemDefaultDevice()
    ) async throws -> V62SceneAdaptiveExpansionReport {
        guard let device = suppliedDevice else {
            throw CalibrationError.decodeFailed("Metal device unavailable")
        }
        let context = try await prepareContext(manifestURL: manifestURL, device: device)
        let scenes = try makeSceneContexts(context: context)
        guard !scenes.isEmpty else {
            throw CalibrationError.incompleteEvaluation("no development scenes were prepared")
        }

        let weights = V4CalibrationConfiguration().weights
        let demand = makeDemand(scenes: scenes, weights: weights)
        let tuneDemand = demand.filter { $0.split == .tune }
        let fitted: [HDRV62ExpansionController: HDRV62ControllerParameters] = Dictionary(
            uniqueKeysWithValues: HDRV62ExpansionController.allCases.map { controller in
                (controller, fitParameters(controller: controller, scenes: tuneDemand))
            }
        )

        var configurations: [(String, String, HDRV62ExpansionController?, HDRV62ControllerParameters?, HDRConfiguration)] = [
            ("v4-baseline", "V4_BASELINE", nil, nil, .calibratedV4),
            (
                HDRV6ToneCurveCandidate.noLowMid.rawValue,
                "V6_NO_LOWMID",
                nil,
                nil,
                HDRV6ToneCurveCandidate.noLowMid.configuration()
            ),
            (
                HDRV6ToneCurveCandidate.bandLimited045.rawValue,
                "V6_BL045",
                nil,
                nil,
                HDRV6ToneCurveCandidate.bandLimited045.configuration()
            )
        ]
        configurations += HDRV62ToneCurveCandidate.allCases.map { candidate in
            let parameters = fitted[candidate.controller] ?? .developmentDefault
            return (
                candidate.rawValue,
                candidate.shortName,
                candidate.controller,
                parameters,
                candidate.configuration(parameters: parameters)
            )
        }

        var candidateResults: [V62CandidateResult] = []
        for (label, shortName, controller, parameters, configuration) in configurations {
            let evaluation = try evaluateCandidate(
                label: label,
                scenes: scenes,
                configuration: configuration,
                weights: weights,
                device: device
            )
            candidateResults.append(V62CandidateResult(
                candidate: label,
                shortName: shortName,
                controller: controller,
                parameters: parameters,
                tune: evaluation.tune,
                validation: evaluation.validation
            ))
        }

        let correlations = makeFeatureCorrelations(demand)
        let matched = makeMatchedComparisons(demand)
        let transferAccuracy = transferLeaveOneOutAccuracy(demand)
        let transferStratification = makeTransferStratification(candidateResults, scenes: scenes)
        let familyRobustness = makeFamilyRobustness(
            candidateResults: candidateResults,
            demand: demand,
            scenes: scenes,
            fitted: fitted,
            weights: weights
        )
        let budgetStability = makeBudgetStability(scenes: scenes, fitted: fitted)
        let verdict = selectVerdict(candidateResults: candidateResults)
        let report = V62SceneAdaptiveExpansionReport(
            manifestPath: manifestURL.standardizedFileURL.path,
            allowedPairIDs: context.allowedPairs.map(\.id),
            preparedPairIDs: context.preparedPairs.map { $0.record.id },
            skippedPairs: context.skipped,
            demandScenes: demand,
            featureCorrelations: correlations,
            matchedSceneComparisons: matched,
            observableTransferLeaveOneOutAccuracy: transferAccuracy,
            transferStratification: transferStratification,
            familyRobustness: familyRobustness,
            budgetStability: budgetStability,
            candidates: candidateResults,
            parameterFreezeNote: "Controller parameters were fit on Tune demand targets and held fixed before the Validation evaluation.",
            verdict: verdict
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

    private static func prepareContext(
        manifestURL: URL,
        device: MTLDevice
    ) async throws -> V62PreparedContext {
        let sourceManifest = try JSONDecoder().decode(
            V4Manifest.self,
            from: Data(contentsOf: manifestURL)
        )
        let allowedPairs = sourceManifest.pairs.filter {
            ($0.split == .tune || $0.split == .validation) && !$0.virginFrozen
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
                print("[V62Adaptive] prepare \(record.id)")
                prepared.append(try await evaluator.prepare(record: record, manifestURL: manifestURL))
            } catch {
                skipped.append(V61SkippedPair(
                    pairID: record.id,
                    split: record.split,
                    reason: String(describing: error)
                ))
                print("[V62Adaptive] skip \(record.id): \(error)")
            }
        }
        guard !prepared.isEmpty else {
            throw CalibrationError.incompleteEvaluation("no allowed pair could be prepared")
        }
        return V62PreparedContext(
            allowedPairs: allowedPairs,
            preparedPairs: prepared,
            skipped: skipped
        )
    }

    private static func makeSceneContexts(
        context: V62PreparedContext
    ) throws -> [V62SceneContext] {
        let familyByID = Dictionary(uniqueKeysWithValues: context.allowedPairs.map {
            ($0.id, $0.contentFamily ?? $0.group ?? "UNSPECIFIED")
        })
        let categoriesByID = Dictionary(uniqueKeysWithValues: context.allowedPairs.map {
            ($0.id, $0.contentCategory)
        })
        var result: [V62SceneContext] = []
        for prepared in context.preparedPairs {
            let accepted = prepared.matches
                .filter { $0.match.confidence >= 0 }
                .sorted { ($0.match.sdrSequencePosition ?? .max) < ($1.match.sdrSequencePosition ?? .max) }
            var framesByScene: [String: [V62Frame]] = [:]
            for item in accepted {
                let scene = prepared.scenes.first { scene in
                    guard let position = item.match.sdrSequencePosition else { return false }
                    return scene.contains(sequencePosition: position)
                }
                let sceneID = scene?.id ?? "unassigned"
                let sourceLuma = try OfflinePixelSampler.linearLumaGrid(
                    pixelBuffer: item.sdr.pixelBuffer,
                    width: item.reference.width,
                    height: item.reference.height
                )
                let featureGrid = try OfflinePixelSampler.linearLumaGrid(
                    pixelBuffer: item.sdr.pixelBuffer,
                    width: HDRSceneStatistics.productionProxyWidth,
                    height: HDRSceneStatistics.productionProxyHeight
                )
                let frame = V62Frame(
                    pairID: prepared.record.id,
                    sceneID: sceneID,
                    split: prepared.record.split,
                    transfer: prepared.referenceTransfer.canonicalName,
                    categories: categoriesByID[prepared.record.id] ?? [],
                    timestampSeconds: item.match.sdrTimeSeconds,
                    pixelBuffer: item.sdr.pixelBuffer,
                    reference: item.reference,
                    sourceLuma: sourceLuma,
                    featureLuma: featureGrid,
                    frameStatistics: HDRSceneStatistics(productionLinearSamples: featureGrid),
                    confidence: item.match.confidence
                )
                framesByScene[sceneID, default: []].append(frame)
            }
            for sceneID in framesByScene.keys.sorted() {
                guard let frames = framesByScene[sceneID], !frames.isEmpty else { continue }
                let sceneSamples = frames.flatMap(\.featureLuma)
                let statistics = HDRSceneStatistics(productionLinearSamples: sceneSamples)
                result.append(V62SceneContext(
                    pairID: prepared.record.id,
                    sceneID: sceneID,
                    split: prepared.record.split,
                    transfer: prepared.referenceTransfer.canonicalName,
                    contentFamily: familyByID[prepared.record.id] ?? "UNSPECIFIED",
                    categories: categoriesByID[prepared.record.id] ?? [],
                    alignment: V2MetricsEvaluator.alignmentStatistics(prepared: prepared),
                    statistics: statistics,
                    features: HDRV62SceneFeatures(statistics: statistics),
                    frames: frames
                ))
            }
        }
        return result.sorted {
            $0.pairID == $1.pairID ? $0.sceneID < $1.sceneID : $0.pairID < $1.pairID
        }
    }

    private static func makeDemand(
        scenes: [V62SceneContext],
        weights: V2ObjectiveWeights
    ) -> [V62SceneDemand] {
        let scales: [Double] = [0, 0.125, 0.25, 0.375, 0.50, 0.625, 0.75, 0.875, 1.0]
        return scenes.map { scene in
            let points = scales.map { scale in
                let generated = scene.frames.flatMap { frame in
                    frame.sourceLuma.map { source in
                        HDRDiagnosticToneSweep.v4Breakdown(
                            luminance: source,
                            configuration: .calibratedV4,
                            temporalAdaptation: 1,
                            sceneShadowFloor: scene.statistics.shadowFloor,
                            sceneShadowTop: scene.statistics.shadowTop,
                            sceneStatisticsValid: true,
                            lowMidCoefficient: Float(0.08 * scale)
                        ).expandedLuminance * HDRConfiguration.calibratedV4.paperWhiteNits
                    }
                }.map(Double.init)
                let reference = scene.frames.flatMap(\.reference.lumaNits).map(Double.init)
                let source = scene.frames.flatMap(\.sourceLuma).map(Double.init)
                let scalar = scalarMetrics(
                    reference: reference,
                    generated: generated,
                    source: source,
                    weights: weights
                )
                return V62ScalarDemandPoint(
                    scale: scale,
                    effectiveLowMidCoefficient: 0.08 * scale,
                    toneOnlyObjective: scalar.objective,
                    signedError: scalar.signedAll,
                    signedDiffuseMidtoneError: scalar.signedDiffuse,
                    highlightError: scalar.highlightError,
                    shadowError: scalar.shadowError
                )
            }
            let ordered = points.sorted { $0.toneOnlyObjective < $1.toneOnlyObjective }
            let best = ordered[0]
            let second = ordered.dropFirst().first
            let bestIndex = points.firstIndex { $0.scale == best.scale } ?? 0
            let neighbourValues = [
                bestIndex > 0 ? points[bestIndex - 1].toneOnlyObjective : best.toneOnlyObjective,
                bestIndex + 1 < points.count ? points[bestIndex + 1].toneOnlyObjective : best.toneOnlyObjective
            ]
            let curvature = neighbourValues.reduce(0, +) / 2 - best.toneOnlyObjective
            let gap = max((second?.toneOnlyObjective ?? best.toneOnlyObjective) - best.toneOnlyObjective, 0)
            let tolerance = max(abs(best.toneOnlyObjective) * 0.02, 0.0001)
            let reliability = min(max(gap / tolerance, 0), 1)
            let acceptable = points.filter { $0.toneOnlyObjective <= best.toneOnlyObjective + tolerance }
            return V62SceneDemand(
                pairID: scene.pairID,
                sceneID: scene.sceneID,
                split: scene.split,
                transfer: scene.transfer,
                contentFamily: scene.contentFamily,
                categories: scene.categories,
                sampleCount: scene.frames.reduce(0) { $0 + $1.sourceLuma.count },
                features: scene.features,
                points: points,
                bestScale: Double(best.scale),
                secondBestScale: second.map { Double($0.scale) },
                bestObjective: best.toneOnlyObjective,
                objectiveGap: gap,
                objectiveCurvature: curvature,
                acceptableScaleLow: acceptable.map(\.scale).min() ?? best.scale,
                acceptableScaleHigh: acceptable.map(\.scale).max() ?? best.scale,
                reliabilityWeight: reliability
            )
        }
    }

    private static func scalarMetrics(
        reference: [Double],
        generated: [Double],
        source: [Double],
        weights: V2ObjectiveWeights
    ) -> V62ScalarValues {
        let count = min(reference.count, min(generated.count, source.count))
        let ref = Array(reference.prefix(count))
        let gen = Array(generated.prefix(count))
        let input = Array(source.prefix(count))
        let signed = (0..<count).map { gen[$0] - ref[$0] }
        let logSigned = (0..<count).map { log((gen[$0] + 1) / (ref[$0] + 1)) }
        let diffuseIndices = (0..<count).filter { (0.15...0.45).contains(input[$0]) }
        let signedDiffuse = V61SignedErrorSummary(
            signedValues: diffuseIndices.map { signed[$0] },
            signedLogValues: diffuseIndices.map { logSigned[$0] }
        )
        let luma = meanAbsLog(ref, gen)
        let absolute = V61ErrorAttributionMath.average((0..<count).map { abs(gen[$0] - ref[$0]) / 1_000 })
        let midtone = percentileRegionError(ref, gen, lower: 0.10, upper: 0.90)
        let diffuseWhite = percentileRegionError(ref, gen, lower: 0.75, upper: 0.95)
        let highlight = percentileRegionError(ref, gen, lower: 0.90, upper: 1.00)
        let shadow = percentileRegionError(ref, gen, lower: 0.00, upper: 0.10)
        let objective = weights.luminance * luma +
            weights.absoluteNits * absolute +
            weights.midtone * midtone +
            weights.diffuseWhite * diffuseWhite +
            weights.highlight * highlight +
            weights.shadow * shadow
        return V62ScalarValues(
            objective: objective,
            signedAll: V61SignedErrorSummary(signedValues: signed, signedLogValues: logSigned),
            signedDiffuse: signedDiffuse,
            highlightError: highlight,
            shadowError: shadow
        )
    }

    private static func meanAbsLog(_ reference: [Double], _ generated: [Double]) -> Double {
        let count = min(reference.count, generated.count)
        guard count > 0 else { return 0 }
        return V61ErrorAttributionMath.average((0..<count).map {
            abs(log((generated[$0] + 1) / (reference[$0] + 1)))
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
        let low = V61ErrorAttributionMath.percentile(reference, lower)
        let high = V61ErrorAttributionMath.percentile(reference, upper)
        let indices = (0..<count).filter { reference[$0] >= low && reference[$0] <= high }
        guard !indices.isEmpty else { return 0 }
        return V61ErrorAttributionMath.average(indices.map {
            abs(log((generated[$0] + 1) / (reference[$0] + 1)))
        })
    }

    private static func fitParameters(
        controller: HDRV62ExpansionController,
        scenes: [V62SceneDemand]
    ) -> HDRV62ControllerParameters {
        guard !scenes.isEmpty else { return .developmentDefault }
        let minimums: [Float] = [0, 0.15, 0.25, 0.35, 0.45, 0.55, 0.65]
        var best = HDRV62ControllerParameters.developmentDefault
        var bestScore = Double.greatestFiniteMagnitude
        func consider(_ parameters: HDRV62ControllerParameters) {
            let score = scenes.reduce(0.0) { total, scene in
                let predicted = HDRV62ExpansionBudgetMath.budget(
                    features: scene.features,
                    controller: controller,
                    parameters: parameters
                ).budget
                let weight = max(scene.reliabilityWeight, 0.05)
                let delta = Double(predicted) - scene.bestScale
                return total + weight * delta * delta
            }
            if score < bestScore - 1e-12 {
                bestScore = score
                best = parameters
            }
        }

        switch controller {
        case .highlightDemand:
            for minimum in minimums {
                for low in [Float(0), 0.02, 0.05, 0.10, 0.15, 0.20] {
                    for high in [Float(0.15), 0.25, 0.35, 0.45, 0.60, 0.80] where high > low {
                        var parameters = HDRV62ControllerParameters.developmentDefault
                        parameters.minimumBudget = minimum
                        parameters.highlightLow = low
                        parameters.highlightHigh = high
                        consider(parameters)
                    }
                }
            }
        case .dynamicRangeDemand:
            for minimum in minimums {
                for low in [Float(0.25), 0.5, 1.0, 1.5, 2.0, 2.5] {
                    for high in [Float(1.5), 2.5, 3.5, 4.5, 6.0] where high > low {
                        var parameters = HDRV62ControllerParameters.developmentDefault
                        parameters.minimumBudget = minimum
                        parameters.dynamicRangeLow = low
                        parameters.dynamicRangeHigh = high
                        consider(parameters)
                    }
                }
            }
        case .compactCombined:
            let weightTriples: [(Float, Float, Float)] = [
                (0.50, 0.30, 0.20), (0.40, 0.35, 0.25),
                (0.30, 0.50, 0.20), (0.40, 0.40, 0.20),
                (0.40, 0.30, 0.30), (0.33, 0.34, 0.33)
            ]
            for minimum in minimums {
                for (highlight, range, midtone) in weightTriples {
                    var parameters = HDRV62ControllerParameters.developmentDefault
                    parameters.minimumBudget = minimum
                    parameters.combinedHighlightWeight = highlight
                    parameters.combinedDynamicRangeWeight = range
                    parameters.combinedMidtoneWeight = midtone
                    consider(parameters)
                }
            }
        }
        return best
    }

    private static func evaluateCandidate(
        label: String,
        scenes: [V62SceneContext],
        configuration: HDRConfiguration,
        weights: V2ObjectiveWeights,
        device: MTLDevice
    ) throws -> (tune: V2DatasetEvaluation?, validation: V2DatasetEvaluation?) {
        let usesSceneStatistics = configuration.toneCurveRevision == .sceneRelativeV4 ||
            configuration.toneCurveRevision == .sceneRelativeV6Candidate ||
            configuration.toneCurveRevision == .sceneAdaptiveV62Candidate
        let parameters = CalibrationParameters(configuration: configuration)
        let pairIDs = Array(Set(scenes.map(\.pairID))).sorted()
        var videos: [V2VideoEvaluation] = []
        for pairID in pairIDs {
            let pairScenes = scenes.filter { $0.pairID == pairID }
            guard let first = pairScenes.first else { continue }
            let evaluator = try HDRCoreOfflineEvaluator(device: device, configuration: configuration)
            var sceneEvaluations: [V2SceneEvaluation] = []
            for scene in pairScenes {
                let frameData = try scene.frames.map { frame -> V2FrameData in
                    let generated = try evaluator.evaluateSpatiallyIndependent(
                        pixelBuffer: frame.pixelBuffer,
                        timestampSeconds: frame.timestampSeconds,
                        configuration: configuration,
                        sceneStatistics: usesSceneStatistics ? scene.statistics : nil
                    )
                    return V2FrameData(
                        reference: frame.reference,
                        generated: generated,
                        sourceLuma: frame.sourceLuma,
                        confidence: frame.confidence
                    )
                }
                sceneEvaluations.append(V2MetricsEvaluator.evaluateScene(
                    pairID: pairID,
                    scene: SceneRange(id: scene.sceneID, startSample: 0, endSample: 0, tags: scene.categories),
                    frames: frameData,
                    configuration: parameters,
                    weights: weights
                ))
            }
            guard !sceneEvaluations.isEmpty else { continue }
            videos.append(V2VideoEvaluation(
                pairID: pairID,
                split: first.split,
                frameCount: sceneEvaluations.map(\.frameCount).reduce(0, +),
                sceneCount: sceneEvaluations.count,
                alignment: first.alignment,
                categories: V2MetricsEvaluator.categories(scenes: sceneEvaluations),
                metrics: V2MetricsEvaluator.aggregate(sceneEvaluations.map(\.metrics)),
                scenes: sceneEvaluations
            ))
        }
        let tuneVideos = videos.filter { $0.split == .tune }
        let validationVideos = videos.filter { $0.split == .validation }
        func dataset(_ values: [V2VideoEvaluation], split: DatasetSplit) -> V2DatasetEvaluation? {
            guard !values.isEmpty else { return nil }
            return V2DatasetEvaluation(
                label: "v6.2-\(label)-\(split.rawValue)",
                split: split,
                videoCount: values.count,
                frameCount: values.map(\.frameCount).reduce(0, +),
                sceneCount: values.map(\.sceneCount).reduce(0, +),
                metrics: V2MetricsEvaluator.aggregate(values.map(\.metrics)),
                videos: values
            )
        }
        return (
            dataset(tuneVideos, split: .tune),
            dataset(validationVideos, split: .validation)
        )
    }

    private static func makeFeatureCorrelations(
        _ demand: [V62SceneDemand]
    ) -> [V62FeatureCorrelation] {
        let names: [(String, (HDRV62SceneFeatures) -> Double)] = [
            ("p50", { Double($0.p50) }),
            ("p90", { Double($0.p90) }),
            ("p99", { Double($0.p99) }),
            ("highlightOccupancyProxy", { Double($0.highlightOccupancyProxy) }),
            ("dynamicRangeStops", { Double($0.dynamicRangeStops) }),
            ("midtoneOccupancyProxy", { Double($0.midtoneOccupancyProxy) }),
            ("nearBlackOccupancyProxy", { Double($0.nearBlackOccupancyProxy) }),
            ("shadowTop", { Double($0.shadowTop) }),
            ("shadowFloor", { Double($0.shadowFloor) })
        ]
        return DatasetSplit.allCases.filter { $0 != .frozen }.flatMap { split -> [V62FeatureCorrelation] in
            let values = demand.filter { $0.split == split }
            return names.map { name, value in
                V62FeatureCorrelation(
                    split: split,
                    feature: name,
                    target: "bestScale",
                    result: V61ErrorAttributionMath.pearson(
                        values.map { value($0.features) },
                        values.map(\.bestScale)
                    )
                )
            }
        }
    }

    private static func makeMatchedComparisons(
        _ demand: [V62SceneDemand]
    ) -> [V62MatchedSceneComparison] {
        guard demand.count > 1 else { return [] }
        let dimensions: [(HDRV62SceneFeatures) -> Double] = [
            { Double($0.p50) }, { Double($0.p90) }, { Double($0.p99) },
            { Double($0.dynamicRangeStops) }, { Double($0.highlightOccupancyProxy) },
            { Double($0.midtoneOccupancyProxy) }
        ]
        let ranges = dimensions.map { dimension in
            let values = demand.map { dimension($0.features) }
            return max(values.max()! - values.min()!, 0.0001)
        }
        var pairs: [(Double, V62SceneDemand, V62SceneDemand)] = []
        for leftIndex in demand.indices {
            for rightIndex in demand.indices where rightIndex > leftIndex {
                let left = demand[leftIndex]
                let right = demand[rightIndex]
                guard left.transfer != right.transfer else { continue }
                let distance = sqrt(zip(dimensions, ranges).reduce(0.0) { total, pair in
                    let delta = (pair.0(left.features) - pair.0(right.features)) / pair.1
                    return total + delta * delta
                })
                pairs.append((distance, left, right))
            }
        }
        return pairs.sorted { $0.0 < $1.0 }.prefix(12).map { distance, left, right in
            V62MatchedSceneComparison(
                leftPairID: left.pairID,
                leftSceneID: left.sceneID,
                leftTransfer: left.transfer,
                rightPairID: right.pairID,
                rightSceneID: right.sceneID,
                rightTransfer: right.transfer,
                featureDistance: distance,
                leftBestScale: left.bestScale,
                rightBestScale: right.bestScale,
                bestScaleDifference: abs(left.bestScale - right.bestScale)
            )
        }
    }

    private static func transferLeaveOneOutAccuracy(_ demand: [V62SceneDemand]) -> Double? {
        guard demand.count > 2 else { return nil }
        let dimensions: [(HDRV62SceneFeatures) -> Double] = [
            { Double($0.p50) }, { Double($0.p90) }, { Double($0.p99) },
            { Double($0.dynamicRangeStops) }, { Double($0.highlightOccupancyProxy) },
            { Double($0.midtoneOccupancyProxy) }
        ]
        let ranges = dimensions.map { dimension in
            let values = demand.map { dimension($0.features) }
            return max(values.max()! - values.min()!, 0.0001)
        }
        var correct = 0
        var count = 0
        for index in demand.indices {
            var bestDistance = Double.greatestFiniteMagnitude
            var bestTransfer: String?
            for other in demand.indices where other != index {
                let distance = sqrt(zip(dimensions, ranges).reduce(0.0) { total, pair in
                    let delta = (pair.0(demand[index].features) - pair.0(demand[other].features)) / pair.1
                    return total + delta * delta
                })
                if distance < bestDistance {
                    bestDistance = distance
                    bestTransfer = demand[other].transfer
                }
            }
            if bestTransfer != nil {
                if bestTransfer == demand[index].transfer { correct += 1 }
                count += 1
            }
        }
        return count > 0 ? Double(correct) / Double(count) : nil
    }

    private static func makeTransferStratification(
        _ candidates: [V62CandidateResult],
        scenes: [V62SceneContext]
    ) -> [V62TransferStratum] {
        var result: [V62TransferStratum] = []
        for candidate in candidates {
            for split in [DatasetSplit.tune, .validation] {
                for transfer in Set(scenes.filter { $0.split == split }.map(\.transfer)).sorted() {
                    let selected = candidate.evaluation(for: split)?.videos.filter { video in
                        scenes.first(where: { $0.pairID == video.pairID })?.transfer == transfer
                    } ?? []
                    let metrics = V2MetricsEvaluator.aggregate(selected.map(\.metrics))
                    guard !selected.isEmpty else { continue }
                    result.append(V62TransferStratum(
                        split: split,
                        transfer: transfer,
                        candidate: candidate.shortName,
                        sceneCount: selected.map(\.sceneCount).reduce(0, +),
                        objective: metrics.objective,
                        diffuseSignedError: metrics.diffuseMidtoneSignedError,
                        diffusePositiveOvershoot: metrics.diffuseMidtonePositiveOvershoot,
                        diffuseNegativeUndershoot: metrics.diffuseMidtoneNegativeUndershoot,
                        highlightError: metrics.highlightError,
                        shadowError: metrics.shadowError
                    ))
                }
            }
        }
        return result
    }

    private static func makeFamilyRobustness(
        candidateResults: [V62CandidateResult],
        demand: [V62SceneDemand],
        scenes: [V62SceneContext],
        fitted: [HDRV62ExpansionController: HDRV62ControllerParameters],
        weights: V2ObjectiveWeights
    ) -> [V62FamilyRobustness] {
        let families = Set(scenes.map(\.contentFamily)).sorted()
        var result: [V62FamilyRobustness] = []
        for family in families {
            for split in [DatasetSplit.tune, .validation] {
                for candidate in candidateResults {
                    let selectedVideos = candidate.evaluation(for: split)?.videos.filter { video in
                        scenes.first(where: { scene in scene.pairID == video.pairID })?.contentFamily == family
                    } ?? []
                    let selectedScenes = demand.filter { $0.contentFamily == family && $0.split == split }
                    guard !selectedScenes.isEmpty else { continue }
                    let metrics = V2MetricsEvaluator.aggregate(selectedVideos.flatMap { $0.scenes.map(\.metrics) })
                    let demandRMSE: Double?
                    if let controller = candidate.controller {
                        let fitScenes = demand.filter { $0.split == .tune && $0.contentFamily != family }
                        let leaveOut = fitParameters(controller: controller, scenes: fitScenes)
                        let errors = selectedScenes.map { scene -> Double in
                            let predicted = HDRV62ExpansionBudgetMath.budget(
                                features: scene.features,
                                controller: controller,
                                parameters: leaveOut
                            ).budget
                            return Double(predicted) - scene.bestScale
                        }
                        demandRMSE = errors.isEmpty ? nil : sqrt(errors.map { $0 * $0 }.reduce(0, +) / Double(errors.count))
                    } else {
                        demandRMSE = nil
                    }
                    result.append(V62FamilyRobustness(
                        family: family,
                        split: split,
                        candidate: candidate.shortName,
                        sceneCount: selectedScenes.count,
                        objective: metrics.objective,
                        demandPredictionRMSE: demandRMSE,
                        fitExcludedFamily: candidate.controller != nil
                    ))
                }
            }
        }
        return result
    }

    private static func makeBudgetStability(
        scenes: [V62SceneContext],
        fitted: [HDRV62ExpansionController: HDRV62ControllerParameters]
    ) -> [V62BudgetStability] {
        HDRV62ExpansionController.allCases.map { controller in
            let parameters = fitted[controller] ?? .developmentDefault
            var deltas: [Double] = []
            var maximum = 0.0
            for scene in scenes {
                var smoothedStatistics = HDRSceneStatistics.neutral
                var previousAverage: Float?
                var statisticsValid = false
                var budgets: [Double] = []
                for frame in scene.frames {
                    // The submitted frame consumes the state produced by the
                    // previous completion. The current frame's 16x9 estimate
                    // is applied only after this budget has been observed.
                    budgets.append(Double(HDRV62ExpansionBudgetMath.budget(
                        features: HDRV62SceneFeatures(
                            statistics: smoothedStatistics,
                            statisticsValid: statisticsValid
                        ),
                        controller: controller,
                        parameters: parameters
                    ).budget))

                    let currentAverage = frame.frameStatistics.averageLuminance
                    let sceneCut = HDRTemporalControlState.isSceneCut(
                        previous: previousAverage,
                        current: currentAverage
                    )
                    smoothedStatistics = HDRSceneStatistics.causalBlend(
                        previous: smoothedStatistics,
                        target: frame.frameStatistics,
                        stability: HDRConfiguration.calibratedV4.temporalStability,
                        sceneCut: sceneCut || !statisticsValid
                    )
                    previousAverage = currentAverage
                    statisticsValid = true
                }
                for index in 1..<budgets.count {
                    let delta = abs(budgets[index] - budgets[index - 1])
                    deltas.append(delta)
                    maximum = max(maximum, delta)
                }
            }
            return V62BudgetStability(
                candidate: controller.shortName,
                sceneCount: scenes.count,
                meanFrameDelta: deltas.isEmpty ? 0 : deltas.reduce(0, +) / Double(deltas.count),
                p95FrameDelta: V61ErrorAttributionMath.percentile(deltas, 0.95),
                maximumFrameDelta: maximum,
                sceneCutRecoveryMeasured: false
            )
        }
    }

    private static func selectVerdict(candidateResults: [V62CandidateResult]) -> String {
        guard let baseline = candidateResults.first(where: { $0.candidate == "v4-baseline" }),
              let baselineValidation = baseline.validation else {
            return "DATA_INSUFFICIENT"
        }
        let adaptive = candidateResults.filter { $0.controller != nil }
        let valid = adaptive.filter { candidate in
            guard let validation = candidate.validation else { return false }
            let baselineMetrics = baselineValidation.metrics
            let candidateMetrics = validation.metrics
            return candidateMetrics.objective <= baselineMetrics.objective + 1e-9 &&
                candidateMetrics.diffuseMidtonePositiveOvershoot < baselineMetrics.diffuseMidtonePositiveOvershoot &&
                candidateMetrics.diffuseMidtoneNegativeUndershoot <= baselineMetrics.diffuseMidtoneNegativeUndershoot * 1.05 + 0.001 &&
                candidateMetrics.highlightError <= baselineMetrics.highlightError * 1.05 + 0.001 &&
                candidateMetrics.shadowError <= baselineMetrics.shadowError * 1.05 + 0.001 &&
                candidateMetrics.nearBlackContrastLoss <= baselineMetrics.nearBlackContrastLoss * 1.05 + 0.001 &&
                candidateMetrics.temporalFlicker <= baselineMetrics.temporalFlicker * 1.10 + 0.001
        }
        if !valid.isEmpty { return "ADAPTIVE_WINNER" }
        return "GLOBAL_V4_STILL_BEST"
    }
}

private extension V62CandidateResult {
    func evaluation(for split: DatasetSplit) -> V2DatasetEvaluation? {
        switch split {
        case .tune: return tune
        case .validation: return validation
        case .frozen: return nil
        }
    }
}
