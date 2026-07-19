import Foundation
import XKit

/// Standard JUnit XML (`<testsuites>`/`<testsuite>`/`<testcase>`) -- the same shape `xcodebuild`
/// and virtually every CI system consume, so no schema is invented here.
enum JUnitReporter {
    static func write(_ report: TestReport, to url: URL) throws {
        var xml = #"<?xml version="1.0" encoding="UTF-8"?>"# + "\n"
        xml += #"<testsuites tests="\#(report.passCount + report.failCount)" failures="\#(report.failCount)">"# + "\n"
        for (index, run) in report.runs.enumerated() {
            let suiteName = escape("\(run.testBundleName) - \(run.deviceName) (run \(index + 1))")
            xml += "  <testsuite name=\"\(suiteName)\" tests=\"\(run.testCases.count)\" "
                + "failures=\"\(run.failCount)\" time=\"\(String(format: "%.3f", run.duration))\" "
                + "timestamp=\"\(iso8601(run.startedAt))\">\n"
            for testCase in run.testCases {
                xml += "    <testcase classname=\"\(escape(testCase.testClass))\" "
                    + "name=\"\(escape(testCase.testMethod))\" "
                    + "time=\"\(String(format: "%.3f", testCase.duration))\""
                if testCase.status == .failed {
                    let message = testCase.failureMessages.first ?? "Test failed"
                    xml += ">\n      <failure message=\"\(escape(message))\">"
                    xml += escape(testCase.failureMessages.joined(separator: "\n"))
                    xml += "</failure>\n    </testcase>\n"
                } else {
                    xml += " />\n"
                }
            }
            if let error = run.infrastructureError {
                xml += "    <system-err>\(escape(error))</system-err>\n"
            }
            xml += "  </testsuite>\n"
        }
        xml += "</testsuites>\n"
        try xml.write(to: url, atomically: true, encoding: .utf8)
    }

    private static func escape(_ string: String) -> String {
        string
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        return formatter.string(from: date)
    }
}
