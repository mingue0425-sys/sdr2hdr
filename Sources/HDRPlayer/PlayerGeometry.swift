import CoreGraphics
import Foundation

public struct AspectFitGeometry: Equatable, Sendable {
    public let destinationRect: CGRect
    public let normalizedRect: CGRect

    public init(sourceSize: CGSize, drawableSize: CGSize) {
        guard sourceSize.width > 0, sourceSize.height > 0,
              drawableSize.width > 0, drawableSize.height > 0 else {
            self.destinationRect = .zero
            self.normalizedRect = .zero
            return
        }
        let scale = min(drawableSize.width / sourceSize.width, drawableSize.height / sourceSize.height)
        let size = CGSize(width: sourceSize.width * scale, height: sourceSize.height * scale)
        let origin = CGPoint(
            x: (drawableSize.width - size.width) * 0.5,
            y: (drawableSize.height - size.height) * 0.5
        )
        let rect = CGRect(origin: origin, size: size)
        self.destinationRect = rect
        self.normalizedRect = CGRect(
            x: rect.minX / drawableSize.width,
            y: rect.minY / drawableSize.height,
            width: rect.width / drawableSize.width,
            height: rect.height / drawableSize.height
        )
    }
}

public enum VideoOrientation: UInt32, Sendable {
    case identity = 0
    case rotate90 = 1
    case rotate180 = 2
    case rotate270 = 3

    public var swapsDimensions: Bool {
        self == .rotate90 || self == .rotate270
    }

    public func displaySize(for encodedSize: CGSize) -> CGSize {
        swapsDimensions ? CGSize(width: encodedSize.height, height: encodedSize.width) : encodedSize
    }
}

public enum VideoTransformResolver {
    public static func orientation(for transform: CGAffineTransform) -> VideoOrientation {
        let epsilon = CGFloat(0.01)
        if abs(transform.a) < epsilon && abs(transform.d) < epsilon {
            return transform.b >= 0 ? .rotate90 : .rotate270
        }
        if transform.a < 0 && transform.d < 0 {
            return .rotate180
        }
        return .identity
    }
}
