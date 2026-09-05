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

public struct PlayerOptions: Equatable, Sendable {
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

    public init(
        inputURL: URL? = nil,
        preset: String = "calibrated-v4",
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
        v62Candidate: HDRV62ToneCurveCandidate = .adaptiveCombined
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
    }

    public static let usage = """
    Usage:
      HDRPlayer <video-file> [--preset natural|hdr|vivid|calibrated-v1|calibrated-v2|calibrated-v4|calibrated-v3-candidate|v6-candidate-bandlimited-035|v6-candidate-bandlimited-045|v6-candidate-bandlimited-055|v6-candidate-bandlimited-065|v6-candidate-bandlimited-075|v6-candidate-no-lowmid|v6.2-candidate-adaptive-highlight|v6.2-candidate-adaptive-dynamic-range|v6.2-candidate-adaptive-combined] [--debug]
      HDRPlayer <video-file> --controlled-ab --debug
      HDRPlayer <video-file> --controlled-v6 --debug
      HDRPlayer <video-file> --debug --diagnostic-json
      HDRPlayer <video-file> --controlled-ab --debug --diagnostic-roi x,y,width,height
      HDRPlayer <video-file> --paper-white 203 --peak 1000
      HDRPlayer --edr-test-pattern [--play-for 5]

    Controls: Space play/pause, Left/Right seek 5s, F fullscreen, Esc exit fullscreen,
    B quick V2/V4 A/B toggle, 6 quick V4/V6 candidate toggle, 7 quick V4/V6.2 candidate toggle, D diagnostic dump, Shift-drag generic ROI, Up/Down volume,
    Command-Q quit.
    """

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
                let supported = ["natural", "hdr", "vivid", "calibrated-v1", "calibrated-v2", "calibrated-v4", "calibrated-v3-candidate"] +
                    HDRV6ToneCurveCandidate.allCases.map(\.rawValue) +
                    HDRV62ToneCurveCandidate.allCases.map(\.rawValue)
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
        var configuration: HDRConfiguration
        if let candidate = HDRV62ToneCurveCandidate(rawValue: preset) {
            configuration = candidate.configuration()
        } else if let candidate = HDRV6ToneCurveCandidate(rawValue: preset) {
            configuration = candidate.configuration()
        } else {
            switch preset {
            case "natural": configuration = .natural
            case "hdr": configuration = .hdr
            case "vivid": configuration = .vivid
            case "calibrated-v1": configuration = .calibratedV1
            case "calibrated-v2": configuration = .calibratedV2
            case "calibrated-v4": configuration = .calibratedV4
            case "calibrated-v3-candidate": configuration = .calibratedV3Candidate
            default: throw HDRPlayerCLIError.unsupportedPreset(preset)
            }
        }
        configuration.outputMode = .edr
        if let paperWhiteNits { configuration.paperWhiteNits = paperWhiteNits }
        if let peakNits { configuration.peakNits = peakNits }
        configuration.inputFallbackPolicy = .bt709VideoRange
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
