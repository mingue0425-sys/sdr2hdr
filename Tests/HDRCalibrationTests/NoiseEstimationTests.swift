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
}
