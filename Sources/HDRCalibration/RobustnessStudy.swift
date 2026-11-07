@preconcurrency import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import HDRCore
import Metal
import simd

/// Tune-only robustness study: how SDR degradations (noise, compression,
/// low resolution, banding) change HDRCore's benefit over a no-expansion
/// mapping, and how much of the injected artifact energy the expansion
/// amplifies. All analysis is full resolution in the PQ-encoded domain so
/// differences are perceptually comparable across luminance levels.
///
/// The study never reads Validation or Frozen media: it rejects every pair
/// whose split is not `.tune`.
public enum RobustnessStudy {
    public struct Variant: Codable, Sendable {
        public let id: String
        public let description: String
        /// ffmpeg -vf chain applied to the clean 8-bit working clip.
        public let filter: String?
        /// x264 CRF when the variant is a compression round trip.
        public let x264CRF: Int?
    }

    /// V4 plus noise-gated gain guidance over radius and tolerance (signal units;
    /// one 8-bit code is ~0.0046 after video-range scaling).
    public static let defaultGuidanceCandidates: [(String, HDRGainGuidance)] = [
        ("v4-guided-r2-t0.05", HDRGainGuidance(radius: 2, tolerance: 0.05)),
        ("v4-guided-r2-t0.08", HDRGainGuidance(radius: 2, tolerance: 0.08)),
        ("v4-guided-r2-t0.12", HDRGainGuidance(radius: 2, tolerance: 0.12)),
        ("v4-guided-r3-t0.08", HDRGainGuidance(radius: 3, tolerance: 0.08))
    ]

    /// Noise-adaptive guidance: tolerance = clamp(k * sigma, min, max), with
    /// sigma the clip's Immerkaer luma noise estimate (signal units). Clean
    /// sources get a small tolerance (texture keeps the curve's expansion),
    /// noisy sources a large one (grain keeps its source contrast).
    public struct AdaptiveGuidance: Codable, Sendable, Equatable {
        public let id: String
        public let radius: Int
        public let k: Double
        public let minimumTolerance: Double
        public let maximumTolerance: Double
        /// Structured artifacts (codec blocking, bit-depth banding) are not
        /// noise to the estimator; when either detector fires the tolerance
        /// is raised to at least `artifactTolerance`. nil = noise only.
        public var artifactTolerance: Double? = nil
        public var blockinessThreshold: Double? = nil
        public var histogramGapThreshold: Double? = nil

        public func tolerance(forSigma sigma: Double) -> Float {
            Float(min(max(k * sigma, minimumTolerance), maximumTolerance))
        }

        public func tolerance(for statistics: LumaArtifactStatistics) -> Float {
            let noise = Double(tolerance(forSigma: statistics.noiseSigma))
            let blocky = blockinessThreshold.map { statistics.blockiness > $0 } ?? false
            let banded = histogramGapThreshold.map { statistics.histogramGapFraction > $0 } ?? false
            guard let artifactTolerance, blocky || banded else { return Float(noise) }
            return Float(max(noise, artifactTolerance))
        }
    }

    public static let defaultAdaptiveCandidates: [AdaptiveGuidance] = [
        AdaptiveGuidance(id: "v4-adaptive-k3-min0.02", radius: 2, k: 3, minimumTolerance: 0.02, maximumTolerance: 0.15),
        AdaptiveGuidance(id: "v4-adaptive-k4-min0.05", radius: 2, k: 4, minimumTolerance: 0.05, maximumTolerance: 0.15),
        AdaptiveGuidance(id: "v4-artifact-aware", radius: 2, k: 3, minimumTolerance: 0.02, maximumTolerance: 0.15,
                         artifactTolerance: 0.12, blockinessThreshold: 1.3, histogramGapThreshold: 0.3)
    ]

