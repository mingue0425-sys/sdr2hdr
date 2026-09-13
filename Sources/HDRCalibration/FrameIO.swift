@preconcurrency import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import HDRCore
import simd

public enum CalibrationPixelFormat {
    public static let sdrNV12 = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
    public static let hdrP010 = kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
}

public struct FrameSample {
    /// Index in the original source timeline. This may be sparse when the
    /// reader uses stride sampling.
    public let index: Int
    /// Position in `FrameSequence.samples`. Never compare this with `index`.
    public let sequencePosition: Int
    public let timestamp: CMTime
    public let pixelBuffer: CVPixelBuffer
    public let descriptor: FrameDescriptor
    public let lumaGrid: [Float]

    public init(
        index: Int,
        sequencePosition: Int? = nil,
        timestamp: CMTime,
        pixelBuffer: CVPixelBuffer,
        descriptor: FrameDescriptor,
        lumaGrid: [Float]
    ) {
        self.index = index
        self.sequencePosition = sequencePosition ?? index
        self.timestamp = timestamp
        self.pixelBuffer = pixelBuffer
        self.descriptor = descriptor
        self.lumaGrid = lumaGrid
    }
}

public struct FrameSequence {
    public let url: URL
    public let pixelFormat: OSType
    public let width: Int
    public let height: Int
    public let nominalFrameRate: Double
    public let durationSeconds: Double
    public let samples: [FrameSample]

    public init(
        url: URL,
        pixelFormat: OSType,
        width: Int,
        height: Int,
        nominalFrameRate: Double,
        durationSeconds: Double,
        samples: [FrameSample]
    ) {
        self.url = url
        self.pixelFormat = pixelFormat
        self.width = width
        self.height = height
        self.nominalFrameRate = nominalFrameRate
        self.durationSeconds = durationSeconds
        self.samples = samples
    }
}

public enum FrameReader {
    static func sourceFrameIndex(
        startSeconds: Double,
        outputIndex: Int,
        outputFramesPerSecond: Double,
        sourceFramesPerSecond: Double,
        samplingSemantics: V6FrameSamplingSemanticConfiguration = .v6
    ) -> Int? {
        samplingSemantics.sourceFrameIndex(
            startSeconds: startSeconds,
            outputIndex: outputIndex,
            outputFramesPerSecond: outputFramesPerSecond,
            sourceFramesPerSecond: sourceFramesPerSecond
        )
    }

    private struct ValidatedVideoMetadata {
        let sourceWidth: Int
        let sourceHeight: Int
        let proxyHeight: Int
        let nominalFrameRate: Double
        let durationSeconds: Double
    }

    /// Decodes a short consecutive proxy sequence for temporal calibration.
    /// Unlike `read`, this never spreads samples across the whole asset.
    public static func readWindow(
        url: URL,
        pixelFormat: OSType,
        startSeconds: Double,
        frameCount: Int = 16,
        framesPerSecond: Double = 30,
        proxyWidth: Int = 320,
        descriptorSemantics: V6DescriptorSemanticConfiguration = .v6,
        colorScience: HDRColorScienceSemanticDefinition = .calibrationV4,
        validationSemantics: V6PreparationValidationSemanticConfiguration = .v6,
        metadataSemantics: V6DecoderMetadataSemanticConfiguration = .v6,
        samplingSemantics: V6FrameSamplingSemanticConfiguration = .v6
    ) async throws -> FrameSequence {
        guard (1...validationSemantics.maximumDecodedFrames).contains(frameCount),
              (validationSemantics.minimumProxyWidth...validationSemantics.maximumProxyWidth).contains(proxyWidth),
              proxyWidth.isMultiple(of: 2),
              isSupported(pixelFormat: pixelFormat),
              startSeconds.isFinite,
              framesPerSecond.isFinite,
              framesPerSecond >= validationSemantics.minimumTemporalFPS,
              framesPerSecond <= validationSemantics.maximumTemporalFPS else {
            throw CalibrationError.decodeFailed(
                "window decode request contains invalid or unsafe bounds"
            )
        }
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard let track = tracks.first else {
            throw CalibrationError.decodeFailed("no video track: \(url.path)")
        }
        let duration = try await asset.load(.duration)
        let naturalSize = try await track.load(.naturalSize)
        let nominal = Double(try await track.load(.nominalFrameRate))
        let formatDescriptions = try await track.load(.formatDescriptions)
        let metadata = try validatedMetadata(
            naturalSize: naturalSize,
            nominalFrameRate: nominal,
            duration: duration,
            proxyWidth: proxyWidth,
            validationSemantics: validationSemantics,
            url: url,
            samplingSemantics: samplingSemantics
        )
        let sourcePosition = max(startSeconds, 0) * samplingSemantics.sourceRate(
            sourceFramesPerSecond: metadata.nominalFrameRate,
            outputFramesPerSecond: framesPerSecond
        )
        guard sourcePosition.isFinite, sourcePosition <= Double(samplingSemantics.sourceTimelineMaximum) else {
            throw CalibrationError.decodeFailed(
                "window decode start exceeds the supported source timeline"
            )
        }
        return try await FFmpegFrameReader.read(
            url: url,
            formatDescription: formatDescriptions.first,
            pixelFormat: pixelFormat,
            maxFrames: frameCount,
            proxyWidth: proxyWidth,
            sourceWidth: metadata.sourceWidth,
            sourceHeight: metadata.sourceHeight,
            nominalFrameRate: metadata.nominalFrameRate,
            durationSeconds: metadata.durationSeconds,
            startSeconds: max(startSeconds, 0),
            samplingFPS: min(framesPerSecond, metadata.nominalFrameRate > 0 ? metadata.nominalFrameRate : framesPerSecond),
            descriptorSemantics: descriptorSemantics,
            colorScience: colorScience,
            validationSemantics: validationSemantics,
            metadataSemantics: metadataSemantics,
            samplingSemantics: samplingSemantics
        )
    }

