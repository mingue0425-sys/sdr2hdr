import Foundation
import HDRCore

public enum HDRPlayerCLIError: Error, LocalizedError, Equatable {
    case helpRequested
    case missingInput
    case tooManyInputs
    case invalidOption(String)
    case invalidNumber(String)
    case invalidROI(String)
    case unsupportedPreset(String)
    case unsupportedMode(String)

    public var errorDescription: String? {
        switch self {
        case .helpRequested:
            return PlayerOptions.usage
        case .missingInput:
            return "missing input video; pass a path or use --edr-test-pattern"
        case .tooManyInputs:
            return "only one input video is supported"
        case .invalidOption(let option):
            return "unknown option: \(option)"
        case .invalidNumber(let value):
            return "invalid numeric value: \(value)"
        case .invalidROI(let value):
            return "invalid diagnostic ROI: \(value); expected normalized x,y,width,height within 0...1"
        case .unsupportedPreset(let preset):
            return "unsupported preset: \(preset)"
        case .unsupportedMode(let mode):
            return "unsupported player mode: \(mode); the player presentation path currently uses EDR"
        }
    }
}

/// Player levels of `HDRConfiguration.skinHighlightProtection`.
public enum HDRSkinProtection: String, CaseIterable, Sendable {
    case off, weak, on

    public var strength: Float {
        switch self {
        case .off: return 0
        case .weak: return 0.5
        case .on: return 1
        }
    }

    public var displayName: String {
        switch self {
        case .off: return "끔"
        case .weak: return "약하게"
        case .on: return "켬 (기본)"
        }
    }
}

public struct PlayerOptions: Equatable, Sendable {
    /// The player decodes BT.709 SDR as the SDR rendition of a YouTube HDR
    /// (HLG) upload unless told otherwise; Y switches to the plain BT.709
    /// inverse OETF during playback. Calibration presets are unaffected.
    public static let defaultSDRTransferInterpretation: HDRSDRTransferInterpretation = .youtubeHLGDerivedInverseLuminanceGain

    public var inputURL: URL?
    public var preset: String
    public var paperWhiteNits: Float?
    public var peakNits: Float?
    public var debug: Bool
    public var playFor: TimeInterval?
    public var edrTestPattern: Bool
    public var startFullscreen: Bool
    public var controlledAB: Bool
    public var controlledV6: Bool
    public var diagnosticJSON: Bool
    public var diagnosticROI: HDRDiagnosticROI?
    public var v6Candidate: HDRV6ToneCurveCandidate
    public var v62Candidate: HDRV62ToneCurveCandidate
    public var decodePrecision: HDRDecodePrecision
    public var chromaReconstructionMode: HDRChromaReconstructionMode
    public var sdrTransferInterpretation: HDRSDRTransferInterpretation
    public var gainGuidance: HDRGainGuidance
    /// Convert inputs AVFoundation cannot decode (YouTube VP9/AV1) once
    /// before playback. `--no-convert` turns it off.
    public var convertUndecodable: Bool = true
    /// Where converted inputs go; nil means
    /// `PlayableInputConverter.defaultCacheDirectory()`.
    public var convertDirectory: URL?
    /// MetalFX upscaling before presentation (`--upscale off|1.5x|2x|auto`).
    public var upscale: HDRUpscaleMode = .auto
    /// `HDRConfiguration.skinHighlightProtection` (`--skin-protection off|weak|on`).
    /// On by default: bright toon-shaded skin (MMD, anime) otherwise glows
    /// at specular brightness. Calibration presets keep it off.
    public var skinProtection: HDRSkinProtection = .on

    public init(
        inputURL: URL? = nil,
        preset: String = HDRPresetResolver.productionDefault,
        paperWhiteNits: Float? = nil,
        peakNits: Float? = nil,
        debug: Bool = false,
        playFor: TimeInterval? = nil,
        edrTestPattern: Bool = false,
        startFullscreen: Bool = false,
        controlledAB: Bool = false,
        controlledV6: Bool = false,
        diagnosticJSON: Bool = false,
        diagnosticROI: HDRDiagnosticROI? = nil,
        v6Candidate: HDRV6ToneCurveCandidate = .bandLimited055,
        v62Candidate: HDRV62ToneCurveCandidate = .adaptiveCombined,
        decodePrecision: HDRDecodePrecision = .automatic,
        chromaReconstructionMode: HDRChromaReconstructionMode = .nearest,
        sdrTransferInterpretation: HDRSDRTransferInterpretation = PlayerOptions.defaultSDRTransferInterpretation,
        gainGuidance: HDRGainGuidance = .off
    ) {
        self.inputURL = inputURL
        self.preset = preset
        self.paperWhiteNits = paperWhiteNits
        self.peakNits = peakNits
        self.debug = debug
        self.playFor = playFor
        self.edrTestPattern = edrTestPattern
        self.startFullscreen = startFullscreen
        self.controlledAB = controlledAB
        self.controlledV6 = controlledV6
        self.diagnosticJSON = diagnosticJSON
        self.diagnosticROI = diagnosticROI
        self.v6Candidate = v6Candidate
        self.v62Candidate = v62Candidate
        self.decodePrecision = decodePrecision
        self.chromaReconstructionMode = chromaReconstructionMode
        self.sdrTransferInterpretation = sdrTransferInterpretation
        self.gainGuidance = gainGuidance
    }

