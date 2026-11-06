import XCTest
import simd
import HDRCore
@testable import HDRCalibration

final class V2LevelNormalizationTests: XCTestCase {
    /// A small synthetic scene: SDR source luma ramps over [0.05, 0.95] and
    /// the reference HDR follows a fixed curve scaled by `masterLevel`.
    private func frames(masterLevel: Float, generatedGain: Float, count: Int = 400) -> [V2FrameData] {
        let source = (0..<count).map { 0.05 + 0.9 * Float($0) / Float(count - 1) }
        let referenceRGB = source.map { s -> SIMD3<Float> in
            let nits = masterLevel * 203 * pow(s, 2.2) + 0.2
            return SIMD3(repeating: nits)
        }
        // Generated output has the right shape (the same curve) at a different level.
        let generatedRGB = source.map { s -> SIMD3<Float> in
            SIMD3(repeating: generatedGain * (203 * pow(s, 2.2) + 0.2))
        }
        return [V2FrameData(
            reference: ReferenceFrame(timestampSeconds: 0, width: count, height: 1, rgbNits: referenceRGB),
            generated: GeneratedFrame(timestampSeconds: 0, width: count, height: 1, rgbNits: generatedRGB),
            sourceLuma: source,
            confidence: 1
        )]
    }

    private func score(_ frames: [V2FrameData]) -> V2MetricBreakdown {
        V2MetricsEvaluator.evaluateScene(
            pairID: "t", scene: SceneRange(id: "s", startSample: 0, endSample: 0, tags: []),
            frames: frames, configuration: CalibrationParameters(configuration: .hdr), weights: V2ObjectiveWeights()
        ).metrics
    }

    func testFitRecoversLevelDifference() {
        let gain = V2LevelNormalization.fitGain(frames(masterLevel: 0.4, generatedGain: 1))
        XCTAssertEqual(gain, 0.4, accuracy: 0.01)
    }

    func testGainIsClampedAndNeutralWithoutSamples() {
        XCTAssertEqual(V2LevelNormalization.fitGain(frames(masterLevel: 20, generatedGain: 1)), 4, accuracy: 1e-12)
        XCTAssertEqual(V2LevelNormalization.fitGain([]), 1)
    }

    func testShapeScoreRemovesLevelMismatchThatAbsoluteScorePenalises() {
        // Same shape at 0.4x brightness (a dim cinema master).
        let dim = frames(masterLevel: 0.4, generatedGain: 1)
        let absolute = score(dim)
        let gain = V2LevelNormalization.fitGain(dim)
        let shape = V2LevelNormalization.merge(
            shape: score(dim.map { V2LevelNormalization.scaled($0, gain: gain) }),
            absolute: absolute
        )
        XCTAssertGreaterThan(absolute.midtoneError, 0.3)
        XCTAssertLessThan(shape.midtoneError, 0.05)
        XCTAssertLessThan(shape.objective, absolute.objective * 0.5)
    }

    func testShapeScoreStillPenalisesWrongShape() {
        // A generated curve with the wrong exponent cannot be fixed by a gain.
        var wrong = frames(masterLevel: 1, generatedGain: 1)
        let source = wrong[0].sourceLuma
        let generated = source.map { SIMD3<Float>(repeating: 203 * pow($0, 1.2) + 0.2) }
        wrong[0] = V2FrameData(
            reference: wrong[0].reference,
            generated: GeneratedFrame(timestampSeconds: 0, width: source.count, height: 1, rgbNits: generated),
            sourceLuma: source, confidence: 1
        )
        let gain = V2LevelNormalization.fitGain(wrong)
        let shape = score(wrong.map { V2LevelNormalization.scaled($0, gain: gain) })
        let right = frames(masterLevel: 1, generatedGain: 1)
        XCTAssertGreaterThan(shape.luminanceError, score(right).luminanceError + 0.1)
    }

    func testMergeKeepsHardSafetyFromAbsoluteOutput() {
        var absolute = score(frames(masterLevel: 1, generatedGain: 1))
        absolute.clippingRatio = 0.25
        absolute.blackCrushRatio = 0.125
        absolute.weightedContributions["penalty_clipping"] = 7
        let shape = score(frames(masterLevel: 1, generatedGain: 1))
        let merged = V2LevelNormalization.merge(shape: shape, absolute: absolute)
        XCTAssertEqual(merged.clippingRatio, 0.25)
        XCTAssertEqual(merged.blackCrushRatio, 0.125)
        XCTAssertEqual(merged.weightedContributions["penalty_clipping"], 7)
        XCTAssertEqual(merged.objective, merged.weightedContributions.values.reduce(0, +), accuracy: 1e-12)
    }

    func testCLINamesAndLegacyEncoding() throws {
        XCTAssertEqual(V2LevelNormalization(cliName: "family-midtone-gain"), .familyMidtoneGainV1)
        XCTAssertNil(V2LevelNormalization(cliName: "off"))
        XCTAssertNil(V2LevelNormalization(cliName: "per-scene"))
        let legacy = String(decoding: try JSONEncoder().encode(V4CalibrationConfiguration()), as: UTF8.self)
        XCTAssertFalse(legacy.contains("levelNormalization"))
        var shaped = V4CalibrationConfiguration()
        shaped.levelNormalization = .familyMidtoneGainV1
        XCTAssertTrue(String(decoding: try JSONEncoder().encode(shaped), as: UTF8.self).contains("family-midtone-gain-v1"))
    }
}