    public struct NoiseEstimate: Codable, Sendable {
        public let pairID: String
        public let variant: String
        /// Median over frames of the Immerkaer luma sigma (signal units).
        public let lumaSigma: Double
        /// Median over frames of the 8x8 boundary/interior step ratio.
        public let blockiness: Double
        /// Median over frames of the unused-code fraction in the luma range.
        public let histogramGapFraction: Double
        public let tolerances: [String: Float]
    }

    public static let variants: [Variant] = [
        Variant(id: "clean", description: "working-resolution clean SDR", filter: nil, x264CRF: nil),
        Variant(id: "noise-light", description: "temporal Gaussian-like noise, strength 6", filter: "noise=alls=6:allf=t", x264CRF: nil),
        Variant(id: "noise-heavy", description: "temporal Gaussian-like noise, strength 14", filter: "noise=alls=14:allf=t", x264CRF: nil),
        Variant(id: "x264-crf32", description: "H.264 CRF 32 round trip", filter: nil, x264CRF: 32),
        Variant(id: "x264-crf42", description: "H.264 CRF 42 round trip (heavy blocking)", filter: nil, x264CRF: 42),
        Variant(id: "lowres-upscale", description: "320-wide bilinear downscale, bicubic upscale", filter: "scale=320:-2:flags=bilinear,scale=WORK_W:WORK_H:flags=bicubic", x264CRF: nil),
        Variant(id: "banding-6bit", description: "luma quantized to 6 bits", filter: "lutyuv=y='bitand(val,252)'", x264CRF: nil),
        Variant(id: "noise-plus-crf35", description: "noise strength 10, then H.264 CRF 35", filter: "noise=alls=10:allf=t", x264CRF: 35)
    ]

    public struct Metrics: Codable, Sendable {
        /// Mean |PQ(out) - PQ(ref)| over all pixels.
        public var errorAll: Double
        /// Same over reference pixels above twice diffuse white.
        public var errorHighlight: Double
        /// RMS high-pass energy (PQ) of the output in reference-flat pixels.
        public var flatHighPass: Double
        /// Same restricted to flat highlight pixels.
        public var flatHighlightHighPass: Double
        /// Std-dev over frames of mean PQ error (temporal instability).
        public var temporalErrorStd: Double
    }

    public struct Row: Codable, Sendable {
        public let pairID: String
        public let variant: String
        public let configuration: String
        public let metrics: Metrics
    }

    public struct Derived: Codable, Sendable {
        public let pairID: String
        public let variant: String
        public let configuration: String
        /// errorAll(no-expansion) - errorAll(candidate): positive = helps.
        public let benefitAll: Double
        public let benefitHighlight: Double
        /// sqrt(max(0, HP²(variant) - HP²(clean))) for candidate divided by the
        /// same for no-expansion, in flat highlights. >1 = expansion amplifies
        /// the injected artifact energy.
        public let artifactAmplification: Double?
        public let addedArtifactPQ: Double
    }

    public struct Report: Codable, Sendable {
        public let schemaVersion: String
        public let manifestPath: String
        public let workingWidth: Int
        public let frameCount: Int
        public let pairs: [String]
        public let variants: [Variant]
        public let configurations: [String]
        public let rows: [Row]
        public let derived: [Derived]
        public let noiseEstimates: [NoiseEstimate]
        public let adaptiveCandidates: [AdaptiveGuidance]
        public let validationOrFrozenAccessed: Bool
    }

