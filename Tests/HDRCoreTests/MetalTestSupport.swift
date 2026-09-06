import Foundation
import Metal

func readRGBA16FloatPixels(from texture: MTLTexture, device: MTLDevice) throws -> [Float16] {
    let bytesPerPixel = MemoryLayout<UInt16>.stride * 4
    guard texture.pixelFormat == .rgba16Float,
          let queue = device.makeCommandQueue(),
          let commandBuffer = queue.makeCommandBuffer(),
          let readback = device.makeBuffer(
            length: texture.width * texture.height * bytesPerPixel,
            options: .storageModeShared
          ),
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
        sourceSize: MTLSize(width: texture.width, height: texture.height, depth: 1),
        to: readback,
        destinationOffset: 0,
        destinationBytesPerRow: texture.width * bytesPerPixel,
        destinationBytesPerImage: texture.width * texture.height * bytesPerPixel
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
    return (0..<(texture.width * texture.height * 4)).map {
        Float16(bitPattern: values[$0])
    }
}

func readFirstRGBA16FloatPixel(from texture: MTLTexture, device: MTLDevice) throws -> SIMD4<Float> {
    let values = try readRGBA16FloatPixels(from: texture, device: device)
    return SIMD4(
        Float(values[0]),
        Float(values[1]),
        Float(values[2]),
        Float(values[3])
    )
}
