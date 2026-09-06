import CoreMedia
import Darwin
import Foundation
import Metal

public enum PlayerSourceUnavailableReason: String, CaseIterable, Codable, Sendable {
    case noNewPixelBuffer = "NO_NEW_PIXEL_BUFFER"
    case copyPixelBufferFailed = "COPY_PIXEL_BUFFER_FAILED"
    case noLastFrame = "NO_LAST_FRAME"
    case noTexture = "NO_TEXTURE"
    case notReady = "NOT_READY"
    case other = "OTHER"
}

public struct PlayerSourceUnavailableBreakdown: Codable, Equatable, Sendable {
    public let noNewPixelBuffer: Int
    public let copyPixelBufferFailed: Int
    public let noLastFrame: Int
    public let noTexture: Int
    public let notReady: Int
    public let other: Int

    public init(
        noNewPixelBuffer: Int = 0,
        copyPixelBufferFailed: Int = 0,
        noLastFrame: Int = 0,
        noTexture: Int = 0,
        notReady: Int = 0,
        other: Int = 0
    ) {
        self.noNewPixelBuffer = noNewPixelBuffer
        self.copyPixelBufferFailed = copyPixelBufferFailed
        self.noLastFrame = noLastFrame
        self.noTexture = noTexture
        self.notReady = notReady
        self.other = other
    }
}

public struct PlayerStartupMetricsSnapshot: Codable, Equatable, Sendable {
    public let appLaunch: Double?
    public let playerCreated: Double?
    public let prepareCalled: Double?
    public let readyToPlay: Double?
    public let playCalled: Double?
    public let firstDisplayCallback: Double?
    public let firstPixelBufferAvailable: Double?
    public let firstPixelBufferCopied: Double?
    public let firstHDRProcessedFrame: Double?
    public let firstDrawablePresented: Double?
    public let firstNonBlackPresentedFrame: Double?

    public init(
        appLaunch: Double?,
        playerCreated: Double?,
        prepareCalled: Double?,
        readyToPlay: Double?,
        playCalled: Double?,
        firstDisplayCallback: Double?,
        firstPixelBufferAvailable: Double?,
        firstPixelBufferCopied: Double?,
        firstHDRProcessedFrame: Double?,
        firstDrawablePresented: Double?,
        firstNonBlackPresentedFrame: Double?
    ) {
        self.appLaunch = appLaunch
        self.playerCreated = playerCreated
        self.prepareCalled = prepareCalled
        self.readyToPlay = readyToPlay
        self.playCalled = playCalled
        self.firstDisplayCallback = firstDisplayCallback
        self.firstPixelBufferAvailable = firstPixelBufferAvailable
        self.firstPixelBufferCopied = firstPixelBufferCopied
        self.firstHDRProcessedFrame = firstHDRProcessedFrame
        self.firstDrawablePresented = firstDrawablePresented
        self.firstNonBlackPresentedFrame = firstNonBlackPresentedFrame
    }

    public var playToFirstPixelBuffer: Double? { difference(from: playCalled, to: firstPixelBufferAvailable) }
    public var playToFirstProcessedFrame: Double? { difference(from: playCalled, to: firstHDRProcessedFrame) }
    public var playToFirstPresentedFrame: Double? { difference(from: playCalled, to: firstDrawablePresented) }
    public var readyToFirstPixelBuffer: Double? { difference(from: readyToPlay, to: firstPixelBufferAvailable) }
    public var readyToFirstPresentedFrame: Double? { difference(from: readyToPlay, to: firstDrawablePresented) }

    public var timestampsAreOrdered: Bool {
        let values = [
            playCalled, firstPixelBufferAvailable, firstPixelBufferCopied,
            firstHDRProcessedFrame, firstDrawablePresented, firstNonBlackPresentedFrame
        ].compactMap { $0 }
        return zip(values, values.dropFirst()).allSatisfy { $0 <= $1 }
    }

