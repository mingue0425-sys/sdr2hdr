import Foundation
import simd

/// Transfer-function constants used by the calibration source-linearization
/// path.  They are data owned by the same color-science definition consumed
/// by the metric and reference decoders.
public struct HDRTransferSemanticDefinition: Codable, Hashable, Sendable {
    public let version: String
    public let bt709InverseBreakPoint: Double
    public let bt709InverseLinearScale: Double
    public let bt709InverseOffset: Double
    public let bt709InverseScale: Double
    public let bt709InverseExponent: Double
    public let bt709ForwardBreakPoint: Double
    public let bt709ForwardLinearScale: Double
    public let bt709ForwardScale: Double
    public let bt709ForwardExponent: Double
    public let bt709ForwardOffset: Double
    public let srgbInverseBreakPoint: Double
    public let srgbInverseLinearScale: Double
    public let srgbInverseOffset: Double
    public let srgbInverseScale: Double
    public let srgbInverseExponent: Double
    public let srgbForwardBreakPoint: Double
    public let srgbForwardLinearScale: Double
    public let srgbForwardScale: Double
    public let srgbForwardExponent: Double
    public let srgbForwardOffset: Double

    public init(
        version: String,
        bt709InverseBreakPoint: Double,
        bt709InverseLinearScale: Double,
        bt709InverseOffset: Double,
        bt709InverseScale: Double,
        bt709InverseExponent: Double,
        bt709ForwardBreakPoint: Double,
        bt709ForwardLinearScale: Double,
        bt709ForwardScale: Double,
        bt709ForwardExponent: Double,
        bt709ForwardOffset: Double,
        srgbInverseBreakPoint: Double,
        srgbInverseLinearScale: Double,
        srgbInverseOffset: Double,
        srgbInverseScale: Double,
        srgbInverseExponent: Double,
        srgbForwardBreakPoint: Double,
        srgbForwardLinearScale: Double,
        srgbForwardScale: Double,
        srgbForwardExponent: Double,
        srgbForwardOffset: Double
    ) {
        self.version = version
        self.bt709InverseBreakPoint = bt709InverseBreakPoint
        self.bt709InverseLinearScale = bt709InverseLinearScale
        self.bt709InverseOffset = bt709InverseOffset
        self.bt709InverseScale = bt709InverseScale
        self.bt709InverseExponent = bt709InverseExponent
        self.bt709ForwardBreakPoint = bt709ForwardBreakPoint
        self.bt709ForwardLinearScale = bt709ForwardLinearScale
        self.bt709ForwardScale = bt709ForwardScale
        self.bt709ForwardExponent = bt709ForwardExponent
        self.bt709ForwardOffset = bt709ForwardOffset
        self.srgbInverseBreakPoint = srgbInverseBreakPoint
        self.srgbInverseLinearScale = srgbInverseLinearScale
        self.srgbInverseOffset = srgbInverseOffset
        self.srgbInverseScale = srgbInverseScale
        self.srgbInverseExponent = srgbInverseExponent
        self.srgbForwardBreakPoint = srgbForwardBreakPoint
        self.srgbForwardLinearScale = srgbForwardLinearScale
        self.srgbForwardScale = srgbForwardScale
        self.srgbForwardExponent = srgbForwardExponent
        self.srgbForwardOffset = srgbForwardOffset
    }

    public static let calibration = HDRTransferSemanticDefinition(
        version: "transfer-functions-bt709-srgb-v1",
        bt709InverseBreakPoint: 0.081,
        bt709InverseLinearScale: 4.5,
        bt709InverseOffset: 0.099,
        bt709InverseScale: 1.099,
        bt709InverseExponent: 1 / 0.45,
        bt709ForwardBreakPoint: 0.018,
        bt709ForwardLinearScale: 4.5,
        bt709ForwardScale: 1.099,
        bt709ForwardExponent: 0.45,
        bt709ForwardOffset: 0.099,
        srgbInverseBreakPoint: 0.04045,
        srgbInverseLinearScale: 12.92,
        srgbInverseOffset: 0.055,
        srgbInverseScale: 1.055,
        srgbInverseExponent: 2.4,
        srgbForwardBreakPoint: 0.0031308,
        srgbForwardLinearScale: 12.92,
        srgbForwardScale: 1.055,
        srgbForwardExponent: 1 / 2.4,
        srgbForwardOffset: 0.055
    )

    public var isValid: Bool {
        let values = [
            bt709InverseBreakPoint, bt709InverseLinearScale, bt709InverseOffset,
            bt709InverseScale, bt709InverseExponent, bt709ForwardBreakPoint,
            bt709ForwardLinearScale, bt709ForwardScale, bt709ForwardExponent,
            bt709ForwardOffset, srgbInverseBreakPoint, srgbInverseLinearScale,
            srgbInverseOffset, srgbInverseScale, srgbInverseExponent,
            srgbForwardBreakPoint, srgbForwardLinearScale, srgbForwardScale,
            srgbForwardExponent, srgbForwardOffset
        ]
        return !version.isEmpty && values.allSatisfy(\.isFinite) &&
            bt709InverseBreakPoint >= 0 && bt709ForwardBreakPoint >= 0 &&
            srgbInverseBreakPoint >= 0 && srgbForwardBreakPoint >= 0 &&
            bt709InverseLinearScale > 0 && bt709InverseScale > 0 &&
            bt709ForwardLinearScale > 0 && bt709ForwardScale > 0 &&
            srgbInverseLinearScale > 0 && srgbInverseScale > 0 &&
            srgbForwardLinearScale > 0 && srgbForwardScale > 0 &&
            bt709InverseExponent > 0 && bt709ForwardExponent > 0 &&
            srgbInverseExponent > 0 && srgbForwardExponent > 0
    }

}

