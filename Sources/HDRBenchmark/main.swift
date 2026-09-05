import CoreVideo
import Foundation
import HDRCore
import HDRPlayerKit
import Metal

private struct BenchmarkOptions {
    var width = 1_920
    var height = 1_080
    var frames = 300
    var warmup = 30
    var mode: HDROutputMode = .edr
    var preset = "hdr"
    var presentationOnly = false

    init(arguments: [String]) {
        var index = 1
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--presentation-only" {
                presentationOnly = true
                index += 1
                continue
            }
            if index + 1 < arguments.count {
                switch argument {
                case "--width": width = Int(arguments[index + 1]) ?? width
                case "--height": height = Int(arguments[index + 1]) ?? height
                case "--frames": frames = Int(arguments[index + 1]) ?? frames
                case "--warmup": warmup = Int(arguments[index + 1]) ?? warmup
                case "--mode": mode = HDROutputMode(rawValue: arguments[index + 1].uppercased()) ?? mode
                case "--preset": preset = arguments[index + 1].lowercased()
                default: break
                }
                index += 2
            } else {
                index += 1
            }
        }
        frames = max(frames, 1)
        warmup = max(warmup, 0)
    }
}

private func makeSyntheticNV12(width: Int, height: Int) throws -> CVPixelBuffer {
    var pixelBuffer: CVPixelBuffer?
    let attributes: CFDictionary = [
        kCVPixelBufferMetalCompatibilityKey as String: true,
        kCVPixelBufferIOSurfacePropertiesKey as String: [:]
    ] as CFDictionary
    let status = CVPixelBufferCreate(
        kCFAllocatorDefault,
        width,
        height,
        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        attributes,
        &pixelBuffer
    )
    guard status == kCVReturnSuccess, let pixelBuffer else {
        throw NSError(domain: "HDRBenchmark", code: Int(status), userInfo: [NSLocalizedDescriptionKey: "CVPixelBufferCreate failed"])
    }

    CVBufferSetAttachment(
        pixelBuffer,
        kCVImageBufferColorPrimariesKey,
        kCVImageBufferColorPrimaries_ITU_R_709_2,
        .shouldPropagate
    )
    CVBufferSetAttachment(
        pixelBuffer,
        kCVImageBufferTransferFunctionKey,
        kCVImageBufferTransferFunction_ITU_R_709_2,
        .shouldPropagate
    )
    CVBufferSetAttachment(
        pixelBuffer,
        kCVImageBufferYCbCrMatrixKey,
        kCVImageBufferYCbCrMatrix_ITU_R_709_2,
        .shouldPropagate
    )

    let lockStatus = CVPixelBufferLockBaseAddress(pixelBuffer, [])
    guard lockStatus == kCVReturnSuccess else { return pixelBuffer }
    defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

    if let yBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0)?.assumingMemoryBound(to: UInt8.self) {
        let rowBytes = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        for y in 0..<CVPixelBufferGetHeightOfPlane(pixelBuffer, 0) {
            let row = yBase.advanced(by: y * rowBytes)
            for x in 0..<CVPixelBufferGetWidthOfPlane(pixelBuffer, 0) {
                let ramp = Float(x) / Float(max(width - 1, 1))
                row[x] = UInt8(min(max(16 + Int(ramp * 219), 16), 235))
            }
        }
    }
    if let uvBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1)?.assumingMemoryBound(to: UInt8.self) {
        let rowBytes = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1)
        let uvWidth = CVPixelBufferGetWidthOfPlane(pixelBuffer, 1)
        let uvHeight = CVPixelBufferGetHeightOfPlane(pixelBuffer, 1)
        for y in 0..<uvHeight {
            let row = uvBase.advanced(by: y * rowBytes)
            for x in 0..<uvWidth {
                row[2 * x] = 128
                row[2 * x + 1] = 128
            }
        }
    }
    return pixelBuffer
}

