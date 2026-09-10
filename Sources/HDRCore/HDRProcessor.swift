import CoreMedia
import CoreVideo
import Foundation
import Metal

private let hdrMultiFlightDeepProgressEnabled =
    ProcessInfo.processInfo.environment["HDR_MULTIFLIGHT_DEEP_PROGRESS"] == "1"

private func writeHDRMultiFlightDeepProgress(_ message: @autoclosure () -> String) {
    guard hdrMultiFlightDeepProgressEnabled else { return }
    FileHandle.standardError.write(
        Data("MULTIFLIGHT_DEEP_PROGRESS \(message())\n".utf8)
    )
}

struct HDRTextureLeaseEvidence: Sendable {
    let id: Int
    let width: Int
    let height: Int
    let inFlight: Bool
    let identity: String
}

struct HDRTemporalEstimateBufferEvidence: Sendable {
    let leaseID: Int
    let identity: String
}

struct HDRRuntimeResourceEvidence: Sendable {
    let outputTextureSlotsPerSize: Int
    let outputTextures: [HDRTextureLeaseEvidence]
    let temporalEstimateBuffers: [HDRTemporalEstimateBufferEvidence]
}

public enum HDRProcessorError: Error, LocalizedError, Sendable {
    case commandQueueCreationFailed
    case commandBufferCreationFailed
    case commandEncoderCreationFailed
    case invalidDimensions
    case unsupportedPixelFormat(OSType)
    case textureCacheCreationFailed(OSStatus)
    case textureCreationFailed(OSStatus, plane: Int)
    case shaderSourceMissing
    case shaderSourceReadFailed(String)
    case shaderCompilationFailed(String)
    case shaderFunctionMissing(String)
    case pipelineCreationFailed(String)
    case outputTextureCreationFailed
    case outputTexturePoolExhausted(width: Int, height: Int)
    case debugBufferCreationFailed
    case metadata(HDRColorMetadataError)
    case configuration(HDRConfigurationError)

    public var errorDescription: String? {
        switch self {
        case .commandQueueCreationFailed:
            return "Metal command queue creation failed"
        case .commandBufferCreationFailed:
            return "Metal command buffer creation failed"
        case .commandEncoderCreationFailed:
            return "Metal compute encoder creation failed"
        case .invalidDimensions:
            return "Input dimensions must be positive"
        case .unsupportedPixelFormat(let format):
            return "Unsupported CVPixelBuffer pixel format: \(format)"
        case .textureCacheCreationFailed(let status):
            return "CVMetalTextureCache creation failed: \(status)"
        case .textureCreationFailed(let status, let plane):
            return "CVMetalTexture creation failed for plane \(plane): \(status)"
        case .shaderSourceMissing:
            return "HDRCore Metal shader resource is missing"
        case .shaderSourceReadFailed(let reason):
            return "HDRCore Metal shader resource could not be read: \(reason)"
        case .shaderCompilationFailed(let reason):
            return "HDRCore Metal shader compilation failed: \(reason)"
        case .shaderFunctionMissing(let name):
            return "HDRCore Metal function is missing: \(name)"
        case .pipelineCreationFailed(let reason):
            return "HDRCore Metal pipeline creation failed: \(reason)"
        case .outputTextureCreationFailed:
            return "HDRCore output RGBA16Float texture creation failed"
        case .outputTexturePoolExhausted(let width, let height):
            return "All HDRCore output textures are in flight for \(width)x\(height); submit fewer concurrent frames or wait for completion"
        case .debugBufferCreationFailed:
            return "HDRCore debug statistics buffer creation failed"
        case .metadata(let error):
            return error.localizedDescription
        case .configuration(let error):
            return error.localizedDescription
        }
    }
}

private final class OutputTexturePool: @unchecked Sendable {
    private struct Entry {
        let id: Int
        let width: Int
        let height: Int
        let texture: MTLTexture
        var inFlight: Bool
    }

    private let device: MTLDevice
    private let lock = NSLock()
    private var entries: [Entry] = []
    private let slotsPerSize = 3
    private var nextID = 0
    private var lastRequestedSize: (width: Int, height: Int)?

    var metrics: (textureAllocations: Int, logicalBytes: Int64) {
        lock.lock()
        defer { lock.unlock() }
        let bytes = entries.reduce(into: Int64(0)) { total, entry in
            total += Int64(entry.width) * Int64(entry.height) * 8
        }
        return (entries.count, bytes)
    }

    var evidence: [HDRTextureLeaseEvidence] {
        lock.lock()
        defer { lock.unlock() }
        return entries.map { entry in
            HDRTextureLeaseEvidence(
                id: entry.id,
                width: entry.width,
                height: entry.height,
                inFlight: entry.inFlight,
                identity: String(describing: ObjectIdentifier(entry.texture as AnyObject))
            )
        }
    }

    func prepare(width: Int, height: Int) throws {
        guard width > 0, height > 0 else {
            throw HDRProcessorError.invalidDimensions
        }
        lock.lock()
        defer { lock.unlock() }
        lastRequestedSize = (width, height)
        pruneUnusedSizes()
        try ensureSlots(width: width, height: height)
    }

    init(device: MTLDevice) {
        self.device = device
    }

    func acquire(width: Int, height: Int) throws -> (id: Int, texture: MTLTexture) {
        lock.lock()
        defer { lock.unlock() }

        lastRequestedSize = (width, height)
        pruneUnusedSizes()
        try ensureSlots(width: width, height: height)
        if let index = entries.firstIndex(where: { $0.width == width && $0.height == height && !$0.inFlight }) {
            entries[index].inFlight = true
            return (entries[index].id, entries[index].texture)
        }
        throw HDRProcessorError.outputTexturePoolExhausted(width: width, height: height)
    }

    private func ensureSlots(width: Int, height: Int) throws {
        let countForSize = entries.reduce(into: 0) { count, entry in
            if entry.width == width && entry.height == height { count += 1 }
        }
        guard countForSize < slotsPerSize else { return }

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .private
        for _ in countForSize..<slotsPerSize {
            guard let texture = device.makeTexture(descriptor: descriptor) else {
                throw HDRProcessorError.outputTextureCreationFailed
            }
            let id = nextID
            nextID += 1
            entries.append(Entry(id: id, width: width, height: height, texture: texture, inFlight: false))
        }
    }

    private func pruneUnusedSizes() {
        guard let lastRequestedSize else { return }
        entries.removeAll {
            !$0.inFlight && ($0.width != lastRequestedSize.width || $0.height != lastRequestedSize.height)
        }
    }

    func release(id: Int) {
        lock.lock()
        defer { lock.unlock() }
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].inFlight = false
        pruneUnusedSizes()
    }
}

/// Keeps a pooled output texture exclusively leased until both the GPU
/// command and every copy of the returned HDRFrame have released it.  The
/// command-buffer completion handler and HDRFrame intentionally share this
/// token; deinitialization is therefore the exact two-party lifetime barrier.
private final class OutputLeaseLifetime: @unchecked Sendable {
    private let pool: OutputTexturePool
    private let id: Int

    init(pool: OutputTexturePool, id: Int) {
        self.pool = pool
        self.id = id
    }

    deinit {
        pool.release(id: id)
    }
}

struct HDRAdaptiveStateSnapshot: Sendable {
    let temporal: (adaptation: Float, sequence: UInt64)
    let scene: (
        floor: Float,
        top: Float,
        valid: Bool,
        sequence: UInt64,
        statistics: HDRSceneStatistics
    )
    let generation: UInt64
    /// One transaction sequence for all adaptive parameters.  The legacy
    /// per-component sequence fields remain available for diagnostics, but a
    /// frame consumes this common commit boundary.
    let committedSequence: UInt64
    let lastGPUCompletedSequence: UInt64
    let lastAdaptiveCommittedSequence: UInt64

