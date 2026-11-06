import CoreVideo
import Metal
import XCTest
@testable import HDRCore

/// The SDR input interpretation policy is an explicit, versioned choice
/// between the historical scene-linear inverse BT.709 OETF and the
/// display-referred BT.1886 EOTF. These tests use independent power-law
/// anchors rather than HDRReference as an oracle.
final class SDRTransferInterpretationTests: XCTestCase {
    func testPolicyIdentifiersAreStableAndVersioned() {
        XCTAssertEqual(
            HDRSDRTransferInterpretation.bt709InverseOETFSceneLinear.rawValue,
            "bt709-inverse-oetf-scene-linear-v1"
        )
        XCTAssertEqual(
            HDRSDRTransferInterpretation.bt1886DisplayReferred.rawValue,
            "bt1886-display-eotf-gamma2.4-lb0-v1"
        )
        XCTAssertEqual(
            HDRSDRTransferInterpretation.bt709ToeBT1886MidBlend.rawValue,
            "bt709-toe-bt1886-mid-blend-0.10-0.70-v1"
        )
        XCTAssertEqual(HDRSDRTransferInterpretation.allCases.count, 3)
        for policy in HDRSDRTransferInterpretation.allCases {
            XCTAssertEqual(HDRSDRTransferInterpretation(rawValue: policy.rawValue), policy)
            XCTAssertEqual(HDRSDRTransferInterpretation(cliName: policy.cliName), policy)
        }
        XCTAssertNil(HDRSDRTransferInterpretation(cliName: "gamma2.2"))
    }

    func testEveryPresetKeepsTheHistoricalInterpretation() {
        // Changing the default would silently invalidate every calibrated
        // preset; BT.1886 must be selected explicitly until a rebase.
        let presets: [HDRConfiguration] = [
            .natural, .hdr, .vivid, .calibratedV1, .calibratedV2,
            .calibratedV3Candidate, .calibratedV4, HDRConfiguration()
        ]
        for preset in presets {
            XCTAssertEqual(preset.sdrTransferInterpretation, .bt709InverseOETFSceneLinear)
        }
        XCTAssertEqual(HDRSDRTransferInterpretation.default, .bt709InverseOETFSceneLinear)
    }

    func testBT1886AnchorsMatchIndependentPowerLaw() {
        for signal: Float in [0, 0.01, 0.081, 0.18, 0.5, 0.75, 1] {
            XCTAssertEqual(HDRColorMath.inverseBT1886(signal), pow(signal, 2.4), accuracy: 1e-7)
        }
        XCTAssertEqual(HDRColorMath.inverseBT1886(0.5), 0.18946457, accuracy: 1e-6)
        XCTAssertEqual(HDRColorMath.inverseBT1886(-0.25), 0)
        XCTAssertEqual(HDRColorMath.inverseTransfer(0.5, function: .bt1886), 0.18946457, accuracy: 1e-6)
        // The two conventions differ materially at mid grey.
        XCTAssertGreaterThan(HDRColorMath.inverseBT709(0.5) - HDRColorMath.inverseBT1886(0.5), 0.06)
    }

    /// Independent anchors: the blend is the inverse OETF up to code 0.10,
    /// the 2.4 power law from 0.70, and strictly increasing in between.
    func testToeBlendAnchorsShadowsMidtonesAndMonotonicity() {
        for signal: Float in [0, 0.02, 0.081, 0.10] {
            XCTAssertEqual(HDRColorMath.inverseBT709ToeBT1886Blend(signal), HDRColorMath.inverseBT709(signal), accuracy: 1e-7)
        }
        for signal: Float in [0.70, 0.85, 1] {
            XCTAssertEqual(HDRColorMath.inverseBT709ToeBT1886Blend(signal), pow(signal, 2.4), accuracy: 1e-6)
        }
        // Mid grey lies between the two conventions.
        let mid = HDRColorMath.inverseBT709ToeBT1886Blend(0.5)
        XCTAssertLessThan(mid, HDRColorMath.inverseBT709(0.5) - 0.03)
        XCTAssertGreaterThan(mid, pow(0.5, 2.4) + 0.01)
        var previous = HDRColorMath.inverseBT709ToeBT1886Blend(0.0815)
        var signal: Float = 0.0815
        while signal < 1 {
            signal += 0.0005
            let value = HDRColorMath.inverseBT709ToeBT1886Blend(signal)
            XCTAssertGreaterThan(value, previous, "signal=\(signal)")
            previous = value
        }
        XCTAssertEqual(HDRTransferFunction.bt709.interpreted(by: .bt709ToeBT1886MidBlend), .bt709ToeBT1886Blend)
    }

    func testInterpretationOnlyRewritesBT709TaggedSignals() {
        let legacy = HDRSDRTransferInterpretation.bt709InverseOETFSceneLinear
        let display = HDRSDRTransferInterpretation.bt1886DisplayReferred
        XCTAssertEqual(HDRTransferFunction.bt709.interpreted(by: legacy), .bt709)
        XCTAssertEqual(HDRTransferFunction.bt709.interpreted(by: display), .bt1886)
        for function: HDRTransferFunction in [.sRGB, .gamma(2.2), .linear, .bt1886] {
            XCTAssertEqual(function.interpreted(by: legacy), function)
            XCTAssertEqual(function.interpreted(by: display), function)
        }
    }

