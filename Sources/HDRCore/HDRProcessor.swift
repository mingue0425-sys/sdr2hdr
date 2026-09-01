import CoreMedia
import CoreVideo
import Foundation
import Metal

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

private final class TemporalState: @unchecked Sendable {
    private let lock = NSLock()
    private var control = HDRTemporalControlState()
    private var generation: UInt64 = 0

    func value() -> Float {
        lock.lock()
        defer { lock.unlock() }
        return control.adaptation
    }

    func snapshot() -> (adaptation: Float, sequence: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        return (control.adaptation, control.automaticSequence)
    }

    func advanceGeneration(to generation: UInt64, reset: Bool) {
        lock.lock()
        self.generation = generation
        if reset { control.reset() }
        lock.unlock()
    }

    func update(averageLuminance: Float, stability: Float, sceneCut: Bool) {
        lock.lock()
        control.updateAverage(averageLuminance: averageLuminance, stability: stability, sceneCut: sceneCut)
        lock.unlock()
    }

    @discardableResult
    func updateAutomatic(
        averageLuminance: Float,
        stability: Float,
        sequence: UInt64,
        generation: UInt64
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard generation == self.generation else { return false }
        return control.updateAutomaticAverage(
            averageLuminance: averageLuminance,
            stability: stability,
            sequence: sequence
        )
    }
}

private final class SceneShadowState: @unchecked Sendable {
    private let lock = NSLock()
    private var control = HDRTemporalControlState()
    private var generation: UInt64 = 0

    func value() -> (floor: Float, top: Float, valid: Bool) {
        lock.lock()
        defer { lock.unlock() }
        return (control.shadowFloor, control.shadowTop, control.shadowStatisticsValid)
    }

    func snapshot() -> (floor: Float, top: Float, valid: Bool, sequence: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        return (control.shadowFloor, control.shadowTop, control.shadowStatisticsValid, control.shadowSequence)
    }

    func advanceGeneration(to generation: UInt64, reset: Bool) {
        lock.lock()
        self.generation = generation
        if reset { control.reset() }
        lock.unlock()
    }

    func update(statistics: HDRSceneStatistics, stability: Float, sceneCut: Bool) {
        lock.lock()
        control.updateStatistics(statistics, stability: stability, sceneCut: sceneCut)
        lock.unlock()
    }

