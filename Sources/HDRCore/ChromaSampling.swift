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
            // DV420 alternates chroma field phase. A single progressive
            // texture has no field selector, so use the documented left and
            // vertically centered geometry and keep the exact source label in
            // diagnostics.
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