    func testReferenceFollowsConfiguredInterpretation() {
        var config = neutralConfiguration()
        for code in [0, 16, 64, 128, 200, 255] {
            let signal = Float(code) / 255
            config.sdrTransferInterpretation = .bt709InverseOETFSceneLinear
            let legacy = HDRReference.process(signalRGB: SIMD3(repeating: signal), configuration: config)
            config.sdrTransferInterpretation = .bt1886DisplayReferred
            let display = HDRReference.process(signalRGB: SIMD3(repeating: signal), configuration: config)
            XCTAssertEqual(legacy.x, HDRColorMath.inverseBT709(signal), accuracy: 1e-5, "code=\(code)")
            XCTAssertEqual(display.x, pow(signal, 2.4), accuracy: 1e-5, "code=\(code)")
        }
    }

    func testGPUFollowsConfiguredInterpretationAndReportsIt() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        for policy in HDRSDRTransferInterpretation.allCases {
            var config = neutralConfiguration()
            config.sdrTransferInterpretation = policy
            let processor = try HDRProcessor(device: device, configuration: config)
            for code: UInt8 in [0, 16, 64, 128, 200, 255] {
                let signal = Float(code) / 255
                let expected: Float
                switch policy {
                case .bt1886DisplayReferred: expected = pow(signal, 2.4)
                case .bt709ToeBT1886MidBlend: expected = HDRColorMath.inverseBT709ToeBT1886Blend(signal)
                case .bt709InverseOETFSceneLinear: expected = HDRColorMath.inverseBT709(signal)
                }
                let reference = HDRReference.process(
                    signalRGB: SIMD3(repeating: signal),
                    configuration: config
                )
                let buffer = try makeBT709TaggedBGRA(code: code)
                let command = try processor.makeCommandBuffer()
                let frame = try processor.process(pixelBuffer: buffer, commandBuffer: command)
                command.commit()
                command.waitUntilCompleted()
                XCTAssertEqual(command.status, .completed)
                XCTAssertEqual(frame.metadata.sdrTransferInterpretation, policy)
                let pixel = try readFirstRGBA16FloatPixel(from: frame.texture, device: device)
                let tolerance = max(expected * 0.002, 1e-6)
                XCTAssertEqual(pixel.x, expected, accuracy: tolerance, "\(policy) code=\(code)")
                XCTAssertEqual(pixel.x, reference.x, accuracy: tolerance, "\(policy) code=\(code) parity")
            }
        }
    }

    func testUpdatingInterpretationChangesOnlyConstants() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        var config = neutralConfiguration()
        let processor = try HDRProcessor(device: device, configuration: config)
        func render() throws -> Float {
            let buffer = try makeBT709TaggedBGRA(code: 128)
            let command = try processor.makeCommandBuffer()
            let frame = try processor.process(pixelBuffer: buffer, commandBuffer: command)
            command.commit()
            command.waitUntilCompleted()
            return try readFirstRGBA16FloatPixel(from: frame.texture, device: device).x
        }
        let legacy = try render()
        config.sdrTransferInterpretation = .bt1886DisplayReferred
        try processor.update(configuration: config)
        let display = try render()
        XCTAssertEqual(legacy, HDRColorMath.inverseBT709(128 / 255), accuracy: 2e-3)
        XCTAssertEqual(display, pow(128 / 255, 2.4), accuracy: 2e-3)
        XCTAssertGreaterThan(legacy - display, 0.05)
    }

    private func neutralConfiguration() -> HDRConfiguration {
        // Identity expansion: no highlight headroom use, no shadow shaping.
        var config = HDRConfiguration.natural
        config.highlightStrength = 0
        config.shadowProtection = 0
        return config
    }

    private func makeBT709TaggedBGRA(code: UInt8) throws -> CVPixelBuffer {
        var result: CVPixelBuffer?
        let attributes = [kCVPixelBufferMetalCompatibilityKey as String: true,
                          kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 2, 2,
                                           kCVPixelFormatType_32BGRA, attributes, &result), kCVReturnSuccess)
        let buffer = try XCTUnwrap(result)
        XCTAssertEqual(CVPixelBufferLockBaseAddress(buffer, []), kCVReturnSuccess)
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(buffer))
        for y in 0..<2 {
            let row = base.advanced(by: y * CVPixelBufferGetBytesPerRow(buffer))
                .assumingMemoryBound(to: UInt8.self)
            for x in 0..<2 {
                row[4 * x] = code
                row[4 * x + 1] = code
                row[4 * x + 2] = code
                row[4 * x + 3] = 255
            }
        }
        CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey,
                              kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey,
                              kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
        return buffer
    }
}
