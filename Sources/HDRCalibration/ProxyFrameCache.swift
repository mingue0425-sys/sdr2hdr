import CoreGraphics
import CoreMedia
import CoreVideo
import CryptoKit
import Darwin
import Foundation

/// Opt-in on-disk cache of decoded proxy sequences (`FrameReader.read` and
/// `FrameReader.readWindow`).
///
/// A correctness review, the batch that follows it and every later round
/// decode the same proxy frames from the same sources. Long 8K VP9 sources
/// take minutes per read. The cache stores each decoded sequence once and
/// replays it.
///
/// A replay is the decoded sequence, not an approximation. It restores the
/// exact proxy plane bytes, pixel-buffer attachments, sample timestamps,
/// source indices and temporal provenance. The luma grid and descriptor are
/// recomputed from those bytes by the same code the decoder uses.
///
/// The key covers everything that can change the decoded result:
/// - the request (kind, pixel format, frame count, proxy width, window start
///   and rate, bit for bit);
/// - the source file identity (path, size, mtime, ctime, inode, device);
/// - the decoders: the OS build (AVFoundation and VideoToolbox), and the file
///   identity of ffmpeg, ffprobe and every non-system library they load;
/// - `decoderSourceDigest`, the SHA-256 of the reader sources. A test fails
///   when those sources change without updating it, so edited decoding code
///   never replays frames decoded by older code.
///
/// Enable it with HDR_PROXY_CACHE_DIR=<directory>. Unset, nothing is read or
/// written. Only Tune/Validation pair preparation and materialization use it
/// (`scope(for:)`); Frozen pairs and every other reader bypass it. A damaged or unreadable entry counts as a miss. Entries are written
/// to a temporary file and renamed into place, so concurrent readers never see
/// a partial entry.
public final class ProxyFrameCache: @unchecked Sendable {
    /// SHA-256 over `decoderSources`, in order, each as "<name>\0<bytes>\0",
    /// with the line that holds this constant removed from this file.
    static let decoderSourceDigest = "e18c1137a87c05fc423aa041a60414257073ed300cf75f09ee859aca93696dfc"
    static let decoderSources = [
        "FrameIO.swift", "ProxyTemporalProvenance.swift", "MetadataProbe.swift",
        "V4DatasetAudit.swift", "ProxyFrameCache.swift"
    ]
    static let formatVersion = "proxy-frame-cache-v1"

    /// The cache readers use in the current task. Only `scope(for:)` sets it,
    /// so audit, preflight and import reads are never cached.
    @TaskLocal public static var current: ProxyFrameCache?

    /// Runs `body` with the shared cache active, unless the pair is Frozen.
    /// Sealed Frozen media is decoded only when a protocol opens it; its proxy
    /// frames never reach the disk.
    static func scope<T>(
        for split: DatasetSplit,
        cache: ProxyFrameCache? = shared,
        _ body: () async throws -> T
    ) async rethrows -> T {
        guard split != .frozen, current == nil, let cache else { return try await body() }
        return try await $current.withValue(cache) { try await body() }
    }

    public static let shared: ProxyFrameCache? = {
        guard let path = ProcessInfo.processInfo.environment["HDR_PROXY_CACHE_DIR"], !path.isEmpty else { return nil }
        return try? ProxyFrameCache(directory: URL(fileURLWithPath: path, isDirectory: true))
    }()

    public let directory: URL
    private let lock = NSLock()
    private var counts = (hits: 0, misses: 0, stores: 0)

    public init(directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.directory = directory
    }

    public var statistics: (hits: Int, misses: Int, stores: Int) {
        lock.lock()
        defer { lock.unlock() }
        return counts
    }

