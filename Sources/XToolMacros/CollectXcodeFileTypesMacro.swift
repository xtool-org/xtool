import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxMacros

/// Adds `static let all`, listing the stored static properties of the attached type or extension whose
/// type is the extended type itself, in declaration order.
///
/// Warns about properties that aren't sorted by name, to keep the list easy to scan.
public struct CollectXcodeFileTypesMacro: MemberMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingMembersOf declaration: some DeclGroupSyntax,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        guard let typeName = typeName(of: declaration) else {
            throw MacroExpansionErrorMessage("@CollectXcodeFileTypes must be attached to a type or extension")
        }
        let names = declaration.memberBlock.members.flatMap { member -> [TokenSyntax] in
            guard let variable = member.decl.as(VariableDeclSyntax.self),
                  variable.modifiers.contains(where: { $0.name.tokenKind == .keyword(.static) })
            else { return [] }
            return variable.bindings.compactMap { binding in
                guard binding.accessorBlock == nil,
                      let name = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier,
                      isOfType(binding, named: typeName)
                else { return nil }
                return name
            }
        }
        for (previous, name) in zip(names, names.dropFirst()) where name.text < previous.text {
            context.diagnose(Diagnostic(
                node: name,
                message: MacroExpansionWarningMessage(
                    "'\(name.text)' should be declared before '\(previous.text)' to keep file types sorted"
                )
            ))
        }
        let elements = names.map { "    .\($0.text)," }.joined(separator: "\n")
        return ["""
        static let all: [\(raw: typeName)] = [
        \(raw: elements)
        ]
        """]
    }

    private static func typeName(of declaration: some DeclGroupSyntax) -> String? {
        if let extensionDecl = declaration.as(ExtensionDeclSyntax.self) {
            return extensionDecl.extendedType.trimmedDescription
        }
        return declaration.asProtocol(NamedDeclSyntax.self)?.name.trimmedDescription
    }

    /// Whether the binding is annotated with the type, or initialized by calling one of its initializers.
    private static func isOfType(_ binding: PatternBindingSyntax, named typeName: String) -> Bool {
        if let annotation = binding.typeAnnotation {
            return [typeName, "Self"].contains(annotation.type.trimmedDescription)
        }
        guard let call = binding.initializer?.value.as(FunctionCallExprSyntax.self) else {
            return false
        }
        let callee = call.calledExpression.trimmedDescription
        return [typeName, "Self", ".init", "\(typeName).init", "Self.init"].contains(callee)
    }
}