    /// Returns the same scene-cut decision used by the runtime temporal
    /// estimator. The sequence guard prevents an out-of-order completion from
    /// changing the causal control state.
    func updateAutomatic(
        statistics: HDRSceneStatistics,
        averageLuminance: Float,
        stability: Float,
        sequence: UInt64,
        generation: UInt64
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard generation == self.generation else { return false }
        let sceneCut = control.updateAutomaticStatistics(
            statistics,
            averageLuminance: averageLuminance,
            stability: stability,
            sequence: sequence
        )
        return sceneCut
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

    var histogram: [UInt32] {
        [histogram0, histogram1, histogram2, histogram3, histogram4, histogram5, histogram6, histogram7,
         histogram8, histogram9, histogram10, histogram11, histogram12, histogram13, histogram14, histogram15]
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
    public let submissionSequence: UInt64
    public let temporalStateVersionConsumed: UInt64
    public let sceneStateVersionConsumed: UInt64
    public let temporalAdaptationUsed: Float
    public let sceneShadowFloorUsed: Float
    public let sceneShadowTopUsed: Float
    public let sceneStatisticsValidUsed: Bool
}

public struct HDRTemporalCompletionTrace: Equatable, Sendable {
    public let submissionSequence: UInt64
    public let temporalStateVersionProduced: UInt64
    public let sceneStateVersionProduced: UInt64
    public let temporalAdaptationProduced: Float
    public let sceneShadowFloorProduced: Float
    public let sceneShadowTopProduced: Float
    public let sceneStatisticsValidProduced: Bool
}


private final class TemporalCompletionBookkeeping: @unchecked Sendable {
    private let lock = NSLock()
    private var generationStorage: UInt64 = 0
    private var lastCompletedSequenceStorage: UInt64 = 0
    private var traceEnabledStorage = false

    var lastCompletedSequence: UInt64 {
        lock.withLock { lastCompletedSequenceStorage }
    }

    var traceEnabled: Bool {
        get { lock.withLock { traceEnabledStorage } }
        set { lock.withLock { traceEnabledStorage = newValue } }
    }

    func advanceGeneration(to generation: UInt64) {
        lock.withLock {
            generationStorage = generation
            lastCompletedSequenceStorage = 0
        }
    }

    func recordCompleted(sequence: UInt64, generation: UInt64) {
        lock.withLock {
            guard generation == generationStorage else { return }
            lastCompletedSequenceStorage = max(lastCompletedSequenceStorage, sequence)
        }
    }
}

private final class TemporalTraceStore: @unchecked Sendable {
    private let lock = NSLock()
    private var submissions: [HDRTemporalSubmissionTrace] = []
    private var completions: [HDRTemporalCompletionTrace] = []

    func clear() {
        lock.withLock {
            submissions.removeAll(keepingCapacity: true)
            completions.removeAll(keepingCapacity: true)
        }
    }

    func append(_ trace: HDRTemporalSubmissionTrace) {
        lock.withLock { submissions.append(trace) }
    }

    func append(_ trace: HDRTemporalCompletionTrace) {
        lock.withLock { completions.append(trace) }
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
    private let temporalState = TemporalState()
    private let sceneShadowState = SceneShadowState()
    private let temporalEstimateBuffers: TemporalEstimateBufferPool
    private let debugStore = DebugStatisticsStore()
    private var debugEnabled = false
    private var automaticTemporalEnabled = true
    private var temporalSubmissionSequenceStorage: UInt64 = 0
    private var temporalGenerationStorage: UInt64 = 0
    private let temporalCompletionBookkeeping = TemporalCompletionBookkeeping()
    private let temporalTraceStore = TemporalTraceStore()

    public var configuration: HDRConfiguration {
        stateLock.lock()
        defer { stateLock.unlock() }
        return currentConfiguration
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

    public init(device: MTLDevice, configuration: HDRConfiguration = .hdr) throws {
        do {
            self.currentConfiguration = try configuration.validated()
        } catch let error as HDRConfigurationError {
            throw HDRProcessorError.configuration(error)
        }
        self.device = device
        self.context = try MetalContext(device: device)
        self.outputPool = OutputTexturePool(device: device)
        self.temporalEstimateBuffers = TemporalEstimateBufferPool(device: device)
    }

    /// Update parameters without rebuilding Metal libraries or pipeline state.
    public func update(configuration: HDRConfiguration) throws {
        do {
            let validated = try configuration.validated()
            stateLock.withLock {
                currentConfiguration = validated
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
        let stability = configuration.temporalStability
        temporalState.update(averageLuminance: averageLuminance, stability: stability, sceneCut: sceneCut)
    }

    /// Supplies the same percentile state that the asynchronous runtime
    /// estimator derives from the previous frame. This is intentionally a
    /// state update API; it does not inspect or copy frame pixels.
    public func updateSceneStatistics(_ statistics: HDRSceneStatistics, sceneCut: Bool = false) {
        sceneShadowState.update(
            statistics: statistics,
            stability: configuration.temporalStability,
            sceneCut: sceneCut
        )
    }

    /// Current causal scene-relative shadow coordinates, useful for the
    /// offline/runtime equivalence harness and DEBUG diagnostics.
    public var sceneShadowCoordinates: (floor: Float, top: Float, valid: Bool) {
        sceneShadowState.value()
    }

    /// Resets temporal history at a seek/scene boundary. Offline calibration
    /// and HDRPlayer use the same state transition.
    public func resetTemporalState(averageLuminance: Float = 0.5) {
        stateLock.withLock {
            let stability = currentConfiguration.temporalStability
            advanceTemporalGenerationLocked(resetTemporal: true, resetScene: false)
            temporalState.update(
                averageLuminance: averageLuminance,
                stability: stability,
                sceneCut: true
            )
        }
    }

    /// Clears history to the neutral adaptation used at processor startup.
    public func clearTemporalHistory() {
        stateLock.withLock {
            advanceTemporalGenerationLocked(resetTemporal: true, resetScene: true)
        }
    }

    /// Must be called with stateLock held.  State objects validate this
    /// generation while holding their own locks, closing the reset/completion
    /// race rather than relying on a check performed before the update.
    @discardableResult
    private func advanceTemporalGenerationLocked(
        resetTemporal: Bool,
        resetScene: Bool
    ) -> UInt64 {
        temporalGenerationStorage &+= 1
        let generation = temporalGenerationStorage
        temporalState.advanceGeneration(to: generation, reset: resetTemporal)
        sceneShadowState.advanceGeneration(to: generation, reset: resetScene)
        temporalCompletionBookkeeping.advanceGeneration(to: generation)
        return generation
    }

    /// Exposed for calibration diagnostics; it does not synchronize with GPU.
    public var temporalAdaptation: Float { temporalState.value() }

    public var temporalSubmissionSequence: UInt64 {
        stateLock.withLock { temporalSubmissionSequenceStorage }
    }

    /// Highest temporal frame whose completion handler has updated causal state.
    public var lastCompletedTemporalSequence: UInt64 {
        temporalCompletionBookkeeping.lastCompletedSequence
    }

    /// Test/debug-only temporal trace instrumentation. Disabled by default and
    /// never required by the realtime path. It records the exact causal state
    /// encoded into each submitted frame plus the state produced at completion.
    public var temporalTraceEnabled: Bool {
        get { temporalCompletionBookkeeping.traceEnabled }
        set { temporalCompletionBookkeeping.traceEnabled = newValue }
    }

    public func clearTemporalTrace() { temporalTraceStore.clear() }
    public var temporalSubmissionTrace: [HDRTemporalSubmissionTrace] { temporalTraceStore.submissionValues }
    public var temporalCompletionTrace: [HDRTemporalCompletionTrace] { temporalTraceStore.completionValues }

    /// Encodes the frame without waiting for GPU completion. The caller owns
    /// an optional supplied command buffer and must keep the input
    /// CVPixelBuffer alive and unmodified until that command buffer completes.
    public func process(
        pixelBuffer: CVPixelBuffer,
        commandBuffer: MTLCommandBuffer? = nil
    ) throws -> HDRFrame {
        try process(pixelBuffer: pixelBuffer, timestamp: nil, commandBuffer: commandBuffer)
    }

    public func process(
        pixelBuffer: CVPixelBuffer,
        timestamp: CMTime?,
        commandBuffer: MTLCommandBuffer? = nil
    ) throws -> HDRFrame {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        guard width > 0, height > 0 else {
            throw HDRProcessorError.invalidDimensions
        }

        // Capture configuration, instrumentation, submission sequence and
        // generation atomically. A concurrent update may still let this frame
        // render with the old constants, but its completion can no longer
        // mutate the new temporal generation.
        let processState: (
            configuration: HDRConfiguration,
            debugEnabled: Bool,
            temporalSubmission: (sequence: UInt64, generation: UInt64)?
        ) = stateLock.withLock {
            let submission: (sequence: UInt64, generation: UInt64)?
            if automaticTemporalEnabled {
                temporalSubmissionSequenceStorage &+= 1
                submission = (
                    sequence: temporalSubmissionSequenceStorage,
                    generation: temporalGenerationStorage
                )
            } else {
                submission = nil
            }
            return (currentConfiguration, debugEnabled, submission)
        }
        let configuration = processState.configuration
        let debugEnabled = processState.debugEnabled
        let temporalSubmission = processState.temporalSubmission
        let resolvedColor: ResolvedColorDescription
        do {
            resolvedColor = try HDRColorMetadataResolver.resolve(
                pixelBuffer: pixelBuffer,
                fallbackPolicy: configuration.inputFallbackPolicy
            )
        } catch let error as HDRColorMetadataError {
            throw HDRProcessorError.metadata(error)
        }

        let inputTextures = try context.textureCache.makeTextures(for: pixelBuffer)
        let lease = try outputPool.acquire(width: width, height: height)
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

        let debugBuffer: MTLBuffer?
        if debugEnabled {
            guard let createdBuffer = device.makeBuffer(
                length: MemoryLayout<HDRDebugStatsStorage>.stride,
                options: .storageModeShared
            ) else {
                throw HDRProcessorError.debugBufferCreationFailed
            }
            createdBuffer.contents()
                .assumingMemoryBound(to: HDRDebugStatsStorage.self)
                .initialize(to: HDRDebugStatsStorage())
            debugBuffer = createdBuffer
        } else {
            debugBuffer = nil
        }

        let isYUV = inputTextures.y != nil
        let pipeline: MTLComputePipelineState
        if debugEnabled {
            pipeline = isYUV ? context.nv12DebugPipeline : context.bgraDebugPipeline
        } else {
            pipeline = isYUV ? context.nv12Pipeline : context.bgraPipeline
        }
        let parameterSnapshot = makeShaderParameters(configuration: configuration, color: resolvedColor)
        var parameters = parameterSnapshot.parameters
        if temporalTraceEnabled, let sequence = temporalSubmission?.sequence {
            temporalTraceStore.append(HDRTemporalSubmissionTrace(
                submissionSequence: sequence,
                temporalStateVersionConsumed: parameterSnapshot.temporalVersion,
                sceneStateVersionConsumed: parameterSnapshot.sceneVersion,
                temporalAdaptationUsed: parameters.temporalAdaptation,
                sceneShadowFloorUsed: parameters.sceneShadowFloor,
                sceneShadowTopUsed: parameters.sceneShadowTop,
                sceneStatisticsValidUsed: parameters.sceneStatisticsValid != 0
            ))
        }

        // Allocate every fallible per-frame resource before encoding anything
        // into a caller-owned command buffer. The transform and temporal
        // estimator then share one compute encoder, so a late encoder failure
        // cannot leave partially encoded work with an already-released lease.
        let temporalEstimateBuffer: MTLBuffer?
        if temporalSubmission != nil {
            let buffer = try temporalEstimateBuffers.buffer(for: lease.id)
            buffer.contents().assumingMemoryBound(to: TemporalLumaStatsStorage.self).pointee =
                TemporalLumaStatsStorage()
            temporalEstimateBuffer = buffer
        } else {
            temporalEstimateBuffer = nil
        }

        guard let encoder = metalCommandBuffer.makeComputeCommandEncoder() else {
            throw HDRProcessorError.commandEncoderCreationFailed
        }
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
        if let debugBuffer {
            encoder.setBuffer(debugBuffer, offset: 0, index: 1)
        }
        let threads = context.threadgroupSize(for: pipeline)
        encoder.dispatchThreads(
            MTLSize(width: width, height: height, depth: 1),
            threadsPerThreadgroup: threads
        )

        if let buffer = temporalEstimateBuffer {
            let temporalPipeline = isYUV ? context.nv12TemporalPipeline : context.bgraTemporalPipeline
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
        encoder.endEncoding()

        // Retain CVMetalTexture wrappers and the pixel buffer through GPU
        // completion. No CPU copy is introduced by this lifetime guarantee.
        let inputLifetime = GPUInputLifetime(pixelBuffer: pixelBuffer, metalTextures: inputTextures.retainedMetalTextures)
        let debugLifetime = debugBuffer.map { DebugBufferLifetime(buffer: $0) }
        let debugStore = self.debugStore
        let temporalState = self.temporalState
        let sceneShadowState = self.sceneShadowState
        let temporalStability = configuration.temporalStability
        let sceneRelativeEnabled = configuration.toneCurveRevision == .sceneRelativeV4
        let temporalEstimateLifetime = temporalEstimateBuffer.map(TemporalEstimateBufferLifetime.init)
        let temporalCompletionBookkeeping = self.temporalCompletionBookkeeping
        let temporalTraceStore = self.temporalTraceStore
        metalCommandBuffer.addCompletedHandler { [outputLeaseLifetime, inputLifetime, debugLifetime, debugStore, temporalEstimateLifetime, temporalState, sceneShadowState, temporalCompletionBookkeeping, temporalTraceStore] commandBuffer in
            _ = outputLeaseLifetime
            _ = inputLifetime
            if let debugLifetime {
                debugStore.update(from: debugLifetime.buffer, width: width, height: height, commandBuffer: commandBuffer)
            }
            var appliedTemporalUpdate = false
            if commandBuffer.status == .completed,
               let temporalEstimateLifetime,
               let submission = temporalSubmission {
                let stats = temporalEstimateLifetime.buffer.contents().assumingMemoryBound(to: TemporalLumaStatsStorage.self).pointee
                if stats.sampleCount > 0 {
                    let average = Float(stats.linearLuminanceSum) / Float(stats.sampleCount) / 65535
                    appliedTemporalUpdate = temporalState.updateAutomatic(
                        averageLuminance: average, stability: temporalStability,
                        sequence: submission.sequence,
                        generation: submission.generation
                    )
                    if appliedTemporalUpdate, sceneRelativeEnabled {
                        _ = sceneShadowState.updateAutomatic(
                            statistics: HDRSceneStatistics(histogram: stats.histogram),
                            averageLuminance: average,
                            stability: temporalStability,
                            sequence: submission.sequence,
                            generation: submission.generation
                        )
                    }
                    if appliedTemporalUpdate {
                        temporalCompletionBookkeeping.recordCompleted(
                            sequence: submission.sequence,
                            generation: submission.generation
                        )
                    }
                }
            }
            if temporalCompletionBookkeeping.traceEnabled,
               appliedTemporalUpdate,
               let sequence = temporalSubmission?.sequence {
                let temporalSnapshot = temporalState.snapshot()
                let sceneSnapshot = sceneShadowState.snapshot()
                temporalTraceStore.append(HDRTemporalCompletionTrace(
                    submissionSequence: sequence,
                    temporalStateVersionProduced: temporalSnapshot.sequence,
                    sceneStateVersionProduced: sceneSnapshot.sequence,
                    temporalAdaptationProduced: temporalSnapshot.adaptation,
                    sceneShadowFloorProduced: sceneSnapshot.floor,
                    sceneShadowTopProduced: sceneSnapshot.top,
                    sceneStatisticsValidProduced: sceneSnapshot.valid
                ))
            }
        }
        if ownsCommandBuffer {
            metalCommandBuffer.commit()
        }

        return HDRFrame(
            texture: lease.texture,
            sourceTimestamp: timestamp,
            configuration: configuration,
            leaseLifetime: outputLeaseLifetime
        )
    }

    private func makeShaderParameters(
        configuration: HDRConfiguration,
        color: ResolvedColorDescription
    ) -> (parameters: HDRShaderParameters, temporalVersion: UInt64, sceneVersion: UInt64) {
        // Capture the exact causal values encoded into this frame. Temporal
        // and scene statistics deliberately retain independent sequence IDs:
        // under burst load one completion may advance one state before the
        // other, and the parity harness must observe that rather than infer it.
        let temporalSnapshot = temporalState.snapshot()
        let shadowCoordinates = sceneShadowState.snapshot()
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
            sceneStatisticsValid: configuration.toneCurveRevision == .sceneRelativeV4 && shadowCoordinates.valid ? 1 : 0,
            sceneStatisticsReserved: 0
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
