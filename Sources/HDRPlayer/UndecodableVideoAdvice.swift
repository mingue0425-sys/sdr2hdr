import AVFoundation
import CoreMedia
import Foundation

/// Explains a video that AVFoundation cannot decode on this Mac, with a
/// one-time conversion that keeps its SDR pixels' colour tags.
///
/// YouTube serves VP9 and AV1, the formats yt-dlp picks by default, and
/// AVPlayer and AVAssetReader cannot open them. That includes the SDR
/// renditions of YouTube HDR uploads, which `--sdr-transfer youtube-hlg-v2`
/// is for. VideoToolbox HEVC keeps the
/// BT.709 primaries, transfer, matrix and narrow range of the source.
public enum UndecodableVideoAdvice {
    /// The first video track. A container AVFoundation cannot open (WebM,
    /// the yt-dlp default) throws the conversion advice.
    public static func videoTrack(of asset: AVAsset, url: URL) async throws -> AVAssetTrack? {
        do {
            return try await asset.loadTracks(withMediaType: .video).first
        } catch {
            throw AdviceError(message: message(url: url, codec: url.pathExtension.isEmpty ? "this" : url.pathExtension))
        }
    }

    public struct AdviceError: Error, LocalizedError {
        public let message: String
        public var errorDescription: String? { message }
    }

    /// Nil when the track is decodable.
    public static func check(track: AVAssetTrack, url: URL) async throws -> String? {
        guard try await !track.load(.isDecodable) else { return nil }
        let codec = try await track.load(.formatDescriptions).first
            .map { fourCC(CMFormatDescriptionGetMediaSubType($0)) } ?? "unknown"
        return message(url: url, codec: codec)
    }

    public static func message(url: URL, codec: String) -> String {
        let name = codecName(codec)
        let output = url.deletingPathExtension().path + "-hevc.mov"
        return """
        AVFoundation cannot decode \(name) video on this Mac: \(url.lastPathComponent)
        YouTube downloads are usually VP9 or AV1. Convert once, keeping the colour tags:
          ffmpeg -i \(quoted(url.path)) -map 0:v:0 -map '0:a?' -c:v hevc_videotoolbox -q:v 75 -tag:v hvc1 -c:a aac \(quoted(output))
        Then play the .mov. If it is the SDR rendition of a YouTube HDR (HLG) upload, add --sdr-transfer youtube-hlg-v2.
        """
    }

    static func codecName(_ fourCC: String) -> String {
        switch fourCC {
        case "vp09": return "VP9"
        case "av01": return "AV1"
        case "webm", "mkv": return fourCC.uppercased()
        default: return fourCC
        }
    }

    static func quoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func fourCC(_ value: FourCharCode) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8((value >> UInt32($0)) & 0xff) }
        return String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespaces)
    }
}
