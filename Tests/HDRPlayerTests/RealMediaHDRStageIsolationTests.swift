@preconcurrency import AVFoundation
import CoreVideo
import Foundation
import Metal
import XCTest
@testable import HDRCore
import HDRPlayerKit

private enum HDRStageIsolationStage: String, CaseIterable {
    case h1 = "H1_HDRProcessor_only"
    case h2 = "H2_HDRProcessor_plus_raw_blit"
    case h3 = "H3_HDRProcessor_plus_presentation"
    case h4 = "H4_full_path"

    var includesRawBlit: Bool {
        self == .h2 || self == .h4
    }

    var includesPresentation: Bool {
        self == .h3 || self == .h4
    }
}

private enum HDRStageExternalHandlerBody: String {
    case none
    case noop
    case counter
}

private struct HDRStageIsolationResult: Codable {
    let stage: String
    let completionMode: String
    let externalHandlerBody: String
    let expectedProductionHandlerCount: Int
    let expectedExternalHandlerCount: Int
    let expectedHandlerCount: Int
    let handlerCountBasis: String
    let status: String
    let frames: Int
    let commandBuffersCommitted: Int
    let commandBuffersCompleted: Int
    let error: String?

    init(
        stage: String,
        completionMode: String,
        externalHandlerBody: String = HDRStageExternalHandlerBody.none.rawValue,
        expectedProductionHandlerCount: Int = 0,
        expectedExternalHandlerCount: Int = 0,
        expectedHandlerCount: Int = 0,
        handlerCountBasis: String =
            "production code-path expectation per command buffer; " +
                "Metal exposes no handler-count introspection",
        status: String,
        frames: Int,
        commandBuffersCommitted: Int,
        commandBuffersCompleted: Int,
        error: String?
    ) {
        self.stage = stage
        self.completionMode = completionMode
        self.externalHandlerBody = externalHandlerBody
        self.expectedProductionHandlerCount = expectedProductionHandlerCount
        self.expectedExternalHandlerCount = expectedExternalHandlerCount
        self.expectedHandlerCount = expectedHandlerCount
        self.handlerCountBasis = handlerCountBasis
        self.status = status
        self.frames = frames
        self.commandBuffersCommitted = commandBuffersCommitted
        self.commandBuffersCompleted = commandBuffersCompleted
        self.error = error
    }
}

private struct HDRStagePendingFrame {
    let commandBuffer: MTLCommandBuffer
    let frame: HDRFrame
    let presentationTexture: MTLTexture?
    let readback: MTLBuffer?
    let completionWaiter: RealMediaCompletionWaiter?
}

private func synchronouslyWaitUntilCompleted(_ commandBuffer: MTLCommandBuffer) {
    commandBuffer.waitUntilCompleted()
}

private func writeHDRStageProgress(_ message: String) {
    FileHandle.standardError.write(Data("HDR_STAGE_PROGRESS \(message)\n".utf8))
}

private final class HDRStageCompletionCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func increment() {
        lock.lock()
        storage += 1
        lock.unlock()
    }
}

@MainActor
final class RealMediaHDRStageIsolationTests: XCTestCase {
    func testVMAppleHDRStage() async {
        let environment = ProcessInfo.processInfo.environment
        guard let stageName = environment["HDR_PRODUCTION_STAGE"] else {
            return
        }
        guard let stage = HDRStageIsolationStage(rawValue: stageName) else {
            emitResult(
                HDRStageIsolationResult(
                    stage: stageName,
                    completionMode: "unknown",
                    status: "ERROR",
                    frames: 0,
                    commandBuffersCommitted: 0,
                    commandBuffersCompleted: 0,
                    error: "unknown HDR stage"
                )
            )
            XCTFail("unknown HDR stage: \(stageName)")
            return
        }
        let completionSetting = environment["HDR_PRODUCTION_COMPLETION_MODE"] ?? "waitUntilCompleted"
        let usesAsyncWaiter = completionSetting == "async-waiter"
        let externalHandlerBody = HDRStageExternalHandlerBody(
            rawValue: environment["HDR_PRODUCTION_COMPLETION_BODY"] ??
                (completionSetting == "waitUntilCompleted" ? "none" : "counter")
        ) ?? .counter
        let usesExternalCompletionHandler = externalHandlerBody != .none
        let completionMode: String
        switch completionSetting {
        case "completion-handler-direct-wait":
            completionMode = "completionHandler+directWait"
        case "async-waiter":
            completionMode = "completionHandler+asyncWaiter"
        default:
            completionMode = "waitUntilCompleted"
        }
        writeHDRStageProgress("stage=\(stage.rawValue) phase=test-enter completionMode=\(completionMode)")

        let requiredFrames = max(
            Int(environment["HDR_PRODUCTION_STAGE_FRAMES"] ?? "2") ?? 2,
            2
        )
        let fixtureID = environment["HDR_PRODUCTION_STAGE_FIXTURE"] ??
            "h264-8-video-24-chroma-edge"
        let fixtureDirectory = environment["HDR_REAL_MEDIA_REGRESSION_FIXTURE_DIR"] ?? ""
        do {
            guard !fixtureDirectory.isEmpty else {
                throw RealMediaRegressionRunner.RunnerError.commandBufferFailed(
                    "fixture directory is not configured"
                )
            }
            guard let device = MTLCreateSystemDefaultDevice() else {
                throw RealMediaRegressionRunner.RunnerError.missingDevice
            }
            let manifest = try loadManifest(environment: environment)
            let gates = try loadGates(environment: environment)
            guard let fixture = manifest.fixtures.first(where: { $0.id == fixtureID }) else {
                throw RealMediaRegressionRunner.RunnerError.commandBufferFailed(
                    "fixture not found: \(fixtureID)"
                )
            }
            let runner = RealMediaRegressionRunner(
                manifest: manifest,
                gates: gates,
                fixtureDirectory: URL(fileURLWithPath: fixtureDirectory),
                device: device
            )
            let frames = try await runner.decodeRegressionFrames(
                fixture,
                requiredFrameCount: requiredFrames
            )
            try await run(
                stage: stage,
                frames: Array(frames.prefix(requiredFrames)),
                device: device,
                usesAsyncWaiter: usesAsyncWaiter,
                usesExternalCompletionHandler: usesExternalCompletionHandler,
                externalHandlerBody: externalHandlerBody,
                completionMode: completionMode
            )
        } catch {
            emitResult(
                HDRStageIsolationResult(
                    stage: stage.rawValue,
                    completionMode: completionMode,
                    status: "ERROR",
                    frames: 0,
                    commandBuffersCommitted: 0,
                    commandBuffersCompleted: 0,
                    error: String(describing: error)
                )
            )
            XCTFail("\(stage.rawValue): \(error)")
        }
    }

