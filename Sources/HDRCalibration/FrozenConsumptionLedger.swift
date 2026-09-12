import Darwin
import Foundation

/// Local, durable one-use boundary for the V4/V6 evaluator. Claims precede
/// objective media materialization and survive failures and process restarts.
/// This is an accidental-reuse guard, not a sandbox against deleting the ledger,
/// using another checkout, or invoking a historical evaluator directly.
struct FrozenConsumptionLedger {
    let directory: URL

    init(repositoryRoot: URL) {
        directory = repositoryRoot.appendingPathComponent(".hdr-frozen-consumption", isDirectory: true)
    }

    private struct Receipt: Encodable {
        let version = 1
        let state = "CONSUMED_BEFORE_OBJECTIVE_DECODE"
        let createdAt: String
        let planSHA256: String
        let inputHashes: [V6InputHashes]
        let freeze: V4FreezeArtifact
    }

    func claim(inputHashes: [V6InputHashes], planSHA256: String, freeze: V4FreezeArtifact) throws {
        let hashes = Set(inputHashes.flatMap { [$0.sdrSHA256, $0.hdrSHA256] })
        func isSHA256(_ value: String) -> Bool {
            value.utf8.count == 64 && value.utf8.allSatisfy {
                (48...57).contains($0) || (97...102).contains($0)
            }
        }
        guard !hashes.isEmpty, hashes.allSatisfy(isSHA256), isSHA256(planSHA256),
              freeze.finalCandidateFrozen, !freeze.frozenOpened,
              freeze.workingTreeDirty == false else {
            throw CalibrationError.invalidCandidate("invalid Frozen consumption claim")
        }
        let receipt = Receipt(createdAt: ISO8601DateFormatter().string(from: Date()),
                              planSHA256: planSHA256, inputHashes: inputHashes, freeze: freeze)
        let payload = try JSONEncoder().encode(receipt)
        if Darwin.mkdir(directory.path, 0o700) != 0 && errno != EEXIST {
            throw failure("create ledger")
        }
        // A directory descriptor keeps claim creation bound to the same ledger.
        // No path from the manifest is ever opened by this operation.
        let directoryFD = Darwin.open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directoryFD >= 0 else { throw failure("open ledger") }
        defer { Darwin.close(directoryFD) }
        for hash in hashes.sorted() {
            let fd = Darwin.openat(directoryFD, hash + ".json",
                                   O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard fd >= 0 else {
                if errno == EEXIST {
                    throw CalibrationError.invalidCandidate(
                        "Frozen asset was already claimed; retry is forbidden (ledger: \(directory.path))"
                    )
                }
                throw failure("create claim")
            }
            defer { Darwin.close(fd) }
            // Even an empty/partial receipt permanently consumes this asset.
            // Never roll claims back after a write error or partial acquisition.
            try payload.withUnsafeBytes { bytes in
                var offset = 0
                while offset < bytes.count {
                    let written = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                    if written < 0 && errno == EINTR { continue }
                    guard written > 0 else { throw failure("write claim") }
                    offset += written
                }
            }
            guard Darwin.fsync(fd) == 0, Darwin.fsync(directoryFD) == 0 else {
                throw failure("sync claim")
            }
        }
        // Persist creation of the ledger itself before any objective decoding.
        let parentFD = Darwin.open(directory.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard parentFD >= 0 else { throw failure("open ledger parent") }
        defer { Darwin.close(parentFD) }
        guard Darwin.fsync(parentFD) == 0 else { throw failure("sync ledger parent") }
    }

    private func failure(_ operation: String) -> CalibrationError {
        .invalidCandidate("Frozen ledger \(operation) failed (errno \(errno)); no retry or automatic cleanup is permitted")
    }
}
