@preconcurrency import AVFoundation
import CoreMedia
import CoreVideo
import Foundation

public enum MetadataProbe {
    public static func probe(url: URL) async throws -> VideoMetadata {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw CalibrationError.metadataUnavailable("file does not exist: \(url.path)")
        }
        let asset = AVURLAsset(url: url)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        guard let track = videoTracks.first else {
            throw CalibrationError.metadataUnavailable("no video track: \(url.path)")
        }
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        let duration = try await asset.load(.duration)
        let naturalSize = try await track.load(.naturalSize)
        let frameRate = Double(try await track.load(.nominalFrameRate))
        let descriptions = try await track.load(.formatDescriptions)
        let color = colorMetadata(from: descriptions.first)
        let codec = descriptions.first.map {
            fourCC(CMFormatDescriptionGetMediaSubType($0))
        }
        let numeric = try validatedNumericMetadata(
            durationSeconds: duration.isNumeric ? duration.seconds : 0,
            frameRate: frameRate,
            width: Double(naturalSize.width),
            height: Double(naturalSize.height)
        )
        return VideoMetadata(
            path: url.path,
            durationSeconds: numeric.durationSeconds,
            frameRate: numeric.frameRate,
            frameCount: numeric.frameCount,
            width: numeric.width,
            height: numeric.height,
            codec: codec,
            pixelFormat: nil,
            audioTrackCount: audioTracks.count,
            color: color
        )
    }

    /// Validate file-derived numeric fields before any floating-point to
    /// integer conversion. Malformed media metadata must produce a normal
    /// decode error instead of trapping the calibration process.
    static func validatedNumericMetadata(
        durationSeconds: Double,
        frameRate: Double,
        width: Double,
        height: Double
    ) throws -> (
        durationSeconds: Double,
        frameRate: Double,
        frameCount: Int?,
        width: Int,
        height: Int
    ) {
        guard durationSeconds.isFinite,
              durationSeconds >= 0,
              durationSeconds <= Double(Int32.max),
              frameRate.isFinite,
              (0...1_000).contains(frameRate),
              width.isFinite,
              height.isFinite,
              (1...65_536).contains(width),
              (1...65_536).contains(height) else {
            throw CalibrationError.metadataUnavailable(
                "video contains invalid or unsafe numeric metadata"
            )
        }
        let estimatedFrames = durationSeconds * frameRate
        guard estimatedFrames.isFinite,
              estimatedFrames <= Double(Int32.max) else {
            throw CalibrationError.metadataUnavailable(
                "video frame count exceeds the supported timeline"
            )
        }
        return (
            durationSeconds,
            frameRate,
            frameRate > 0 && durationSeconds > 0
                ? Int(estimatedFrames.rounded()) : nil,
            Int(width.rounded()),
            Int(height.rounded())
        )
    }

    public static func validatePair(
        record: PairRecord,
        sdr: VideoMetadata,
        hdr: VideoMetadata
    ) -> PairValidation {
        var notes: [String] = []
        guard sdr.durationSeconds.isFinite,
              hdr.durationSeconds.isFinite,
              sdr.durationSeconds > 0,
              hdr.durationSeconds > 0,
              sdr.frameRate.isFinite,
              hdr.frameRate.isFinite,
              sdr.frameRate >= 0,
              hdr.frameRate >= 0,
              sdr.width > 0,
              sdr.height > 0,
              hdr.width > 0,
              hdr.height > 0 else {
            return PairValidation(
                pair: record,
                sdrMetadata: sdr,
                hdrMetadata: hdr,
                status: .pairUncertain,
                notes: ["invalid, zero, or unknown stream metadata"]
            )
        }
        guard hdr.color.referenceTransfer == .pq || hdr.color.referenceTransfer == .hlg else {
            notes.append("HDR transfer is \(hdr.color.transfer ?? "missing"), not PQ; HLG/unknown references are excluded")
            return PairValidation(pair: record, sdrMetadata: sdr, hdrMetadata: hdr, status: .pairInvalidHDR, notes: notes)
        }
        if hdr.color.referenceTransfer == .hlg {
            notes.append("HLG reference will use an explicit scene-referred system-gamma model; it is not treated as PQ")
        }
        guard hdr.color.primaries?.lowercased().contains("2020") == true else {
            notes.append("HDR reference does not declare BT.2020 primaries")
            return PairValidation(pair: record, sdrMetadata: sdr, hdrMetadata: hdr, status: .pairInvalidHDR, notes: notes)
        }
        let durationDelta = abs(sdr.durationSeconds - hdr.durationSeconds)
        let aspectSDR = Double(sdr.width) / Double(max(sdr.height, 1))
        let aspectHDR = Double(hdr.width) / Double(max(hdr.height, 1))
        let aspectDelta = abs(aspectSDR - aspectHDR) / max(aspectSDR, aspectHDR)
        let frameRateDelta = sdr.frameRate > 0 && hdr.frameRate > 0
            ? abs(sdr.frameRate - hdr.frameRate) / max(sdr.frameRate, hdr.frameRate)
            : 0
        if durationDelta > 0.5 {
            notes.append(String(format: "duration delta %.3fs requires temporal alignment", durationDelta))
        }
        if aspectDelta > 0.02 {
            notes.append(String(format: "aspect ratio delta %.3f requires spatial inspection", aspectDelta))
        }
        if frameRateDelta > 0.02 {
            notes.append(String(format: "frame-rate delta %.3f requires PTS alignment", frameRateDelta))
        }
        let status: PairStatus = durationDelta > 5 || aspectDelta > 0.12 ? .pairUncertain : .pairNeedsAlignment
        return PairValidation(pair: record, sdrMetadata: sdr, hdrMetadata: hdr, status: status, notes: notes)
    }

    private static func colorMetadata(from description: CMFormatDescription?) -> ColorMetadataSummary {
        guard let description,
              let extensions = CMFormatDescriptionGetExtensions(description) as? [String: Any] else {
            return ColorMetadataSummary()
        }
        func string(_ key: CFString) -> String? {
            if let value = extensions[key as String] as? String { return value }
            return nil
        }
        func number(_ key: CFString) -> Int? {
            (extensions[key as String] as? NSNumber).map(\.intValue)
        }
        var maxCLL: Float?
        var maxFALL: Float?
        var masteringPeak: Float?
        if let data = extensions[kCMFormatDescriptionExtension_ContentLightLevelInfo as String] as? Data,
           let contentPeak = bigEndianUInt16(data, offset: 0),
           let frameAverage = bigEndianUInt16(data, offset: 2) {
            maxCLL = Float(contentPeak)
            maxFALL = Float(frameAverage)
        }
        if let data = extensions[kCMFormatDescriptionExtension_MasteringDisplayColorVolume as String] as? Data,
           let peak = bigEndianUInt32(data, offset: 16) {
            masteringPeak = Float(peak) * 0.0001
        }
        return ColorMetadataSummary(
            primaries: string(kCMFormatDescriptionExtension_ColorPrimaries),
            transfer: string(kCMFormatDescriptionExtension_TransferFunction),
            matrix: string(kCMFormatDescriptionExtension_YCbCrMatrix),
            range: nil,
            bitDepth: number(kCMFormatDescriptionExtension_BitsPerComponent),
            masteringPeakNits: masteringPeak,
            maxCLL: maxCLL,
            maxFALL: maxFALL
        )
    }

    private static func bigEndianUInt16(_ data: Data, offset: Int) -> UInt16? {
        guard offset >= 0, data.count - offset >= 2 else { return nil }
        return data.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            return UInt16(bytes[offset]) << 8 | UInt16(bytes[offset + 1])
        }
    }

    private static func bigEndianUInt32(_ data: Data, offset: Int) -> UInt32? {
        guard offset >= 0, data.count - offset >= 4 else { return nil }
        return data.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            return UInt32(bytes[offset]) << 24 |
                UInt32(bytes[offset + 1]) << 16 |
                UInt32(bytes[offset + 2]) << 8 |
                UInt32(bytes[offset + 3])
        }
    }

    private static func fourCC(_ value: FourCharCode) -> String {
        let bytes: [UInt8] = [
            UInt8((value >> 24) & 0xff), UInt8((value >> 16) & 0xff),
            UInt8((value >> 8) & 0xff), UInt8(value & 0xff)
        ]
        return String(bytes: bytes.map { $0 >= 32 && $0 < 127 ? $0 : 46 }, encoding: .ascii) ?? "unknown"
    }
}
