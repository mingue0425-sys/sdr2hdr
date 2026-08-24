import CoreMedia

public enum FrameSelectionDecision: Equatable, Sendable {
    case process
    case reuse
    case lateDrop
}

public struct FrameTimestampSelector: Sendable {
    public var lastProcessedTime: CMTime?
    public var lateTolerance: CMTime

    public init(lateTolerance: CMTime = CMTime(value: 1, timescale: 120)) {
        self.lastProcessedTime = nil
        self.lateTolerance = lateTolerance
    }

    public mutating func decide(
        frameTime: CMTime,
        targetTime: CMTime,
        dropIfLate: Bool = false
    ) -> FrameSelectionDecision {
        guard frameTime.isNumeric else { return .reuse }
        if let lastProcessedTime, CMTimeCompare(frameTime, lastProcessedTime) <= 0 {
            return .reuse
        }
        if dropIfLate, targetTime.isNumeric,
           CMTimeCompare(frameTime, targetTime - lateTolerance) < 0 {
            return .lateDrop
        }
        lastProcessedTime = frameTime
        return .process
    }

    public mutating func reset() {
        lastProcessedTime = nil
    }
}
