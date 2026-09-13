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
    var bt1886BlackLuminance: Float
    var bt1886WhiteLuminance: Float
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
    var sceneProxyWidth: UInt32
    var sceneProxyHeight: UInt32
    var sceneHistogramBinCount: UInt32
    var sceneLinear16HistogramBinCount: UInt32
    var sceneInputMinimum: Float
    var sceneInputMaximum: Float
    var sceneHistogramUpperExclusive: Float
    var sceneHistogramLogMinimumExponent: Float
    var sceneHistogramLogMaximumExponent: Float
    var sceneShadowDenseBreakpoint: Float
    var sceneShadowDenseLowerBinCount: UInt32
    var sceneShadowDenseUpperSpan: Float
    var sceneQuantizationMaximum: Float
    var sceneQuantizationRounding: Float
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

    // Calibration color-science identity. These values are copied from the
    // same immutable definition used by the scalar reference path.
    var bt709LumaR: Float
    var bt709LumaG: Float
    var bt709LumaB: Float
    var bt2020LumaR: Float
    var bt2020LumaG: Float
    var bt2020LumaB: Float
    var bt709ToBT2020_00: Float
    var bt709ToBT2020_01: Float
    var bt709ToBT2020_02: Float
    var bt709ToBT2020_10: Float
    var bt709ToBT2020_11: Float
    var bt709ToBT2020_12: Float
    var bt709ToBT2020_20: Float
    var bt709ToBT2020_21: Float
    var bt709ToBT2020_22: Float
    var bt709InverseBreakPoint: Float
    var bt709InverseLinearScale: Float
    var bt709InverseOffset: Float
    var bt709InverseScale: Float
    var bt709InverseExponent: Float
    var srgbInverseBreakPoint: Float
    var srgbInverseLinearScale: Float
    var srgbInverseOffset: Float
    var srgbInverseScale: Float
    var srgbInverseExponent: Float
    var bt601ToRGB_00: Float
    var bt601ToRGB_01: Float
    var bt601ToRGB_02: Float
    var bt601ToRGB_10: Float
    var bt601ToRGB_11: Float
    var bt601ToRGB_12: Float
    var bt601ToRGB_20: Float
    var bt601ToRGB_21: Float
    var bt601ToRGB_22: Float
    var bt709ToRGB_00: Float
    var bt709ToRGB_01: Float
    var bt709ToRGB_02: Float
    var bt709ToRGB_10: Float
    var bt709ToRGB_11: Float
    var bt709ToRGB_12: Float
    var bt709ToRGB_20: Float
    var bt709ToRGB_21: Float
    var bt709ToRGB_22: Float
    var bt2020ToRGB_00: Float
    var bt2020ToRGB_01: Float
    var bt2020ToRGB_02: Float
    var bt2020ToRGB_10: Float
    var bt2020ToRGB_11: Float
    var bt2020ToRGB_12: Float
    var bt2020ToRGB_20: Float
    var bt2020ToRGB_21: Float
    var bt2020ToRGB_22: Float
    var pqM1: Float
    var pqM2: Float
    var pqC1: Float
    var pqC2: Float
    var pqC3: Float
    var pqAbsolutePeakNits: Float
    var p010StorageDenominator: Float
    var p010RightShift: UInt32
    var p010CodeMaximum: Float

    // Calibration tone-mapping identity. The shader must consume these
    // values rather than owning a second copy of the production equation.
    var toneInputMinimum: Float
    var toneInputMaximum: Float
    var toneSmoothstepFloor: Float
    var toneSmoothstepLinear: Float
    var toneSmoothstepQuadratic: Float
    var toneShoulderBase: Float
    var toneShoulderContrast: Float
    var toneLegacyShadowLower: Float
    var toneLegacyShadowUpper: Float
    var toneSceneFloorLower: Float
    var toneSceneFloorUpper: Float
    var toneSceneFloorFallback: Float
    var toneSceneTopMinimumDelta: Float
    var toneSceneTopFallback: Float
    var toneSceneTopUpper: Float
    var toneSceneLowMidCoefficient: Float
    var toneSceneProtectionCoefficient: Float
    var toneDefaultPresenceLower: Float
    var toneDefaultPresenceUpper: Float
    var toneDefaultFadeLower: Float
    var toneDefaultFadeUpper: Float
    var toneDefaultAttenuationCoefficient: Float
    var toneChromaStart: Float
    var toneChromaPeakMinimum: Float
    var toneChromaCoefficient: Float
    var toneGamutLuminanceFloor: Float
    var toneGamutDenominatorFloor: Float
    var toneChromaScaleMinimum: Float
    var toneChromaScaleMaximum: Float
    var toneOutputMinimum: Float
}

internal final class MetalContext {
    let device: MTLDevice
    let commandQueue: MTLCommandQueue
    let textureCache: TextureCache
    let nv12Pipeline: MTLComputePipelineState
    let p010Pipeline: MTLComputePipelineState
    let bgraPipeline: MTLComputePipelineState
    let nv12DebugPipeline: MTLComputePipelineState
    let p010DebugPipeline: MTLComputePipelineState
    let bgraDebugPipeline: MTLComputePipelineState
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
