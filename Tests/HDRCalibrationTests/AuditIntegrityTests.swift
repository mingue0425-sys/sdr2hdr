import Foundation
import CoreVideo
import HDRCore
import XCTest
@testable import HDRCalibration

private final class ClaimCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}

final class AuditIntegrityTests: XCTestCase {
    func testSourceLinearLuminanceHonorsSRGBMetadata() throws {
        var created: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, 2, 2, kCVPixelFormatType_32BGRA, nil, &created), kCVReturnSuccess)
        let buffer = try XCTUnwrap(created)
        CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey,
                              kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey,
                              kCVImageBufferTransferFunction_sRGB, .shouldPropagate)
        XCTAssertEqual(CVPixelBufferLockBaseAddress(buffer, []), kCVReturnSuccess)
        let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(buffer))
        memset(base, 128, CVPixelBufferGetBytesPerRow(buffer) * 2)
        CVPixelBufferUnlockBaseAddress(buffer, [])
        let luma = try OfflinePixelSampler.linearLumaGrid(pixelBuffer: buffer, width: 1, height: 1)
        let expected = pow((128.0 / 255.0 + 0.055) / 1.055, 2.4)
        XCTAssertEqual(Double(try XCTUnwrap(luma.first)), expected, accuracy: 1e-6)
    }

    func testConcurrentFrozenClaimsHaveExactlyOneWinner() throws {
        try withTemporaryRepository { root in
            let counter = ClaimCounter()
            let inputs = [V6InputHashes(sdrSHA256: hash("a"), hdrSHA256: hash("b"))]
            let planHash = hash("c")
            let artifact = freeze()
            DispatchQueue.concurrentPerform(iterations: 8) { _ in
                do {
                    try FrozenConsumptionLedger(repositoryRoot: root).claim(
                        inputHashes: inputs, planSHA256: planHash, freeze: artifact)
                    counter.increment()
                } catch { /* Exclusive creation rejects the competing claims. */ }
            }
            XCTAssertEqual(counter.value, 1)
        }
    }

    func testSignedMidtoneDiagnosticRetainsUnderPrediction() {
        let frame = V2FrameData(
            reference: ReferenceFrame(timestampSeconds: 0, width: 1, height: 1,
                                      rgbNits: [SIMD3(repeating: 100)]),
            generated: GeneratedFrame(timestampSeconds: 0, width: 1, height: 1,
                                      rgbNits: [SIMD3(repeating: 50)]),
            sourceLuma: [0.3], confidence: 1
        )
        let result = V2MetricsEvaluator.evaluateScene(
            pairID: "synthetic", scene: SceneRange(id: "one", startSample: 0, endSample: 0, tags: []),
            frames: [frame], configuration: CalibrationParameters(configuration: .calibratedV4),
            weights: V2ObjectiveWeights()
        )
        XCTAssertEqual(result.metrics.luminanceRegionErrors["diffuse_midtone_signed"] ?? .nan,
                       log(51.0 / 101.0), accuracy: 1e-7)
        XCTAssertGreaterThan(result.metrics.luminanceRegionErrors["diffuse_midtone_negative_undershoot"] ?? 0, 0)
    }

    func testFrozenClaimSurvivesNewInstanceAndDifferentPlanAndCandidate() throws {
        try withTemporaryRepository { root in
            let inputs = [V6InputHashes(sdrSHA256: hash("a"), hdrSHA256: hash("b"))]
            try FrozenConsumptionLedger(repositoryRoot: root).claim(
                inputHashes: inputs, planSHA256: hash("c"), freeze: freeze())
            var changed = freeze()
            changed.candidateID = "different-candidate"
            XCTAssertThrowsError(try FrozenConsumptionLedger(repositoryRoot: root).claim(
                inputHashes: inputs, planSHA256: hash("d"), freeze: changed))
            // Reusing just one asset, even in the other role, is also consumed.
            XCTAssertThrowsError(try FrozenConsumptionLedger(repositoryRoot: root).claim(
                inputHashes: [V6InputHashes(sdrSHA256: hash("b"), hdrSHA256: hash("e"))],
                planSHA256: hash("d"), freeze: changed))
            XCTAssertNoThrow(try FrozenConsumptionLedger(repositoryRoot: root).claim(
                inputHashes: [V6InputHashes(sdrSHA256: hash("f"), hdrSHA256: hash("0"))],
                planSHA256: hash("d"), freeze: changed))
        }
    }

    func testEmptyClaimLeftByCrashFailsClosed() throws {
        try withTemporaryRepository { root in
            let ledger = FrozenConsumptionLedger(repositoryRoot: root)
            try FileManager.default.createDirectory(at: ledger.directory, withIntermediateDirectories: true)
            try Data().write(to: ledger.directory.appendingPathComponent(hash("a") + ".json"))
            XCTAssertThrowsError(try ledger.claim(
                inputHashes: [V6InputHashes(sdrSHA256: hash("a"), hdrSHA256: hash("b"))],
                planSHA256: hash("c"), freeze: freeze()))
        }
    }

    func testInvalidFrozenIdentityDoesNotCreateLedger() throws {
        try withTemporaryRepository { root in
            let ledger = FrozenConsumptionLedger(repositoryRoot: root)
            XCTAssertThrowsError(try ledger.claim(
                inputHashes: [V6InputHashes(sdrSHA256: "../bad", hdrSHA256: hash("b"))],
                planSHA256: hash("c"), freeze: freeze()))
            XCTAssertFalse(FileManager.default.fileExists(atPath: ledger.directory.path))
        }
    }

    private func hash(_ value: Character) -> String { String(repeating: String(value), count: 64) }

    private func freeze() -> V4FreezeArtifact {
        V4FreezeArtifact(candidateID: "synthetic", parameters: CalibrationParameters(configuration: .calibratedV4),
                         parameterHash: hash("1"), codeHash: hash("2"), manifestHash: hash("3"),
                         objectiveHash: hash("4"), finalCandidateFrozen: true, frozenOpened: false,
                         workingTreeDirty: false)
    }

    private func withTemporaryRepository(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("hdr-audit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }
}