    public static var usage: String {
        """
        Usage:
          HDRPlayer <video-file> [--preset \(HDRPresetResolver.supportedPresetNames.joined(separator: "|"))] [--debug]
          HDRPlayer <video-file> --controlled-ab --debug
          HDRPlayer <video-file> --controlled-v6 --debug
          HDRPlayer <video-file> --debug --diagnostic-json
          HDRPlayer <video-file> --decode-precision automatic|8bit|10bit
          HDRPlayer <video-file> --chroma-reconstruction nearest|siting-aware-bilinear
          HDRPlayer <video-file> --sdr-transfer \(HDRSDRTransferInterpretation.allCases.map(\.cliName).joined(separator: "|"))
          HDRPlayer <video-file> --gain-guidance off|noise-gated
          HDRPlayer <video-file> --skin-protection off|weak|on   (default on: keeps bright skin from glowing)
          HDRPlayer <video-file> --upscale off|1.5x|2x|auto   (MetalFX, default auto: up to the on-screen size)
          HDRPlayer <youtube.webm> [--convert-dir DIR | --no-convert]   (VP9/AV1 inputs are converted once to HEVC)
          HDRPlayer <video-file> --controlled-ab --debug --diagnostic-roi x,y,width,height
          HDRPlayer <video-file> --paper-white 203 --peak 1000
          HDRPlayer --edr-test-pattern [--play-for 5]

        SDR is decoded as a YouTube HDR (HLG) rendition by default (youtube-hlg-v2); Y switches to bt709-oetf.

        Controls: Space play/pause, Left/Right seek 5s, F fullscreen, Esc exit fullscreen, Y YouTube HDR decode on/off,
        B quick V2/V4 A/B toggle, 6 quick V4/V6 candidate toggle, 7 quick V4/V6.2 candidate toggle, D diagnostic dump, Shift-drag generic ROI, Up/Down volume,
        Command-Q quit.
        """
    }

