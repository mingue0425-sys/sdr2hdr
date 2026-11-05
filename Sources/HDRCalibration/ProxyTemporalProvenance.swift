import Foundation

/// Per-sequence record of where each decoded proxy frame came from in the
/// original source timeline. Readers may decimate, but must never duplicate a
/// frame or replace source presentation times with a synthesized grid.
public struct FrameTemporalProvenance: Equatable, Codable, Sendable {
    /// FFmpeg proxy: `-copyts`, optional slot-based `select` decimation,
    /// `showinfo` source PTS, and an ffprobe packet table for ordinals.
    public static let ffmpegSourcePTSPolicy = "ffmpeg-proxy-copyts-slot-select-source-pts-v1"
    /// AVAssetReader: presentation-order stride sampling with sample-buffer PTS.
    public static let avAssetReaderPolicy = "avassetreader-presentation-order-stride-v1"

    public let policy: String
    /// Source presentation time of each sample, relative to the stream start.
    public let sourceTimestampsSeconds: [Double]
    /// Presentation-order ordinal of each sample in the source stream.
    public let sourceFrameIndices: [Int]
    /// Source frames skipped between this sample and the previous one. The
    /// first sample reports zero; a window start is not a drop.
    public let skippedSourceFramesBefore: [Int]
    /// Always zero for accepted sequences; duplicates fail closed.
    public let duplicatedFrameCount: Int
    /// `nil` when the reader cannot observe the full source timeline.
    public let sourceIsVariableFrameRate: Bool?

    public init(
        policy: String,
        sourceTimestampsSeconds: [Double],
        sourceFrameIndices: [Int],
        skippedSourceFramesBefore: [Int],
        duplicatedFrameCount: Int = 0,
        sourceIsVariableFrameRate: Bool?
    ) {
        self.policy = policy
        self.sourceTimestampsSeconds = sourceTimestampsSeconds
        self.sourceFrameIndices = sourceFrameIndices
        self.skippedSourceFramesBefore = skippedSourceFramesBefore
        self.duplicatedFrameCount = duplicatedFrameCount
        self.sourceIsVariableFrameRate = sourceIsVariableFrameRate
    }

    /// Builds provenance from strictly increasing source ordinals.
    static func make(
        policy: String,
        timestamps: [Double],
        indices: [Int],
        isVariableFrameRate: Bool?
    ) throws -> FrameTemporalProvenance {
        guard timestamps.count == indices.count, !indices.isEmpty else {
            throw CalibrationError.decodeFailed("proxy temporal provenance is empty or inconsistent")
        }
        var skipped: [Int] = [0]
        for (previous, current) in zip(indices, indices.dropFirst()) {
            guard current > previous else {
                throw CalibrationError.decodeFailed(
                    "proxy produced a duplicated or non-monotone source frame (\(previous) -> \(current))"
                )
            }
            skipped.append(current - previous - 1)
        }
        for (previous, current) in zip(timestamps, timestamps.dropFirst()) where !(current > previous) {
            throw CalibrationError.decodeFailed("proxy source timestamps are not strictly increasing")
        }
        return FrameTemporalProvenance(
            policy: policy,
            sourceTimestampsSeconds: timestamps,
            sourceFrameIndices: indices,
            skippedSourceFramesBefore: skipped,
            sourceIsVariableFrameRate: isVariableFrameRate
        )
    }
}

/// One frame line from FFmpeg's `showinfo` filter.
struct FFmpegShowinfoFrame: Equatable {
    let ordinal: Int
    let pts: Int64
    let seconds: Double
}

