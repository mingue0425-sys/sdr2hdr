import Foundation
import Metal

/// Loads a package's Metal library from whichever layout SwiftPM produced.
///
/// * Named `<name>.metallib`: an explicitly precompiled library.
/// * `default.metallib`: what SwiftPM's build system emits for `.process`
///   shader resources when the Metal Toolchain is installed. The `.metal`
///   sources are then not bundled.
/// * `<name>.metal`: raw sources, compiled at runtime. The native build
///   system copies these when no offline toolchain is used.
///
/// A precompiled library is accepted only if it exposes every required
/// function, so an unrelated `default.metallib` can never be used.
public enum HDRMetalLibraryLoader {
    public enum Origin: String, Equatable, Sendable {
        case namedMetallib = "named-metallib"
        case defaultMetallib = "default-metallib"
        case runtimeSource = "runtime-source"
    }

    public enum Failure: Error, Equatable, LocalizedError {
        case sourceMissing
        case sourceReadFailed(String)
        case compilationFailed(String)

        public var errorDescription: String? {
            switch self {
            case .sourceMissing:
                return "No usable precompiled Metal library or shader source is bundled"
            case .sourceReadFailed(let reason):
                return "Metal shader source could not be read: \(reason)"
            case .compilationFailed(let reason):
                return "Metal shader source failed to compile: \(reason)"
            }
        }
    }

    public static func load(
        device: MTLDevice,
        bundle: Bundle,
        name: String,
        requiredFunctions: [String]
    ) throws -> (library: MTLLibrary, origin: Origin) {
        func complete(_ library: MTLLibrary) -> Bool {
            let available = Set(library.functionNames)
            return requiredFunctions.allSatisfy(available.contains)
        }
        let precompiled: [(String, Origin)] = [(name, .namedMetallib), ("default", .defaultMetallib)]
        for (resource, origin) in precompiled {
            guard let url = bundle.url(forResource: resource, withExtension: "metallib"),
                  let library = try? device.makeLibrary(URL: url),
                  complete(library) else { continue }
            return (library, origin)
        }
        guard let sourceURL = bundle.url(forResource: name, withExtension: "metal") else {
            throw Failure.sourceMissing
        }
        let source: String
        do {
            source = try String(contentsOf: sourceURL, encoding: .utf8)
        } catch {
            throw Failure.sourceReadFailed(String(describing: error))
        }
        do {
            return (try device.makeLibrary(source: source, options: nil), .runtimeSource)
        } catch {
            throw Failure.compilationFailed(String(describing: error))
        }
    }
}