    private func difference(from start: Double?, to end: Double?) -> Double? {
        guard let start, let end else { return nil }
        return max(0, end - start)
    }
}

public enum PlayerPerformanceMode: String, CaseIterable, Codable, Sendable {
    case normalV4 = "normal-v4"
    case quickAB = "quick-ab"
    case controlledAB = "controlled-ab"
    case controlledV6 = "controlled-v6"
    case v6Candidate = "v6-candidate"
    case debugDiagnostics = "debug-diagnostics"
}

public struct PlayerModePerformanceSnapshot: Codable, Equatable, Sendable {
    public let mode: PlayerPerformanceMode
    public let gpuP50: Double?
    public let gpuP95: Double?
    public let cpuP50: Double?
    public let cpuP95: Double?

    public init(
        mode: PlayerPerformanceMode,
        gpuP50: Double?,
        gpuP95: Double?,
        cpuP50: Double?,
        cpuP95: Double?
    ) {
        self.mode = mode
        self.gpuP50 = gpuP50
        self.gpuP95 = gpuP95
        self.cpuP50 = cpuP50
        self.cpuP95 = cpuP95
    }
}

public struct PlayerMetricsSnapshot: Codable, Sendable {
    public let displayCallbacks: Int
    public let processedHDRFrames: Int
    public let presentedFrames: Int
    public let reusedFrames: Int
    public let lateDroppedFrames: Int
    public let sourceUnavailableFrames: Int
    public let sourceUnavailableBreakdown: PlayerSourceUnavailableBreakdown
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
    public let startup: PlayerStartupMetricsSnapshot
    public let performanceByMode: [PlayerModePerformanceSnapshot]

    public var debugLine: String {
        "FPS callbacks=\(displayCallbacks), processed=\(processedHDRFrames), presented=\(presentedFrames), reused=\(reusedFrames), lateDrop=\(lateDroppedFrames), sourceUnavailable=\(sourceUnavailableFrames), drawableMiss=\(drawableMisses), poolBusy=\(inFlightSaturation), linkRestarts=\(displayLinkRestarts), GPU render p50/p95=\(format(gpuRenderP50))/\(format(gpuRenderP95)) ms, CPU submit p50/p95=\(format(cpuSubmissionP50))/\(format(cpuSubmissionP95)) ms, play→pixel=\(formatMilliseconds(startup.playToFirstPixelBuffer)) ms, play→present=\(formatMilliseconds(startup.playToFirstPresentedFrame)) ms"
    }

    private func format(_ value: Double?) -> String {
        guard let value else { return "NOT_MEASURED" }
        return String(format: "%.3f", value)
    }

