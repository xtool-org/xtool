import Foundation
import XKit

/// Simple, dependency-free HTML report -- optional per the plan, so kept minimal: one page,
/// inline CSS, no JS. Screenshot/syslog artifacts are referenced by their relative path (written
/// alongside the report directory), not embedded, so the report stays small even with many
/// failures.
enum HTMLReporter {
    static func write(_ report: TestReport, to url: URL) throws {
        var html = """
        <!doctype html>
        <html><head><meta charset="utf-8"><title>xtool test report</title><style>
        body { font-family: -apple-system, Helvetica, Arial, sans-serif; margin: 2rem; color: #1a1a1a; }
        h1 { font-size: 1.4rem; }
        .summary { margin-bottom: 1.5rem; }
        .pass { color: #1a7f37; }
        .fail { color: #cf222e; }
        table { border-collapse: collapse; width: 100%; margin-bottom: 2rem; }
        th, td { text-align: left; padding: 0.4rem 0.8rem; border-bottom: 1px solid #e2e2e2; font-size: 0.9rem; }
        th { background: #f6f8fa; }
        .failure-message { white-space: pre-wrap; font-family: ui-monospace, monospace; font-size: 0.8rem; color: #cf222e; }
        img.screenshot { max-width: 240px; display: block; margin-top: 0.4rem; }
        </style></head><body>
        """
        html += "<h1>xtool test report</h1>\n"
        html += "<div class=\"summary\"><strong class=\"pass\">\(report.passCount) passed</strong>, "
            + "<strong class=\"fail\">\(report.failCount) failed</strong> across \(report.runs.count) run(s)</div>\n"

        for (index, run) in report.runs.enumerated() {
            html += "<h2>Run \(index + 1): \(escape(run.deviceName)) (iOS \(escape(run.productVersion)))</h2>\n"
            if let error = run.infrastructureError {
                html += "<p class=\"fail\">Infrastructure error: \(escape(error))</p>\n"
            }
            html += "<table><tr><th>Test</th><th>Status</th><th>Duration</th><th>Details</th></tr>\n"
            for testCase in run.testCases {
                let statusClass = testCase.status == .passed ? "pass" : "fail"
                html += "<tr><td>\(escape(testCase.identifier))</td>"
                html += "<td class=\"\(statusClass)\">\(testCase.status.rawValue)</td>"
                html += "<td>\(String(format: "%.3f", testCase.duration))s</td><td>"
                if !testCase.failureMessages.isEmpty {
                    html += "<div class=\"failure-message\">\(escape(testCase.failureMessages.joined(separator: "\n")))</div>"
                }
                if let screenshotPath = testCase.screenshotPath {
                    html += "<img class=\"screenshot\" src=\"\(escape(screenshotPath))\">"
                }
                html += "</td></tr>\n"
            }
            html += "</table>\n"
            if let syslogPath = run.syslogPath {
                html += "<p><a href=\"\(escape(syslogPath))\">Device syslog for this run</a></p>\n"
            }
        }

        html += "</body></html>\n"
        try html.write(to: url, atomically: true, encoding: .utf8)
    }

    private static func escape(_ string: String) -> String {
        string
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