private func percentile(_ values: [Double], _ fraction: Double) -> Double {
    guard !values.isEmpty else { return .nan }
    let sorted = values.sorted()
    let position = min(max(Int(Double(sorted.count - 1) * fraction), 0), sorted.count - 1)
    return sorted[position]
}

private func runPresentationBenchmark(options: BenchmarkOptions, device: MTLDevice) throws {
    let renderer = try HDRPresentationRenderer(device: device)
    guard let queue = device.makeCommandQueue() else {
        throw NSError(domain: "HDRBenchmark", code: 2, userInfo: [NSLocalizedDescriptionKey: "Command queue unavailable"])
    }
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: .rgba16Float,
        width: options.width,
        height: options.height,
        mipmapped: false
    )
    descriptor.storageMode = .private
    descriptor.usage = [.renderTarget]
    guard let target = device.makeTexture(descriptor: descriptor) else {
        throw NSError(domain: "HDRBenchmark", code: 4, userInfo: [NSLocalizedDescriptionKey: "Presentation target creation failed"])
    }

    let totalFrames = options.warmup + options.frames
    var gpuDurations: [Double] = []
    var cpuSubmissionDurations: [Double] = []
    gpuDurations.reserveCapacity(options.frames)
    cpuSubmissionDurations.reserveCapacity(options.frames)

    for frameIndex in 0..<totalFrames {
        guard let commandBuffer = queue.makeCommandBuffer() else {
            throw HDRProcessorError.commandBufferCreationFailed
        }
        let cpuStart = ProcessInfo.processInfo.systemUptime
        renderer.encodeTestPattern(
            to: target,
            commandBuffer: commandBuffer,
            masteringHeadroom: HDRConfiguration.calibratedV3Candidate.masteringHeadroom,
            displayHeadroom: 2
        )
        let encodeEnd = ProcessInfo.processInfo.systemUptime
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        let wallEnd = ProcessInfo.processInfo.systemUptime
        if frameIndex >= options.warmup {
            let gpuDuration = commandBuffer.gpuStartTime > 0 && commandBuffer.gpuEndTime > commandBuffer.gpuStartTime
                ? (commandBuffer.gpuEndTime - commandBuffer.gpuStartTime) * 1_000
                : (wallEnd - cpuStart) * 1_000
            gpuDurations.append(gpuDuration)
            cpuSubmissionDurations.append((encodeEnd - cpuStart) * 1_000)
        }
    }

    print("HDRPresentationBenchmark")
    print("device: \(device.name)")
    print("size: \(options.width)x\(options.height), format: rgba16Float, mastering: \(HDRConfiguration.calibratedV3Candidate.masteringHeadroom), display: 2.0, warmup: \(options.warmup), measured: \(options.frames)")
    print(String(format: "GPU p50: %.3f ms", percentile(gpuDurations, 0.50)))
    print(String(format: "GPU p95: %.3f ms", percentile(gpuDurations, 0.95)))
    print(String(format: "GPU p99: %.3f ms", percentile(gpuDurations, 0.99)))
    print(String(format: "CPU submission p50: %.3f ms", percentile(cpuSubmissionDurations, 0.50)))
    print(String(format: "CPU submission p95: %.3f ms", percentile(cpuSubmissionDurations, 0.95)))
    print(String(format: "CPU submission p99: %.3f ms", percentile(cpuSubmissionDurations, 0.99)))
    print("persistent presentation textures: 1")
}

