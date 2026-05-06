import Foundation

/// Reverse-DNS identifiers Apple's AppIntents pipeline writes into
/// `extract.actionsdata.actions[*].systemProtocols` /
/// `systemProtocolMetadata` / `systemProtocolMetadataV2`.
///
/// Each Swift conformance protocol on an `AppIntent` translates to zero or
/// more `com.apple.link.systemProtocol.*` strings. The mapping is internal
/// to Apple and not documented; values below were captured by inspecting
/// shipping iOS apps. When auditing a new reference IPA, extend this table
/// rather than hardcoding inline in the emitter.
///
/// Confirmed entries (from Wispr Flow 1.55):
///   * `AudioRecordingIntent` →
///       `com.apple.link.systemProtocol.AudioRecording`,
///       `com.apple.link.systemProtocol.SessionStarting`
///   * `AppIntent` (plain) → no entries
///
/// Best-guess entries (added without IPA confirmation, kept conservative —
/// a wrong entry can cause Shortcuts to reject the metadata, while a missing
/// one merely degrades indexing). Validate against a real IPA before relying
/// on these for production:
///   * `LiveActivityIntent`
///       → `com.apple.link.systemProtocol.LiveActivity`
///   * `WidgetConfigurationIntent`
///       → `com.apple.link.systemProtocol.WidgetConfiguration`
///   * `OpenIntent`
///       → `com.apple.link.systemProtocol.OpenApp`
///   * `ForegroundContinuableIntent`
///       → `com.apple.link.systemProtocol.ForegroundContinuable`
public enum SystemProtocols {

    private static let confirmed: [String: [String]] = [
        "AudioRecordingIntent": [
            "com.apple.link.systemProtocol.SessionStarting",
            "com.apple.link.systemProtocol.AudioRecording",
        ],
    ]

    private static let provisional: [String: [String]] = [
        "LiveActivityIntent": [
            "com.apple.link.systemProtocol.LiveActivity",
        ],
        "WidgetConfigurationIntent": [
            "com.apple.link.systemProtocol.WidgetConfiguration",
        ],
        "OpenIntent": [
            "com.apple.link.systemProtocol.OpenApp",
        ],
        "ForegroundContinuableIntent": [
            "com.apple.link.systemProtocol.ForegroundContinuable",
        ],
    ]

    /// Returns the de-duplicated reverse-DNS list for the given Swift
    /// conformance names. Order is stable: confirmed first, then provisional,
    /// preserving the order in which protocol names appear on the type.
    public static func resolve(for protocolNames: [String]) -> [String] {
        var seen: Set<String> = []
        var ordered: [String] = []
        for name in protocolNames {
            // Strip module qualifier (e.g. `AppIntents.AudioRecordingIntent`).
            let bare = name.split(separator: ".").last.map(String.init) ?? name
            let entries = (confirmed[bare] ?? []) + (provisional[bare] ?? [])
            for entry in entries where !seen.contains(entry) {
                seen.insert(entry)
                ordered.append(entry)
            }
        }
        return ordered
    }

    /// Returns the V2 metadata payload Apple writes alongside the flat
    /// `systemProtocols` list. Each protocol gets two list elements: the
    /// reverse-DNS string, then a `{"empty": {}}` marker dict. We do not
    /// know what richer payloads might appear here on more elaborate intents
    /// (focus filters, etc.); keep the empty marker until a counter-example
    /// is captured.
    public static func metadata(for protocolNames: [String]) -> [Any] {
        var out: [Any] = []
        for entry in resolve(for: protocolNames) {
            out.append(entry)
            out.append(["empty": [String: Any]()] as [String: Any])
        }
        return out
    }
}