/// Parses `showinfo` output using the integer PTS and the filter time base.
/// The printed `pts_time` is rounded to six significant digits and is never
/// used as a timestamp.
enum FFmpegShowinfoParser {
    static func parse(_ log: String) throws -> [FFmpegShowinfoFrame] {
        var timeBase: (num: Int64, den: Int64)?
        var frames: [FFmpegShowinfoFrame] = []
        for line in log.split(whereSeparator: \.isNewline) {
            guard line.contains("Parsed_showinfo_") else { continue }
            if let range = line.range(of: "config in time_base: ") {
                let fields = line[range.upperBound...].prefix { $0 != "," }.split(separator: "/")
                guard fields.count == 2,
                      let num = Int64(fields[0]), let den = Int64(fields[1]),
                      num > 0, den > 0 else {
                    throw CalibrationError.decodeFailed("ffmpeg showinfo reported an invalid time base")
                }
                timeBase = (num, den)
                continue
            }
            guard let ordinal = integer(after: " n:", in: line),
                  let pts = integer(after: " pts:", in: line) else { continue }
            guard let timeBase else {
                throw CalibrationError.decodeFailed("ffmpeg showinfo frame precedes its time base")
            }
            guard ordinal == Int64(frames.count) else {
                throw CalibrationError.decodeFailed("ffmpeg showinfo frame ordinals are not consecutive")
            }
            frames.append(FFmpegShowinfoFrame(
                ordinal: Int(ordinal),
                pts: pts,
                seconds: Double(pts) * Double(timeBase.num) / Double(timeBase.den)
            ))
        }
        return frames
    }

    private static func integer(after token: String, in line: Substring) -> Int64? {
        guard let range = line.range(of: token) else { return nil }
        let rest = line[range.upperBound...].drop { $0 == " " }
        let digits = rest.prefix { $0 == "-" || $0.isNumber }
        return Int64(digits)
    }
}

/// Presentation-ordered packet times of the source video stream. Mapping a
/// decoded frame back to this table yields its true source ordinal; a frame
/// time that is not in the table (for example a synthesized duplicate) fails.
struct SourcePresentationTable {
    let presentationSeconds: [Double]
    let streamStartSeconds: Double
    let tolerance: Double

    init(presentationSeconds unsorted: [Double], streamStartSeconds: Double) throws {
        let finite = unsorted.filter(\.isFinite)
        guard finite.count == unsorted.count, streamStartSeconds.isFinite else {
            throw CalibrationError.decodeFailed("source packet table contains non-finite timestamps")
        }
        let sorted = finite.sorted()
        let firstGap = zip(sorted.dropFirst(), sorted).map { $0 - $1 }.filter { $0 > 0 }.min() ?? 1
        // Edit-list pre-roll packets precede the stream start and are never
        // presented; they are not part of the source timeline.
        let presented = sorted.filter { $0 >= streamStartSeconds - firstGap * 0.25 }
        guard !presented.isEmpty, presented.count <= 50_000_000 else {
            throw CalibrationError.decodeFailed("source packet table is empty or exceeds safe bounds")
        }
        let gaps = zip(presented.dropFirst(), presented).map { $0 - $1 }
        guard gaps.allSatisfy({ $0 > 0 }) else {
            throw CalibrationError.decodeFailed("source packet table contains duplicate presentation times")
        }
        self.presentationSeconds = presented
        self.streamStartSeconds = streamStartSeconds
        self.tolerance = min((gaps.min() ?? 1) * 0.25, 0.001)
    }

    var frameCount: Int { presentationSeconds.count }

    /// True when presented frame durations differ by more than 1%.
    var isVariableFrameRate: Bool {
        let gaps = zip(presentationSeconds.dropFirst(), presentationSeconds).map { $0 - $1 }
        guard let minimum = gaps.min(), let maximum = gaps.max(), minimum > 0 else { return false }
        return maximum / minimum > 1.01
    }

    func sourceIndex(forSeconds seconds: Double) -> Int? {
        var low = 0
        var high = presentationSeconds.count
        while low < high {
            let middle = (low + high) / 2
            if presentationSeconds[middle] < seconds { low = middle + 1 } else { high = middle }
        }
        let candidates = [low - 1, low].filter { presentationSeconds.indices.contains($0) }
        guard let best = candidates.min(by: {
            abs(presentationSeconds[$0] - seconds) < abs(presentationSeconds[$1] - seconds)
        }), abs(presentationSeconds[best] - seconds) <= tolerance else { return nil }
        return best
    }

