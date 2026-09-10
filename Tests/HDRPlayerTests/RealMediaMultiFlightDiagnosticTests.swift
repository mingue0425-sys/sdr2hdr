import Foundation
import Metal
import XCTest
@testable import HDRCore
@testable import HDRPlayerKit

private struct RealMediaMultiFlightDiagnosticEnvironment: Codable, Sendable {
    let os: String
    let kernel: String
    let architecture: String
    let metalDevice: String
    let fixture: String
    let frames: Int
    let flightDepth: Int
    let mode: RegressionMode
}

private struct RealMediaMultiFlightDiagnosticPayload: Codable, Sendable {
    let schemaVersion: Int
    let caseName: String
    let environment: RealMediaMultiFlightDiagnosticEnvironment
    let metalDebugLayer: Bool
    let metalDebugLayerValue: String
    let schedulingWork: Bool
    let schedulingWorkBytes: Int
    let schedulingWorkPasses: Int
    let schedulingWorkStorageMode: String
    let schedulingWorkEncoder: String
    let presentationAudit: RealMediaMultiFlightPresentationAudit
    let completionObserverEnabled: Bool
    let status: String
    let error: String?
    let result: RealMediaMultiFlightFixtureResult?
}

private struct RealMediaMultiFlightPresentationAudit: Codable, Sendable {
    let perCommandWritableDiagnosticBuffer: Bool
    let fallbackSourceTextureReadOnly: Bool
    let diagnosticBufferLifetimeUntilGPUCompletion: Bool
}

private let realMediaMultiFlightPresentationAudit = RealMediaMultiFlightPresentationAudit(
    perCommandWritableDiagnosticBuffer: true,
    fallbackSourceTextureReadOnly: true,
    diagnosticBufferLifetimeUntilGPUCompletion: true
)

