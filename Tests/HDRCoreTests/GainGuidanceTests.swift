import CoreVideo
import Metal
import XCTest
import simd
@testable import HDRCore

/// Noise-gated gain guidance evaluates the expansion gain at a range-gated
/// local mean so sub-tolerance fluctuations are not stretched by the tone
/// curve's slope. It is opt-in: every preset keeps the per-pixel gain.
final class GainGuidanceTests: XCTestCase {
    private let size = 32

    func testGuidanceIsOffForEveryPresetAndClampsItsInputs() {
        let presets: [HDRConfiguration] = [
            .natural, .hdr, .vivid, .calibratedV1, .calibratedV2,
            .calibratedV3Candidate, .calibratedV4, HDRConfiguration()
        ]
        for preset in presets {
            XCTAssertEqual(preset.gainGuidance, .off)
            XCTAssertFalse(preset.gainGuidance.isEnabled)
        }
        XCTAssertEqual(HDRGainGuidance(radius: 99, tolerance: 0.03).radius, HDRGainGuidance.maximumRadius)
        XCTAssertEqual(HDRGainGuidance(radius: -1, tolerance: 0.03), .off)
        XCTAssertEqual(HDRGainGuidance(radius: 2, tolerance: 0).tolerance, 1e-4)
    }

    func testUniformFieldIsUnchangedByGuidance() throws {
        let frame = try makeFrame { _, _ in 230 }
        let plain = try render(frame, guidance: .off)
        let guided = try render(frame, guidance: .noiseGatedCandidate)
        for (a, b) in zip(plain, guided) {
            XCTAssertEqual(a, b, accuracy: max(a * 1e-3, 1e-5))
        }
    }

    func testGuidanceRemovesSlopeAmplificationOfHighlightNoise() throws {
        // Bright flat region with deterministic ±4-code grain.
        var state: UInt32 = 0x9E37_79B9
        var codes = [UInt8](repeating: 0, count: size * size)
        for index in codes.indices {
            state = state &* 1_664_525 &+ 1_013_904_223
            codes[index] = UInt8(232 + Int(state >> 29)) // 232...239
        }
        let frame = try makeFrame { x, y in codes[y * size + x] }
        let plain = pqDeviation(try render(frame, guidance: .off))
        let guided = pqDeviation(try render(frame, guidance: .noiseGatedCandidate))
        let identity = pqDeviation(try render(frame, guidance: .off, identity: true))
        // Premise: the per-pixel V4 gain amplifies the grain beyond the
        // unexpanded mapping in PQ terms.
        XCTAssertGreaterThan(plain, identity * 1.1, "plain=\(plain) identity=\(identity)")
        // Guidance brings it back near the source contrast.
        XCTAssertLessThan(guided, plain * 0.9, "guided=\(guided) plain=\(plain)")
        // and removes most of the excess: the residual comes from the
        // finite 5x5 mean, whose own grain is (slope - 1)-amplified.
        XCTAssertLessThan(guided - identity, 0.35 * (plain - identity),
                          "guided=\(guided) plain=\(plain) identity=\(identity)")
    }

    func testEdgesAboveToleranceKeepThePerPixelGain() throws {
        let frame = try makeFrame { x, _ in x < 16 ? 60 : 235 }
        let plain = try render(frame, guidance: .off)
        let guided = try render(frame, guidance: .noiseGatedCandidate)
        for (index, (a, b)) in zip(plain, guided).enumerated() {
            XCTAssertEqual(a, b, accuracy: max(a * 2e-3, 1e-5), "pixel \(index)")
        }
    }

    // MARK: - Helpers

    /// EDR-relative BT.2020 luminance per pixel.
    private func render(_ buffer: CVPixelBuffer, guidance: HDRGainGuidance, identity: Bool = false) throws -> [Float] {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        var config = HDRConfiguration.calibratedV4
        if identity {
            config.highlightStrength = 0
            config.contrastStrength = 0
            config.saturationCompensation = 0
            config.shadowProtection = 0
        }
        config.gainGuidance = guidance
        let processor = try HDRProcessor(device: device, configuration: config)
        let command = try processor.makeCommandBuffer()
        let frame = try processor.process(pixelBuffer: buffer, commandBuffer: command)
        command.commit()
        command.waitUntilCompleted()
        XCTAssertEqual(command.status, .completed)
        let halves = try readRGBA16FloatPixels(from: frame.texture, device: device)
        return (0..<(size * size)).map { index in
            let r = Float(halves[index * 4])
            let g = Float(halves[index * 4 + 1])
            let b = Float(halves[index * 4 + 2])
            let rgb = SIMD3<Float>(r, g, b)
            return max(simd_dot(rgb, HDRColorMath.bt2020Luminance), 0)
        }
    }

    private func pqDeviation(_ luminance: [Float]) -> Float {
        let pq = luminance.map { HDRColorMath.pqEncode(nits: $0 * 203) }
        let mean = pq.reduce(0, +) / Float(pq.count)
        return sqrt(pq.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Float(pq.count))
    }

