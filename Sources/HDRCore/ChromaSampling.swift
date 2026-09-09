import CoreVideo

/// Describes the location of a 4:2:0 chroma sample relative to the luma
/// samples in one 2x2 luma block. The values mirror the CoreVideo attachment
/// constants, while `unspecified` represents absent or unusable metadata.
public enum HDRChromaSiting: String, CaseIterable, Codable, Sendable {
    case center
    case left
    case topLeft
    case top
    case bottomLeft
    case bottom
    case dv420
    case unspecified
}

public enum HDRChromaReconstructionFallbackReason: String, Codable, Equatable, Sendable {
    /// DV420 can carry component-specific and field-dependent phase. The
    /// current progressive texture path cannot represent that information
    /// with one shared bilinear sample center.
    case dv420RequiresComponentSpecificPhase
}

public struct HDRChromaReconstructionDecision: Codable, Equatable, Sendable {
    public let requested: HDRChromaReconstructionMode
    public let effective: HDRChromaReconstructionMode
    public let siting: HDRChromaSiting
    public let fallbackReason: HDRChromaReconstructionFallbackReason?

    public var fallbackUsed: Bool {
        fallbackReason != nil
    }

    public init(
        requested: HDRChromaReconstructionMode,
        effective: HDRChromaReconstructionMode,
        siting: HDRChromaSiting,
        fallbackReason: HDRChromaReconstructionFallbackReason? = nil
    ) {
        self.requested = requested
        self.effective = effective
        self.siting = siting
        self.fallbackReason = fallbackReason
    }
}

public extension HDRChromaReconstructionMode {
    var diagnosticName: String {
        switch self {
        case .nearest:
            return "nearest"
        case .sitingAwareBilinear:
            return "siting-aware-bilinear"
        }
    }
}

public enum HDRChromaReconstructionResolver {
    /// Resolves the requested mode before it reaches Metal. The geometry
    /// resolver intentionally continues to preserve the source siting label;
    /// this decision only determines whether the current reconstruction
    /// implementation can safely consume that geometry.
    public static func resolve(
        requested: HDRChromaReconstructionMode,
        siting: HDRChromaSiting
    ) -> HDRChromaReconstructionDecision {
        guard requested == .sitingAwareBilinear, siting == .dv420 else {
            return HDRChromaReconstructionDecision(
                requested: requested,
                effective: requested,
                siting: siting
            )
        }

        return HDRChromaReconstructionDecision(
            requested: requested,
            effective: .nearest,
            siting: siting,
            fallbackReason: .dv420RequiresComponentSpecificPhase
        )
    }
}

/// Geometry passed to the Metal input path. `sampleCenterX/Y` are expressed in
/// luma sample-edge coordinates for the first 2x2 block. For example, a
/// centered sample is at (1, 1), while a left co-sited sample is at (0.5, 1).
internal struct HDRChromaSamplingGeometry: Equatable, Sendable {
    let resolvedSiting: HDRChromaSiting
    let sampleCenterX: Float
    let sampleCenterY: Float
    let metadataDescription: String
    let metadataWasExplicit: Bool

    static let defaultCenter = HDRChromaSamplingGeometry(
        resolvedSiting: .center,
        sampleCenterX: 1,
        sampleCenterY: 1,
        metadataDescription: "unspecified(default=center)",
        metadataWasExplicit: false
    )
}

internal enum HDRChromaSamplingGeometryResolver {
    static func resolve(pixelBuffer: CVPixelBuffer) -> HDRChromaSamplingGeometry {
        let top = parse(
            CVBufferCopyAttachment(pixelBuffer, kCVImageBufferChromaLocationTopFieldKey, nil)
        )
        let bottom = parse(
            CVBufferCopyAttachment(pixelBuffer, kCVImageBufferChromaLocationBottomFieldKey, nil)
        )

        switch (top, bottom) {
        case (nil, nil):
            return .defaultCenter
        case let (top?, bottom?) where top == bottom:
            return geometry(for: top, metadataDescription: top.rawValue)
        case let (top?, bottom?):
            return HDRChromaSamplingGeometry(
                resolvedSiting: .center,
                sampleCenterX: 1,
                sampleCenterY: 1,
                metadataDescription: "mixed(top=\(top.rawValue),bottom=\(bottom.rawValue); default=center)",
                metadataWasExplicit: false
            )
        case let (location?, nil), let (nil, location?):
            return geometry(for: location, metadataDescription: location.rawValue)
        }
    }

    private static func parse(_ value: CFTypeRef?) -> HDRChromaSiting? {
        guard let value else { return nil }
        if CFEqual(value, kCVImageBufferChromaLocation_Center) { return .center }
        if CFEqual(value, kCVImageBufferChromaLocation_Left) { return .left }
        if CFEqual(value, kCVImageBufferChromaLocation_TopLeft) { return .topLeft }
        if CFEqual(value, kCVImageBufferChromaLocation_Top) { return .top }
        if CFEqual(value, kCVImageBufferChromaLocation_BottomLeft) { return .bottomLeft }
        if CFEqual(value, kCVImageBufferChromaLocation_Bottom) { return .bottom }
        if CFEqual(value, kCVImageBufferChromaLocation_DV420) { return .dv420 }
        return nil
    }

    private static func geometry(
        for siting: HDRChromaSiting,
        metadataDescription: String
    ) -> HDRChromaSamplingGeometry {
        let center: (Float, Float)
        switch siting {
        case .center:
            center = (1, 1)
        case .left:
            center = (0.5, 1)
        case .topLeft:
            center = (0.5, 0.5)
        case .top:
            center = (1, 0.5)
        case .bottomLeft:
            center = (0.5, 1.5)
        case .bottom:
            center = (1, 1.5)
        case .dv420:
            // Retain a deterministic geometry for diagnostics and for the
            // legacy nearest path. HDRChromaReconstructionResolver prevents
            // this provisional shared center from being used by the current
            // siting-aware bilinear implementation.
            center = (0.5, 1)
        case .unspecified:
            return .defaultCenter
        }
        return HDRChromaSamplingGeometry(
            resolvedSiting: siting,
            sampleCenterX: center.0,
            sampleCenterY: center.1,
            metadataDescription: metadataDescription,
            metadataWasExplicit: true
        )
    }
}
