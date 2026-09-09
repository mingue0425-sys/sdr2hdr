import CoreMedia
import CoreVideo
import Foundation
import Metal
import simd
import XCTest
@testable import HDRCore

final class ChromaReconstructionTests: XCTestCase {
    func testCalibratedV4KeepsNearestChromaAndProductionValues() {
        let configuration = HDRConfiguration.calibratedV4
        XCTAssertEqual(configuration.chromaReconstructionMode, .nearest)
        XCTAssertEqual(configuration.paperWhiteNits, 190)
        XCTAssertEqual(configuration.peakNits, 1008.6863, accuracy: 0.000001)
        XCTAssertEqual(configuration.highlightStrength, 0.6208221, accuracy: 0.0000001)
        XCTAssertEqual(configuration.contrastStrength, 0.90542316, accuracy: 0.0000001)
        XCTAssertEqual(configuration.saturationCompensation, 0.43140942, accuracy: 0.0000001)
        XCTAssertEqual(configuration.shadowProtection, 0.4755874, accuracy: 0.0000001)
        XCTAssertEqual(configuration.temporalStability, 0.7308984, accuracy: 0.0000001)
        XCTAssertEqual(configuration.masteringHeadroom, 5.308875, accuracy: 0.000001)
        XCTAssertEqual(configuration.toneCurveRevision, .sceneRelativeV4)
        XCTAssertEqual(configuration.sceneHistogramStrategy, .production)
    }

    func testDV420SitingAwareFallsBackToNearest() {
        let decision = HDRChromaReconstructionResolver.resolve(
            requested: .sitingAwareBilinear,
            siting: .dv420
        )

        XCTAssertEqual(decision.requested, .sitingAwareBilinear)
        XCTAssertEqual(decision.effective, .nearest)
        XCTAssertEqual(decision.siting, .dv420)
        XCTAssertTrue(decision.fallbackUsed)
        XCTAssertEqual(
            decision.fallbackReason,
            .dv420RequiresComponentSpecificPhase
        )
    }

    func testDV420NearestDoesNotReportFallback() {
        let decision = HDRChromaReconstructionResolver.resolve(
            requested: .nearest,
            siting: .dv420
        )

        XCTAssertEqual(decision.requested, .nearest)
        XCTAssertEqual(decision.effective, .nearest)
        XCTAssertEqual(decision.siting, .dv420)
        XCTAssertFalse(decision.fallbackUsed)
        XCTAssertNil(decision.fallbackReason)
    }

    func testSupportedSitingAwareModesRemainBilinear() {
        for siting in [
            HDRChromaSiting.center,
            .left,
            .topLeft,
            .top,
            .bottomLeft,
            .bottom
        ] {
            let decision = HDRChromaReconstructionResolver.resolve(
                requested: .sitingAwareBilinear,
                siting: siting
            )

            XCTAssertEqual(decision.effective, .sitingAwareBilinear, "siting=\(siting)")
            XCTAssertFalse(decision.fallbackUsed, "siting=\(siting)")
            XCTAssertNil(decision.fallbackReason, "siting=\(siting)")
        }
    }

    func testUnspecifiedSitingRetainsCenteredCandidatePolicy() {
        let decision = HDRChromaReconstructionResolver.resolve(
            requested: .sitingAwareBilinear,
            siting: .unspecified
        )

        XCTAssertEqual(decision.effective, .sitingAwareBilinear)
        XCTAssertFalse(decision.fallbackUsed)
        XCTAssertNil(decision.fallbackReason)
    }

    func testDV420SitingAwareDecisionIsDeterministic() {
        let expected = HDRChromaReconstructionDecision(
            requested: .sitingAwareBilinear,
            effective: .nearest,
            siting: .dv420,
            fallbackReason: .dv420RequiresComponentSpecificPhase
        )

        for _ in 0..<10 {
            XCTAssertEqual(
                HDRChromaReconstructionResolver.resolve(
                    requested: .sitingAwareBilinear,
                    siting: .dv420
                ),
                expected
            )
        }
    }

    func testChromaLocationMetadataResolvesCenterAndLeft() throws {
        let centerBuffer = try makeNV12(width: 8, height: 4, chromaLocation: .center)
        let center = try HDRColorMetadataResolver.resolve(
            pixelBuffer: centerBuffer,
            fallbackPolicy: .requireMetadata
        )
        XCTAssertEqual(center.chromaGeometry.resolvedSiting, HDRChromaSiting.center)
        XCTAssertEqual(center.chromaGeometry.sampleCenterX, 1)
        XCTAssertEqual(center.chromaGeometry.sampleCenterY, 1)
        XCTAssertTrue(center.chromaGeometry.metadataWasExplicit)

        let leftBuffer = try makeNV12(width: 8, height: 4, chromaLocation: .left)
        let left = try HDRColorMetadataResolver.resolve(
            pixelBuffer: leftBuffer,
            fallbackPolicy: .requireMetadata
        )
        XCTAssertEqual(left.chromaGeometry.resolvedSiting, HDRChromaSiting.left)
        XCTAssertEqual(left.chromaGeometry.sampleCenterX, 0.5)
        XCTAssertEqual(left.chromaGeometry.sampleCenterY, 1)
        XCTAssertTrue(left.chromaGeometry.metadataWasExplicit)
    }

