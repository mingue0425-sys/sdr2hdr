import Foundation
import Metal
import XCTest
@testable import HDRCore

/// SwiftPM packages shaders differently depending on the build system and
/// whether the Metal Toolchain is installed: a named metallib, a single
/// `default.metallib` without sources, or raw `.metal` sources. The loader
/// must accept each layout and reject a library missing required kernels.
final class MetalLibraryLoaderTests: XCTestCase {
    private let source = """
    #include <metal_stdlib>
    using namespace metal;
    kernel void loaderProbeA(device float* out [[buffer(0)]]) { out[0] = 1.0f; }
    kernel void loaderProbeB(device float* out [[buffer(0)]]) { out[0] = 2.0f; }
    """

    func testRuntimeSourceIsUsedWhenNoPrecompiledLibraryExists() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let bundle = try makeBundle(files: ["Probe.metal": Data(source.utf8)])
        let loaded = try HDRMetalLibraryLoader.load(
            device: device, bundle: bundle, name: "Probe",
            requiredFunctions: ["loaderProbeA", "loaderProbeB"]
        )
        XCTAssertEqual(loaded.origin, .runtimeSource)
    }

    func testDefaultMetallibWithoutSourcesIsAccepted() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let metallib = try compiledLibraryData()
        let bundle = try makeBundle(files: ["default.metallib": metallib])
        let loaded = try HDRMetalLibraryLoader.load(
            device: device, bundle: bundle, name: "Probe",
            requiredFunctions: ["loaderProbeA", "loaderProbeB"]
        )
        XCTAssertEqual(loaded.origin, .defaultMetallib)
        XCTAssertNotNil(loaded.library.makeFunction(name: "loaderProbeB"))
    }

    func testNamedMetallibTakesPrecedence() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let metallib = try compiledLibraryData()
        let bundle = try makeBundle(files: [
            "Probe.metallib": metallib,
            "default.metallib": metallib,
            "Probe.metal": Data(source.utf8)
        ])
        let loaded = try HDRMetalLibraryLoader.load(
            device: device, bundle: bundle, name: "Probe",
            requiredFunctions: ["loaderProbeA"]
        )
        XCTAssertEqual(loaded.origin, .namedMetallib)
    }

    func testIncompletePrecompiledLibraryFallsBackToSource() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let metallib = try compiledLibraryData()
        let complete = source + "\nkernel void loaderProbeC(device float* out [[buffer(0)]]) { out[0] = 3.0f; }\n"
        let bundle = try makeBundle(files: [
            "default.metallib": metallib,
            "Probe.metal": Data(complete.utf8)
        ])
        let loaded = try HDRMetalLibraryLoader.load(
            device: device, bundle: bundle, name: "Probe",
            requiredFunctions: ["loaderProbeA", "loaderProbeC"]
        )
        XCTAssertEqual(loaded.origin, .runtimeSource)
    }

    func testMissingEverythingReportsMissingSource() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let bundle = try makeBundle(files: [:])
        XCTAssertThrowsError(try HDRMetalLibraryLoader.load(
            device: device, bundle: bundle, name: "Probe", requiredFunctions: ["loaderProbeA"]
        )) { error in
            XCTAssertEqual(error as? HDRMetalLibraryLoader.Failure, .sourceMissing)
        }
    }

    func testProductionResourcesLoadWithEveryKernel() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let context = try MetalContext(device: device)
        // Whatever layout this build produced, the processor must come up.
        XCTAssertTrue([.namedMetallib, .defaultMetallib, .runtimeSource].contains(context.libraryOrigin))
        let hasPrecompiled = Bundle.module.url(forResource: "default", withExtension: "metallib") != nil ||
            Bundle.module.url(forResource: "SDRToHDR", withExtension: "metallib") != nil
        if hasPrecompiled {
            XCTAssertNotEqual(context.libraryOrigin, .runtimeSource,
                              "a precompiled library was bundled but runtime compilation was used")
        }
    }

    // MARK: - Helpers

    private func compiledLibraryData() throws -> Data {
        // Precompiled-layout fixtures need the offline Metal Toolchain.
        guard let metal = Self.toolPath("metal"), let metallibTool = Self.toolPath("metallib") else {
            throw XCTSkip("Metal Toolchain is required to build a metallib fixture")
        }
        let root = try temporaryDirectory()
        let sourceURL = root.appendingPathComponent("probe.metal")
        let airURL = root.appendingPathComponent("probe.air")
        let libURL = root.appendingPathComponent("probe.metallib")
        try Data(source.utf8).write(to: sourceURL)
        try run(metal, ["-c", sourceURL.path, "-o", airURL.path])
        try run(metallibTool, [airURL.path, "-o", libURL.path])
        return try Data(contentsOf: libURL)
    }

    private static func toolPath(_ name: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["--find", name]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let path = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        // `xcrun --find metal` succeeds without the toolchain; probe it.
        let probe = Process()
        probe.executableURL = URL(fileURLWithPath: path)
        probe.arguments = ["--version"]
        probe.standardOutput = FileHandle.nullDevice
        probe.standardError = FileHandle.nullDevice
        guard (try? probe.run()) != nil else { return nil }
        probe.waitUntilExit()
        return probe.terminationStatus == 0 ? path : nil
    }

    private func run(_ executable: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "\(executable) failed")
    }

    private func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("hdr-metal-loader-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func makeBundle(files: [String: Data]) throws -> Bundle {
        let root = try temporaryDirectory().appendingPathComponent("Probe.bundle")
        let resources = root.appendingPathComponent("Contents/Resources")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        let plist: [String: Any] = [
            "CFBundleIdentifier": "test.hdr.loader.\(UUID().uuidString)",
            "CFBundlePackageType": "BNDL"
        ]
        let plistData = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try plistData.write(to: root.appendingPathComponent("Contents/Info.plist"))
        for (name, data) in files {
            try data.write(to: resources.appendingPathComponent(name))
        }
        return try XCTUnwrap(Bundle(url: root))
    }
}