    private func run(
        stage: HDRStageIsolationStage,
        frames: [RealMediaRegressionRunner.DecodedFrame],
        device: MTLDevice,
        usesAsyncWaiter: Bool,
        usesExternalCompletionHandler: Bool,
        externalHandlerBody: HDRStageExternalHandlerBody,
        completionMode: String
    ) async throws {
        guard frames.count >= 2 else {
            throw RealMediaRegressionRunner.RunnerError.insufficientFrames(
                id: stage.rawValue,
                count: frames.count,
                required: 2
            )
        }
        let firstPixelBuffer = frames[0].pixelBuffer
        let width = CVPixelBufferGetWidth(firstPixelBuffer)
        let height = CVPixelBufferGetHeight(firstPixelBuffer)
        var configuration = HDRConfiguration.calibratedV4
        configuration.chromaReconstructionMode = .nearest
        let processor = try HDRProcessor(device: device, configuration: configuration)
        processor.temporalTraceEnabled = true
        let renderer = stage.includesPresentation
            ? try HDRPresentationRenderer(device: device, colorPixelFormat: .rgba16Float)
            : nil
        var pending: [HDRStagePendingFrame] = []
        pending.reserveCapacity(2)
        let completionCounter = HDRStageCompletionCounter()
        let expectedProductionHandlerCount = stage.includesPresentation ? 2 : 1
        let expectedExternalHandlerCount = usesExternalCompletionHandler ? 1 : 0
        writeHDRStageProgress(
            "stage=\(stage.rawValue) phase=expected-handlers " +
                "production=\(expectedProductionHandlerCount) " +
                "external=\(expectedExternalHandlerCount) " +
                "body=\(externalHandlerBody.rawValue)"
        )

        writeHDRStageProgress("stage=\(stage.rawValue) phase=resources-ready")
        for (index, decoded) in frames.prefix(2).enumerated() {
            guard let commandBuffer = try? processor.makeCommandBuffer() else {
                throw RealMediaRegressionRunner.RunnerError.commandBufferFailed(
                    "could not create command buffer for frame \(index)"
                )
            }
            writeHDRStageProgress("stage=\(stage.rawValue) phase=processor-start frame=\(index)")
            let frame = try processor.process(
                pixelBuffer: decoded.pixelBuffer,
                timestamp: decoded.presentationTime,
                commandBuffer: commandBuffer,
                diagnosticFrameIndex: UInt64(index + 1)
            )
            writeHDRStageProgress("stage=\(stage.rawValue) phase=processor-finished frame=\(index)")

            var presentationTexture: MTLTexture?
            var readback: MTLBuffer?
            let completionWaiter = usesAsyncWaiter ? RealMediaCompletionWaiter() : nil
            if stage.includesPresentation {
                let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                    pixelFormat: .rgba16Float,
                    width: width,
                    height: height,
                    mipmapped: false
                )
                descriptor.usage = [.renderTarget, .shaderRead]
                descriptor.storageMode = .private
                guard let target = device.makeTexture(descriptor: descriptor),
                      let renderer,
                      renderer.encodeOffscreen(
                        texture: frame.texture,
                        to: target,
                        commandBuffer: commandBuffer,
                        sourceSize: CGSize(width: width, height: height),
                        drawableSize: CGSize(width: width, height: height),
                        orientation: .identity,
                        fallbackToSDR: false,
                        masteringHeadroom: frame.metadata.masteringHeadroom,
                        displayHeadroom: 1.5,
                        diagnosticFrameIndex: UInt64(index + 1)
                      ) else {
                    throw RealMediaRegressionRunner.RunnerError.commandBufferFailed(
                        "presentation encoding failed for frame \(index)"
                    )
                }
                presentationTexture = target
                writeHDRStageProgress("stage=\(stage.rawValue) phase=presentation-encoded frame=\(index)")
            }

            if stage.includesRawBlit {
                let sourceTexture = presentationTexture ?? frame.texture
                let length = width * height * 4 * MemoryLayout<UInt16>.stride
                guard let destination = device.makeBuffer(
                    length: length,
                    options: .storageModeShared
                ), let blit = commandBuffer.makeBlitCommandEncoder() else {
                    throw RealMediaRegressionRunner.RunnerError.missingTexture
                }
                blit.copy(
                    from: sourceTexture,
                    sourceSlice: 0,
                    sourceLevel: 0,
                    sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                    sourceSize: MTLSize(width: width, height: height, depth: 1),
                    to: destination,
                    destinationOffset: 0,
                    destinationBytesPerRow: width * 4 * MemoryLayout<UInt16>.stride,
                    destinationBytesPerImage: length
                )
                blit.endEncoding()
                readback = destination
                writeHDRStageProgress("stage=\(stage.rawValue) phase=raw-blit-encoded frame=\(index)")
            }

            if usesExternalCompletionHandler {
                switch externalHandlerBody {
                case .none:
                    break
                case .noop:
                    commandBuffer.addCompletedHandler { _ in }
                case .counter:
                    commandBuffer.addCompletedHandler { _ in
                        completionCounter.increment()
                        completionWaiter?.signal()
                    }
                }
            }

            pending.append(
                HDRStagePendingFrame(
                    commandBuffer: commandBuffer,
                    frame: frame,
                    presentationTexture: presentationTexture,
                    readback: readback,
                    completionWaiter: completionWaiter
                )
            )
        }