    func provenance(forFrameSeconds frameSeconds: [Double], policy: String) throws -> FrameTemporalProvenance {
        let indices = try frameSeconds.map { seconds -> Int in
            guard let index = sourceIndex(forSeconds: seconds) else {
                throw CalibrationError.decodeFailed(
                    "proxy frame at \(seconds)s does not correspond to a source frame"
                )
            }
            return index
        }
        return try FrameTemporalProvenance.make(
            policy: policy,
            timestamps: frameSeconds.map { $0 - streamStartSeconds },
            indices: indices,
            isVariableFrameRate: isVariableFrameRate
        )
    }
}

/// Frame selection for the FFmpeg proxy. At or above the native rate every
/// source frame passes. Below it, the first frame of each 1/fps slot measured
/// from the first decoded frame passes; empty slots (VFR gaps) stay empty.
enum FFmpegProxySelection {
    static func filter(requestedFPS: Double, nominalFrameRate: Double) -> String? {
        if nominalFrameRate > 0, requestedFPS >= nominalFrameRate * 0.999 {
            return nil
        }
        let fps = String(format: "%.6f", requestedFPS)
        return "select='isnan(prev_selected_t)+gt(floor((t-start_t)*\(fps)+1e-6)\\," +
            "floor((prev_selected_t-start_t)*\(fps)+1e-6))'"
    }
}

/// Reads the source video stream's packet presentation times with ffprobe.
/// This demuxes only; no frame is decoded.
enum FFmpegPacketTableProbe {
    static func probe(ffprobe: String, url: URL) throws -> SourcePresentationTable {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffprobe)
        process.arguments = [
            "-v", "error", "-select_streams", "v:0",
            "-show_entries", "stream=time_base,start_time:packet=pts",
            "-of", "json", url.path
        ]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle(forWritingAtPath: "/dev/null")
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw CalibrationError.decodeFailed("ffprobe could not read the packet table of \(url.lastPathComponent)")
        }
        return try parse(data, name: url.lastPathComponent)
    }

    static func parse(_ data: Data, name: String) throws -> SourcePresentationTable {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let stream = (root["streams"] as? [[String: Any]])?.first,
              let timeBase = stream["time_base"] as? String,
              let packets = root["packets"] as? [[String: Any]] else {
            throw CalibrationError.decodeFailed("ffprobe packet table is malformed for \(name)")
        }
        let fields = timeBase.split(separator: "/")
        guard fields.count == 2,
              let num = Double(fields[0]), let den = Double(fields[1]),
              num > 0, den > 0 else {
            throw CalibrationError.decodeFailed("ffprobe reported an invalid time base for \(name)")
        }
        let seconds = try packets.map { packet -> Double in
            guard let pts = (packet["pts"] as? NSNumber)?.int64Value else {
                // Without packet PTS the source timeline cannot be proven.
                throw CalibrationError.decodeFailed("source packet without PTS in \(name)")
            }
            return Double(pts) * num / den
        }
        let start = (stream["start_time"] as? String).flatMap(Double.init) ?? (seconds.min() ?? 0)
        return try SourcePresentationTable(presentationSeconds: seconds, streamStartSeconds: start)
    }
}

/// Drains a pipe on a background queue so the writer never blocks.
final class PipeCollector: @unchecked Sendable {
    private let lock = NSLock()
    private let done = DispatchSemaphore(value: 0)
    private var data = Data()

    init(_ handle: FileHandle) {
        DispatchQueue.global(qos: .utility).async { [self] in
            let all = handle.readDataToEndOfFile()
            lock.lock()
            data = all
            lock.unlock()
            done.signal()
        }
    }

    func finish() -> Data {
        done.wait()
        lock.lock()
        defer { lock.unlock() }
        return data
    }
}
