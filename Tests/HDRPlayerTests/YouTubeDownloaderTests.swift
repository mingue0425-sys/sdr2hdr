import Foundation
import XCTest
@testable import HDRPlayerKit

final class YouTubeDownloaderTests: XCTestCase {
    func testVideoIDsAreRecognizedInEveryLinkForm() {
        let id = "jNQXAC9IVRw"
        for link in [
            "https://www.youtube.com/watch?v=\(id)",
            "https://www.youtube.com/watch?v=\(id)&t=42s&list=PL123",
            "https://youtube.com/watch?feature=share&v=\(id)",
            "https://m.youtube.com/watch?v=\(id)",
            "https://music.youtube.com/watch?v=\(id)",
            "https://youtu.be/\(id)?si=abc",
            "https://www.youtube.com/shorts/\(id)",
            "https://www.youtube.com/live/\(id)",
            "https://www.youtube.com/embed/\(id)",
            "https://www.youtube-nocookie.com/embed/\(id)",
            "youtu.be/\(id)",
            "  www.youtube.com/watch?v=\(id)\n"
        ] {
            XCTAssertEqual(YouTubeLink.videoID(from: link), id, link)
        }
        for link in [
            "https://www.youtube.com/", "https://www.youtube.com/watch?v=short", "https://www.youtube.com/@channel",
            "https://www.youtube.com/playlist?list=PL123", "https://example.com/watch?v=\(id)",
            "https://notyoutube.com/watch?v=\(id)", "/Users/me/video.mp4", ""
        ] {
            XCTAssertNil(YouTubeLink.videoID(from: link), link)
        }
        XCTAssertNil(YouTubeLink.videoID(from: URL(fileURLWithPath: "/tmp/youtu.be/\(id)")), "file URLs are never links")
    }

    func testSafariHandoffCarriesTheLink() throws {
        let link = "https://www.youtube.com/watch?v=jNQXAC9IVRw&t=5"
        var components = URLComponents(string: "hdrplayer://open")!
        components.queryItems = [URLQueryItem(name: "url", value: link)]
        let target = try XCTUnwrap(YouTubeLink.handoffTarget(components.url!))
        XCTAssertEqual(YouTubeLink.videoID(from: target), "jNQXAC9IVRw")
        XCTAssertNil(YouTubeLink.handoffTarget(URL(string: "https://www.youtube.com/watch?v=jNQXAC9IVRw")!))
        XCTAssertTrue(YouTubeLink.bookmarklet.hasPrefix("javascript:"))
        XCTAssertTrue(YouTubeLink.bookmarklet.contains("hdrplayer://open?url="))
        XCTAssertTrue(SafariButtonPage.html.contains("hdrplayer://open?url="))
    }

    func testCommandLineAcceptsALink() throws {
        let options = try PlayerOptions.parse(arguments: ["HDRPlayer", "https://youtu.be/jNQXAC9IVRw"])
        XCTAssertEqual(options.inputURL.flatMap(YouTubeLink.videoID(from:)), "jNQXAC9IVRw")
        let file = try PlayerOptions.parse(arguments: ["HDRPlayer", "movie.mp4"])
        XCTAssertEqual(file.inputURL?.isFileURL, true)
    }

    func testProgressWeightsVideoThenAudio() {
        let tracker = DownloadProgressTracker()
        XCTAssertNil(tracker.consume("[download] Destination: x.f137.mp4"))
        XCTAssertEqual(tracker.consume("HDRPROGRESS  50.0% 137")!, 0.45, accuracy: 1e-9)
        XCTAssertEqual(tracker.consume("HDRPROGRESS 100.0% 137")!, 0.9, accuracy: 1e-9)
        XCTAssertEqual(tracker.consume("HDRPROGRESS  50.0% 140")!, 0.95, accuracy: 1e-9)
        XCTAssertEqual(tracker.consume("HDRPROGRESS 100.0% 140")!, 1.0, accuracy: 1e-9)
        XCTAssertNil(tracker.consume("HDRPROGRESS   N/A 140"))
    }