    func testChromaLocationMetadataResolvesTopLeftAndFieldMismatchSafely() throws {
        let buffer = try makeNV12(width: 8, height: 4, chromaLocation: .topLeft)
        let resolved = try HDRColorMetadataResolver.resolve(
            pixelBuffer: buffer,
            fallbackPolicy: .requireMetadata
        )
        XCTAssertEqual(resolved.chromaGeometry.resolvedSiting, HDRChromaSiting.topLeft)
        XCTAssertEqual(resolved.chromaGeometry.sampleCenterX, 0.5)
        XCTAssertEqual(resolved.chromaGeometry.sampleCenterY, 0.5)

        let mismatched = try makeNV12(width: 8, height: 4, chromaLocation: .left)
        CVBufferSetAttachment(
            mismatched,
            kCVImageBufferChromaLocationBottomFieldKey,
            kCVImageBufferChromaLocation_TopLeft,
            .shouldPropagate
        )
        let fallback = try HDRColorMetadataResolver.resolve(
            pixelBuffer: mismatched,
            fallbackPolicy: .requireMetadata
        )
        XCTAssertEqual(fallback.chromaGeometry.resolvedSiting, HDRChromaSiting.center)
        XCTAssertEqual(fallback.chromaGeometry.metadataWasExplicit, false)
        XCTAssertTrue(fallback.chromaGeometry.metadataDescription.contains("mixed"))
    }

    func testChromaLocationMetadataResolvesDV420() throws {
        let buffer = try makeNV12(width: 8, height: 4, chromaLocation: .dv420)
        let resolved = try HDRColorMetadataResolver.resolve(
            pixelBuffer: buffer,
            fallbackPolicy: .requireMetadata
        )

        XCTAssertEqual(resolved.chromaGeometry.resolvedSiting, .dv420)
        XCTAssertEqual(resolved.chromaGeometry.sampleCenterX, 0.5)
        XCTAssertEqual(resolved.chromaGeometry.sampleCenterY, 1)
        XCTAssertTrue(resolved.chromaGeometry.metadataWasExplicit)
        XCTAssertEqual(resolved.chromaGeometry.metadataDescription, "dv420")
    }

    func testMissingChromaMetadataUsesDocumentedCenterFallback() throws {
        let buffer = try makeNV12(width: 8, height: 4, chromaLocation: nil)
        let resolved = try HDRColorMetadataResolver.resolve(
            pixelBuffer: buffer,
            fallbackPolicy: .requireMetadata
        )
        XCTAssertEqual(resolved.chromaGeometry.resolvedSiting, HDRChromaSiting.center)
        XCTAssertEqual(resolved.chromaGeometry.sampleCenterX, 1)
        XCTAssertEqual(resolved.chromaGeometry.sampleCenterY, 1)
        XCTAssertEqual(resolved.chromaGeometry.metadataDescription, "unspecified(default=center)")
        XCTAssertFalse(resolved.chromaGeometry.metadataWasExplicit)
    }

    func testSitingAwareReconstructionReducesVerticalEdgeError() {
        let width = 64
        let height = 4
        let plane = makeVerticalRamp(width: width, height: height, sampleCenterX: 0.5, sampleCenterY: 1)
        let truth = (0..<width).map { verticalRamp(at: Float($0) + 0.5) }
        let nearest = (0..<width).map {
            plane.nearest(lumaX: $0, lumaY: 0).y
        }
        let centered = (0..<width).map {
            plane.bilinear(lumaX: $0, lumaY: 0, sampleCenterX: 1, sampleCenterY: 1).y
        }
        let sitingAware = (0..<width).map {
            plane.bilinear(lumaX: $0, lumaY: 0, sampleCenterX: 0.5, sampleCenterY: 1).y
        }

        let nearestError = meanAbsoluteError(nearest, truth)
        let centeredError = meanAbsoluteError(centered, truth)
        let sitingError = meanAbsoluteError(sitingAware, truth)
        let nearestEdgeError = abs(edgePosition(nearest) - 32)
        let centeredEdgeError = abs(edgePosition(centered) - 32)
        let sitingEdgeError = abs(edgePosition(sitingAware) - 32)
        let nearestRGBError = rgbP95Error(nearest, truth)
        let centeredRGBError = rgbP95Error(centered, truth)
        let sitingRGBError = rgbP95Error(sitingAware, truth)
        print(
            "CHROMA_VERTICAL nearest=\(nearestError) centered=\(centeredError) " +
                "sitingAware=\(sitingError) edge=\(nearestEdgeError)/\(centeredEdgeError)/\(sitingEdgeError) " +
                "rgbP95=\(nearestRGBError)/\(centeredRGBError)/\(sitingRGBError)"
        )

        XCTAssertLessThan(sitingError, nearestError)
        XCTAssertLessThanOrEqual(sitingEdgeError, nearestEdgeError + 1e-6)
    }

