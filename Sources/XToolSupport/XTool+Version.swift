import CXKit

extension XTool {
    public static let version = String(cString: xtl_version())
}