    public static func read(
        url: URL,
        pixelFormat: OSType,
        maxFrames: Int = 240,
        proxyWidth: Int = 320,
        descriptorSemantics: V6DescriptorSemanticConfiguration = .v6,
        colorScience: HDRColorScienceSemanticDefinition = .calibrationV4,
        validationSemantics: V6PreparationValidationSemanticConfiguration = .v6,
        metadataSemantics: V6DecoderMetadataSemanticConfiguration = .v6,
        samplingSemantics: V6FrameSamplingSemanticConfiguration = .v6
    ) async throws -> FrameSequence {
        guard (1...validationSemantics.maximumDecodedFrames).contains(maxFrames),
              (validationSemantics.minimumProxyWidth...validationSemantics.maximumProxyWidth).contains(proxyWidth),
              proxyWidth.isMultiple(of: 2),
              isSupported(pixelFormat: pixelFormat) else {
            throw CalibrationError.decodeFailed(
                "proxy decode request contains invalid or unsafe bounds"
            )
        }
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard let track = tracks.first else {
            throw CalibrationError.decodeFailed("no video track: \(url.path)")
        }
        let duration = try await asset.load(.duration)
        let naturalSize = try await track.load(.naturalSize)
        let nominalFrameRate = Double(try await track.load(.nominalFrameRate))
        let metadata = try validatedMetadata(
            naturalSize: naturalSize,
            nominalFrameRate: nominalFrameRate,
            duration: duration,
            proxyWidth: proxyWidth,
            validationSemantics: validationSemantics,
            url: url,
            samplingSemantics: samplingSemantics
        )
        let formatDescriptions = try await track.load(.formatDescriptions)
        let codec = formatDescriptions.first.map { fourCC(CMFormatDescriptionGetMediaSubType($0)) }
        if codec == "vp09" || codec == "av01" {
            return try await FFmpegFrameReader.read(
                url: url,
                formatDescription: formatDescriptions.first,
                pixelFormat: pixelFormat,
                maxFrames: maxFrames,
                proxyWidth: proxyWidth,
                sourceWidth: metadata.sourceWidth,
                sourceHeight: metadata.sourceHeight,
                nominalFrameRate: metadata.nominalFrameRate,
                durationSeconds: metadata.durationSeconds,
            descriptorSemantics: descriptorSemantics,
            colorScience: colorScience,
            validationSemantics: validationSemantics,
            metadataSemantics: metadataSemantics,
            samplingSemantics: samplingSemantics
            )
        }
        let estimatedFrames = metadata.nominalFrameRate > 0 && metadata.durationSeconds > 0
            ? metadata.durationSeconds * metadata.nominalFrameRate
            : Double(maxFrames)
        let stride = samplingSemantics.stride(
            estimatedFrames: estimatedFrames,
            maximumFrames: maxFrames
        )
        guard stride > 0, stride <= Int(samplingSemantics.sourceTimelineMaximum) else {
            throw CalibrationError.decodeFailed(
                "video timeline exceeds the supported proxy sampling range"
            )
        }
        let settings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: pixelFormat,
            kCVPixelBufferWidthKey as String: proxyWidth,
            kCVPixelBufferHeightKey as String: metadata.proxyHeight,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw CalibrationError.decodeFailed("cannot add track output: \(url.path)")
        }
        reader.add(output)
        guard reader.startReading() else {
            return try await FFmpegFrameReader.read(
                url: url,
                formatDescription: formatDescriptions.first,
                pixelFormat: pixelFormat,
                maxFrames: maxFrames,
                proxyWidth: proxyWidth,
                sourceWidth: metadata.sourceWidth,
                sourceHeight: metadata.sourceHeight,
                nominalFrameRate: metadata.nominalFrameRate,
                durationSeconds: metadata.durationSeconds,
                descriptorSemantics: descriptorSemantics,
                colorScience: colorScience,
                validationSemantics: validationSemantics,
                metadataSemantics: metadataSemantics,
                samplingSemantics: samplingSemantics
            )
        }