    func transactionInvariantHolds(sceneRelativeEnabled: Bool) -> Bool {
        guard committedSequence == temporal.sequence,
              lastAdaptiveCommittedSequence == committedSequence else {
            return false
        }
        return !sceneRelativeEnabled || scene.sequence == committedSequence
    }
}

struct HDRAdaptiveCompletionUpdate: Sendable {
    let applied: Bool
    let temporal: (adaptation: Float, sequence: UInt64)
    let scene: (floor: Float, top: Float, valid: Bool, sequence: UInt64)
    let committedSequence: UInt64
}

private struct HDRAdaptiveState: Sendable {
    var temporal = HDRTemporalControlState()
    var scene = HDRTemporalControlState()
    /// Causal scene statistics consumed by development controllers.
    var smoothedStatistics = HDRSceneStatistics.neutral
    var generation: UInt64 = 0
    /// The last automatic sequence accepted by the required components.
    /// Scene-relative mode requires this to equal both component sequences;
    /// non-scene-relative mode only requires the temporal component.
    var committedSequence: UInt64 = 0
    var lastGPUCompletedSequence: UInt64 = 0
    var lastAdaptiveCommittedSequence: UInt64 = 0

    func transactionInvariantHolds(sceneRelativeEnabled: Bool) -> Bool {
        snapshot().transactionInvariantHolds(sceneRelativeEnabled: sceneRelativeEnabled)
    }

    func snapshot() -> HDRAdaptiveStateSnapshot {
        HDRAdaptiveStateSnapshot(
            temporal: (temporal.adaptation, temporal.automaticSequence),
            scene: (
                scene.shadowFloor,
                scene.shadowTop,
                scene.shadowStatisticsValid,
                scene.shadowSequence,
                smoothedStatistics
            ),
            generation: generation,
            committedSequence: committedSequence,
            lastGPUCompletedSequence: lastGPUCompletedSequence,
            lastAdaptiveCommittedSequence: lastAdaptiveCommittedSequence
        )
    }
}

/// Owns every causal state used to encode one frame. Automatic completion
/// updates are calculated in a value-semantic candidate and published only
/// after every required component has accepted the sequence.
final class HDRAdaptiveStateStore: @unchecked Sendable {
    private let lock = NSLock()
    private var state = HDRAdaptiveState()

    var generation: UInt64 { lock.withLock { state.generation } }

    func snapshot() -> HDRAdaptiveStateSnapshot {
        lock.withLock { state.snapshot() }
    }

    func temporalAdaptation() -> Float {
        lock.withLock { state.temporal.adaptation }
    }

    func sceneCoordinates() -> (floor: Float, top: Float, valid: Bool) {
        lock.withLock {
            (state.scene.shadowFloor, state.scene.shadowTop, state.scene.shadowStatisticsValid)
        }
    }

    func sceneStatistics() -> HDRSceneStatistics {
        lock.withLock { state.smoothedStatistics }
    }

    func advanceGeneration(to generation: UInt64, resetTemporal: Bool, resetScene: Bool) {
        lock.withLock {
            state.generation = generation
            state.committedSequence = 0
            state.lastGPUCompletedSequence = 0
            state.lastAdaptiveCommittedSequence = 0
            if resetTemporal { state.temporal.reset() }
            if resetScene {
                state.scene.reset()
                state.smoothedStatistics = .neutral
            }
        }
    }

    func updateTemporal(averageLuminance: Float, stability: Float, sceneCut: Bool) {
        lock.withLock {
            state.temporal.updateAverage(
                averageLuminance: averageLuminance,
                stability: stability,
                sceneCut: sceneCut
            )
        }
    }

    func updateScene(statistics: HDRSceneStatistics, stability: Float, sceneCut: Bool) {
        lock.withLock {
            guard statistics.isFinite else { return }
            let shouldSnap = sceneCut || !state.scene.shadowStatisticsValid
            state.scene.updateStatistics(statistics, stability: stability, sceneCut: sceneCut)
            state.smoothedStatistics = HDRSceneStatistics.causalBlend(
                previous: state.smoothedStatistics,
                target: statistics,
                stability: stability,
                sceneCut: shouldSnap,
                deltaSeconds: HDRTemporalControlState.referenceFrameDurationSeconds
            )
        }
    }

    /// Records a completed estimator command independently from whether its
    /// causal state was accepted. The sequence is scoped to the current
    /// generation, so a completion from before a reset cannot advance it.
    @discardableResult
    func recordGPUCompletion(sequence: UInt64, generation: UInt64) -> Bool {
        lock.withLock {
            guard generation == state.generation else { return false }
            state.lastGPUCompletedSequence = max(state.lastGPUCompletedSequence, sequence)
            return true
        }
    }

    var lastGPUCompletedSequence: UInt64 {
        lock.withLock { state.lastGPUCompletedSequence }
    }

    var lastAdaptiveCommittedSequence: UInt64 {
        lock.withLock { state.lastAdaptiveCommittedSequence }
    }

    @discardableResult
    func updateAutomatic(
        statistics: HDRSceneStatistics,
        averageLuminance: Float,
        stability: Float,
        sequence: UInt64,
        generation: UInt64,
        timestampSeconds: Double?,
        sceneRelativeEnabled: Bool,
        rejectSceneCommitForTesting: Bool = false
    ) -> HDRAdaptiveCompletionUpdate {
        lock.withLock {
            let current = snapshotUnlocked()
            let canApplyTemporal = generation == state.generation &&
                averageLuminance.isFinite &&
                sequence > state.committedSequence &&
                sequence > current.temporal.sequence &&
                sequence >= state.lastGPUCompletedSequence
            let canApplyScene = !sceneRelativeEnabled ||
                (statistics.isFinite && averageLuminance.isFinite && sequence > current.scene.sequence)
            guard canApplyTemporal, canApplyScene else {
                return rejectedUpdate(from: current)
            }

            var candidate = state
            let previousTemporalSequence = candidate.temporal.automaticSequence
            _ = candidate.temporal.updateAutomaticAverage(
                averageLuminance: averageLuminance,
                stability: stability,
                sequence: sequence,
                timestampSeconds: timestampSeconds
            )
            // updateAutomaticAverage returns scene-cut status. Its sequence
            // transition is the acceptance proof for this candidate.
            guard candidate.temporal.automaticSequence > previousTemporalSequence,
                  candidate.temporal.automaticSequence == sequence else {
                return rejectedUpdate(from: current)
            }

            if sceneRelativeEnabled {
                let previousSceneSequence = candidate.scene.shadowSequence
                let sceneCut = candidate.scene.updateAutomaticStatistics(
                    statistics,
                    averageLuminance: averageLuminance,
                    stability: stability,
                    sequence: sequence,
                    timestampSeconds: timestampSeconds
                )
                // updateAutomaticStatistics returns scene-cut status. Its
                // sequence transition is the acceptance proof for this
                // value-semantic candidate; a failed update leaves the
                // previous sequence untouched.
                guard candidate.scene.shadowSequence > previousSceneSequence,
                      candidate.scene.shadowSequence == sequence,
                      !rejectSceneCommitForTesting else {
                    return rejectedUpdate(from: current)
                }
                candidate.smoothedStatistics = HDRSceneStatistics.causalBlend(
                    previous: candidate.smoothedStatistics,
                    target: statistics,
                    stability: stability,
                    sceneCut: sceneCut,
                    deltaSeconds: candidate.scene.lastShadowDeltaSeconds
                )
            }
            candidate.committedSequence = sequence
            candidate.lastAdaptiveCommittedSequence = sequence
            guard candidate.transactionInvariantHolds(sceneRelativeEnabled: sceneRelativeEnabled) else {
                return rejectedUpdate(from: current)
            }
            state = candidate
            let committed = state.snapshot()
            return HDRAdaptiveCompletionUpdate(
                applied: true,
                temporal: committed.temporal,
                scene: (
                    floor: committed.scene.floor,
                    top: committed.scene.top,
                    valid: committed.scene.valid,
                    sequence: committed.scene.sequence
                ),
                committedSequence: committed.committedSequence
            )
        }
    }

