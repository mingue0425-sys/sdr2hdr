import AVFoundation
import CryptoKit
import Darwin
import Foundation

/// Makes an input AVFoundation can decode, converting it once if needed.
///
/// YouTube serves VP9 and AV1. AVFoundation cannot decode VP9 here, and AV1 may
/// fail too. Such an input is converted once with VideoToolbox HEVC into
/// `cacheDirectory`; colour tags are kept, and 10-bit sources stay 10-bit
/// (Main10, P010) so HDR renditions keep their precision. The converted file
/// is reused while the source's path, size and modification time are unchanged.
public struct PlayableInputConverter: Sendable {
    public let cacheDirectory: URL
    public let ffmpeg: String
    public let ffprobe: String

    public init?(cacheDirectory: URL) {
        guard let directory = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"].first(where: {
            FileManager.default.isExecutableFile(atPath: $0 + "/ffmpeg") &&
                FileManager.default.isExecutableFile(atPath: $0 + "/ffprobe")
        }) else { return nil }
        self.cacheDirectory = cacheDirectory
        self.ffmpeg = directory + "/ffmpeg"
        self.ffprobe = directory + "/ffprobe"
    }

    /// `<directory of the executable>/../converted`, so a checkout's
    /// `.build/release/HDRPlayer` writes to `.build/converted`.
    public static func defaultCacheDirectory(executable: URL? = Bundle.main.executableURL) -> URL {
        let base = executable?.resolvingSymlinksInPath().deletingLastPathComponent()
            ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        return base.deletingLastPathComponent().appendingPathComponent("converted", isDirectory: true)
    }

    public enum Outcome: Equatable, Sendable {
        case decodable
        case reused(URL)
        case converted(URL)

        public var url: URL? {
            switch self {
            case .decodable: return nil
            case .reused(let url), .converted(let url): return url
            }
        }
    }

    /// Returns `.decodable` for inputs AVFoundation can decode, otherwise the
    /// converted file. `progress` receives a fraction in 0...1.
    public func prepare(_ url: URL, progress: @Sendable (Double) -> Void = { _ in }) async throws -> Outcome {
        guard try await Self.isDecodable(url) == false else { return .decodable }
        let output = try convertedURL(for: url)
        if FileManager.default.fileExists(atPath: output.path), try await Self.isDecodable(output) == true {
            return .reused(output)
        }
        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        let partial = cacheDirectory.appendingPathComponent(".\(output.lastPathComponent).\(UUID().uuidString).partial.mov")
        defer { try? FileManager.default.removeItem(at: partial) }
        let duration = probeDuration(url)
        try run(arguments(input: url, output: partial, tenBit: isTenBit(url)), duration: duration, progress: progress)
        guard try await Self.isDecodable(partial) == true else {
            throw PlayableInputError.conversionFailed("the converted file is still not decodable")
        }
        guard rename(partial.path, output.path) == 0 else {
            throw PlayableInputError.conversionFailed("could not move the converted file into \(cacheDirectory.path)")
        }
        return .converted(output)
    }

    /// Blocking form for the command-line entry point, before the app runs.
    /// Prints progress to stderr and returns the URL to play.
    public func prepareForPlayback(_ url: URL) throws -> URL {
        let box = ResultBox()
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached { [self] in
            do {
                let lastPercent = PercentPrinter(name: url.lastPathComponent)
                box.result = .success(try await prepare(url) { lastPercent.update($0) })
            } catch {
                box.result = .failure(error)
            }
            semaphore.signal()
        }
        semaphore.wait()
        let outcome = try box.result!.get()
        switch outcome {
        case .decodable:
            return url
        case .reused(let converted):
            fputs("HDRPlayer: using the converted copy \(converted.path)\n", stderr)
            return converted
        case .converted(let converted):
            fputs("\nHDRPlayer: converted to \(converted.path)\n", stderr)
            return converted
        }
    }

    /// False when AVFoundation cannot open the container (WebM, the yt-dlp
    /// default) or cannot decode its video; nil when it opens a file without
    /// video.
    static func isDecodable(_ url: URL) async throws -> Bool? {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw PlayableInputError.conversionFailed("no such file: \(url.path)")
        }
        do {
            guard let track = try await AVURLAsset(url: url).loadTracks(withMediaType: .video).first else { return nil }
            return try await track.load(.isDecodable)
        } catch {
            return false
        }
    }

    func convertedURL(for url: URL) throws -> URL {
        var info = stat()
        guard stat(url.path, &info) == 0 else { throw PlayableInputError.conversionFailed("cannot read \(url.path)") }
        let identity = "\(url.standardizedFileURL.path)|\(info.st_size)|\(info.st_mtimespec.tv_sec).\(info.st_mtimespec.tv_nsec)"
        let key = SHA256.hash(data: Data(identity.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
        return cacheDirectory.appendingPathComponent("\(url.deletingPathExtension().lastPathComponent)-\(key)-hevc.mov")
    }

    func arguments(input: URL, output: URL, tenBit: Bool) -> [String] {
        ["-hide_banner", "-nostdin", "-loglevel", "error", "-nostats", "-progress", "pipe:1", "-y",
         "-i", input.path, "-map", "0:v:0", "-map", "0:a?",
         "-c:v", "hevc_videotoolbox", "-q:v", "75", "-tag:v", "hvc1"]
            + (tenBit ? ["-profile:v", "main10", "-pix_fmt", "p010le"] : [])
            + ["-c:a", "aac", output.path]
    }

    func probeDuration(_ url: URL) -> Double {
        Double(probe(url, ["-show_entries", "format=duration"]).trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }

    func isTenBit(_ url: URL) -> Bool {
        let format = probe(url, ["-select_streams", "v:0", "-show_entries", "stream=pix_fmt"])
        return format.contains("10le") || format.contains("10be") || format.contains("p010")
    }

    private func probe(_ url: URL, _ entries: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffprobe)
        process.arguments = ["-v", "error"] + entries + ["-of", "csv=p=0", url.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return "" }
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        return output
    }

    private func run(_ arguments: [String], duration: Double, progress: (Double) -> Void) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpeg)
        process.arguments = arguments
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        let errorText = ErrorCollector(errors.fileHandleForReading)
        try process.run()
        // -progress writes key=value lines; out_time_us is the position written.
        var pending = Data()
        while let chunk = try output.fileHandleForReading.read(upToCount: 4096), !chunk.isEmpty {
            pending.append(chunk)
            while let newline = pending.firstIndex(of: 0x0A) {
                let line = String(decoding: pending[pending.startIndex..<newline], as: UTF8.self)
                pending.removeSubrange(pending.startIndex...newline)
                if line.hasPrefix("out_time_us="), duration > 0, let micros = Double(line.dropFirst(12)) {
                    progress(min(max(micros / 1e6 / duration, 0), 1))
                }
            }
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let tail = errorText.finish().split(separator: "\n").suffix(3).joined(separator: " / ")
            throw PlayableInputError.conversionFailed("ffmpeg exited with \(process.terminationStatus): \(tail)")
        }
        progress(1)
    }
}

