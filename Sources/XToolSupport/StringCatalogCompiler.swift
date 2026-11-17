import Foundation

/// Compiles a String Catalog (`.xcstrings`) into the `.strings` and `.stringsdict`
/// tables that iOS reads at runtime, like `xcstringstool compile` does.
///
/// For each language this produces `<lang>.lproj/<Table>.strings` with the plain
/// strings and `<lang>.lproj/<Table>.stringsdict` with the strings that vary by
/// plural or device, or that use substitutions. Both are written as XML property
/// lists, which swift-build's CopyStringsFile step accepts as input.
struct StringCatalogCompiler {
    struct Output: Equatable {
        /// Path relative to the output directory, e.g. `ko.lproj/Localizable.strings`.
        var path: String
        var contents: Data
    }

    struct CompileError: Error, CustomStringConvertible {
        var description: String
    }

    /// Only compile these languages (`-l`). `nil` compiles every language in the catalog.
    var languages: Set<String>?

    /// Also compile translations whose state is `new` (`--force-build-all-strings`). These
    /// are skipped by default, since they haven't been translated yet (and are often empty).
    var forceBuildAllStrings: Bool

    /// Whether `new` strings are compiled for the language being compiled. Source language
    /// strings are always `new` unless reviewed, and their values may come from code
    /// (`defaultValue:`), so they're compiled too.
    private var compilesNewStrings = false

    /// Non-fatal problems found while compiling, e.g. variations that had to be simplified.
    private(set) var warnings: [String] = []

    init(languages: Set<String>? = nil, forceBuildAllStrings: Bool = false) {
        self.languages = languages
        self.forceBuildAllStrings = forceBuildAllStrings
    }

    /// Whether the catalog has strings that symbols would be generated for. Only
    /// manually managed strings get symbols; strings extracted from code don't.
    static func hasManualStrings(catalog data: Data) throws -> Bool {
        try decode(data).strings?.values.contains { $0.extractionState == "manual" } ?? false
    }

    private static func decode(_ data: Data) throws -> Catalog {
        do {
            return try JSONDecoder().decode(Catalog.self, from: data)
        } catch {
            throw CompileError(description: "The data couldn't be read: \(error)")
        }
    }

    mutating func compile(catalog data: Data, tableName: String) throws -> [Output] {
        let catalog = try Self.decode(data)

        var plain: [String: [String: String]] = [:]
        var rich: [String: [String: Any]] = [:]

        for (key, entry) in catalog.strings ?? [:] {
            var localizations = entry.localizations ?? [:]
            // The source language must always get a table, even if it only maps keys to
            // themselves: Bundle picks the best language among the .lproj folders it finds,
            // so without it an English user would be shown whichever translation exists.
            // (xcstringstool leaves the table out when every source string is `new`.)
            if localizations[catalog.sourceLanguage] == nil {
                localizations[catalog.sourceLanguage] = Localization(
                    stringUnit: StringUnit(state: nil, value: key)
                )
            }
            for (language, localization) in localizations {
                if entry.shouldTranslate == false && language != catalog.sourceLanguage { continue }
                if let languages, !languages.contains(language) { continue }
                try Self.validate(language: language)
                compilesNewStrings = forceBuildAllStrings || language == catalog.sourceLanguage

                let (value, item) = entries(
                    key: key,
                    localization: localization,
                    isSourceLanguage: language == catalog.sourceLanguage
                )
                if let value { plain[language, default: [:]][key] = value }
                if let item { rich[language, default: [:]][key] = item }
            }
        }

        var outputs: [Output] = []
        for language in Set(plain.keys).union(rich.keys).sorted() {
            if let strings = plain[language] {
                outputs.append(Output(
                    path: "\(language).lproj/\(tableName).strings",
                    contents: try Self.plist(strings)
                ))
            }
            if let stringsdict = rich[language] {
                outputs.append(Output(
                    path: "\(language).lproj/\(tableName).stringsdict",
                    contents: try Self.plist(stringsdict)
                ))
            }
        }
        return outputs
    }

    /// The `.strings` value and the `.stringsdict` entry (either may be nil) for a localization.
    private mutating func entries(
        key: String,
        localization: Localization,
        isSourceLanguage: Bool
    ) -> (value: String?, entry: [String: Any]?) {
        guard localization.substitutions == nil, localization.variations == nil else {
            return stringsdictEntry(key: key, localization: localization)
        }
        return (value(of: localization.stringUnit) ?? (isSourceLanguage ? key : nil), nil)
    }

    // MARK: - stringsdict

    private static let pluralVariable = "__plural"

