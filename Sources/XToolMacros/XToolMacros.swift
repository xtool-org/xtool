import SwiftCompilerPlugin
import SwiftSyntaxMacros

@main
struct XToolMacros: CompilerPlugin {
    let providingMacros: [any Macro.Type] = [
        CollectXcodeFileTypesMacro.self,
    ]
}
