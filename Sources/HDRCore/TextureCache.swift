import CoreVideo
import Metal

internal struct CVMetalInputTextures: @unchecked Sendable {
    let y: MTLTexture?
    let uv: MTLTexture?
    let bgra: MTLTexture?
    let retainedMetalTextures: [CVMetalTexture]
}

internal final class TextureCache {
    let cache: CVMetalTextureCache

    init(device: MTLDevice) throws {
        var createdCache: CVMetalTextureCache?
        let status = CVMetalTextureCacheCreate(
            kCFAllocatorDefault,
            nil,
            device,
            nil,
            &createdCache
        )
        guard status == kCVReturnSuccess, let createdCache else {
            throw HDRProcessorError.textureCacheCreationFailed(status)
        }
        self.cache = createdCache
    }

    func makeTextures(for pixelBuffer: CVPixelBuffer) throws -> CVMetalInputTextures {
        let format = CVPixelBufferGetPixelFormatType(pixelBuffer)
        switch format {
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
             kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
            let width = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
            let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
            let uvWidth = CVPixelBufferGetWidthOfPlane(pixelBuffer, 1)
            let uvHeight = CVPixelBufferGetHeightOfPlane(pixelBuffer, 1)
            guard width > 0, height > 0, uvWidth > 0, uvHeight > 0 else {
                throw HDRProcessorError.invalidDimensions
            }

            var yTexture: CVMetalTexture?
            let yStatus = CVMetalTextureCacheCreateTextureFromImage(
                kCFAllocatorDefault,
                cache,
                pixelBuffer,
                nil,
                .r8Unorm,
                width,
                height,
                0,
                &yTexture
            )
            guard yStatus == kCVReturnSuccess, let yTexture,
                  let y = CVMetalTextureGetTexture(yTexture) else {
                throw HDRProcessorError.textureCreationFailed(yStatus, plane: 0)
            }

            var uvTexture: CVMetalTexture?
            let uvStatus = CVMetalTextureCacheCreateTextureFromImage(
                kCFAllocatorDefault,
                cache,
                pixelBuffer,
                nil,
                .rg8Unorm,
                uvWidth,
                uvHeight,
                1,
                &uvTexture
            )
            guard uvStatus == kCVReturnSuccess, let uvTexture,
                  let uv = CVMetalTextureGetTexture(uvTexture) else {
                throw HDRProcessorError.textureCreationFailed(uvStatus, plane: 1)
            }
            return CVMetalInputTextures(
                y: y,
                uv: uv,
                bgra: nil,
                retainedMetalTextures: [yTexture, uvTexture]
            )

        case kCVPixelFormatType_32BGRA:
            let width = CVPixelBufferGetWidth(pixelBuffer)
            let height = CVPixelBufferGetHeight(pixelBuffer)
            guard width > 0, height > 0 else {
                throw HDRProcessorError.invalidDimensions
            }
            var bgraTexture: CVMetalTexture?
            let status = CVMetalTextureCacheCreateTextureFromImage(
                kCFAllocatorDefault,
                cache,
                pixelBuffer,
                nil,
                .bgra8Unorm,
                width,
                height,
                0,
                &bgraTexture
            )
            guard status == kCVReturnSuccess, let bgraTexture,
                  let bgra = CVMetalTextureGetTexture(bgraTexture) else {
                throw HDRProcessorError.textureCreationFailed(status, plane: 0)
            }
            return CVMetalInputTextures(
                y: nil,
                uv: nil,
                bgra: bgra,
                retainedMetalTextures: [bgraTexture]
            )

        default:
            throw HDRProcessorError.unsupportedPixelFormat(format)
        }
    }
}
