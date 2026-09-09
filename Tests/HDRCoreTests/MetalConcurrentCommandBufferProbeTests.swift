import Foundation
import Metal
import XCTest

private struct MetalProbeCounts: Codable {
    let commandBuffersCommitted: Int
    let commandBuffersCompleted: Int
    let completionHandlers: Int?

    init(
        commandBuffersCommitted: Int,
        commandBuffersCompleted: Int,
        completionHandlers: Int? = nil
    ) {
        self.commandBuffersCommitted = commandBuffersCommitted
        self.commandBuffersCompleted = commandBuffersCompleted
        self.completionHandlers = completionHandlers
    }
}

private struct MetalProbeResult: Codable {
    let probe: String
    let status: String
    let commandBuffersCommitted: Int
    let commandBuffersCompleted: Int
    let completionHandlers: Int?
    let error: String?
}

private struct MetalDeviceInventory: Codable {
    let name: String
    let registryID: String
    let isLowPower: Bool
    let isRemovable: Bool
    let hasUnifiedMemory: Bool
}

private struct MetalProbeFailure: LocalizedError {
    let message: String

    var errorDescription: String? { message }
}

private final class CompletionCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func increment() {
        lock.lock()
        storage += 1
        lock.unlock()
    }
}

private let metalProbeShaderSource = """
#include <metal_stdlib>
using namespace metal;

kernel void probe_write(
    device uint *output [[buffer(0)]],
    uint index [[thread_position_in_grid]]) {
    output[index] = index + 1;
}

struct ProbeVertexOut {
    float4 position [[position]];
    float2 texCoord;
};

vertex ProbeVertexOut probe_vertex(uint vertexID [[vertex_id]]) {
    const float2 positions[3] = {
        float2(-1.0, -1.0),
        float2( 3.0, -1.0),
        float2(-1.0,  3.0)
    };
    const float2 texCoords[3] = {
        float2(0.0, 0.0),
        float2(2.0, 0.0),
        float2(0.0, 2.0)
    };
    ProbeVertexOut output;
    output.position = float4(positions[vertexID], 0.0, 1.0);
    output.texCoord = texCoords[vertexID];
    return output;
}

fragment float4 probe_fragment(
    ProbeVertexOut input [[stage_in]],
    texture2d<float> source [[texture(0)]],
    sampler sourceSampler [[sampler(0)]]) {
    return source.sample(sourceSampler, input.texCoord);
}
"""

final class MetalConcurrentCommandBufferProbeTests: XCTestCase {
    func testP0DeviceInventory() {
        executeProbe("P0_device_inventory") {
            let device = try requireDevice()
            let inventory = MetalDeviceInventory(
                name: device.name,
                registryID: String(device.registryID),
                isLowPower: device.isLowPower,
                isRemovable: device.isRemovable,
                hasUnifiedMemory: device.hasUnifiedMemory
            )
            let encoded = try JSONEncoder().encode(inventory)
            print("PURE_METAL_DEVICE_JSON \(String(decoding: encoded, as: UTF8.self))")
            return MetalProbeCounts(commandBuffersCommitted: 0, commandBuffersCompleted: 0)
        }
    }

    func testP1EmptyCommandBuffers() {
        executeProbe("P1_empty") {
            let device = try requireDevice()
            guard let queue = device.makeCommandQueue(),
                  let first = queue.makeCommandBuffer(),
                  let second = queue.makeCommandBuffer() else {
                throw MetalProbeFailure(message: "could not create Metal queue or empty command buffers")
            }

            let completionCounter = CompletionCounter()
            let completionGroup = DispatchGroup()
            for commandBuffer in [first, second] {
                completionGroup.enter()
                commandBuffer.addCompletedHandler { _ in
                    completionCounter.increment()
                    completionGroup.leave()
                }
            }

            let counts = try commitAndWait(
                [first, second],
                probe: "P1_empty"
            )
            guard completionGroup.wait(timeout: .now() + 5) == .success else {
                throw MetalProbeFailure(message: "empty command buffer completion handlers did not drain")
            }
            guard completionCounter.value == 2 else {
                throw MetalProbeFailure(
                    message: "expected two completion handlers, got \(completionCounter.value)"
                )
            }
            print("PURE_METAL_PROGRESS probe=P1_empty phase=completion-handlers count=\(completionCounter.value)")
            return MetalProbeCounts(
                commandBuffersCommitted: counts.commandBuffersCommitted,
                commandBuffersCompleted: counts.commandBuffersCompleted,
                completionHandlers: completionCounter.value
            )
        }
    }

