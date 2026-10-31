import CoreVideo
import Foundation
import Metal
import XCTest
@testable import HDRCore

/// Covers the versioned BT.709 input-domain policy. Expected values are
/// computed from the independent closed-form definitions (BT.709 inverse OETF
/// and the zero-black BT.1886 power law), never from HDRReference itself.
final class SDRInputInterpretationTests: XCTestCase {
    private let midCode: UInt8 = 128

    private var midSignal: Float { Float(midCode) / 255 }

    private func independentInverseOETF(_ value: Float) -> Float {
        value < 0.081 ? value / 4.5 : pow((value + 0.099) / 1.099, 1 / 0.45)
    }

    /// The SDR-fallback recipe used by the player: every expansion control at
    /// zero, so the output is the linearized input in BT.2020 linear EDR.
    private func neutralConfiguration(_ interpretation: HDRSDRInputInterpretation) -> HDRConfiguration {
        var configuration = HDRConfiguration.natural
        configuration.highlightStrength = 0
        configuration.contrastStrength = 0
        configuration.saturationCompensation = 0
        configuration.shadowProtection = 0
        configuration.sdrInputInterpretation = interpretation
        return configuration
    }

    func testProductionDefaultIsHistoricalInverseOETF() {
        XCTAssertEqual(HDRSDRInputInterpretation.production, .sceneReferredInverseOETF)
        XCTAssertEqual(HDRConfiguration().sdrInputInterpretation, .sceneReferredInverseOETF)
        XCTAssertEqual(HDRConfiguration.calibratedV4.sdrInputInterpretation, .sceneReferredInverseOETF)
        XCTAssertEqual(HDRConfiguration.hdr.sdrInputInterpretation, .sceneReferredInverseOETF)
    }

    func testEffectiveTransferOnlyRemapsBT709() {
        let bt1886 = HDRSDRInputInterpretation.bt1886
        XCTAssertEqual(bt1886.effectiveTransfer(for: .bt709), .gamma(2.4))
        XCTAssertEqual(bt1886.effectiveTransfer(for: .sRGB), .sRGB)
        XCTAssertEqual(bt1886.effectiveTransfer(for: .gamma(2.2)), .gamma(2.2))
        XCTAssertEqual(bt1886.effectiveTransfer(for: .linear), .linear)

        let oetf = HDRSDRInputInterpretation.sceneReferredInverseOETF
        for tagged: HDRTransferFunction in [.bt709, .sRGB, .gamma(2.2), .linear] {
            XCTAssertEqual(oetf.effectiveTransfer(for: tagged), tagged)
        }
        XCTAssertEqual(oetf.identifier, "scene-inverse-oetf")
        XCTAssertEqual(bt1886.identifier, "bt1886")
    }

    func testValidationRejectsInvalidBT1886Gamma() {
        for gamma: Float in [.nan, .infinity, 0, 0.5, 4.5] {
            var configuration = HDRConfiguration.calibratedV4
            configuration.sdrInputInterpretation = .displayReferredBT1886(gamma: gamma)
            XCTAssertThrowsError(try configuration.validated(), "gamma=\(gamma)")
        }
        var accepted = HDRConfiguration.calibratedV4
        accepted.sdrInputInterpretation = .bt1886
        XCTAssertNoThrow(try accepted.validated())
    }

    func testScalarReferenceAppliesInterpretationToBT709Input() {
        let signal = SIMD3<Float>(repeating: midSignal)
        let oetf = HDRReference.process(
            signalRGB: signal,
            configuration: neutralConfiguration(.sceneReferredInverseOETF),
            transferFunction: .bt709
        )
        let bt1886 = HDRReference.process(
            signalRGB: signal,
            configuration: neutralConfiguration(.bt1886),
            transferFunction: .bt709
        )
        let expectedOETF = independentInverseOETF(midSignal)
        let expectedBT1886 = pow(midSignal, 2.4)
        XCTAssertEqual(oetf.x, expectedOETF, accuracy: expectedOETF * 1e-4)
        XCTAssertEqual(bt1886.x, expectedBT1886, accuracy: expectedBT1886 * 1e-4)
        // The documented input-domain gap: roughly 27% lower linear light for
        // BT.1886 at code 128 (about 37% relative to the BT.1886 value).
        XCTAssertLessThan(bt1886.x, oetf.x * 0.8)

        // sRGB-tagged input is unaffected by the BT.709 policy.
        let srgbOETF = HDRReference.process(
            signalRGB: signal,
            configuration: neutralConfiguration(.sceneReferredInverseOETF),
            transferFunction: .sRGB
        )
        let srgbBT1886 = HDRReference.process(
            signalRGB: signal,
            configuration: neutralConfiguration(.bt1886),
            transferFunction: .sRGB
        )
        XCTAssertEqual(srgbOETF, srgbBT1886)
    }

    func testMetalTransformMatchesIndependentDefinitionsForBothPolicies() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let cases: [(HDRSDRInputInterpretation, Float)] = [
            (.sceneReferredInverseOETF, independentInverseOETF(midSignal)),
            (.bt1886, pow(midSignal, 2.4))
        ]
        for (interpretation, expected) in cases {
            let processor = try HDRProcessor(device: device, configuration: neutralConfiguration(interpretation))
            let buffer = try makeBT709TaggedBGRA(code: midCode)
            let command = try processor.makeCommandBuffer()
            let frame = try processor.process(pixelBuffer: buffer, commandBuffer: command)
            command.commit()
            command.waitUntilCompleted()
            XCTAssertEqual(command.status, .completed)
            let pixel = try readFirstRGBA16FloatPixel(from: frame.texture, device: device)
            for channel in [pixel.x, pixel.y, pixel.z] {
                // RGBA16Float carries ~11 significant bits.
                XCTAssertEqual(channel, expected, accuracy: expected * 2e-3,
                               "\(interpretation.identifier) mid-grey mismatch")
            }
        }
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