/// HLG inverse-OETF and display-side OOTF constants used by the reference
/// decoder.  HLG is included here because changing it changes the reference
/// samples supplied to calibration metrics.
public struct HDRHLGSemanticDefinition: Codable, Hashable, Sendable {
    public let version: String
    public let signalMinimum: Double
    public let signalMaximum: Double
    public let inverseOETFBreakpoint: Double
    public let inverseOETFLinearScale: Double
    public let inverseOETFExponentialA: Double
    public let inverseOETFExponentialB: Double
    public let inverseOETFExponentialC: Double
    public let inverseOETFExponentialScale: Double
    public let systemGammaOffset: Double
    public let systemGammaPeakScale: Double
    public let systemGammaMinimumPeakNits: Double
    public let systemGammaReferencePeakNits: Double
    public let displayMinimumPeakNits: Double

    public init(
        version: String,
        signalMinimum: Double,
        signalMaximum: Double,
        inverseOETFBreakpoint: Double,
        inverseOETFLinearScale: Double,
        inverseOETFExponentialA: Double,
        inverseOETFExponentialB: Double,
        inverseOETFExponentialC: Double,
        inverseOETFExponentialScale: Double,
        systemGammaOffset: Double,
        systemGammaPeakScale: Double,
        systemGammaMinimumPeakNits: Double,
        systemGammaReferencePeakNits: Double,
        displayMinimumPeakNits: Double
    ) {
        self.version = version
        self.signalMinimum = signalMinimum
        self.signalMaximum = signalMaximum
        self.inverseOETFBreakpoint = inverseOETFBreakpoint
        self.inverseOETFLinearScale = inverseOETFLinearScale
        self.inverseOETFExponentialA = inverseOETFExponentialA
        self.inverseOETFExponentialB = inverseOETFExponentialB
        self.inverseOETFExponentialC = inverseOETFExponentialC
        self.inverseOETFExponentialScale = inverseOETFExponentialScale
        self.systemGammaOffset = systemGammaOffset
        self.systemGammaPeakScale = systemGammaPeakScale
        self.systemGammaMinimumPeakNits = systemGammaMinimumPeakNits
        self.systemGammaReferencePeakNits = systemGammaReferencePeakNits
        self.displayMinimumPeakNits = displayMinimumPeakNits
    }

    public static let bt2100 = HDRHLGSemanticDefinition(
        version: "itu-r-bt.2100-hlg-reference-v1",
        signalMinimum: 0,
        signalMaximum: 1,
        inverseOETFBreakpoint: 0.5,
        inverseOETFLinearScale: 1.0 / 3.0,
        inverseOETFExponentialA: 0.17883277,
        inverseOETFExponentialB: 1 - 4 * 0.17883277,
        inverseOETFExponentialC: 0.55991073,
        inverseOETFExponentialScale: 1.0 / 12.0,
        systemGammaOffset: 1.2,
        systemGammaPeakScale: 0.42,
        systemGammaMinimumPeakNits: 100,
        systemGammaReferencePeakNits: 1_000,
        displayMinimumPeakNits: 1
    )

    public var isValid: Bool {
        let values = [
            signalMinimum, signalMaximum, inverseOETFBreakpoint,
            inverseOETFLinearScale, inverseOETFExponentialA,
            inverseOETFExponentialB, inverseOETFExponentialC,
            inverseOETFExponentialScale, systemGammaOffset,
            systemGammaPeakScale, systemGammaMinimumPeakNits,
            systemGammaReferencePeakNits, displayMinimumPeakNits
        ]
        return !version.isEmpty && values.allSatisfy(\.isFinite) &&
            signalMinimum <= signalMaximum &&
            inverseOETFBreakpoint >= signalMinimum &&
            inverseOETFBreakpoint <= signalMaximum &&
            inverseOETFLinearScale > 0 && inverseOETFExponentialA > 0 &&
            inverseOETFExponentialScale > 0 && systemGammaReferencePeakNits > 0 &&
            systemGammaMinimumPeakNits > 0 && displayMinimumPeakNits > 0
    }
}

/// The exact PQ transfer constants consumed by calibration metrics and the
/// HDRCore implementation.  Values are stored as semantic data rather than
/// hidden literals so a color-science mutation changes the experiment
/// identity.
public struct HDRPQSemanticDefinition: Codable, Hashable, Sendable {
    public let version: String
    public let m1: Double
    public let m2: Double
    public let c1: Double
    public let c2: Double
    public let c3: Double
    public let absolutePeakNits: Double

    public init(
        version: String,
        m1: Double,
        m2: Double,
        c1: Double,
        c2: Double,
        c3: Double,
        absolutePeakNits: Double
    ) {
        self.version = version
        self.m1 = m1
        self.m2 = m2
        self.c1 = c1
        self.c2 = c2
        self.c3 = c3
        self.absolutePeakNits = absolutePeakNits
    }

