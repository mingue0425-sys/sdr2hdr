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

public struct VideoOrientation: RawRepresentable, Equatable, Sendable {
    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    public static let identity = VideoOrientation(rawValue: 0)
    public static let rotate90 = VideoOrientation(rawValue: 1)
    public static let rotate180 = VideoOrientation(rawValue: 2)
    public static let rotate270 = VideoOrientation(rawValue: 3)
    public static let mirrorX = VideoOrientation(rawValue: 4)
    public static let mirrorY = VideoOrientation(rawValue: 8)
    public static let rotate90MirrorX = VideoOrientation(rawValue: 5)
    public static let rotate90MirrorY = VideoOrientation(rawValue: 9)
    public static let rotate180MirrorX = VideoOrientation(rawValue: 6)
    public static let rotate180MirrorY = VideoOrientation(rawValue: 10)
    public static let rotate270MirrorX = VideoOrientation(rawValue: 7)
    public static let rotate270MirrorY = VideoOrientation(rawValue: 11)

    public var rotation: UInt32 { rawValue & 3 }
    public var mirroredX: Bool { rawValue & 4 != 0 }
    public var mirroredY: Bool { rawValue & 8 != 0 }

    public var swapsDimensions: Bool {
        rotation == 1 || rotation == 3
    }

    public func displaySize(for encodedSize: CGSize) -> CGSize {
        swapsDimensions ? CGSize(width: encodedSize.height, height: encodedSize.width) : encodedSize
    }

    /// Maps a display-space top-left normalized point to the encoded source
    /// texture space used by the presentation shader.
    public func sourcePoint(forDisplayPoint point: CGPoint) -> CGPoint {
        var value = CGPoint(x: point.x, y: point.y)
        if mirroredX { value.x = 1 - value.x }
        if mirroredY { value.y = 1 - value.y }
        switch rotation {
        case 1: return CGPoint(x: value.y, y: 1 - value.x)
        case 2: return CGPoint(x: 1 - value.x, y: 1 - value.y)
        case 3: return CGPoint(x: 1 - value.y, y: value.x)
        default: return value
        }
    }
}

public enum VideoTransformResolver {
    public static func orientation(for transform: CGAffineTransform) -> VideoOrientation {
        let epsilon = CGFloat(0.01)
        let candidates: [(VideoOrientation, CGAffineTransform)] = [
            (.identity, CGAffineTransform(a: 1, b: 0, c: 0, d: 1, tx: 0, ty: 0)),
            (.rotate90, CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 0, ty: 0)),
            (.rotate180, CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: 0, ty: 0)),
            (.rotate270, CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: 0)),
            (.mirrorX, CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: 0, ty: 0)),
            (.mirrorY, CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: 0)),
            (.rotate90MirrorX, CGAffineTransform(a: 0, b: 1, c: 1, d: 0, tx: 0, ty: 0)),
            (.rotate90MirrorY, CGAffineTransform(a: 0, b: -1, c: -1, d: 0, tx: 0, ty: 0)),
            (.rotate180MirrorX, CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: 0)),
            (.rotate180MirrorY, CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: 0, ty: 0)),
            (.rotate270MirrorX, CGAffineTransform(a: 0, b: -1, c: -1, d: 0, tx: 0, ty: 0)),
            (.rotate270MirrorY, CGAffineTransform(a: 0, b: 1, c: 1, d: 0, tx: 0, ty: 0))
        ]
        return candidates.first {
            abs(transform.a - $0.1.a) < epsilon &&
                abs(transform.b - $0.1.b) < epsilon &&
                abs(transform.c - $0.1.c) < epsilon &&
                abs(transform.d - $0.1.d) < epsilon
        }?.0 ?? .identity
    }
}

/// Token gate for asynchronous AVPlayer seek completions. A late completion
/// must not clear or redraw the frame selected by a newer seek.
public struct PlaybackSeekRedrawGate: Sendable {
    public private(set) var generation: UInt64 = 0

    public init() {}

    public mutating func begin() -> UInt64 {
        generation &+= 1
        return generation
    }

    public func accepts(completionFor token: UInt64) -> Bool {
        token == generation
    }
}

/// Deterministic orchestration state for AVPlayer seek completion handling.
/// The AVFoundation wrapper supplies the asynchronous seek result; this value
/// decides whether that result is still current and whether it may request one
/// redraw of the newly selected frame.
public struct PlaybackSeekRedrawAction: Equatable, Sendable {
    public let generation: UInt64
    public let requestMediaDataChange: Bool
    public let requestRedraw: Bool
    public let resumePlayback: Bool

    public init(
        generation: UInt64,
        requestMediaDataChange: Bool,
        requestRedraw: Bool,
        resumePlayback: Bool
    ) {
        self.generation = generation
        self.requestMediaDataChange = requestMediaDataChange
        self.requestRedraw = requestRedraw
        self.resumePlayback = resumePlayback
    }
}

public struct PlaybackSeekRedrawCoordinator: Sendable {
    private var gate = PlaybackSeekRedrawGate()
    private var pendingGeneration: UInt64?
    private var pendingWasPlaying = false

    public init() {}

    public var generation: UInt64 { gate.generation }

    public mutating func begin(wasPlaying: Bool) -> UInt64 {
        let token = gate.begin()
        pendingGeneration = token
        pendingWasPlaying = wasPlaying
        return token
    }

    /// Returns exactly one redraw action for the latest successful seek. A
    /// late completion, a failed seek, and a duplicate callback return nil.
    public mutating func complete(token: UInt64, succeeded: Bool) -> PlaybackSeekRedrawAction? {
        guard gate.accepts(completionFor: token), pendingGeneration == token else { return nil }
        guard succeeded else {
            pendingGeneration = nil
            pendingWasPlaying = false
            return nil
        }
        pendingGeneration = nil
        return PlaybackSeekRedrawAction(
            generation: token,
            requestMediaDataChange: true,
            requestRedraw: true,
            resumePlayback: pendingWasPlaying
        )
    }

    /// Invalidates any pending seek when AVPlayerItemVideoOutput flushes or a
    /// stream is otherwise discontinuous.
    public mutating func invalidate() {
        _ = gate.begin()
        pendingGeneration = nil
        pendingWasPlaying = false
    }
}