        var samples: [FrameSample] = []
        var frameIndex = 0
        while let sampleBuffer = output.copyNextSampleBuffer() {
            defer { frameIndex += 1 }
            guard frameIndex % stride == 0,
                  let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { continue }
            let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            let grid = try OfflinePixelSampler.lumaGrid(
                pixelBuffer: pixelBuffer,
                width: descriptorSemantics.gridWidth,
                height: descriptorSemantics.gridHeight,
                colorScience: colorScience
            )
            let descriptor = FrameDescriptorBuilder.make(
                timestamp: timestamp,
                lumaGrid: grid,
                configuration: descriptorSemantics
            )
            samples.append(FrameSample(
                index: frameIndex,
                sequencePosition: samples.count,
                timestamp: timestamp,
                pixelBuffer: pixelBuffer,
                descriptor: descriptor,
                lumaGrid: grid
            ))
            if samples.count >= maxFrames {
                reader.cancelReading()
                break
            }
        }
        if reader.status == .failed || samples.isEmpty {
            return try await FFmpegFrameReader.read(
                url: url,
                formatDescription: formatDescriptions.first,
                pixelFormat: pixelFormat,
                maxFrames: maxFrames,
                proxyWidth: proxyWidth,
                sourceWidth: metadata.sourceWidth,
                sourceHeight: metadata.sourceHeight,
                nominalFrameRate: metadata.nominalFrameRate,
                durationSeconds: metadata.durationSeconds,
                descriptorSemantics: descriptorSemantics,
                colorScience: colorScience,
                validationSemantics: validationSemantics,
                metadataSemantics: metadataSemantics,
                samplingSemantics: samplingSemantics
            )
        }
        let actualWidth = samples.first.map { CVPixelBufferGetWidth($0.pixelBuffer) } ?? metadata.sourceWidth
        let actualHeight = samples.first.map { CVPixelBufferGetHeight($0.pixelBuffer) } ?? metadata.sourceHeight
        return FrameSequence(
            url: url,
            pixelFormat: pixelFormat,
            width: actualWidth,
            height: actualHeight,
            nominalFrameRate: metadata.nominalFrameRate,
            durationSeconds: metadata.durationSeconds,
            samples: samples
        )
    }

    private static func isSupported(pixelFormat: OSType) -> Bool {
        pixelFormat == CalibrationPixelFormat.sdrNV12 ||
            pixelFormat == CalibrationPixelFormat.hdrP010
    }

    private static func validatedMetadata(
        naturalSize: CGSize,
        nominalFrameRate: Double,
        duration: CMTime,
        proxyWidth: Int,
        validationSemantics: V6PreparationValidationSemanticConfiguration,
        url: URL,
        samplingSemantics: V6FrameSamplingSemanticConfiguration
    ) throws -> ValidatedVideoMetadata {
        let durationSeconds = duration.isNumeric ? duration.seconds : 0
        guard naturalSize.width.isFinite,
              naturalSize.height.isFinite,
              naturalSize.width > 0,
              naturalSize.height > 0,
              naturalSize.width <= CGFloat(validationSemantics.maximumDecodedWidth),
              naturalSize.height <= CGFloat(validationSemantics.maximumDecodedHeight),
              nominalFrameRate.isFinite,
              (0...validationSemantics.maximumNominalFPS).contains(nominalFrameRate),
              durationSeconds.isFinite,
              durationSeconds >= 0 else {
            throw CalibrationError.decodeFailed(
                "video metadata is invalid or unsafe: \(url.lastPathComponent)"
            )
        }

        let sourceWidth = Int(naturalSize.width.rounded())
        let sourceHeight = Int(naturalSize.height.rounded())
        let scaledHeight = Double(proxyWidth) * Double(sourceHeight) / Double(sourceWidth)
        guard scaledHeight.isFinite, scaledHeight > 0,
              scaledHeight <= Double(validationSemantics.maximumProxyHeight) else {
            throw CalibrationError.decodeFailed(
                "video aspect ratio produces an unsafe proxy size: \(url.lastPathComponent)"
            )
        }
        let proxyHeight = samplingSemantics.proxyHeight(
            proxyWidth: proxyWidth,
            sourceWidth: sourceWidth,
            sourceHeight: sourceHeight
        )
        return ValidatedVideoMetadata(
            sourceWidth: sourceWidth,
            sourceHeight: sourceHeight,
            proxyHeight: proxyHeight,
            nominalFrameRate: nominalFrameRate,
            durationSeconds: durationSeconds
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

/// Rawvideo has no color metadata. Preserve the source contract explicitly;
/// P010 is a storage format, not evidence that the transfer function is HLG.
struct FFmpegProxyColorMetadata {
    let primaries: String
    let transfer: String
    let matrix: String
    let gamma: NSNumber?
    let scaleOptions: String
    let isHDRReference: Bool

    init(formatDescription: CMFormatDescription?, pixelFormat: OSType) throws {
        guard let formatDescription,
              let extensions = CMFormatDescriptionGetExtensions(formatDescription) as? [String: Any] else {
            throw CalibrationError.decodeFailed("ffmpeg proxy requires explicit source color metadata")
        }
        try self.init(extensions: extensions, pixelFormat: pixelFormat)
    }

    static func resolve(
        url: URL,
        formatDescription: CMFormatDescription?,
        pixelFormat: OSType,
        metadataSemantics: V6DecoderMetadataSemanticConfiguration = .v6
    ) async throws -> Self {
        if let color = try? Self(formatDescription: formatDescription, pixelFormat: pixelFormat) { return color }
        // If AVFoundation does not supply the needed tags, recover explicit
        // ffprobe metadata for the fallback decoder, not invented defaults.
        let metadata = try await V4MetadataProbe.probe(url: url)
        guard metadata.probeTool == "ffprobe" else {
            throw CalibrationError.decodeFailed("no complete color metadata for ffmpeg proxy")
        }
        let primaries: CFString
        switch metadata.colorPrimaries {
        case "bt709": primaries = kCVImageBufferColorPrimaries_ITU_R_709_2
        case "bt2020": primaries = kCVImageBufferColorPrimaries_ITU_R_2020
        default: throw CalibrationError.decodeFailed("unsupported ffmpeg source primaries")
        }
        let matrix: CFString
        switch metadata.matrix {
        case "bt709": matrix = kCVImageBufferYCbCrMatrix_ITU_R_709_2
        case "smpte170m", "bt470bg": matrix = kCVImageBufferYCbCrMatrix_ITU_R_601_4
        case "bt2020nc": matrix = kCVImageBufferYCbCrMatrix_ITU_R_2020
        default: throw CalibrationError.decodeFailed("unsupported ffmpeg source matrix")
        }
        let transfer: CFString
        var gamma: NSNumber?
        switch metadata.transfer {
        case "bt709": transfer = kCVImageBufferTransferFunction_ITU_R_709_2
        case "iec61966-2-1": transfer = kCVImageBufferTransferFunction_sRGB
        case "linear": transfer = kCVImageBufferTransferFunction_Linear
        case "gamma22": transfer = kCVImageBufferTransferFunction_UseGamma; gamma = NSNumber(value: metadataSemantics.gamma22)
        case "gamma28": transfer = kCVImageBufferTransferFunction_UseGamma; gamma = NSNumber(value: metadataSemantics.gamma28)
        default:
            switch ReferenceTransfer.parse(metadata.transfer) {
            case .pq: transfer = kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ
            case .hlg: transfer = kCVImageBufferTransferFunction_ITU_R_2100_HLG
            case .unknown: throw CalibrationError.decodeFailed("unsupported ffmpeg source transfer")
            }
        }
        var extensions: [String: Any] = [
            kCMFormatDescriptionExtension_ColorPrimaries as String: primaries,
            kCMFormatDescriptionExtension_TransferFunction as String: transfer,
            kCMFormatDescriptionExtension_YCbCrMatrix as String: matrix
        ]
        if let gamma { extensions[kCMFormatDescriptionExtension_GammaLevel as String] = gamma }
        if metadata.colorRange == "pc" || metadata.colorRange == "tv" {
            extensions[kCMFormatDescriptionExtension_FullRangeVideo as String] = NSNumber(value: metadata.colorRange == "pc")
        }
        return try Self(extensions: extensions, pixelFormat: pixelFormat)
    }

    private init(extensions: [String: Any], pixelFormat: OSType) throws {
        guard let primaries = extensions[kCMFormatDescriptionExtension_ColorPrimaries as String] as? String,
              let transfer = extensions[kCMFormatDescriptionExtension_TransferFunction as String] as? String,
              let matrix = extensions[kCMFormatDescriptionExtension_YCbCrMatrix as String] as? String else {
            throw CalibrationError.decodeFailed("ffmpeg proxy requires explicit source color metadata")
        }
        let matrixName: String
        if matrix == kCVImageBufferYCbCrMatrix_ITU_R_709_2 as String { matrixName = "bt709" }
        else if matrix == kCVImageBufferYCbCrMatrix_ITU_R_601_4 as String { matrixName = "bt601" }
        else if matrix == kCVImageBufferYCbCrMatrix_ITU_R_2020 as String { matrixName = "bt2020" }
        else { throw CalibrationError.decodeFailed("unsupported ffmpeg proxy YCbCr matrix") }
        isHDRReference = pixelFormat == CalibrationPixelFormat.hdrP010
        if isHDRReference {
            guard primaries == kCVImageBufferColorPrimaries_ITU_R_2020 as String,
                  matrixName == "bt2020", ReferenceTransfer.parse(transfer) != .unknown else {
                throw CalibrationError.unsupportedReference("proxy reference requires BT.2020 PQ or HLG")
            }
        }
        self.primaries = primaries
        self.transfer = transfer
        self.matrix = matrix
        gamma = extensions[kCMFormatDescriptionExtension_GammaLevel as String] as? NSNumber
        // Rawvideo has no range metadata.  `auto` is not a source contract:
        // it lets the decoder guess differently across codecs/platforms and
        // can turn a tag-only relabel into a numeric range error.  Require the
        // explicit CoreMedia range bit, or let resolve(url:) recover it from
        // the complete ffprobe stream metadata.
        guard let fullRange = extensions[kCMFormatDescriptionExtension_FullRangeVideo as String] as? NSNumber else {
            throw CalibrationError.decodeFailed("ffmpeg proxy requires explicit source color range")
        }
        let inputRange = fullRange.boolValue ? "pc" : "tv"
        // Both supported proxy CV pixel formats are video-range. Do the actual
        // conversion in swscale instead of merely tagging full-range raw bytes.
        scaleOptions = "in_range=\(inputRange):out_range=tv:in_color_matrix=\(matrixName):out_color_matrix=\(matrixName)"
    }

    func apply(to pixelBuffer: CVPixelBuffer) throws {
        CVBufferSetAttachment(pixelBuffer, kCVImageBufferColorPrimariesKey, primaries as CFString, .shouldPropagate)
        CVBufferSetAttachment(pixelBuffer, kCVImageBufferTransferFunctionKey, transfer as CFString, .shouldPropagate)
        CVBufferSetAttachment(pixelBuffer, kCVImageBufferYCbCrMatrixKey, matrix as CFString, .shouldPropagate)
        if let gamma { CVBufferSetAttachment(pixelBuffer, kCVImageBufferGammaLevelKey, gamma, .shouldPropagate) }
        if !isHDRReference {
            _ = try HDRInputMetadata.resolve(pixelBuffer: pixelBuffer, fallbackPolicy: .requireMetadata)
        }
    }
}

private enum FFmpegFrameReader {
    static func read(
        url: URL,
        formatDescription: CMFormatDescription?,
        pixelFormat: OSType,
        maxFrames: Int,
        proxyWidth: Int,
        sourceWidth: Int,
        sourceHeight: Int,
        nominalFrameRate: Double,
        durationSeconds: Double,
        startSeconds: Double? = nil,
        samplingFPS: Double? = nil,
        descriptorSemantics: V6DescriptorSemanticConfiguration = .v6,
        colorScience: HDRColorScienceSemanticDefinition = .calibrationV4,
        validationSemantics: V6PreparationValidationSemanticConfiguration = .v6,
        metadataSemantics: V6DecoderMetadataSemanticConfiguration = .v6,
        samplingSemantics: V6FrameSamplingSemanticConfiguration = .v6
    ) async throws -> FrameSequence {
        guard let executable = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg"].first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw CalibrationError.decodeFailed("AVAssetReader failed and ffmpeg fallback is unavailable")
        }
        let isP010 = pixelFormat == CalibrationPixelFormat.hdrP010
        let color = try await FFmpegProxyColorMetadata.resolve(
            url: url,
            formatDescription: formatDescription,
            pixelFormat: pixelFormat,
            metadataSemantics: metadataSemantics
        )
        let proxyHeight = samplingSemantics.proxyHeight(
            proxyWidth: proxyWidth,
            sourceWidth: sourceWidth,
            sourceHeight: sourceHeight
        )
        let outputPixelFormat = isP010 ? "p010le" : "nv12"
        let distributedFPS = samplingSemantics.distributedFPS(
            maxFrames: maxFrames,
            durationSeconds: durationSeconds,
            nominalFrameRate: nominalFrameRate,
            minimumFPS: descriptorSemantics.minimumFFmpegSamplingFPS
        )
        let requestedFPS = samplingFPS ?? distributedFPS
        let outputFPS = nominalFrameRate > 0
            ? min(requestedFPS, nominalFrameRate)
            : min(requestedFPS, validationSemantics.maximumNominalFPS)
        guard outputFPS.isFinite,
              outputFPS >= validationSemantics.minimumTemporalFPS,
              outputFPS <= validationSemantics.maximumNominalFPS,
              proxyHeight <= validationSemantics.maximumProxyHeight else {
            throw CalibrationError.decodeFailed(
                "ffmpeg proxy rate or dimensions exceed safe bounds"
            )
        }
        let filter = "fps=\(String(format: "%.6f", outputFPS)):round=\(samplingSemantics.ffmpegFPSRoundingRule),scale=\(proxyWidth):\(proxyHeight):flags=\(samplingSemantics.ffmpegScaleFilter):\(color.scaleOptions)"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        // This is an offline proxy reader, but it must still be bounded and
        // non-interactive.  In particular, never leave ffmpeg's stderr pipe
        // undrained: a noisy VideoToolbox fallback can fill that pipe while
        // the caller is blocked waiting for rawvideo on stdout.
        var arguments = ["-hide_banner", "-nostdin", "-loglevel", "error", "-hwaccel", "videotoolbox"]
        if let startSeconds {
            arguments += ["-ss", String(format: "%.6f", startSeconds)]
        }
        arguments += [
            "-i", url.path,
            "-an", "-vf", filter, "-pix_fmt", outputPixelFormat, "-frames:v", String(maxFrames),
            "-f", "rawvideo", "pipe:1"
        ]
        process.arguments = arguments
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle(forWritingAtPath: "/dev/null")
        try process.run()
        defer {
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
        }

        let frameBytes = isP010
            ? proxyWidth * proxyHeight * 2 + proxyWidth * max(1, proxyHeight / 2) * 2
            : proxyWidth * proxyHeight + proxyWidth * max(1, proxyHeight / 2)
        let outputFPSForTimestamp = max(outputFPS, validationSemantics.minimumTemporalFPS)
        var samples: [FrameSample] = []
        var index = 0
        while let data = try readExactly(stdout.fileHandleForReading, count: frameBytes) {
            guard data.count == frameBytes else {
                process.terminate()
                throw CalibrationError.decodeFailed("ffmpeg returned a truncated raw frame for \(url.lastPathComponent)")
            }
            let pixelBuffer = try makePixelBuffer(
                data: data,
                width: proxyWidth,
                height: proxyHeight,
                pixelFormat: pixelFormat,
                color: color
            )
            let seconds = samplingSemantics.timestamp(
                startSeconds: startSeconds ?? 0,
                outputIndex: index,
                outputFPS: outputFPSForTimestamp
            )
            let timestamp = CMTime(seconds: seconds, preferredTimescale: samplingSemantics.timestampTimescale)
            let grid = try OfflinePixelSampler.lumaGrid(
                pixelBuffer: pixelBuffer,
                width: descriptorSemantics.gridWidth,
                height: descriptorSemantics.gridHeight,
                colorScience: colorScience
            )
            let descriptor = FrameDescriptorBuilder.make(
                timestamp: timestamp,
                lumaGrid: grid,
                configuration: descriptorSemantics
            )
            guard let sourceFrameIndex = FrameReader.sourceFrameIndex(
                startSeconds: startSeconds ?? 0,
                outputIndex: index,
                outputFramesPerSecond: outputFPSForTimestamp,
                sourceFramesPerSecond: nominalFrameRate,
                samplingSemantics: samplingSemantics
            ) else {
                throw CalibrationError.decodeFailed(
                    "ffmpeg source position exceeds the supported timeline"
                )
            }
            samples.append(FrameSample(
                index: sourceFrameIndex,
                sequencePosition: index,
                timestamp: timestamp,
                pixelBuffer: pixelBuffer,
                descriptor: descriptor,
                lumaGrid: grid
            ))
            index += 1
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0, !samples.isEmpty else {
            throw CalibrationError.decodeFailed("ffmpeg could not decode \(url.lastPathComponent)")
        }
        return FrameSequence(
            url: url,
            pixelFormat: pixelFormat,
            width: proxyWidth,
            height: proxyHeight,
            nominalFrameRate: nominalFrameRate,
            durationSeconds: durationSeconds,
            samples: samples
        )
    }

    private static func readExactly(_ handle: FileHandle, count: Int) throws -> Data? {
        var data = Data()
        data.reserveCapacity(count)
        while data.count < count {
            guard let chunk = try handle.read(upToCount: count - data.count), !chunk.isEmpty else { break }
            data.append(chunk)
        }
        return data.isEmpty ? nil : data
    }

    private static func makePixelBuffer(
        data: Data,
        width: Int,
        height: Int,
        pixelFormat: OSType,
        color: FFmpegProxyColorMetadata
    ) throws -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        let attributes: CFDictionary = [
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ] as CFDictionary
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, pixelFormat, attributes, &pixelBuffer)
        guard status == kCVReturnSuccess, let pixelBuffer else {
            throw CalibrationError.decodeFailed("could not allocate offline pixel buffer")
        }
        try color.apply(to: pixelBuffer)
        guard CVPixelBufferLockBaseAddress(pixelBuffer, []) == kCVReturnSuccess else {
            throw CalibrationError.decodeFailed("could not lock offline pixel buffer")
        }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        let bytesPerSample = pixelFormat == CalibrationPixelFormat.hdrP010 ? 2 : 1
        let yBytes = width * height * bytesPerSample
        guard data.count == yBytes + width * (height / 2) * bytesPerSample,
              CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) != nil,
              CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1) != nil else {
            throw CalibrationError.decodeFailed("invalid raw frame or missing proxy planes")
        }
        if let yBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) {
            let destinationRowBytes = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
            data.withUnsafeBytes { source in
                for row in 0..<height {
                    let sourceOffset = row * width * bytesPerSample
                    let destination = yBase.advanced(by: row * destinationRowBytes)
                    destination.copyMemory(from: source.baseAddress!.advanced(by: sourceOffset), byteCount: width * bytesPerSample)
                }
            }
        }
        if let uvBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1) {
            let uvHeight = max(1, height / 2)
            let uvBytesPerRow = width * bytesPerSample
            let destinationRowBytes = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1)
            data.withUnsafeBytes { source in
                for row in 0..<uvHeight {
                    let sourceOffset = yBytes + row * uvBytesPerRow
                    let destination = uvBase.advanced(by: row * destinationRowBytes)
                    destination.copyMemory(from: source.baseAddress!.advanced(by: sourceOffset), byteCount: uvBytesPerRow)
                }
            }
        }
        return pixelBuffer
    }
}