    func testP1SerialEmptyCommandBuffers() {
        executeProbe("P1_serial_empty") {
            let device = try requireDevice()
            guard let queue = device.makeCommandQueue() else {
                throw MetalProbeFailure(message: "could not create serial-control queue")
            }
            var committed = 0
            var completed = 0
            for index in 0..<2 {
                guard let commandBuffer = queue.makeCommandBuffer() else {
                    throw MetalProbeFailure(message: "could not create serial-control command buffer \(index)")
                }
                let counts = try commitAndWait(
                    [commandBuffer],
                    probe: "P1_serial_empty"
                )
                committed += counts.commandBuffersCommitted
                completed += counts.commandBuffersCompleted
            }
            return MetalProbeCounts(
                commandBuffersCommitted: committed,
                commandBuffersCompleted: completed
            )
        }
    }

    func testP2BlitCommandBuffers() {
        executeProbe("P2_blit") {
            let device = try requireDevice()
            guard let queue = device.makeCommandQueue(),
                  let first = queue.makeCommandBuffer(),
                  let second = queue.makeCommandBuffer(),
                  let firstBuffer = device.makeBuffer(
                    length: 64 * 1024,
                    options: .storageModeShared
                  ),
                  let secondBuffer = device.makeBuffer(
                    length: 64 * 1024,
                    options: .storageModeShared
                  ) else {
                throw MetalProbeFailure(message: "could not create P2 blit resources")
            }

            for (commandBuffer, buffer, value) in [
                (first, firstBuffer, UInt8(0x5a)),
                (second, secondBuffer, UInt8(0xa5))
            ] {
                guard let blit = commandBuffer.makeBlitCommandEncoder() else {
                    throw MetalProbeFailure(message: "could not create P2 blit encoder")
                }
                blit.fill(buffer: buffer, range: 0..<buffer.length, value: value)
                blit.endEncoding()
            }

            let counts = try commitAndWait([first, second], probe: "P2_blit")
            try verify(buffer: firstBuffer, equals: 0x5a, probe: "P2_blit first")
            try verify(buffer: secondBuffer, equals: 0xa5, probe: "P2_blit second")
            return counts
        }
    }

    func testP3ComputeCommandBuffers() {
        executeProbe("P3_compute") {
            let device = try requireDevice()
            let pipeline = try makeComputePipeline(device: device)
            guard let queue = device.makeCommandQueue(),
                  let first = queue.makeCommandBuffer(),
                  let second = queue.makeCommandBuffer(),
                  let firstBuffer = device.makeBuffer(
                    length: computeElementCount * MemoryLayout<UInt32>.stride,
                    options: .storageModeShared
                  ),
                  let secondBuffer = device.makeBuffer(
                    length: computeElementCount * MemoryLayout<UInt32>.stride,
                    options: .storageModeShared
                  ) else {
                throw MetalProbeFailure(message: "could not create P3 compute resources")
            }

            try encodeCompute(
                commandBuffer: first,
                pipeline: pipeline,
                output: firstBuffer,
                probe: "P3_compute first"
            )
            try encodeCompute(
                commandBuffer: second,
                pipeline: pipeline,
                output: secondBuffer,
                probe: "P3_compute second"
            )

            let counts = try commitAndWait([first, second], probe: "P3_compute")
            try verifyComputeOutput(firstBuffer, probe: "P3_compute first")
            try verifyComputeOutput(secondBuffer, probe: "P3_compute second")
            return counts
        }
    }

    func testP4RenderCommandBuffers() {
        executeProbe("P4_render") {
            let device = try requireDevice()
            let renderPipeline = try makeRenderPipeline(device: device)
            let sampler = try makeSampler(device: device)
            let firstSource = try makeSourceTexture(device: device, seed: 17)
            let secondSource = try makeSourceTexture(device: device, seed: 43)
            let firstTarget = try makeRenderTarget(device: device)
            let secondTarget = try makeRenderTarget(device: device)
            guard let queue = device.makeCommandQueue(),
                  let first = queue.makeCommandBuffer(),
                  let second = queue.makeCommandBuffer() else {
                throw MetalProbeFailure(message: "could not create P4 render command buffers")
            }

            try encodeRender(
                commandBuffer: first,
                pipeline: renderPipeline,
                sampler: sampler,
                source: firstSource,
                target: firstTarget,
                probe: "P4_render first"
            )
            try encodeRender(
                commandBuffer: second,
                pipeline: renderPipeline,
                sampler: sampler,
                source: secondSource,
                target: secondTarget,
                probe: "P4_render second"
            )

            return try commitAndWait([first, second], probe: "P4_render")
        }
    }