    func testSitingAwareReconstructionReducesHorizontalEdgeError() {
        let width = 4
        let height = 64
        let plane = makeHorizontalRamp(width: width, height: height, sampleCenterX: 1, sampleCenterY: 0.5)
        let truth = (0..<height).map { horizontalRamp(at: Float($0) + 0.5) }
        let nearest = (0..<height).map {
            plane.nearest(lumaX: 0, lumaY: $0).y
        }
        let centered = (0..<height).map {
            plane.bilinear(lumaX: 0, lumaY: $0, sampleCenterX: 1, sampleCenterY: 1).y
        }
        let sitingAware = (0..<height).map {
            plane.bilinear(lumaX: 0, lumaY: $0, sampleCenterX: 1, sampleCenterY: 0.5).y
        }

        let nearestError = meanAbsoluteError(nearest, truth)
        let centeredError = meanAbsoluteError(centered, truth)
        let sitingError = meanAbsoluteError(sitingAware, truth)
        let nearestEdgeError = abs(edgePosition(nearest) - 32)
        let centeredEdgeError = abs(edgePosition(centered) - 32)
        let sitingEdgeError = abs(edgePosition(sitingAware) - 32)
        let nearestRGBError = rgbP95Error(nearest, truth)
        let centeredRGBError = rgbP95Error(centered, truth)
        let sitingRGBError = rgbP95Error(sitingAware, truth)
        print(
            "CHROMA_HORIZONTAL nearest=\(nearestError) centered=\(centeredError) " +
                "sitingAware=\(sitingError) edge=\(nearestEdgeError)/\(centeredEdgeError)/\(sitingEdgeError) " +
                "rgbP95=\(nearestRGBError)/\(centeredRGBError)/\(sitingRGBError)"
        )

        XCTAssertLessThan(sitingError, nearestError)
        XCTAssertLessThanOrEqual(sitingEdgeError, nearestEdgeError + 1e-6)
    }

