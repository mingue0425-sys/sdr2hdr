import Foundation
import HDRCore
import HDRPlayerKit

enum RegressionCodec: String, Codable, Sendable {
    case h264
    case hevc
}

enum RegressionTimingMode: String, Codable, Sendable {
    case cfr
    case vfr
}

enum RegressionPixelFormatFamily: String, Codable, Sendable {
    case nv12
    case p010
}

enum RegressionRange: String, Codable, Sendable {
    case video
    case full

    var decodeRange: HDRDecodeRange {
        switch self {
        case .video: return .video
        case .full: return .full
        }
    }
}

enum RegressionTransfer: String, Codable, Sendable {
    case bt709
}

enum RegressionMatrix: String, Codable, Sendable {
    case bt709
}

enum RegressionContentClass: String, Codable, Sendable {
    case darkGradient = "dark-gradient"
    case neutralColor = "neutral-color"
    case motion
    case chromaEdge = "chroma-edge"
    case nearBlack = "near-black"

    var isStatic: Bool {
        switch self {
        case .motion: return false
        case .darkGradient, .neutralColor, .chromaEdge, .nearBlack: return true
        }
    }
}

struct RegressionChromaSitingExpectation: Codable, Equatable, Sendable {
    let required: Bool
    let allowed: [HDRChromaSiting]?

    init(required: Bool, allowed: [HDRChromaSiting]? = nil) {
        self.required = required
        self.allowed = allowed
    }
}

struct RealMediaRegressionFixture: Codable, Equatable, Sendable, Identifiable {
    let id: String
    let codec: RegressionCodec
    let sourceBitDepth: Int
    let expectedDecodeBitDepth: Int
    let expectedPixelFormatFamily: RegressionPixelFormatFamily
    let range: RegressionRange
    let frameRate: Double
    let timing: RegressionTimingMode
    let contentClass: RegressionContentClass
    let profile: String
    let expectedTransfer: RegressionTransfer
    let expectedMatrix: RegressionMatrix
    let chromaSiting: RegressionChromaSitingExpectation
    let minimumFrames: Int
    let minimumDistinctFrameDurations: Int
    let staticContent: Bool
    let minimumInputLuminanceLevels: Int

    var decodePrecision: HDRDecodePrecision {
        expectedPixelFormatFamily == .p010 ? .tenBitPreferred : .eightBit
    }
}

struct RealMediaRegressionManifest: Codable, Equatable, Sendable {
    let version: Int
    let baseline: String
    let fixtures: [RealMediaRegressionFixture]

    static let expectedVersion = 1
    static let expectedBaseline = "0a980d9"

    func validate() throws {
        guard version == Self.expectedVersion else {
            throw RegressionManifestError.invalid("unsupported manifest version \(version)")
        }
        guard baseline == Self.expectedBaseline else {
            throw RegressionManifestError.invalid(
                "manifest baseline \(baseline) does not match \(Self.expectedBaseline)"
            )
        }
        guard !fixtures.isEmpty else {
            throw RegressionManifestError.invalid("manifest has no fixtures")
        }
        let ids = fixtures.map(\.id)
        guard Set(ids).count == ids.count else {
            throw RegressionManifestError.invalid("manifest fixture IDs are not unique")
        }
        for fixture in fixtures {
            guard fixture.sourceBitDepth == 8 || fixture.sourceBitDepth == 10 else {
                throw RegressionManifestError.invalid(
                    "\(fixture.id) has unsupported source bit depth \(fixture.sourceBitDepth)"
                )
            }
            guard fixture.expectedDecodeBitDepth == fixture.sourceBitDepth else {
                throw RegressionManifestError.invalid(
                    "\(fixture.id) does not require source precision to be retained"
                )
            }
            guard (fixture.sourceBitDepth == 10) == (fixture.expectedPixelFormatFamily == .p010) else {
                throw RegressionManifestError.invalid(
                    "\(fixture.id) has inconsistent bit-depth and pixel-format family"
                )
            }
            guard fixture.frameRate.isFinite, fixture.frameRate > 0 else {
                throw RegressionManifestError.invalid("\(fixture.id) has invalid frame rate")
            }
            guard fixture.minimumFrames > 0 else {
                throw RegressionManifestError.invalid("\(fixture.id) has invalid minimum frame count")
            }
            guard fixture.minimumDistinctFrameDurations >= (fixture.timing == .vfr ? 2 : 1) else {
                throw RegressionManifestError.invalid(
                    "\(fixture.id) has insufficient timing diversity requirement"
                )
            }
            guard fixture.chromaSiting.required || fixture.chromaSiting.allowed != nil else {
                throw RegressionManifestError.invalid(
                    "\(fixture.id) must declare a chroma metadata policy"
                )
            }
            guard fixture.staticContent == fixture.contentClass.isStatic else {
                throw RegressionManifestError.invalid(
                    "\(fixture.id) staticContent disagrees with contentClass"
                )
            }
        }
    }