    func testP5ComputeRenderBlitCommandBuffers() {
        executeProbe("P5_compute_render_blit") {
            let device = try requireDevice()
            let computePipeline = try makeComputePipeline(device: device)
            let renderPipeline = try makeRenderPipeline(device: device)
            let sampler = try makeSampler(device: device)
            let first = try makeMultiEncoderResources(device: device, seed: 29)
            let second = try makeMultiEncoderResources(device: device, seed: 71)
            guard let queue = device.makeCommandQueue(),
                  let firstCommandBuffer = queue.makeCommandBuffer(),
                  let secondCommandBuffer = queue.makeCommandBuffer() else {
                throw MetalProbeFailure(message: "could not create P5 command buffers")
            }

            try encodeComputeRenderBlit(
                commandBuffer: firstCommandBuffer,
                computePipeline: computePipeline,
                renderPipeline: renderPipeline,
                sampler: sampler,
                resources: first,
                probe: "P5_compute_render_blit first"
            )
            try encodeComputeRenderBlit(
                commandBuffer: secondCommandBuffer,
                computePipeline: computePipeline,
                renderPipeline: renderPipeline,
                sampler: sampler,
                resources: second,
                probe: "P5_compute_render_blit second"
            )

            let counts = try commitAndWait(
                [firstCommandBuffer, secondCommandBuffer],
                probe: "P5_compute_render_blit"
            )
            try verifyComputeOutput(first.computeOutput, probe: "P5_compute_render_blit first")
            try verifyReadback(first.readback, probe: "P5_compute_render_blit first")
            try verifyComputeOutput(second.computeOutput, probe: "P5_compute_render_blit second")
            try verifyReadback(second.readback, probe: "P5_compute_render_blit second")
            return counts
        }
    }

    func testP6SharedPipelineStates() {
        executeProbe("P6_shared_pipeline") {
            let device = try requireDevice()
            let computePipeline = try makeComputePipeline(device: device)
            let renderPipeline = try makeRenderPipeline(device: device)
            let sampler = try makeSampler(device: device)
            let first = try makeMultiEncoderResources(device: device, seed: 101)
            let second = try makeMultiEncoderResources(device: device, seed: 151)
            guard let queue = device.makeCommandQueue(),
                  let firstCommandBuffer = queue.makeCommandBuffer(),
                  let secondCommandBuffer = queue.makeCommandBuffer() else {
                throw MetalProbeFailure(message: "could not create P6 command buffers")
            }

            print("PURE_METAL_PROGRESS probe=P6_shared_pipeline phase=shared-state-created")
            try encodeComputeRenderBlit(
                commandBuffer: firstCommandBuffer,
                computePipeline: computePipeline,
                renderPipeline: renderPipeline,
                sampler: sampler,
                resources: first,
                probe: "P6_shared_pipeline first"
            )
            try encodeComputeRenderBlit(
                commandBuffer: secondCommandBuffer,
                computePipeline: computePipeline,
                renderPipeline: renderPipeline,
                sampler: sampler,
                resources: second,
                probe: "P6_shared_pipeline second"
            )

            let counts = try commitAndWait(
                [firstCommandBuffer, secondCommandBuffer],
                probe: "P6_shared_pipeline"
            )
            try verifyComputeOutput(first.computeOutput, probe: "P6_shared_pipeline first")
            try verifyReadback(first.readback, probe: "P6_shared_pipeline first")
            try verifyComputeOutput(second.computeOutput, probe: "P6_shared_pipeline second")
            try verifyReadback(second.readback, probe: "P6_shared_pipeline second")
            return counts
        }
    }