    /// The stringsdict entry for a localization with variations or substitutions, and the
    /// plain `.strings` value to fall back on, if any.
    private mutating func stringsdictEntry(
        key: String,
        localization: Localization
    ) -> (value: String?, entry: [String: Any]?) {
        guard let device = localization.variations?.device else {
            return (nil, formatEntry(key: key, localization: localization))
        }
        // A device variation whose cases are all plain strings maps directly onto
        // NSStringDeviceSpecificRuleType. `other` isn't a device there: devices without
        // their own case use the .strings value. Nested variations can't be expressed in
        // a stringsdict, so fall back to the iPhone (or generic) case.
        if device.values.allSatisfy(\.isPlain), localization.substitutions == nil {
            var cases = device.compactMapValues { value(of: $0.stringUnit) }
            let fallback = cases.removeValue(forKey: "other")
            return (fallback, cases.isEmpty ? nil : ["NSStringDeviceSpecificRuleType": cases])
        }
        guard let chosen = device["iphone"] ?? device["other"] ?? device.min(by: { $0.key < $1.key })?.value
        else { return (nil, nil) }
        warnings.append("'\(key)' varies by device and by plural or substitution; only its iPhone variant is compiled")
        let substitutions = (localization.substitutions ?? [:])
            .merging(chosen.substitutions ?? [:]) { _, new in new }
        return (nil, formatEntry(key: key, localization: Localization(
            stringUnit: chosen.stringUnit,
            variations: chosen.variations,
            substitutions: substitutions.isEmpty ? nil : substitutions
        )))
    }

    /// An entry whose whole string varies by plural, or whose string has substitutions.
    private mutating func formatEntry(key: String, localization: Localization) -> [String: Any]? {
        var item: [String: Any] = [:]
        if let plural = localization.variations?.plural {
            // The format key is a single variable whose cases are complete strings,
            // selected by the first numeric argument.
            guard let forms = pluralForms(plural, key: key) else { return nil }
            // The count is the first numeric argument of the key (the source format, when it
            // is one). Otherwise look through the forms, since one may leave the number out.
            let formats = [key, forms["other"]].compactMap { $0 } + forms.sorted { $0.key < $1.key }.map(\.value)
            let argument = formats.lazy.compactMap { FormatSpecifier.parse($0).first { $0.isNumeric } }.first
            item["NSStringLocalizedFormatKey"] = Self.variableReference(
                Self.pluralVariable,
                position: argument?.position ?? 1
            )
            item[Self.pluralVariable] = Self.pluralRule(valueType: argument?.valueType ?? "lld", forms: forms)
        } else if let value = value(of: localization.stringUnit) {
            item["NSStringLocalizedFormatKey"] = value
        } else {
            return nil
        }

        for (name, substitution) in localization.substitutions ?? [:] {
            guard let plural = substitution.variations?.plural else {
                warnings.append("'\(key)': substitution '\(name)' has no plural variation and was left out")
                continue
            }
            let position = substitution.argNum ?? 1
            let valueType = substitution.formatSpecifier ?? "lld"
            // `%arg` stands for the substituted argument itself.
            guard let forms = pluralForms(plural, key: key) else { return nil }
            item[name] = Self.pluralRule(valueType: valueType, forms: forms.mapValues {
                $0.replacingOccurrences(of: "%arg", with: "%\(position)$\(valueType)")
            })
        }
        if localization.variations?.plural == nil, let substitutions = localization.substitutions,
           let format = item["NSStringLocalizedFormatKey"] as? String {
            // Bind every argument explicitly: the variables may not appear in argument order,
            // and the forms above are positional, which mustn't be mixed with sequential ones.
            item["NSStringLocalizedFormatKey"] = FormatSpecifier.positional(
                format,
                variables: substitutions.mapValues { $0.argNum ?? 1 }
            )
        }
        return item
    }

    /// The language becomes a directory name in the output directory, so it mustn't be a path.
    private static func validate(language: String) throws {
        guard !language.isEmpty, language.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "-_".contains($0)) })
        else { throw CompileError(description: "invalid language identifier '\(language)'") }
    }

    /// The cases of a plural variation. A stringsdict can't nest further variations or
    /// substitutions inside a plural case, so such cases are left out. Returns nil without
    /// an `other` case (e.g. not translated yet), which every plural rule needs.
    private mutating func pluralForms(_ plural: [String: Localization], key: String) -> [String: String]? {
        if plural.values.contains(where: { !$0.isPlain }) {
            warnings.append("'\(key)': plural cases that vary further or have substitutions were left out")
        }
        let forms = plural.filter { $0.value.isPlain }.compactMapValues { value(of: $0.stringUnit) }
        return forms["other"] == nil ? nil : forms
    }

    private func value(of unit: StringUnit?) -> String? {
        guard let unit, compilesNewStrings || unit.state != "new" else { return nil }
        return unit.value
    }

    private static func pluralRule(valueType: String, forms: [String: String]) -> [String: String] {
        forms.merging([
            "NSStringFormatSpecTypeKey": "NSStringPluralRuleType",
            "NSStringFormatValueTypeKey": valueType,
        ]) { _, new in new }
    }

    private static func variableReference(_ name: String, position: Int) -> String {
        position == 1 ? "%#@\(name)@" : "%\(position)$#@\(name)@"
    }

    private static func plist(_ object: Any) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: object, format: .xml, options: 0)
    }
}

