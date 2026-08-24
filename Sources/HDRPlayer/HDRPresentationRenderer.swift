import CoreGraphics
import Foundation
import Metal
import QuartzCore

public struct PresentationUniforms {
    var destinationRect: SIMD4<Float>
    var orientation: UInt32
    var fallbackToSDR: UInt32
    var testPattern: UInt32
    var hasTexture: UInt32
    var masteringHeadroom: Float
    var displayHeadroom: Float
}

public final class HDRPresentationRenderer: @unchecked Sendable {
    public let device: MTLDevice
    public let pipelineState: MTLRenderPipelineState

    private let samplerState: MTLSamplerState

    public init(device: MTLDevice, colorPixelFormat: MTLPixelFormat = .rgba16Float) throws {
        self.device = device
        let library: MTLLibrary
        if let precompiledURL = Bundle.module.url(forResource: "Presentation", withExtension: "metallib"),
           let precompiled = try? device.makeLibrary(URL: precompiledURL) {
            library = precompiled
        } else {
            guard let shaderURL = Bundle.module.url(forResource: "Presentation", withExtension: "metal") else {
                throw HDRPlayerError.presentationShaderMissing
            }
            let source = try String(contentsOf: shaderURL, encoding: .utf8)
            do {
                library = try device.makeLibrary(source: source, options: nil)
            } catch {
                throw HDRPlayerError.presentationShaderCompilationFailed(String(describing: error))
            }
        }
        guard let vertex = library.makeFunction(name: "presentationVertex"),
              let fragment = library.makeFunction(name: "presentationFragment") else {
            throw HDRPlayerError.presentationFunctionMissing
        }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        descriptor.colorAttachments[0].pixelFormat = colorPixelFormat
        do {
            pipelineState = try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            throw HDRPlayerError.presentationPipelineCreationFailed(String(describing: error))
        }

        let samplerDescriptor = MTLSamplerDescriptor()
        samplerDescriptor.minFilter = .linear
        samplerDescriptor.magFilter = .linear
        samplerDescriptor.mipFilter = .notMipmapped
        samplerDescriptor.sAddressMode = .clampToEdge
        samplerDescriptor.tAddressMode = .clampToEdge
        guard let sampler = device.makeSamplerState(descriptor: samplerDescriptor) else {
            throw HDRPlayerError.presentationSamplerCreationFailed
        }
        self.samplerState = sampler
    }

    @discardableResult
    public func encode(
        texture: MTLTexture?,
        drawable: CAMetalDrawable,
        commandBuffer: MTLCommandBuffer,
        sourceSize: CGSize,
        drawableSize: CGSize,
        orientation: VideoOrientation,
        fallbackToSDR: Bool,
        testPattern: Bool,
        masteringHeadroom: Float,
        displayHeadroom: Float
    ) -> Bool {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else {
            return false
        }

        let geometry = AspectFitGeometry(sourceSize: sourceSize, drawableSize: drawableSize)
        let rect = geometry.normalizedRect
        var uniforms = PresentationUniforms(
            destinationRect: SIMD4(
                Float(rect.origin.x),
                Float(rect.origin.y),
                Float(rect.size.width),
                Float(rect.size.height)
            ),
            orientation: orientation.rawValue,
            fallbackToSDR: fallbackToSDR ? 1 : 0,
            testPattern: testPattern ? 1 : 0,
            hasTexture: texture == nil ? 0 : 1,
            masteringHeadroom: masteringHeadroom,
            displayHeadroom: displayHeadroom
        )
        encoder.setRenderPipelineState(pipelineState)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<PresentationUniforms>.stride, index: 0)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<PresentationUniforms>.stride, index: 0)
        if let texture {
            encoder.setFragmentTexture(texture, index: 0)
            encoder.setFragmentSamplerState(samplerState, index: 0)
        }
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        encoder.endEncoding()
        commandBuffer.present(drawable)
        return true
    }

    /// Test-only presentation entry point. It uses the same render pipeline as
    /// the CAMetalLayer path but omits drawable presentation, allowing CI to
    /// verify that EDR values above 1.0 survive the shader.
    public func encodeTestPattern(
        to outputTexture: MTLTexture,
        commandBuffer: MTLCommandBuffer,
        fallbackToSDR: Bool = false,
        masteringHeadroom: Float = 4.8668838,
        displayHeadroom: Float = 4.8668838
    ) {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = outputTexture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        var uniforms = PresentationUniforms(
            destinationRect: SIMD4(0, 0, 1, 1),
            orientation: VideoOrientation.identity.rawValue,
            fallbackToSDR: fallbackToSDR ? 1 : 0,
            testPattern: 1,
            hasTexture: 0,
            masteringHeadroom: masteringHeadroom,
            displayHeadroom: displayHeadroom
        )
        encoder.setRenderPipelineState(pipelineState)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<PresentationUniforms>.stride, index: 0)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<PresentationUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        encoder.endEncoding()
    }
}
