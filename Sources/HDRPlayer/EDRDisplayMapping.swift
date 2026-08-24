import Foundation
import simd

/// Runtime-only display state. It is deliberately separate from
/// HDRConfiguration, whose headroom describes mastering intent.
public struct HDRDisplayState: Equatable, Sendable {
    public var currentEDRHeadroom: Float
    public var potentialEDRHeadroom: Float

    public init(currentEDRHeadroom: Float, potentialEDRHeadroom: Float) {
        self.currentEDRHeadroom = Self.sanitize(currentEDRHeadroom)
        self.potentialEDRHeadroom = Self.sanitize(potentialEDRHeadroom)
    }

    public static let sdr = HDRDisplayState(currentEDRHeadroom: 1, potentialEDRHeadroom: 1)

    public var usableHeadroom: Float {
        min(max(currentEDRHeadroom, 1), max(potentialEDRHeadroom, 1))
    }

    private static func sanitize(_ value: Float) -> Float {
        value.isFinite ? min(max(value, 1), 64) : 1
    }
}

/// Scalar form of the presentation shader's direct-EDR shoulder. Values up to
/// reference white are unchanged. For M>D>1, x above reference white follows
/// x/(1+a*x), where a=1/(D-1)-1/(M-1). This has unit slope at the knee, maps M
/// exactly to D, and remains continuous and strictly monotonic before M.
public enum EDRDisplayMapper {
    public static func mapLuminance(
        _ luminance: Float,
        masteringHeadroom: Float,
        displayHeadroom: Float
    ) -> Float {
        guard luminance.isFinite else { return 0 }
        let y = max(luminance, 0)
        let mastering = max(masteringHeadroom.isFinite ? masteringHeadroom : 1, 1)
        let display = min(max(displayHeadroom.isFinite ? displayHeadroom : 1, 1), mastering)
        guard y > 1 else { return y }
        guard display > 1 else { return 1 }
        let bounded = min(y, mastering)
        guard display < mastering - 0.000_001 else { return bounded }
        let sourceRange = mastering - 1
        let destinationRange = display - 1
        let x = bounded - 1
        let curvature = 1 / destinationRange - 1 / sourceRange
        return min(1 + x / max(1 + curvature * x, 0.000_001), display)
    }
}

/// Time-based smoothing for changes in NSScreen current EDR. Content temporal
/// adaptation remains inside HDRProcessor and is intentionally independent.
public struct EDRHeadroomSmoother: Sendable {
    public private(set) var value: Float
    public private(set) var target: Float
    public var timeConstantSeconds: Double
    private var lastTimestamp: Double?

    public init(initial: Float = 1, timeConstantSeconds: Double = 0.18) {
        let safe = initial.isFinite ? min(max(initial, 1), 64) : 1
        self.value = safe
        self.target = safe
        self.timeConstantSeconds = max(timeConstantSeconds, 0.001)
    }

    public mutating func setTarget(_ newTarget: Float) {
        target = newTarget.isFinite ? min(max(newTarget, 1), 64) : 1
    }

    public mutating func step(timestamp: Double) -> Float {
        guard timestamp.isFinite else { return value }
        guard let previous = lastTimestamp else {
            lastTimestamp = timestamp
            value = target
            return value
        }
        let delta = min(max(timestamp - previous, 0), 1)
        lastTimestamp = timestamp
        let alpha = Float(1 - exp(-delta / timeConstantSeconds))
        value += alpha * (target - value)
        return value
    }
}
