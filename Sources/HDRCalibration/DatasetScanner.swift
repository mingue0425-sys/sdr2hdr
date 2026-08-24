import Foundation

public enum DatasetScanner {
    public static func scan(manifestURL: URL) async throws -> DatasetReport {
        let manifest = try PairManifest.load(from: manifestURL)
        try SplitManager.validate(manifest)
        var validations: [PairValidation] = []
        validations.reserveCapacity(manifest.pairs.count)
        for record in manifest.pairs {
            let urls = record.resolvedURLs(relativeTo: manifestURL)
            guard FileManager.default.fileExists(atPath: urls.sdr.path),
                  FileManager.default.fileExists(atPath: urls.hdr.path) else {
                validations.append(PairValidation(pair: record, status: .missingFile, notes: [
                    "SDR: \(urls.sdr.path)",
                    "HDR: \(urls.hdr.path)"
                ]))
                continue
            }
            do {
                let sdr = try await MetadataProbe.probe(url: urls.sdr)
                let hdr = try await MetadataProbe.probe(url: urls.hdr)
                validations.append(MetadataProbe.validatePair(record: record, sdr: sdr, hdr: hdr))
            } catch {
                validations.append(PairValidation(pair: record, status: .pairUncertain, notes: [error.localizedDescription]))
            }
        }
        return DatasetReport(manifestPath: manifestURL.path, pairs: validations)
    }

    public static func write(_ report: DatasetReport, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: url)
    }
}
