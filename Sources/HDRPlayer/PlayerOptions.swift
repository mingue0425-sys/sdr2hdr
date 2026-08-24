import Foundation
import HDRCore

public enum HDRPlayerCLIError: Error, LocalizedError, Equatable {
    case helpRequested
    case missingInput
    case tooManyInputs
    case invalidOption(String)
    case invalidNumber(String)
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

    public init(
        inputURL: URL? = nil,
        preset: String = "hdr",
        paperWhiteNits: Float? = nil,
        peakNits: Float? = nil,
        debug: Bool = false,
        playFor: TimeInterval? = nil,
        edrTestPattern: Bool = false,
        startFullscreen: Bool = false
    ) {
        self.inputURL = inputURL
        self.preset = preset
        self.paperWhiteNits = paperWhiteNits
        self.peakNits = peakNits
        self.debug = debug
        self.playFor = playFor
        self.edrTestPattern = edrTestPattern
        self.startFullscreen = startFullscreen
    }

    public static let usage = """
    Usage:
      HDRPlayer <video-file> [--preset natural|hdr|vivid|calibrated-v1|calibrated-v2|calibrated-v3-candidate] [--debug]
      HDRPlayer <video-file> --paper-white 203 --peak 1000
      HDRPlayer --edr-test-pattern [--play-for 5]

    Controls: Space play/pause, Left/Right seek 5s, F fullscreen, Esc exit fullscreen,
    Up/Down volume, Command-Q quit.
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
            case "--preset":
                let value = try valueAfter(argument, arguments: arguments, index: index)
                guard ["natural", "hdr", "vivid", "calibrated-v1", "calibrated-v2", "calibrated-v3-candidate"].contains(value.lowercased()) else {
                    throw HDRPlayerCLIError.unsupportedPreset(value)
                }
                options.preset = value.lowercased()
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
        switch preset {
        case "natural": configuration = .natural
        case "hdr": configuration = .hdr
        case "vivid": configuration = .vivid
        case "calibrated-v1": configuration = .calibratedV1
        case "calibrated-v2": configuration = .calibratedV2
        case "calibrated-v3-candidate": configuration = .calibratedV3Candidate
        default: throw HDRPlayerCLIError.unsupportedPreset(preset)
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
}
