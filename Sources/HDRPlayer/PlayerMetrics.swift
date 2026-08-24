import CoreMedia
import Darwin
import Foundation
import Metal

public struct PlayerMetricsSnapshot: Sendable {
    public let displayCallbacks: Int
    public let processedHDRFrames: Int
    public let presentedFrames: Int
    public let reusedFrames: Int
    public let lateDroppedFrames: Int
    public let sourceUnavailableFrames: Int
    public let drawableMisses: Int
    public let inFlightSaturation: Int
    public let displayLinkRestarts: Int
    public let gpuRenderP50: Double?
    public let gpuRenderP95: Double?
    public let cpuSubmissionP50: Double?
    public let cpuSubmissionP95: Double?
    public let wallPlaybackSeconds: Double?
    public let startupResidentBytes: Int64?
    public let endResidentBytes: Int64?

    public var debugLine: String {
        "FPS callbacks=\(displayCallbacks), processed=\(processedHDRFrames), presented=\(presentedFrames), reused=\(reusedFrames), lateDrop=\(lateDroppedFrames), sourceUnavailable=\(sourceUnavailableFrames), drawableMiss=\(drawableMisses), poolBusy=\(inFlightSaturation), linkRestarts=\(displayLinkRestarts), GPU render p50/p95=\(format(gpuRenderP50))/\(format(gpuRenderP95)) ms, CPU submit p50/p95=\(format(cpuSubmissionP50))/\(format(cpuSubmissionP95)) ms"
    }

    private func format(_ value: Double?) -> String {
        guard let value else { return "NOT_MEASURED" }
        return String(format: "%.3f", value)
    }
}

public final class PlayerMetrics: @unchecked Sendable {
    private let lock = NSLock()
    private let sampleLimit = 512
    private var displayCallbacks = 0
    private var processedHDRFrames = 0
    private var presentedFrames = 0
    private var reusedFrames = 0
    private var lateDroppedFrames = 0
    private var sourceUnavailableFrames = 0
    private var drawableMisses = 0
    private var inFlightSaturation = 0
    private var displayLinkRestarts = 0
    private var gpuRenderSamples: [Double] = []
    private var cpuSubmissionSamples: [Double] = []
    private var playbackStartUptime: Double?
    private var playbackEndUptime: Double?
    private var startupResidentBytes: Int64?
    private var endResidentBytes: Int64?

    public init() {}

    public func markPlaybackStarted() {
        lock.lock()
        if playbackStartUptime == nil {
            playbackStartUptime = ProcessInfo.processInfo.systemUptime
            startupResidentBytes = currentResidentMemoryBytes()
        }
        lock.unlock()
    }

    public func markPlaybackEnded() {
        lock.lock()
        if playbackEndUptime == nil {
            playbackEndUptime = ProcessInfo.processInfo.systemUptime
            endResidentBytes = currentResidentMemoryBytes()
        }
        lock.unlock()
    }

    public func recordDisplayCallback() { increment { displayCallbacks += 1 } }
    public func recordProcessedFrame() { increment { processedHDRFrames += 1 } }
    public func recordPresentedFrame() { increment { presentedFrames += 1 } }
    public func recordReusedFrame() { increment { reusedFrames += 1 } }
    public func recordLateDrop() { increment { lateDroppedFrames += 1 } }
    public func recordSourceUnavailable() { increment { sourceUnavailableFrames += 1 } }
    public func recordDrawableMiss() { increment { drawableMisses += 1 } }
    public func recordInFlightSaturation() { increment { inFlightSaturation += 1 } }
    public func recordDisplayLinkRestart() { increment { displayLinkRestarts += 1 } }

    public func recordSubmission(cpuMilliseconds: Double) {
        lock.lock()
        append(cpuMilliseconds, to: &cpuSubmissionSamples)
        lock.unlock()
    }

    public func recordGPU(milliseconds: Double) {
        guard milliseconds.isFinite, milliseconds >= 0 else { return }
        lock.lock()
        append(milliseconds, to: &gpuRenderSamples)
        lock.unlock()
    }

    public func snapshot() -> PlayerMetricsSnapshot {
        lock.lock()
        defer { lock.unlock() }
        let wall: Double?
        if let start = playbackStartUptime {
            let end = playbackEndUptime ?? ProcessInfo.processInfo.systemUptime
            wall = max(0, end - start)
        } else {
            wall = nil
        }
        return PlayerMetricsSnapshot(
            displayCallbacks: displayCallbacks,
            processedHDRFrames: processedHDRFrames,
            presentedFrames: presentedFrames,
            reusedFrames: reusedFrames,
            lateDroppedFrames: lateDroppedFrames,
            sourceUnavailableFrames: sourceUnavailableFrames,
            drawableMisses: drawableMisses,
            inFlightSaturation: inFlightSaturation,
            displayLinkRestarts: displayLinkRestarts,
            gpuRenderP50: percentile(gpuRenderSamples, fraction: 0.50),
            gpuRenderP95: percentile(gpuRenderSamples, fraction: 0.95),
            cpuSubmissionP50: percentile(cpuSubmissionSamples, fraction: 0.50),
            cpuSubmissionP95: percentile(cpuSubmissionSamples, fraction: 0.95),
            wallPlaybackSeconds: wall,
            startupResidentBytes: startupResidentBytes,
            endResidentBytes: endResidentBytes
        )
    }

    private func increment(_ body: () -> Void) {
        lock.lock()
        body()
        lock.unlock()
    }

    private func append(_ value: Double, to array: inout [Double]) {
        guard value.isFinite else { return }
        if array.count == sampleLimit { array.removeFirst() }
        array.append(value)
    }

    private func percentile(_ values: [Double], fraction: Double) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let index = min(max(Int(Double(sorted.count - 1) * fraction), 0), sorted.count - 1)
        return sorted[index]
    }
}

private func currentResidentMemoryBytes() -> Int64? {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(
        MemoryLayout<mach_task_basic_info>.stride / MemoryLayout<natural_t>.stride
    )
    let result: kern_return_t = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
            task_info(
                mach_task_self_,
                task_flavor_t(MACH_TASK_BASIC_INFO),
                rebound,
                &count
            )
        }
    }
    guard result == KERN_SUCCESS else { return nil }
    return Int64(info.resident_size)
}