    private func snapshotUnlocked() -> HDRAdaptiveStateSnapshot {
        state.snapshot()
    }

    private func rejectedUpdate(from snapshot: HDRAdaptiveStateSnapshot) -> HDRAdaptiveCompletionUpdate {
        HDRAdaptiveCompletionUpdate(
            applied: false,
            temporal: snapshot.temporal,
            scene: (
                floor: snapshot.scene.floor,
                top: snapshot.scene.top,
                valid: snapshot.scene.valid,
                sequence: snapshot.scene.sequence
            ),
            committedSequence: snapshot.committedSequence
        )
    }
}

private struct TemporalLumaStatsStorage {
    var linearLuminanceSum: UInt32 = 0
    var sampleCount: UInt32 = 0
    var histogram0: UInt32 = 0
    var histogram1: UInt32 = 0
    var histogram2: UInt32 = 0
    var histogram3: UInt32 = 0
    var histogram4: UInt32 = 0
    var histogram5: UInt32 = 0
    var histogram6: UInt32 = 0
    var histogram7: UInt32 = 0
    var histogram8: UInt32 = 0
    var histogram9: UInt32 = 0
    var histogram10: UInt32 = 0
    var histogram11: UInt32 = 0
    var histogram12: UInt32 = 0
    var histogram13: UInt32 = 0
    var histogram14: UInt32 = 0
    var histogram15: UInt32 = 0
    var histogram16: UInt32 = 0
    var histogram17: UInt32 = 0
    var histogram18: UInt32 = 0
    var histogram19: UInt32 = 0
    var histogram20: UInt32 = 0
    var histogram21: UInt32 = 0
    var histogram22: UInt32 = 0
    var histogram23: UInt32 = 0
    var histogram24: UInt32 = 0
    var histogram25: UInt32 = 0
    var histogram26: UInt32 = 0
    var histogram27: UInt32 = 0
    var histogram28: UInt32 = 0
    var histogram29: UInt32 = 0
    var histogram30: UInt32 = 0
    var histogram31: UInt32 = 0
    var histogram32: UInt32 = 0
    var histogram33: UInt32 = 0
    var histogram34: UInt32 = 0
    var histogram35: UInt32 = 0
    var histogram36: UInt32 = 0
    var histogram37: UInt32 = 0
    var histogram38: UInt32 = 0
    var histogram39: UInt32 = 0
    var histogram40: UInt32 = 0
    var histogram41: UInt32 = 0
    var histogram42: UInt32 = 0
    var histogram43: UInt32 = 0
    var histogram44: UInt32 = 0
    var histogram45: UInt32 = 0
    var histogram46: UInt32 = 0
    var histogram47: UInt32 = 0
    var histogram48: UInt32 = 0
    var histogram49: UInt32 = 0
    var histogram50: UInt32 = 0
    var histogram51: UInt32 = 0
    var histogram52: UInt32 = 0
    var histogram53: UInt32 = 0
    var histogram54: UInt32 = 0
    var histogram55: UInt32 = 0
    var histogram56: UInt32 = 0
    var histogram57: UInt32 = 0
    var histogram58: UInt32 = 0
    var histogram59: UInt32 = 0
    var histogram60: UInt32 = 0
    var histogram61: UInt32 = 0
    var histogram62: UInt32 = 0
    var histogram63: UInt32 = 0

    var histogram: [UInt32] {
        [histogram0, histogram1, histogram2, histogram3, histogram4, histogram5, histogram6, histogram7, histogram8, histogram9, histogram10, histogram11, histogram12, histogram13, histogram14, histogram15, histogram16, histogram17, histogram18, histogram19, histogram20, histogram21, histogram22, histogram23, histogram24, histogram25, histogram26, histogram27, histogram28, histogram29, histogram30, histogram31,
         histogram32, histogram33, histogram34, histogram35, histogram36, histogram37, histogram38, histogram39, histogram40, histogram41, histogram42, histogram43, histogram44, histogram45, histogram46, histogram47, histogram48, histogram49, histogram50, histogram51, histogram52, histogram53, histogram54, histogram55, histogram56, histogram57, histogram58, histogram59, histogram60, histogram61, histogram62, histogram63]
    }
}

private final class TemporalEstimateBufferPool: @unchecked Sendable {
    private let device: MTLDevice
    private let lock = NSLock()
    private var buffers: [Int: MTLBuffer] = [:]

    init(device: MTLDevice) { self.device = device }

    var allocationCount: Int {
        lock.withLock { buffers.count }
    }

    var evidence: [HDRTemporalEstimateBufferEvidence] {
        lock.withLock {
            buffers.map { leaseID, buffer in
                HDRTemporalEstimateBufferEvidence(
                    leaseID: leaseID,
                    identity: String(describing: ObjectIdentifier(buffer as AnyObject))
                )
            }
            .sorted { $0.leaseID < $1.leaseID }
        }
    }

    func buffer(for leaseID: Int) throws -> MTLBuffer {
        lock.lock()
        defer { lock.unlock() }
        if let buffer = buffers[leaseID] { return buffer }
        guard let buffer = device.makeBuffer(
            length: MemoryLayout<TemporalLumaStatsStorage>.stride,
            options: .storageModeShared
        ) else { throw HDRProcessorError.debugBufferCreationFailed }
        buffers[leaseID] = buffer
        return buffer
    }
}

private final class TemporalEstimateBufferLifetime: @unchecked Sendable {
    let buffer: MTLBuffer
    init(_ buffer: MTLBuffer) { self.buffer = buffer }
}

public struct HDRTemporalSubmissionTrace: Equatable, Sendable {
    public let generation: UInt64
    public let submissionSequence: UInt64
    public let temporalStateVersionConsumed: UInt64
    public let sceneStateVersionConsumed: UInt64
    public let temporalAdaptationUsed: Float
    public let sceneShadowFloorUsed: Float
    public let sceneShadowTopUsed: Float
    public let sceneStatisticsValidUsed: Bool
}

public struct HDRTemporalCompletionTrace: Equatable, Sendable {
    public let generation: UInt64
    public let submissionSequence: UInt64
    /// The command-buffer sequence observed as completed by the GPU.  A
    /// completion trace is emitted only after the adaptive transaction below
    /// has accepted the same sequence, but keeping both names explicit avoids
    /// conflating GPU completion with causal-state publication.
    public let gpuCompletionSequence: UInt64
    public let adaptiveCommittedSequence: UInt64
    public let temporalStateVersionProduced: UInt64
    public let sceneStateVersionProduced: UInt64
    public let temporalAdaptationProduced: Float
    public let sceneShadowFloorProduced: Float
    public let sceneShadowTopProduced: Float
    public let sceneStatisticsValidProduced: Bool
}


private final class TemporalTraceStore: @unchecked Sendable {
    private let lock = NSLock()
    private var generationStorage: UInt64 = 0
    private var traceEnabledStorage = false
    private var submissions: [HDRTemporalSubmissionTrace] = []
    private var completions: [HDRTemporalCompletionTrace] = []

    var traceEnabled: Bool {
        get { lock.withLock { traceEnabledStorage } }
        set { lock.withLock { traceEnabledStorage = newValue } }
    }

    func advanceGeneration(to generation: UInt64) {
        lock.withLock { generationStorage = generation }
    }

