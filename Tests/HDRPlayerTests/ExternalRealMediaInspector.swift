import CryptoKit
import Foundation
@testable import HDRPlayerKit

struct ExternalMediaProbe: Codable, Equatable, Sendable {
    let codec: String?
    let profile: String?
    let pixelFormat: String?
    let bitDepth: Int?
    let range: RegressionRange?
    let primaries: String?
    let transfer: String?
    let matrix: String?
    let averageFrameRate: Double?
    let nominalFrameRate: Double?
    let duration: Double?
    let frameCount: Int?
    let width: Int?
    let height: Int?
}

struct ExternalMediaWindowResult: Codable, Sendable {
    let window: ExternalMediaWindow
    let resolvedStart: Double
    let resolvedDuration: Double
    let nearest: RegressionModeResult
    let candidate: RegressionModeResult
    let comparison: RegressionModeComparison
}

struct ExternalMediaAutomaticDecision: Codable, Equatable, Sendable {
    let requested: HDRDecodePrecision
    let resolved: HDRResolvedDecodePrecision
    let sourceBitDepth: Int?
    let sourceCodec: String?
    let reason: HDRDecodePrecisionDecisionReason
    let fallbackUsed: Bool

    init(_ decision: HDRDecodePrecisionDecision) {
        requested = decision.requested
        resolved = decision.resolved
        sourceBitDepth = decision.sourceBitDepth
        sourceCodec = decision.sourceCodec
        reason = decision.reason
        fallbackUsed = decision.fallbackUsed
    }
}

struct ExternalMediaSourceResult: Codable, Sendable {
    let id: String
    let fileName: String
    let sha256: String
    let provenance: ExternalMediaProvenance
    let probe: ExternalMediaProbe
    let automaticDecision: ExternalMediaAutomaticDecision?
    let windows: [ExternalMediaWindowResult]
    let status: String
    let failure: String?
}

struct ExternalRealMediaReport: Codable, Sendable {
    let manifestVersion: Int
    let baseline: String
    let split: ExternalMediaSplit
    let sourceCount: Int
    let failures: Int
    let skipped: Int
    let sources: [ExternalMediaSourceResult]
    let pairs: [ExternalMediaPairResult]
}

struct ExternalMediaPairResult: Codable, Sendable {
    let pairID: String
    let sdrSourceID: String
    let hdrSourceID: String
    let durationDelta: Double?
    let frameCountDelta: Int?
    let frameRateDelta: Double?
    let resolutionMatch: Bool?
    let metadataCompatible: Bool?
    let sceneCorrespondence: String
    let status: String
    let failure: String?
}

enum ExternalMediaInspectionError: Error, LocalizedError, Equatable {
    case missingFile(URL)
    case missingTool(String)
    case hashMismatch(id: String, expected: String, actual: String)
    case invalidProbe(String)
    case expectationMismatch(id: String, details: String)

    var errorDescription: String? {
        switch self {
        case .missingFile(let url): return "external media file does not exist: \(url.path)"
        case .missingTool(let tool): return "required external media tool is unavailable: \(tool)"
        case .hashMismatch(let id, let expected, let actual):
            return "REAL_MEDIA_HASH_MISMATCH id=\(id) expected=\(expected) actual=\(actual)"
        case .invalidProbe(let message): return "invalid ffprobe result: \(message)"
        case .expectationMismatch(let id, let details):
            return "external media metadata mismatch id=\(id): \(details)"
        }
    }
}