    private func formatMilliseconds(_ value: Double?) -> String {
        guard let value else { return "NOT_MEASURED" }
        return String(format: "%.3f", value * 1_000)
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
    private var sourceUnavailableCounts: [PlayerSourceUnavailableReason: Int] = [:]
    private var drawableMisses = 0
    private var inFlightSaturation = 0
    private var displayLinkRestarts = 0
    private var gpuRenderSamples: [Double] = []
    private var cpuSubmissionSamples: [Double] = []
    private var gpuRenderSamplesByMode: [PlayerPerformanceMode: [Double]] = [:]
    private var cpuSubmissionSamplesByMode: [PlayerPerformanceMode: [Double]] = [:]
    private var playbackStartUptime: Double?
    private var playbackEndUptime: Double?
    private var startupResidentBytes: Int64?
    private var endResidentBytes: Int64?
    private var startupAppLaunch: Double?
    private var startupPlayerCreated: Double?
    private var startupPrepareCalled: Double?
    private var startupReadyToPlay: Double?
    private var startupPlayCalled: Double?
    private var startupFirstDisplayCallback: Double?
    private var startupFirstPixelBufferAvailable: Double?
    private var startupFirstPixelBufferCopied: Double?
    private var startupFirstHDRProcessedFrame: Double?
    private var startupFirstDrawablePresented: Double?
    private var startupFirstNonBlackPresentedFrame: Double?

    public init() {}

    public func markAppLaunch() { markStartupEvent(.appLaunch) }
    public func markPlayerCreated() { markStartupEvent(.playerCreated) }
    public func markPrepareCalled() { markStartupEvent(.prepareCalled) }
    public func markReadyToPlay() { markStartupEvent(.readyToPlay) }
    public func markPlayCalled() { markStartupEvent(.playCalled) }
    public func markFirstDisplayCallback() { markStartupEvent(.firstDisplayCallback) }
    public func markFirstPixelBufferAvailable() { markStartupEvent(.firstPixelBufferAvailable) }
    public func markFirstPixelBufferCopied() { markStartupEvent(.firstPixelBufferCopied) }
    public func markFirstHDRProcessedFrame() { markStartupEvent(.firstHDRProcessedFrame) }
    public func markFirstDrawablePresented() { markStartupEvent(.firstDrawablePresented) }
    public func markFirstNonBlackPresentedFrame() { markStartupEvent(.firstNonBlackPresentedFrame) }

    public func markPlaybackStarted() {
        lock.lock()
        if playbackStartUptime == nil {
            playbackStartUptime = ProcessInfo.processInfo.systemUptime
            startupResidentBytes = currentResidentMemoryBytes()
        }
        lock.unlock()
        markPlayCalled()
    }

    public func markPlaybackEnded() {
        lock.lock()
        if playbackEndUptime == nil {
            playbackEndUptime = ProcessInfo.processInfo.systemUptime
            endResidentBytes = currentResidentMemoryBytes()
        }
        lock.unlock()
    }

    public func recordDisplayCallback() {
        increment { displayCallbacks += 1 }
        markFirstDisplayCallback()
    }
    public func recordProcessedFrame() { increment { processedHDRFrames += 1 } }
    public func recordPresentedFrame() { increment { presentedFrames += 1 } }
    public func recordReusedFrame() { increment { reusedFrames += 1 } }
    public func recordLateDrop() { increment { lateDroppedFrames += 1 } }
    public func recordSourceUnavailable() { recordSourceUnavailable(reason: .other) }
    public func recordSourceUnavailable(reason: PlayerSourceUnavailableReason) {
        increment {
            sourceUnavailableFrames += 1
            sourceUnavailableCounts[reason, default: 0] += 1
        }
    }
    public func recordDrawableMiss() { increment { drawableMisses += 1 } }
    public func recordInFlightSaturation() { increment { inFlightSaturation += 1 } }
    public func recordDisplayLinkRestart() { increment { displayLinkRestarts += 1 } }

    public func recordSubmission(cpuMilliseconds: Double, mode: PlayerPerformanceMode = .normalV4) {
        lock.lock()
        append(cpuMilliseconds, to: &cpuSubmissionSamples)
        append(cpuMilliseconds, to: &cpuSubmissionSamplesByMode[mode, default: []])
        lock.unlock()
    }

    public func recordGPU(milliseconds: Double, mode: PlayerPerformanceMode = .normalV4) {
        guard milliseconds.isFinite, milliseconds >= 0 else { return }
        lock.lock()
        append(milliseconds, to: &gpuRenderSamples)
        append(milliseconds, to: &gpuRenderSamplesByMode[mode, default: []])
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
            sourceUnavailableBreakdown: PlayerSourceUnavailableBreakdown(
                noNewPixelBuffer: sourceUnavailableCounts[.noNewPixelBuffer, default: 0],
                copyPixelBufferFailed: sourceUnavailableCounts[.copyPixelBufferFailed, default: 0],
                noLastFrame: sourceUnavailableCounts[.noLastFrame, default: 0],
                noTexture: sourceUnavailableCounts[.noTexture, default: 0],
                notReady: sourceUnavailableCounts[.notReady, default: 0],
                other: sourceUnavailableCounts[.other, default: 0]
            ),
            drawableMisses: drawableMisses,
            inFlightSaturation: inFlightSaturation,
            displayLinkRestarts: displayLinkRestarts,
            gpuRenderP50: percentile(gpuRenderSamples, fraction: 0.50),
            gpuRenderP95: percentile(gpuRenderSamples, fraction: 0.95),
            cpuSubmissionP50: percentile(cpuSubmissionSamples, fraction: 0.50),
            cpuSubmissionP95: percentile(cpuSubmissionSamples, fraction: 0.95),
            wallPlaybackSeconds: wall,
            startupResidentBytes: startupResidentBytes,
            endResidentBytes: endResidentBytes,
            startup: PlayerStartupMetricsSnapshot(
                appLaunch: startupAppLaunch,
                playerCreated: startupPlayerCreated,
                prepareCalled: startupPrepareCalled,
                readyToPlay: startupReadyToPlay,
                playCalled: startupPlayCalled,
                firstDisplayCallback: startupFirstDisplayCallback,
                firstPixelBufferAvailable: startupFirstPixelBufferAvailable,
                firstPixelBufferCopied: startupFirstPixelBufferCopied,
                firstHDRProcessedFrame: startupFirstHDRProcessedFrame,
                firstDrawablePresented: startupFirstDrawablePresented,
                firstNonBlackPresentedFrame: startupFirstNonBlackPresentedFrame
            ),
            performanceByMode: PlayerPerformanceMode.allCases.map { mode in
                PlayerModePerformanceSnapshot(
                    mode: mode,
                    gpuP50: percentile(gpuRenderSamplesByMode[mode] ?? [], fraction: 0.50),
                    gpuP95: percentile(gpuRenderSamplesByMode[mode] ?? [], fraction: 0.95),
                    cpuP50: percentile(cpuSubmissionSamplesByMode[mode] ?? [], fraction: 0.50),
                    cpuP95: percentile(cpuSubmissionSamplesByMode[mode] ?? [], fraction: 0.95)
                )
            }
        )
    }