    func clear() {
        lock.withLock {
            submissions.removeAll(keepingCapacity: true)
            completions.removeAll(keepingCapacity: true)
        }
    }

    @discardableResult
    func append(_ trace: HDRTemporalSubmissionTrace, generation: UInt64) -> Bool {
        lock.withLock {
            guard generation == generationStorage else { return false }
            submissions.append(trace)
            return true
        }
    }

    @discardableResult
    func append(_ trace: HDRTemporalCompletionTrace, generation: UInt64) -> Bool {
        lock.withLock {
            guard generation == generationStorage else { return false }
            completions.append(trace)
            return true
        }
    }

    var submissionValues: [HDRTemporalSubmissionTrace] {
        lock.withLock { submissions.sorted { $0.submissionSequence < $1.submissionSequence } }
    }

    var completionValues: [HDRTemporalCompletionTrace] {
        // Preserve actual completion-handler order; sorting would erase the
        // very out-of-order behavior this trace exists to detect.
        lock.withLock { completions }
    }
}

public final class HDRProcessor {
    public let device: MTLDevice

    private let context: MetalContext
    private let outputPool: OutputTexturePool
    private let stateLock = NSLock()
    private var currentConfiguration: HDRConfiguration
    private let adaptiveState = HDRAdaptiveStateStore()
    private let temporalEstimateBuffers: TemporalEstimateBufferPool
    private let debugStore = DebugStatisticsStore()
    private var debugEnabled = false
    private var debugPresetLabel = "configuration"
    private var configurationGenerationStorage: UInt64 = 0
    private var automaticTemporalEnabled = true
    private var temporalSubmissionSequenceStorage: UInt64 = 0
    private var temporalGenerationStorage: UInt64 = 0
    private let temporalTraceStore = TemporalTraceStore()

    public var configuration: HDRConfiguration {
        stateLock.lock()
        defer { stateLock.unlock() }
        return currentConfiguration
    }

    /// Diagnostic metadata only. The shader never reads this generation.
    public var configurationGeneration: UInt64 {
        stateLock.withLock { configurationGenerationStorage }
    }

    /// Enables an additional atomic-statistics shader variant. Keep this off
    /// on the realtime release path; it intentionally adds per-pixel debug
    /// work and a shared readback buffer.
    public var debugInstrumentationEnabled: Bool {
        get {
            stateLock.lock()
            defer { stateLock.unlock() }
            return debugEnabled
        }
        set {
            stateLock.lock()
            debugEnabled = newValue
            stateLock.unlock()
        }
    }

    public var lastDebugStatistics: HDRDebugStatistics? {
        debugStore.value
    }

    public var lastFrameDiagnostic: HDRFrameDiagnosticSnapshot? {
        debugStore.diagnosticValue
    }

    public var diagnosticPresetLabel: String {
        get { stateLock.withLock { debugPresetLabel } }
        set { stateLock.withLock { debugPresetLabel = newValue } }
    }

    /// Enables the 16x9 asynchronous source-luminance estimator. It adds 144
    /// texture reads and no CPU/GPU wait; completion updates the next frame's
    /// temporal adaptation. Offline calibration enables the same estimator
    /// and only waits after submission when it needs a numeric readback.
    public var automaticTemporalEstimationEnabled: Bool {
        get { stateLock.withLock { automaticTemporalEnabled } }
        set {
            stateLock.withLock {
                guard automaticTemporalEnabled != newValue else { return }
                automaticTemporalEnabled = newValue
                advanceTemporalGenerationLocked(resetTemporal: false, resetScene: false)
            }
        }
    }

    /// Prepares the reusable RGBA16Float output ring for a known stream size.
    /// This is optional; the first process call also prepares it lazily.
    public func prepare(width: Int, height: Int) throws {
        try outputPool.prepare(width: width, height: height)
    }

    /// Creates a command buffer from the processor's persistent queue. A
    /// presentation layer can use this to encode HDR transform and drawable
    /// presentation in the same GPU submission without introducing a CPU/GPU
    /// synchronization point.
    public func makeCommandBuffer() throws -> MTLCommandBuffer {
        guard let commandBuffer = context.commandQueue.makeCommandBuffer() else {
            throw HDRProcessorError.commandBufferCreationFailed
        }
        return commandBuffer
    }

    /// Logical output-pool metrics intended for debug/benchmark reporting.
    /// `textureAllocations` counts persistent output textures, not transient
    /// driver allocations. `logicalBytes` is width*height*8 per texture.
    public var runtimeMetrics: HDRRuntimeMetrics {
        let values = outputPool.metrics
        return HDRRuntimeMetrics(
            outputTextureAllocations: values.textureAllocations,
            outputTextureLogicalBytes: values.logicalBytes,
            temporalEstimateBufferAllocations: temporalEstimateBuffers.allocationCount
        )
    }

    /// Test-only resource evidence. It is intentionally a snapshot and has
    /// no effect on command encoding or pool policy.
    var runtimeResourceEvidence: HDRRuntimeResourceEvidence {
        HDRRuntimeResourceEvidence(
            outputTextureSlotsPerSize: 3,
            outputTextures: outputPool.evidence,
            temporalEstimateBuffers: temporalEstimateBuffers.evidence
        )
    }

    public init(
        device: MTLDevice,
        configuration: HDRConfiguration = .hdr,
        commandQueue: MTLCommandQueue? = nil
    ) throws {
        do {
            self.currentConfiguration = try configuration.validated()
        } catch let error as HDRConfigurationError {
            throw HDRProcessorError.configuration(error)
        }
        self.device = device
        self.context = try MetalContext(device: device, commandQueue: commandQueue)
        self.outputPool = OutputTexturePool(device: device)
        self.temporalEstimateBuffers = TemporalEstimateBufferPool(device: device)
    }

    /// Update parameters without rebuilding Metal libraries or pipeline state.
    public func update(configuration: HDRConfiguration) throws {
        do {
            let validated = try configuration.validated()
            stateLock.withLock {
                currentConfiguration = validated
                configurationGenerationStorage &+= 1
                // Frames already in flight captured the previous constants.
                // Preserve the causal history, but reject their late updates.
                advanceTemporalGenerationLocked(resetTemporal: false, resetScene: false)
            }
        } catch let error as HDRConfigurationError {
            throw HDRProcessorError.configuration(error)
        }
    }

    /// Feed an optional upstream luminance estimate to the conservative
    /// temporal controller. No estimate is generated by reading pixels on the
    /// CPU. Scene cuts reset history instead of smearing the new scene.
    public func updateTemporalEstimate(averageLuminance: Float, sceneCut: Bool = false) {
        stateLock.withLock {
            guard averageLuminance.isFinite else { return }
            // A caller-supplied estimate is authoritative for the current
            // causal state. Reject automatic completions submitted before it
            // instead of allowing one to overwrite this update afterward.
            advanceTemporalGenerationLocked(resetTemporal: false, resetScene: false)
            adaptiveState.updateTemporal(
                averageLuminance: averageLuminance,
                stability: currentConfiguration.temporalStability,
                sceneCut: sceneCut
            )
        }
    }

    /// Supplies the same percentile state that the asynchronous runtime
    /// estimator derives from the previous frame. This is intentionally a
    /// state update API; it does not inspect or copy frame pixels.
    public func updateSceneStatistics(_ statistics: HDRSceneStatistics, sceneCut: Bool = false) {
        stateLock.withLock {
            guard statistics.isFinite else { return }
            // Keep manual temporal/scene control atomic with respect to the
            // generation observed by asynchronous GPU completions.
            advanceTemporalGenerationLocked(resetTemporal: false, resetScene: false)
            adaptiveState.updateScene(
                statistics: statistics,
                stability: currentConfiguration.temporalStability,
                sceneCut: sceneCut
            )
        }
    }