    func testNV12ChromaReconstructionMatchesIndependentScalarReference() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device unavailable")
        }
        let output = try processChromaFixture(format: .nv12, device: device)
        XCTAssertLessThanOrEqual(output.maximumError, 0.012)
        print("CHROMA_NV12_SCALAR_PARITY maxError=\(output.maximumError)")
    }

    func testP010ChromaReconstructionMatchesIndependentScalarReference() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device unavailable")
        }
        let output = try processChromaFixture(format: .p010, device: device)
        XCTAssertLessThanOrEqual(output.maximumError, 0.012)
        print("CHROMA_P010_SCALAR_PARITY maxError=\(output.maximumError)")
    }

    func testDV420FallbackMatchesNearestNV12() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device unavailable")
        }

        let fallback = try processChromaFixture(
            format: .nv12,
            mode: .sitingAwareBilinear,
            chromaLocation: .dv420,
            device: device
        ).pixels
        let nearest = try processChromaFixture(
            format: .nv12,
            mode: .nearest,
            chromaLocation: .dv420,
            device: device
        ).pixels

        let maximumDifference = maximumDelta(fallback, nearest)
        print("CHROMA_DV420_NV12_FALLBACK maxDelta=\(maximumDifference)")
        XCTAssertLessThanOrEqual(maximumDifference, 1e-6)
    }

    func testDV420FallbackMatchesNearestP010() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device unavailable")
        }

        let fallback = try processChromaFixture(
            format: .p010,
            mode: .sitingAwareBilinear,
            chromaLocation: .dv420,
            device: device
        ).pixels
        let nearest = try processChromaFixture(
            format: .p010,
            mode: .nearest,
            chromaLocation: .dv420,
            device: device
        ).pixels

        let maximumDifference = maximumDelta(fallback, nearest)
        print("CHROMA_DV420_P010_FALLBACK maxDelta=\(maximumDifference)")
        XCTAssertLessThanOrEqual(maximumDifference, 1e-6)
    }

    func testDV420DiagnosticReportsRequestedAndEffectiveModes() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device unavailable")
        }

        let pixelBuffer = try makeNV12(
            width: 8,
            height: 4,
            chromaLocation: .dv420
        )
        var configuration = HDRConfiguration.calibratedV4
        configuration.chromaReconstructionMode = .sitingAwareBilinear
        let processor = try HDRProcessor(device: device, configuration: configuration)
        processor.debugInstrumentationEnabled = true
        let commandBuffer = try processor.makeCommandBuffer()
        _ = try processor.process(
            pixelBuffer: pixelBuffer,
            timestamp: CMTime(value: 0, timescale: 24),
            commandBuffer: commandBuffer,
            diagnosticFrameIndex: 1
        )
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        let diagnostic = try XCTUnwrap(processor.lastFrameDiagnostic)
        XCTAssertEqual(diagnostic.resolvedChromaSiting, HDRChromaSiting.dv420.rawValue)
        XCTAssertEqual(diagnostic.requestedChromaReconstructionMode, "siting-aware-bilinear")
        XCTAssertEqual(diagnostic.effectiveChromaReconstructionMode, "nearest")
        XCTAssertEqual(diagnostic.chromaReconstructionMode, "nearest")
        XCTAssertEqual(
            diagnostic.chromaReconstructionFallbackReason,
            HDRChromaReconstructionFallbackReason.dv420RequiresComponentSpecificPhase.rawValue
        )
    }

    func testPrecisionAndReconstructionMatrixSeparatesNV12AndP010Effects() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device unavailable")
        }
        let nv12Nearest = try processChromaFixture(format: .nv12, mode: .nearest, device: device).pixels
        let nv12Bilinear = try processChromaFixture(format: .nv12, mode: .sitingAwareBilinear, device: device).pixels
        let p010Nearest = try processChromaFixture(format: .p010, mode: .nearest, device: device).pixels
        let p010Bilinear = try processChromaFixture(format: .p010, mode: .sitingAwareBilinear, device: device).pixels

        let nv12ReconstructionDelta = maximumDelta(nv12Nearest, nv12Bilinear)
        let p010ReconstructionDelta = maximumDelta(p010Nearest, p010Bilinear)
        let nearestPrecisionDelta = maximumDelta(nv12Nearest, p010Nearest)
        let bilinearPrecisionDelta = maximumDelta(nv12Bilinear, p010Bilinear)
        print(
            "CHROMA_2X2 nv12Reconstruction=\(nv12ReconstructionDelta) " +
                "p010Reconstruction=\(p010ReconstructionDelta) " +
                "nearestPrecision=\(nearestPrecisionDelta) bilinearPrecision=\(bilinearPrecisionDelta)"
        )

        XCTAssertGreaterThan(nv12ReconstructionDelta, 0.0001)
        XCTAssertGreaterThan(p010ReconstructionDelta, 0.0001)
        XCTAssertLessThanOrEqual(nearestPrecisionDelta, 0.002)
        XCTAssertLessThanOrEqual(bilinearPrecisionDelta, 0.002)
    }

    func testNeutralChromaRemainsNeutralForNV12AndP010() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device unavailable")
        }
        for format in [FixtureFormat.nv12, .p010] {
            let result = try processNeutralFixture(format: format, mode: .sitingAwareBilinear, device: device)
            print("CHROMA_NEUTRAL format=\(format) maxChannelSpread=\(result.maximumChannelSpread)")
            XCTAssertLessThan(result.maximumChannelSpread, 0.003, "format=\(format)")
        }
    }

    func testExistingGrayscaleOutputDoesNotRegressBetweenNearestAndSitingAwareModes() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device unavailable")
        }
        for format in [FixtureFormat.nv12, .p010] {
            let nearest = try processNeutralFixture(format: format, mode: .nearest, device: device).pixels
            let sitingAware = try processNeutralFixture(format: format, mode: .sitingAwareBilinear, device: device).pixels
            let maximumDelta = zip(nearest, sitingAware)
                .map { abs(Float($0.0) - Float($0.1)) }
                .max() ?? 0
            print("CHROMA_GRAYSCALE format=\(format) nearestVsSitingAwareMaxDelta=\(maximumDelta)")
            XCTAssertLessThanOrEqual(maximumDelta, 0.002, "format=\(format)")
        }
    }

    func testChromaSamplingClampsImageBoundaries() {
        let samples = [
            SIMD2<Float>(0.1, 0.2), SIMD2<Float>(0.3, 0.4),
            SIMD2<Float>(0.5, 0.6), SIMD2<Float>(0.7, 0.8)
        ]
        let plane = ScalarChromaPlane(width: 2, height: 2, values: samples)
        let corners = [
            plane.bilinear(lumaX: 0, lumaY: 0, sampleCenterX: 0.5, sampleCenterY: 0.5),
            plane.bilinear(lumaX: 3, lumaY: 0, sampleCenterX: 0.5, sampleCenterY: 0.5),
            plane.bilinear(lumaX: 0, lumaY: 3, sampleCenterX: 0.5, sampleCenterY: 0.5),
            plane.bilinear(lumaX: 3, lumaY: 3, sampleCenterX: 0.5, sampleCenterY: 0.5)
        ]
        XCTAssertTrue(corners.flatMap { [$0.x, $0.y] }.allSatisfy(\.isFinite))
        XCTAssertEqual(corners.first, samples[0])
        XCTAssertEqual(corners.last, samples[3])
    }

    func testTemporalEstimatorUsesTheSameResolvedChromaGeometry() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device unavailable")
        }
        let chromaCodes = (0..<9).flatMap { row in
            (0..<8).map { column in
                let code: UInt8 = column.isMultiple(of: 2) ? 64 : 240
                return SIMD2(code, UInt8(128 + (row.isMultiple(of: 2) ? 64 : 0)))
            }
        }

        func run(mode: HDRChromaReconstructionMode) throws -> HDRSceneStatistics {
            let buffer = try makeNV12(
                width: 16,
                height: 18,
                yCode: 128,
                chromaCodes: chromaCodes,
                chromaLocation: .left
            )
            let resolved = try HDRColorMetadataResolver.resolve(
                pixelBuffer: buffer,
                fallbackPolicy: .requireMetadata
            )
            XCTAssertEqual(resolved.chromaGeometry.resolvedSiting, HDRChromaSiting.left)
            XCTAssertEqual(resolved.chromaGeometry.sampleCenterX, 0.5)
            XCTAssertEqual(resolved.chromaGeometry.sampleCenterY, 1)

            var configuration = HDRConfiguration.calibratedV4
            configuration.chromaReconstructionMode = mode
            let processor = try HDRProcessor(device: device, configuration: configuration)
            processor.temporalTraceEnabled = true
            let commandBuffer = try processor.makeCommandBuffer()
            _ = try processor.process(
                pixelBuffer: buffer,
                timestamp: CMTime(value: 0, timescale: 24),
                commandBuffer: commandBuffer,
                diagnosticFrameIndex: 1
            )
            commandBuffer.commit()
            commandBuffer.waitUntilCompleted()
            XCTAssertEqual(commandBuffer.status, .completed)
            XCTAssertNil(commandBuffer.error)
            XCTAssertEqual(processor.lastAdaptiveCommittedSequence, 1)
            XCTAssertEqual(processor.temporalCompletionTrace.first?.temporalStateVersionProduced, 1)
            XCTAssertEqual(processor.temporalCompletionTrace.first?.sceneStateVersionProduced, 1)
            return processor.causalSceneStatistics
        }

        let nearest = try run(mode: .nearest)
        let sitingAware = try run(mode: .sitingAwareBilinear)
        let maximumDifference = [
            abs(nearest.p01 - sitingAware.p01),
            abs(nearest.p05 - sitingAware.p05),
            abs(nearest.p10 - sitingAware.p10),
            abs(nearest.p25 - sitingAware.p25),
            abs(nearest.p50 - sitingAware.p50),
            abs(nearest.p90 - sitingAware.p90),
            abs(nearest.p99 - sitingAware.p99)
        ].max() ?? 0
        print("CHROMA_TEMPORAL_GEOMETRY nearestP50=\(nearest.p50) sitingAwareP50=\(sitingAware.p50) maxDelta=\(maximumDifference)")
        XCTAssertGreaterThan(maximumDifference, 0.0001)
    }

    func testDV420FallbackKeepsTemporalEstimatorAlignedWithNearest() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device unavailable")
        }
        let chromaCodes = (0..<2).flatMap { row in
            (0..<4).map { column in
                SIMD2(
                    UInt8(column.isMultiple(of: 2) ? 64 : 240),
                    UInt8(row.isMultiple(of: 2) ? 64 : 192)
                )
            }
        }

        func run(mode: HDRChromaReconstructionMode) throws -> HDRSceneStatistics {
            let buffer = try makeNV12(
                width: 8,
                height: 4,
                yCode: 128,
                chromaCodes: chromaCodes,
                chromaLocation: .dv420
            )
            var configuration = HDRConfiguration.calibratedV4
            configuration.chromaReconstructionMode = mode
            let processor = try HDRProcessor(device: device, configuration: configuration)
            let commandBuffer = try processor.makeCommandBuffer()
            _ = try processor.process(
                pixelBuffer: buffer,
                timestamp: CMTime(value: 0, timescale: 24),
                commandBuffer: commandBuffer,
                diagnosticFrameIndex: 1
            )
            commandBuffer.commit()
            commandBuffer.waitUntilCompleted()
            XCTAssertEqual(commandBuffer.status, .completed)
            XCTAssertNil(commandBuffer.error)
            return processor.causalSceneStatistics
        }

        let fallback = try run(mode: .sitingAwareBilinear)
        let nearest = try run(mode: .nearest)
        let maximumDifference = [
            abs(fallback.p01 - nearest.p01),
            abs(fallback.p05 - nearest.p05),
            abs(fallback.p10 - nearest.p10),
            abs(fallback.p25 - nearest.p25),
            abs(fallback.p50 - nearest.p50),
            abs(fallback.p90 - nearest.p90),
            abs(fallback.p99 - nearest.p99)
        ].max() ?? 0
        print("CHROMA_DV420_TEMPORAL_FALLBACK maxDelta=\(maximumDifference)")
        XCTAssertLessThanOrEqual(maximumDifference, 1e-6)
    }

    private enum FixtureFormat: CustomStringConvertible {
        case nv12
        case p010

        var description: String {
            switch self {
            case .nv12: return "NV12"
            case .p010: return "P010"
            }
        }
    }

    private struct ScalarChromaPlane {
        let width: Int
        let height: Int
        let values: [SIMD2<Float>]

        func nearest(lumaX: Int, lumaY: Int) -> SIMD2<Float> {
            values[index(x: min(lumaX / 2, width - 1), y: min(lumaY / 2, height - 1))]
        }

        func bilinear(
            lumaX: Int,
            lumaY: Int,
            sampleCenterX: Float,
            sampleCenterY: Float
        ) -> SIMD2<Float> {
            let lumaCenter = SIMD2(Float(lumaX) + 0.5, Float(lumaY) + 0.5)
            let coordinate = (lumaCenter - SIMD2(sampleCenterX, sampleCenterY)) / 2
            let clampedX = min(max(coordinate.x, 0), Float(width - 1))
            let clampedY = min(max(coordinate.y, 0), Float(height - 1))
            let lowerX = Int(floor(clampedX))
            let lowerY = Int(floor(clampedY))
            let upperX = min(lowerX + 1, width - 1)
            let upperY = min(lowerY + 1, height - 1)
            let fractionX = clampedX - Float(lowerX)
            let fractionY = clampedY - Float(lowerY)
            let lowerRow = values[index(x: lowerX, y: lowerY)] +
                (values[index(x: upperX, y: lowerY)] - values[index(x: lowerX, y: lowerY)]) * fractionX
            let upperRow = values[index(x: lowerX, y: upperY)] +
                (values[index(x: upperX, y: upperY)] - values[index(x: lowerX, y: upperY)]) * fractionX
            return lowerRow + (upperRow - lowerRow) * fractionY
        }

        private func index(x: Int, y: Int) -> Int {
            y * width + x
        }
    }

    private struct MetalFixtureResult {
        let pixels: [Float16]
        let expected: [Float]

        var maximumError: Float {
            zip(pixels, expected)
                .map { abs(Float($0.0) - $0.1) }
                .max() ?? 0
        }
    }

    private struct NeutralFixtureResult {
        let pixels: [Float16]

        var maximumChannelSpread: Float {
            stride(from: 0, to: pixels.count, by: 4).map { index in
                let rgb = [Float(pixels[index]), Float(pixels[index + 1]), Float(pixels[index + 2])]
                return (rgb.max() ?? 0) - (rgb.min() ?? 0)
            }.max() ?? 0
        }
    }

    private func processChromaFixture(
        format: FixtureFormat,
        mode: HDRChromaReconstructionMode = .sitingAwareBilinear,
        chromaLocation: HDRChromaSiting = .left,
        device: MTLDevice
    ) throws -> MetalFixtureResult {
        let width = 8
        let height = 4
        let chromaValues = (0..<2).flatMap { row in
            (0..<4).map { column in
                let cb = UInt16(384 + column * 48 + row * 8)
                let cr = UInt16(640 - column * 48 - row * 8)
                return SIMD2(cb, cr)
            }
        }
        let yCode8: UInt8 = 128
        let yCode10: UInt16 = 512
        let pixelBuffer: CVPixelBuffer
        let plane: ScalarChromaPlane
        let ySignal: Float
        let chromaOffset: Float
        let chromaScale: Float
        switch format {
        case .nv12:
            pixelBuffer = try makeNV12(
                width: width,
                height: height,
                yCode: yCode8,
                chromaCodes: chromaValues.map { SIMD2(UInt8($0.x / 4), UInt8($0.y / 4)) },
                chromaLocation: chromaLocation
            )
            plane = ScalarChromaPlane(
                width: 4,
                height: 2,
                values: chromaValues.map {
                    SIMD2(Float($0.x / 4) / 255, Float($0.y / 4) / 255)
                }
            )
            ySignal = (Float(yCode8) - 16) / 219
            chromaOffset = 128 / 255
            chromaScale = 255 / 224
        case .p010:
            pixelBuffer = try makeP010(
                width: width,
                height: height,
                yCode: yCode10,
                chromaCodes: chromaValues,
                chromaLocation: chromaLocation
            )
            plane = ScalarChromaPlane(
                width: 4,
                height: 2,
                values: chromaValues.map {
                    SIMD2(Float($0.x) / 1023, Float($0.y) / 1023)
                }
            )
            ySignal = (Float(yCode10) / 1023 - 64 / 1023) * (1023 / 876)
            chromaOffset = 512 / 1023
            chromaScale = 1023 / 896
        }

        var configuration = HDRConfiguration.calibratedV4
        configuration.toneCurveRevision = .legacyV2
        configuration.chromaReconstructionMode = mode
        let effectiveMode = HDRChromaReconstructionResolver.resolve(
            requested: mode,
            siting: chromaLocation
        ).effective
        let processor = try HDRProcessor(device: device, configuration: configuration)
        processor.automaticTemporalEstimationEnabled = false
        let commandBuffer = try processor.makeCommandBuffer()
        let frame = try processor.process(
            pixelBuffer: pixelBuffer,
            timestamp: CMTime(value: 0, timescale: 24),
            commandBuffer: commandBuffer,
            diagnosticFrameIndex: 1
        )
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        XCTAssertEqual(commandBuffer.status, .completed)
        XCTAssertNil(commandBuffer.error)
        let actual = try readRGBA16FloatPixels(from: frame.texture, device: device)

        var expected: [Float] = []
        expected.reserveCapacity(width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let chroma: SIMD2<Float>
                switch effectiveMode {
                case .nearest:
                    chroma = plane.nearest(lumaX: x, lumaY: y)
                case .sitingAwareBilinear:
                    chroma = plane.bilinear(
                        lumaX: x,
                        lumaY: y,
                        sampleCenterX: 0.5,
                        sampleCenterY: 1
                    )
                }
                let cb = (chroma.x - chromaOffset) * chromaScale
                let cr = (chroma.y - chromaOffset) * chromaScale
                let signalRGB = SIMD3(
                    ySignal + 1.5748 * cr,
                    ySignal - 0.187324 * cb - 0.468124 * cr,
                    ySignal + 1.8556 * cb
                )
                let reference = HDRReference.process(
                    signalRGB: signalRGB,
                    configuration: configuration
                )
                expected.append(contentsOf: [reference.x, reference.y, reference.z, reference.w])
            }
        }
        return MetalFixtureResult(pixels: actual, expected: expected)
    }

    private func processNeutralFixture(
        format: FixtureFormat,
        mode: HDRChromaReconstructionMode,
        device: MTLDevice
    ) throws -> NeutralFixtureResult {
        let width = 8
        let height = 4
        let pixelBuffer: CVPixelBuffer
        switch format {
        case .nv12:
            pixelBuffer = try makeNV12(
                width: width,
                height: height,
                yCode: 128,
                chromaCodes: Array(repeating: SIMD2(UInt8(128), UInt8(128)), count: 8),
                chromaLocation: .left
            )
        case .p010:
            pixelBuffer = try makeP010(
                width: width,
                height: height,
                yCode: 512,
                chromaCodes: Array(repeating: SIMD2(UInt16(512), UInt16(512)), count: 8),
                chromaLocation: .left
            )
        }
        var configuration = HDRConfiguration.calibratedV4
        configuration.toneCurveRevision = .legacyV2
        configuration.chromaReconstructionMode = mode
        let processor = try HDRProcessor(device: device, configuration: configuration)
        processor.automaticTemporalEstimationEnabled = false
        let commandBuffer = try processor.makeCommandBuffer()
        let frame = try processor.process(pixelBuffer: pixelBuffer, commandBuffer: commandBuffer)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        XCTAssertEqual(commandBuffer.status, .completed)
        XCTAssertNil(commandBuffer.error)
        return NeutralFixtureResult(pixels: try readRGBA16FloatPixels(from: frame.texture, device: device))
    }

    private func makeVerticalRamp(
        width: Int,
        height: Int,
        sampleCenterX: Float,
        sampleCenterY: Float
    ) -> ScalarChromaPlane {
        let chromaWidth = width / 2
        let chromaHeight = height / 2
        let values = (0..<chromaHeight).flatMap { row in
            (0..<chromaWidth).map { column in
                SIMD2(0.5, verticalRamp(at: sampleCenterX + Float(column * 2)))
            }
        }
        return ScalarChromaPlane(width: chromaWidth, height: chromaHeight, values: values)
    }

    private func makeHorizontalRamp(
        width: Int,
        height: Int,
        sampleCenterX: Float,
        sampleCenterY: Float
    ) -> ScalarChromaPlane {
        let chromaWidth = width / 2
        let chromaHeight = height / 2
        let values = (0..<chromaHeight).flatMap { row in
            (0..<chromaWidth).map { _ in
                SIMD2(0.5, horizontalRamp(at: sampleCenterY + Float(row * 2)))
            }
        }
        return ScalarChromaPlane(width: chromaWidth, height: chromaHeight, values: values)
    }

    private func verticalRamp(at x: Float) -> Float {
        min(max((x - 24) / 16, 0), 1)
    }

    private func horizontalRamp(at y: Float) -> Float {
        min(max((y - 24) / 16, 0), 1)
    }

    private func meanAbsoluteError(_ lhs: [Float], _ rhs: [Float]) -> Float {
        zip(lhs, rhs).map { abs($0.0 - $0.1) }.reduce(0, +) / Float(lhs.count)
    }

    private func maximumDelta(_ lhs: [Float16], _ rhs: [Float16]) -> Float {
        zip(lhs, rhs).map { abs(Float($0.0) - Float($0.1)) }.max() ?? 0
    }

    private func edgePosition(_ values: [Float]) -> Float {
        for index in 0..<(values.count - 1) {
            let lower = values[index]
            let upper = values[index + 1]
            if lower <= 0.5 && upper >= 0.5 && upper > lower {
                let fraction = (0.5 - lower) / (upper - lower)
                return Float(index) + 0.5 + fraction
            }
        }
        return .infinity
    }

    private func rgbP95Error(_ reconstructed: [Float], _ truth: [Float]) -> Float {
        let errors = zip(reconstructed, truth).flatMap { value -> [Float] in
            let reconstructedRGB = rgbSignal(cr: value.0)
            let truthRGB = rgbSignal(cr: value.1)
            return [
                abs(reconstructedRGB.x - truthRGB.x),
                abs(reconstructedRGB.y - truthRGB.y),
                abs(reconstructedRGB.z - truthRGB.z)
            ]
        }.sorted()
        let index = min(errors.count - 1, Int(ceil(Float(errors.count) * 0.95)) - 1)
        return errors[index]
    }

    private func rgbSignal(cr: Float) -> SIMD3<Float> {
        let y: Float = 0.5
        let cb: Float = 0
        let chromaR = cr - 0.5
        return SIMD3(
            y + 1.5748 * chromaR,
            y - 0.187324 * cb - 0.468124 * chromaR,
            y + 1.8556 * cb
        )
    }

    private func mix(_ lhs: SIMD2<Float>, _ rhs: SIMD2<Float>, t: Float) -> SIMD2<Float> {
        lhs + (rhs - lhs) * t
    }

    private func attachColorMetadata(_ pixelBuffer: CVPixelBuffer) {
        CVBufferSetAttachment(pixelBuffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(pixelBuffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(pixelBuffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
    }

    private func chromaLocationConstant(_ location: HDRChromaSiting) -> CFString? {
        switch location {
        case .center: return kCVImageBufferChromaLocation_Center
        case .left: return kCVImageBufferChromaLocation_Left
        case .topLeft: return kCVImageBufferChromaLocation_TopLeft
        case .top: return kCVImageBufferChromaLocation_Top
        case .bottomLeft: return kCVImageBufferChromaLocation_BottomLeft
        case .bottom: return kCVImageBufferChromaLocation_Bottom
        case .dv420: return kCVImageBufferChromaLocation_DV420
        case .unspecified: return nil
        }
    }

    private func attachChromaMetadata(_ pixelBuffer: CVPixelBuffer, location: HDRChromaSiting?) {
        guard let location, let value = chromaLocationConstant(location) else { return }
        CVBufferSetAttachment(pixelBuffer, kCVImageBufferChromaLocationTopFieldKey, value, .shouldPropagate)
        CVBufferSetAttachment(pixelBuffer, kCVImageBufferChromaLocationBottomFieldKey, value, .shouldPropagate)
    }

    private func makeNV12(
        width: Int,
        height: Int,
        yCode: UInt8,
        chromaCodes: [SIMD2<UInt8>],
        chromaLocation: HDRChromaSiting?
    ) throws -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            [
                kCVPixelBufferMetalCompatibilityKey as String: true,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:]
            ] as CFDictionary,
            &pixelBuffer
        )
        guard status == kCVReturnSuccess, let pixelBuffer else {
            throw NSError(domain: "ChromaReconstructionTests", code: Int(status))
        }
        attachColorMetadata(pixelBuffer)
        attachChromaMetadata(pixelBuffer, location: chromaLocation)
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        let yRowBytes = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        let yBase = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0))
            .assumingMemoryBound(to: UInt8.self)
        for row in 0..<height {
            for column in 0..<width {
                yBase[row * yRowBytes + column] = yCode
            }
        }
        let uvRowBytes = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1)
        let uvBase = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1))
            .assumingMemoryBound(to: UInt8.self)
        for row in 0..<(height / 2) {
            for column in 0..<(width / 2) {
                let source = chromaCodes[row * (width / 2) + column]
                let offset = row * uvRowBytes + column * 2
                uvBase[offset] = source.x
                uvBase[offset + 1] = source.y
            }
        }
        return pixelBuffer
    }

    private func makeNV12(
        width: Int,
        height: Int,
        chromaLocation: HDRChromaSiting?
    ) throws -> CVPixelBuffer {
        try makeNV12(
            width: width,
            height: height,
            yCode: 128,
            chromaCodes: Array(
                repeating: SIMD2(UInt8(128), UInt8(128)),
                count: (width / 2) * (height / 2)
            ),
            chromaLocation: chromaLocation
        )
    }

    private func makeP010(
        width: Int,
        height: Int,
        yCode: UInt16,
        chromaCodes: [SIMD2<UInt16>],
        chromaLocation: HDRChromaSiting?
    ) throws -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
            [
                kCVPixelBufferMetalCompatibilityKey as String: true,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:]
            ] as CFDictionary,
            &pixelBuffer
        )
        guard status == kCVReturnSuccess, let pixelBuffer else {
            throw NSError(domain: "ChromaReconstructionTests", code: Int(status))
        }
        attachColorMetadata(pixelBuffer)
        attachChromaMetadata(pixelBuffer, location: chromaLocation)
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        let yRowBytes = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        let yBase = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0))
            .assumingMemoryBound(to: UInt16.self)
        for row in 0..<height {
            for column in 0..<width {
                yBase[row * yRowBytes / MemoryLayout<UInt16>.stride + column] = yCode << 6
            }
        }
        let uvRowBytes = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1)
        let uvBase = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1))
            .assumingMemoryBound(to: UInt16.self)
        for row in 0..<(height / 2) {
            for column in 0..<(width / 2) {
                let source = chromaCodes[row * (width / 2) + column]
                let offset = row * uvRowBytes / MemoryLayout<UInt16>.stride + column * 2
                uvBase[offset] = source.x << 6
                uvBase[offset + 1] = source.y << 6
            }
        }
        return pixelBuffer
    }
}
