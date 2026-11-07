import AppKit
import HDRPlayerKit

@main
struct HDRPlayerMain {
    @MainActor
    static func main() {
        do {
            var options = try PlayerOptions.parse(arguments: CommandLine.arguments)
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
