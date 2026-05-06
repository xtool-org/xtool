import Foundation
import SwiftParser
import SwiftSyntax

/// Walks a list of source roots and harvests every AppIntents-related
/// declaration into a `ScannedModule`. The scanner is purely lexical:
/// it does not execute any Swift code and does not resolve types across
/// modules, so it sees only what the source itself spells out.
///
/// Recognised conformance markers (matched by trailing identifier on the
/// inheritance clause; module-qualified spellings such as
/// `AppIntents.AppIntent` also match):
///   * `AppIntent`, `AudioRecordingIntent`, `OpenIntent`,
///     `ForegroundContinuableIntent`, `LiveActivityIntent` (treated as
///     intents).
///   * `AppShortcutsProvider` (treated as a shortcuts provider).
///   * `AppEntity` (entity).
///   * `AppEnum` (enum).
///
/// Anything not recognised is ignored. The scanner is forgiving by design;
/// it would rather under-report than fail a build.
public struct Scanner: Sendable {

    /// A source root paired with the SwiftPM module that owns it. Used to
    /// stamp scanned declarations with their declaring module so the emitter
    /// can produce correct cross-module mangled names.
    public struct ScanRoot: Sendable, Equatable {
        public var module: String
        public var url: URL

        public init(module: String, url: URL) {
            self.module = module
            self.url = url
        }
    }

    public init() {}

    /// Scan every `.swift` file under each root, recursively. Symlinks are
    /// not followed. Hidden files are skipped. All decls are stamped with
    /// the empty string for `module` (legacy single-module callers).
    public func scan(roots: [URL]) throws -> ScannedModule {
        try scan(roots: roots.map { ScanRoot(module: "", url: $0) })
    }

    /// Scan a list of `(module, root)` pairs. Each scanned declaration is
    /// stamped with its declaring module name, which the emitter uses to
    /// generate correct mangled names for cross-module types.
    public func scan(roots: [ScanRoot]) throws -> ScannedModule {
        var module = ScannedModule()
        for root in roots {
            for url in try Self.swiftFiles(under: root.url) {
                let source = try String(contentsOf: url, encoding: .utf8)
                module.merge(scan(source: source, module: root.module))
            }
        }
        return module
    }

    /// Scan a single Swift source string. Useful in tests and for the
    /// `xtool-appintents-gen` CLI.
    public func scan(source: String) -> ScannedModule {
        scan(source: source, module: "")
    }

    public func scan(source: String, module: String) -> ScannedModule {
        let tree = Parser.parse(source: source)
        let visitor = AppIntentsVisitor(module: module, viewMode: .sourceAccurate)
        visitor.walk(tree)
        return visitor.module
    }

    static func swiftFiles(under root: URL) throws -> [URL] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        var files: [URL] = []
        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            files.append(url)
        }
        return files.sorted { $0.path < $1.path }
    }
}

private final class AppIntentsVisitor: SyntaxVisitor {
    var module = ScannedModule()
    let moduleName: String

    init(module: String, viewMode: SyntaxTreeViewMode) {
        self.moduleName = module
        super.init(viewMode: viewMode)
    }