public enum OfflinePixelSampler {
    public static func lumaGrid(
        pixelBuffer: CVPixelBuffer,
        width: Int,
        height: Int,
        colorScience: HDRColorScienceSemanticDefinition = .calibrationV4
    ) throws -> [Float] {
        guard width > 0, height > 0 else { throw CalibrationError.decodeFailed("invalid proxy size") }
        let pixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer)
        let isP010 = pixelFormat == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange ||
            pixelFormat == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
        let isNV12 = pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ||
            pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        var result = [Float](repeating: 0, count: width * height)
        let sourceWidth = max(1, CVPixelBufferGetWidth(pixelBuffer))
        let sourceHeight = max(1, CVPixelBufferGetHeight(pixelBuffer))
        if isNV12 || isP010 {
            guard let base = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) else {
                throw CalibrationError.decodeFailed("missing luma plane")
            }
            let rowBytes = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
            for y in 0..<height {
                let sourceY = min(sourceHeight - 1, y * sourceHeight / height)
                for x in 0..<width {
                    let sourceX = min(sourceWidth - 1, x * sourceWidth / width)
                    let value: Float
                    if isP010 {
                        let row = base.advanced(by: sourceY * rowBytes).assumingMemoryBound(to: UInt16.self)
                        let code = Float(row[sourceX] >> colorScience.yCbCr.p010RightShift)
                        let full = pixelFormat == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
                        let y = full
                            ? code / Float(colorScience.yCbCr.fullRange10Denominator)
                            : (code - Float(colorScience.yCbCr.videoRange10LumaOffset)) /
                                Float(colorScience.yCbCr.videoRange10LumaDenominator)
                        value = min(max(y, 0), 1)
                    } else {
                        let row = base.advanced(by: sourceY * rowBytes).assumingMemoryBound(to: UInt8.self)
                        let code = Float(row[sourceX])
                        let full = pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
                        let y = full
                            ? code / Float(colorScience.yCbCr.fullRange8Denominator)
                            : (code - Float(colorScience.yCbCr.videoRange8LumaOffset)) /
                                Float(colorScience.yCbCr.videoRange8LumaDenominator)
                        value = min(max(y, 0), 1)
                    }
                    result[y * width + x] = value
                }
            }
            return result
        }
        guard pixelFormat == kCVPixelFormatType_32BGRA,
              let base = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            throw CalibrationError.decodeFailed("unsupported proxy pixel format \(pixelFormat)")
        }
        let rowBytes = CVPixelBufferGetBytesPerRow(pixelBuffer)
        for y in 0..<height {
            let sourceY = min(sourceHeight - 1, y * sourceHeight / height)
            let row = base.advanced(by: sourceY * rowBytes).assumingMemoryBound(to: UInt8.self)
            for x in 0..<width {
                let sourceX = min(sourceWidth - 1, x * sourceWidth / width)
                let offset = sourceX * 4
                let blue = Float(row[offset]) / 255
                let green = Float(row[offset + 1]) / 255
                let red = Float(row[offset + 2]) / 255
                let coefficients = colorScience.yCbCr.bgraBT709Luminance
                result[y * width + x] = Float(coefficients[0]) * red +
                    Float(coefficients[1]) * green + Float(coefficients[2]) * blue
            }
        }
        return result
    }

    /// Returns the same linear BT.709 luminance domain consumed by the SDR to
    /// HDR shader. `lumaGrid` is intentionally an encoded Y proxy for frame
    /// matching; diagnostic attribution must use this method instead so its
    /// bins and scalar tone-curve contributions are in the shader's domain.
    public static func linearLumaGrid(
        pixelBuffer: CVPixelBuffer,
        width: Int,
        height: Int,
        interpretationPolicy: SDRInputInterpretationPolicy = .bt709SourceLinear,
        untaggedFallback: SDRUntaggedFallbackPolicy = .assumeBT709SourceLinear,
        bt1886Parameters: BT1886TransferParameters = .idealReference,
        colorScience: HDRColorScienceSemanticDefinition = .calibrationV4
    ) throws -> [Float] {
        guard width > 0, height > 0 else { throw CalibrationError.decodeFailed("invalid proxy size") }
        let pixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer)
        let isP010 = pixelFormat == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange ||
            pixelFormat == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
        let isNV12 = pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ||
            pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        let isFullRange = pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange ||
            pixelFormat == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
        let metadata = try HDRInputMetadata.resolve(
            pixelBuffer: pixelBuffer,
            fallbackPolicy: isFullRange || pixelFormat == kCVPixelFormatType_32BGRA
                ? .bt709FullRange : .bt709VideoRange,
            interpretationPolicy: interpretationPolicy,
            untaggedFallback: untaggedFallback,
            bt1886Parameters: bt1886Parameters
        )
        let matrix = metadata.yCbCrMatrix

        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        let sourceWidth = max(1, CVPixelBufferGetWidth(pixelBuffer))
        let sourceHeight = max(1, CVPixelBufferGetHeight(pixelBuffer))
        var result = [Float](repeating: 0, count: width * height)

        func inverse(_ value: Float) -> Float {
            HDRColorMath.inverseTransfer(
                min(max(value, 0), 1),
                function: metadata.transferFunction,
                colorScience: colorScience
            )
        }

        func linearLuminance(y: Float, cb: Float, cr: Float) -> Float {
            let converted = colorScience.yCbCr.rgb(
                from: matrix, y: Double(y), cb: Double(cb), cr: Double(cr)
            )
            let rgb = SIMD3<Float>(
                Float(converted.0), Float(converted.1), Float(converted.2)
            )
            let linear = SIMD3(inverse(rgb.x), inverse(rgb.y), inverse(rgb.z))
            let coefficients = SIMD3<Float>(
                Float(colorScience.yCbCr.bt709Luminance[0]),
                Float(colorScience.yCbCr.bt709Luminance[1]),
                Float(colorScience.yCbCr.bt709Luminance[2])
            )
            return max(simd_dot(linear, coefficients), 0)
        }

        if isNV12 || isP010 {
            guard let yBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0),
                  let uvBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1) else {
                throw CalibrationError.decodeFailed("missing YUV plane")
            }
            let yRowBytes = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
            let uvRowBytes = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1)
            let uvWidth = max(1, CVPixelBufferGetWidthOfPlane(pixelBuffer, 1))
            let uvHeight = max(1, CVPixelBufferGetHeightOfPlane(pixelBuffer, 1))
            for y in 0..<height {
                let sourceY = min(sourceHeight - 1, y * sourceHeight / height)
                let uvY = min(uvHeight - 1, sourceY / 2)
                for x in 0..<width {
                    let sourceX = min(sourceWidth - 1, x * sourceWidth / width)
                    let uvX = min(uvWidth - 1, sourceX / 2)
                    let ySignal: Float
                    let cbSignal: Float
                    let crSignal: Float
                    if isP010 {
                        let yRow = yBase.advanced(by: sourceY * yRowBytes).assumingMemoryBound(to: UInt16.self)
                        let uvRow = uvBase.advanced(by: uvY * uvRowBytes).assumingMemoryBound(to: UInt16.self)
                        let rightShift = colorScience.yCbCr.p010RightShift
                        let yCode = Float(yRow[sourceX] >> rightShift)
                        let cbCode = Float(uvRow[uvX * 2] >> rightShift)
                        let crCode = Float(uvRow[uvX * 2 + 1] >> rightShift)
                        ySignal = isFullRange
                            ? yCode / Float(colorScience.yCbCr.fullRange10Denominator)
                            : min(max(
                                (yCode - Float(colorScience.yCbCr.videoRange10LumaOffset)) /
                                    Float(colorScience.yCbCr.videoRange10LumaDenominator), 0
                            ), 1)
                        let chromaScale: Float = isFullRange
                            ? 1
                            : Float(colorScience.yCbCr.fullRange10Denominator) /
                                Float(colorScience.yCbCr.videoRange10ChromaDenominator)
                        cbSignal = (
                            cbCode / Float(colorScience.yCbCr.fullRange10Denominator) -
                                Float(colorScience.yCbCr.videoRange10ChromaCenter) /
                                    Float(colorScience.yCbCr.fullRange10Denominator)
                        ) * chromaScale
                        crSignal = (
                            crCode / Float(colorScience.yCbCr.fullRange10Denominator) -
                                Float(colorScience.yCbCr.videoRange10ChromaCenter) /
                                    Float(colorScience.yCbCr.fullRange10Denominator)
                        ) * chromaScale
                    } else {
                        let yRow = yBase.advanced(by: sourceY * yRowBytes).assumingMemoryBound(to: UInt8.self)
                        let uvRow = uvBase.advanced(by: uvY * uvRowBytes).assumingMemoryBound(to: UInt8.self)
                        let yCode = Float(yRow[sourceX])
                        let cbCode = Float(uvRow[uvX * 2])
                        let crCode = Float(uvRow[uvX * 2 + 1])
                        ySignal = isFullRange
                            ? yCode / Float(colorScience.yCbCr.fullRange8Denominator)
                            : min(max(
                                (yCode - Float(colorScience.yCbCr.videoRange8LumaOffset)) /
                                    Float(colorScience.yCbCr.videoRange8LumaDenominator), 0
                            ), 1)
                        let chromaScale: Float = isFullRange
                            ? 1
                            : Float(colorScience.yCbCr.fullRange8Denominator) /
                                Float(colorScience.yCbCr.videoRange8ChromaDenominator)
                        cbSignal = (
                            cbCode / Float(colorScience.yCbCr.fullRange8Denominator) -
                                Float(colorScience.yCbCr.videoRange8ChromaCenter) /
                                    Float(colorScience.yCbCr.fullRange8Denominator)
                        ) * chromaScale
                        crSignal = (
                            crCode / Float(colorScience.yCbCr.fullRange8Denominator) -
                                Float(colorScience.yCbCr.videoRange8ChromaCenter) /
                                    Float(colorScience.yCbCr.fullRange8Denominator)
                        ) * chromaScale
                    }
                    result[y * width + x] = linearLuminance(y: ySignal, cb: cbSignal, cr: crSignal)
                }
            }
            return result
        }

        guard pixelFormat == kCVPixelFormatType_32BGRA,
              let base = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            throw CalibrationError.decodeFailed("unsupported proxy pixel format \(pixelFormat)")
        }
        let rowBytes = CVPixelBufferGetBytesPerRow(pixelBuffer)
        for y in 0..<height {
            let sourceY = min(sourceHeight - 1, y * sourceHeight / height)
            let row = base.advanced(by: sourceY * rowBytes).assumingMemoryBound(to: UInt8.self)
            for x in 0..<width {
                let sourceX = min(sourceWidth - 1, x * sourceWidth / width)
                let offset = sourceX * 4
                let rgb = SIMD3(
                    inverse(Float(row[offset + 2]) / 255),
                    inverse(Float(row[offset + 1]) / 255),
                    inverse(Float(row[offset]) / 255)
                )
                let coefficients = SIMD3<Float>(
                    Float(colorScience.yCbCr.bt709Luminance[0]),
                    Float(colorScience.yCbCr.bt709Luminance[1]),
                    Float(colorScience.yCbCr.bt709Luminance[2])
                )
                result[y * width + x] = max(simd_dot(rgb, coefficients), 0)
            }
        }
        return result
    }

    public static func chromaMagnitude(
        pixelBuffer: CVPixelBuffer,
        configuration: V6RepresentativeFrameSemanticConfiguration = .v6,
        colorScience: HDRColorScienceSemanticDefinition = .calibrationV4
    ) -> Float {
        let format = CVPixelBufferGetPixelFormatType(pixelBuffer)
        let isP010 = format == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange ||
            format == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
        let isNV12 = format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ||
            format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        guard isNV12 || isP010 else { return 0 }
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1) else { return 0 }
        let width = CVPixelBufferGetWidthOfPlane(pixelBuffer, 1)
        let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, 1)
        let rowBytes = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1)
        let ycbcr = colorScience.yCbCr
        let isFullRange = format == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange ||
            format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        let p010ChromaDenominator = isFullRange
            ? ycbcr.fullRange10Denominator
            : ycbcr.videoRange10ChromaDenominator
        let nv12ChromaDenominator = isFullRange
            ? ycbcr.fullRange8Denominator
            : ycbcr.videoRange8ChromaDenominator
        let stepX = max(1, width / configuration.chromaSampleGridWidth)
        let stepY = max(1, height / configuration.chromaSampleGridHeight)
        var total: Float = 0
        var count = 0
        for y in stride(from: 0, to: height, by: stepY) {
            if isP010 {
                let row = base.advanced(by: y * rowBytes).assumingMemoryBound(to: UInt16.self)
                for x in stride(from: 0, to: width, by: stepX) {
                    let rightShift = ycbcr.p010RightShift
                    let cb = (Float(row[x * 2] >> rightShift) - Float(ycbcr.videoRange10ChromaCenter)) /
                        Float(p010ChromaDenominator)
                    let cr = (Float(row[x * 2 + 1] >> rightShift) - Float(ycbcr.videoRange10ChromaCenter)) /
                        Float(p010ChromaDenominator)
                    total += hypot(cb, cr)
                    count += 1
                }
            } else {
                let row = base.advanced(by: y * rowBytes).assumingMemoryBound(to: UInt8.self)
                for x in stride(from: 0, to: width, by: stepX) {
                    let cb = (Float(row[x * 2]) - Float(ycbcr.videoRange8ChromaCenter)) /
                        Float(nv12ChromaDenominator)
                    let cr = (Float(row[x * 2 + 1]) - Float(ycbcr.videoRange8ChromaCenter)) /
                        Float(nv12ChromaDenominator)
                    total += hypot(cb, cr)
                    count += 1
                }
            }
        }
        return count > 0 ? total / Float(count) : 0
    }
}

