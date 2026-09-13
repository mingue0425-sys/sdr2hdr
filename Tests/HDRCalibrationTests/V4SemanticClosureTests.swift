import Foundation
import HDRCore
@testable import HDRCalibration
import XCTest

final class V4SemanticClosureTests: XCTestCase {
    private func object<T: Encodable>(_ value: T) throws -> [String: Any] {
        try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: HDRCanonicalIdentity.data(value),
                options: [.fragmentsAllowed]
            ) as? [String: Any]
        )
    }

    private func replacing(
        _ object: [String: Any],
        path: [String],
        with value: Any
    ) throws -> [String: Any] {
        guard let key = path.first else {
            throw NSError(domain: "v4-semantic-test", code: 1)
        }
        var changed = object
        if path.count == 1 {
            changed[key] = value
            return changed
        }
        guard let child = changed[key] as? [String: Any] else {
            throw NSError(domain: "v4-semantic-test", code: 2)
        }
        changed[key] = try replacing(child, path: Array(path.dropFirst()), with: value)
        return changed
    }

    private func decoded<T: Decodable>(
        _ type: T.Type,
        from object: [String: Any]
    ) throws -> T {
        try JSONDecoder().decode(
            type,
            from: JSONSerialization.data(withJSONObject: object)
        )
    }

    private func changedPreparation(
        path: [String],
        value: Any,
        matcherHash: String? = nil
    ) throws -> V6PreparationConfiguration {
        let base = V6PreparationConfiguration.v6
        var root = try object(base)
        root = try replacing(root, path: path, with: value)
        if let matcherHash {
            root["matcherConfigurationHash"] = matcherHash
        }
        return try decoded(V6PreparationConfiguration.self, from: root)
    }

    private func searchDefinition(
        from base: SDRCalibrationSearchDefinitionV4,
        policyHash: String? = nil,
        preparationHash: String? = nil,
        metricHash: String? = nil,
        gate: V4GateDefinition? = nil,
        algorithm: SDRSearchAlgorithmDefinitionV4? = nil,
        runner: V4RunnerSemanticConfiguration? = nil,
        seed: UInt64? = nil,
        splitSeed: UInt64? = nil,
        bounds: V2ParameterBounds? = nil,
        shortlistSize: Int? = nil
    ) throws -> SDRCalibrationSearchDefinitionV4 {
        try SDRCalibrationSearchDefinitionV4(
            policyDefinitionHashV4: policyHash ?? base.policyDefinitionHashV4,
            preparationDefinitionHashV4: preparationHash ?? base.preparationDefinitionHashV4,
            metricDefinitionHashV4: metricHash ?? base.metricDefinitionHashV4,
            colorScienceDefinitionHash: base.colorScienceDefinitionHash,
            gateDefinition: gate ?? base.gateDefinition,
            searchAlgorithmDefinition: algorithm ?? base.searchAlgorithmDefinition,
            runnerDefinition: runner ?? base.runnerDefinition,
            policyCandidates: base.policyCandidates,
            searchBudgetPerPolicy: base.searchBudgetPerPolicy,
            seed: seed ?? base.seed,
            splitSeed: splitSeed ?? base.splitSeed,
            parameterBounds: bounds ?? base.parameterBounds,
            safetyThresholds: base.safetyThresholds,
            shortlistSize: shortlistSize ?? base.shortlistSize
        )
    }

    func testV4SealDerivesBothPoliciesWithExactBudgetAndShortlist() throws {
        let experiment = try PreregisteredCalibrationExperimentV4.current()
        try experiment.validate()
        let runner = try PreregisteredCalibrationRunnerV4(experiment: experiment)
        let runtimes = try runner.verifyOnly()

        XCTAssertEqual(runtimes.map(\.policy), [.bt709SourceLinear, .bt1886ReferenceDisplay])
        XCTAssertEqual(runtimes.count, 2)
        XCTAssertTrue(runtimes.allSatisfy { runtime in
            runtime.searchAlgorithmDefinition.globalCandidateCount == 128 &&
                runtime.searchAlgorithmDefinition.localCandidateCount == 64 &&
                runtime.totalCandidatesPerPolicy == 192 &&
                runtime.searchSeed == 2_026_09_12 &&
                runtime.shortlistSize == 3
        })
        XCTAssertEqual(experiment.objectiveEvaluations, 0)
        XCTAssertEqual(experiment.corpusDefinitionHash, "NOT_YET_CREATED")
        XCTAssertEqual(experiment.experimentBindingHash, "NOT_YET_CREATED")
    }

    func testV4PreparationAndMatcherMutationMatrixChangesPreparationAndSearchIdentity() throws {
        let baseDefinition = SDRPreparationDefinitionV4.current
        let baseHash = try baseDefinition.canonicalSHA256()
        let baseSeal = try SDRCalibrationSemanticSealV4.current()
        let baseSearchHash = baseSeal.searchDefinitionHashV4
        let matcherBase = V6MatcherConfiguration.v6

        let directMutations: [([String], Any)] = [
            (["proxyWidth"], 321),
            (["sceneSegmentationSemantics", "boundaryDescriptorDistanceThreshold"], 0.30),
            (["sceneSegmentationSemantics", "lowKeyMeanThreshold"], 0.65)
        ]
        for (path, value) in directMutations {
            let changedConfiguration = try changedPreparation(path: path, value: value)
            let changedDefinition = SDRPreparationDefinitionV4(configuration: changedConfiguration)
            let changedHash = try changedDefinition.canonicalSHA256()
            XCTAssertNotEqual(changedHash, baseHash, "preparation mutation did not change identity: \(path.joined(separator: "."))")
            let changedSearch = try searchDefinition(from: baseSeal.searchDefinition, preparationHash: changedHash)
            XCTAssertNotEqual(try changedSearch.canonicalSHA256(), baseSearchHash)
        }

        var acceptedObject = try object(baseDefinition.configuration)
        acceptedObject["acceptedConfidenceThreshold"] = 0.61
        var acceptedMatcherObject = try object(matcherBase)
        acceptedMatcherObject["acceptedConfidenceThreshold"] = 0.61
        let acceptedMatcher = try decoded(V6MatcherConfiguration.self, from: acceptedMatcherObject)
        acceptedObject["matcherConfiguration"] = acceptedMatcherObject
        acceptedObject["matcherConfigurationHash"] = try acceptedMatcher.canonicalSHA256()
        let acceptedConfiguration = try decoded(V6PreparationConfiguration.self, from: acceptedObject)
        let acceptedDefinition = SDRPreparationDefinitionV4(configuration: acceptedConfiguration)
        let acceptedHash = try acceptedDefinition.canonicalSHA256()
        XCTAssertNotEqual(acceptedHash, baseHash)
        XCTAssertNotEqual(try searchDefinition(from: baseSeal.searchDefinition, preparationHash: acceptedHash).canonicalSHA256(), baseSearchHash)

        var matcherObject = try object(matcherBase)
        matcherObject = try replacing(matcherObject, path: ["offsetStepSeconds"], with: 1.0 / 24.0)
        let changedMatcher = try decoded(V6MatcherConfiguration.self, from: matcherObject)
        let changedMatcherHash = try changedMatcher.canonicalSHA256()
        let changedConfiguration = try changedPreparation(
            path: ["matcherConfiguration"],
            value: matcherObject,
            matcherHash: changedMatcherHash
        )
        let changedDefinition = SDRPreparationDefinitionV4(configuration: changedConfiguration)
        let changedHash = try changedDefinition.canonicalSHA256()
        XCTAssertNotEqual(changedHash, baseHash)
        let changedSearch = try searchDefinition(from: baseSeal.searchDefinition, preparationHash: changedHash)
        XCTAssertNotEqual(try changedSearch.canonicalSHA256(), baseSearchHash)
        XCTAssertNotEqual(changedMatcherHash, try matcherBase.canonicalSHA256())

        var validationObject = try object(matcherBase)
        validationObject = try replacing(
            validationObject,
            path: ["validationSemantics", "maximumGridCellCount"],
            with: 4_097
        )
        let changedValidationMatcher = try decoded(V6MatcherConfiguration.self, from: validationObject)
        let changedValidationMatcherHash = try changedValidationMatcher.canonicalSHA256()
        let changedValidationPreparation = try changedPreparation(
            path: ["matcherConfiguration"],
            value: validationObject,
            matcherHash: changedValidationMatcherHash
        )
        let changedValidationPreparationHash = try SDRPreparationDefinitionV4(
            configuration: changedValidationPreparation
        ).canonicalSHA256()
        XCTAssertNotEqual(changedValidationMatcherHash, try matcherBase.canonicalSHA256())
        XCTAssertNotEqual(changedValidationPreparationHash, baseHash)

        let decodedPreparation = try object(baseDefinition.configuration)
        XCTAssertEqual(Set(decodedPreparation.keys), V6PreparationConfiguration.canonicalFieldNames)
        XCTAssertEqual(Set(matcherObject.keys), V6MatcherConfiguration.canonicalFieldNames)
    }

    func testV4MetricAndColorScienceMutationMatrixChangesMetricAndSearchIdentity() throws {
        let baseDefinition = SDRMetricDefinitionV4.current
        let baseHash = try baseDefinition.canonicalSHA256()
        let baseSeal = try SDRCalibrationSemanticSealV4.current()
        let baseSearchHash = baseSeal.searchDefinitionHashV4

        let mutations: [([String], Any)] = [
            (["highlightUnderreachRatio"], 0.85),
            (["clippingPeakRatio"], 0.995),
            (["hueMeanWeight"], 0.50),
            (["temporalLuminanceWeight"], 0.50),
            (["colorScience", "pq", "m1"], 0.16)
        ]
        for (path, value) in mutations {
            let changedObject = try replacing(object(baseDefinition.configuration), path: path, with: value)
            let changedConfiguration = try decoded(V2MetricSemanticConfiguration.self, from: changedObject)
            let changedDefinition = SDRMetricDefinitionV4(configuration: changedConfiguration)
            let changedHash = try changedDefinition.canonicalSHA256()
            XCTAssertNotEqual(changedHash, baseHash, "metric/color mutation did not change identity: \(path.joined(separator: "."))")
            let changedSearch = try searchDefinition(from: baseSeal.searchDefinition, metricHash: changedHash)
            XCTAssertNotEqual(try changedSearch.canonicalSHA256(), baseSearchHash)
        }

        let metricObject = try object(baseDefinition.configuration)
        XCTAssertEqual(Set(metricObject.keys), V2MetricSemanticConfiguration.canonicalFieldNames)
    }

    func testV4GateRunnerAndSearchMutationMatrixChangesSearchIdentity() throws {
        let seal = try SDRCalibrationSemanticSealV4.current()
        let baseHash = seal.searchDefinitionHashV4

        var gateObject = try object(seal.gateDefinition)
        gateObject = try replacing(gateObject, path: ["candidateClippingRatio", "operation"], with: "lessThan")
        let changedGate = try decoded(V4GateDefinition.self, from: gateObject)
        XCTAssertNotEqual(try changedGate.canonicalSHA256(), try seal.gateDefinition.canonicalSHA256())
        XCTAssertNotEqual(try searchDefinition(from: seal.searchDefinition, gate: changedGate).canonicalSHA256(), baseHash)

        var runnerObject = try object(seal.searchDefinition.runnerDefinition)
        runnerObject = try replacing(runnerObject, path: ["requiredValidationPairCount"], with: 4)
        let changedRunner = try decoded(V4RunnerSemanticConfiguration.self, from: runnerObject)
        XCTAssertNotEqual(try changedRunner.canonicalSHA256(), try seal.searchDefinition.runnerDefinition.canonicalSHA256())
        XCTAssertNotEqual(try searchDefinition(from: seal.searchDefinition, runner: changedRunner, shortlistSize: 4).canonicalSHA256(), baseHash)

        var algorithmObject = try object(seal.searchDefinition.searchAlgorithmDefinition)
        algorithmObject = try replacing(algorithmObject, path: ["localNeighborhoodRadius"], with: 0.11)
        let changedAlgorithm = try decoded(SDRSearchAlgorithmDefinitionV4.self, from: algorithmObject)
        XCTAssertNotEqual(try changedAlgorithm.canonicalSHA256(), try seal.searchDefinition.searchAlgorithmDefinition.canonicalSHA256())
        XCTAssertNotEqual(try searchDefinition(from: seal.searchDefinition, algorithm: changedAlgorithm).canonicalSHA256(), baseHash)

        XCTAssertNotEqual(
            try searchDefinition(from: seal.searchDefinition, seed: seal.searchDefinition.seed + 1).canonicalSHA256(),
            baseHash
        )

        var representationObject = try object(seal.searchDefinition.searchAlgorithmDefinition.parameterRepresentation)
        representationObject = try replacing(representationObject, path: ["finiteOnly"], with: false)
        let invalidRepresentation = try decoded(V4ParameterRepresentationDefinition.self, from: representationObject)
        var invalidAlgorithmObject = try object(seal.searchDefinition.searchAlgorithmDefinition)
        invalidAlgorithmObject["parameterRepresentation"] = representationObject
        let invalidAlgorithm = try decoded(SDRSearchAlgorithmDefinitionV4.self, from: invalidAlgorithmObject)
        XCTAssertThrowsError(
            try SDRCalibrationSearchDefinitionV4(
                policyDefinitionHashV4: seal.searchDefinition.policyDefinitionHashV4,
                preparationDefinitionHashV4: seal.searchDefinition.preparationDefinitionHashV4,
                metricDefinitionHashV4: seal.searchDefinition.metricDefinitionHashV4,
                colorScienceDefinitionHash: seal.searchDefinition.colorScienceDefinitionHash,
                gateDefinition: seal.searchDefinition.gateDefinition,
                searchAlgorithmDefinition: invalidAlgorithm,
                runnerDefinition: seal.searchDefinition.runnerDefinition,
                policyCandidates: seal.searchDefinition.policyCandidates,
                searchBudgetPerPolicy: seal.searchDefinition.searchBudgetPerPolicy,
                seed: seal.searchDefinition.seed,
                splitSeed: seal.searchDefinition.splitSeed,
                parameterBounds: seal.searchDefinition.parameterBounds,
                safetyThresholds: seal.searchDefinition.safetyThresholds,
                shortlistSize: seal.searchDefinition.shortlistSize
            )
        )
        _ = invalidRepresentation
    }

    func testV4SensitivityAxesAndRunnerOnlySemanticsAreSealedAndConsumed() throws {
        let seal = try SDRCalibrationSemanticSealV4.current()
        let baseAlgorithmHash = try seal.searchDefinition.searchAlgorithmDefinition.canonicalSHA256()
        let baseRunnerHash = try seal.searchDefinition.runnerDefinition.canonicalSHA256()

        let changedAxes = [
            V4SensitivityAxisDefinition(
                parameter: .shadowProtection,
                measure: .shadowLiftRatio,
                monotonicRule: .consecutiveDeltaLessThanOrEqualTolerance
            ),
            V4SensitivityAxisDefinition(
                parameter: .temporalStability,
                measure: .temporalFlickerPlusHighlightPumping,
                probeOrdering: .ascendingProbeValue
            )
        ]
        let changedAlgorithm = SDRSearchAlgorithmDefinitionV4(
            sensitivityProbeValues: [0, 0.2, 0.5, 0.75, 1],
            sensitivityAxes: changedAxes
        )
        XCTAssertNotEqual(try changedAlgorithm.canonicalSHA256(), baseAlgorithmHash)
        XCTAssertNotEqual(
            try searchDefinition(from: seal.searchDefinition, algorithm: changedAlgorithm).canonicalSHA256(),
            seal.searchDefinitionHashV4
        )

        let changedRunner = V4RunnerSemanticConfiguration(unclassifiedFamilyKey: "UNCLASSIFIED_V4")
        XCTAssertNotEqual(try changedRunner.canonicalSHA256(), baseRunnerHash)
        XCTAssertEqual(
            seal.searchDefinition.runnerDefinition.stableFamilyOrderingRule,
            .canonicalUTF8AscendingBeforeFloatingPointReduction
        )
        XCTAssertEqual(
            seal.searchDefinition.runnerDefinition.temporalWindowPolicy.weightingPolicy,
            .equalSceneWindowWeightFramesWithinWindowOnly
        )
    }

    func testV4MetricReductionsIgnoreDictionaryInsertionOrder() throws {
        let first: [String: Double] = ["z": 0.1, "a": 1.0, "m": 10.0]
        let second: [String: Double] = ["m": 10.0, "z": 0.1, "a": 1.0]
        XCTAssertEqual(
            V2MetricsEvaluator.stableSum(first),
            V2MetricsEvaluator.stableSum(second),
            accuracy: 0
        )
        XCTAssertEqual(
            V2MetricsEvaluator.stableSum(first),
            11.1,
            accuracy: 0
        )
    }

    func testV4RuntimeBindingRejectsSemanticOverridesBeforeExecution() throws {
        let experiment = try PreregisteredCalibrationExperimentV4.current()
        let runtime = try XCTUnwrap(try PreregisteredCalibrationRunnerV4(experiment: experiment).verifyOnly().first)
        let base = try V4CalibrationConfiguration(preregisteredRuntime: runtime)
        try base.validatePreregisteredExecutionBinding()
        var matcherObject = try object(base.preparationSemanticConfiguration!.matcherConfiguration)
        matcherObject = try replacing(matcherObject, path: ["offsetStepSeconds"], with: 1.0 / 24.0)
        let changedMatcher = try decoded(V6MatcherConfiguration.self, from: matcherObject)
        let changedMatcherHash = try changedMatcher.canonicalSHA256()
        var preparationObject = try object(base.preparationSemanticConfiguration!)
        preparationObject["matcherConfiguration"] = matcherObject
        preparationObject["matcherConfigurationHash"] = changedMatcherHash
        let changedPreparation = try decoded(V6PreparationConfiguration.self, from: preparationObject)

        let overrides: [(String, (inout V4CalibrationConfiguration) -> Void)] = [
            ("seed", { $0.searchSeed += 1 }),
            ("shortlist", { $0.validationTopCount = 8 }),
            ("global budget", { $0.globalCandidates += 1 }),
            ("paper white bound", { $0.bounds.paperWhiteNits = 191...245 }),
            ("gate operator", {
                $0.gateDefinition = V4GateDefinition(
                    candidateClippingRatio: V4ComparisonDefinition(
                        operation: .lessThan,
                        metric: .clippingRatio,
                        threshold: .candidateClippingRatio
                    )
                )
            }),
            ("metric constant", {
                guard let metric = $0.metricSemanticConfiguration,
                      let metricObject = try? self.object(metric),
                      let changed = try? self.replacing(
                          metricObject,
                          path: ["highlightUnderreachRatio"],
                          with: 0.85
                      ),
                      let changedMetric = try? self.decoded(
                          V2MetricSemanticConfiguration.self,
                          from: changed
                      ) else { return }
                $0.metricSemanticConfiguration = changedMetric
            }),
            ("matcher constant", {
                $0.preparationSemanticConfiguration = changedPreparation
            })
        ]
        for (label, mutate) in overrides {
            var changed = base
            mutate(&changed)
            XCTAssertThrowsError(try changed.validatePreregisteredExecutionBinding(), "accepted runtime override: \(label)")
        }
    }

    func testV4FinalRunnerIdentityIsTheAdapterBoundary() throws {
        let experiment = try PreregisteredCalibrationExperimentV4.current()
        let runtimes = try PreregisteredCalibrationRunnerV4(experiment: experiment).verifyOnly()
        for runtime in runtimes {
            let configuration = try V4CalibrationConfiguration(preregisteredRuntime: runtime)
            XCTAssertEqual(try configuration.validatedRunnerSemanticIdentity(), runtime.semanticIdentity)
            try configuration.validatePreregisteredExecutionBinding()
        }
    }

    func testV4CanonicalizationIsStableAndFailClosed() throws {
        XCTAssertEqual(
            try HDRCanonicalIdentity.data(["b": 2, "a": 1]),
            try HDRCanonicalIdentity.data(["a": 1, "b": 2])
        )
        XCTAssertEqual(try HDRCanonicalIdentity.number(-0.0), "0")
        XCTAssertEqual(try HDRCanonicalIdentity.number(1.0), "1")
        XCTAssertThrowsError(try HDRCanonicalIdentity.sha256(["bad": Double.nan]))
        XCTAssertThrowsError(try HDRCanonicalIdentity.sha256(["bad": Double.infinity]))

        struct FailingEncodable: Encodable {
            func encode(to encoder: Encoder) throws {
                throw NSError(domain: "v4-semantic-test", code: 3)
            }
        }
        XCTAssertThrowsError(try HDRCanonicalIdentity.sha256(FailingEncodable()))
    }

    func testV4SemanticOnlyRebaseDoesNotEvaluateMedia() throws {
        throw XCTSkip("semantic-only V4 rebase: media qualification, media hashing, Tune, Validation, Frozen evaluation, and objective evaluation are disabled")
    }
}
