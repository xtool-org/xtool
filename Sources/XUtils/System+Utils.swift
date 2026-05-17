#if canImport(System)
import System
public typealias FilePath = System.FilePath
public typealias FileDescriptor = System.FileDescriptor
#else
import SystemPackage
import Foundation

public typealias FilePath = SystemPackage.FilePath
public typealias FileDescriptor = SystemPackage.FileDescriptor

extension URL {
    public init?(filePath: FilePath) {
        self.init(filePath: filePath.string)
    }
}

extension FilePath {
    public init?(_ url: URL) {
        guard url.isFileURL else { return nil }
        self.init(url.path)
    }
}
#endif