    public static let st2084 = HDRPQSemanticDefinition(
        version: "itu-r-bt.2100-st2084",
        m1: 2610.0 / 16384.0,
        m2: 2523.0 / 32.0,
        c1: 3424.0 / 4096.0,
        c2: 2413.0 / 128.0,
        c3: 2392.0 / 128.0,
        absolutePeakNits: 10_000
    )

    public var isValid: Bool {
        !version.isEmpty &&
            [m1, m2, c1, c2, c3, absolutePeakNits].allSatisfy(\.isFinite) &&
            m1 > 0 && m2 > 0 && c1 >= 0 && c2 > 0 && c3 >= 0 &&
            absolutePeakNits > 0
    }
}

/// Row-major RGB-to-LMS and LMS-to-ICtCp coefficient matrices.  The matrix
/// values are explicit because changing one coefficient changes hue and
/// chroma objective values.
public struct HDRICtCpSemanticDefinition: Codable, Hashable, Sendable {
    public let version: String
    public let rgbToLMS: [Double]
    public let lmsToICtCp: [Double]
    public let matrixNormalization: Double

    public init(
        version: String,
        rgbToLMS: [Double],
        lmsToICtCp: [Double],
        matrixNormalization: Double
    ) {
        self.version = version
        self.rgbToLMS = rgbToLMS
        self.lmsToICtCp = lmsToICtCp
        self.matrixNormalization = matrixNormalization
    }

    public static let bt2100 = HDRICtCpSemanticDefinition(
        version: "itu-r-bt.2100-ictcp",
        rgbToLMS: [
            1688, 2146, 262,
            683, 2951, 462,
            99, 309, 3688
        ],
        lmsToICtCp: [
            2048, 2048, 0,
            6610, -13613, 7003,
            17933, -17390, -543
        ],
        matrixNormalization: 4096
    )

    public var isValid: Bool {
        !version.isEmpty && rgbToLMS.count == 9 && lmsToICtCp.count == 9 &&
            rgbToLMS.allSatisfy(\.isFinite) && lmsToICtCp.allSatisfy(\.isFinite) &&
            matrixNormalization.isFinite && matrixNormalization > 0
    }

    public func rgbToLMSValues(_ rgb: (Double, Double, Double)) -> (Double, Double, Double) {
        let values = [rgb.0, rgb.1, rgb.2]
        return (
            dot(row: 0, matrix: rgbToLMS, values: values),
            dot(row: 1, matrix: rgbToLMS, values: values),
            dot(row: 2, matrix: rgbToLMS, values: values)
        )
    }

    public func lmsToICtCpValues(_ lms: (Double, Double, Double)) -> (Double, Double, Double) {
        let values = [lms.0, lms.1, lms.2]
        return (
            dot(row: 0, matrix: lmsToICtCp, values: values),
            dot(row: 1, matrix: lmsToICtCp, values: values),
            dot(row: 2, matrix: lmsToICtCp, values: values)
        )
    }

    private func dot(row: Int, matrix: [Double], values: [Double]) -> Double {
        let start = row * 3
        return (0..<3).reduce(0) { total, index in
            total + matrix[start + index] * values[index]
        } / matrixNormalization
    }
}

/// Numeric Y'CbCr/RGB and luminance constants used by the calibration input
/// and objective paths.  Keeping these next to PQ and ICtCp prevents a source
/// decode or luminance mutation from becoming an unbound implementation
/// detail.
public struct HDRYCbCrSemanticDefinition: Codable, Hashable, Sendable {
    public let version: String
    public let bt601ToRGB: [Double]
    public let bt709ToRGB: [Double]
    public let bt2020ToRGB: [Double]
    public let bt709Luminance: [Double]
    public let bt2020Luminance: [Double]
    public let bgraBT709Luminance: [Double]
    public let videoRange8LumaOffset: Double
    public let videoRange8LumaDenominator: Double
    public let videoRange8ChromaCenter: Double
    public let videoRange8ChromaDenominator: Double
    public let videoRange10LumaOffset: Double
    public let videoRange10LumaDenominator: Double
    public let videoRange10ChromaCenter: Double
    public let videoRange10ChromaDenominator: Double
    public let fullRange8Denominator: Double
    public let fullRange10Denominator: Double
    /// Storage-layout semantics for CoreVideo's 10-bit bi-planar formats.
    /// These are separate from the normalized Y'CbCr range coefficients.
    public let p010StorageDenominator: Double
    public let p010RightShift: UInt16
    public let p010CodeMaximum: Double

