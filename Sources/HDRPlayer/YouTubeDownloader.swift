import Foundation

/// YouTube links: recognising them and the `hdrplayer://` hand-off.
public enum YouTubeLink {
    /// The 11-character video ID of a youtube.com / youtu.be link, or nil.
    /// Accepts watch?v=, shorts/, live/, embed/ and youtu.be/ forms, with or
    /// without a scheme, on www., m. and music. hosts.
    public static func videoID(from text: String) -> String? {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.contains("://") { trimmed = "https://" + trimmed }
        guard let components = URLComponents(string: trimmed),
              let host = components.host?.lowercased() else { return nil }
        let path = components.path.split(separator: "/").map(String.init)
        var candidate: String?
        if host == "youtu.be" {
            candidate = path.first
        } else if host == "youtube.com" || host.hasSuffix(".youtube.com") || host == "youtube-nocookie.com"
                    || host.hasSuffix(".youtube-nocookie.com") {
            if path.first == "watch" {
                candidate = components.queryItems?.first(where: { $0.name == "v" })?.value
            } else if let first = path.first, ["shorts", "live", "embed", "v"].contains(first), path.count > 1 {
                candidate = path[1]
            }
        }
        guard let id = candidate, isVideoID(id) else { return nil }
        return id
    }

    public static func videoID(from url: URL) -> String? {
        guard url.scheme == "http" || url.scheme == "https" else { return nil }
        return videoID(from: url.absoluteString)
    }

    static func isVideoID(_ id: String) -> Bool {
        id.count == 11 && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }

    /// `hdrplayer://open?url=<link>` (Safari button, `open` command) → the link.
    public static func handoffTarget(_ url: URL) -> URL? {
        guard url.scheme?.lowercased() == "hdrplayer",
              let value = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "url" })?.value,
              let target = URL(string: value) else { return nil }
        return target
    }

    /// The Safari bookmarklet: sends the current tab's address to HDRPlayer.
    public static let bookmarklet =
        "javascript:location.href='hdrplayer://open?url='+encodeURIComponent(location.href)"
}

/// Downloads a YouTube video once, in a form AVFoundation decodes directly.
///
/// yt-dlp (already on this Mac, never installed by this tool) fetches H.264
/// video up to 1080p with AAC audio and merges them into MP4; when a video has
/// no H.264 rendition, the best one up to 1080p is taken and
/// `PlayableInputConverter` converts it afterwards. Browser cookies are
/// never read. Files go to `cacheDirectory` as `<id>.mp4` with the title in
/// `<id>.title.txt`, and a finished download is reused.
public struct YouTubeDownloader: Sendable {
    public let cacheDirectory: URL
    public let ytDLP: String
    public let ffmpegDirectory: String

    public struct Download: Equatable, Sendable {
        public let url: URL
        public let title: String
    }

