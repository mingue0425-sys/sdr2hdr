import CoreMedia
import Foundation
import Metal

public struct HDRFrameMetadata: Equatable, Sendable {
    public let outputMode: HDROutputMode
    public let outputPrimaries: String
    public let peakNits: Float
    public let paperWhiteNits: Float
    public let masteringHeadroom: Float

    @available(*, deprecated, renamed: "masteringHeadroom")
    public var displayHeadroom: Float { masteringHeadroom }

    public init(
        outputMode: HDROutputMode,
        outputPrimaries: String = "BT.2020",
        peakNits: Float,
        paperWhiteNits: Float,
        masteringHeadroom: Float
    ) {
        self.outputMode = outputMode
        self.outputPrimaries = outputPrimaries
        self.peakNits = peakNits
        self.paperWhiteNits = paperWhiteNits
        self.masteringHeadroom = masteringHeadroom
    }
}

/// A GPU-owned frame. The texture remains valid until the command buffer that
/// produced it completes; the processor retains the backing pool lease until
/// then. Callers must not read it from the CPU on the realtime path.
public struct HDRFrame {
    public let texture: MTLTexture
    public let sourceTimestamp: CMTime?
    public let peakNits: Float
    public let paperWhiteNits: Float
    public let metadata: HDRFrameMetadata

    internal init(
        texture: MTLTexture,
        sourceTimestamp: CMTime?,
        configuration: HDRConfiguration
    ) {
        self.texture = texture
        self.sourceTimestamp = sourceTimestamp
        self.peakNits = configuration.peakNits
        self.paperWhiteNits = configuration.paperWhiteNits
        self.metadata = HDRFrameMetadata(
            outputMode: configuration.outputMode,
            peakNits: configuration.peakNits,
            paperWhiteNits: configuration.paperWhiteNits,
            masteringHeadroom: configuration.masteringHeadroom
        )
    }
}