    /// Current causal scene-relative shadow coordinates, useful for the
    /// offline/runtime equivalence harness and DEBUG diagnostics.
    public var sceneShadowCoordinates: (floor: Float, top: Float, valid: Bool) {
        adaptiveState.sceneCoordinates()
    }

    /// The causal percentile state consumed by development controllers. It is
    /// updated only from completed 16x9 estimator results and is smoothed with
    /// the configured temporal stability. V4's production shader does not
    /// read these percentile fields.
    public var causalSceneStatistics: HDRSceneStatistics {
        adaptiveState.sceneStatistics()
    }

    /// Resets temporal history at a seek/scene boundary. Offline calibration
    /// and HDRPlayer use the same state transition.
    public func resetTemporalState(averageLuminance: Float = 0.5) {
        stateLock.withLock {
            let stability = currentConfiguration.temporalStability
            advanceTemporalGenerationLocked(resetTemporal: true, resetScene: false)
            adaptiveState.updateTemporal(
                averageLuminance: averageLuminance,
                stability: stability,
                sceneCut: true
            )
        }
    }

    /// Clears history to the neutral adaptation used at processor startup.
    public func clearTemporalHistory() {
        _ = stateLock.withLock {
            advanceTemporalGenerationLocked(resetTemporal: true, resetScene: true)
        }
    }

    /// Must be called with stateLock held.  HDRAdaptiveStateStore validates
    /// this generation while holding its transaction lock, closing the
    /// reset/completion race rather than relying on a check performed before
    /// the update.
    @discardableResult
    private func advanceTemporalGenerationLocked(
        resetTemporal: Bool,
        resetScene: Bool
    ) -> UInt64 {
        temporalGenerationStorage &+= 1
        let generation = temporalGenerationStorage
        adaptiveState.advanceGeneration(
            to: generation,
            resetTemporal: resetTemporal,
            resetScene: resetScene
        )
        temporalTraceStore.advanceGeneration(to: generation)
        return generation
    }

    /// Exposed for calibration diagnostics; it does not synchronize with GPU.
    public var temporalAdaptation: Float { adaptiveState.temporalAdaptation() }

    public var temporalSubmissionSequence: UInt64 {
        stateLock.withLock { temporalSubmissionSequenceStorage }
    }

    /// Current causal generation. A seek, reset, or configuration change
    /// increments this value and invalidates older GPU completions.
    public var temporalGeneration: UInt64 {
        stateLock.withLock { temporalGenerationStorage }
    }

    /// Current-generation GPU estimator completion sequence. This can advance
    /// even when the corresponding adaptive update is rejected.
    public var lastGPUCompletedSequence: UInt64 {
        adaptiveState.lastGPUCompletedSequence
    }

    /// Highest current-generation sequence whose adaptive state was accepted.
    public var lastAdaptiveCommittedSequence: UInt64 {
        adaptiveState.lastAdaptiveCommittedSequence
    }

    /// Compatibility alias for clients that used the old ambiguous name.
    public var lastCompletedTemporalSequence: UInt64 {
        lastAdaptiveCommittedSequence
    }

    /// Test/debug-only temporal trace instrumentation. Disabled by default and
    /// never required by the realtime path. It records the exact causal state
    /// encoded into each submitted frame plus the state produced at completion.
    public var temporalTraceEnabled: Bool {
        get { temporalTraceStore.traceEnabled }
        set { temporalTraceStore.traceEnabled = newValue }
    }

    public func clearTemporalTrace() { temporalTraceStore.clear() }
    public var temporalSubmissionTrace: [HDRTemporalSubmissionTrace] { temporalTraceStore.submissionValues }
    public var temporalCompletionTrace: [HDRTemporalCompletionTrace] { temporalTraceStore.completionValues }

    /// Encodes the frame without waiting for GPU completion. The caller owns
    /// an optional supplied command buffer and must keep the input
    /// CVPixelBuffer alive and unmodified until that command buffer completes.
    public func process(
        pixelBuffer: CVPixelBuffer,
        commandBuffer: MTLCommandBuffer? = nil,
        diagnosticFrameIndex: UInt64 = 0,
        diagnosticROI: HDRDiagnosticROI? = nil
    ) throws -> HDRFrame {
        try process(
            pixelBuffer: pixelBuffer,
            timestamp: nil,
            commandBuffer: commandBuffer,
            diagnosticFrameIndex: diagnosticFrameIndex,
            diagnosticROI: diagnosticROI
        )
    }

