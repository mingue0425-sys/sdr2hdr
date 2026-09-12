import Metal
import XCTest
@testable import HDRPlayerKit

final class AuditPresentationTests: XCTestCase {
    func testEDRPresentationPreservesRepresentableNearBlack() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let renderer = try HDRPresentationRenderer(device: device)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float, width: 1, height: 1, mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = [.shaderRead, .renderTarget]
        let source = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        let target = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        let queue = try XCTUnwrap(device.makeCommandQueue())
        for value: Float in [0, 0.00000011920929, 0.0000009536743, 0.000061035156, 0.5, 1] {
            var input: [Float16] = [Float16(value), Float16(value), Float16(value), 1]
            source.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0,
                           withBytes: &input, bytesPerRow: 8)
            let command = try XCTUnwrap(queue.makeCommandBuffer())
            XCTAssertTrue(renderer.encodeOffscreen(
                texture: source, to: target, commandBuffer: command,
                sourceSize: CGSize(width: 1, height: 1), drawableSize: CGSize(width: 1, height: 1),
                orientation: .identity, fallbackToSDR: false,
                masteringHeadroom: 5, displayHeadroom: 2))
            command.commit()
            command.waitUntilCompleted()
            XCTAssertEqual(command.status, .completed)
            var output = [Float16](repeating: 0, count: 4)
            target.getBytes(&output, bytesPerRow: 8, from: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0)
            XCTAssertEqual(output[0], input[0], "neutral EDR sample \(value) changed during presentation")
        }
    }
}
