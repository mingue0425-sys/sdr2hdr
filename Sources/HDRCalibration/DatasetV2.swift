import CryptoKit
import Foundation
import Metal

public enum DatasetV2Discovery {
    public static func audit(rootURL: URL) -> V2DatasetAudit {
        let fileManager = FileManager.default
        let groupURLs = (try? fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        var entries: [V2AuditEntry] = []
        for groupURL in groupURLs.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let isDirectory = (try? groupURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            guard isDirectory else { continue }
            let files = (try? fileManager.contentsOfDirectory(at: groupURL, includingPropertiesForKeys: nil)) ?? []
            let sdr = files.first { $0.lastPathComponent.hasSuffix(".f628.mp4") }
            let hdr = files.first { $0.lastPathComponent.hasSuffix(".f642.mp4") }
            var warnings: [String] = []
            let sdrMetadata = sdr.map(FFProbeV2.probe) ?? [:]
            let hdrMetadata = hdr.map(FFProbeV2.probe) ?? [:]
            var status = "PAIR_VALID"
            if sdr == nil { status = "MISSING_SDR"; warnings.append("missing f628 SDR candidate") }
            if hdr == nil { status = "MISSING_HDR"; warnings.append("missing f642 HDR candidate") }
            if let sdrDuration = Double(sdrMetadata["duration"] ?? ""),
               let hdrDuration = Double(hdrMetadata["duration"] ?? ""),
               abs(sdrDuration - hdrDuration) > max(0.5, max(sdrDuration, hdrDuration) * 0.01) {
                status = "DURATION_MISMATCH"
                warnings.append("duration mismatch: \(sdrDuration) vs \(hdrDuration)")
            }
            if !hdrMetadata.isEmpty {
                let transfer = hdrMetadata["color_transfer"] ?? "unknown"
                if transfer != "arib-std-b67" && transfer != "smpte2084" {
                    status = "UNKNOWN_HDR_TRANSFER"
                    warnings.append("unsupported HDR transfer: \(transfer)")
                }
                if !(hdrMetadata["pix_fmt"] ?? "").contains("10") {
                    warnings.append("HDR candidate does not advertise a 10-bit pixel format")
                }
            }
            let pairID = sdr.map { makePairID(group: groupURL.lastPathComponent, filename: $0.lastPathComponent) }
            entries.append(V2AuditEntry(
                group: groupURL.lastPathComponent,
                status: status,
                pairID: pairID,
                sdrPath: sdr?.path,
                hdrPath: hdr?.path,
                sdrMetadata: sdrMetadata,
                hdrMetadata: hdrMetadata,
                warnings: warnings
            ))
        }
        return V2DatasetAudit(
            rootPath: rootURL.path,
            generatedAt: ISO8601DateFormatter().string(from: Date()),
            entries: entries,
            validPairCount: entries.filter { $0.status == "PAIR_VALID" }.count,
            rejectedGroupCount: entries.filter { $0.status != "PAIR_VALID" }.count
        )
    }

    public static func splitDocument(manifest: PairManifest, seed: UInt64) -> V2SplitDocument {
        V2SplitDocument(
            splitSeed: seed,
            algorithm: "video-level deterministic FNV-1a ordering; 60/20/20 allocation",
            tune: manifest.pairs.filter { $0.split == .tune }.map(\.id).sorted(),
            validation: manifest.pairs.filter { $0.split == .validation }.map(\.id).sorted(),
            frozen: manifest.pairs.filter { $0.split == .frozen }.map(\.id).sorted(),
            frozenAccessPolicy: "Frozen decode/evaluation is guarded until selectionFinalized and may execute once."
        )
    }

    private static func makePairID(group: String, filename: String) -> String {
        let identifier = filename.split(separator: "[").last?.split(separator: "]").first.map(String.init) ?? group
        return "\(group)_\(identifier)".lowercased().replacingOccurrences(of: "-", with: "_")
    }
}

public enum ReproducibilityV2 {
    public static func collect(
        manifestURL: URL,
        configuration: V2SearchConfiguration,
        device: MTLDevice?
    ) -> V2Reproducibility {
        V2Reproducibility(
            gitCommit: command(["/usr/bin/git", "rev-parse", "HEAD"], workingDirectory: manifestURL.deletingLastPathComponent()) ?? "NOT_A_GIT_REPOSITORY",
            buildMode: "release calibration executable; offline GPU readback",
            hardware: device?.name ?? "Metal unavailable",
            operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
            swiftVersion: command(["/usr/bin/swift", "--version"]) ?? command(["/usr/bin/xcrun", "swift", "--version"]) ?? "NOT_MEASURED",
            ffmpegVersion: firstLine(command(["/opt/homebrew/bin/ffmpeg", "-version"]) ?? command(["/usr/local/bin/ffmpeg", "-version"])) ?? "NOT_MEASURED",
            datasetManifestSHA256: sha256(url: manifestURL),
            splitSeed: configuration.splitSeed,
            searchSeed: configuration.searchSeed,
            globalCandidates: configuration.globalCandidates,
            localCandidates: configuration.localCandidates,
            bounds: configuration.bounds,
            weights: configuration.weights,
            alignmentThresholds: configuration.alignmentSensitivityThresholds
        )
    }

    public static func sha256(url: URL) -> String {
        guard let data = try? Data(contentsOf: url) else { return "UNAVAILABLE" }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func firstLine(_ value: String?) -> String? {
        value?.split(whereSeparator: \.isNewline).first.map(String.init)
    }

    private static func command(_ arguments: [String], workingDirectory: URL? = nil) -> String? {
        guard let executable = arguments.first,
              FileManager.default.isExecutableFile(atPath: executable) else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = Array(arguments.dropFirst())
        process.currentDirectoryURL = workingDirectory
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()
        do {
            try process.run()
            let data = stdout.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return nil
        }
    }
}

private enum FFProbeV2 {
    static func probe(url: URL) -> [String: String] {
        guard let executable = ["/opt/homebrew/bin/ffprobe", "/usr/local/bin/ffprobe", "/usr/bin/ffprobe"]
            .first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return [:] }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = [
            "-v", "error", "-select_streams", "v:0",
            "-show_entries", "stream=codec_name,width,height,pix_fmt,r_frame_rate,avg_frame_rate,color_space,color_transfer,color_primaries,color_range,bits_per_raw_sample:stream_side_data:format=duration",
            "-of", "json", url.path
        ]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()
        do {
            try process.run()
            let data = stdout.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0,
                  let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let stream = (root["streams"] as? [[String: Any]])?.first else { return [:] }
            var result = stream.reduce(into: [String: String]()) { output, pair in
                if let value = pair.value as? String { output[pair.key] = value }
                else if let value = pair.value as? NSNumber { output[pair.key] = value.stringValue }
            }
            if let format = root["format"] as? [String: Any], let duration = format["duration"] {
                result["duration"] = String(describing: duration)
            }
            let transfer = result["color_transfer"] ?? "unknown"
            result["hdr_type"] = transfer == "arib-std-b67" ? "HLG" : transfer == "smpte2084" ? "PQ" : "unknown"
            result["bit_depth"] = (result["pix_fmt"] ?? "").contains("10") ? "10" : "8"
            return result
        } catch {
            return [:]
        }
    }
}