    func testP7SharedReadOnlyTexture() {
        executeProbe("P7_shared_readonly_texture") {
            let device = try requireDevice()
            let computePipeline = try makeComputePipeline(device: device)
            let renderPipeline = try makeRenderPipeline(device: device)
            let sampler = try makeSampler(device: device)
            let sharedSource = try makeSourceTexture(device: device, seed: 211)
            let first = try makeMultiEncoderResources(
                device: device,
                seed: 223,
                source: sharedSource
            )
            let second = try makeMultiEncoderResources(
                device: device,
                seed: 227,
                source: sharedSource
            )
            guard let queue = device.makeCommandQueue(),
                  let firstCommandBuffer = queue.makeCommandBuffer(),
                  let secondCommandBuffer = queue.makeCommandBuffer() else {
                throw MetalProbeFailure(message: "could not create P7 command buffers")
            }

            print("PURE_METAL_PROGRESS probe=P7_shared_readonly_texture phase=shared-readonly-texture-created")
            try encodeComputeRenderBlit(
                commandBuffer: firstCommandBuffer,
                computePipeline: computePipeline,
                renderPipeline: renderPipeline,
                sampler: sampler,
                resources: first,
                probe: "P7_shared_readonly_texture first"
            )
            try encodeComputeRenderBlit(
                commandBuffer: secondCommandBuffer,
                computePipeline: computePipeline,
                renderPipeline: renderPipeline,
                sampler: sampler,
                resources: second,
                probe: "P7_shared_readonly_texture second"
            )

            let counts = try commitAndWait(
                [firstCommandBuffer, secondCommandBuffer],
                probe: "P7_shared_readonly_texture"
            )
            try verifyComputeOutput(first.computeOutput, probe: "P7_shared_readonly_texture first")
            try verifyReadback(first.readback, probe: "P7_shared_readonly_texture first")
            try verifyComputeOutput(second.computeOutput, probe: "P7_shared_readonly_texture second")
            try verifyReadback(second.readback, probe: "P7_shared_readonly_texture second")
            return counts
        }
    }

    private let computeElementCount = 256
    private let renderWidth = 64
    private let renderHeight = 36

    private struct MultiEncoderResources {
        let source: MTLTexture
        let renderTarget: MTLTexture
        let computeOutput: MTLBuffer
        let readback: MTLBuffer
    }

    private func executeProbe(
        _ name: String,
        body: () throws -> MetalProbeCounts
    ) {
        print("PURE_METAL_PROGRESS probe=\(name) phase=start")
        do {
            let counts = try body()
            let result = MetalProbeResult(
                probe: name,
                status: "PASS",
                commandBuffersCommitted: counts.commandBuffersCommitted,
                commandBuffersCompleted: counts.commandBuffersCompleted,
                completionHandlers: counts.completionHandlers,
                error: nil
            )
            print("PURE_METAL_PROBE_RESULT \(encodeJSON(result))")
        } catch {
            let result = MetalProbeResult(
                probe: name,
                status: "FAIL",
                commandBuffersCommitted: 0,
                commandBuffersCompleted: 0,
                completionHandlers: nil,
                error: error.localizedDescription
            )
            print("PURE_METAL_PROBE_ERROR probe=\(name) error=\(error.localizedDescription)")
            print("PURE_METAL_PROBE_RESULT \(encodeJSON(result))")
            XCTFail("\(name): \(error.localizedDescription)")
        }
    }