    public init(
        version: String,
        bt601ToRGB: [Double],
        bt709ToRGB: [Double],
        bt2020ToRGB: [Double],
        bt709Luminance: [Double],
        bt2020Luminance: [Double],
        bgraBT709Luminance: [Double],
        videoRange8LumaOffset: Double,
        videoRange8LumaDenominator: Double,
        videoRange8ChromaCenter: Double,
        videoRange8ChromaDenominator: Double,
        videoRange10LumaOffset: Double,
        videoRange10LumaDenominator: Double,
        videoRange10ChromaCenter: Double,
        videoRange10ChromaDenominator: Double,
        fullRange8Denominator: Double,
        fullRange10Denominator: Double,
        p010StorageDenominator: Double = 65_535,
        p010RightShift: UInt16 = 6,
        p010CodeMaximum: Double = 1_023
    ) {
        self.version = version
        self.bt601ToRGB = bt601ToRGB
        self.bt709ToRGB = bt709ToRGB
        self.bt2020ToRGB = bt2020ToRGB
        self.bt709Luminance = bt709Luminance
        self.bt2020Luminance = bt2020Luminance
        self.bgraBT709Luminance = bgraBT709Luminance
        self.videoRange8LumaOffset = videoRange8LumaOffset
        self.videoRange8LumaDenominator = videoRange8LumaDenominator
        self.videoRange8ChromaCenter = videoRange8ChromaCenter
        self.videoRange8ChromaDenominator = videoRange8ChromaDenominator
        self.videoRange10LumaOffset = videoRange10LumaOffset
        self.videoRange10LumaDenominator = videoRange10LumaDenominator
        self.videoRange10ChromaCenter = videoRange10ChromaCenter
        self.videoRange10ChromaDenominator = videoRange10ChromaDenominator
        self.fullRange8Denominator = fullRange8Denominator
        self.fullRange10Denominator = fullRange10Denominator
        self.p010StorageDenominator = p010StorageDenominator
        self.p010RightShift = p010RightShift
        self.p010CodeMaximum = p010CodeMaximum
    }

    public static let bt2100 = HDRYCbCrSemanticDefinition(
        version: "itu-r-bt.2100-ycbcr-calibration-v1",
        bt601ToRGB: [
            1, 0, 1.402000,
            1, -0.344136, -0.714136,
            1, 1.772000, 0
        ],
        bt709ToRGB: [
            1, 0, 1.574800,
            1, -0.187324, -0.468124,
            1, 1.855600, 0
        ],
        bt2020ToRGB: [
            1, 0, 1.474600,
            1, -0.164553, -0.571353,
            1, 1.881400, 0
        ],
        bt709Luminance: [0.2126, 0.7152, 0.0722],
        bt2020Luminance: [0.2627, 0.6780, 0.0593],
        bgraBT709Luminance: [0.2126, 0.7152, 0.0722],
        videoRange8LumaOffset: 16,
        videoRange8LumaDenominator: 219,
        videoRange8ChromaCenter: 128,
        videoRange8ChromaDenominator: 224,
        videoRange10LumaOffset: 64,
        videoRange10LumaDenominator: 876,
        videoRange10ChromaCenter: 512,
        videoRange10ChromaDenominator: 896,
        fullRange8Denominator: 255,
        fullRange10Denominator: 1023
    )

    public var isValid: Bool {
        let matrices = [bt601ToRGB, bt709ToRGB, bt2020ToRGB]
        let vectors = [bt709Luminance, bt2020Luminance, bgraBT709Luminance]
        let scalars = [
            videoRange8LumaOffset, videoRange8LumaDenominator,
            videoRange8ChromaCenter, videoRange8ChromaDenominator,
            videoRange10LumaOffset, videoRange10LumaDenominator,
            videoRange10ChromaCenter, videoRange10ChromaDenominator,
            fullRange8Denominator, fullRange10Denominator,
            p010StorageDenominator, p010CodeMaximum
        ]
        return !version.isEmpty && matrices.allSatisfy { $0.count == 9 && $0.allSatisfy(\.isFinite) } &&
            vectors.allSatisfy { $0.count == 3 && $0.allSatisfy(\.isFinite) } &&
            scalars.allSatisfy(\.isFinite) &&
            videoRange8LumaDenominator > 0 && videoRange8ChromaDenominator > 0 &&
            videoRange10LumaDenominator > 0 && videoRange10ChromaDenominator > 0 &&
            fullRange8Denominator > 0 && fullRange10Denominator > 0 &&
            p010StorageDenominator > 0 && p010CodeMaximum > 0 && p010RightShift < 16
    }

    public func rgb(from matrix: HDRYCbCrMatrix, y: Double, cb: Double, cr: Double) -> (Double, Double, Double) {
        let coefficients: [Double]
        switch matrix {
        case .bt601: coefficients = bt601ToRGB
        case .bt709: coefficients = bt709ToRGB
        case .bt2020: coefficients = bt2020ToRGB
        }
        return (
            coefficients[0] * y + coefficients[1] * cb + coefficients[2] * cr,
            coefficients[3] * y + coefficients[4] * cb + coefficients[5] * cr,
            coefficients[6] * y + coefficients[7] * cb + coefficients[8] * cr
        )
    }
}

/// Color-science semantics used by the calibration objective path.  Other
/// renderer constants are intentionally outside this object unless they feed
/// preparation, objective scoring, gating, ranking, or shortlist selection.
public struct HDRColorScienceSemanticDefinition: Codable, Hashable, Sendable {
    public let version: String
    public let pq: HDRPQSemanticDefinition
    public let ictcp: HDRICtCpSemanticDefinition
    public let yCbCr: HDRYCbCrSemanticDefinition
    public let transfer: HDRTransferSemanticDefinition
    public let hlg: HDRHLGSemanticDefinition
    /// Column-major BT.709 RGB to BT.2020 RGB matrix values used by the production
    /// renderer and CPU reference path.
    public let bt709ToBT2020: [Double]
    public let inputMinimumNits: Double
    public let inputMaximumNits: Double