struct ExternalMediaInspector {
    static func sha256(fileURL: URL) throws -> String {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw ExternalMediaInspectionError.missingFile(fileURL)
        }
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let data = try handle.read(upToCount: 1024 * 1024) ?? Data()
            if data.isEmpty { break }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func probe(fileURL: URL, countFrames: Bool = true) throws -> ExternalMediaProbe {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw ExternalMediaInspectionError.missingFile(fileURL)
        }
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/env") else {
            throw ExternalMediaInspectionError.missingTool("env")
        }
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        var arguments = ["ffprobe", "-v", "error"]
        if countFrames {
            arguments.append("-count_frames")
        }
        arguments += [
            "-select_streams", "v:0",
            "-show_entries",
            "stream=codec_name,profile,pix_fmt,color_range,color_space,color_transfer,color_primaries,avg_frame_rate,r_frame_rate,bits_per_raw_sample,nb_read_frames,nb_frames,width,height:format=duration",
            "-of", "json", fileURL.path
        ]
        process.arguments = arguments
        process.standardOutput = stdout
        process.standardError = stderr
        do {
            try process.run()
        } catch {
            throw ExternalMediaInspectionError.missingTool("ffprobe")
        }
        process.waitUntilExit()
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        if process.terminationStatus == 127 {
            throw ExternalMediaInspectionError.missingTool("ffprobe")
        }
        guard process.terminationStatus == 0 else {
            let diagnostic = String(
                data: stderr.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? "ffprobe failed"
            throw ExternalMediaInspectionError.invalidProbe(diagnostic)
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let stream = (object["streams"] as? [[String: Any]])?.first else {
            throw ExternalMediaInspectionError.invalidProbe("video stream is missing")
        }
        let format = object["format"] as? [String: Any]
        let pixelFormat = stream["pix_fmt"] as? String
        let bitDepth = bitDepth(pixelFormat: pixelFormat, rawBits: stream["bits_per_raw_sample"] as? String)
        return ExternalMediaProbe(
            codec: stream["codec_name"] as? String,
            profile: stream["profile"] as? String,
            pixelFormat: pixelFormat,
            bitDepth: bitDepth,
            range: range(from: stream["color_range"] as? String),
            primaries: stream["color_primaries"] as? String,
            transfer: stream["color_transfer"] as? String,
            matrix: stream["color_space"] as? String,
            averageFrameRate: parseRate(stream["avg_frame_rate"] as? String),
            nominalFrameRate: parseRate(stream["r_frame_rate"] as? String),
            duration: Double(format?["duration"] as? String ?? ""),
            frameCount: Int(stream["nb_read_frames"] as? String ?? stream["nb_frames"] as? String ?? ""),
            width: stream["width"] as? Int,
            height: stream["height"] as? Int
        )
    }

    static func validate(source: ExternalRealMediaSource, fileURL: URL) throws -> ExternalMediaProbe {
        let actualHash = try sha256(fileURL: fileURL)
        guard actualHash.caseInsensitiveCompare(source.sha256) == .orderedSame else {
            throw ExternalMediaInspectionError.hashMismatch(
                id: source.id,
                expected: source.sha256,
                actual: actualHash
            )
        }
        // External windows already verify decoded frame count through the
        // shared AVFoundation runner. Avoid a second full-file ffprobe frame
        // scan for large corpus sources; retain container nb_frames when it is
        // available and leave it nil when the container does not provide one.
        let probe = try probe(fileURL: fileURL, countFrames: false)
        try validate(source: source, probe: probe)
        return probe
    }

    static func validate(source: ExternalRealMediaSource, probe: ExternalMediaProbe) throws {
        let expected = source.expected
        var mismatches: [String] = []
        if let value = expected.codec, probe.codec != value.rawValue { mismatches.append("codec") }
        if let value = expected.profile, probe.profile != value { mismatches.append("profile") }
        if let value = expected.bitDepth, probe.bitDepth != value { mismatches.append("bitDepth") }
        if let value = expected.range, probe.range != value { mismatches.append("range") }
        if let value = expected.primaries, probe.primaries != value { mismatches.append("primaries") }
        if let value = expected.transfer, probe.transfer != value { mismatches.append("transfer") }
        if let value = expected.matrix, probe.matrix != value { mismatches.append("matrix") }
        if let value = expected.frameRate {
            guard let actual = probe.averageFrameRate else {
                mismatches.append("frameRate")
                throw ExternalMediaInspectionError.expectationMismatch(
                    id: source.id,
                    details: mismatches.joined(separator: ",")
                )
            }
            if abs(actual - value) > 0.01 { mismatches.append("frameRate") }
        }
        if !mismatches.isEmpty {
            throw ExternalMediaInspectionError.expectationMismatch(
                id: source.id,
                details: mismatches.joined(separator: ",")
            )
        }
    }

    static func diagnosePair(
        pair: MatchedMediaPair,
        sdr: ExternalMediaProbe,
        hdr: ExternalMediaProbe
    ) -> ExternalMediaPairResult {
        let durationDelta: Double?
        if let sdrDuration = sdr.duration, let hdrDuration = hdr.duration {
            durationDelta = abs(sdrDuration - hdrDuration)
        } else {
            durationDelta = nil
        }
        let frameCountDelta: Int?
        if let sdrFrameCount = sdr.frameCount, let hdrFrameCount = hdr.frameCount {
            frameCountDelta = abs(sdrFrameCount - hdrFrameCount)
        } else {
            frameCountDelta = nil
        }
        let frameRateDelta: Double?
        if let sdrRate = sdr.averageFrameRate, let hdrRate = hdr.averageFrameRate {
            frameRateDelta = abs(sdrRate - hdrRate)
        } else {
            frameRateDelta = nil
        }
        let resolutionMatch: Bool?
        if let sdrWidth = sdr.width, let hdrWidth = hdr.width,
           let sdrHeight = sdr.height, let hdrHeight = hdr.height {
            resolutionMatch = sdrWidth == hdrWidth && sdrHeight == hdrHeight
        } else {
            resolutionMatch = nil
        }
        let metadataCompatible: Bool?
        if let sdrRange = sdr.range, let hdrRange = hdr.range,
           let sdrPrimaries = sdr.primaries, let hdrPrimaries = hdr.primaries,
           let sdrTransfer = sdr.transfer, let hdrTransfer = hdr.transfer,
           let sdrMatrix = sdr.matrix, let hdrMatrix = hdr.matrix {
            metadataCompatible = sdrRange == hdrRange &&
                sdrPrimaries == hdrPrimaries &&
                sdrTransfer == hdrTransfer &&
                sdrMatrix == hdrMatrix
        } else {
            metadataCompatible = nil
        }
        let hardFailure = resolutionMatch == false ||
            (durationDelta.map { $0 > 0.25 } ?? false) ||
            (frameRateDelta.map { $0 > 0.01 } ?? false)
        return ExternalMediaPairResult(
            pairID: pair.pairID,
            sdrSourceID: pair.sdrSourceID,
            hdrSourceID: pair.hdrSourceID,
            durationDelta: durationDelta,
            frameCountDelta: frameCountDelta,
            frameRateDelta: frameRateDelta,
            resolutionMatch: resolutionMatch,
            metadataCompatible: metadataCompatible,
            sceneCorrespondence: "not-evaluated; coarse timestamp/metadata viability only",
            status: hardFailure ? "fail" : "diagnostic",
            failure: hardFailure ? "pair timing or resolution is not aligned" : nil
        )
    }

    private static func bitDepth(pixelFormat: String?, rawBits: String?) -> Int? {
        if let rawBits, let value = Int(rawBits) { return value }
        guard let pixelFormat else { return nil }
        if pixelFormat.contains("10") || pixelFormat.contains("p010") { return 10 }
        if pixelFormat.contains("8") || pixelFormat.contains("420") { return 8 }
        return nil
    }

    private static func range(from value: String?) -> RegressionRange? {
        switch value {
        case "tv": return .video
        case "pc": return .full
        default: return nil
        }
    }

    private static func parseRate(_ value: String?) -> Double? {
        guard let value, let separator = value.firstIndex(of: "/") else {
            return Double(value ?? "")
        }
        let numerator = Double(value[..<separator]) ?? 0
        let denominator = Double(value[value.index(after: separator)...]) ?? 0
        guard denominator != 0 else { return nil }
        return numerator / denominator
    }
}