    public func process(
        pixelBuffer: CVPixelBuffer,
        timestamp: CMTime?,
        commandBuffer: MTLCommandBuffer? = nil,
        diagnosticFrameIndex: UInt64 = 0,
        diagnosticROI: HDRDiagnosticROI? = nil
    ) throws -> HDRFrame {
        let progressFrame = diagnosticFrameIndex == 0 ? "auto" : String(diagnosticFrameIndex)
        writeHDRMultiFlightDeepProgress("processor-enter frame=\(progressFrame)")
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        guard width > 0, height > 0 else {
            throw HDRProcessorError.invalidDimensions
        }

        // Capture configuration, instrumentation, submission sequence and
        // generation atomically. A concurrent update may still let this frame
        // render with the old constants, but its completion can no longer
        // mutate the new temporal generation.
        writeHDRMultiFlightDeepProgress("adaptive-snapshot-start frame=\(progressFrame)")
        let processState: (
            configuration: HDRConfiguration,
            debugEnabled: Bool,
            diagnosticPresetLabel: String,
            configurationGeneration: UInt64,
            temporalSubmission: (
                sequence: UInt64,
                generation: UInt64,
                timestampSeconds: Double?
            )?,
            temporalSnapshot: (adaptation: Float, sequence: UInt64),
            sceneSnapshot: (
                floor: Float,
                top: Float,
                valid: Bool,
                sequence: UInt64,
                statistics: HDRSceneStatistics
            )
        ) = stateLock.withLock {
            let submission: (
                sequence: UInt64,
                generation: UInt64,
                timestampSeconds: Double?
            )?
            if automaticTemporalEnabled {
                temporalSubmissionSequenceStorage &+= 1
                submission = (
                    sequence: temporalSubmissionSequenceStorage,
                    generation: temporalGenerationStorage,
                    timestampSeconds: timestamp?.isNumeric == true ? timestamp?.seconds : nil
                )
            } else {
                submission = nil
            }
            let adaptiveSnapshot = self.adaptiveState.snapshot()
            return (
                currentConfiguration,
                self.debugEnabled,
                self.debugPresetLabel,
                self.configurationGenerationStorage,
                submission,
                adaptiveSnapshot.temporal,
                adaptiveSnapshot.scene
            )
        }
        writeHDRMultiFlightDeepProgress(
            "adaptive-snapshot-done frame=\(progressFrame) " +
                "submissionSequence=\(processState.temporalSubmission?.sequence ?? 0) " +
                "generation=\(processState.temporalSubmission?.generation ?? temporalGenerationStorage) " +
                "lastGPUCompletedSequence=\(self.adaptiveState.lastGPUCompletedSequence) " +
                "lastAdaptiveCommittedSequence=\(self.adaptiveState.lastAdaptiveCommittedSequence)"
        )
        let configuration = processState.configuration
        let debugEnabled = processState.debugEnabled
        let diagnosticPresetLabel = processState.diagnosticPresetLabel
        let configurationGeneration = processState.configurationGeneration
        let temporalSubmission = processState.temporalSubmission
        let resolvedColor: ResolvedColorDescription
        writeHDRMultiFlightDeepProgress("metadata-resolution-start frame=\(progressFrame)")
        do {
            resolvedColor = try HDRColorMetadataResolver.resolve(
                pixelBuffer: pixelBuffer,
                fallbackPolicy: configuration.inputFallbackPolicy
            )
        } catch let error as HDRColorMetadataError {
            throw HDRProcessorError.metadata(error)
        }
        writeHDRMultiFlightDeepProgress(
            "metadata-resolution-done frame=\(progressFrame) " +
                "chromaSiting=\(resolvedColor.chromaGeometry.resolvedSiting.rawValue)"
        )

        let chromaReconstructionDecision = HDRChromaReconstructionResolver.resolve(
            requested: configuration.chromaReconstructionMode,
            siting: resolvedColor.chromaGeometry.resolvedSiting
        )

        writeHDRMultiFlightDeepProgress("input-texture-create-start frame=\(progressFrame)")
        let inputTextures = try context.textureCache.makeTextures(for: pixelBuffer)
        writeHDRMultiFlightDeepProgress(
            "input-texture-create-done frame=\(progressFrame) " +
                "format=\(inputTextures.pixelFormat.diagnosticName)"
        )
        if hdrMultiFlightDeepProgressEnabled {
            let outputEvidenceBeforeAcquire = outputPool.evidence
            writeHDRMultiFlightDeepProgress(
                "output-pool-acquire-start frame=\(progressFrame) " +
                    "activeLeases=\(outputEvidenceBeforeAcquire.filter { $0.inFlight }.count) " +
                    "allocations=\(outputEvidenceBeforeAcquire.count) slotsPerSize=3 " +
                    "leaseIDs=\(outputEvidenceBeforeAcquire.filter { $0.inFlight }.map { String($0.id) }.joined(separator: ","))"
            )
        }
        let lease = try outputPool.acquire(width: width, height: height)
        if hdrMultiFlightDeepProgressEnabled {
            let outputEvidenceAfterAcquire = outputPool.evidence
            writeHDRMultiFlightDeepProgress(
                "output-pool-acquire-done frame=\(progressFrame) leaseID=\(lease.id) " +
                    "activeLeases=\(outputEvidenceAfterAcquire.filter { $0.inFlight }.count) " +
                    "allocations=\(outputEvidenceAfterAcquire.count) slotsPerSize=3 " +
                    "leaseIDs=\(outputEvidenceAfterAcquire.filter { $0.inFlight }.map { String($0.id) }.joined(separator: ","))"
            )
        }
        let outputLeaseLifetime = OutputLeaseLifetime(pool: outputPool, id: lease.id)

        let metalCommandBuffer: MTLCommandBuffer
        let ownsCommandBuffer: Bool
        if let commandBuffer {
            metalCommandBuffer = commandBuffer
            ownsCommandBuffer = false
        } else {
            guard let createdCommandBuffer = context.commandQueue.makeCommandBuffer() else {
                throw HDRProcessorError.commandBufferCreationFailed
            }
            metalCommandBuffer = createdCommandBuffer
            ownsCommandBuffer = true
        }

        let debugBuffers: DebugBufferLifetime?
        if debugEnabled {
            guard let statsBuffer = device.makeBuffer(
                length: MemoryLayout<HDRDebugStatsStorage>.stride,
                options: .storageModeShared
            ) else {
                throw HDRProcessorError.debugBufferCreationFailed
            }
            guard let histogramBuffer = device.makeBuffer(
                length: MemoryLayout<UInt32>.stride * HDRDiagnosticHistogramLayout.valueCount,
                options: .storageModeShared
            ), let detailBuffer = device.makeBuffer(
                length: MemoryLayout<UInt32>.stride * HDRDiagnosticDetailLayout.valueCount,
                options: .storageModeShared
            ) else {
                throw HDRProcessorError.debugBufferCreationFailed
            }
            statsBuffer.contents()
                .assumingMemoryBound(to: HDRDebugStatsStorage.self)
                .initialize(to: HDRDebugStatsStorage())
            histogramBuffer.contents()
                .assumingMemoryBound(to: UInt32.self)
                .initialize(repeating: 0, count: HDRDiagnosticHistogramLayout.valueCount)
            let detailPointer = detailBuffer.contents()
                .assumingMemoryBound(to: UInt32.self)
            detailPointer.initialize(repeating: 0, count: HDRDiagnosticDetailLayout.valueCount)
            for band in 0..<HDRDiagnosticDetailLayout.nearBlackBandCount {
                let start = HDRDiagnosticDetailLayout.nearBlackBase +
                    band * HDRDiagnosticDetailLayout.nearBlackStride
                detailPointer[start + HDRDiagnosticDetailLayout.nearBlackInputMinOffset] = UInt32.max
                detailPointer[start + HDRDiagnosticDetailLayout.nearBlackCoreMinOffset] = UInt32.max
            }
            debugBuffers = DebugBufferLifetime(
                stats: statsBuffer,
                histograms: histogramBuffer,
                details: detailBuffer
            )
        } else {
            debugBuffers = nil
        }

        let isYUV = inputTextures.pixelFormat.isYUV
        let pipeline: MTLComputePipelineState
        if debugEnabled {
            switch inputTextures.pixelFormat {
            case .nv12VideoRange, .nv12FullRange:
                pipeline = context.nv12DebugPipeline
            case .p010VideoRange, .p010FullRange:
                pipeline = context.p010DebugPipeline
            case .bgra8:
                pipeline = context.bgraDebugPipeline
            }
        } else {
            switch inputTextures.pixelFormat {
            case .nv12VideoRange, .nv12FullRange:
                pipeline = context.nv12Pipeline
            case .p010VideoRange, .p010FullRange:
                pipeline = context.p010Pipeline
            case .bgra8:
                pipeline = context.bgraPipeline
            }
        }
        writeHDRMultiFlightDeepProgress("parameter-build-start frame=\(progressFrame)")
        let parameterSnapshot = makeShaderParameters(
            configuration: configuration,
            color: resolvedColor,
            temporalSnapshot: processState.temporalSnapshot,
            shadowCoordinates: processState.sceneSnapshot,
            diagnosticROI: diagnosticROI,
            chromaReconstructionDecision: chromaReconstructionDecision
        )
        var parameters = parameterSnapshot.parameters
        writeHDRMultiFlightDeepProgress(
            "parameter-build-done frame=\(progressFrame) " +
                "temporalVersion=\(parameterSnapshot.temporalVersion) " +
                "sceneVersion=\(parameterSnapshot.sceneVersion)"
        )
        let debugFrameContext = debugEnabled ? HDRDebugFrameContext(
            frameIndex: diagnosticFrameIndex == 0
                ? temporalSubmission?.sequence ?? 0
                : diagnosticFrameIndex,
            timestampSeconds: timestamp?.isNumeric == true ? timestamp?.seconds : nil,
            preset: diagnosticPresetLabel,
            configurationGeneration: configurationGeneration,
            configuration: configuration,
            inputPixelFormat: inputTextures.pixelFormat.diagnosticName,
            inputBitDepth: inputTextures.pixelFormat.bitDepth,
            inputRange: inputTextures.pixelFormat.diagnosticRangeName,
            inputChromaLocation: resolvedColor.chromaGeometry.metadataDescription,
            resolvedChromaSiting: resolvedColor.chromaGeometry.resolvedSiting.rawValue,
            chromaReconstructionMode: chromaReconstructionDecision.effective.diagnosticName,
            requestedChromaReconstructionMode: chromaReconstructionDecision.requested.diagnosticName,
            effectiveChromaReconstructionMode: chromaReconstructionDecision.effective.diagnosticName,
            chromaReconstructionFallbackReason: chromaReconstructionDecision.fallbackReason?.rawValue,
            temporalAdaptation: parameters.temporalAdaptation,
            temporalSubmissionSequence: temporalSubmission?.sequence ?? 0,
            sceneShadowFloor: parameters.sceneShadowFloor,
            sceneShadowTop: parameters.sceneShadowTop,
            sceneStatisticsValid: parameters.sceneStatisticsValid != 0,
            roi: diagnosticROI
        ) : nil
        if temporalTraceEnabled, let submission = temporalSubmission {
            temporalTraceStore.append(HDRTemporalSubmissionTrace(
                generation: submission.generation,
                submissionSequence: submission.sequence,
                temporalStateVersionConsumed: parameterSnapshot.temporalVersion,
                sceneStateVersionConsumed: parameterSnapshot.sceneVersion,
                temporalAdaptationUsed: parameters.temporalAdaptation,
                sceneShadowFloorUsed: parameters.sceneShadowFloor,
                sceneShadowTopUsed: parameters.sceneShadowTop,
                sceneStatisticsValidUsed: parameters.sceneStatisticsValid != 0
            ), generation: submission.generation)
        }

        // Allocate every fallible per-frame resource before encoding anything
        // into a caller-owned command buffer. The transform and temporal
        // estimator then share one compute encoder, so a late encoder failure
        // cannot leave partially encoded work with an already-released lease.
        let temporalEstimateBuffer: MTLBuffer?
        if temporalSubmission != nil {
            writeHDRMultiFlightDeepProgress(
                "temporal-estimator-buffer-start frame=\(progressFrame) " +
                    "leaseID=\(lease.id) allocations=\(temporalEstimateBuffers.allocationCount)"
            )
            let buffer = try temporalEstimateBuffers.buffer(for: lease.id)
            buffer.contents().assumingMemoryBound(to: TemporalLumaStatsStorage.self).pointee =
                TemporalLumaStatsStorage()
            temporalEstimateBuffer = buffer
            if hdrMultiFlightDeepProgressEnabled {
                let temporalEvidence = temporalEstimateBuffers.evidence
                let temporalIdentitySummary = temporalEvidence.map {
                    "\($0.leaseID):\($0.identity)"
                }.joined(separator: ",")
                writeHDRMultiFlightDeepProgress(
                    "temporal-estimator-buffer-done frame=\(progressFrame) " +
                        "leaseID=\(lease.id) allocations=\(temporalEvidence.count) " +
                        "identities=\(temporalIdentitySummary)"
                )
            }
        } else {
            temporalEstimateBuffer = nil
        }

        writeHDRMultiFlightDeepProgress("compute-encoder-start frame=\(progressFrame)")
        guard let encoder = metalCommandBuffer.makeComputeCommandEncoder() else {
            throw HDRProcessorError.commandEncoderCreationFailed
        }
        writeHDRMultiFlightDeepProgress("compute-encoder-created frame=\(progressFrame)")
        encoder.setComputePipelineState(pipeline)
        if isYUV {
            encoder.setTexture(inputTextures.y, index: 0)
            encoder.setTexture(inputTextures.uv, index: 1)
            encoder.setTexture(lease.texture, index: 2)
        } else {
            encoder.setTexture(inputTextures.bgra, index: 0)
            encoder.setTexture(lease.texture, index: 1)
        }
        encoder.setBytes(&parameters, length: MemoryLayout<HDRShaderParameters>.stride, index: 0)
        if let debugBuffers {
            encoder.setBuffer(debugBuffers.stats, offset: 0, index: 1)
            encoder.setBuffer(debugBuffers.histograms, offset: 0, index: 2)
            encoder.setBuffer(debugBuffers.details, offset: 0, index: 3)
        }
        let threads = context.threadgroupSize(for: pipeline)
        encoder.dispatchThreads(
            MTLSize(width: width, height: height, depth: 1),
            threadsPerThreadgroup: threads
        )

        if let buffer = temporalEstimateBuffer {
            let temporalPipeline: MTLComputePipelineState
            switch inputTextures.pixelFormat {
            case .nv12VideoRange, .nv12FullRange:
                temporalPipeline = context.nv12TemporalPipeline
            case .p010VideoRange, .p010FullRange:
                temporalPipeline = context.p010TemporalPipeline
            case .bgra8:
                temporalPipeline = context.bgraTemporalPipeline
            }
            encoder.setComputePipelineState(temporalPipeline)
            if isYUV {
                encoder.setTexture(inputTextures.y, index: 0)
                encoder.setTexture(inputTextures.uv, index: 1)
            } else {
                encoder.setTexture(inputTextures.bgra, index: 0)
            }
            encoder.setBytes(
                &parameters,
                length: MemoryLayout<HDRShaderParameters>.stride,
                index: 0
            )
            encoder.setBuffer(buffer, offset: 0, index: 1)
            encoder.dispatchThreads(
                MTLSize(width: 16, height: 9, depth: 1),
                threadsPerThreadgroup: context.threadgroupSize(for: temporalPipeline)
            )
        }
        writeHDRMultiFlightDeepProgress("compute-dispatch-done frame=\(progressFrame)")
        encoder.endEncoding()

        // Retain CVMetalTexture wrappers and the pixel buffer through GPU
        // completion. No CPU copy is introduced by this lifetime guarantee.
        let inputLifetime = GPUInputLifetime(pixelBuffer: pixelBuffer, metalTextures: inputTextures.retainedMetalTextures)
        let debugLifetime = debugBuffers
        let debugStore = self.debugStore
        let adaptiveState = self.adaptiveState
        let temporalStability = configuration.temporalStability
        let histogramStrategy = configuration.sceneHistogramStrategy
        let sceneRelativeEnabled = configuration.toneCurveRevision == .sceneRelativeV4 ||
            configuration.toneCurveRevision == .sceneRelativeV6Candidate ||
            configuration.toneCurveRevision == .sceneAdaptiveV62Candidate
        let temporalEstimateLifetime = temporalEstimateBuffer.map(TemporalEstimateBufferLifetime.init)
        let temporalTraceStore = self.temporalTraceStore
        metalCommandBuffer.addCompletedHandler { [outputLeaseLifetime, inputLifetime, debugLifetime, debugStore, debugFrameContext, temporalEstimateLifetime, adaptiveState, temporalTraceStore, histogramStrategy] commandBuffer in
            _ = outputLeaseLifetime
            _ = inputLifetime
            var adaptiveUpdate: HDRAdaptiveCompletionUpdate?
            var adaptiveCompletionAccepted = false
            if commandBuffer.status == .completed,
               let submission = temporalSubmission {
                let gpuCompletionAccepted = adaptiveState.recordGPUCompletion(
                    sequence: submission.sequence,
                    generation: submission.generation
                )
                if gpuCompletionAccepted,
                   let temporalEstimateLifetime {
                    let stats = temporalEstimateLifetime.buffer.contents().assumingMemoryBound(to: TemporalLumaStatsStorage.self).pointee
                    if stats.sampleCount > 0 {
                        let average = Float(stats.linearLuminanceSum) / Float(stats.sampleCount) / 65535
                        let update = adaptiveState.updateAutomatic(
                            statistics: HDRSceneStatistics(histogram: stats.histogram, strategy: histogramStrategy),
                            averageLuminance: average,
                            stability: temporalStability,
                            sequence: submission.sequence,
                            generation: submission.generation,
                            timestampSeconds: submission.timestampSeconds,
                            sceneRelativeEnabled: sceneRelativeEnabled
                        )
                        adaptiveUpdate = update
                        adaptiveCompletionAccepted = update.applied
                    }
                }
            }
            if temporalTraceStore.traceEnabled,
               adaptiveCompletionAccepted,
               let adaptiveUpdate,
               let submission = temporalSubmission {
                temporalTraceStore.append(HDRTemporalCompletionTrace(
                    generation: submission.generation,
                    submissionSequence: submission.sequence,
                    gpuCompletionSequence: submission.sequence,
                    adaptiveCommittedSequence: adaptiveUpdate.committedSequence,
                    temporalStateVersionProduced: adaptiveUpdate.temporal.sequence,
                    sceneStateVersionProduced: adaptiveUpdate.scene.sequence,
                    temporalAdaptationProduced: adaptiveUpdate.temporal.adaptation,
                    sceneShadowFloorProduced: adaptiveUpdate.scene.floor,
                    sceneShadowTopProduced: adaptiveUpdate.scene.top,
                    sceneStatisticsValidProduced: adaptiveUpdate.scene.valid
                ), generation: submission.generation)
            }
            if commandBuffer.status == .completed,
               let debugLifetime,
               let debugFrameContext {
                debugStore.update(
                    from: debugLifetime,
                    context: debugFrameContext,
                    commandBuffer: commandBuffer,
                    lastCompletedTemporalSequence: adaptiveState.lastAdaptiveCommittedSequence
                )
            }
        }
        if ownsCommandBuffer {
            metalCommandBuffer.commit()
        }

        writeHDRMultiFlightDeepProgress(
            "processor-return frame=\(progressFrame) leaseID=\(lease.id) " +
                "submissionSequence=\(temporalSubmission?.sequence ?? 0) " +
                "generation=\(temporalSubmission?.generation ?? temporalGenerationStorage) " +
                "lastGPUCompletedSequence=\(self.adaptiveState.lastGPUCompletedSequence) " +
                "lastAdaptiveCommittedSequence=\(self.adaptiveState.lastAdaptiveCommittedSequence)"
        )

        return HDRFrame(
            texture: lease.texture,
            sourceTimestamp: timestamp,
            configuration: configuration,
            leaseLifetime: outputLeaseLifetime
        )
    }

