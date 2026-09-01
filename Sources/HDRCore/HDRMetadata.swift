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

/// A GPU-owned frame. The texture remains exclusively leased while any copy
/// of this value is retained and at least until its producing command buffer
/// completes. Callers must not read it from the CPU on the realtime path.
public struct HDRFrame {
    public let texture: MTLTexture
    public let sourceTimestamp: CMTime?
    public let peakNits: Float
    public let paperWhiteNits: Float
    public let metadata: HDRFrameMetadata
    // Shared reference lifetime for the processor's pooled texture. Keeping it
    // internal prevents callers from forging or prematurely releasing leases.
    internal let leaseLifetime: AnyObject

    internal init(
        texture: MTLTexture,
        sourceTimestamp: CMTime?,
        configuration: HDRConfiguration,
        leaseLifetime: AnyObject
    ) {
        self.texture = texture
        self.sourceTimestamp = sourceTimestamp
        self.peakNits = configuration.peakNits
        self.paperWhiteNits = configuration.paperWhiteNits
        self.leaseLifetime = leaseLifetime
        self.metadata = HDRFrameMetadata(
            outputMode: configuration.outputMode,
            peakNits: configuration.peakNits,
            paperWhiteNits: configuration.paperWhiteNits,
            masteringHeadroom: configuration.masteringHeadroom
        )
    }
}