    private func requireDevice() throws -> MTLDevice {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw MetalProbeFailure(message: "MTLCreateSystemDefaultDevice returned nil")
        }
        return device
    }

    private func commitAndWait(
        _ commandBuffers: [MTLCommandBuffer],
        probe: String
    ) throws -> MetalProbeCounts {
        guard !commandBuffers.isEmpty else {
            throw MetalProbeFailure(message: "\(probe): no command buffers")
        }
        print("PURE_METAL_PROGRESS probe=\(probe) phase=commit count=\(commandBuffers.count)")
        for commandBuffer in commandBuffers {
            commandBuffer.commit()
        }
        print("PURE_METAL_PROGRESS probe=\(probe) phase=committed count=\(commandBuffers.count)")
        for commandBuffer in commandBuffers {
            commandBuffer.waitUntilCompleted()
        }
        for (index, commandBuffer) in commandBuffers.enumerated() {
            guard commandBuffer.status == .completed, commandBuffer.error == nil else {
                throw MetalProbeFailure(
                    message: "\(probe): command buffer \(index) status=\(commandBuffer.status.rawValue) error=\(commandBuffer.error?.localizedDescription ?? "nil")"
                )
            }
        }
        print("PURE_METAL_PROGRESS probe=\(probe) phase=completed count=\(commandBuffers.count)")
        return MetalProbeCounts(
            commandBuffersCommitted: commandBuffers.count,
            commandBuffersCompleted: commandBuffers.count
        )
    }

    private func makeComputePipeline(device: MTLDevice) throws -> MTLComputePipelineState {
        let library = try device.makeLibrary(source: metalProbeShaderSource, options: nil)
        guard let function = library.makeFunction(name: "probe_write") else {
            throw MetalProbeFailure(message: "probe_write function unavailable")
        }
        return try device.makeComputePipelineState(function: function)
    }

    private func makeRenderPipeline(device: MTLDevice) throws -> MTLRenderPipelineState {
        let library = try device.makeLibrary(source: metalProbeShaderSource, options: nil)
        guard let vertex = library.makeFunction(name: "probe_vertex"),
              let fragment = library.makeFunction(name: "probe_fragment") else {
            throw MetalProbeFailure(message: "render probe functions unavailable")
        }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        descriptor.colorAttachments[0].pixelFormat = .rgba16Float
        return try device.makeRenderPipelineState(descriptor: descriptor)
    }

    private func makeSampler(device: MTLDevice) throws -> MTLSamplerState {
        let descriptor = MTLSamplerDescriptor()
        descriptor.minFilter = .nearest
        descriptor.magFilter = .nearest
        descriptor.sAddressMode = .clampToEdge
        descriptor.tAddressMode = .clampToEdge
        guard let sampler = device.makeSamplerState(descriptor: descriptor) else {
            throw MetalProbeFailure(message: "could not create shared sampler state")
        }
        return sampler
    }

    private func makeSourceTexture(device: MTLDevice, seed: UInt8) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: 2,
            height: 2,
            mipmapped: false
        )
        descriptor.storageMode = .shared
        descriptor.usage = [.shaderRead]
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw MetalProbeFailure(message: "could not create read-only source texture")
        }
        let pixels: [UInt8] = [
            seed, 0x40, 0x80, 0xff,
            0x20, seed, 0xa0, 0xff,
            0x60, 0xc0, seed, 0xff,
            seed, 0xe0, 0x30, 0xff
        ]
        pixels.withUnsafeBytes { rawBytes in
            guard let baseAddress = rawBytes.baseAddress else { return }
            texture.replace(
                region: MTLRegionMake2D(0, 0, 2, 2),
                mipmapLevel: 0,
                withBytes: baseAddress,
                bytesPerRow: 2 * 4
            )
        }
        return texture
    }

    private func makeRenderTarget(device: MTLDevice) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float,
            width: renderWidth,
            height: renderHeight,
            mipmapped: false
        )
        descriptor.storageMode = .private
        descriptor.usage = [.renderTarget, .shaderRead]
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw MetalProbeFailure(message: "could not create private RGBA16Float render target")
        }
        return texture
    }

    private func makeMultiEncoderResources(
        device: MTLDevice,
        seed: UInt8,
        source: MTLTexture? = nil
    ) throws -> MultiEncoderResources {
        guard let computeOutput = device.makeBuffer(
            length: computeElementCount * MemoryLayout<UInt32>.stride,
            options: .storageModeShared
        ), let readback = device.makeBuffer(
            length: renderWidth * renderHeight * 4 * MemoryLayout<UInt16>.stride,
            options: .storageModeShared
        ) else {
            throw MetalProbeFailure(message: "could not create multi-encoder shared buffers")
        }
        return MultiEncoderResources(
            source: try source ?? makeSourceTexture(device: device, seed: seed),
            renderTarget: try makeRenderTarget(device: device),
            computeOutput: computeOutput,
            readback: readback
        )
    }

    private func encodeCompute(
        commandBuffer: MTLCommandBuffer,
        pipeline: MTLComputePipelineState,
        output: MTLBuffer,
        probe: String
    ) throws {
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw MetalProbeFailure(message: "\(probe): could not create compute encoder")
        }
        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(output, offset: 0, index: 0)
        let threads = MTLSize(width: computeElementCount, height: 1, depth: 1)
        let width = min(computeElementCount, pipeline.maxTotalThreadsPerThreadgroup)
        encoder.dispatchThreads(threads, threadsPerThreadgroup: MTLSize(width: width, height: 1, depth: 1))
        encoder.endEncoding()
        print("PURE_METAL_PROGRESS probe=\(probe) phase=compute-encoded")
    }

    private func encodeRender(
        commandBuffer: MTLCommandBuffer,
        pipeline: MTLRenderPipelineState,
        sampler: MTLSamplerState,
        source: MTLTexture,
        target: MTLTexture,
        probe: String
    ) throws {
        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = target
        descriptor.colorAttachments[0].loadAction = .clear
        descriptor.colorAttachments[0].storeAction = .store
        descriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0.125, green: 0.25, blue: 0.5, alpha: 1.0)
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
            throw MetalProbeFailure(message: "\(probe): could not create render encoder")
        }
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(source, index: 0)
        encoder.setFragmentSamplerState(sampler, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        print("PURE_METAL_PROGRESS probe=\(probe) phase=render-encoded")
    }

    private func encodeBlit(
        commandBuffer: MTLCommandBuffer,
        source: MTLTexture,
        destination: MTLBuffer,
        probe: String
    ) throws {
        guard let encoder = commandBuffer.makeBlitCommandEncoder() else {
            throw MetalProbeFailure(message: "\(probe): could not create blit encoder")
        }
        encoder.copy(
            from: source,
            sourceSlice: 0,
            sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: renderWidth, height: renderHeight, depth: 1),
            to: destination,
            destinationOffset: 0,
            destinationBytesPerRow: renderWidth * 4 * MemoryLayout<UInt16>.stride,
            destinationBytesPerImage: renderWidth * renderHeight * 4 * MemoryLayout<UInt16>.stride
        )
        encoder.endEncoding()
        print("PURE_METAL_PROGRESS probe=\(probe) phase=blit-encoded")
    }

    private func encodeComputeRenderBlit(
        commandBuffer: MTLCommandBuffer,
        computePipeline: MTLComputePipelineState,
        renderPipeline: MTLRenderPipelineState,
        sampler: MTLSamplerState,
        resources: MultiEncoderResources,
        probe: String
    ) throws {
        try encodeCompute(
            commandBuffer: commandBuffer,
            pipeline: computePipeline,
            output: resources.computeOutput,
            probe: probe
        )
        try encodeRender(
            commandBuffer: commandBuffer,
            pipeline: renderPipeline,
            sampler: sampler,
            source: resources.source,
            target: resources.renderTarget,
            probe: probe
        )
        try encodeBlit(
            commandBuffer: commandBuffer,
            source: resources.renderTarget,
            destination: resources.readback,
            probe: probe
        )
    }

    private func verify(buffer: MTLBuffer, equals expected: UInt8, probe: String) throws {
        let bytes = buffer.contents().assumingMemoryBound(to: UInt8.self)
        for index in 0..<buffer.length {
            guard bytes[index] == expected else {
                throw MetalProbeFailure(message: "\(probe): byte \(index) was \(bytes[index]), expected \(expected)")
            }
        }
    }

    private func verifyComputeOutput(_ buffer: MTLBuffer, probe: String) throws {
        let values = buffer.contents().assumingMemoryBound(to: UInt32.self)
        for index in 0..<computeElementCount {
            guard values[index] == UInt32(index + 1) else {
                throw MetalProbeFailure(
                    message: "\(probe): output[\(index)] was \(values[index]), expected \(index + 1)"
                )
            }
        }
    }

    private func verifyReadback(_ buffer: MTLBuffer, probe: String) throws {
        let values = buffer.contents().assumingMemoryBound(to: UInt16.self)
        let componentCount = renderWidth * renderHeight * 4
        var hasNonZeroValue = false
        for index in 0..<componentCount where values[index] != 0 {
            hasNonZeroValue = true
            break
        }
        guard hasNonZeroValue else {
            throw MetalProbeFailure(message: "\(probe): render readback was all zero")
        }
    }

    private func encodeJSON<T: Encodable>(_ value: T) -> String {
        guard let data = try? JSONEncoder().encode(value) else {
            return "{\"status\":\"FAIL\",\"error\":\"JSON encoding failed\"}"
        }
        return String(decoding: data, as: UTF8.self)
    }
}
