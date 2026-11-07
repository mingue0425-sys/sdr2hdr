import CryptoKit
import Darwin
import Foundation
import XCTest
@testable import HDRCalibration

final class HashMemoryTests: XCTestCase {
    private func physicalFootprintBytes() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : 0
    }

    /// Hashing streams the file: the digest is unchanged, and an async caller
    /// does not keep every 1 MiB chunk alive until the file ends.
    func testStreamingHashMatchesOneShotDigestWithBoundedFootprint() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("hash-memory-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: url) }
        let chunk = Data((0..<1_048_576).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let writer = try FileHandle(forWritingTo: url)
        var expected = SHA256()
        for index in 0..<96 {
            var block = chunk
            block[0] = UInt8(index)
            writer.write(block)
            expected.update(data: block)
        }
        try writer.close()
        let expectedHex = expected.finalize().map { String(format: "%02x", $0) }.joined()

        await Task.yield()
        let before = physicalFootprintBytes()
        let digest = try V4DatasetIntegrity.sha256(url: url)
        let after = physicalFootprintBytes()
        XCTAssertEqual(digest, expectedHex)
        if before > 0, after > 0 {
            XCTAssertLessThan(
                Int64(after) - Int64(before), 48 * 1_048_576,
                "hashing a 96 MiB file grew the footprint by \((Int64(after) - Int64(before)) / 1_048_576) MiB"
            )
        }
    }
}
