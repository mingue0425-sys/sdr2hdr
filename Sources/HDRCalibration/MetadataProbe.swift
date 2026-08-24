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
        return VideoMetadata(
            path: url.path,
            durationSeconds: duration.isNumeric ? duration.seconds : 0,
            frameRate: frameRate,
            frameCount: frameRate > 0 && duration.isNumeric ? Int((duration.seconds * frameRate).rounded()) : nil,
            width: Int(naturalSize.width),
            height: Int(naturalSize.height),
            codec: codec,
            pixelFormat: nil,
            audioTrackCount: audioTracks.count,
            color: color
        )
    }

    public static func validatePair(
        record: PairRecord,
        sdr: VideoMetadata,
        hdr: VideoMetadata
    ) -> PairValidation {
        var notes: [String] = []
        guard sdr.durationSeconds > 0, hdr.durationSeconds > 0 else {
            return PairValidation(pair: record, sdrMetadata: sdr, hdrMetadata: hdr, status: .pairUncertain, notes: ["zero or unknown duration"])
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
        if let data = extensions[kCMFormatDescriptionExtension_ContentLightLevelInfo as String] as? Data, data.count >= 4 {
            maxCLL = Float(data.withUnsafeBytes { bytes in
                UInt16(bigEndian: bytes.load(fromByteOffset: 0, as: UInt16.self))
            })
            maxFALL = Float(data.withUnsafeBytes { bytes in
                UInt16(bigEndian: bytes.load(fromByteOffset: 2, as: UInt16.self))
            })
        }
        if let data = extensions[kCMFormatDescriptionExtension_MasteringDisplayColorVolume as String] as? Data, data.count >= 24 {
            masteringPeak = Float(data.withUnsafeBytes { bytes in
                UInt32(bigEndian: bytes.load(fromByteOffset: 16, as: UInt32.self))
            }) * 0.0001
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

    private static func fourCC(_ value: FourCharCode) -> String {
        let bytes: [UInt8] = [
            UInt8((value >> 24) & 0xff), UInt8((value >> 16) & 0xff),
            UInt8((value >> 8) & 0xff), UInt8(value & 0xff)
        ]
        return String(bytes: bytes.map { $0 >= 32 && $0 < 127 ? $0 : 46 }, encoding: .ascii) ?? "unknown"
    }
}