    func testErrorsAreExplained() {
        XCTAssertEqual(YouTubeDownloadError.from(stderr: "ERROR: [youtube] x: Sign in to confirm you’re not a bot.", status: 1), .botCheck)
        XCTAssertEqual(YouTubeDownloadError.from(stderr: "ERROR: [youtube] x: Video unavailable", status: 1), .unavailable)
        XCTAssertEqual(YouTubeDownloadError.from(stderr: "ERROR: [youtube] x: Private video", status: 1), .unavailable)
        XCTAssertEqual(YouTubeDownloadError.from(stderr: "WARNING: a\nERROR: something else", status: 1), .failed("ERROR: something else"))
        XCTAssertEqual(YouTubeDownloadError.from(stderr: "", status: 2), .failed("yt-dlp exited with 2"))
    }

    func testCacheSitsNextToConvertedFiles() {
        let checkout = URL(fileURLWithPath: "/repo/.build/release/HDRPlayer")
        XCTAssertEqual(YouTubeDownloader.defaultCacheDirectory(executable: checkout).path, "/repo/.build/youtube")
    }

    func testArgumentsNeverReadCookiesAndPreferH264() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("hdr-yt-\(UUID().uuidString)")
        guard let downloader = YouTubeDownloader(cacheDirectory: root) else {
            throw XCTSkip("yt-dlp or ffmpeg is not installed")
        }
        let arguments = downloader.arguments(id: "jNQXAC9IVRw", workDirectory: root)
        XCTAssertTrue(arguments.contains("--no-cookies"))
        XCTAssertTrue(arguments.contains("--no-cookies-from-browser"))
        XCTAssertFalse(arguments.contains { $0.contains("cookies-from-browser") && $0 != "--no-cookies-from-browser" })
        XCTAssertTrue(arguments.contains("--no-playlist"))
        XCTAssertEqual(arguments.last, "https://www.youtube.com/watch?v=jNQXAC9IVRw")
        XCTAssertTrue(YouTubeDownloader.formatSelector.hasPrefix("bv*[vcodec^=avc1][height<=1080]+ba[ext=m4a]"))
        XCTAssertEqual(arguments[arguments.firstIndex(of: "--ffmpeg-location")! + 1], downloader.ffmpegDirectory)
    }

    func testAFinishedDownloadIsReusedWithoutTheNetwork() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("hdr-yt-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        guard let downloader = YouTubeDownloader(cacheDirectory: root) else {
            throw XCTSkip("yt-dlp or ffmpeg is not installed")
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: root.appendingPathComponent("jNQXAC9IVRw.mp4"))
        try "Me at the zoo\n".write(to: root.appendingPathComponent("jNQXAC9IVRw.title.txt"), atomically: true, encoding: .utf8)
        let download = try await downloader.download(id: "jNQXAC9IVRw")
        XCTAssertEqual(download.title, "Me at the zoo")
        XCTAssertEqual(download.url.lastPathComponent, "jNQXAC9IVRw.mp4")
        do {
            _ = try await downloader.download(id: "bad")
            XCTFail("an invalid ID must not reach yt-dlp")
        } catch {
            XCTAssertEqual(error as? YouTubeDownloadError, .invalidLink("bad"))
        }
    }

    /// Opt-in (network): HDR_YOUTUBE_NETWORK_TEST=1.
    func testRealDownloadIsPlayableH264() async throws {
        guard ProcessInfo.processInfo.environment["HDR_YOUTUBE_NETWORK_TEST"] == "1" else {
            throw XCTSkip("set HDR_YOUTUBE_NETWORK_TEST=1 to download from YouTube")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("hdr-yt-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let downloader = try XCTUnwrap(YouTubeDownloader(cacheDirectory: root))
        let fractions = FractionLog()
        let download = try await downloader.download(id: "jNQXAC9IVRw") { fractions.append($0) }
        XCTAssertEqual(download.title, "Me at the zoo")
        XCTAssertEqual(fractions.values.last, 1)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasPrefix(".partial") }
        XCTAssertEqual(leftovers, [])
        let decodable = try await PlayableInputConverter.isDecodable(download.url)
        XCTAssertEqual(decodable, true, "H.264 plays without conversion")
    }
}

private final class FractionLog: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Double] = []
    var values: [Double] { lock.withLock { stored } }
    func append(_ value: Double) { lock.withLock { stored.append(value) } }
}