private func run(options: BenchmarkOptions) throws {
    guard let device = MTLCreateSystemDefaultDevice() else {
        throw NSError(domain: "HDRBenchmark", code: 1, userInfo: [NSLocalizedDescriptionKey: "Metal device unavailable"])
    }
    if options.presentationOnly {
        try runPresentationBenchmark(options: options, device: device)
        return
    }
    let pixelBuffer = try makeSyntheticNV12(width: options.width, height: options.height)
    var configuration: HDRConfiguration
    switch options.preset {
    case "natural": configuration = .natural
    case "hdr": configuration = .hdr
    case "vivid": configuration = .vivid
    case "calibrated-v1": configuration = .calibratedV1
    case "calibrated-v2": configuration = .calibratedV2
    case "calibrated-v4": configuration = .calibratedV4
    case "calibrated-v3-candidate": configuration = .calibratedV3Candidate
    default:
        if let candidate = HDRV62ToneCurveCandidate(rawValue: options.preset) {
            configuration = candidate.configuration()
        } else if let candidate = HDRV6ToneCurveCandidate(rawValue: options.preset) {
            configuration = candidate.configuration()
        } else {
            throw NSError(
                domain: "HDRBenchmark",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "unsupported preset: \(options.preset)"]
            )
        }
    }
    configuration.outputMode = options.mode
    let processor = try HDRProcessor(device: device, configuration: configuration)
    try processor.prepare(width: options.width, height: options.height)
    guard let queue = device.makeCommandQueue() else {
        throw NSError(domain: "HDRBenchmark", code: 2, userInfo: [NSLocalizedDescriptionKey: "Command queue unavailable"])
    }

    let totalFrames = options.warmup + options.frames
    var gpuDurations: [Double] = []
    var cpuSubmissionDurations: [Double] = []
    gpuDurations.reserveCapacity(options.frames)
    cpuSubmissionDurations.reserveCapacity(options.frames)

    for frameIndex in 0..<totalFrames {
        guard let commandBuffer = queue.makeCommandBuffer() else {
            throw HDRProcessorError.commandBufferCreationFailed
        }
        let cpuStart = ProcessInfo.processInfo.systemUptime
        _ = try processor.process(pixelBuffer: pixelBuffer, commandBuffer: commandBuffer)
        let encodeEnd = ProcessInfo.processInfo.systemUptime
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        let wallEnd = ProcessInfo.processInfo.systemUptime

        if frameIndex >= options.warmup {
            let gpuDuration = commandBuffer.gpuStartTime > 0 && commandBuffer.gpuEndTime > commandBuffer.gpuStartTime
                ? (commandBuffer.gpuEndTime - commandBuffer.gpuStartTime) * 1_000
                : (wallEnd - cpuStart) * 1_000
            gpuDurations.append(gpuDuration)
            cpuSubmissionDurations.append((encodeEnd - cpuStart) * 1_000)
        }
    }

    let gpuP50 = percentile(gpuDurations, 0.50)
    let gpuP95 = percentile(gpuDurations, 0.95)
    let gpuP99 = percentile(gpuDurations, 0.99)
    let cpuP50 = percentile(cpuSubmissionDurations, 0.50)
    let cpuP95 = percentile(cpuSubmissionDurations, 0.95)
    let cpuP99 = percentile(cpuSubmissionDurations, 0.99)
    let fps = gpuP50 > 0 ? 1_000 / gpuP50 : .nan

    print("HDRBenchmark")
    print("device: \(device.name)")
    print("size: \(options.width)x\(options.height), mode: \(options.mode.rawValue), preset: \(options.preset), warmup: \(options.warmup), measured: \(options.frames)")
    print(String(format: "GPU p50: %.3f ms", gpuP50))
    print(String(format: "GPU p95: %.3f ms", gpuP95))
    print(String(format: "GPU p99: %.3f ms", gpuP99))
    print(String(format: "CPU submission p50: %.3f ms", cpuP50))
    print(String(format: "CPU submission p95: %.3f ms", cpuP95))
    print(String(format: "CPU submission p99: %.3f ms", cpuP99))
    print(String(format: "GPU FPS equivalent: %.2f", fps))
    let metrics = processor.runtimeMetrics
    print("output texture allocations: \(metrics.outputTextureAllocations) persistent texture(s)")
    print("output texture logical memory: \(metrics.outputTextureLogicalBytes) bytes")
    print("temporal estimate buffers: \(metrics.temporalEstimateBufferAllocations) persistent buffer(s)")
}

do {
    try run(options: BenchmarkOptions(arguments: CommandLine.arguments))
} catch {
    fputs("HDRBenchmark failed: \(error.localizedDescription)\n", stderr)
    exit(1)
}
