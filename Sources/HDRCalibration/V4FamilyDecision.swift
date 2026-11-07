import Foundation

/// Preregistered candidate-selection and promotion protocols.
///
/// `familyMaximinLOFOV1` responds to the open-content V4 result. In that run
/// the gain shrank from Tune (10.4%) to Validation (5.25%) to Frozen (3.48%),
/// and selecting on a single family regressed others by up to 13%.
///
/// - Every Tune-safe candidate is scored on every Tune and Validation family.
/// - The candidate whose worst family improves most over V2 is selected.
/// - No family may regress beyond a tolerance against V2 or against the
///   default preset.
/// - Before the Virgin Frozen holdout may open, a leave-one-family-out (LOFO)
///   estimate of held-out improvement must clear the preregistered gate.
public enum V4DecisionProtocol: String, Codable, Sendable, CaseIterable {
    case familyMaximinLOFOV1 = "family-maximin-lofo-v1"

    /// A family may not be worse than V2 or the default by more than this ratio.
    public var familyRegressionTolerance: Double { 0.02 }
    /// Minimum mean held-out LOFO improvement over V2 required to open Frozen.
    /// It equals the Frozen promotion gate, so Frozen is only opened when the
    /// honest pre-Frozen estimate already predicts a pass.
    public var minimumMeanHeldOutImprovement: Double { 0.05 }
    /// Every held-out family must improve by more than this.
    public var minimumWorstHeldOutImprovement: Double { 0 }

    public init(manifestValue: String?) throws {
        guard let manifestValue else {
            throw CalibrationError.invalidManifest("decisionProtocol is not set")
        }
        guard let known = V4DecisionProtocol(rawValue: manifestValue) else {
            throw CalibrationError.invalidManifest("unknown decisionProtocol: \(manifestValue)")
        }
        self = known
    }
}

/// Per-family objective of one configuration over Tune and Validation.
public struct V4FamilyScores: Codable, Sendable, Equatable {
    public var id: String
    /// Family-balanced objective per content family (lower is better).
    public var objectiveByFamily: [String: Double]
    /// Passed every pooled (non-family) safety constraint.
    public var safe: Bool

    public init(id: String, objectiveByFamily: [String: Double], safe: Bool) {
        self.id = id
        self.objectiveByFamily = objectiveByFamily
        self.safe = safe
    }
}

public struct V4FamilySelection: Codable, Sendable, Equatable {
    public var candidateID: String
    /// Worst (largest) candidate/V2 objective ratio over the scored families.
    public var worstRatio: Double
    public var meanRatio: Double
}

public struct V4LeaveOneFamilyOutFold: Codable, Sendable, Equatable {
    public var heldOutFamily: String
    public var selectedCandidateID: String?
    /// 1 − candidate/V2 on the held-out family; nil when nothing was eligible.
    public var heldOutImprovementOverV2: Double?
    public var heldOutImprovementOverDefault: Double?
}

public struct V4LeaveOneFamilyOutReport: Codable, Sendable, Equatable {
    public var decisionProtocol: String
    public var folds: [V4LeaveOneFamilyOutFold]
    public var meanHeldOutImprovement: Double?
    public var worstHeldOutImprovement: Double?
    public var status: V4GateStatus
    public var reasons: [String]
}

public enum V4FamilyDecision {
    /// Groups videos by content family and aggregates each family with the
    /// same pair-mean used inside the runner's family balancing.
    public static func objectiveByFamily(
        _ videos: [V2VideoEvaluation],
        familyByID: [String: String]
    ) -> [String: Double] {
        Dictionary(grouping: videos) { familyByID[$0.pairID] ?? "UNCLASSIFIED" }
            .mapValues { V2MetricsEvaluator.aggregate($0.map(\.metrics)).objective }
    }

    /// Selects the eligible candidate with the smallest worst-family ratio to
    /// V2, breaking ties by the mean ratio and then by identifier.
    ///
    /// - Parameter families: families to score; defaults to every V2 family.
    /// - Returns: nil when no candidate is eligible.
    public static func select(
        candidates: [V4FamilyScores],
        v2: [String: Double],
        defaults: [String: Double],
        protocol decision: V4DecisionProtocol,
        families: Set<String>? = nil
    ) -> V4FamilySelection? {
        let scored = families ?? Set(v2.keys)
        guard !scored.isEmpty else { return nil }
        var best: V4FamilySelection?
        for candidate in candidates where candidate.safe {
            guard let ratios = ratios(candidate, v2: v2, defaults: defaults, families: scored, decision: decision) else {
                continue
            }
            let worst = ratios.max() ?? .infinity
            let mean = ratios.reduce(0, +) / Double(ratios.count)
            let entry = V4FamilySelection(candidateID: candidate.id, worstRatio: worst, meanRatio: mean)
            if let current = best {
                if (worst, mean, candidate.id) < (current.worstRatio, current.meanRatio, current.candidateID) {
                    best = entry
                }
            } else {
                best = entry
            }
        }
        return best
    }

