import AppKit
import HDRPlayerKit

@main
struct HDRPlayerMain {
    @MainActor
    static func main() {
        // Launched as HDRPlayer.app (double-click, Finder "Open With"): files
        // arrive as open events and the app converts them itself.
        if Bundle.main.bundleURL.pathExtension == "app" {
            let options = (try? PlayerOptions.parse(arguments: CommandLine.arguments)) ?? PlayerOptions()
            let application = NSApplication.shared
            application.setActivationPolicy(.regular)
            let delegate = HDRPlayerApplication(options: options, documentMode: true)
            application.delegate = delegate
            application.run()
            return
        }
        do {
            var options = try PlayerOptions.parse(arguments: CommandLine.arguments)
            if let link = options.inputURL, let id = YouTubeLink.videoID(from: link) {
                guard let downloader = YouTubeDownloader(cacheDirectory: YouTubeDownloader.defaultCacheDirectory()) else {
                    throw YouTubeDownloadError.failed("yt-dlp or ffmpeg not found in /opt/homebrew/bin or /usr/local/bin")
                }
                options.inputURL = try downloader.downloadForPlayback(id: id).url
            }
            if let input = options.inputURL, options.convertUndecodable,
               let converter = PlayableInputConverter(
                   cacheDirectory: options.convertDirectory ?? PlayableInputConverter.defaultCacheDirectory()
               ) {
                options.inputURL = try converter.prepareForPlayback(input)
            }
            let application = NSApplication.shared
            application.setActivationPolicy(.regular)
            let delegate = HDRPlayerApplication(options: options)
            application.delegate = delegate
            application.run()
        } catch HDRPlayerCLIError.helpRequested {
            print(PlayerOptions.usage)
        } catch {
            fputs("HDRPlayer error: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
}
