import Foundation
import Metal

internal struct HDRShaderParameters {
    var yOffset: Float
    var yScale: Float
    var chromaOffset: Float
    var chromaScale: Float
    var matrixKind: UInt32
    var transferFunction: UInt32
    var gamma: Float
    var outputMode: UInt32
    var toneCurveRevision: UInt32
    var paperWhiteNits: Float
    var peakNits: Float
    var peakRatio: Float
    var highlightStrength: Float
    var contrastStrength: Float
    var saturationCompensation: Float
    var shadowProtection: Float
    var temporalAdaptation: Float
    var masteringHeadroom: Float
    var sceneShadowFloor: Float
    var sceneShadowTop: Float
    var sceneStatisticsValid: UInt32
    var sceneStatisticsReserved: UInt32
    var histogramStrategy: UInt32
    var sceneP01: Float
    var sceneP05: Float
    var sceneP50: Float
    var sceneP90: Float
    var sceneP99: Float
    var diagnosticROIX: Float
    var diagnosticROIY: Float
    var diagnosticROIWidth: Float
    var diagnosticROIHeight: Float
    var diagnosticROIEnabled: UInt32
    var developmentLowMidFadePosition: Float
    var developmentLowMidStrength: Float
    var developmentExpansionController: UInt32
    var developmentExpansionMinimumBudget: Float
    var developmentExpansionHighlightLow: Float
    var developmentExpansionHighlightHigh: Float
    var developmentExpansionRangeLow: Float
    var developmentExpansionRangeHigh: Float
    var developmentExpansionMidtoneLow: Float
    var developmentExpansionMidtoneHigh: Float
    var developmentExpansionCombinedHighlightWeight: Float
    var developmentExpansionCombinedRangeWeight: Float
    var developmentExpansionCombinedMidtoneWeight: Float
    var chromaReconstructionMode: UInt32
    var chromaSampleCenterX: Float
    var chromaSampleCenterY: Float
    var gainGuidanceRadius: UInt32
    var gainGuidanceTolerance: Float
    var gainGuidanceReferencePath: UInt32
    /// `HDRInputPrimaries` raw value; 0 (BT.709) skips the conversion.
    var inputPrimaries: UInt32
    /// Texture-adaptive gate (`HDRGainGuidance`); textureHigh <= textureLow disables it.
    var gainGuidanceTextureLow: Float
    var gainGuidanceTextureHigh: Float
    var gainGuidanceMinimumTolerance: Float
}

internal final class MetalContext {
    static let requiredFunctions = [
        "sdrNV12ToHDR", "sdrP010ToHDR", "sdrBGRA8ToHDR",
        "sdrNV12ToHDRDebug", "sdrP010ToHDRDebug", "sdrBGRA8ToHDRDebug",
        "sdrNV12ToHDRGuided", "sdrP010ToHDRGuided", "sdrBGRA8ToHDRGuided",
        "estimateNV12TemporalLuminance", "estimateP010TemporalLuminance",
        "estimateBGRATemporalLuminance"
    ]

    let device: MTLDevice
    /// Which bundled layout supplied the shader library.
    let libraryOrigin: HDRMetalLibraryLoader.Origin
    let commandQueue: MTLCommandQueue
    let textureCache: TextureCache
    let nv12Pipeline: MTLComputePipelineState
    let p010Pipeline: MTLComputePipelineState
    let bgraPipeline: MTLComputePipelineState
    let nv12DebugPipeline: MTLComputePipelineState
    let p010DebugPipeline: MTLComputePipelineState
    let bgraDebugPipeline: MTLComputePipelineState
    /// Gain-guided variants; the plain pipelines carry no guidance code.
    let nv12GuidedPipeline: MTLComputePipelineState
    let p010GuidedPipeline: MTLComputePipelineState
    let bgraGuidedPipeline: MTLComputePipelineState
    let nv12TemporalPipeline: MTLComputePipelineState
    let p010TemporalPipeline: MTLComputePipelineState
    let bgraTemporalPipeline: MTLComputePipelineState

