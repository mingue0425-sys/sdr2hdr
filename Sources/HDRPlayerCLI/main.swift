import AppKit
import HDRPlayerKit

@main
struct HDRPlayerMain {
    @MainActor
    static func main() {
        do {
            let options = try PlayerOptions.parse(arguments: CommandLine.arguments)
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