// MARK: - Format specifiers

struct FormatSpecifier: Equatable {
    /// 1-based argument position, explicit (`%2$d`) or implied by order.
    var position: Int
    /// Length modifier and conversion, e.g. `lld`, `@`, `f`.
    var valueType: String

    var isNumeric: Bool {
        guard let conversion = valueType.last else { return false }
        return "dDiuUoOxXfFeEgGaA".contains(conversion)
    }

    /// The printf-style specifiers in `format`, ignoring `%%` and `%#@variable@`.
    static func parse(_ format: String) -> [FormatSpecifier] {
        var next = 1
        return tokens(in: Array(format)).compactMap { token in
            guard let valueType = token.valueType else { return nil }
            let position = token.position ?? next
            next = position + 1
            return FormatSpecifier(position: position, valueType: valueType)
        }
    }

    /// Rewrites `format` so that every specifier names its argument (`%@` → `%1$@`).
    /// `%#@variable@` references take the argument in `variables`; the remaining
    /// sequential specifiers take the arguments left over, in order.
    static func positional(_ format: String, variables: [String: Int]) -> String {
        let chars = Array(format)
        let tokens = tokens(in: chars)
        let explicit = tokens.map { token in token.position ?? token.variable.flatMap { variables[$0] } }
        var taken = Set(explicit.compactMap { $0 })
        var next = 1
        var result = ""
        var index = 0
        for (token, position) in zip(tokens, explicit) {
            let position = position ?? {
                while taken.contains(next) { next += 1 }
                taken.insert(next)
                return next
            }()
            result += String(chars[index..<token.start]) + "%\(position)$" + String(chars[token.body])
            index = token.body.upperBound
        }
        return result + String(chars[index...])
    }

    private struct Token {
        /// Index of the `%`.
        var start: Int
        /// Explicit `n$` position, if any.
        var position: Int?
        /// The specifier after the `%` and any `n$`.
        var body: Range<Int>
        /// Set for `%#@variable@` references.
        var variable: String?
        /// Set for ordinary specifiers: length modifier and conversion.
        var valueType: String?
    }

    private static func tokens(in chars: [Character]) -> [Token] {
        func skip(_ j: inout Int, while predicate: (Character) -> Bool) {
            while j < chars.count, predicate(chars[j]) { j += 1 }
        }
        let isDigit: (Character) -> Bool = { $0.isASCII && $0.isNumber }
        var tokens: [Token] = []
        var index = 0
        while index < chars.count {
            guard chars[index] == "%" else { index += 1; continue }
            let start = index
            var j = index + 1
            guard j < chars.count else { break }
            if chars[j] == "%" { index = j + 1; continue }

            var position: Int?
            var k = j
            skip(&k, while: isDigit)
            if k > j, k < chars.count, chars[k] == "$" {
                position = Int(String(chars[j..<k]))
                j = k + 1
            }
            let bodyStart = j
            skip(&j) { "-+ #0'".contains($0) }  // flags
            if j < chars.count, chars[j] == "@", j > bodyStart, chars[j - 1] == "#" {
                // %#@variable@
                guard let end = chars[(j + 1)...].firstIndex(of: "@") else { index = j + 1; continue }
                let variable = String(chars[(j + 1)..<end])
                tokens.append(Token(start: start, position: position, body: bodyStart..<(end + 1), variable: variable))
                index = end + 1
                continue
            }
            skip(&j) { $0 == "*" || isDigit($0) }  // width
            if j < chars.count, chars[j] == "." {
                j += 1
                skip(&j) { $0 == "*" || isDigit($0) }  // precision
            }
            let lengthStart = j
            skip(&j) { "hlqLzjt".contains($0) }
            guard j < chars.count, "dDiuUoOxXfFeEgGaAcCsSp@".contains(chars[j]) else { index = j; continue }
            let valueType = String(chars[lengthStart...j])
            tokens.append(Token(start: start, position: position, body: bodyStart..<(j + 1), valueType: valueType))
            index = j + 1
        }
        return tokens
    }
}

// MARK: - Catalog model

extension StringCatalogCompiler {
    struct Catalog: Decodable {
        var sourceLanguage: String
        var strings: [String: Entry]?
    }

    struct Entry: Decodable {
        var extractionState: String?
        var shouldTranslate: Bool?
        var localizations: [String: Localization]?
    }

    struct Localization: Decodable {
        var stringUnit: StringUnit?
        var variations: Variations?
        var substitutions: [String: Substitution]?

        var isPlain: Bool { variations == nil && substitutions == nil }
    }

    struct StringUnit: Decodable {
        var state: String?
        var value: String?
    }

    struct Variations: Decodable {
        var plural: [String: Localization]?
        var device: [String: Localization]?
    }

    struct Substitution: Decodable {
        var argNum: Int?
        var formatSpecifier: String?
        var variations: Variations?
    }
}
