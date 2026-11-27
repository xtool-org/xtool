public struct CommandVersion: Sendable, Hashable {
    public var version: String
    public var hasUncommittedChanges: Bool

    public init(version: String, hasUncommittedChanges: Bool) {
        self.version = version
        self.hasUncommittedChanges = hasUncommittedChanges
    }

    public static var unversioned: Self {
        .init(version: "unversioned", hasUncommittedChanges: true)
    }
}

extension CommandVersion: CustomStringConvertible {
    public var description: String {
        version + (hasUncommittedChanges ? "-dirty" : "")
    }
}
