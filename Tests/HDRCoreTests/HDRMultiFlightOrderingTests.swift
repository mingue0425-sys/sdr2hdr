import CoreMedia
import CoreVideo
import Foundation
import Metal
import XCTest
@testable import HDRCore

final class HDRMultiFlightOrderingTests: XCTestCase {
    func testOutOfOrderCompletionKeepsNewestAdaptiveSequence() {
        let store = HDRAdaptiveStateStore()
        store.advanceGeneration(to: 1, resetTemporal: true, resetScene: true)
        let statistics = HDRSceneStatistics(samples: [0.01, 0.20, 0.80])

        XCTAssertTrue(store.recordGPUCompletion(sequence: 3, generation: 1))
        let accepted = store.updateAutomatic(
            statistics: statistics,
            averageLuminance: 0.40,
            stability: 0.5,
            sequence: 3,
            generation: 1,
            timestampSeconds: 0.125,
            sceneRelativeEnabled: true
        )
        XCTAssertTrue(accepted.applied)

        for sequence: UInt64 in [1, 2] {
            XCTAssertTrue(store.recordGPUCompletion(sequence: sequence, generation: 1))
            let rejected = store.updateAutomatic(
                statistics: statistics,
                averageLuminance: 0.10,
                stability: 0.5,
                sequence: sequence,
                generation: 1,
                timestampSeconds: Double(sequence) / 24,
                sceneRelativeEnabled: true
            )
            XCTAssertFalse(rejected.applied)
        }

        let snapshot = store.snapshot()
        XCTAssertEqual(snapshot.lastGPUCompletedSequence, 3)
        XCTAssertEqual(snapshot.lastAdaptiveCommittedSequence, 3)
        XCTAssertEqual(snapshot.committedSequence, 3)
        XCTAssertTrue(snapshot.transactionInvariantHolds(sceneRelativeEnabled: true))
    }

    func testGenerationResetRejectsLateInFlightCompletions() {
        let store = HDRAdaptiveStateStore()
        store.advanceGeneration(to: 10, resetTemporal: true, resetScene: true)
        let statistics = HDRSceneStatistics(samples: [0.01, 0.20, 0.80])

        XCTAssertTrue(store.recordGPUCompletion(sequence: 3, generation: 10))
        XCTAssertTrue(
            store.updateAutomatic(
                statistics: statistics,
                averageLuminance: 0.40,
                stability: 0.5,
                sequence: 3,
                generation: 10,
                timestampSeconds: 0.125,
                sceneRelativeEnabled: true
            ).applied
        )

        store.advanceGeneration(to: 11, resetTemporal: true, resetScene: true)
        XCTAssertFalse(store.recordGPUCompletion(sequence: 4, generation: 10))
        XCTAssertFalse(
            store.updateAutomatic(
                statistics: statistics,
                averageLuminance: 0.90,
                stability: 0,
                sequence: 4,
                generation: 10,
                timestampSeconds: 0.2,
                sceneRelativeEnabled: true
            ).applied
        )

        XCTAssertTrue(store.recordGPUCompletion(sequence: 1, generation: 11))
        XCTAssertTrue(
            store.updateAutomatic(
                statistics: statistics,
                averageLuminance: 0.30,
                stability: 0.5,
                sequence: 1,
                generation: 11,
                timestampSeconds: 0.01,
                sceneRelativeEnabled: true
            ).applied
        )
        let snapshot = store.snapshot()
        XCTAssertEqual(snapshot.generation, 11)
        XCTAssertEqual(snapshot.lastGPUCompletedSequence, 1)
        XCTAssertEqual(snapshot.lastAdaptiveCommittedSequence, 1)
        XCTAssertTrue(snapshot.transactionInvariantHolds(sceneRelativeEnabled: true))
    }

