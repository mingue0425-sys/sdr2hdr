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

    func testHEVCMain10ProfileWithEightBitSPSResolvesEightBit() {
        let configuration = makeHEVCConfiguration(
            sps: dataFromHex(
                "4201010160000003009000000300000300ffa020829f796566b932bc05a81010082000000300200000030301"
            ),
            profileByte: 0x02
        )

        XCTAssertEqual(
            HDRDecodePrecisionResolver.bitDepthFromCodecConfiguration(
                codec: "hvc1",
                data: configuration
            ),
            8
        )
    }

    func testHEVCMain10ProfileWithTenBitSPSResolvesTenBit() {
        let configuration = makeHEVCConfiguration(
            sps: dataFromHex(
                "4201010220000003009000000300000300ffa020829f6d96566b932b9a808080820000030002000003003010"
            ),
            profileByte: 0x02
        )

        XCTAssertEqual(
            HDRDecodePrecisionResolver.bitDepthFromCodecConfiguration(
                codec: "hvc1",
                data: configuration
            ),
            10
        )
    }

    func testAVCHigh10ProfileDoesNotImplyTenBitWithoutSPSDepth() {
        var configuration = [UInt8](dataFromHex(
            "0164000affe1001b6764000aacd9447f9f016a040402800000030080000018078912cb01000668ebe3cb22c0fdf8f800"
        ))
        // The bytes are from an actual High-profile 8-bit SPS. Changing the
        // profile signalling to High10 must not manufacture 10-bit evidence.
        configuration[1] = 110
        configuration[9] = 110

        XCTAssertEqual(
            HDRDecodePrecisionResolver.bitDepthFromCodecConfiguration(
                codec: "avc1",
                data: Data(configuration)
            ),
            8
        )
    }

    func testAVCHigh10EightBitSPSResolvesEightBit() {
        var configuration = [UInt8](dataFromHex(
            "0164000affe1001b6764000aacd9447f9f016a040402800000030080000018078912cb01000668ebe3cb22c0fdf8f800"
        ))
        configuration[1] = 110
        configuration[9] = 110

        XCTAssertEqual(
            HDRDecodePrecisionResolver.bitDepthFromCodecConfiguration(
                codec: "avc1",
                data: Data(configuration)
            ),
            8
        )
    }

    func testAVCHigh10TenBitSPSResolvesTenBit() {
        let configuration = dataFromHex(
            "016e000affe1001c676e000aa6cd9447f9e6a04040280000030008000003018078912cb001000668ebe06b2c8bfdfafa00"
        )

        XCTAssertEqual(
            HDRDecodePrecisionResolver.bitDepthFromCodecConfiguration(
                codec: "avc1",
                data: configuration
            ),
            10
        )
    }

    func testTruncatedHEVCSPSFallsBackSafely() {
        let fullSPS = dataFromHex(
            "4201010220000003009000000300000300ffa020829f6d96566b932b9a808080820000030002000003003010"
        )
        let configuration = makeHEVCConfiguration(
            // Keep the hvcC array framing valid while truncating the SPS
            // before its required Exp-Golomb fields.
            sps: Data(fullSPS.prefix(10)),
            profileByte: 0x02
        )

        XCTAssertNil(
            HDRDecodePrecisionResolver.bitDepthFromCodecConfiguration(
                codec: "hvc1",
                data: configuration
            )
        )
    }

    func testTruncatedAVCSPSFallsBackSafely() {
        let fullSPS = dataFromHex(
            "676e000aa6cd9447f9e6a04040280000030008000003018078912cb0"
        )
        let configuration = makeAVCConfiguration(
            sps: Data(fullSPS.prefix(4)),
            profileByte: 110
        )

        XCTAssertNil(
            HDRDecodePrecisionResolver.bitDepthFromCodecConfiguration(
                codec: "avc1",
                data: configuration
            )
        )
    }

    func testEmulationPreventionBytesAreHandled() {
        let configuration = makeHEVCConfiguration(
            sps: dataFromHex(
                "4201010220000003009000000300000300ffa020829f6d96566b932b9a808080820000030002000003003010"
            ),
            profileByte: 0x02
        )

        XCTAssertEqual(
            HDRDecodePrecisionResolver.bitDepthFromCodecConfiguration(
                codec: "hvc1",
                data: configuration
            ),
            10
        )
    }

    func testMalformedExpGolombCannotReadOutOfBounds() {
        let configuration = makeHEVCConfiguration(
            // Leave enough header bits to reach sps_seq_parameter_set_id,
            // then provide an unterminated run of zero bits.
            sps: Data([0x42, 0x01] + Array(repeating: 0, count: 21)),
            profileByte: 0x02
        )

        XCTAssertNil(
            HDRDecodePrecisionResolver.bitDepthFromCodecConfiguration(
                codec: "hvc1",
                data: configuration
            )
        )
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

    private func dataFromHex(_ value: String) -> Data {
        let bytes = stride(from: 0, to: value.count, by: 2).compactMap { offset -> UInt8? in
            let start = value.index(value.startIndex, offsetBy: offset)
            let end = value.index(start, offsetBy: 2)
            return UInt8(value[start..<end], radix: 16)
        }
        return Data(bytes)
    }

    private func makeHEVCConfiguration(sps: Data, profileByte: UInt8) -> Data {
        let vps = dataFromHex("40010c01ffff0160000003009000000300000300ff959809")
        let pps = dataFromHex("4401c171a912")
        var result = [UInt8](dataFromHex("010220000000900000000000fff000fcfdfafa00000f03"))
        result[1] = profileByte
        appendHEVCArray(type: 32, unit: vps, to: &result)
        appendHEVCArray(type: 33, unit: sps, to: &result)
        appendHEVCArray(type: 34, unit: pps, to: &result)
        return Data(result)
    }

    private func makeAVCConfiguration(sps: Data, profileByte: UInt8) -> Data {
        let pps = dataFromHex("68ebe06b2c8b")
        var result: [UInt8] = [1, profileByte, 0, 10, 0xff, 0xe1]
        result.append(UInt8((sps.count >> 8) & 0xff))
        result.append(UInt8(sps.count & 0xff))
        result.append(contentsOf: sps)
        result.append(1)
        result.append(0)
        result.append(UInt8(pps.count))
        result.append(contentsOf: pps)
        return Data(result)
    }

    private func appendHEVCArray(type: UInt8, unit: Data, to result: inout [UInt8]) {
        result.append(0x80 | type)
        result.append(0)
        result.append(1)
        result.append(UInt8((unit.count >> 8) & 0xff))
        result.append(UInt8(unit.count & 0xff))
        result.append(contentsOf: unit)
    }
}