    init(device: MTLDevice, commandQueue suppliedQueue: MTLCommandQueue? = nil) throws {
        self.device = device
        guard let commandQueue = suppliedQueue ?? device.makeCommandQueue() else {
            throw HDRProcessorError.commandQueueCreationFailed
        }
        self.commandQueue = commandQueue
        self.textureCache = try TextureCache(device: device)

        let library: MTLLibrary
        do {
            let loaded = try HDRMetalLibraryLoader.load(
                device: device,
                bundle: Bundle.module,
                name: "SDRToHDR",
                requiredFunctions: Self.requiredFunctions
            )
            library = loaded.library
            libraryOrigin = loaded.origin
        } catch let failure as HDRMetalLibraryLoader.Failure {
            switch failure {
            case .sourceMissing: throw HDRProcessorError.shaderSourceMissing
            case .sourceReadFailed(let reason): throw HDRProcessorError.shaderSourceReadFailed(reason)
            case .compilationFailed(let reason): throw HDRProcessorError.shaderCompilationFailed(reason)
            }
        }
        guard let nv12Function = library.makeFunction(name: "sdrNV12ToHDR") else {
            throw HDRProcessorError.shaderFunctionMissing("sdrNV12ToHDR")
        }
        guard let p010Function = library.makeFunction(name: "sdrP010ToHDR") else {
            throw HDRProcessorError.shaderFunctionMissing("sdrP010ToHDR")
        }
        guard let bgraFunction = library.makeFunction(name: "sdrBGRA8ToHDR") else {
            throw HDRProcessorError.shaderFunctionMissing("sdrBGRA8ToHDR")
        }
        guard let nv12DebugFunction = library.makeFunction(name: "sdrNV12ToHDRDebug") else {
            throw HDRProcessorError.shaderFunctionMissing("sdrNV12ToHDRDebug")
        }
        guard let p010DebugFunction = library.makeFunction(name: "sdrP010ToHDRDebug") else {
            throw HDRProcessorError.shaderFunctionMissing("sdrP010ToHDRDebug")
        }
        guard let bgraDebugFunction = library.makeFunction(name: "sdrBGRA8ToHDRDebug") else {
            throw HDRProcessorError.shaderFunctionMissing("sdrBGRA8ToHDRDebug")
        }
        guard let nv12GuidedFunction = library.makeFunction(name: "sdrNV12ToHDRGuided") else {
            throw HDRProcessorError.shaderFunctionMissing("sdrNV12ToHDRGuided")
        }
        guard let p010GuidedFunction = library.makeFunction(name: "sdrP010ToHDRGuided") else {
            throw HDRProcessorError.shaderFunctionMissing("sdrP010ToHDRGuided")
        }
        guard let bgraGuidedFunction = library.makeFunction(name: "sdrBGRA8ToHDRGuided") else {
            throw HDRProcessorError.shaderFunctionMissing("sdrBGRA8ToHDRGuided")
        }
        guard let nv12TemporalFunction = library.makeFunction(name: "estimateNV12TemporalLuminance") else {
            throw HDRProcessorError.shaderFunctionMissing("estimateNV12TemporalLuminance")
        }
        guard let p010TemporalFunction = library.makeFunction(name: "estimateP010TemporalLuminance") else {
            throw HDRProcessorError.shaderFunctionMissing("estimateP010TemporalLuminance")
        }
        guard let bgraTemporalFunction = library.makeFunction(name: "estimateBGRATemporalLuminance") else {
            throw HDRProcessorError.shaderFunctionMissing("estimateBGRATemporalLuminance")
        }
        do {
            self.nv12Pipeline = try device.makeComputePipelineState(function: nv12Function)
            self.p010Pipeline = try device.makeComputePipelineState(function: p010Function)
            self.bgraPipeline = try device.makeComputePipelineState(function: bgraFunction)
            self.nv12DebugPipeline = try device.makeComputePipelineState(function: nv12DebugFunction)
            self.p010DebugPipeline = try device.makeComputePipelineState(function: p010DebugFunction)
            self.bgraDebugPipeline = try device.makeComputePipelineState(function: bgraDebugFunction)
            self.nv12GuidedPipeline = try device.makeComputePipelineState(function: nv12GuidedFunction)
            self.p010GuidedPipeline = try device.makeComputePipelineState(function: p010GuidedFunction)
            self.bgraGuidedPipeline = try device.makeComputePipelineState(function: bgraGuidedFunction)
            self.nv12TemporalPipeline = try device.makeComputePipelineState(function: nv12TemporalFunction)
            self.p010TemporalPipeline = try device.makeComputePipelineState(function: p010TemporalFunction)
            self.bgraTemporalPipeline = try device.makeComputePipelineState(function: bgraTemporalFunction)
        } catch {
            throw HDRProcessorError.pipelineCreationFailed(String(describing: error))
        }
    }

    func threadgroupSize(for pipeline: MTLComputePipelineState) -> MTLSize {
        let executionWidth = max(1, pipeline.threadExecutionWidth)
        let maxThreads = max(executionWidth, pipeline.maxTotalThreadsPerThreadgroup)
        let y = max(1, min(8, maxThreads / executionWidth))
        return MTLSize(width: executionWidth, height: y, depth: 1)
    }
}
