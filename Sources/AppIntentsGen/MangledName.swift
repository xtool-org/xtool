import Foundation

/// Computes the lightweight Apple "mangled type name" string used inside
/// `Metadata.appintents/extract.actionsdata`.
///
/// The format observed in shipping iOS apps (e.g. Wispr Flow 1.55) is a
/// stripped-down form of Swift symbol mangling, not the full Swift ABI
/// mangled symbol that nm/dyld would emit. Concretely:
///
///     <moduleLength><moduleName><typeLength><typeName><kindSuffix>
///
/// where `kindSuffix` is `V` for `struct`, `C` for `class`, `O` for `enum`.
/// Examples from Wispr:
///   * `Flow.StartStopRecordingAppIntent` (struct)
///       → `4Flow27StartStopRecordingAppIntentV`
///   * `Widgets.NoteAppIntent` (struct in widget extension)
///       → `7Widgets13NoteAppIntentV`
///   * `Flow.ShortcutsProvider` (autoShortcutProviderMangledName)
///       → `4Flow17ShortcutsProviderV`
///
/// We deliberately do NOT prefix `$s` (the Swift 5 mangling marker) — Apple's
/// AppIntents pipeline uses the bare `<len><name>` grammar internally and the
/// daemon recognises it without the Swift prefix.
///
/// Limitations of this v0:
///   * Top-level types only. Nested types would need additional context grammar
///     (`<outer><inner>` with no second length, etc.). None of iMoonshine's
///     intents are nested, and the same is true of every reference IPA we have
///     audited so far. Add nested-type support when an app needs it.
///   * Generic types are emitted as their bare name. AppIntents in the wild do
///     not use generics on the intent type itself.
public enum MangledName {

    /// Single mangled name. `module` and `typeName` must be ASCII identifiers
    /// (Swift identifier rules). UTF-8 byte counts of single-codepoint ASCII
    /// equal `String.count`, so we use `count` directly here.
    public static func encode(
        module: String,
        typeName: String,
        kind: ScannedDeclKind
    ) -> String {
        "\(module.count)\(module)\(typeName.count)\(typeName)\(kind.mangledSuffix)"
    }
}