    /// Returns the cached sequence for `request`, or decodes it with `decode`
    /// and stores the result.
    func sequence(
        source: URL,
        request: [String],
        decode: () async throws -> FrameSequence
    ) async throws -> FrameSequence {
        guard let key = Self.key(source: source, request: request) else { return try await decode() }
        let entry = directory.appendingPathComponent(key + ".pfc")
        if let data = try? Data(contentsOf: entry, options: .alwaysMapped),
           let cached = try? Self.decodeEntry(data, url: source) {
            count { $0.hits += 1 }
            return cached
        }
        count { $0.misses += 1 }
        let sequence = try await decode()
        if let data = try? Self.encodeEntry(sequence) {
            let temporary = directory.appendingPathComponent(".\(key).\(UUID().uuidString).tmp")
            if (try? data.write(to: temporary)) != nil {
                if rename(temporary.path, entry.path) == 0 {
                    count { $0.stores += 1 }
                } else {
                    try? FileManager.default.removeItem(at: temporary)
                }
            }
        }
        return sequence
    }

    private func count(_ update: (inout (hits: Int, misses: Int, stores: Int)) -> Void) {
        lock.lock()
        update(&counts)
        lock.unlock()
    }

    // MARK: - Key

    static func key(source: URL, request: [String]) -> String? {
        guard let sourceIdentity = fileIdentity(source.path), let tools = toolIdentity else { return nil }
        let material = [formatVersion, decoderSourceDigest, tools, sourceIdentity] + request
        return SHA256.hash(data: Data(material.joined(separator: "\u{0}").utf8))
            .map { String(format: "%02x", $0) }.joined()
    }

    static func fileIdentity(_ path: String) -> String? {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        return [
            path, String(info.st_size),
            "\(info.st_mtimespec.tv_sec).\(info.st_mtimespec.tv_nsec)",
            "\(info.st_ctimespec.tv_sec).\(info.st_ctimespec.tv_nsec)",
            String(info.st_ino), String(info.st_dev)
        ].joined(separator: "|")
    }

