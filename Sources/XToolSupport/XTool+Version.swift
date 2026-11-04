import CXKit
import XCLIUtils

extension XTool {
    public static let version = CommandVersion(
        version: String(cString: xtl_version()),
        hasUncommittedChanges: xtl_has_uncommitted_changes(),
    )
}
