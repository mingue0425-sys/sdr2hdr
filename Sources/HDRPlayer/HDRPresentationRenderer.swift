import CoreGraphics
import Foundation
import HDRCore
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
    var diagnosticROIX: Float
    var diagnosticROIY: Float
    var diagnosticROIWidth: Float
    var diagnosticROIHeight: Float
    var diagnosticEnabled: UInt32
}

public struct HDRPresentationDiagnosticSnapshot: Equatable, Sendable {
    public let frameIndex: UInt64
    public let fullFrame: HDRPresentationDiagnostic
    public let roi: HDRPresentationDiagnostic?

    public init(
        frameIndex: UInt64,
        fullFrame: HDRPresentationDiagnostic,
        roi: HDRPresentationDiagnostic?
    ) {
        self.frameIndex = frameIndex
        self.fullFrame = fullFrame
        self.roi = roi
    }
}

private struct HDRPresentationDebugStatsStorage {
    var mappedLuminanceSum: UInt32 = 0
    var mappedLuminanceMax: UInt32 = 0
    var pixelCount: UInt32 = 0
    var roiMappedLuminanceSum: UInt32 = 0
    var roiMappedLuminanceMax: UInt32 = 0
    var roiPixelCount: UInt32 = 0
}

private final class PresentationDebugBufferLifetime: @unchecked Sendable {
    let buffer: MTLBuffer

    init(_ buffer: MTLBuffer) {
        self.buffer = buffer
    }
}

public final class HDRPresentationRenderer: @unchecked Sendable {
    public let device: MTLDevice
    public let pipelineState: MTLRenderPipelineState

    private let samplerState: MTLSamplerState
    private let diagnosticLock = NSLock()
    private var diagnosticsEnabledStorage = false
    private var lastPresentationDiagnosticStorage: HDRPresentationDiagnosticSnapshot?
    private var onNonBlackPresentedStorage: (@Sendable () -> Void)?

    public var diagnosticsEnabled: Bool {
        get {
            diagnosticLock.lock()
            defer { diagnosticLock.unlock() }
            return diagnosticsEnabledStorage
        }
        set {
            diagnosticLock.lock()
            diagnosticsEnabledStorage = newValue
            diagnosticLock.unlock()
        }
    }

    public var lastPresentationDiagnostic: HDRPresentationDiagnosticSnapshot? {
        diagnosticLock.lock()
        defer { diagnosticLock.unlock() }
        return lastPresentationDiagnosticStorage
    }

    /// Called from the command-buffer completion handler when measured mapped
    /// luminance is non-black. Callers should keep the callback thread-safe.
    public var onNonBlackPresented: (@Sendable () -> Void)? {
        get {
            diagnosticLock.lock()
            defer { diagnosticLock.unlock() }
            return onNonBlackPresentedStorage
        }
        set {
            diagnosticLock.lock()
            onNonBlackPresentedStorage = newValue
            diagnosticLock.unlock()
        }
    }

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
        displayHeadroom: Float,
        diagnosticFrameIndex: UInt64 = 0,
        diagnosticROI: HDRDiagnosticROI? = nil
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
        let diagnosticsEnabled = self.diagnosticsEnabled
        let diagnosticLifetime = diagnosticsEnabled ? device.makeBuffer(
            length: MemoryLayout<HDRPresentationDebugStatsStorage>.stride,
            options: .storageModeShared
        ).map(PresentationDebugBufferLifetime.init) : nil
        if let diagnosticLifetime {
            diagnosticLifetime.buffer.contents().assumingMemoryBound(to: HDRPresentationDebugStatsStorage.self)
                .initialize(to: HDRPresentationDebugStatsStorage())
        }
        // The UI stores ROI coordinates with a top-left origin; the vertex
        // shader's local UV has a bottom-left origin.
        let shaderROI = diagnosticROI.map {
            HDRDiagnosticROI(x: $0.x, y: 1 - $0.y - $0.height, width: $0.width, height: $0.height)
        }
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
            displayHeadroom: displayHeadroom,
            diagnosticROIX: shaderROI?.x ?? 0,
            diagnosticROIY: shaderROI?.y ?? 0,
            diagnosticROIWidth: shaderROI?.width ?? 0,
            diagnosticROIHeight: shaderROI?.height ?? 0,
            diagnosticEnabled: diagnosticLifetime == nil ? 0 : 1
        )
        encoder.setRenderPipelineState(pipelineState)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<PresentationUniforms>.stride, index: 0)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<PresentationUniforms>.stride, index: 0)
        if let texture {
            encoder.setFragmentTexture(texture, index: 0)
            encoder.setFragmentSamplerState(samplerState, index: 0)
        }
        if let diagnosticLifetime {
            encoder.setFragmentBuffer(diagnosticLifetime.buffer, offset: 0, index: 1)
        }
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        encoder.endEncoding()
        commandBuffer.present(drawable)
        if let diagnosticLifetime {
            commandBuffer.addCompletedHandler { [weak self, diagnosticLifetime] commandBuffer in
                guard commandBuffer.status == .completed else { return }
                self?.updatePresentationDiagnostic(
                    from: diagnosticLifetime.buffer,
                    frameIndex: diagnosticFrameIndex,
                    masteringHeadroom: masteringHeadroom,
                    displayHeadroom: displayHeadroom,
                    roi: diagnosticROI
                )
            }
        }
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
            displayHeadroom: displayHeadroom,
            diagnosticROIX: 0,
            diagnosticROIY: 0,
            diagnosticROIWidth: 0,
            diagnosticROIHeight: 0,
            diagnosticEnabled: 0
        )
        encoder.setRenderPipelineState(pipelineState)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<PresentationUniforms>.stride, index: 0)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<PresentationUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        encoder.endEncoding()
    }

    private func updatePresentationDiagnostic(
        from buffer: MTLBuffer,
        frameIndex: UInt64,
        masteringHeadroom: Float,
        displayHeadroom: Float,
        roi: HDRDiagnosticROI?
    ) {
        let storage = buffer.contents().assumingMemoryBound(to: HDRPresentationDebugStatsStorage.self).pointee
        let count = max(storage.pixelCount, 1)
        let full = HDRPresentationDiagnostic(
            masteringHeadroom: masteringHeadroom,
            physicalDisplayHeadroom: displayHeadroom,
            mappedEDRAverage: Float(storage.mappedLuminanceSum) / Float(count) / 256,
            mappedEDRMax: Float(storage.mappedLuminanceMax) / 256
        )
        let roiDiagnostic: HDRPresentationDiagnostic?
        if let roi, !roi.isEmpty, storage.roiPixelCount > 0 {
            roiDiagnostic = HDRPresentationDiagnostic(
                masteringHeadroom: masteringHeadroom,
                physicalDisplayHeadroom: displayHeadroom,
                mappedEDRAverage: Float(storage.roiMappedLuminanceSum) / Float(storage.roiPixelCount) / 256,
                mappedEDRMax: Float(storage.roiMappedLuminanceMax) / 256
            )
        } else {
            roiDiagnostic = nil
        }
        let snapshot = HDRPresentationDiagnosticSnapshot(
            frameIndex: frameIndex,
            fullFrame: full,
            roi: roiDiagnostic
        )
        diagnosticLock.lock()
        lastPresentationDiagnosticStorage = snapshot
        diagnosticLock.unlock()
        let callback = diagnosticLock.withLock { onNonBlackPresentedStorage }
        if let mappedAverage = full.mappedEDRAverage, mappedAverage > 0.001 {
            callback?()
        }
    }
}
