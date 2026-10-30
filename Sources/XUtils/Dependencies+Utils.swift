import Dependencies

/// The current `DependencyValues`.
///
/// Prefer adding `@Dependency` fields to your type when possible, as
/// they remember the value assigned during initialization.
public var d: DependencyValues {
    @Dependency(\.self) var values
    return values
}
