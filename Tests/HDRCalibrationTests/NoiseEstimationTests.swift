import Foundation
import XCTest
@testable import HDRCalibration

final class NoiseEstimationTests: XCTestCase {
    private func gaussianField(width: Int, height: Int, sigma: Double, base: (Int, Int) -> Double) -> [Float] {
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        func uniform() -> Double {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return (Double(state >> 11) + 0.5) / Double(1 << 53)
        }
        var values = [Float](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                let gaussian = (-2 * log(uniform())).squareRoot() * cos(2 * .pi * uniform())
                values[y * width + x] = Float(base(x, y) + sigma * gaussian)
            }
        }
        return values
    }

    func testRecoversGaussianSigma() {
        for sigma in [0.005, 0.02, 0.05] {
            let field = gaussianField(width: 256, height: 256, sigma: sigma) { _, _ in 0.5 }
            XCTAssertEqual(ImmerkaerNoiseEstimator.sigma(field, width: 256, height: 256), sigma, accuracy: sigma * 0.05)
        }
    }

    func testLinearStructureIsIgnored() {
        // Ramps and planes are cancelled by the Laplacian difference.
        let ramp: [Float] = (0..<(64 * 64)).map { (index: Int) -> Float in
            let x = Float(index % 64), y = Float(index / 64)
            return x * 0.01 + y * 0.003
        }
        XCTAssertEqual(ImmerkaerNoiseEstimator.sigma(ramp, width: 64, height: 64), 0, accuracy: 1e-6)
        let noisyRamp = gaussianField(width: 256, height: 256, sigma: 0.02) { (x: Int, y: Int) -> Double in
            Double(x) * 0.002 + Double(y) * 0.001
        }
        XCTAssertEqual(ImmerkaerNoiseEstimator.sigma(noisyRamp, width: 256, height: 256), 0.02, accuracy: 0.001)
    }

    func testDegenerateInputs() {
        XCTAssertEqual(ImmerkaerNoiseEstimator.sigma([], width: 0, height: 0), 0)
        XCTAssertEqual(ImmerkaerNoiseEstimator.sigma([1, 2, 3, 4], width: 2, height: 2), 0)
    }

    func testBlockinessSeparatesBlockyFromNatural() {
        let width = 128, height = 128
        let natural = gaussianField(width: width, height: height, sigma: 0.01) { (x: Int, y: Int) -> Double in
            0.5 + 0.2 * sin(Double(x) * 0.07) * cos(Double(y) * 0.05)
        }
        XCTAssertEqual(BlockinessEstimator.ratio(natural, width: width, height: height), 1, accuracy: 0.15)
        // Piecewise-constant 8x8 blocks with small interior noise.
        let blocky = gaussianField(width: width, height: height, sigma: 0.002) { (x: Int, y: Int) -> Double in
            0.5 + 0.05 * Double(((x / 8) * 7 + (y / 8) * 3) % 5)
        }
        XCTAssertGreaterThan(BlockinessEstimator.ratio(blocky, width: width, height: height), 3)
        XCTAssertEqual(BlockinessEstimator.ratio([Float](repeating: 0.3, count: 256), width: 16, height: 16), 1)
    }

    func testHistogramGapsDetectReducedBitDepth() {
        var state: UInt32 = 7
        let full: [UInt8] = (0..<20_000).map { _ in state = state &* 1_664_525 &+ 1_013_904_223; return UInt8(60 + Int(state >> 25) % 120) }
        XCTAssertLessThan(HistogramGapEstimator.gapFraction(codes: full), 0.02)
        let sixBit = full.map { $0 & 252 }
        XCTAssertEqual(HistogramGapEstimator.gapFraction(codes: sixBit), 0.75, accuracy: 0.03)
        XCTAssertEqual(HistogramGapEstimator.gapFraction(codes: []), 0)
    }
}
