import Foundation

public enum CalibrationReportWriter {
    public static func writeCSV(_ report: CalibrationReport, to url: URL) throws {
        var rows = [
            "candidate,split,pair,scene,frameCount,tags,alignmentConfidence,luminanceError,highlightError,diffuseWhiteError,shadowError,colorError,temporalError,structureError,clippedRatio,errorFamilies"
        ]
        func append(_ candidate: String, _ metrics: DatasetMetrics?) {
            guard let metrics else { return }
            for scene in metrics.sceneMetrics {
                rows.append([
                    candidate,
                    metrics.split.rawValue,
                    scene.pairID,
                    scene.sceneID,
                    String(scene.frameCount),
                    scene.tags.joined(separator: "+"),
                    String(scene.alignmentConfidence),
                    String(scene.luminanceError),
                    String(scene.highlightError),
                    String(scene.diffuseWhiteError),
                    String(scene.shadowError),
                    String(scene.colorError),
                    String(scene.temporalError),
                    String(scene.structureError),
                    String(scene.clippedRatio),
                    scene.errorFamilies.map(\.rawValue).joined(separator: "+")
                ].map(csvEscape).joined(separator: ","))
            }
        }
        append("BASELINE", report.baseline)
        append("BASELINE_VALIDATION", report.baselineValidation)
        append("BASELINE_FROZEN", report.baselineFrozenTest)
        for candidate in report.candidates {
            append(candidate.id + "_TUNE", candidate.tune)
            append(candidate.id + "_VALIDATION", candidate.validation)
            append(candidate.id + "_FROZEN", candidate.frozen)
        }
        if let selected = report.selectedCandidate {
            append(selected.id + "_SELECTED_VALIDATION", report.validation)
            append(selected.id + "_SELECTED_FROZEN", report.frozenTest)
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try rows.joined(separator: "\n").appending("\n").data(using: .utf8)?.write(to: url)
    }

    public static func writeHTML(_ report: CalibrationReport, to url: URL) throws {
        let baseline = report.baseline.map { String(format: "%.5f", $0.objective) } ?? "NOT_MEASURED"
        let baselineValidation = report.baselineValidation.map { String(format: "%.5f", $0.objective) } ?? "NOT_MEASURED"
        let baselineFrozen = report.baselineFrozenTest.map { String(format: "%.5f", $0.objective) } ?? "NOT_MEASURED"
        let selected = report.selectedCandidate?.tune.map { String(format: "%.5f", $0.objective) } ?? "NOT_MEASURED"
        let html = """
        <!doctype html>
        <html><head><meta charset="utf-8"><title>HDR Calibration \(report.experimentID)</title>
        <style>body{font-family:system-ui;margin:2rem}table{border-collapse:collapse}td,th{border:1px solid #ccc;padding:.4rem}</style></head>
        <body><h1>HDR Calibration \(report.experimentID)</h1>
        <p>Verdict: <strong>\(report.verdict.rawValue)</strong></p>
        <p>Baseline TUNE objective: \(baseline)<br>Baseline VALIDATION objective: \(baselineValidation)<br>Baseline FROZEN objective: \(baselineFrozen)<br>Selected TUNE objective: \(selected)</p>
        <h2>Notes</h2><ul>\(report.notes.map { "<li>\(htmlEscape($0))</li>" }.joined())</ul>
        <h2>Scene metrics</h2>
        <table><tr><th>Candidate</th><th>Split</th><th>Pair</th><th>Scene</th><th>Objective axes</th><th>Errors</th></tr>
        \(sceneRows(report))
        </table></body></html>
        """
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try html.data(using: .utf8)?.write(to: url)
    }

    private static func sceneRows(_ report: CalibrationReport) -> String {
        var rows: [String] = []
        func append(_ label: String, _ metrics: DatasetMetrics?) {
            guard let metrics else { return }
            for scene in metrics.sceneMetrics {
                rows.append("<tr><td>\(htmlEscape(label))</td><td>\(metrics.split.rawValue)</td><td>\(htmlEscape(scene.pairID))</td><td>\(scene.sceneID)</td><td>luma \(format(scene.luminanceError)), highlight \(format(scene.highlightError)), shadow \(format(scene.shadowError))</td><td>\(scene.errorFamilies.map(\.rawValue).joined(separator: ", "))</td></tr>")
            }
        }
        append("BASELINE", report.baseline)
        append("BASELINE_VALIDATION", report.baselineValidation)
        append("BASELINE_FROZEN", report.baselineFrozenTest)
        for candidate in report.candidates { append(candidate.id, candidate.tune) }
        return rows.joined()
    }

    private static func csvEscape(_ value: String) -> String {
        guard value.contains(",") || value.contains("\"") || value.contains("\n") else { return value }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    private static func htmlEscape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func format(_ value: Double) -> String {
        value.isFinite ? String(format: "%.4f", value) : "NaN"
    }
}