    private func makeShaderParameters(
        configuration: HDRConfiguration,
        color: ResolvedColorDescription,
        temporalSnapshot: (adaptation: Float, sequence: UInt64),
        shadowCoordinates: (
            floor: Float,
            top: Float,
            valid: Bool,
            sequence: UInt64,
            statistics: HDRSceneStatistics
        ),
        diagnosticROI: HDRDiagnosticROI?,
        chromaReconstructionDecision: HDRChromaReconstructionDecision
    ) -> (parameters: HDRShaderParameters, temporalVersion: UInt64, sceneVersion: UInt64) {
        // Capture the exact causal values encoded into this frame. Temporal
        // and scene statistics come from one atomic adaptive-state snapshot.
        let matrixKind: UInt32
        switch color.metadata.yCbCrMatrix {
        case .bt709: matrixKind = 0
        case .bt601: matrixKind = 1
        case .bt2020: matrixKind = 2
        }
        let transferFunction: UInt32
        let gamma: Float
        switch color.metadata.transferFunction {
        case .bt709:
            transferFunction = 0
            gamma = 1
        case .sRGB:
            transferFunction = 1
            gamma = 1
        case .gamma(let value):
            transferFunction = 2
            gamma = value
        case .linear:
            transferFunction = 3
            gamma = 1
        }
        let parameters = HDRShaderParameters(
            yOffset: color.yOffset,
            yScale: color.yScale,
            chromaOffset: color.chromaOffset,
            chromaScale: color.chromaScale,
            matrixKind: matrixKind,
            transferFunction: transferFunction,
            gamma: gamma,
            outputMode: configuration.outputMode == .edr ? 0 : 1,
            toneCurveRevision: configuration.toneCurveRevision.rawValue,
            paperWhiteNits: configuration.paperWhiteNits,
            peakNits: configuration.peakNits,
            peakRatio: configuration.peakNits / configuration.paperWhiteNits,
            highlightStrength: configuration.highlightStrength,
            contrastStrength: configuration.contrastStrength,
            saturationCompensation: configuration.saturationCompensation,
            shadowProtection: configuration.shadowProtection,
            temporalAdaptation: temporalSnapshot.adaptation,
            masteringHeadroom: configuration.masteringHeadroom,
            sceneShadowFloor: shadowCoordinates.floor,
            sceneShadowTop: shadowCoordinates.top,
            sceneStatisticsValid: (
                configuration.toneCurveRevision == .sceneRelativeV4 ||
                configuration.toneCurveRevision == .sceneRelativeV6Candidate ||
                configuration.toneCurveRevision == .sceneAdaptiveV62Candidate
            ) && shadowCoordinates.valid ? 1 : 0,
            sceneStatisticsReserved: 0,
            histogramStrategy: configuration.sceneHistogramStrategy.metalValue,
            sceneP01: shadowCoordinates.statistics.p01,
            sceneP05: shadowCoordinates.statistics.p05,
            sceneP50: shadowCoordinates.statistics.p50,
            sceneP90: shadowCoordinates.statistics.p90,
            sceneP99: shadowCoordinates.statistics.p99,
            diagnosticROIX: diagnosticROI?.x ?? 0,
            diagnosticROIY: diagnosticROI?.y ?? 0,
            diagnosticROIWidth: diagnosticROI?.width ?? 0,
            diagnosticROIHeight: diagnosticROI?.height ?? 0,
            diagnosticROIEnabled: diagnosticROI?.isEmpty == false ? 1 : 0,
            developmentLowMidFadePosition: configuration.developmentLowMidFadePosition,
            developmentLowMidStrength: configuration.developmentLowMidStrength,
            developmentExpansionController: configuration.developmentExpansionController.rawValue,
            developmentExpansionMinimumBudget: configuration.developmentExpansionMinimumBudget,
            developmentExpansionHighlightLow: configuration.developmentExpansionHighlightLow,
            developmentExpansionHighlightHigh: configuration.developmentExpansionHighlightHigh,
            developmentExpansionRangeLow: configuration.developmentExpansionRangeLow,
            developmentExpansionRangeHigh: configuration.developmentExpansionRangeHigh,
            developmentExpansionMidtoneLow: configuration.developmentExpansionMidtoneLow,
            developmentExpansionMidtoneHigh: configuration.developmentExpansionMidtoneHigh,
            developmentExpansionCombinedHighlightWeight: configuration.developmentExpansionCombinedHighlightWeight,
            developmentExpansionCombinedRangeWeight: configuration.developmentExpansionCombinedRangeWeight,
            developmentExpansionCombinedMidtoneWeight: configuration.developmentExpansionCombinedMidtoneWeight,
            chromaReconstructionMode: chromaReconstructionDecision.effective.rawValue,
            chromaSampleCenterX: color.chromaGeometry.sampleCenterX,
            chromaSampleCenterY: color.chromaGeometry.sampleCenterY
        )
        return (parameters, temporalSnapshot.sequence, shadowCoordinates.sequence)
    }
}

public struct HDRRuntimeMetrics: Equatable, Sendable {
    public let outputTextureAllocations: Int
    public let outputTextureLogicalBytes: Int64
    public let temporalEstimateBufferAllocations: Int

    public init(
        outputTextureAllocations: Int,
        outputTextureLogicalBytes: Int64,
        temporalEstimateBufferAllocations: Int = 0
    ) {
        self.outputTextureAllocations = outputTextureAllocations
        self.outputTextureLogicalBytes = outputTextureLogicalBytes
        self.temporalEstimateBufferAllocations = temporalEstimateBufferAllocations
    }
}

private final class GPUInputLifetime: @unchecked Sendable {
    let pixelBuffer: CVPixelBuffer
    let metalTextures: [CVMetalTexture]

    init(pixelBuffer: CVPixelBuffer, metalTextures: [CVMetalTexture]) {
        self.pixelBuffer = pixelBuffer
        self.metalTextures = metalTextures
    }
}
