import Foundation

public enum SplitManager {
    public static func validate(_ manifest: PairManifest) throws {
        var ids = Set<String>()
        var paths = Set<String>()
        for pair in manifest.pairs {
            guard !pair.id.isEmpty else {
                throw CalibrationError.invalidManifest("pair id must not be empty")
            }
            guard ids.insert(pair.id).inserted else {
                throw CalibrationError.invalidManifest("duplicate pair id: \(pair.id)")
            }
            for path in [pair.sdr, pair.hdr] {
                let normalized = URL(fileURLWithPath: path).standardizedFileURL.path
                if path.hasPrefix("/") {
                    guard paths.insert(normalized).inserted else {
                        throw CalibrationError.invalidManifest("same media path appears in more than one pair: \(normalized)")
                    }
                }
            }
        }
    }

    public static func counts(_ manifest: PairManifest) -> [DatasetSplit: Int] {
        Dictionary(grouping: manifest.pairs, by: \.split).mapValues(\.count)
    }
}
