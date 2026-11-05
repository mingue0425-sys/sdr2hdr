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
}