    /// Candidate/V2 ratios on `families`, or nil when any family is missing,
    /// non-finite, or regresses beyond tolerance against V2 or the default.
    static func ratios(
        _ candidate: V4FamilyScores,
        v2: [String: Double],
        defaults: [String: Double],
        families: Set<String>,
        decision: V4DecisionProtocol
    ) -> [Double]? {
        var result: [Double] = []
        for family in families.sorted() {
            guard let value = candidate.objectiveByFamily[family], value.isFinite,
                  let baseline = v2[family], baseline.isFinite, baseline > 0,
                  let reference = defaults[family], reference.isFinite, reference > 0 else {
                return nil
            }
            let limit = 1 + decision.familyRegressionTolerance
            guard value <= baseline * limit, value <= reference * limit else { return nil }
            result.append(value / baseline)
        }
        return result
    }

    /// Leave-one-family-out estimate of held-out improvement.
    ///
    /// For each family F, the selection rule is applied using only the other
    /// families. The selected candidate is then scored on F.
    ///
    /// The candidate pool is fixed beforehand. Local-refinement centres used
    /// all of Tune, so Tune families leak slightly through the pool; the
    /// report states this.
    public static func leaveOneFamilyOut(
        candidates: [V4FamilyScores],
        v2: [String: Double],
        defaults: [String: Double],
        protocol decision: V4DecisionProtocol
    ) -> V4LeaveOneFamilyOutReport {
        let families = v2.keys.sorted()
        var folds: [V4LeaveOneFamilyOutFold] = []
        var reasons: [String] = []
        guard families.count >= 2 else {
            return V4LeaveOneFamilyOutReport(
                decisionProtocol: decision.rawValue, folds: [],
                meanHeldOutImprovement: nil, worstHeldOutImprovement: nil,
                status: .fail, reasons: ["leave-one-family-out needs at least two families, found \(families.count)"]
            )
        }
        for heldOut in families {
            let training = Set(families).subtracting([heldOut])
            let selection = select(
                candidates: candidates, v2: v2, defaults: defaults,
                protocol: decision, families: training
            )
            var fold = V4LeaveOneFamilyOutFold(
                heldOutFamily: heldOut, selectedCandidateID: selection?.candidateID,
                heldOutImprovementOverV2: nil, heldOutImprovementOverDefault: nil
            )
            if let id = selection?.candidateID,
               let candidate = candidates.first(where: { $0.id == id }),
               let value = candidate.objectiveByFamily[heldOut] {
                if let baseline = v2[heldOut] {
                    fold.heldOutImprovementOverV2 = V4PromotionMath.improvementRatio(baseline: baseline, candidate: value)
                }
                if let reference = defaults[heldOut] {
                    fold.heldOutImprovementOverDefault = V4PromotionMath.improvementRatio(baseline: reference, candidate: value)
                }
            } else {
                reasons.append("no eligible candidate when \(heldOut) is held out")
            }
            folds.append(fold)
        }
        let improvements = folds.compactMap(\.heldOutImprovementOverV2)
        let complete = improvements.count == folds.count
        let mean = improvements.isEmpty ? nil : improvements.reduce(0, +) / Double(improvements.count)
        let worst = improvements.min()
        var passed = complete
        if let mean, mean < decision.minimumMeanHeldOutImprovement {
            passed = false
            reasons.append(String(format: "mean held-out improvement %.2f%% < %.2f%%", mean * 100, decision.minimumMeanHeldOutImprovement * 100))
        }
        if let worst, worst <= decision.minimumWorstHeldOutImprovement {
            passed = false
            reasons.append(String(format: "worst held-out improvement %.2f%% is not positive", worst * 100))
        }
        for fold in folds {
            if let overDefault = fold.heldOutImprovementOverDefault, overDefault < -decision.familyRegressionTolerance {
                passed = false
                reasons.append(String(format: "held-out %@ is %.2f%% worse than the default", fold.heldOutFamily, -overDefault * 100))
            }
        }
        reasons.append("candidate pool is fixed before folding; local-refinement centres used all Tune families")
        return V4LeaveOneFamilyOutReport(
            decisionProtocol: decision.rawValue, folds: folds,
            meanHeldOutImprovement: mean, worstHeldOutImprovement: worst,
            status: passed ? .pass : .fail, reasons: reasons
        )
    }

    /// Frozen family gate: every Virgin Frozen family within tolerance of
    /// both V2 and the default.
    public static func frozenFamiliesWithinTolerance(
        candidate: [String: Double],
        v2: [String: Double],
        defaults: [String: Double],
        protocol decision: V4DecisionProtocol
    ) -> Bool {
        guard !candidate.isEmpty, Set(candidate.keys) == Set(v2.keys), Set(candidate.keys) == Set(defaults.keys) else {
            return false
        }
        let scores = V4FamilyScores(id: "frozen", objectiveByFamily: candidate, safe: true)
        return ratios(scores, v2: v2, defaults: defaults, families: Set(candidate.keys), decision: decision) != nil
    }
}