    private func makeFrame(_ code: (Int, Int) -> UInt8) throws -> CVPixelBuffer {
        var result: CVPixelBuffer?
        let attributes = [kCVPixelBufferMetalCompatibilityKey as String: true,
                          kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, size, size,
                                           kCVPixelFormatType_32BGRA, attributes, &result), kCVReturnSuccess)
        let buffer = try XCTUnwrap(result)
        XCTAssertEqual(CVPixelBufferLockBaseAddress(buffer, []), kCVReturnSuccess)
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(buffer))
        for y in 0..<size {
            let row = base.advanced(by: y * CVPixelBufferGetBytesPerRow(buffer)).assumingMemoryBound(to: UInt8.self)
            for x in 0..<size {
                let value = code(x, y)
                row[4 * x] = value
                row[4 * x + 1] = value
                row[4 * x + 2] = value
                row[4 * x + 3] = 255
            }
        }
        CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey,
                              kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey,
                              kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
        return buffer
    }

    /// The gather path (NV12/P010, radius 1-2) must reproduce the per-texel
    /// reference window, including clamped edges and odd offsets.
    func testGatherPathMatchesReferenceWindowToOneHalfULP() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        for format in [kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange] {
            let frame = try makeBiPlanarNoiseFrame(width: 38, height: 22, format: format)
            for guidance in [HDRGainGuidance(radius: 1, tolerance: 0.05), .noiseGatedCandidate, HDRGainGuidance(radius: 2, tolerance: 0.5)] {
                let gathered = try renderRaw(frame, guidance: guidance, referencePath: false, device: device)
                let reference = try renderRaw(frame, guidance: guidance, referencePath: true, device: device)
                XCTAssertEqual(gathered.count, reference.count)
                // Same texels, same visiting order; fast-math may still contract
                // the two code shapes differently, which can flip a half-float
                // rounding at most 1 ULP on a handful of values. A wrong texel
                // spreads to many pixels and fails this by orders of magnitude.
                let differing = zip(gathered, reference).filter { $0.0.bitPattern != $0.1.bitPattern }
                let worstRelative = differing.map { abs(Float($0.0) - Float($0.1)) / max(abs(Float($0.1)), 1e-6) }.max() ?? 0
                let label = "format \(format) radius \(guidance.radius) tolerance \(guidance.tolerance)"
                XCTAssertLessThanOrEqual(differing.count, gathered.count / 200, label)
                XCTAssertLessThanOrEqual(worstRelative, 1e-3, label)
                let unguided = try renderRaw(frame, guidance: .off, referencePath: false, device: device)
                XCTAssertGreaterThan(zip(gathered, unguided).filter { $0.0.bitPattern != $0.1.bitPattern }.count, 0,
                                     "guidance must actually change the noisy frame")
            }
        }
    }

    private func renderRaw(_ buffer: CVPixelBuffer, guidance: HDRGainGuidance, referencePath: Bool,
                           device: MTLDevice) throws -> [Float16] {
        var config = HDRConfiguration.calibratedV4
        config.gainGuidance = guidance
        let processor = try HDRProcessor(device: device, configuration: config)
        processor.gainGuidanceReferencePathEnabled = referencePath
        let command = try processor.makeCommandBuffer()
        let frame = try processor.process(pixelBuffer: buffer, commandBuffer: command)
        command.commit()
        command.waitUntilCompleted()
        XCTAssertEqual(command.status, .completed)
        return try readRGBA16FloatPixels(from: frame.texture, device: device)
    }

    private func makeBiPlanarNoiseFrame(width: Int, height: Int, format: OSType) throws -> CVPixelBuffer {
        var result: CVPixelBuffer?
        let attributes = [kCVPixelBufferMetalCompatibilityKey as String: true,
                          kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, width, height, format, attributes, &result), kCVReturnSuccess)
        let buffer = try XCTUnwrap(result)
        XCTAssertEqual(CVPixelBufferLockBaseAddress(buffer, []), kCVReturnSuccess)
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let tenBit = format == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
        var state: UInt32 = 0x1234_5678
        func next() -> UInt32 { state = state &* 1_664_525 &+ 1_013_904_223; return state >> 8 }
        let yBase = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(buffer, 0))
        let yStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        for y in 0..<height {
            for x in 0..<width {
                // Bright base with +-12 code grain and one hard edge.
                let base = x < width / 2 ? 200 : 120
                let code = base + Int(next() % 25) - 12
                if tenBit {
                    yBase.advanced(by: y * yStride).assumingMemoryBound(to: UInt16.self)[x] = UInt16(code * 4) << 6
                } else {
                    yBase.advanced(by: y * yStride).assumingMemoryBound(to: UInt8.self)[x] = UInt8(code)
                }
            }
        }
        let uvBase = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(buffer, 1))
        let uvStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
        for y in 0..<CVPixelBufferGetHeightOfPlane(buffer, 1) {
            for x in 0..<(2 * CVPixelBufferGetWidthOfPlane(buffer, 1)) {
                if tenBit {
                    uvBase.advanced(by: y * uvStride).assumingMemoryBound(to: UInt16.self)[x] = UInt16(512) << 6
                } else {
                    uvBase.advanced(by: y * uvStride).assumingMemoryBound(to: UInt8.self)[x] = 128
                }
            }
        }
        for (key, value) in [(kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2),
                             (kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2),
                             (kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2)] {
            CVBufferSetAttachment(buffer, key, value, .shouldPropagate)
        }
        return buffer
    }

    func testDecodingClampsLikeTheInitializer() throws {
        func decode(_ json: String) throws -> HDRGainGuidance {
            try JSONDecoder().decode(HDRGainGuidance.self, from: Data(json.utf8))
        }
        XCTAssertEqual(try decode(#"{"radius":-3,"tolerance":0.1}"#), .off)
        XCTAssertEqual(try decode(#"{"radius":99,"tolerance":0.1}"#).radius, HDRGainGuidance.maximumRadius)
        XCTAssertEqual(try decode(#"{"radius":2,"tolerance":0}"#).tolerance, 1e-4)
        let roundTrip = try JSONDecoder().decode(HDRGainGuidance.self, from: JSONEncoder().encode(HDRGainGuidance.noiseGatedCandidate))
        XCTAssertEqual(roundTrip, .noiseGatedCandidate)
    }
}