    public init(
        version: String,
        pq: HDRPQSemanticDefinition,
        ictcp: HDRICtCpSemanticDefinition,
        yCbCr: HDRYCbCrSemanticDefinition,
        transfer: HDRTransferSemanticDefinition,
        hlg: HDRHLGSemanticDefinition,
        bt709ToBT2020: [Double],
        inputMinimumNits: Double,
        inputMaximumNits: Double
    ) {
        self.version = version
        self.pq = pq
        self.ictcp = ictcp
        self.yCbCr = yCbCr
        self.transfer = transfer
        self.hlg = hlg
        self.bt709ToBT2020 = bt709ToBT2020
        self.inputMinimumNits = inputMinimumNits
        self.inputMaximumNits = inputMaximumNits
    }

    public static let calibrationV4 = HDRColorScienceSemanticDefinition(
        version: "calibration-color-science-v4",
        pq: .st2084,
        ictcp: .bt2100,
        yCbCr: .bt2100,
        transfer: .calibration,
        hlg: .bt2100,
        bt709ToBT2020: [
            0.6274040, 0.0690970, 0.0163916,
            0.3292820, 0.9195400, 0.0880132,
            0.0433136, 0.0113623, 0.8955950
        ],
        inputMinimumNits: 0,
        inputMaximumNits: 10_000
    )

    public var isValid: Bool {
        !version.isEmpty && pq.isValid && ictcp.isValid && yCbCr.isValid && transfer.isValid && hlg.isValid &&
            bt709ToBT2020.count == 9 && bt709ToBT2020.allSatisfy(\.isFinite) &&
            inputMinimumNits.isFinite && inputMaximumNits.isFinite &&
            inputMinimumNits >= 0 && inputMaximumNits > inputMinimumNits
    }

    public var bt709LuminanceVector: SIMD3<Float> {
        SIMD3(
            Float(yCbCr.bt709Luminance[0]),
            Float(yCbCr.bt709Luminance[1]),
            Float(yCbCr.bt709Luminance[2])
        )
    }

    public var bt2020LuminanceVector: SIMD3<Float> {
        SIMD3(
            Float(yCbCr.bt2020Luminance[0]),
            Float(yCbCr.bt2020Luminance[1]),
            Float(yCbCr.bt2020Luminance[2])
        )
    }

    public var bt709ToBT2020Matrix: simd_float3x3 {
        simd_float3x3(columns: (
            SIMD3<Float>(Float(bt709ToBT2020[0]), Float(bt709ToBT2020[1]), Float(bt709ToBT2020[2])),
            SIMD3<Float>(Float(bt709ToBT2020[3]), Float(bt709ToBT2020[4]), Float(bt709ToBT2020[5])),
            SIMD3<Float>(Float(bt709ToBT2020[6]), Float(bt709ToBT2020[7]), Float(bt709ToBT2020[8]))
        ))
    }

    public func canonicalSHA256() throws -> String {
        guard isValid else { throw HDRCanonicalIdentityError.encodingFailed }
        return try HDRCanonicalIdentity.sha256(self)
    }
}

/// Scene-statistics arithmetic used by the production V4 estimator and its
/// causal CPU state.  This is deliberately a typed owner shared by the
/// reference implementation, HDRProcessor, and the Metal estimator.  Keeping
/// the estimator constants here prevents a histogram or scene-cut mutation
/// from changing candidate scores without changing the runner identity.
public struct HDRSceneStatisticsSemanticDefinition: Codable, Hashable, Sendable {
    public let version: String
    public let proxyWidth: Int
    public let proxyHeight: Int
    public let histogramBinCount: Int
    public let linear16HistogramBinCount: Int
    public let inputMinimum: Double
    public let inputMaximum: Double
    public let histogramUpperExclusive: Double
    public let histogramLogMinimumExponent: Double
    public let histogramLogMaximumExponent: Double
    public let shadowDenseBreakpoint: Double
    public let shadowDenseLowerBinCount: Int
    public let shadowDenseUpperSpan: Double
    public let quantileFractions: [Double]
    public let minimumQuantileCount: UInt64
    public let quantizationMaximum: Double
    public let quantizationRounding: Double
    public let emptyAverage: Double
    public let averageClampMinimum: Double
    public let averageClampMaximum: Double
    public let shadowFloorMinimum: Double
    public let shadowFloorMaximum: Double
    public let shadowFloorFallback: Double
    public let shadowTopInterpolation: Double
    public let shadowTopMinimumDelta: Double
    public let shadowTopFallback: Double
    public let shadowTopMaximum: Double
    public let lowMidExpansionCoefficient: Double
    public let shadowProtectionCoefficient: Double
    public let sceneCutLuminanceFloor: Double
    public let sceneCutLog2Threshold: Double
    public let referenceFrameDurationSeconds: Double
    public let maximumContinuousDeltaSeconds: Double
    public let timeConstantStabilityFloor: Double
    public let timeConstantMinimumSeconds: Double
    public let timeConstantFallbackSeconds: Double
    public let adaptationBase: Double
    public let adaptationAverageCenter: Double
    public let adaptationCoefficient: Double
    public let adaptationMinimum: Double
    public let adaptationMaximum: Double
    public let neutralPercentiles: [Double]
    public let samplePositionRule: String