    static func load(from url: URL) throws -> Self {
        let data = try Data(contentsOf: url)
        let manifest = try JSONDecoder().decode(Self.self, from: data)
        try manifest.validate()
        return manifest
    }
}

struct RegressionGates: Codable, Equatable, Sendable {
    let version: Int
    let minimumDecodedFrames: Int
    let minimumP010InputLuminanceLevels: Int
    let minimumP010OutputLuminanceLevels: Int
    let maximumSequenceMismatch: UInt64
    let maximumUnexpectedClippingFraction: Double
    let maximumStaticFlickerP95: Double
    let maximumStaticFlickerMaximum: Double
    let maximumTimestampBackwardsSeconds: Double
    let maximumExpectedCFRDeltaVariationSeconds: Double

    static func load(from url: URL) throws -> Self {
        try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
    }
}

enum RegressionManifestError: Error, LocalizedError {
    case invalid(String)

    var errorDescription: String? {
        switch self {
        case .invalid(let message): return message
        }
    }
}

enum RegressionMode: String, Codable, Sendable {
    case nearest
    case sitingAwareBilinear
}

struct RegressionFrameOutput: Codable, Sendable {
    let finiteSampleCount: Int
    let nanCount: Int
    let infinityCount: Int
    let negativeCount: Int
    let nonZeroSampleCount: Int
    let meanLuminance: Double
    let minimumValue: Double
    let maximumValue: Double
    let clippingFraction: Double
    let luminance: [Float]
}

struct RegressionTimingSummary: Codable, Sendable {
    let timestampStart: Double
    let timestampEnd: Double
    let frameDeltas: [Double]
    let distinctFrameDeltaCount: Int
    let gpuMilliseconds: [Double]
    let cpuMilliseconds: [Double]
}

struct RegressionOutputSummary: Codable, Sendable {
    let finiteSampleCount: Int
    let nanCount: Int
    let infinityCount: Int
    let negativeCount: Int
    let nonZeroSampleCount: Int
    let minimumValue: Double
    let maximumValue: Double
    let maximumClippingFraction: Double
    let inputDistinguishableLuminanceLevels: Int
    let outputDistinguishableLuminanceLevels: Int
    let staticFlickerP95: Double
    let staticFlickerMaximum: Double
}

struct RegressionMetadataSummary: Codable, Sendable {
    let pixelFormat: String
    let pixelFormatFamily: RegressionPixelFormatFamily
    let bitDepth: Int
    let range: RegressionRange
    let transfer: String
    let matrix: String
    let topChromaLocation: String?
    let bottomChromaLocation: String?
    let resolvedChromaSiting: String
}

struct RegressionModeResult: Codable, Sendable {
    let mode: RegressionMode
    let metadata: RegressionMetadataSummary
    let frameCount: Int
    let timestamps: [Double]
    let timing: RegressionTimingSummary
    let output: RegressionOutputSummary
    let gpuCompletedSequence: UInt64
    let adaptiveCommittedSequence: UInt64
    let traceCount: Int
    let outputTextureAllocations: Int
    let passed: Bool
    let failures: [String]
}

struct RegressionModeComparison: Codable, Sendable {
    let meanAbsoluteLuminanceDelta: Double
    let p95AbsoluteLuminanceDelta: Double
    let maximumAbsoluteLuminanceDelta: Double
    let clippingFractionDelta: Double
    let gpuP95MillisecondsDelta: Double
}

struct RealMediaRegressionFixtureResult: Codable, Sendable {
    let manifest: RealMediaRegressionFixture
    let id: String
    let status: String
    let skipReason: String?
    let nearest: RegressionModeResult?
    let candidate: RegressionModeResult?
    let comparison: RegressionModeComparison?
}

struct RealMediaRegressionReport: Codable, Sendable {
    let baseline: String
    let candidate: String
    let fixtureCount: Int
    let failures: Int
    let skipped: Int
    let fixtures: [RealMediaRegressionFixtureResult]
}