    private enum StartupEvent {
        case appLaunch, playerCreated, prepareCalled, readyToPlay, playCalled
        case firstDisplayCallback, firstPixelBufferAvailable, firstPixelBufferCopied
        case firstHDRProcessedFrame, firstDrawablePresented, firstNonBlackPresentedFrame
    }

    private func markStartupEvent(_ event: StartupEvent) {
        let timestamp = ProcessInfo.processInfo.systemUptime
        lock.lock()
        switch event {
        case .appLaunch: if startupAppLaunch == nil { startupAppLaunch = timestamp }
        case .playerCreated: if startupPlayerCreated == nil { startupPlayerCreated = timestamp }
        case .prepareCalled: if startupPrepareCalled == nil { startupPrepareCalled = timestamp }
        case .readyToPlay: if startupReadyToPlay == nil { startupReadyToPlay = timestamp }
        case .playCalled: if startupPlayCalled == nil { startupPlayCalled = timestamp }
        case .firstDisplayCallback: if startupFirstDisplayCallback == nil { startupFirstDisplayCallback = timestamp }
        case .firstPixelBufferAvailable: if startupFirstPixelBufferAvailable == nil { startupFirstPixelBufferAvailable = timestamp }
        case .firstPixelBufferCopied: if startupFirstPixelBufferCopied == nil { startupFirstPixelBufferCopied = timestamp }
        case .firstHDRProcessedFrame:
            if startupPlayCalled != nil, startupFirstHDRProcessedFrame == nil { startupFirstHDRProcessedFrame = timestamp }
        case .firstDrawablePresented:
            if startupPlayCalled != nil, startupFirstDrawablePresented == nil { startupFirstDrawablePresented = timestamp }
        case .firstNonBlackPresentedFrame:
            if startupPlayCalled != nil, startupFirstNonBlackPresentedFrame == nil { startupFirstNonBlackPresentedFrame = timestamp }
        }
        lock.unlock()
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