    public init(
        version: String = "hdr-scene-statistics-v4",
        proxyWidth: Int = 16,
        proxyHeight: Int = 9,
        histogramBinCount: Int = 64,
        linear16HistogramBinCount: Int = 16,
        inputMinimum: Double = 0,
        inputMaximum: Double = 1,
        histogramUpperExclusive: Double = 0.999999,
        histogramLogMinimumExponent: Double = -16,
        histogramLogMaximumExponent: Double = 0,
        shadowDenseBreakpoint: Double = 0.125,
        shadowDenseLowerBinCount: Int = 32,
        shadowDenseUpperSpan: Double = 0.875,
        quantileFractions: [Double] = [0.01, 0.05, 0.10, 0.25, 0.50, 0.90, 0.99],
        minimumQuantileCount: UInt64 = 1,
        quantizationMaximum: Double = 65_535,
        quantizationRounding: Double = 0.5,
        emptyAverage: Double = 0.5,
        averageClampMinimum: Double = 0.001,
        averageClampMaximum: Double = 1,
        shadowFloorMinimum: Double = 0.001,
        shadowFloorMaximum: Double = 0.20,
        shadowFloorFallback: Double = 0.01,
        shadowTopInterpolation: Double = 0.5,
        shadowTopMinimumDelta: Double = 0.025,
        shadowTopFallback: Double = 0.1125,
        shadowTopMaximum: Double = 0.60,
        lowMidExpansionCoefficient: Double = 0.08,
        shadowProtectionCoefficient: Double = 0.90,
        sceneCutLuminanceFloor: Double = 0.001,
        sceneCutLog2Threshold: Double = 1.25,
        referenceFrameDurationSeconds: Double = 1.0 / 60.0,
        maximumContinuousDeltaSeconds: Double = 0.5,
        timeConstantStabilityFloor: Double = 1e-6,
        timeConstantMinimumSeconds: Double = 1e-6,
        timeConstantFallbackSeconds: Double = 1_000_000,
        adaptationBase: Double = 0.94,
        adaptationAverageCenter: Double = 0.5,
        adaptationCoefficient: Double = 0.12,
        adaptationMinimum: Double = 0.90,
        adaptationMaximum: Double = 1.06,
        neutralPercentiles: [Double] = [0.002, 0.01, 0.025, 0.20, 0.50, 0.90, 1.0],
        samplePositionRule: String = "center-of-cell-floor-clamped"
    ) {
        self.version = version
        self.proxyWidth = proxyWidth
        self.proxyHeight = proxyHeight
        self.histogramBinCount = histogramBinCount
        self.linear16HistogramBinCount = linear16HistogramBinCount
        self.inputMinimum = inputMinimum
        self.inputMaximum = inputMaximum
        self.histogramUpperExclusive = histogramUpperExclusive
        self.histogramLogMinimumExponent = histogramLogMinimumExponent
        self.histogramLogMaximumExponent = histogramLogMaximumExponent
        self.shadowDenseBreakpoint = shadowDenseBreakpoint
        self.shadowDenseLowerBinCount = shadowDenseLowerBinCount
        self.shadowDenseUpperSpan = shadowDenseUpperSpan
        self.quantileFractions = quantileFractions
        self.minimumQuantileCount = minimumQuantileCount
        self.quantizationMaximum = quantizationMaximum
        self.quantizationRounding = quantizationRounding
        self.emptyAverage = emptyAverage
        self.averageClampMinimum = averageClampMinimum
        self.averageClampMaximum = averageClampMaximum
        self.shadowFloorMinimum = shadowFloorMinimum
        self.shadowFloorMaximum = shadowFloorMaximum
        self.shadowFloorFallback = shadowFloorFallback
        self.shadowTopInterpolation = shadowTopInterpolation
        self.shadowTopMinimumDelta = shadowTopMinimumDelta
        self.shadowTopFallback = shadowTopFallback
        self.shadowTopMaximum = shadowTopMaximum
        self.lowMidExpansionCoefficient = lowMidExpansionCoefficient
        self.shadowProtectionCoefficient = shadowProtectionCoefficient
        self.sceneCutLuminanceFloor = sceneCutLuminanceFloor
        self.sceneCutLog2Threshold = sceneCutLog2Threshold
        self.referenceFrameDurationSeconds = referenceFrameDurationSeconds
        self.maximumContinuousDeltaSeconds = maximumContinuousDeltaSeconds
        self.timeConstantStabilityFloor = timeConstantStabilityFloor
        self.timeConstantMinimumSeconds = timeConstantMinimumSeconds
        self.timeConstantFallbackSeconds = timeConstantFallbackSeconds
        self.adaptationBase = adaptationBase
        self.adaptationAverageCenter = adaptationAverageCenter
        self.adaptationCoefficient = adaptationCoefficient
        self.adaptationMinimum = adaptationMinimum
        self.adaptationMaximum = adaptationMaximum
        self.neutralPercentiles = neutralPercentiles
        self.samplePositionRule = samplePositionRule
    }

    public static let calibrationV4 = HDRSceneStatisticsSemanticDefinition()