    private static let intentProtocols: Set<String> = [
        "AppIntent",
        "AudioRecordingIntent",
        "ForegroundContinuableIntent",
        "LiveActivityIntent",
        "OpenIntent",
        "WidgetConfigurationIntent",
        "AppIntentsPackage",
    ]

    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
        let typeName = node.name.text
        let protocols = inheritanceNames(node.inheritanceClause)
        classify(
            typeName: typeName,
            kind: .struct,
            protocols: protocols,
            members: node.memberBlock.members
        )
        return .visitChildren
    }

    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
        let typeName = node.name.text
        let protocols = inheritanceNames(node.inheritanceClause)
        classify(
            typeName: typeName,
            kind: .class,
            protocols: protocols,
            members: node.memberBlock.members
        )
        return .visitChildren
    }

    override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind {
        let typeName = node.name.text
        let protocols = inheritanceNames(node.inheritanceClause)
        let isAppEnum = protocols.contains { $0 == "AppEnum" }
        if isAppEnum {
            var cases: [String] = []
            for member in node.memberBlock.members {
                if let caseDecl = member.decl.as(EnumCaseDeclSyntax.self) {
                    for element in caseDecl.elements {
                        cases.append(element.name.text)
                    }
                }
            }
            module.enums.append(
                ScannedEnum(
                    typeName: typeName,
                    module: moduleName,
                    protocolNames: protocols,
                    cases: cases
                )
            )
        }
        return .visitChildren
    }

    private func classify(
        typeName: String,
        kind: ScannedDeclKind,
        protocols: [String],
        members: MemberBlockItemListSyntax
    ) {
        let protocolSet = Set(protocols)
        let isIntent = !protocolSet.isDisjoint(with: Self.intentProtocols.subtracting(["AppIntentsPackage"]))
        let isProvider = protocols.contains("AppShortcutsProvider")
        let isEntity = protocols.contains("AppEntity")
        let isPackage = protocols.contains("AppIntentsPackage")

        if isIntent {
            var intent = makeIntent(
                typeName: typeName,
                kind: kind,
                protocols: protocols,
                members: members
            )
            intent.module = moduleName
            module.intents.append(intent)
        }
        if isProvider {
            var provider = makeShortcutsProvider(typeName: typeName, kind: kind, members: members)
            provider.module = moduleName
            module.shortcutsProviders.append(provider)
        }
        if isEntity {
            module.entities.append(
                ScannedEntity(typeName: typeName, kind: kind, module: moduleName, protocolNames: protocols)
            )
        }
        if isPackage {
            module.packages.append(ScannedPackage(typeName: typeName, kind: kind, module: moduleName))
        }
    }

    private func makeIntent(
        typeName: String,
        kind: ScannedDeclKind,
        protocols: [String],
        members: MemberBlockItemListSyntax
    ) -> ScannedIntent {
        var intent = ScannedIntent(typeName: typeName, kind: kind, protocolNames: protocols)
        for member in members {
            if let varDecl = member.decl.as(VariableDeclSyntax.self) {
                handleIntentProperty(varDecl, into: &intent)
            }
            if let funcDecl = member.decl.as(FunctionDeclSyntax.self),
               funcDecl.name.text == "perform" {
                if let returnType = funcDecl.signature.returnClause?.type {
                    intent.returnsValue = Self.typeMentions(returnType, name: "ReturnsValue")
                } else {
                    intent.returnsValue = false
                }
            }
        }
        return intent
    }

    private func handleIntentProperty(
        _ varDecl: VariableDeclSyntax,
        into intent: inout ScannedIntent
    ) {
        let isStatic = varDecl.modifiers.contains { $0.name.text == "static" }
        let bindings = varDecl.bindings
        guard let binding = bindings.first,
              let identPattern = binding.pattern.as(IdentifierPatternSyntax.self) else { return }
        let propertyName = identPattern.identifier.text

        if isStatic {
            switch propertyName {
            case "title":
                intent.title = stringLiteralValue(from: binding.initializer?.value)
            case "description":
                intent.descriptionText = intentDescriptionText(from: binding.initializer?.value)
                intent.categoryName = intentDescriptionCategory(from: binding.initializer?.value)
            case "openAppWhenRun":
                intent.openAppWhenRun = booleanValue(from: binding.initializer?.value)
            case "isDiscoverable":
                intent.isDiscoverable = booleanValue(from: binding.initializer?.value)
            default:
                break
            }
            return
        }

        // Instance property: candidate for `@Parameter`.
        let isParameter = varDecl.attributes.contains { attr in
            guard let attrSyntax = attr.as(AttributeSyntax.self) else { return false }
            return attrSyntax.attributeName.trimmedDescription == "Parameter"
        }
        guard isParameter else { return }
        guard let typeAnnotation = binding.typeAnnotation else { return }
        let typeText = typeAnnotation.type.trimmedDescription
        let isOptional = typeText.hasSuffix("?") || typeText.hasPrefix("Optional<")

        var parameter = ScannedParameter(
            propertyName: propertyName,
            typeName: typeText,
            isOptional: isOptional
        )

        if let attr = varDecl.attributes.first?.as(AttributeSyntax.self),
           attr.attributeName.trimmedDescription == "Parameter",
           case let .argumentList(args)? = attr.arguments {
            for arg in args {
                guard let label = arg.label?.text else { continue }
                if label == "title" {
                    parameter.title = stringLiteralValue(from: arg.expression)
                } else if label == "description" {
                    parameter.descriptionText = stringLiteralValue(from: arg.expression)
                } else if label == "default" {
                    parameter.defaultValueExpression = arg.expression.trimmedDescription
                }
            }
        }
        intent.parameters.append(parameter)
    }

    private func makeShortcutsProvider(
        typeName: String,
        kind: ScannedDeclKind,
        members: MemberBlockItemListSyntax
    ) -> ScannedShortcutsProvider {
        var provider = ScannedShortcutsProvider(typeName: typeName, kind: kind)
        for member in members {
            guard let varDecl = member.decl.as(VariableDeclSyntax.self),
                  varDecl.modifiers.contains(where: { $0.name.text == "static" }),
                  let binding = varDecl.bindings.first,
                  let identPattern = binding.pattern.as(IdentifierPatternSyntax.self),
                  identPattern.identifier.text == "appShortcuts" else { continue }

            let initializerExpr = binding.initializer?.value
            let accessorBody = binding.accessorBlock.flatMap { accessorBlock -> ExprSyntax? in
                if case .getter(let stmts) = accessorBlock.accessors {
                    // Find the last expression statement (the implicit return).
                    return stmts.last?.item.as(ExprSyntax.self)
                }
                return nil
            }
            let expr = initializerExpr ?? accessorBody
            guard let expr else { continue }
            provider.shortcuts = parseAppShortcutsExpression(expr)
            break
        }
        return provider
    }

    /// Walk a result builder body that produces `[AppShortcut]`. The body
    /// is typically a sequence of `AppShortcut(intent:phrases:shortTitle:systemImageName:)`
    /// calls. We accept either an array literal or a `@AppShortcutsBuilder`
    /// block.
    private func parseAppShortcutsExpression(_ expr: ExprSyntax) -> [ScannedShortcut] {
        var collected: [ScannedShortcut] = []
        let collector = AppShortcutCollector { call in
            if let shortcut = self.scanAppShortcutCall(call) {
                collected.append(shortcut)
            }
        }
        collector.walk(Syntax(expr))
        return collected
    }

    private func scanAppShortcutCall(_ call: FunctionCallExprSyntax) -> ScannedShortcut? {
        // Match `AppShortcut(...)` or `AppIntents.AppShortcut(...)`.
        let calleeText = call.calledExpression.trimmedDescription
        let calleeTail = calleeText.split(separator: ".").last.map(String.init) ?? calleeText
        guard calleeTail == "AppShortcut" else { return nil }

        var intentTypeName: String?
        var shortTitle: String?
        var systemImageName: String?
        var phrases: [String] = []

        for arg in call.arguments {
            guard let label = arg.label?.text else { continue }
            switch label {
            case "intent":
                intentTypeName = intentTypeFromExpression(arg.expression)
            case "phrases":
                phrases = stringArrayLiteralValue(arg.expression)
            case "shortTitle":
                shortTitle = stringLiteralValue(from: arg.expression)
            case "systemImageName":
                systemImageName = stringLiteralValue(from: arg.expression)
            default:
                break
            }
        }

        guard let intentTypeName else { return nil }
        return ScannedShortcut(
            intentTypeName: intentTypeName,
            phrases: phrases,
            shortTitle: shortTitle,
            systemImageName: systemImageName
        )
    }

    /// Extract a type name from `MyIntent()` / `MyIntent.self` /
    /// `Module.MyIntent()` style expressions. Returns the trailing
    /// identifier so module qualification is stripped.
    private func intentTypeFromExpression(_ expr: ExprSyntax) -> String? {
        if let call = expr.as(FunctionCallExprSyntax.self) {
            return call.calledExpression.trimmedDescription
                .split(separator: ".").last.map(String.init)
        }
        if let memberAccess = expr.as(MemberAccessExprSyntax.self),
           memberAccess.declName.baseName.text == "self" {
            return memberAccess.base?.trimmedDescription
                .split(separator: ".").last.map(String.init)
        }
        return expr.trimmedDescription
            .split(separator: ".").last.map(String.init)
    }

    private func inheritanceNames(_ clause: InheritanceClauseSyntax?) -> [String] {
        guard let clause else { return [] }
        return clause.inheritedTypes.map { inherited in
            let text = inherited.type.trimmedDescription
            return text.split(separator: ".").last.map(String.init) ?? text
        }
    }

    private func stringLiteralValue(from expr: ExprSyntax?) -> String? {
        guard let expr else { return nil }
        // Plain string literal: `"foo"`.
        if let lit = expr.as(StringLiteralExprSyntax.self) {
            return concatStringLiteralSegments(lit)
        }
        // `LocalizedStringResource("foo")` / `IntentDescription("foo", ...)`.
        if let call = expr.as(FunctionCallExprSyntax.self),
           let firstArg = call.arguments.first,
           firstArg.label == nil,
           let lit = firstArg.expression.as(StringLiteralExprSyntax.self) {
            return concatStringLiteralSegments(lit)
        }
        return nil
    }

    /// Specifically handles `IntentDescription("foo", categoryName: "bar")`.
    private func intentDescriptionText(from expr: ExprSyntax?) -> String? {
        guard let expr else { return nil }
        if let lit = expr.as(StringLiteralExprSyntax.self) {
            return concatStringLiteralSegments(lit)
        }
        if let call = expr.as(FunctionCallExprSyntax.self),
           let firstArg = call.arguments.first,
           firstArg.label == nil,
           let lit = firstArg.expression.as(StringLiteralExprSyntax.self) {
            return concatStringLiteralSegments(lit)
        }
        return nil
    }

    private func intentDescriptionCategory(from expr: ExprSyntax?) -> String? {
        guard let call = expr?.as(FunctionCallExprSyntax.self) else { return nil }
        for arg in call.arguments where arg.label?.text == "categoryName" {
            return stringLiteralValue(from: arg.expression)
        }
        return nil
    }

    private func booleanValue(from expr: ExprSyntax?) -> Bool? {
        guard let booleanLiteral = expr?.as(BooleanLiteralExprSyntax.self) else { return nil }
        return booleanLiteral.literal.text == "true"
    }

    private func stringArrayLiteralValue(_ expr: ExprSyntax) -> [String] {
        guard let array = expr.as(ArrayExprSyntax.self) else { return [] }
        var values: [String] = []
        for element in array.elements {
            if let lit = element.expression.as(StringLiteralExprSyntax.self),
               let s = concatStringLiteralSegments(lit) {
                values.append(s)
            }
        }
        return values
    }

    /// Concatenate the static segments of a string literal. Returns `nil`
    /// if the literal contains an interpolation we cannot represent
    /// statically (e.g. `\(.applicationName)`) — callers should treat that
    /// as "unknown" and fall back to the raw source text.
    private func concatStringLiteralSegments(_ lit: StringLiteralExprSyntax) -> String? {
        var out = ""
        var hadInterpolation = false
        for segment in lit.segments {
            if let str = segment.as(StringSegmentSyntax.self) {
                out.append(str.content.text)
            } else if let interp = segment.as(ExpressionSegmentSyntax.self) {
                hadInterpolation = true
                // App Intents phrases use `\(.applicationName)` heavily;
                // we keep the source spelling so the emitter can leave a
                // placeholder that Shortcuts substitutes at runtime.
                out.append("\\(\(interp.expressions.trimmedDescription))")
            }
        }
        if hadInterpolation, out.isEmpty { return nil }
        return out
    }

    /// Returns true when `type` is, or contains as a nested component, an
    /// identifier whose trailing name matches `name`. Used to detect
    /// `ReturnsValue<...>` inside opaque/composition return types like
    /// `some IntentResult & ReturnsValue<String>`. Walks
    /// `IdentifierTypeSyntax`, `MemberTypeSyntax`, `CompositionTypeSyntax`,
    /// `SomeOrAnyTypeSyntax`, and any generic argument lists.
    static func typeMentions(_ type: TypeSyntax, name: String) -> Bool {
        if let ident = type.as(IdentifierTypeSyntax.self) {
            if ident.name.text == name { return true }
            if let args = ident.genericArgumentClause?.arguments {
                for arg in args {
                    if typeMentions(TypeSyntax(arg.argument), name: name) {
                        return true
                    }
                }
            }
            return false
        }
        if let member = type.as(MemberTypeSyntax.self) {
            if member.name.text == name { return true }
            if let args = member.genericArgumentClause?.arguments {
                for arg in args {
                    if typeMentions(TypeSyntax(arg.argument), name: name) {
                        return true
                    }
                }
            }
            return typeMentions(TypeSyntax(member.baseType), name: name)
        }
        if let composition = type.as(CompositionTypeSyntax.self) {
            for element in composition.elements {
                if typeMentions(element.type, name: name) { return true }
            }
            return false
        }
        if let some = type.as(SomeOrAnyTypeSyntax.self) {
            return typeMentions(some.constraint, name: name)
        }
        if let attributed = type.as(AttributedTypeSyntax.self) {
            return typeMentions(attributed.baseType, name: name)
        }
        return false
    }
}

/// Walks any expression tree and invokes the supplied closure for every
/// nested `FunctionCallExprSyntax`. We use this to harvest `AppShortcut(...)`
/// calls inside an `AppShortcutsBuilder` body without having to enumerate
/// the result-builder transform shapes by hand.
private final class AppShortcutCollector: SyntaxVisitor {
    private let onCall: (FunctionCallExprSyntax) -> Void

    init(onCall: @escaping (FunctionCallExprSyntax) -> Void) {
        self.onCall = onCall
        super.init(viewMode: .sourceAccurate)
    }

    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        onCall(node)
        return .visitChildren
    }
}