public enum FrameDescriptorBuilder {
    public static func downsample(
        _ values: [Float],
        sourceWidth: Int,
        sourceHeight: Int,
        width: Int,
        height: Int
    ) -> [Float] {
        guard sourceWidth > 0, sourceHeight > 0, width > 0, height > 0, !values.isEmpty else { return [] }
        return (0..<height).flatMap { y in
            (0..<width).map { x in
                let sourceX = min(sourceWidth - 1, x * sourceWidth / width)
                let sourceY = min(sourceHeight - 1, y * sourceHeight / height)
                return values[min(values.count - 1, sourceY * sourceWidth + sourceX)]
            }
        }
    }

    public static func make(
        timestamp: CMTime,
        lumaGrid: [Float],
        configuration: V6DescriptorSemanticConfiguration = .v6
    ) -> FrameDescriptor {
        let finite = lumaGrid.filter(\.isFinite)
        let mean = finite.isEmpty ? 0 : finite.reduce(0, +) / Float(finite.count)
        let variance = finite.isEmpty ? 0 : finite.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Float(finite.count)
        let histogram = makeHistogram(finite, configuration: configuration)
        var edgeEnergy: Float = 0
        let width = configuration.gridWidth
        let algorithm = configuration.algorithmSemantics
        let height = max(algorithm.edgeEnergyMinimumHeight, lumaGrid.count / max(width, 1))
        if width >= algorithm.edgeEnergyMinimumWidth, height >= algorithm.edgeEnergyMinimumHeight {
            for y in 0..<(height - 1) {
                for x in 0..<(width - 1) {
                    let index = y * width + x
                    edgeEnergy += abs(lumaGrid[index + 1] - lumaGrid[index])
                    edgeEnergy += abs(lumaGrid[index + width] - lumaGrid[index])
                }
            }
            edgeEnergy /= Float((width - 1) * (height - 1) * algorithm.edgeEnergyComponentsPerCell)
        }
        return FrameDescriptor(
            timestampSeconds: timestamp.isNumeric ? timestamp.seconds : 0,
            meanLuma: mean,
            variance: variance,
            histogram: histogram,
            edgeEnergy: edgeEnergy
        )
    }

