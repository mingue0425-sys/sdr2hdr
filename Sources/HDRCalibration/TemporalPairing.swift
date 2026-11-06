import Foundation

/// Position-wise SDR/HDR temporal window pairing.
///
/// Window frames are paired by sequence position after the alignment offset
/// has been applied to the HDR start. Position `i` is a valid pair only while
/// both frames are the same elapsed time from their window's first frame,
/// within half of the longer typical frame interval. The first mismatch ends
/// the paired prefix. A cadence mismatch or a one-sided VFR gap therefore
/// shortens the window (and may reject it) instead of silently comparing
/// different moments.
enum V6TemporalPairing {
    static let policy = "pts-paired-prefix-half-frame-v1"

    static func pairedPrefixCount(sdrSeconds: [Double], hdrSeconds: [Double]) -> Int {
        let count = min(sdrSeconds.count, hdrSeconds.count)
        guard count > 0 else { return 0 }
        guard sdrSeconds[0].isFinite, hdrSeconds[0].isFinite else { return 0 }
        guard count > 1 else { return 1 }
        let interval = max(
            typicalInterval(Array(sdrSeconds.prefix(count))),
            typicalInterval(Array(hdrSeconds.prefix(count)))
        )
        guard interval.isFinite, interval > 0 else { return 1 }
        let tolerance = interval * 0.5
        for index in 1..<count {
            let sdrElapsed = sdrSeconds[index] - sdrSeconds[0]
            let hdrElapsed = hdrSeconds[index] - hdrSeconds[0]
            guard sdrElapsed.isFinite, hdrElapsed.isFinite,
                  abs(sdrElapsed - hdrElapsed) <= tolerance else {
                return index
            }
        }
        return count
    }

    /// Median positive interval; robust to a single VFR gap.
    private static func typicalInterval(_ seconds: [Double]) -> Double {
        let intervals = zip(seconds.dropFirst(), seconds)
            .map { $0 - $1 }
            .filter { $0.isFinite && $0 > 0 }
            .sorted()
        guard !intervals.isEmpty else { return .nan }
        return intervals[intervals.count / 2]
    }

    static func pairedPrefixCount(sdr: FrameSequence, hdr: FrameSequence) -> Int {
        pairedPrefixCount(
            sdrSeconds: sdr.samples.map(\.descriptor.timestampSeconds),
            hdrSeconds: hdr.samples.map(\.descriptor.timestampSeconds)
        )
    }
}

/// Order in which a scene's alignment matches are tried as temporal-window
/// anchors.
///
/// The first element is the historical anchor: the highest-confidence match,
/// and the earliest of any tie, exactly as `max(by:)` picked it. The rest
/// follow by descending confidence (ties keep match order) and are tried only
/// when a pair would otherwise have no temporal window.
enum V6TemporalAnchorOrder {
    static let fallbackAttempts = 4

    static func ranked(_ matches: [MatchedFrame]) -> [MatchedFrame] {
        matches.enumerated()
            .sorted { lhs, rhs in
                lhs.element.confidence != rhs.element.confidence
                    ? lhs.element.confidence > rhs.element.confidence
                    : lhs.offset < rhs.offset
            }
            .map(\.element)
    }
}