    public var isValid: Bool {
        let scalars = [
            inputMinimum, inputMaximum, histogramUpperExclusive,
            histogramLogMinimumExponent, histogramLogMaximumExponent,
            shadowDenseBreakpoint, shadowDenseUpperSpan,
            quantizationMaximum, quantizationRounding, emptyAverage,
            averageClampMinimum, averageClampMaximum, shadowFloorMinimum,
            shadowFloorMaximum, shadowFloorFallback, shadowTopInterpolation,
            shadowTopMinimumDelta, shadowTopFallback, shadowTopMaximum,
            lowMidExpansionCoefficient, shadowProtectionCoefficient,
            sceneCutLuminanceFloor, sceneCutLog2Threshold,
            referenceFrameDurationSeconds, maximumContinuousDeltaSeconds,
            timeConstantStabilityFloor, timeConstantMinimumSeconds,
            timeConstantFallbackSeconds, adaptationBase, adaptationAverageCenter,
            adaptationCoefficient, adaptationMinimum, adaptationMaximum
        ]
        return !version.isEmpty && proxyWidth > 0 && proxyHeight > 0 &&
            histogramBinCount > 0 && histogramBinCount <= 64 &&
            linear16HistogramBinCount > 0 && linear16HistogramBinCount <= histogramBinCount &&
            inputMinimum <= inputMaximum &&
            histogramUpperExclusive > inputMinimum && histogramUpperExclusive <= inputMaximum &&
            histogramLogMinimumExponent < histogramLogMaximumExponent &&
            shadowDenseBreakpoint > inputMinimum && shadowDenseBreakpoint < inputMaximum &&
            shadowDenseLowerBinCount > 0 && shadowDenseLowerBinCount < histogramBinCount &&
            shadowDenseUpperSpan > 0 &&
            quantileFractions.count == 7 &&
            quantileFractions.allSatisfy { $0.isFinite && (0...1).contains($0) } &&
            quantileFractions == quantileFractions.sorted() &&
            neutralPercentiles.count == 7 && neutralPercentiles.allSatisfy { $0.isFinite } &&
            neutralPercentiles == neutralPercentiles.sorted() &&
            minimumQuantileCount > 0 && quantizationMaximum > 0 &&
            quantizationRounding >= 0 && averageClampMinimum <= averageClampMaximum &&
            shadowFloorMinimum <= shadowFloorMaximum &&
            shadowFloorFallback >= inputMinimum && shadowFloorFallback <= shadowFloorMaximum &&
            shadowTopMinimumDelta >= 0 && shadowTopMaximum > shadowFloorMaximum &&
            shadowTopFallback >= shadowFloorMinimum && shadowTopFallback <= shadowTopMaximum &&
            sceneCutLuminanceFloor > 0 && sceneCutLog2Threshold >= 0 &&
            referenceFrameDurationSeconds > 0 && maximumContinuousDeltaSeconds > 0 &&
            timeConstantStabilityFloor > 0 && timeConstantMinimumSeconds > 0 &&
            timeConstantFallbackSeconds > 0 && adaptationMinimum <= adaptationMaximum &&
            scalars.allSatisfy(\.isFinite) && !samplePositionRule.isEmpty
    }

    public func canonicalSHA256() throws -> String {
        guard isValid else { throw HDRCanonicalIdentityError.encodingFailed }
        return try HDRCanonicalIdentity.sha256(self)
    }
}

/// Tone-mapping arithmetic used by the calibration production path.  The
/// renderer and the scalar reference both consume this value; it is not a
/// documentation-only list of constants.  Development-only V6 controller
/// values remain on their explicitly separate configuration path.
public struct HDRToneMappingSemanticDefinition: Codable, Hashable, Sendable {
    public let version: String
    public let inputLuminanceMinimum: Double
    public let inputLuminanceMaximum: Double
    public let smoothstepDenominatorFloor: Double
    public let smoothstepLinearCoefficient: Double
    public let smoothstepQuadraticCoefficient: Double
    public let shoulderStartBase: Double
    public let shoulderContrastCoefficient: Double
    public let legacyShadowGateLower: Double
    public let legacyShadowGateUpper: Double
    /// Scene-estimator and scene-relative controller semantics are shared
    /// with HDRSceneStatistics and the Metal estimator.  They deliberately
    /// live in one value rather than being copied into this tone definition.
    public let sceneStatistics: HDRSceneStatisticsSemanticDefinition
    public let defaultShadowPresenceLower: Double
    public let defaultShadowPresenceUpper: Double
    public let defaultShadowFadeLower: Double
    public let defaultShadowFadeUpper: Double
    public let defaultShadowAttenuationCoefficient: Double
    public let chromaReductionLuminanceStart: Double
    public let chromaReductionPeakRatioMinimum: Double
    public let chromaReductionCoefficient: Double
    public let gamutLuminanceFloor: Double
    public let gamutDenominatorFloor: Double
    public let chromaScaleMinimum: Double
    public let chromaScaleMaximum: Double
    public let outputLuminanceMinimum: Double

    // Compatibility accessors for the scalar and shader adapters.  The
    // stored source of truth is sceneStatistics above.
    public var sceneShadowFloorLower: Double { sceneStatistics.shadowFloorMinimum }
    public var sceneShadowFloorUpper: Double { sceneStatistics.shadowFloorMaximum }
    public var sceneShadowFloorFallback: Double { sceneStatistics.shadowFloorFallback }
    public var sceneShadowTopMinimumDelta: Double { sceneStatistics.shadowTopMinimumDelta }
    public var sceneShadowTopFallback: Double { sceneStatistics.shadowTopFallback }
    public var sceneShadowTopUpper: Double { sceneStatistics.shadowTopMaximum }
    public var sceneLowMidExpansionCoefficient: Double { sceneStatistics.lowMidExpansionCoefficient }
    public var sceneShadowProtectionCoefficient: Double { sceneStatistics.shadowProtectionCoefficient }