    public static func distance(
        _ lhs: FrameDescriptor,
        _ rhs: FrameDescriptor,
        configuration: V6DescriptorSemanticConfiguration = .v6
    ) -> Double {
        let histogramDistance = zip(lhs.histogram, rhs.histogram).reduce(0) { $0 + abs(Double($1.0 - $1.1)) }
        let meanDistance = abs(Double(lhs.meanLuma - rhs.meanLuma))
        let varianceDistance = abs(Double(lhs.variance - rhs.variance))
        let edgeDistance = abs(Double(lhs.edgeEnergy - rhs.edgeEnergy))
        return histogramDistance * configuration.distanceWeights[0] +
            meanDistance * configuration.distanceWeights[1] +
            varianceDistance * configuration.distanceWeights[2] +
            edgeDistance * configuration.distanceWeights[3]
    }

    /// Alignment-only distance. SDR and HLG/PQ versions of the same frame
    /// are expected to have different code-value brightness. Comparing a
    /// freely shifted histogram plus normalized low-frequency statistics is
    /// therefore safer than using encoded luma bins directly.
    public static func alignmentDistance(
        _ lhs: FrameDescriptor,
        _ rhs: FrameDescriptor,
        configuration: V6DescriptorSemanticConfiguration = .v6
    ) -> Double {
        let histogramDistance = shiftedHistogramDistance(lhs.histogram, rhs.histogram, configuration: configuration)
        let meanDistance = boundedLogDistance(lhs.meanLuma, rhs.meanLuma, configuration: configuration)
        let varianceDistance = boundedLogDistance(lhs.variance, rhs.variance, configuration: configuration)
        let edgeDistance = boundedLogDistance(lhs.edgeEnergy, rhs.edgeEnergy, configuration: configuration)
        return histogramDistance * configuration.alignmentDistanceWeights[0] +
            meanDistance * configuration.alignmentDistanceWeights[1] +
            varianceDistance * configuration.alignmentDistanceWeights[2] +
            edgeDistance * configuration.alignmentDistanceWeights[3]
    }

