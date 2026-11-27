/// Adds `static let all`, listing the stored static properties of the attached type or extension whose
/// type is the extended type itself, in declaration order.
@attached(member, names: named(all))
macro CollectXcodeFileTypes() = #externalMacro(module: "XToolMacros", type: "CollectXcodeFileTypesMacro")