@MainActor
final class RealMediaMultiFlightDiagnosticTests: XCTestCase {
    func testVMAppleDiagnosticCase() async {
        let processEnvironment = ProcessInfo.processInfo.environment
        guard let caseName = processEnvironment["HDR_MULTIFLIGHT_DIAGNOSTIC_CASE"] else {
            return
        }

        let fixtureID = processEnvironment["HDR_MULTIFLIGHT_DIAGNOSTIC_FIXTURE"] ??
            "h264-8-video-24-chroma-edge"
        let frameCount = max(
            Int(processEnvironment["HDR_MULTIFLIGHT_DIAGNOSTIC_FRAMES"] ?? "2") ?? 2,
            2
        )
        let flightDepth = Int(
            processEnvironment["HDR_MULTIFLIGHT_DIAGNOSTIC_FLIGHT_DEPTH"] ?? "2"
        ) ?? 2
        let modeNames = (processEnvironment["HDR_MULTIFLIGHT_DIAGNOSTIC_MODES"] ?? "nearest")
            .split(separator: ",")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        let diagnosticModes = modeNames.compactMap(RegressionMode.init(rawValue:))
        let debugLayerValue = processEnvironment["MTL_DEBUG_LAYER"] ?? "unset"
        let schedulingWorkEnabled =
            processEnvironment["HDR_MULTIFLIGHT_SCHEDULING_WORK"] == "1"
        let schedulingWorkBytes = max(
            Int(
                processEnvironment["HDR_MULTIFLIGHT_SCHEDULING_WORK_BYTES"] ??
                    String(32 * 1024 * 1024)
            ) ?? (32 * 1024 * 1024),
            1
        )
        let schedulingWorkPasses = max(
            Int(
                processEnvironment["HDR_MULTIFLIGHT_SCHEDULING_WORK_PASSES"] ?? "8"
            ) ?? 8,
            1
        )
        let completionObserverEnabled =
            processEnvironment["HDR_REAL_MEDIA_MULTIFLIGHT_NATIVE_OBSERVER"] == "1"
        let deviceName = MTLCreateSystemDefaultDevice()?.name ?? "unavailable"
        let environment = RealMediaMultiFlightDiagnosticEnvironment(
            os: processEnvironment["HDR_MULTIFLIGHT_DIAGNOSTIC_OS"] ??
                ProcessInfo.processInfo.operatingSystemVersionString,
            kernel: processEnvironment["HDR_MULTIFLIGHT_DIAGNOSTIC_KERNEL"] ?? "unknown",
            architecture: processEnvironment["HDR_MULTIFLIGHT_DIAGNOSTIC_ARCH"] ?? "unknown",
            metalDevice: deviceName,
            fixture: fixtureID,
            frames: frameCount,
            flightDepth: flightDepth,
            mode: diagnosticModes.first ?? .nearest
        )
        writeMetadata(
            environment: environment,
            metalDebugLayer: debugLayerValue == "1",
            metalDebugLayerValue: debugLayerValue,
            schedulingWork: schedulingWorkEnabled,
            schedulingWorkBytes: schedulingWorkEnabled ? schedulingWorkBytes : 0,
            schedulingWorkPasses: schedulingWorkEnabled ? schedulingWorkPasses : 0,
            processEnvironment: processEnvironment
        )

        do {
            guard let device = MTLCreateSystemDefaultDevice() else {
                throw NSError(
                    domain: "RealMediaMultiFlightDiagnosticTests",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Metal device unavailable"]
                )
            }
            let manifest = try loadManifest(processEnvironment: processEnvironment)
            let gates = try loadGates(processEnvironment: processEnvironment)
            guard let fixture = manifest.fixtures.first(where: { $0.id == fixtureID }) else {
                throw NSError(
                    domain: "RealMediaMultiFlightDiagnosticTests",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "fixture not found: \(fixtureID)"]
                )
            }
            guard !diagnosticModes.isEmpty, diagnosticModes.count == modeNames.count else {
                throw NSError(
                    domain: "RealMediaMultiFlightDiagnosticTests",
                    code: 4,
                    userInfo: [NSLocalizedDescriptionKey: "invalid diagnostic mode list"]
                )
            }
            let fixturePath = processEnvironment["HDR_REAL_MEDIA_REGRESSION_FIXTURE_DIR"] ?? ""
            guard !fixturePath.isEmpty else {
                throw NSError(
                    domain: "RealMediaMultiFlightDiagnosticTests",
                    code: 3,
                    userInfo: [NSLocalizedDescriptionKey: "fixture directory is not configured"]
                )
            }
            let runner = RealMediaRegressionRunner(
                manifest: manifest,
                gates: gates,
                fixtureDirectory: URL(fileURLWithPath: fixturePath),
                device: device
            )
            let frames = try await runner.decodeRegressionFrames(
                fixture,
                requiredFrameCount: frameCount
            )
            let result = try await runner.runMultiFlight(
                fixture,
                decodedFrames: frames,
                flightDepth: flightDepth,
                modes: diagnosticModes,
                schedulingWorkEnabled: schedulingWorkEnabled,
                schedulingWorkBytes: schedulingWorkBytes,
                schedulingWorkPasses: schedulingWorkPasses,
                enforceOverlapGate: false,
                completionObserverEnabled: completionObserverEnabled
            )
            writePayload(
                RealMediaMultiFlightDiagnosticPayload(
                    schemaVersion: 1,
                    caseName: caseName,
                    environment: environment,
                    metalDebugLayer: debugLayerValue == "1",
                    metalDebugLayerValue: debugLayerValue,
                    schedulingWork: schedulingWorkEnabled,
                    schedulingWorkBytes: schedulingWorkEnabled ? schedulingWorkBytes : 0,
                    schedulingWorkPasses: schedulingWorkEnabled ? schedulingWorkPasses : 0,
                    schedulingWorkStorageMode: "shared",
                    schedulingWorkEncoder: "blit",
                    presentationAudit: realMediaMultiFlightPresentationAudit,
                    completionObserverEnabled: completionObserverEnabled,
                    status: result.passed ? "PASS" : "FAIL",
                    error: result.passed ? nil : result.failures.joined(separator: "; "),
                    result: result
                ),
                environment: processEnvironment
            )
        } catch {
            writePayload(
                RealMediaMultiFlightDiagnosticPayload(
                    schemaVersion: 1,
                    caseName: caseName,
                    environment: environment,
                    metalDebugLayer: debugLayerValue == "1",
                    metalDebugLayerValue: debugLayerValue,
                    schedulingWork: schedulingWorkEnabled,
                    schedulingWorkBytes: schedulingWorkEnabled ? schedulingWorkBytes : 0,
                    schedulingWorkPasses: schedulingWorkEnabled ? schedulingWorkPasses : 0,
                    schedulingWorkStorageMode: "shared",
                    schedulingWorkEncoder: "blit",
                    presentationAudit: realMediaMultiFlightPresentationAudit,
                    completionObserverEnabled: completionObserverEnabled,
                    status: "ERROR",
                    error: String(describing: error),
                    result: nil
                ),
                environment: processEnvironment
            )
        }
    }

    private func loadManifest(
        processEnvironment: [String: String]
    ) throws -> RealMediaRegressionManifest {
        let path = processEnvironment["HDR_REAL_MEDIA_REGRESSION_MANIFEST"] ??
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("Tests/RealMediaRegression/manifest.json")
                .path
        return try RealMediaRegressionManifest.load(from: URL(fileURLWithPath: path))
    }

    private func loadGates(
        processEnvironment: [String: String]
    ) throws -> RegressionGates {
        let path = processEnvironment["HDR_REAL_MEDIA_REGRESSION_GATES"] ??
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("Tests/RealMediaRegression/gates.json")
                .path
        return try RegressionGates.load(from: URL(fileURLWithPath: path))
    }

    private func writePayload(
        _ payload: RealMediaMultiFlightDiagnosticPayload,
        environment: [String: String]
    ) {
        guard let path = environment["HDR_MULTIFLIGHT_DIAGNOSTIC_RESULT"] else { return }
        let url = URL(fileURLWithPath: path)
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(payload).write(to: url, options: .atomic)
        } catch {
            FileHandle.standardError.write(
                Data("MULTIFLIGHT_DIAGNOSTIC_RESULT_WRITE_ERROR \(error)\n".utf8)
            )
        }
    }

    private func writeMetadata(
        environment: RealMediaMultiFlightDiagnosticEnvironment,
        metalDebugLayer: Bool,
        metalDebugLayerValue: String,
        schedulingWork: Bool,
        schedulingWorkBytes: Int,
        schedulingWorkPasses: Int,
        processEnvironment: [String: String]
    ) {
        guard let path = processEnvironment["HDR_MULTIFLIGHT_DIAGNOSTIC_METADATA"] else { return }
        let document: [String: Any] = [
            "environment": [
                "os": environment.os,
                "kernel": environment.kernel,
                "architecture": environment.architecture,
                "metalDevice": environment.metalDevice,
                "fixture": environment.fixture,
                "frames": environment.frames,
                "flightDepth": environment.flightDepth,
                "mode": environment.mode.rawValue,
            ],
            "metalDebugLayer": metalDebugLayer,
            "metalDebugLayerValue": metalDebugLayerValue,
            "schedulingWork": schedulingWork,
            "schedulingWorkBytes": schedulingWorkBytes,
            "schedulingWorkPasses": schedulingWorkPasses,
            "schedulingWorkStorageMode": "shared",
            "schedulingWorkEncoder": "blit",
        ]
        guard JSONSerialization.isValidJSONObject(document) else { return }
        do {
            let url = URL(fileURLWithPath: path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys])
                .write(to: url, options: .atomic)
        } catch {
            FileHandle.standardError.write(
                Data("MULTIFLIGHT_DIAGNOSTIC_METADATA_WRITE_ERROR \(error)\n".utf8)
            )
        }
    }
}