    public init(
        version: String,
        inputLuminanceMinimum: Double = 0,
        inputLuminanceMaximum: Double = 1,
        smoothstepDenominatorFloor: Double = 1e-6,
        smoothstepLinearCoefficient: Double = 3,
        smoothstepQuadraticCoefficient: Double = 2,
        shoulderStartBase: Double = 0.68,
        shoulderContrastCoefficient: Double = 0.20,
        legacyShadowGateLower: Double = 0.035,
        legacyShadowGateUpper: Double = 0.48,
        sceneStatistics: HDRSceneStatisticsSemanticDefinition = .calibrationV4,
        defaultShadowPresenceLower: Double = 0.002,
        defaultShadowPresenceUpper: Double = 0.025,
        defaultShadowFadeLower: Double = 0.12,
        defaultShadowFadeUpper: Double = 0.48,
        defaultShadowAttenuationCoefficient: Double = 0.18,
        chromaReductionLuminanceStart: Double = 1,
        chromaReductionPeakRatioMinimum: Double = 1.001,
        chromaReductionCoefficient: Double = 0.35,
        gamutLuminanceFloor: Double = 0,
        gamutDenominatorFloor: Double = 1e-6,
        chromaScaleMinimum: Double = 0,
        chromaScaleMaximum: Double = 1,
        outputLuminanceMinimum: Double = 0
    ) {
        self.version = version
        self.inputLuminanceMinimum = inputLuminanceMinimum
        self.inputLuminanceMaximum = inputLuminanceMaximum
        self.smoothstepDenominatorFloor = smoothstepDenominatorFloor
        self.smoothstepLinearCoefficient = smoothstepLinearCoefficient
        self.smoothstepQuadraticCoefficient = smoothstepQuadraticCoefficient
        self.shoulderStartBase = shoulderStartBase
        self.shoulderContrastCoefficient = shoulderContrastCoefficient
        self.legacyShadowGateLower = legacyShadowGateLower
        self.legacyShadowGateUpper = legacyShadowGateUpper
        self.sceneStatistics = sceneStatistics
        self.defaultShadowPresenceLower = defaultShadowPresenceLower
        self.defaultShadowPresenceUpper = defaultShadowPresenceUpper
        self.defaultShadowFadeLower = defaultShadowFadeLower
        self.defaultShadowFadeUpper = defaultShadowFadeUpper
        self.defaultShadowAttenuationCoefficient = defaultShadowAttenuationCoefficient
        self.chromaReductionLuminanceStart = chromaReductionLuminanceStart
        self.chromaReductionPeakRatioMinimum = chromaReductionPeakRatioMinimum
        self.chromaReductionCoefficient = chromaReductionCoefficient
        self.gamutLuminanceFloor = gamutLuminanceFloor
        self.gamutDenominatorFloor = gamutDenominatorFloor
        self.chromaScaleMinimum = chromaScaleMinimum
        self.chromaScaleMaximum = chromaScaleMaximum
        self.outputLuminanceMinimum = outputLuminanceMinimum
    }

    public static let calibrationV4 = HDRToneMappingSemanticDefinition(
        version: "calibration-tone-mapping-v4"
    )

    public var isValid: Bool {
        let values = [
            inputLuminanceMinimum, inputLuminanceMaximum,
            smoothstepDenominatorFloor, smoothstepLinearCoefficient,
            smoothstepQuadraticCoefficient, shoulderStartBase,
            shoulderContrastCoefficient, legacyShadowGateLower,
            legacyShadowGateUpper,
            defaultShadowPresenceLower, defaultShadowPresenceUpper,
            defaultShadowFadeLower, defaultShadowFadeUpper,
            defaultShadowAttenuationCoefficient, chromaReductionLuminanceStart,
            chromaReductionPeakRatioMinimum, chromaReductionCoefficient,
            gamutLuminanceFloor, gamutDenominatorFloor, chromaScaleMinimum,
            chromaScaleMaximum, outputLuminanceMinimum
        ]
        return !version.isEmpty && sceneStatistics.isValid && values.allSatisfy(\.isFinite) &&
            inputLuminanceMinimum <= inputLuminanceMaximum &&
            smoothstepDenominatorFloor > 0 &&
            smoothstepLinearCoefficient.isFinite &&
            smoothstepQuadraticCoefficient.isFinite &&
            legacyShadowGateLower <= legacyShadowGateUpper &&
            defaultShadowPresenceLower <= defaultShadowPresenceUpper &&
            defaultShadowFadeLower <= defaultShadowFadeUpper &&
            gamutDenominatorFloor > 0 &&
            chromaScaleMinimum <= chromaScaleMaximum &&
            chromaScaleMinimum >= 0 && chromaScaleMaximum <= 1 &&
            chromaReductionPeakRatioMinimum >= chromaReductionLuminanceStart
    }

    public func canonicalSHA256() throws -> String {
        guard isValid else { throw HDRCanonicalIdentityError.encodingFailed }
        return try HDRCanonicalIdentity.sha256(self)
    }
}