    public static func run(
        manifestURL: URL,
        outputURL: URL,
        workingWidth: Int = 960,
        frameCount: Int = 24,
        candidates: [(String, HDRConfiguration)] = [],
        guidanceCandidates: [(String, HDRGainGuidance)] = RobustnessStudy.defaultGuidanceCandidates,
        adaptiveCandidates: [AdaptiveGuidance] = RobustnessStudy.defaultAdaptiveCandidates
    ) async throws -> Report {
        let manifest = try V4Manifest.load(from: manifestURL)
        let tunePairs = manifest.pairs.filter { $0.split == .tune }
        guard !tunePairs.isEmpty else {
            throw CalibrationError.invalidManifest("robustness study needs at least one Tune pair")
        }
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw CalibrationError.decodeFailed("Metal device unavailable")
        }
        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("hdr-robustness-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        // Pinned to calibrated-v4, the preset this study was designed and
        // reported against; it does not follow the production default.
        guard let v4 = HDRPresetResolver.configuration(for: "calibrated-v4") else {
            throw CalibrationError.invalidManifest("production preset unavailable")
        }
        var noExpansion = v4
        noExpansion.highlightStrength = 0
        noExpansion.contrastStrength = 0
        noExpansion.saturationCompensation = 0
        noExpansion.shadowProtection = 0
        let guided = guidanceCandidates.map { name, guidance -> (String, HDRConfiguration) in
            var configuration = v4
            configuration.gainGuidance = guidance
            return (name, configuration)
        }
        let configurations: [(String, HDRConfiguration)] =
            [("no-expansion", noExpansion), ("calibrated-v4", v4)] + guided + candidates

        var rows: [Row] = []
        var noiseEstimates: [NoiseEstimate] = []
        for pair in tunePairs {
            let urls = pair.resolvedURLs(relativeTo: manifestURL, roots: manifest.roots)
            let start = windowStart(durationSeconds: try await mediaDuration(urls.sdr))
            let pairDir = work.appendingPathComponent(pair.id)
            try FileManager.default.createDirectory(at: pairDir, withIntermediateDirectories: true)
            let prepared = try prepare(
                sdr: urls.sdr, hdr: urls.hdr, start: start, frames: frameCount,
                width: workingWidth, directory: pairDir
            )
            let reference = try await readFrames(prepared.reference, pixelFormat: CalibrationPixelFormat.hdrP010, limit: frameCount)
            let referenceTransfer = try transfer(of: reference[0].pixelBuffer)
            let referenceNits = try reference.map { frame in
                try HDRReferenceDecoder.decode(
                    pixelBuffer: frame.pixelBuffer, timestampSeconds: frame.seconds,
                    width: CVPixelBufferGetWidth(frame.pixelBuffer),
                    height: CVPixelBufferGetHeight(frame.pixelBuffer),
                    transfer: referenceTransfer, referencePeakNits: 1_000
                ).lumaNits
            }
            let width = CVPixelBufferGetWidth(reference[0].pixelBuffer)
            let height = CVPixelBufferGetHeight(reference[0].pixelBuffer)
            for variant in variants {
                let sdrURL = try makeVariant(variant, clean: prepared.cleanSDR, directory: pairDir, width: width, height: height)
                let sdr = try await readFrames(sdrURL, pixelFormat: CalibrationPixelFormat.sdrNV12, limit: frameCount)
                let count = min(sdr.count, referenceNits.count)
                let frameStatistics = sdr.prefix(count).compactMap { LumaArtifactStatistics.measure($0.pixelBuffer) }
                func median(_ values: [Double]) -> Double {
                    let sorted = values.sorted()
                    return sorted.isEmpty ? 0 : sorted[sorted.count / 2]
                }
                let statistics = LumaArtifactStatistics(
                    noiseSigma: median(frameStatistics.map(\.noiseSigma)),
                    blockiness: median(frameStatistics.map(\.blockiness)),
                    histogramGapFraction: median(frameStatistics.map(\.histogramGapFraction))
                )
                let sigma = statistics.noiseSigma
                let adaptive = adaptiveCandidates.map { candidate -> (String, HDRConfiguration) in
                    var configuration = v4
                    configuration.gainGuidance = HDRGainGuidance(
                        radius: candidate.radius, tolerance: candidate.tolerance(for: statistics)
                    )
                    return (candidate.id, configuration)
                }
                noiseEstimates.append(NoiseEstimate(
                    pairID: pair.id, variant: variant.id, lumaSigma: sigma,
                    blockiness: statistics.blockiness, histogramGapFraction: statistics.histogramGapFraction,
                    tolerances: Dictionary(uniqueKeysWithValues: adaptive.map { ($0.0, $0.1.gainGuidance.tolerance) })
                ))
                FileHandle.standardError.write(Data(String(
                    format: "robustness: %@ %@ frames=%d sigma=%.4f blockiness=%.3f gaps=%.3f\n",
                    pair.id, variant.id, count, sigma, statistics.blockiness, statistics.histogramGapFraction
                ).utf8))
                for (name, configuration) in configurations + adaptive {
                    let output = try render(sdr.prefix(count).map { $0 }, configuration: configuration, device: device)
                    let metrics = measure(
                        output: output, reference: Array(referenceNits.prefix(count)),
                        width: width, height: height, paperWhite: configuration.paperWhiteNits
                    )
                    rows.append(Row(pairID: pair.id, variant: variant.id, configuration: name, metrics: metrics))
                }
            }
        }
        let report = Report(
            schemaVersion: "robustness-study-v4",
            manifestPath: manifestURL.path,
            workingWidth: workingWidth,
            frameCount: frameCount,
            pairs: tunePairs.map(\.id),
            variants: variants,
            configurations: configurations.map(\.0) + adaptiveCandidates.map(\.id),
            rows: rows,
            derived: derive(rows),
            noiseEstimates: noiseEstimates,
            adaptiveCandidates: adaptiveCandidates,
            validationOrFrozenAccessed: false
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(report).write(to: outputURL)
        return report
    }

    /// 30 s into long clips (past intros), else the beginning. The window
    /// (24 frames, under 1.5 s at >= 16 fps) must end inside the clip.
    static func windowStart(durationSeconds: Double) -> Double {
        durationSeconds >= 32 ? 30 : 0
    }

    // MARK: - Derived quantities

    static func derive(_ rows: [Row]) -> [Derived] {
        func find(_ pair: String, _ variant: String, _ configuration: String) -> Metrics? {
            rows.first { $0.pairID == pair && $0.variant == variant && $0.configuration == configuration }?.metrics
        }
        var result: [Derived] = []
        for row in rows where row.configuration != "no-expansion" {
            guard let neutral = find(row.pairID, row.variant, "no-expansion"),
                  let candidateClean = find(row.pairID, "clean", row.configuration),
                  let neutralClean = find(row.pairID, "clean", "no-expansion") else { continue }
            func added(_ value: Double, _ clean: Double) -> Double { sqrt(max(0, value * value - clean * clean)) }
            let candidateAdded = added(row.metrics.flatHighlightHighPass, candidateClean.flatHighlightHighPass)
            let neutralAdded = added(neutral.flatHighlightHighPass, neutralClean.flatHighlightHighPass)
            result.append(Derived(
                pairID: row.pairID, variant: row.variant, configuration: row.configuration,
                benefitAll: neutral.errorAll - row.metrics.errorAll,
                benefitHighlight: neutral.errorHighlight - row.metrics.errorHighlight,
                artifactAmplification: neutralAdded > 1e-5 ? candidateAdded / neutralAdded : nil,
                addedArtifactPQ: candidateAdded
            ))
        }
        return result
    }

    // MARK: - Metrics

    static func measure(
        output: [[Float]], reference: [[Float]], width: Int, height: Int, paperWhite: Float
    ) -> Metrics {
        var errorAll = 0.0, errorAllCount = 0.0
        var errorHigh = 0.0, errorHighCount = 0.0
        var flatEnergy = 0.0, flatCount = 0.0
        var flatHighEnergy = 0.0, flatHighCount = 0.0
        var perFrame: [Double] = []
        for (out, ref) in zip(output, reference) {
            let outPQ = out.map { HDRColorMath.pqEncode(nits: $0) }
            let refPQ = ref.map { HDRColorMath.pqEncode(nits: $0) }
            let outHP = highPass(outPQ, width: width, height: height)
            let refHP = highPass(refPQ, width: width, height: height).map(abs)
            let flatThreshold = percentile(refHP, 0.30)
            var frameError = 0.0
            for index in 0..<min(outPQ.count, refPQ.count) {
                let difference = Double(outPQ[index] - refPQ[index])
                frameError += difference
                errorAll += abs(difference); errorAllCount += 1
                let highlight = ref[index] > 2 * paperWhite
                if highlight { errorHigh += abs(difference); errorHighCount += 1 }
                if refHP[index] <= flatThreshold {
                    let energy = Double(outHP[index] * outHP[index])
                    flatEnergy += energy; flatCount += 1
                    if highlight { flatHighEnergy += energy; flatHighCount += 1 }
                }
            }
            perFrame.append(frameError / Double(max(outPQ.count, 1)))
        }
        let mean = perFrame.reduce(0, +) / Double(max(perFrame.count, 1))
        let variance = perFrame.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(max(perFrame.count, 1))
        return Metrics(
            errorAll: errorAll / max(errorAllCount, 1),
            errorHighlight: errorHighCount > 0 ? errorHigh / errorHighCount : 0,
            flatHighPass: sqrt(flatEnergy / max(flatCount, 1)),
            flatHighlightHighPass: flatHighCount > 0 ? sqrt(flatHighEnergy / flatHighCount) : 0,
            temporalErrorStd: sqrt(variance)
        )
    }

    /// x minus its 3x3 box mean (edge-clamped).
    static func highPass(_ values: [Float], width: Int, height: Int) -> [Float] {
        var result = [Float](repeating: 0, count: values.count)
        for y in 0..<height {
            for x in 0..<width {
                var sum: Float = 0
                for dy in -1...1 {
                    let yy = min(max(y + dy, 0), height - 1)
                    for dx in -1...1 {
                        let xx = min(max(x + dx, 0), width - 1)
                        sum += values[yy * width + xx]
                    }
                }
                result[y * width + x] = values[y * width + x] - sum / 9
            }
        }
        return result
    }

    static func percentile(_ values: [Float], _ fraction: Double) -> Float {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * fraction))]
    }

    // MARK: - Rendering

    struct DecodedFrame {
        let pixelBuffer: CVPixelBuffer
        let seconds: Double
    }

    static func render(_ frames: [DecodedFrame], configuration: HDRConfiguration, device: MTLDevice) throws -> [[Float]] {
        let processor = try HDRProcessor(device: device, configuration: configuration)
        processor.automaticTemporalEstimationEnabled = true
        var result: [[Float]] = []
        for frame in frames {
            let width = CVPixelBufferGetWidth(frame.pixelBuffer)
            let height = CVPixelBufferGetHeight(frame.pixelBuffer)
            try processor.prepare(width: width, height: height)
            let command = try processor.makeCommandBuffer()
            let output = try processor.process(
                pixelBuffer: frame.pixelBuffer,
                timestamp: CMTime(seconds: frame.seconds, preferredTimescale: 90_000),
                commandBuffer: command
            )
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba16Float, width: width, height: height, mipmapped: false
            )
            descriptor.storageMode = .shared
            descriptor.usage = [.shaderRead]
            guard let staging = device.makeTexture(descriptor: descriptor),
                  let blit = command.makeBlitCommandEncoder() else {
                throw CalibrationError.decodeFailed("robustness readback allocation failed")
            }
            blit.copy(from: output.texture, to: staging)
            blit.endEncoding()
            command.commit()
            command.waitUntilCompleted()
            guard command.status == .completed else {
                throw CalibrationError.decodeFailed(command.error?.localizedDescription ?? "HDRCore command failed")
            }
            var halves = [Float16](repeating: 0, count: width * height * 4)
            staging.getBytes(&halves, bytesPerRow: width * 8, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
            var luma = [Float](repeating: 0, count: width * height)
            for index in 0..<(width * height) {
                let rgb = SIMD3<Float>(Float(halves[index * 4]), Float(halves[index * 4 + 1]), Float(halves[index * 4 + 2]))
                luma[index] = max(simd_dot(rgb, HDRColorMath.bt2020Luminance), 0) * configuration.paperWhiteNits
            }
            result.append(luma)
        }
        return result
    }

    // MARK: - Media

    /// Async so that loading the track never blocks a cooperative-pool
    /// thread on a semaphore (which can deadlock when the pool is saturated).
    static func readFrames(_ url: URL, pixelFormat: OSType, limit: Int) async throws -> [DecodedFrame] {
        let asset = AVURLAsset(url: url)
        let track = try await asset.loadTracks(withMediaType: .video).first
        guard let track else { throw CalibrationError.decodeFailed("no video track: \(url.lastPathComponent)") }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: pixelFormat,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ])
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else {
            throw reader.error ?? CalibrationError.decodeFailed("cannot read \(url.lastPathComponent)")
        }
        var frames: [DecodedFrame] = []
        while frames.count < limit, let sample = output.copyNextSampleBuffer() {
            guard let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            frames.append(DecodedFrame(pixelBuffer: buffer, seconds: CMSampleBufferGetPresentationTimeStamp(sample).seconds))
        }
        reader.cancelReading()
        guard !frames.isEmpty else { throw CalibrationError.decodeFailed("no frames in \(url.lastPathComponent)") }
        return frames
    }

    static func transfer(of buffer: CVPixelBuffer) throws -> ReferenceTransfer {
        let value = CVBufferCopyAttachment(buffer, kCVImageBufferTransferFunctionKey, nil) as? String
        if value == kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String { return .pq }
        if value == kCVImageBufferTransferFunction_ITU_R_2100_HLG as String { return .hlg }
        throw CalibrationError.unsupportedReference("reference transfer is neither PQ nor HLG: \(value ?? "nil")")
    }

    static func mediaDuration(_ url: URL) async throws -> Double {
        try await AVURLAsset(url: url).load(.duration).seconds
    }

    struct Prepared {
        let cleanSDR: URL
        let reference: URL
    }

    static func prepare(sdr: URL, hdr: URL, start: Double, frames: Int, width: Int, directory: URL) throws -> Prepared {
        let referenceTransfer = try ffprobe(hdr, entry: "stream=color_transfer")
        guard referenceTransfer == "smpte2084" || referenceTransfer == "arib-std-b67" else {
            throw CalibrationError.unsupportedReference("unsupported reference transfer \(referenceTransfer)")
        }
        // Both cuts are rebased to PTS 0. A seek that lands between source
        // frames otherwise leaves a small positive start, which QuickTime
        // stores as an empty edit; AVAssetReader then emits a synthetic black
        // frame at t=0 and every frame moves back by one. Re-encoded variants
        // start at 0, so they would be compared one frame off the reference.
        let reference = directory.appendingPathComponent("reference.mov")
        try ffmpeg([
            "-ss", String(start), "-i", hdr.path, "-map", "0:v:0", "-frames:v", String(frames),
            "-vf", "setpts=PTS-STARTPTS,scale=\(width):-2:flags=area", "-c:v", "prores_ks", "-profile:v", "4",
            "-pix_fmt", "yuv444p10le", "-color_primaries", "bt2020", "-color_trc", referenceTransfer,
            "-colorspace", "bt2020nc", "-color_range", "tv", reference.path
        ])
        // The clean working clip is 8-bit 4:2:0 like typical delivered SDR;
        // every degradation is applied to this same clip.
        let clean = directory.appendingPathComponent("sdr-clean.mov")
        try ffmpeg([
            "-ss", String(start), "-i", sdr.path, "-map", "0:v:0", "-frames:v", String(frames),
            "-vf", "setpts=PTS-STARTPTS,scale=\(width):-2:flags=area,format=yuv420p", "-c:v", "prores_ks", "-profile:v", "3",
            "-pix_fmt", "yuv422p10le", "-color_primaries", "bt709", "-color_trc", "bt709",
            "-colorspace", "bt709", "-color_range", "tv", clean.path
        ])
        try requireZeroStart(reference)
        try requireZeroStart(clean)
        return Prepared(cleanSDR: clean, reference: reference)
    }

    static func makeVariant(_ variant: Variant, clean: URL, directory: URL, width: Int, height: Int) throws -> URL {
        if variant.filter == nil && variant.x264CRF == nil { return clean }
        let tags = ["-color_primaries", "bt709", "-color_trc", "bt709", "-colorspace", "bt709", "-color_range", "tv"]
        var source = clean
        if let filter = variant.filter {
            let filtered = directory.appendingPathComponent("sdr-\(variant.id)-filtered.mov")
            // Variants keep the clean clip's frame timing exactly (passthrough).
            let chain = "format=yuv420p," + filter
                .replacingOccurrences(of: "WORK_W", with: String(width))
                .replacingOccurrences(of: "WORK_H", with: String(height)) + ",format=yuv420p"
            try ffmpeg(["-i", clean.path, "-fps_mode", "passthrough", "-vf", chain, "-c:v", "prores_ks", "-profile:v", "3",
                        "-pix_fmt", "yuv422p10le"] + tags + [filtered.path])
            try requireZeroStart(filtered)
            source = filtered
        }
        guard let crf = variant.x264CRF else { return source }
        let compressed = directory.appendingPathComponent("sdr-\(variant.id).mp4")
        try ffmpeg(["-i", source.path, "-fps_mode", "passthrough", "-vf", "format=yuv420p", "-c:v", "libx264", "-preset", "medium",
                    "-crf", String(crf), "-x264-params", "log-level=error"] + tags + [compressed.path])
        let decoded = directory.appendingPathComponent("sdr-\(variant.id).mov")
        try ffmpeg(["-i", compressed.path, "-fps_mode", "passthrough", "-vf", "format=yuv420p", "-c:v", "prores_ks", "-profile:v", "3",
                    "-pix_fmt", "yuv422p10le"] + tags + [decoded.path])
        try requireZeroStart(decoded)
        return decoded
    }

    /// Every clip the study reads must start at PTS 0 so position i means the
    /// same instant in the reference, the clean clip and each variant.
    static func requireZeroStart(_ url: URL) throws {
        let start = try ffprobe(url, entry: "format=start_time", stream: false)
        guard let seconds = Double(start), abs(seconds) < 1e-6 else {
            throw CalibrationError.decodeFailed(
                "robustness clip \(url.lastPathComponent) starts at \(start), not 0; frames would be misaligned"
            )
        }
    }

    private static func tool(_ name: String) throws -> String {
        guard let path = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]
            .map({ "\($0)/\(name)" })
            .first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw CalibrationError.decodeFailed("\(name) is required for the robustness study")
        }
        return path
    }

    private static func ffmpeg(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: try tool("ffmpeg"))
        process.arguments = ["-hide_banner", "-nostdin", "-loglevel", "error", "-y"] + arguments
        process.standardOutput = FileHandle.nullDevice
        let errors = Pipe()
        process.standardError = errors
        try process.run()
        let message = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw CalibrationError.decodeFailed("ffmpeg failed: \(String(decoding: message, as: UTF8.self).prefix(400))")
        }
    }

    private static func ffprobe(_ url: URL, entry: String, stream: Bool = true) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: try tool("ffprobe"))
        process.arguments = ["-v", "error"] + (stream ? ["-select_streams", "v:0"] : [])
            + ["-show_entries", entry, "-of", "csv=p=0", url.path]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        // Side data (e.g. mastering display) can append extra CSV lines; the
        // stream entry is always the first non-empty one.
        return String(decoding: data, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ","))) }
            .first { !$0.isEmpty } ?? ""
    }
}
