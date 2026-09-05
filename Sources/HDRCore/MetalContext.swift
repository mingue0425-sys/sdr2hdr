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
}

internal final class MetalContext {
    let device: MTLDevice
    let commandQueue: MTLCommandQueue
    let textureCache: TextureCache
    let nv12Pipeline: MTLComputePipelineState
    let bgraPipeline: MTLComputePipelineState
    let nv12DebugPipeline: MTLComputePipelineState
    let bgraDebugPipeline: MTLComputePipelineState
    let nv12TemporalPipeline: MTLComputePipelineState
    let bgraTemporalPipeline: MTLComputePipelineState

    init(device: MTLDevice, commandQueue suppliedQueue: MTLCommandQueue? = nil) throws {
        self.device = device
        guard let commandQueue = suppliedQueue ?? device.makeCommandQueue() else {
            throw HDRProcessorError.commandQueueCreationFailed
        }
        self.commandQueue = commandQueue
        self.textureCache = try TextureCache(device: device)

        let library: MTLLibrary
        if let precompiledURL = Bundle.module.url(forResource: "SDRToHDR", withExtension: "metallib"),
           let precompiled = try? device.makeLibrary(URL: precompiledURL) {
            library = precompiled
        } else {
            guard let sourceURL = Bundle.module.url(forResource: "SDRToHDR", withExtension: "metal") else {
                throw HDRProcessorError.shaderSourceMissing
            }
            let source: String
            do {
                source = try String(contentsOf: sourceURL, encoding: .utf8)
            } catch {
                throw HDRProcessorError.shaderSourceReadFailed(String(describing: error))
            }
            do {
                library = try device.makeLibrary(source: source, options: nil)
            } catch {
                throw HDRProcessorError.shaderCompilationFailed(String(describing: error))
            }
        }
        guard let nv12Function = library.makeFunction(name: "sdrNV12ToHDR") else {
            throw HDRProcessorError.shaderFunctionMissing("sdrNV12ToHDR")
        }
        guard let bgraFunction = library.makeFunction(name: "sdrBGRA8ToHDR") else {
            throw HDRProcessorError.shaderFunctionMissing("sdrBGRA8ToHDR")
        }
        guard let nv12DebugFunction = library.makeFunction(name: "sdrNV12ToHDRDebug") else {
            throw HDRProcessorError.shaderFunctionMissing("sdrNV12ToHDRDebug")
        }
        guard let bgraDebugFunction = library.makeFunction(name: "sdrBGRA8ToHDRDebug") else {
            throw HDRProcessorError.shaderFunctionMissing("sdrBGRA8ToHDRDebug")
        }
        guard let nv12TemporalFunction = library.makeFunction(name: "estimateNV12TemporalLuminance") else {
            throw HDRProcessorError.shaderFunctionMissing("estimateNV12TemporalLuminance")
        }
        guard let bgraTemporalFunction = library.makeFunction(name: "estimateBGRATemporalLuminance") else {
            throw HDRProcessorError.shaderFunctionMissing("estimateBGRATemporalLuminance")
        }
        do {
            self.nv12Pipeline = try device.makeComputePipelineState(function: nv12Function)
            self.bgraPipeline = try device.makeComputePipelineState(function: bgraFunction)
            self.nv12DebugPipeline = try device.makeComputePipelineState(function: nv12DebugFunction)
            self.bgraDebugPipeline = try device.makeComputePipelineState(function: bgraDebugFunction)
            self.nv12TemporalPipeline = try device.makeComputePipelineState(function: nv12TemporalFunction)
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
