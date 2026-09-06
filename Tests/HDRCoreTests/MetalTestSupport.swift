import Foundation
import Metal

func readFirstRGBA16FloatPixel(from texture: MTLTexture, device: MTLDevice) throws -> SIMD4<Float> {
    let bytesPerPixel = MemoryLayout<UInt16>.stride * 4
    guard texture.pixelFormat == .rgba16Float,
          let queue = device.makeCommandQueue(),
          let commandBuffer = queue.makeCommandBuffer(),
          let readback = device.makeBuffer(length: bytesPerPixel, options: .storageModeShared),
          let blit = commandBuffer.makeBlitCommandEncoder()
    else {
        throw NSError(
            domain: "MetalTestSupport",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Could not create RGBA16Float readback resources"]
        )
    }

    blit.copy(
        from: texture,
        sourceSlice: 0,
        sourceLevel: 0,
        sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
        sourceSize: MTLSize(width: 1, height: 1, depth: 1),
        to: readback,
        destinationOffset: 0,
        destinationBytesPerRow: bytesPerPixel,
        destinationBytesPerImage: bytesPerPixel
    )
    blit.endEncoding()
    commandBuffer.commit()
    commandBuffer.waitUntilCompleted()

    guard commandBuffer.status == .completed, commandBuffer.error == nil else {
        throw commandBuffer.error ?? NSError(
            domain: "MetalTestSupport",
            code: 2,
            userInfo: [NSLocalizedDescriptionKey: "RGBA16Float readback command buffer failed"]
        )
    }

    let values = readback.contents().assumingMemoryBound(to: UInt16.self)
    return SIMD4(
        Float(Float16(bitPattern: values[0])),
        Float(Float16(bitPattern: values[1])),
        Float(Float16(bitPattern: values[2])),
        Float(Float16(bitPattern: values[3]))
    )
}
