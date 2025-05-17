import CXKit

extension XTool {
    public struct Version: Sendable, Hashable {
        public var commit: String
        public var tag: String?
    }

    public static let version: Version? = {
        guard let commit = xtl_git_commit() else { return nil }
        return Version(
            commit: String(cString: commit),
            tag: xtl_git_tag().map { String(cString: $0) }
        )
    }()
}

extension XTool.Version: CustomStringConvertible {
    public var description: String {
        if let tag {
            "xtool version \(tag)"
        } else {
            "xtool commit \(commit)"
        }
    }
}
