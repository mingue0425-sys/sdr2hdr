import CoreVideo
import HDRCore
@testable import HDRCalibration
import simd
import XCTest

final class V61ErrorAttributionTests: XCTestCase {
    func testSignedErrorKeepsDirectionAndComputesRequiredStatistics() {
        let summary = V61SignedErrorSummary(
            values: [-20, -10, 0, 10, 30],
            signedLogValues: [-0.2, -0.1, 0, 0.1, 0.3]
        )

        XCTAssertEqual(summary.sampleCount, 5)
        XCTAssertEqual(summary.meanSignedError, 2, accuracy: 1e-12)
        XCTAssertEqual(summary.medianSignedError, 0, accuracy: 1e-12)
        XCTAssertEqual(summary.p05, -20, accuracy: 1e-12)
        XCTAssertEqual(summary.p95, 10, accuracy: 1e-12)
        XCTAssertEqual(summary.positiveErrorMean, 20, accuracy: 1e-12)
        XCTAssertEqual(summary.negativeErrorMean, -15, accuracy: 1e-12)
        XCTAssertEqual(summary.overPredictionRatio, 0.4, accuracy: 1e-12)
        XCTAssertEqual(summary.underPredictionRatio, 0.4, accuracy: 1e-12)
        XCTAssertEqual(summary.mae, 14, accuracy: 1e-12)
        XCTAssertEqual(summary.rmse, sqrt(300), accuracy: 1e-12)
        XCTAssertEqual(summary.meanSignedLogError, 0.02, accuracy: 1e-12)
        XCTAssertEqual(summary.logMAE, 0.14, accuracy: 1e-12)
    }

    func testLuminanceBinsHaveUnambiguousBoundariesAndCoverUnitDomain() {
        let values = V61ErrorAttributionMath.sourceLuminanceBinEdges + [0.001, 0.019, 0.499, 0.999]
        var counts = Array(repeating: 0, count: V61ErrorAttributionMath.sourceLuminanceBinEdges.count - 1)
        for value in values {
            guard let index = V61ErrorAttributionMath.binIndex(value) else {
                XCTFail("value was not assigned: \(value)")
                continue
            }
            counts[index] += 1
        }

        XCTAssertEqual(counts.reduce(0, +), values.count)
        XCTAssertEqual(V61ErrorAttributionMath.binIndex(0), 0)
        XCTAssertEqual(V61ErrorAttributionMath.binIndex(0.01), 1)
        XCTAssertEqual(V61ErrorAttributionMath.binIndex(0.02), 2)
        XCTAssertEqual(V61ErrorAttributionMath.binIndex(1.0), counts.count - 1)
        XCTAssertNil(V61ErrorAttributionMath.binIndex(-0.001))
        XCTAssertNil(V61ErrorAttributionMath.binIndex(1.001))
    }

    func testCorrelationAndWeightedComponentConsistency() {
        let correlation = V61ErrorAttributionMath.pearson(
            [0, 1, 2, 3],
            [0, 2, 4, 6]
        )
        XCTAssertEqual(correlation.sampleCount, 4)
        XCTAssertEqual(correlation.pearson ?? .nan, 1, accuracy: 1e-12)
        XCTAssertEqual(correlation.spearman ?? .nan, 1, accuracy: 1e-12)
        XCTAssertTrue(correlation.estimable)
        let unavailable = V61ErrorAttributionMath.pearson([1, 1], [0, 1])
        XCTAssertFalse(unavailable.estimable)
        XCTAssertNil(unavailable.pearson)
        XCTAssertNil(unavailable.spearman)
        XCTAssertEqual(unavailable.unavailableReason, "zero variance in at least one input")

        let components = ["luminance": 0.10, "highlight": -0.02, "shadow": 0.03]
        XCTAssertEqual(
            V61ErrorAttributionMath.weightedComponentSum(components),
            0.11,
            accuracy: 1e-12
        )
    }

    func testV2V4ReferenceClassificationAndFrozenExclusion() {
        XCTAssertEqual(
            V61ErrorAttributionMath.referenceDirectionCase(
                v2SignedError: -10,
                v4SignedError: 0
            ),
            "V2_UNDER_REFERENCE_V4_NEAR_REFERENCE"
        )
        XCTAssertEqual(
            V61ErrorAttributionMath.referenceDirectionCase(
                v2SignedError: 0,
                v4SignedError: 10
            ),
            "V2_NEAR_REFERENCE_V4_OVER_REFERENCE"
        )
        XCTAssertEqual(
            V61ErrorAttributionMath.referenceDirectionCase(
                v2SignedError: -10,
                v4SignedError: 10
            ),
            "V2_UNDER_REFERENCE_V4_OVER_REFERENCE"
        )

        XCTAssertTrue(V61ErrorAttributionMath.isAllowedDevelopmentPair(split: .tune, virginFrozen: false))
        XCTAssertTrue(V61ErrorAttributionMath.isAllowedDevelopmentPair(split: .validation, virginFrozen: false))
        XCTAssertFalse(V61ErrorAttributionMath.isAllowedDevelopmentPair(split: .frozen, virginFrozen: false))
        XCTAssertFalse(V61ErrorAttributionMath.isAllowedDevelopmentPair(split: .tune, virginFrozen: true))
    }