    /// Adds a spatial rank/contrast signature when the proxy grids are
    /// available. Pearson correlation is intentionally used here instead of
    /// encoded-luma subtraction because the SDR and HLG masters can apply
    /// different monotonic tone curves.
    public static func alignmentDistance(
        _ lhs: FrameDescriptor,
        _ rhs: FrameDescriptor,
        lhsGrid: [Float],
        rhsGrid: [Float],
        configuration: V6DescriptorSemanticConfiguration = .v6
    ) -> Double {
        let histogramDistance = shiftedHistogramDistance(lhs.histogram, rhs.histogram, configuration: configuration)
        let meanDistance = boundedLogDistance(lhs.meanLuma, rhs.meanLuma, configuration: configuration)
        let varianceDistance = boundedLogDistance(lhs.variance, rhs.variance, configuration: configuration)
        let edgeDistance = boundedLogDistance(lhs.edgeEnergy, rhs.edgeEnergy, configuration: configuration)
        let spatialDistance = gridCorrelationDistance(lhsGrid, rhsGrid, configuration: configuration)
        return spatialDistance * configuration.spatialAlignmentDistanceWeights[0] +
            histogramDistance * configuration.spatialAlignmentDistanceWeights[1] +
            meanDistance * configuration.spatialAlignmentDistanceWeights[2] +
            varianceDistance * configuration.spatialAlignmentDistanceWeights[3] +
            edgeDistance * configuration.spatialAlignmentDistanceWeights[4]
    }

