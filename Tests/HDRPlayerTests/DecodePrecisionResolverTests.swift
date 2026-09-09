import CoreVideo
import Foundation
import HDRCore
import XCTest
@testable import HDRPlayerKit

final class DecodePrecisionResolverTests: XCTestCase {
    func testAutomaticSelectsEightBitForKnownEightBitH264() {
        let source = HDRSourcePrecisionEvidence(
            codec: "avc1",
            bitDepth: 8,
            evidence: .codecConfiguration
        )

        let decision = HDRDecodePrecisionResolver.resolve(
            requested: .automatic,
            source: source
        )

        XCTAssertEqual(decision.resolved, .eightBit)
        XCTAssertEqual(decision.reason, .sourceCodecConfigurationEightBit)
        XCTAssertFalse(decision.fallbackUsed)
    }

    func testAutomaticSelectsEightBitForKnownEightBitHEVC() {
        let source = HDRSourcePrecisionEvidence(
            codec: "hvc1",
            bitDepth: 8,
            evidence: .bitsPerComponent
        )

        let decision = HDRDecodePrecisionResolver.resolve(
            requested: .automatic,
            source: source
        )

        XCTAssertEqual(decision.resolved, .eightBit)
        XCTAssertEqual(decision.reason, .sourceReportedEightBit)
        XCTAssertFalse(decision.fallbackUsed)
    }

    func testAutomaticSelectsTenBitForKnownMain10HEVC() {
        let source = HDRSourcePrecisionEvidence(
            codec: "hvc1",
            bitDepth: 10,
            evidence: .codecConfiguration
        )

        let decision = HDRDecodePrecisionResolver.resolve(
            requested: .automatic,
            source: source
        )

        XCTAssertEqual(decision.resolved, .tenBit)
        XCTAssertEqual(decision.reason, .sourceCodecConfigurationTenBit)
        XCTAssertFalse(decision.fallbackUsed)
    }

    func testAutomaticFallsBackSafelyWhenPrecisionIsUnknown() {
        let source = HDRSourcePrecisionEvidence(
            codec: "hvc1",
            bitDepth: nil,
            evidence: .unresolved
        )

        let decision = HDRDecodePrecisionResolver.resolve(
            requested: .automatic,
            source: source
        )

        XCTAssertEqual(decision.resolved, .eightBit)
        XCTAssertEqual(decision.reason, .sourcePrecisionUnresolved)
        XCTAssertTrue(decision.fallbackUsed)
        XCTAssertTrue(decision.diagnosticDescription.contains("fallback=true"))
    }

    func testExplicitEightBitOverridesAutomaticDetection() {
        let source = HDRSourcePrecisionEvidence(
            codec: "hvc1",
            bitDepth: 10,
            evidence: .bitsPerComponent
        )

        let decision = HDRDecodePrecisionResolver.resolve(
            requested: .eightBit,
            source: source
        )

        XCTAssertEqual(decision.resolved, .eightBit)
        XCTAssertEqual(decision.reason, .explicitEightBitOverride)
        XCTAssertEqual(decision.sourceBitDepth, 10)
    }

    func testExplicitTenBitPreferredOverridesAutomaticDetection() {
        let source = HDRSourcePrecisionEvidence(
            codec: "avc1",
            bitDepth: 8,
            evidence: .bitsPerComponent
        )

        let decision = HDRDecodePrecisionResolver.resolve(
            requested: .tenBitPreferred,
            source: source
        )

        XCTAssertEqual(decision.resolved, .tenBit)
        XCTAssertEqual(decision.reason, .explicitTenBitOverride)
        XCTAssertEqual(decision.sourceBitDepth, 8)
    }

    func testMalformedCodecConfigurationReturnsUnknown() {
        XCTAssertNil(
            HDRDecodePrecisionResolver.bitDepthFromCodecConfiguration(
                codec: "avc1",
                data: Data([1, 100, 0])
            )
        )
        XCTAssertNil(
            HDRDecodePrecisionResolver.bitDepthFromCodecConfiguration(
                codec: "hvc1",
                data: Data([1, 0xff])
            )
        )
    }

    func testTruncatedCodecConfigurationCannotReadOutOfBounds() {
        for codec in ["avc1", "avc3", "hvc1", "hev1"] {
            XCTAssertNil(
                HDRDecodePrecisionResolver.bitDepthFromCodecConfiguration(
                    codec: codec,
                    data: Data()
                )
            )
            XCTAssertNil(
                HDRDecodePrecisionResolver.bitDepthFromCodecConfiguration(
                    codec: codec,
                    data: Data([1])
                )
            )
        }
    }

    func testResolvedEightBitRequestsNV12() {
        let key = kCVPixelBufferPixelFormatTypeKey as String
        let attributes = HDRVideoOutputConfiguration.pixelBufferAttributes(
            forResolvedPrecision: HDRResolvedDecodePrecision.eightBit
        )
        XCTAssertEqual(
            attributes[key] as? OSType,
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        )
    }

    func testResolvedTenBitRequestsP010() {
        let key = kCVPixelBufferPixelFormatTypeKey as String
        let attributes = HDRVideoOutputConfiguration.pixelBufferAttributes(
            forResolvedPrecision: HDRResolvedDecodePrecision.tenBit
        )
        XCTAssertEqual(
            attributes[key] as? OSType,
            kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
        )
    }
}