        writeHDRStageProgress("stage=\(stage.rawValue) phase=commit count=\(pending.count)")
        for value in pending {
            value.commandBuffer.commit()
        }
        writeHDRStageProgress("stage=\(stage.rawValue) phase=committed count=\(pending.count)")
        if usesAsyncWaiter {
            for value in pending {
                await value.completionWaiter?.wait()
            }
        } else {
            for value in pending {
                synchronouslyWaitUntilCompleted(value.commandBuffer)
            }
        }
        for value in pending {
            guard value.commandBuffer.status == .completed,
                  value.commandBuffer.error == nil else {
                throw RealMediaRegressionRunner.RunnerError.commandBufferFailed(
                    "stage command buffer status=\(value.commandBuffer.status.rawValue) error=\(value.commandBuffer.error?.localizedDescription ?? "nil")"
                )
            }
            if let readback = value.readback {
                let words = readback.contents().assumingMemoryBound(to: UInt16.self)
                let count = width * height * 4
                var hasNonZeroValue = false
                for index in 0..<count where words[index] != 0 {
                    hasNonZeroValue = true
                    break
                }
                guard hasNonZeroValue else {
                    throw RealMediaRegressionRunner.RunnerError.commandBufferFailed(
                        "stage readback was all zero"
                    )
                }
            }
        }
        if externalHandlerBody == .counter {
            guard completionCounter.value == pending.count else {
                throw RealMediaRegressionRunner.RunnerError.commandBufferFailed(
                    "external completion handler count=\(completionCounter.value), expected \(pending.count)"
                )
            }
        }
        writeHDRStageProgress("stage=\(stage.rawValue) phase=completed count=\(pending.count)")
        emitResult(
            HDRStageIsolationResult(
                stage: stage.rawValue,
                completionMode: completionMode,
                externalHandlerBody: externalHandlerBody.rawValue,
                expectedProductionHandlerCount: expectedProductionHandlerCount,
                expectedExternalHandlerCount: expectedExternalHandlerCount,
                expectedHandlerCount: expectedProductionHandlerCount + expectedExternalHandlerCount,
                status: "PASS",
                frames: pending.count,
                commandBuffersCommitted: pending.count,
                commandBuffersCompleted: pending.count,
                error: nil
            )
        )
    }

    private func loadManifest(environment: [String: String]) throws -> RealMediaRegressionManifest {
        let path = environment["HDR_REAL_MEDIA_REGRESSION_MANIFEST"] ??
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("Tests/RealMediaRegression/manifest.json")
                .path
        return try RealMediaRegressionManifest.load(from: URL(fileURLWithPath: path))
    }

    private func loadGates(environment: [String: String]) throws -> RegressionGates {
        let path = environment["HDR_REAL_MEDIA_REGRESSION_GATES"] ??
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("Tests/RealMediaRegression/gates.json")
                .path
        return try RegressionGates.load(from: URL(fileURLWithPath: path))
    }

    private func emitResult(_ result: HDRStageIsolationResult) {
        guard let data = try? JSONEncoder().encode(result) else { return }
        FileHandle.standardError.write(
            Data("HDR_STAGE_RESULT \(String(decoding: data, as: UTF8.self))\n".utf8)
        )
    }
}
