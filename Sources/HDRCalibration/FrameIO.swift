@preconcurrency import AVFoundation
import CoreMedia
import CoreVideo
import Foundation

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
        sourceFramesPerSecond: Double
    ) -> Int? {
        guard startSeconds.isFinite,
              startSeconds >= 0,
              outputIndex >= 0,
              outputFramesPerSecond.isFinite,
              outputFramesPerSecond > 0,
              sourceFramesPerSecond.isFinite,
              sourceFramesPerSecond > 0 else {
            return nil
        }

        let sourceRate = max(
            sourceFramesPerSecond,
            outputFramesPerSecond
        )
        let startPosition = startSeconds * sourceRate
        let sourceStep = sourceRate / outputFramesPerSecond
        let position = startPosition + Double(outputIndex) * sourceStep

        guard position.isFinite,
              position >= 0,
              position <= Double(Int32.max) else {
            return nil
        }

        return Int(position.rounded())
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
        proxyWidth: Int = 320
    ) async throws -> FrameSequence {
        guard (1...512).contains(frameCount),
              (16...512).contains(proxyWidth),
              isSupported(pixelFormat: pixelFormat),
              startSeconds.isFinite,
              framesPerSecond.isFinite,
              framesPerSecond >= 0.001,
              framesPerSecond <= 1_000 else {
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
        let metadata = try validatedMetadata(
            naturalSize: naturalSize,
            nominalFrameRate: nominal,
            duration: duration,
            proxyWidth: proxyWidth,
            url: url
        )
        let sourcePosition = max(startSeconds, 0) * max(metadata.nominalFrameRate, framesPerSecond)
        guard sourcePosition.isFinite, sourcePosition <= Double(Int32.max) else {
            throw CalibrationError.decodeFailed(
                "window decode start exceeds the supported source timeline"
            )
        }
        return try FFmpegFrameReader.read(
            url: url,
            pixelFormat: pixelFormat,
            maxFrames: frameCount,
            proxyWidth: proxyWidth,
            sourceWidth: metadata.sourceWidth,
            sourceHeight: metadata.sourceHeight,
            nominalFrameRate: metadata.nominalFrameRate,
            durationSeconds: metadata.durationSeconds,
            startSeconds: max(startSeconds, 0),
            samplingFPS: min(framesPerSecond, metadata.nominalFrameRate > 0 ? metadata.nominalFrameRate : framesPerSecond)
        )
    }

    public static func read(
        url: URL,
        pixelFormat: OSType,
        maxFrames: Int = 240,
        proxyWidth: Int = 320
    ) async throws -> FrameSequence {
        guard (1...512).contains(maxFrames),
              (16...512).contains(proxyWidth),
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
            url: url
        )
        let formatDescriptions = try await track.load(.formatDescriptions)
        let codec = formatDescriptions.first.map { fourCC(CMFormatDescriptionGetMediaSubType($0)) }
        if codec == "vp09" || codec == "av01" {
            return try FFmpegFrameReader.read(
                url: url,
                pixelFormat: pixelFormat,
                maxFrames: maxFrames,
                proxyWidth: proxyWidth,
                sourceWidth: metadata.sourceWidth,
                sourceHeight: metadata.sourceHeight,
                nominalFrameRate: metadata.nominalFrameRate,
                durationSeconds: metadata.durationSeconds
            )
        }
        let estimatedFrames = metadata.nominalFrameRate > 0 && metadata.durationSeconds > 0
            ? metadata.durationSeconds * metadata.nominalFrameRate
            : Double(maxFrames)
        let strideValue = ceil(estimatedFrames / Double(maxFrames))
        guard strideValue.isFinite, strideValue <= Double(Int32.max) else {
            throw CalibrationError.decodeFailed(
                "video timeline exceeds the supported proxy sampling range"
            )
        }
        let stride = max(1, Int(strideValue))
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
            return try FFmpegFrameReader.read(
                url: url,
                pixelFormat: pixelFormat,
                maxFrames: maxFrames,
                proxyWidth: proxyWidth,
                sourceWidth: metadata.sourceWidth,
                sourceHeight: metadata.sourceHeight,
                nominalFrameRate: metadata.nominalFrameRate,
                durationSeconds: metadata.durationSeconds
            )
        }

        var samples: [FrameSample] = []
        var frameIndex = 0
        while let sampleBuffer = output.copyNextSampleBuffer() {
            defer { frameIndex += 1 }
            guard frameIndex % stride == 0,
                  let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { continue }
            let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            let grid = try OfflinePixelSampler.lumaGrid(pixelBuffer: pixelBuffer, width: 64, height: 36)
            let descriptor = FrameDescriptorBuilder.make(timestamp: timestamp, lumaGrid: grid)
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
            return try FFmpegFrameReader.read(
                url: url,
                pixelFormat: pixelFormat,
                maxFrames: maxFrames,
                proxyWidth: proxyWidth,
                sourceWidth: metadata.sourceWidth,
                sourceHeight: metadata.sourceHeight,
                nominalFrameRate: metadata.nominalFrameRate,
                durationSeconds: metadata.durationSeconds
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
        url: URL
    ) throws -> ValidatedVideoMetadata {
        let durationSeconds = duration.isNumeric ? duration.seconds : 0
        guard naturalSize.width.isFinite,
              naturalSize.height.isFinite,
              naturalSize.width > 0,
              naturalSize.height > 0,
              naturalSize.width <= 65_536,
              naturalSize.height <= 65_536,
              nominalFrameRate.isFinite,
              (0...1_000).contains(nominalFrameRate),
              durationSeconds.isFinite,
              durationSeconds >= 0 else {
            throw CalibrationError.decodeFailed(
                "video metadata is invalid or unsafe: \(url.lastPathComponent)"
            )
        }

        let sourceWidth = Int(naturalSize.width.rounded())
        let sourceHeight = Int(naturalSize.height.rounded())
        let scaledHeight = Double(proxyWidth) * Double(sourceHeight) / Double(sourceWidth)
        guard scaledHeight.isFinite, scaledHeight > 0, scaledHeight <= 4_096 else {
            throw CalibrationError.decodeFailed(
                "video aspect ratio produces an unsafe proxy size: \(url.lastPathComponent)"
            )
        }
        let proxyHeight = max(2, Int(scaledHeight.rounded()) / 2 * 2)
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

private enum FFmpegFrameReader {
    static func read(
        url: URL,
        pixelFormat: OSType,
        maxFrames: Int,
        proxyWidth: Int,
        sourceWidth: Int,
        sourceHeight: Int,
        nominalFrameRate: Double,
        durationSeconds: Double,
        startSeconds: Double? = nil,
        samplingFPS: Double? = nil
    ) throws -> FrameSequence {
        guard let executable = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg"].first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw CalibrationError.decodeFailed("AVAssetReader failed and ffmpeg fallback is unavailable")
        }
        let isP010 = pixelFormat == CalibrationPixelFormat.hdrP010
        let proxyHeight = max(2, Int((Double(proxyWidth) * Double(sourceHeight) / Double(max(sourceWidth, 1))).rounded() / 2) * 2)
        let outputPixelFormat = isP010 ? "p010le" : "nv12"
        let distributedFPS = durationSeconds > 0
            ? max(0.25, Double(maxFrames) / durationSeconds)
            : max(nominalFrameRate, 1)
        let requestedFPS = samplingFPS ?? distributedFPS
        let outputFPS = nominalFrameRate > 0
            ? min(requestedFPS, nominalFrameRate)
            : min(requestedFPS, 1_000)
        guard outputFPS.isFinite,
              outputFPS >= 0.001,
              outputFPS <= 1_000,
              proxyHeight <= 4_096 else {
            throw CalibrationError.decodeFailed(
                "ffmpeg proxy rate or dimensions exceed safe bounds"
            )
        }
        let filter = "fps=\(String(format: "%.6f", outputFPS)):round=up,scale=\(proxyWidth):\(proxyHeight):flags=bicubic"
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
        let outputFPSForTimestamp = max(outputFPS, 0.001)
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
                isHDR: isP010
            )
            let seconds = (startSeconds ?? 0) + Double(index) / outputFPSForTimestamp
            let timestamp = CMTime(seconds: seconds, preferredTimescale: 1_000)
            let grid = try OfflinePixelSampler.lumaGrid(pixelBuffer: pixelBuffer, width: 64, height: 36)
            let descriptor = FrameDescriptorBuilder.make(timestamp: timestamp, lumaGrid: grid)
            guard let sourceFrameIndex = FrameReader.sourceFrameIndex(
                startSeconds: startSeconds ?? 0,
                outputIndex: index,
                outputFramesPerSecond: outputFPSForTimestamp,
                sourceFramesPerSecond: max(
                    nominalFrameRate,
                    outputFPSForTimestamp
                )
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
        isHDR: Bool
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
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        let bytesPerSample = isHDR ? 2 : 1
        let yBytes = width * height * bytesPerSample
        guard data.count >= yBytes else { throw CalibrationError.decodeFailed("short raw frame") }
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
        CVBufferSetAttachment(
            pixelBuffer,
            kCVImageBufferColorPrimariesKey,
            isHDR ? kCVImageBufferColorPrimaries_ITU_R_2020 : kCVImageBufferColorPrimaries_ITU_R_709_2,
            .shouldPropagate
        )
        CVBufferSetAttachment(
            pixelBuffer,
            kCVImageBufferTransferFunctionKey,
            isHDR ? kCVImageBufferTransferFunction_ITU_R_2100_HLG : kCVImageBufferTransferFunction_ITU_R_709_2,
            .shouldPropagate
        )
        CVBufferSetAttachment(
            pixelBuffer,
            kCVImageBufferYCbCrMatrixKey,
            isHDR ? kCVImageBufferYCbCrMatrix_ITU_R_2020 : kCVImageBufferYCbCrMatrix_ITU_R_709_2,
            .shouldPropagate
        )
        return pixelBuffer
    }
}

public enum OfflinePixelSampler {
    public static func lumaGrid(
        pixelBuffer: CVPixelBuffer,
        width: Int,
        height: Int
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
                        let code = Float(row[sourceX] >> 6)
                        let full = pixelFormat == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
                        value = full ? code / 1023 : min(max((code - 64) / 876, 0), 1)
                    } else {
                        let row = base.advanced(by: sourceY * rowBytes).assumingMemoryBound(to: UInt8.self)
                        let code = Float(row[sourceX])
                        let full = pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
                        value = full ? code / 255 : min(max((code - 16) / 219, 0), 1)
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
                result[y * width + x] = 0.2126 * red + 0.7152 * green + 0.0722 * blue
            }
        }
        return result
    }

    public static func chromaMagnitude(pixelBuffer: CVPixelBuffer) -> Float {
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
        let stepX = max(1, width / 16)
        let stepY = max(1, height / 9)
        var total: Float = 0
        var count = 0
        for y in stride(from: 0, to: height, by: stepY) {
            if isP010 {
                let row = base.advanced(by: y * rowBytes).assumingMemoryBound(to: UInt16.self)
                for x in stride(from: 0, to: width, by: stepX) {
                    let cb = (Float(row[x * 2] >> 6) - 512) / 512
                    let cr = (Float(row[x * 2 + 1] >> 6) - 512) / 512
                    total += hypot(cb, cr)
                    count += 1
                }
            } else {
                let row = base.advanced(by: y * rowBytes).assumingMemoryBound(to: UInt8.self)
                for x in stride(from: 0, to: width, by: stepX) {
                    let cb = (Float(row[x * 2]) - 128) / 128
                    let cr = (Float(row[x * 2 + 1]) - 128) / 128
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

    public static func make(timestamp: CMTime, lumaGrid: [Float]) -> FrameDescriptor {
        let finite = lumaGrid.filter(\.isFinite)
        let mean = finite.isEmpty ? 0 : finite.reduce(0, +) / Float(finite.count)
        let variance = finite.isEmpty ? 0 : finite.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Float(finite.count)
        let histogram = makeHistogram(finite)
        var edgeEnergy: Float = 0
        let width = 64
        let height = max(1, lumaGrid.count / width)
        if width > 1, height > 1 {
            for y in 0..<(height - 1) {
                for x in 0..<(width - 1) {
                    let index = y * width + x
                    edgeEnergy += abs(lumaGrid[index + 1] - lumaGrid[index])
                    edgeEnergy += abs(lumaGrid[index + width] - lumaGrid[index])
                }
            }
            edgeEnergy /= Float((width - 1) * (height - 1) * 2)
        }
        return FrameDescriptor(
            timestampSeconds: timestamp.isNumeric ? timestamp.seconds : 0,
            meanLuma: mean,
            variance: variance,
            histogram: histogram,
            edgeEnergy: edgeEnergy
        )
    }

    public static func distance(_ lhs: FrameDescriptor, _ rhs: FrameDescriptor) -> Double {
        let histogramDistance = zip(lhs.histogram, rhs.histogram).reduce(0) { $0 + abs(Double($1.0 - $1.1)) }
        let meanDistance = abs(Double(lhs.meanLuma - rhs.meanLuma))
        let varianceDistance = abs(Double(lhs.variance - rhs.variance))
        let edgeDistance = abs(Double(lhs.edgeEnergy - rhs.edgeEnergy))
        return histogramDistance * 0.65 + meanDistance * 0.20 + varianceDistance * 0.10 + edgeDistance * 0.05
    }

    /// Alignment-only distance. SDR and HLG/PQ versions of the same frame
    /// are expected to have different code-value brightness. Comparing a
    /// freely shifted histogram plus normalized low-frequency statistics is
    /// therefore safer than using encoded luma bins directly.
    public static func alignmentDistance(_ lhs: FrameDescriptor, _ rhs: FrameDescriptor) -> Double {
        let histogramDistance = shiftedHistogramDistance(lhs.histogram, rhs.histogram)
        let meanDistance = boundedLogDistance(lhs.meanLuma, rhs.meanLuma)
        let varianceDistance = boundedLogDistance(lhs.variance, rhs.variance)
        let edgeDistance = boundedLogDistance(lhs.edgeEnergy, rhs.edgeEnergy)
        return histogramDistance * 0.72 + meanDistance * 0.10 + varianceDistance * 0.10 + edgeDistance * 0.08
    }

    /// Adds a spatial rank/contrast signature when the proxy grids are
    /// available. Pearson correlation is intentionally used here instead of
    /// encoded-luma subtraction because the SDR and HLG masters can apply
    /// different monotonic tone curves.
    public static func alignmentDistance(
        _ lhs: FrameDescriptor,
        _ rhs: FrameDescriptor,
        lhsGrid: [Float],
        rhsGrid: [Float]
    ) -> Double {
        let histogramDistance = shiftedHistogramDistance(lhs.histogram, rhs.histogram)
        let meanDistance = boundedLogDistance(lhs.meanLuma, rhs.meanLuma)
        let varianceDistance = boundedLogDistance(lhs.variance, rhs.variance)
        let edgeDistance = boundedLogDistance(lhs.edgeEnergy, rhs.edgeEnergy)
        let spatialDistance = gridCorrelationDistance(lhsGrid, rhsGrid)
        return spatialDistance * 0.62 + histogramDistance * 0.20 + meanDistance * 0.08 + varianceDistance * 0.05 + edgeDistance * 0.05
    }

    private static func shiftedHistogramDistance(_ lhs: [Float], _ rhs: [Float]) -> Double {
        guard !lhs.isEmpty, !rhs.isEmpty else { return 1 }
        var best = Double.greatestFiniteMagnitude
        for shift in -4...4 {
            var distance = 0.0
            for index in lhs.indices {
                let rhsIndex = index + shift
                let rhsValue = rhs.indices.contains(rhsIndex) ? rhs[rhsIndex] : 0
                distance += abs(Double(lhs[index] - rhsValue))
            }
            best = min(best, distance)
        }
        return min(best, 1)
    }

    private static func boundedLogDistance(_ lhs: Float, _ rhs: Float) -> Double {
        let left = max(Double(lhs), 1e-4)
        let right = max(Double(rhs), 1e-4)
        return min(abs(log(left / right)), 1)
    }

    private static func gridCorrelationDistance(_ lhs: [Float], _ rhs: [Float]) -> Double {
        guard lhs.count == rhs.count, lhs.count > 1 else { return 0.5 }
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
        guard denominator > 1e-9 else { return 0.5 }
        let correlation = max(-1, min(1, numerator / denominator))
        return (1 - correlation) * 0.5
    }

    private static func makeHistogram(_ values: [Float]) -> [Float] {
        guard !values.isEmpty else { return Array(repeating: 0, count: 16) }
        var histogram = Array(repeating: Float(0), count: 16)
        for value in values {
            let index = min(15, max(0, Int(value * 16)))
            histogram[index] += 1
        }
        let count = Float(values.count)
        return histogram.map { $0 / count }
    }
}