    func testGenerationAndOrderingStressRunsOneHundredIterations() {
        let store = HDRAdaptiveStateStore()
        let statistics = HDRSceneStatistics(samples: [0.01, 0.20, 0.80])

        for iteration in 0..<100 {
            let oldGeneration = UInt64(iteration * 2 + 1)
            let newGeneration = oldGeneration + 1
            store.advanceGeneration(to: oldGeneration, resetTemporal: true, resetScene: true)
            XCTAssertTrue(store.recordGPUCompletion(sequence: 3, generation: oldGeneration))
            XCTAssertTrue(
                store.updateAutomatic(
                    statistics: statistics,
                    averageLuminance: 0.40,
                    stability: 0.5,
                    sequence: 3,
                    generation: oldGeneration,
                    timestampSeconds: 0.1,
                    sceneRelativeEnabled: true
                ).applied
            )

            store.advanceGeneration(to: newGeneration, resetTemporal: true, resetScene: true)
            XCTAssertFalse(store.recordGPUCompletion(sequence: 4, generation: oldGeneration))
            XCTAssertFalse(
                store.updateAutomatic(
                    statistics: statistics,
                    averageLuminance: 0.90,
                    stability: 0,
                    sequence: 4,
                    generation: oldGeneration,
                    timestampSeconds: 0.2,
                    sceneRelativeEnabled: true
                ).applied
            )
            XCTAssertTrue(store.recordGPUCompletion(sequence: 1, generation: newGeneration))
            XCTAssertTrue(
                store.updateAutomatic(
                    statistics: statistics,
                    averageLuminance: 0.30,
                    stability: 0.5,
                    sequence: 1,
                    generation: newGeneration,
                    timestampSeconds: 0.01,
                    sceneRelativeEnabled: true
                ).applied
            )

            let snapshot = store.snapshot()
            XCTAssertEqual(snapshot.generation, newGeneration)
            XCTAssertEqual(snapshot.lastGPUCompletedSequence, 1)
            XCTAssertEqual(snapshot.lastAdaptiveCommittedSequence, 1)
            XCTAssertTrue(snapshot.transactionInvariantHolds(sceneRelativeEnabled: true))
        }
    }