    public init?(cacheDirectory: URL) {
        let directories = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]
        guard let ytDLP = directories.map({ $0 + "/yt-dlp" }).first(where: FileManager.default.isExecutableFile(atPath:)),
              let ffmpegDirectory = directories.first(where: { FileManager.default.isExecutableFile(atPath: $0 + "/ffmpeg") })
        else { return nil }
        self.cacheDirectory = cacheDirectory
        self.ytDLP = ytDLP
        self.ffmpegDirectory = ffmpegDirectory
    }

    /// `youtube` next to the converted-file cache (`.build/youtube` in a checkout).
    public static func defaultCacheDirectory(executable: URL? = Bundle.main.executableURL) -> URL {
        let converted = PlayableInputConverter.defaultCacheDirectory(executable: executable)
        let name = converted.lastPathComponent == "converted" ? "youtube" : "HDRPlayer-youtube"
        return converted.deletingLastPathComponent().appendingPathComponent(name, isDirectory: true)
    }

    public static let formatSelector =
        "bv*[vcodec^=avc1][height<=1080]+ba[ext=m4a]/b[vcodec^=avc1][height<=1080]/bv*[height<=1080]+ba/b[height<=1080]/b"

    public func cachedDownload(id: String) -> Download? {
        let video = cacheDirectory.appendingPathComponent("\(id).mp4")
        guard FileManager.default.fileExists(atPath: video.path) else { return nil }
        let title = (try? String(contentsOf: cacheDirectory.appendingPathComponent("\(id).title.txt"), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Download(url: video, title: title?.isEmpty == false ? title! : id)
    }

    func arguments(id: String, workDirectory: URL) -> [String] {
        ["--no-playlist", "--newline", "--color", "never", "--no-cookies", "--no-cookies-from-browser",
         "--ffmpeg-location", ffmpegDirectory,
         "-f", Self.formatSelector, "--merge-output-format", "mp4",
         "-o", workDirectory.appendingPathComponent("%(id)s.%(ext)s").path,
         "--print-to-file", "%(title)s", workDirectory.appendingPathComponent("%(id)s.title.txt").path,
         "--progress-template", "download:HDRPROGRESS %(progress._percent_str)s %(info.format_id)s",
         "--", "https://www.youtube.com/watch?v=\(id)"]
    }

    /// Downloads (or reuses) the video. `progress` gets 0...1: the first
    /// stream (video) fills 90%, a second (audio) the rest.
    public func download(id: String, progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> Download {
        guard YouTubeLink.isVideoID(id) else { throw YouTubeDownloadError.invalidLink(id) }
        if let cached = cachedDownload(id: id) { return cached }
        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        let work = cacheDirectory.appendingPathComponent(".partial-\(id)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: ytDLP)
        process.arguments = arguments(id: id, workDirectory: work)
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = [ffmpegDirectory, "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"].joined(separator: ":")
        process.environment = environment
        let output = Pipe(), errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        let errorText = PipeDrain(errors.fileHandleForReading)
        try process.run()
        let tracker = DownloadProgressTracker()
        try await withTaskCancellationHandler {
            try await Task.detached(priority: .userInitiated) {
                var pending = Data()
                while let chunk = try output.fileHandleForReading.read(upToCount: 4096), !chunk.isEmpty {
                    pending.append(chunk)
                    while let newline = pending.firstIndex(of: 0x0A) {
                        let line = String(decoding: pending[pending.startIndex..<newline], as: UTF8.self)
                        pending.removeSubrange(pending.startIndex...newline)
                        if let fraction = tracker.consume(line) { progress(fraction) }
                    }
                }
                process.waitUntilExit()
            }.value
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
        try Task.checkCancellation()
        guard process.terminationStatus == 0 else {
            throw YouTubeDownloadError.from(stderr: errorText.finish(), status: process.terminationStatus)
        }
        let downloaded = work.appendingPathComponent("\(id).mp4")
        guard FileManager.default.fileExists(atPath: downloaded.path) else {
            throw YouTubeDownloadError.failed("yt-dlp finished without \(id).mp4")
        }
        let titleFile = work.appendingPathComponent("\(id).title.txt")
        let finalTitle = cacheDirectory.appendingPathComponent("\(id).title.txt")
        try? FileManager.default.removeItem(at: finalTitle)
        if FileManager.default.fileExists(atPath: titleFile.path) {
            try FileManager.default.moveItem(at: titleFile, to: finalTitle)
        }
        // The video moves last: its presence marks a complete download.
        try FileManager.default.moveItem(at: downloaded, to: cacheDirectory.appendingPathComponent("\(id).mp4"))
        progress(1)
        guard let result = cachedDownload(id: id) else { throw YouTubeDownloadError.failed("download vanished") }
        return result
    }

    /// Blocking form for the command-line player; prints progress.
    public func downloadForPlayback(id: String) throws -> Download {
        let box = DownloadResultBox()
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached { [self] in
            do {
                box.result = .success(try await download(id: id) { fraction in
                    fputs("\rHDRPlayer: downloading YouTube \(id)... \(Int(fraction * 100))%", stderr)
                })
            } catch {
                box.result = .failure(error)
            }
            semaphore.signal()
        }
        semaphore.wait()
        fputs("\n", stderr)
        return try box.result!.get()
    }
}

public enum YouTubeDownloadError: Error, LocalizedError, Equatable {
    case invalidLink(String)
    case unavailable
    case botCheck
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidLink(let text): return "유튜브 영상 링크가 아닙니다: \(text)"
        case .unavailable: return "이 영상은 볼 수 없습니다(비공개, 삭제 또는 지역·연령 제한)."
        case .botCheck: return "유튜브가 자동 접속 확인을 요구했습니다. 잠시 뒤 다시 시도해 주세요. 브라우저 쿠키는 쓰지 않습니다."
        case .failed(let reason): return "유튜브 영상을 받지 못했습니다: \(reason)"
        }
    }

    static func from(stderr: String, status: Int32) -> YouTubeDownloadError {
        let lowered = stderr.lowercased()
        if lowered.contains("sign in to confirm") || lowered.contains("not a bot") { return .botCheck }
        if lowered.contains("video unavailable") || lowered.contains("private video")
            || lowered.contains("sign in to confirm your age") || lowered.contains("not available in your country") {
            return .unavailable
        }
        let tail = stderr.split(separator: "\n").filter { $0.contains("ERROR") }.suffix(2).joined(separator: " / ")
        return .failed(tail.isEmpty ? "yt-dlp exited with \(status)" : tail)
    }
}

/// Maps yt-dlp's `HDRPROGRESS <percent> <format>` lines to overall progress.
final class DownloadProgressTracker: @unchecked Sendable {
    private var formats: [String] = []

    func consume(_ line: String) -> Double? {
        guard line.hasPrefix("HDRPROGRESS") else { return nil }
        let fields = line.split(separator: " ")
        guard fields.count >= 3, let percent = Double(fields[1].replacingOccurrences(of: "%", with: "")) else { return nil }
        let format = String(fields[2])
        if !formats.contains(format) { formats.append(format) }
        let fraction = min(max(percent / 100, 0), 1)
        return formats.firstIndex(of: format) == 0 ? fraction * 0.9 : 0.9 + fraction * 0.1
    }
}

private final class PipeDrain: @unchecked Sendable {
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

private final class DownloadResultBox: @unchecked Sendable {
    var result: Result<YouTubeDownloader.Download, Error>?
}