    public static func parse(arguments: [String]) throws -> PlayerOptions {
        var options = PlayerOptions()
        var positional: [String] = []
        var index = 1

        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--help", "-h":
                throw HDRPlayerCLIError.helpRequested
            case "--debug":
                options.debug = true
                index += 1
            case "--edr-test-pattern":
                options.edrTestPattern = true
                index += 1
            case "--fullscreen":
                options.startFullscreen = true
                index += 1
            case "--controlled-ab":
                options.controlledAB = true
                index += 1
            case "--controlled-v6":
                options.controlledV6 = true
                index += 1
            case "--diagnostic-json":
                options.diagnosticJSON = true
                options.debug = true
                index += 1
            case "--diagnostic-roi":
                let value = try valueAfter(argument, arguments: arguments, index: index)
                options.diagnosticROI = try parseROI(value)
                options.debug = true
                index += 2
            case "--preset":
                let value = try valueAfter(argument, arguments: arguments, index: index)
                let normalized = value.lowercased()
                let supported = HDRPresetResolver.supportedPresetNames
                guard supported.contains(normalized) else {
                    throw HDRPlayerCLIError.unsupportedPreset(value)
                }
                options.preset = normalized
                if let candidate = HDRV62ToneCurveCandidate(rawValue: normalized) {
                    options.v62Candidate = candidate
                } else if let candidate = HDRV6ToneCurveCandidate(rawValue: normalized) {
                    options.v6Candidate = candidate
                }
                index += 2
            case "--paper-white":
                let value = try valueAfter(argument, arguments: arguments, index: index)
                options.paperWhiteNits = try parsePositive(value)
                index += 2
            case "--peak":
                let value = try valueAfter(argument, arguments: arguments, index: index)
                options.peakNits = try parsePositive(value)
                index += 2
            case "--decode-precision":
                let value = try valueAfter(argument, arguments: arguments, index: index).lowercased()
                switch value {
                case "automatic":
                    options.decodePrecision = .automatic
                case "8bit", "8-bit":
                    options.decodePrecision = .eightBit
                case "10bit", "10-bit", "p010":
                    options.decodePrecision = .tenBitPreferred
                default:
                    throw HDRPlayerCLIError.invalidOption("unsupported decode precision: \(value)")
                }
                index += 2
            case "--chroma-reconstruction":
                let value = try valueAfter(argument, arguments: arguments, index: index).lowercased()
                switch value {
                case "nearest":
                    options.chromaReconstructionMode = .nearest
                case "siting-aware-bilinear", "bilinear", "siting-aware":
                    options.chromaReconstructionMode = .sitingAwareBilinear
                default:
                    throw HDRPlayerCLIError.invalidOption("unsupported chroma reconstruction: \(value)")
                }
                index += 2
            case "--sdr-transfer":
                let value = try valueAfter(argument, arguments: arguments, index: index)
                guard let policy = HDRSDRTransferInterpretation(cliName: value) else {
                    throw HDRPlayerCLIError.invalidOption("unsupported SDR transfer interpretation: \(value)")
                }
                options.sdrTransferInterpretation = policy
                index += 2
            case "--gain-guidance":
                let value = try valueAfter(argument, arguments: arguments, index: index)
                guard let guidance = HDRGainGuidance(cliName: value) else {
                    throw HDRPlayerCLIError.invalidOption("unsupported gain guidance: \(value) (off|noise-gated)")
                }
                options.gainGuidance = guidance
                index += 2
            case "--skin-protection":
                let value = try valueAfter(argument, arguments: arguments, index: index)
                guard let level = HDRSkinProtection(rawValue: value.lowercased()) else {
                    throw HDRPlayerCLIError.invalidOption("unsupported skin protection: \(value) (off|weak|on)")
                }
                options.skinProtection = level
                index += 2
            case "--upscale":
                let value = try valueAfter(argument, arguments: arguments, index: index)
                guard let mode = HDRUpscaleMode(cliName: value) else {
                    throw HDRPlayerCLIError.invalidOption("unsupported upscale: \(value) (off|1.5x|2x|auto)")
                }
                options.upscale = mode
                index += 2
            case "--no-convert":
                options.convertUndecodable = false
                index += 1
            case "--convert-dir":
                let value = try valueAfter(argument, arguments: arguments, index: index)
                options.convertDirectory = URL(fileURLWithPath: value, isDirectory: true).standardizedFileURL
                index += 2
            case "--play-for":
                let value = try valueAfter(argument, arguments: arguments, index: index)
                let seconds = try parsePositive(value)
                options.playFor = TimeInterval(seconds)
                index += 2
            case "--mode":
                let value = try valueAfter(argument, arguments: arguments, index: index)
                guard value.lowercased() == "edr" else {
                    throw HDRPlayerCLIError.unsupportedMode(value)
                }
                index += 2
            default:
                if argument.hasPrefix("-") {
                    throw HDRPlayerCLIError.invalidOption(argument)
                }
                positional.append(argument)
                index += 1
            }
        }

        guard positional.count <= 1 else { throw HDRPlayerCLIError.tooManyInputs }
        if let path = positional.first {
            options.inputURL = URL(fileURLWithPath: path).standardizedFileURL
        }
        guard options.edrTestPattern || options.inputURL != nil else {
            throw HDRPlayerCLIError.missingInput
        }
        if options.edrTestPattern {
            options.inputURL = nil
        }
        return options
    }

    public func baseConfiguration() throws -> HDRConfiguration {
        guard var configuration = HDRPresetResolver.configuration(for: preset) else {
            throw HDRPlayerCLIError.unsupportedPreset(preset)
        }
        configuration.outputMode = .edr
        if let paperWhiteNits { configuration.paperWhiteNits = paperWhiteNits }
        if let peakNits { configuration.peakNits = peakNits }
        configuration.inputFallbackPolicy = .bt709VideoRange
        configuration.chromaReconstructionMode = chromaReconstructionMode
        configuration.sdrTransferInterpretation = sdrTransferInterpretation
        configuration.skinHighlightProtection = skinProtection.strength
        configuration.gainGuidance = gainGuidance
        return try configuration.validated()
    }

    private static func valueAfter(_ option: String, arguments: [String], index: Int) throws -> String {
        guard index + 1 < arguments.count else {
            throw HDRPlayerCLIError.invalidOption("\(option) requires a value")
        }
        return arguments[index + 1]
    }

    private static func parsePositive(_ value: String) throws -> Float {
        guard let number = Float(value), number.isFinite, number > 0 else {
            throw HDRPlayerCLIError.invalidNumber(value)
        }
        return number
    }

    private static func parseROI(_ value: String) throws -> HDRDiagnosticROI {
        let components = value.split(separator: ",", omittingEmptySubsequences: false)
        guard components.count == 4,
              let x = Float(components[0]),
              let y = Float(components[1]),
              let width = Float(components[2]),
              let height = Float(components[3]),
              x.isFinite, y.isFinite, width.isFinite, height.isFinite,
              x >= 0, y >= 0, width > 0, height > 0,
              x + width <= 1, y + height <= 1 else {
            throw HDRPlayerCLIError.invalidROI(value)
        }
        return HDRDiagnosticROI(x: x, y: y, width: width, height: height)
    }
}