public enum PlayableInputError: Error, LocalizedError, Equatable {
    case conversionFailed(String)

    public var errorDescription: String? {
        switch self {
        case .conversionFailed(let reason): return "could not convert the input for AVFoundation: \(reason)"
        }
    }
}

/// Drains a pipe in the background so ffmpeg never blocks on stderr.
private final class ErrorCollector: @unchecked Sendable {
    private var data = Data()
    private let done = DispatchSemaphore(value: 0)

    init(_ handle: FileHandle) {
        DispatchQueue.global(qos: .utility).async { [self] in
            data = handle.readDataToEndOfFile()
            done.signal()
        }
    }

    func finish() -> String {
        done.wait()
        return String(decoding: data, as: UTF8.self)
    }
}

private final class ResultBox: @unchecked Sendable {
    var result: Result<PlayableInputConverter.Outcome, Error>?
}

/// Prints whole-percent progress on one terminal line.
private final class PercentPrinter: @unchecked Sendable {
    private let name: String
    private let lock = NSLock()
    private var last = -1

    init(name: String) { self.name = name }

    func update(_ fraction: Double) {
        let percent = Int(fraction * 100)
        lock.lock()
        defer { lock.unlock() }
        guard percent != last else { return }
        last = percent
        fputs("\rHDRPlayer: AVFoundation cannot decode \(name); converting to HEVC once... \(percent)%", stderr)
    }
}