    func testScalarCoefficientResponseIsDeterministicAndKeepsV4Shoulder() {
        let statistics = HDRSceneStatistics(
            p01: 0.03125,
            p05: 0.03125,
            p10: 0.03125,
            p25: 0.08125,
            p50: 0.42,
            p90: 0.88,
            p99: 1
        )
        let first = HDRDiagnosticToneSweep.v4Breakdown(
            luminance: 0.70,
            configuration: .calibratedV4,
            temporalAdaptation: 0.965,
            sceneShadowFloor: statistics.shadowFloor,
            sceneShadowTop: statistics.shadowTop,
            sceneStatisticsValid: true,
            lowMidCoefficient: 0.08 * 0.50
        )
        let second = HDRDiagnosticToneSweep.v4Breakdown(
            luminance: 0.70,
            configuration: .calibratedV4,
            temporalAdaptation: 0.965,
            sceneShadowFloor: statistics.shadowFloor,
            sceneShadowTop: statistics.shadowTop,
            sceneStatisticsValid: true,
            lowMidCoefficient: 0.08 * 0.50
        )
        XCTAssertEqual(first, second)
        XCTAssertEqual(
            HDRDiagnosticToneSweep.v4Breakdown(
                luminance: 0.70,
                configuration: .calibratedV4,
                temporalAdaptation: 0.965,
                sceneShadowFloor: statistics.shadowFloor,
                sceneShadowTop: statistics.shadowTop,
                sceneStatisticsValid: true,
                lowMidCoefficient: 0
            ).lowMidContribution,
            0,
            accuracy: 1e-7
        )
        XCTAssertGreaterThan(first.shoulderContribution, 0)
    }

    func testLinearLumaGridMatchesShaderTransferDomainForBGRA() throws {
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            1,
            1,
            kCVPixelFormatType_32BGRA,
            nil,
            &pixelBuffer
        )
        XCTAssertEqual(status, kCVReturnSuccess)
        let buffer = try XCTUnwrap(pixelBuffer)
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(buffer))
            .assumingMemoryBound(to: UInt8.self)
        base[0] = 128
        base[1] = 128
        base[2] = 128
        base[3] = 255

        let values = try OfflinePixelSampler.linearLumaGrid(
            pixelBuffer: buffer,
            width: 1,
            height: 1
        )
        XCTAssertEqual(values.count, 1)
        XCTAssertEqual(
            values[0],
            HDRColorMath.inverseBT709(128 / 255),
            accuracy: 1e-6
        )
    }

    func testSceneAndTransferStyleAggregationPreservesDirectionalMetrics() {
        let over = syntheticMetric(generatedNits: 120)
        let under = syntheticMetric(generatedNits: 80)
        let aggregate = V2MetricsEvaluator.aggregate([over, under])

        XCTAssertGreaterThan(over.diffuseMidtonePositiveOvershoot, 0)
        XCTAssertEqual(over.diffuseMidtoneNegativeUndershoot, 0, accuracy: 1e-12)
        XCTAssertGreaterThan(under.diffuseMidtoneNegativeUndershoot, 0)
        XCTAssertEqual(under.diffuseMidtonePositiveOvershoot, 0, accuracy: 1e-12)
        XCTAssertEqual(
            aggregate.diffuseMidtoneSignedError,
            (over.diffuseMidtoneSignedError + under.diffuseMidtoneSignedError) / 2,
            accuracy: 1e-12
        )
        XCTAssertGreaterThan(aggregate.diffuseMidtonePositiveOvershoot, 0)
        XCTAssertGreaterThan(aggregate.diffuseMidtoneNegativeUndershoot, 0)
        XCTAssertEqual(
            aggregate.luminanceRegionErrors["diffuse_midtone_sample_count"] ?? 0,
            2,
            accuracy: 1e-12
        )
    }

    private func syntheticMetric(generatedNits: Float) -> V2MetricBreakdown {
        let referenceRGB = [SIMD3<Float>(repeating: 100), SIMD3<Float>(repeating: 100)]
        let generatedRGB = [
            SIMD3<Float>(repeating: generatedNits),
            SIMD3<Float>(repeating: generatedNits)
        ]
        let reference = ReferenceFrame(
            timestampSeconds: 0,
            width: 2,
            height: 1,
            rgbNits: referenceRGB
        )
        let generated = GeneratedFrame(
            timestampSeconds: 0,
            width: 2,
            height: 1,
            rgbNits: generatedRGB
        )
        let frame = V2FrameData(
            reference: reference,
            generated: generated,
            sourceLuma: [0.20, 0.30],
            confidence: 1
        )
        return V2MetricsEvaluator.evaluateScene(
            pairID: "synthetic",
            scene: SceneRange(id: "synthetic", startSample: 0, endSample: 0, tags: []),
            frames: [frame],
            configuration: CalibrationParameters(configuration: .calibratedV4),
            weights: V2ObjectiveWeights()
        ).metrics
    }
}