    private static func shiftedHistogramDistance(
        _ lhs: [Float],
        _ rhs: [Float],
        configuration: V6DescriptorSemanticConfiguration
    ) -> Double {
        guard !lhs.isEmpty, !rhs.isEmpty else { return configuration.emptyHistogramDistance }
        var best = Double.greatestFiniteMagnitude
        for shift in configuration.histogramShiftMinimum...configuration.histogramShiftMaximum {
            var distance = 0.0
            for index in lhs.indices {
                let rhsIndex = index + shift
                let rhsValue = rhs.indices.contains(rhsIndex)
                    ? rhs[rhsIndex]
                    : Float(configuration.algorithmSemantics.histogramOutOfBoundsValue)
                distance += abs(Double(lhs[index] - rhsValue))
            }
            best = min(best, distance)
        }
        return min(best, configuration.emptyHistogramDistance)
    }

    private static func boundedLogDistance(
        _ lhs: Float,
        _ rhs: Float,
        configuration: V6DescriptorSemanticConfiguration
    ) -> Double {
        let left = max(Double(lhs), configuration.boundedLogFloor)
        let right = max(Double(rhs), configuration.boundedLogFloor)
        return min(abs(log(left / right)), configuration.emptyHistogramDistance)
    }

    private static func gridCorrelationDistance(
        _ lhs: [Float],
        _ rhs: [Float],
        configuration: V6DescriptorSemanticConfiguration
    ) -> Double {
        let algorithm = configuration.algorithmSemantics
        guard lhs.count == rhs.count,
              lhs.count >= algorithm.minimumCorrelationSampleCount else {
            return configuration.degenerateCorrelationDistance
        }
        let leftMean = lhs.reduce(0, +) / Float(lhs.count)
        let rightMean = rhs.reduce(0, +) / Float(rhs.count)
        var numerator = 0.0
        var leftVariance = 0.0
        var rightVariance = 0.0
        for index in lhs.indices {
            let left = Double(lhs[index] - leftMean)
            let right = Double(rhs[index] - rightMean)
            numerator += left * right
            leftVariance += left * left
            rightVariance += right * right
        }
        let denominator = sqrt(leftVariance * rightVariance)
        guard denominator > configuration.gridCorrelationEpsilon else {
            return configuration.degenerateCorrelationDistance
        }
        let correlation = max(configuration.correlationLowerBound,
            min(configuration.correlationUpperBound, numerator / denominator))
        return (1 - correlation) * algorithm.correlationDistanceScale
    }

    private static func makeHistogram(
        _ values: [Float],
        configuration: V6DescriptorSemanticConfiguration
    ) -> [Float] {
        guard !values.isEmpty else {
            return Array(
                repeating: Float(configuration.algorithmSemantics.emptyHistogramBinValue),
                count: configuration.histogramBinCount
            )
        }
        var histogram = Array(repeating: Float(0), count: configuration.histogramBinCount)
        for value in values {
            let normalized = min(
                max(Double(value), configuration.algorithmSemantics.histogramValueMinimum),
                configuration.algorithmSemantics.histogramValueMaximum
            )
            let index = min(
                configuration.histogramBinCount - 1,
                max(0, Int(normalized * Double(configuration.histogramBinCount)))
            )
            histogram[index] += 1
        }
        let count = Float(values.count)
        return histogram.map { $0 / count }
    }
}