    func testThreeSlotPoolRejectsPrematureFourthLeaseAndAllowsReuseAfterRetirement() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device unavailable")
        }
        let processor = try HDRProcessor(device: device, configuration: .calibratedV4)
        let pixelBuffer = try makeBGRA(width: 32, height: 18, value: 0.45)
        var retainedFrames: [HDRFrame] = []
        var commandBuffers: [MTLCommandBuffer] = []

        for index in 0..<3 {
            let commandBuffer = try processor.makeCommandBuffer()
            let frame = try processor.process(
                pixelBuffer: pixelBuffer,
                timestamp: CMTime(value: Int64(index), timescale: 24),
                commandBuffer: commandBuffer,
                diagnosticFrameIndex: UInt64(index + 1)
            )
            retainedFrames.append(frame)
            commandBuffers.append(commandBuffer)
        }
        XCTAssertEqual(processor.runtimeMetrics.outputTextureAllocations, 3)

        let fourthCommandBuffer = try processor.makeCommandBuffer()
        XCTAssertThrowsError(
            try processor.process(
                pixelBuffer: pixelBuffer,
                timestamp: CMTime(value: 3, timescale: 24),
                commandBuffer: fourthCommandBuffer,
                diagnosticFrameIndex: 4
            )
        )

        commandBuffers.forEach { commandBuffer in
            commandBuffer.commit()
            commandBuffer.waitUntilCompleted()
            XCTAssertEqual(commandBuffer.status, .completed)
            XCTAssertNil(commandBuffer.error)
        }

        let stillHeldCommandBuffer = try processor.makeCommandBuffer()
        XCTAssertThrowsError(
            try processor.process(
                pixelBuffer: pixelBuffer,
                timestamp: CMTime(value: 4, timescale: 24),
                commandBuffer: stillHeldCommandBuffer,
                diagnosticFrameIndex: 5
            )
        )

        retainedFrames.removeFirst()
        let reuseCommandBuffer = try processor.makeCommandBuffer()
        _ = try processor.process(
            pixelBuffer: pixelBuffer,
            timestamp: CMTime(value: 5, timescale: 24),
            commandBuffer: reuseCommandBuffer,
            diagnosticFrameIndex: 6
        )
        reuseCommandBuffer.commit()
        reuseCommandBuffer.waitUntilCompleted()
        XCTAssertEqual(reuseCommandBuffer.status, .completed)
        XCTAssertNil(reuseCommandBuffer.error)
        XCTAssertEqual(processor.runtimeMetrics.outputTextureAllocations, 3)
    }

    func testDroppedSourceFrameUsesMonotonicSubmissionIdentity() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device unavailable")
        }
        let processor = try HDRProcessor(device: device, configuration: .calibratedV4)
        processor.temporalTraceEnabled = true
        let pixelBuffer = try makeBGRA(width: 32, height: 18, value: 0.45)
        let sourceIndices = [0, 1, 3, 4]
        var pending: [(commandBuffer: MTLCommandBuffer, frame: HDRFrame)] = []

        func retireOldest() {
            guard !pending.isEmpty else { return }
            let retired = pending.removeFirst()
            retired.commandBuffer.waitUntilCompleted()
        }

        for sourceIndex in sourceIndices {
            while pending.count >= 2 { retireOldest() }
            let commandBuffer = try processor.makeCommandBuffer()
            let frame = try processor.process(
                pixelBuffer: pixelBuffer,
                timestamp: CMTime(value: Int64(sourceIndex), timescale: 24),
                commandBuffer: commandBuffer,
                diagnosticFrameIndex: UInt64(sourceIndex + 1)
            )
            commandBuffer.commit()
            pending.append((commandBuffer, frame))
        }
        while !pending.isEmpty { retireOldest() }

        XCTAssertEqual(processor.temporalSubmissionTrace.map(\.submissionSequence), [1, 2, 3, 4])
        XCTAssertEqual(processor.lastGPUCompletedSequence, 4)
        XCTAssertEqual(processor.lastAdaptiveCommittedSequence, 4)
        XCTAssertTrue(processor.temporalCompletionTrace.allSatisfy {
            $0.adaptiveCommittedSequence == $0.submissionSequence
        })
    }

    func testProcessorResetRejectsMultipleOldInFlightCompletions() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device unavailable")
        }
        let processor = try HDRProcessor(device: device, configuration: .calibratedV4)
        processor.temporalTraceEnabled = true
        processor.clearTemporalTrace()
        let pixelBuffer = try makeBGRA(width: 32, height: 18, value: 0.45)
        var oldFrames: [HDRFrame] = []
        var oldCommands: [MTLCommandBuffer] = []

        for index in 0..<3 {
            let commandBuffer = try processor.makeCommandBuffer()
            oldFrames.append(try processor.process(
                pixelBuffer: pixelBuffer,
                timestamp: CMTime(value: Int64(index), timescale: 24),
                commandBuffer: commandBuffer,
                diagnosticFrameIndex: UInt64(index + 1)
            ))
            oldCommands.append(commandBuffer)
        }
        let oldGeneration = processor.temporalGeneration
        processor.clearTemporalHistory()
        let newGeneration = processor.temporalGeneration
        XCTAssertGreaterThan(newGeneration, oldGeneration)

        oldCommands.forEach { commandBuffer in
            commandBuffer.commit()
            commandBuffer.waitUntilCompleted()
        }
        oldFrames.removeAll()

        for index in 0..<2 {
            let commandBuffer = try processor.makeCommandBuffer()
            _ = try processor.process(
                pixelBuffer: pixelBuffer,
                timestamp: CMTime(value: Int64(index), timescale: 24),
                commandBuffer: commandBuffer,
                diagnosticFrameIndex: UInt64(index + 10)
            )
            commandBuffer.commit()
            commandBuffer.waitUntilCompleted()
        }

        XCTAssertEqual(processor.lastGPUCompletedSequence, 5)
        XCTAssertEqual(processor.lastAdaptiveCommittedSequence, 5)
        XCTAssertTrue(processor.temporalCompletionTrace.allSatisfy { $0.generation == newGeneration })
        XCTAssertTrue(processor.temporalCompletionTrace.allSatisfy {
            $0.gpuCompletionSequence == $0.adaptiveCommittedSequence &&
                $0.temporalStateVersionProduced == $0.adaptiveCommittedSequence &&
                $0.sceneStateVersionProduced == $0.adaptiveCommittedSequence
        })
    }

    private func makeBGRA(width: Int, height: Int, value: Float) throws -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            [
                kCVPixelBufferMetalCompatibilityKey as String: true,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:]
            ] as CFDictionary,
            &pixelBuffer
        )
        guard status == kCVReturnSuccess, let pixelBuffer else {
            throw NSError(domain: "HDRMultiFlightOrderingTests", code: Int(status))
        }
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            throw NSError(
                domain: "HDRMultiFlightOrderingTests",
                code: Int(kCVReturnInvalidArgument)
            )
        }
        let bytes = baseAddress.assumingMemoryBound(to: UInt8.self)
        let rowBytes = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let channel = UInt8(min(max(Int((value * 255).rounded()), 0), 255))
        for y in 0..<height {
            let row = bytes.advanced(by: y * rowBytes)
            for x in 0..<width {
                let offset = x * 4
                row[offset] = channel
                row[offset + 1] = channel
                row[offset + 2] = channel
                row[offset + 3] = 255
            }
        }
        return pixelBuffer
    }
}
