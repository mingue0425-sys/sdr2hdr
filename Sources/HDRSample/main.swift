import AVFoundation
import CoreVideo
import Foundation
import HDRCore
import Metal

private func argumentValue(_ name: String, in arguments: [String]) -> String? {
    guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}

private func run(arguments: [String]) async throws {
    guard let inputPath = argumentValue("--input", in: arguments) else {
        throw NSError(domain: "HDRSample", code: 1, userInfo: [NSLocalizedDescriptionKey: "Usage: HDRSample --input /path/to/video [--frames N] [--mode EDR|PQ]"])
    }
    let requestedFrames = max(Int(argumentValue("--frames", in: arguments) ?? "1") ?? 1, 1)
    let outputMode = HDROutputMode(rawValue: (argumentValue("--mode", in: arguments) ?? "EDR").uppercased()) ?? .edr
    guard let device = MTLCreateSystemDefaultDevice() else {
        throw NSError(domain: "HDRSample", code: 2, userInfo: [NSLocalizedDescriptionKey: "Metal device unavailable"])
    }

    let asset = AVURLAsset(url: URL(fileURLWithPath: inputPath))
    guard let track = try await asset.loadTracks(withMediaType: .video).first else {
        throw NSError(domain: "HDRSample", code: 3, userInfo: [NSLocalizedDescriptionKey: "No video track found"])
    }
    let reader = try AVAssetReader(asset: asset)
    let outputSettings: [String: Any] = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        kCVPixelBufferMetalCompatibilityKey as String: true,
        kCVPixelBufferIOSurfacePropertiesKey as String: [:]
    ]
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
    output.alwaysCopiesSampleData = false
    guard reader.canAdd(output) else {
        throw NSError(domain: "HDRSample", code: 4, userInfo: [NSLocalizedDescriptionKey: "Cannot add AVAssetReader output"])
    }
    reader.add(output)
    guard reader.startReading() else {
        throw reader.error ?? NSError(domain: "HDRSample", code: 5, userInfo: [NSLocalizedDescriptionKey: "AVAssetReader failed to start"])
    }

    var configuration = HDRConfiguration.hdr
    configuration.outputMode = outputMode
    let processor = try HDRProcessor(device: device, configuration: configuration)
    guard let queue = device.makeCommandQueue() else {
        throw HDRProcessorError.commandQueueCreationFailed
    }

    var processed = 0
    while processed < requestedFrames, let sampleBuffer = output.copyNextSampleBuffer() {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
              let commandBuffer = queue.makeCommandBuffer() else {
            throw HDRProcessorError.commandBufferCreationFailed
        }
        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        _ = try processor.process(pixelBuffer: pixelBuffer, timestamp: timestamp, commandBuffer: commandBuffer)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            commandBuffer.addCompletedHandler { _ in
                continuation.resume()
            }
            commandBuffer.commit()
        }
        guard commandBuffer.status == .completed else {
            throw commandBuffer.error ?? NSError(domain: "HDRSample", code: 6, userInfo: [NSLocalizedDescriptionKey: "Metal processing failed"])
        }
        processed += 1
        print("processed frame \(processed) at \(timestamp.seconds)s -> \(outputMode.rawValue) RGBA16Float")
    }
    print("HDRSample complete: \(processed) frame(s); no output encoding was performed")
}

@main
private struct HDRSampleMain {
    static func main() async {
        do {
            try await run(arguments: CommandLine.arguments)
        } catch {
            fputs("HDRSample failed: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
}