    /// OS build plus the identity of ffmpeg, ffprobe and every non-system
    /// library they load (transitively). Nil disables the cache.
    static let toolIdentity: String? = {
        guard let directory = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"].first(where: {
            FileManager.default.isExecutableFile(atPath: $0 + "/ffmpeg") &&
                FileManager.default.isExecutableFile(atPath: $0 + "/ffprobe")
        }) else { return nil }
        var pending = [directory + "/ffmpeg", directory + "/ffprobe"].map {
            URL(fileURLWithPath: $0).resolvingSymlinksInPath().path
        }
        var seen = Set<String>()
        var identities: [String] = []
        while let path = pending.popLast() {
            guard seen.insert(path).inserted else { continue }
            guard let identity = fileIdentity(path), let libraries = linkedLibraries(path) else { return nil }
            identities.append(identity)
            pending += libraries.filter { !$0.hasPrefix("/System/") && !$0.hasPrefix("/usr/lib/") }
                .map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
        }
        return ([ProcessInfo.processInfo.operatingSystemVersionString] + identities.sorted()).joined(separator: "\n")
    }()

    private static func linkedLibraries(_ path: String) -> [String]? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/otool")
        process.arguments = ["-L", path]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self).split(separator: "\n").dropFirst().compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let end = trimmed.range(of: " (compatibility") else { return nil }
            let library = String(trimmed[..<end.lowerBound])
            // @rpath/@loader_path entries resolve inside the binary's own
            // keg, which the binary's identity already covers.
            return library.hasPrefix("/") ? library : nil
        }
    }

    // MARK: - Entry format

    private static let magic = Data("HDRPFC1\n".utf8)

    private struct Header: Codable {
        var formatVersion: String
        var pixelFormat: UInt32
        var width: Int
        var height: Int
        var nominalFrameRate: Double
        var durationSeconds: Double
        var temporalProvenance: FrameTemporalProvenance?
        var samples: [SampleHeader]
        /// Binary property lists of pixel-buffer attachments, deduplicated.
        var attachments: [Data]
    }

    private struct SampleHeader: Codable {
        var index: Int
        var sequencePosition: Int
        var timeValue: Int64
        var timeScale: Int32
        var timeFlags: UInt32
        var timeEpoch: Int64
        var width: Int
        var height: Int
        var propagated: Int
        var notPropagated: Int
    }

    static func encodeEntry(_ sequence: FrameSequence) throws -> Data {
        var attachments: [Data] = []
        func intern(_ dictionary: CFDictionary?) throws -> Int {
            let data = try PropertyListSerialization.data(
                fromPropertyList: try storable((dictionary as? [String: Any]) ?? [:]), format: .binary, options: 0
            )
            if let existing = attachments.firstIndex(of: data) { return existing }
            attachments.append(data)
            return attachments.count - 1
        }
        var planes = Data()
        var samples: [SampleHeader] = []
        for sample in sequence.samples {
            let buffer = sample.pixelBuffer
            guard CVPixelBufferGetPixelFormatType(buffer) == sequence.pixelFormat else {
                throw CalibrationError.decodeFailed("proxy cache: sample pixel format differs from its sequence")
            }
            samples.append(SampleHeader(
                index: sample.index, sequencePosition: sample.sequencePosition,
                timeValue: sample.timestamp.value, timeScale: sample.timestamp.timescale,
                timeFlags: sample.timestamp.flags.rawValue, timeEpoch: sample.timestamp.epoch,
                width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer),
                propagated: try intern(CVBufferCopyAttachments(buffer, .shouldPropagate)),
                notPropagated: try intern(CVBufferCopyAttachments(buffer, .shouldNotPropagate))
            ))
            try withPlanes(buffer, pixelFormat: sequence.pixelFormat, readOnly: true) { base, rowBytes, used, rows in
                for row in 0..<rows { planes.append(base.advanced(by: row * rowBytes).assumingMemoryBound(to: UInt8.self), count: used) }
            }
        }
        let header = try PropertyListEncoder.binary.encode(Header(
            formatVersion: formatVersion, pixelFormat: sequence.pixelFormat,
            width: sequence.width, height: sequence.height,
            nominalFrameRate: sequence.nominalFrameRate, durationSeconds: sequence.durationSeconds,
            temporalProvenance: sequence.temporalProvenance, samples: samples, attachments: attachments
        ))
        var entry = magic
        var length = UInt64(header.count).littleEndian
        entry.append(Data(bytes: &length, count: 8))
        entry.append(header)
        entry.append(planes)
        return entry
    }

    static func decodeEntry(_ entry: Data, url: URL) throws -> FrameSequence {
        func damaged() -> Error { CalibrationError.decodeFailed("proxy cache entry is damaged") }
        let headerStart = magic.count + 8
        guard entry.count >= headerStart, entry.prefix(magic.count) == magic else { throw damaged() }
        let length = entry.subdata(in: magic.count..<headerStart).withUnsafeBytes { UInt64(littleEndian: $0.loadUnaligned(as: UInt64.self)) }
        guard length <= UInt64(entry.count - headerStart) else { throw damaged() }
        let planesStart = headerStart + Int(length)
        let header = try PropertyListDecoder().decode(Header.self, from: entry.subdata(in: headerStart..<planesStart))
        guard header.formatVersion == formatVersion else { throw damaged() }
        var offset = entry.startIndex + planesStart
        var samples: [FrameSample] = []
        samples.reserveCapacity(header.samples.count)
        for item in header.samples {
            guard header.attachments.indices.contains(item.propagated),
                  header.attachments.indices.contains(item.notPropagated) else { throw damaged() }
            var created: CVPixelBuffer?
            let attributes = [
                kCVPixelBufferMetalCompatibilityKey as String: true,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:]
            ] as CFDictionary
            guard CVPixelBufferCreate(kCFAllocatorDefault, item.width, item.height, header.pixelFormat, attributes, &created) == kCVReturnSuccess,
                  let buffer = created else { throw damaged() }
            for (index, mode) in [(item.propagated, CVAttachmentMode.shouldPropagate), (item.notPropagated, .shouldNotPropagate)] {
                let stored = try PropertyListSerialization.propertyList(from: header.attachments[index], format: nil)
                guard let stored = stored as? [String: Any] else { throw damaged() }
                let dictionary = try restored(stored)
                if !dictionary.isEmpty {
                    CVBufferSetAttachments(buffer, dictionary as CFDictionary, mode)
                }
            }
            try withPlanes(buffer, pixelFormat: header.pixelFormat, readOnly: false) { base, rowBytes, used, rows in
                guard offset + used * rows <= entry.endIndex else { throw damaged() }
                entry.withUnsafeBytes { raw in
                    let source = raw.baseAddress!.advanced(by: offset - entry.startIndex)
                    for row in 0..<rows {
                        base.advanced(by: row * rowBytes).copyMemory(from: source.advanced(by: row * used), byteCount: used)
                    }
                }
                offset += used * rows
            }
            let timestamp = CMTime(
                value: item.timeValue, timescale: item.timeScale,
                flags: CMTimeFlags(rawValue: item.timeFlags), epoch: item.timeEpoch
            )
            let grid = try OfflinePixelSampler.lumaGrid(pixelBuffer: buffer, width: 64, height: 36)
            samples.append(FrameSample(
                index: item.index, sequencePosition: item.sequencePosition, timestamp: timestamp,
                pixelBuffer: buffer, descriptor: FrameDescriptorBuilder.make(timestamp: timestamp, lumaGrid: grid),
                lumaGrid: grid
            ))
        }
        guard offset == entry.endIndex else { throw damaged() }
        return FrameSequence(
            url: url, pixelFormat: header.pixelFormat, width: header.width, height: header.height,
            nominalFrameRate: header.nominalFrameRate, durationSeconds: header.durationSeconds,
            samples: samples, temporalProvenance: header.temporalProvenance
        )
    }

    /// Attachments as a property list. AVFoundation attaches a CGColorSpace,
    /// which is stored as its ICC profile and rebuilt from it.
    private static let colorSpaceMarker = "HDRProxyFrameCache.CGColorSpaceICC"

    private static func storable(_ attachments: [String: Any]) throws -> [String: Any] {
        try attachments.mapValues { value in
            let object = value as CFTypeRef
            if CFGetTypeID(object) == CGColorSpace.typeID {
                guard let icc = (object as! CGColorSpace).copyICCData() as Data? else {
                    throw CalibrationError.decodeFailed("proxy cache cannot store a color space without an ICC profile")
                }
                return [colorSpaceMarker: icc]
            }
            return value
        }
    }

    private static func restored(_ attachments: [String: Any]) throws -> [String: Any] {
        try attachments.mapValues { value in
            guard let wrapped = value as? [String: Any], wrapped.count == 1,
                  let icc = wrapped[colorSpaceMarker] as? Data else { return value }
            guard let space = CGColorSpace(iccData: icc as CFData) else {
                throw CalibrationError.decodeFailed("proxy cache entry is damaged")
            }
            return space
        }
    }

    /// Visits the used bytes of each plane of a supported biplanar proxy
    /// buffer: one sample per luma pixel, one CbCr pair per chroma pixel,
    /// 16 bits per sample for P010.
    private static func withPlanes(
        _ buffer: CVPixelBuffer,
        pixelFormat: OSType,
        readOnly: Bool,
        _ body: (UnsafeMutableRawPointer, Int, Int, Int) throws -> Void
    ) throws {
        guard pixelFormat == CalibrationPixelFormat.sdrNV12 || pixelFormat == CalibrationPixelFormat.hdrP010,
              CVPixelBufferGetPlaneCount(buffer) == 2 else {
            throw CalibrationError.decodeFailed("proxy cache supports NV12 and P010 proxies only")
        }
        let flags: CVPixelBufferLockFlags = readOnly ? .readOnly : []
        guard CVPixelBufferLockBaseAddress(buffer, flags) == kCVReturnSuccess else {
            throw CalibrationError.decodeFailed("proxy cache could not lock a pixel buffer")
        }
        defer { CVPixelBufferUnlockBaseAddress(buffer, flags) }
        let bytesPerSample = pixelFormat == CalibrationPixelFormat.hdrP010 ? 2 : 1
        for plane in 0..<2 {
            guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, plane) else {
                throw CalibrationError.decodeFailed("proxy cache found a pixel buffer without planes")
            }
            let used = CVPixelBufferGetWidthOfPlane(buffer, plane) * (plane == 0 ? 1 : 2) * bytesPerSample
            try body(base, CVPixelBufferGetBytesPerRowOfPlane(buffer, plane), used, CVPixelBufferGetHeightOfPlane(buffer, plane))
        }
    }
}

private extension PropertyListEncoder {
    static var binary: PropertyListEncoder {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        return encoder
    }
}
