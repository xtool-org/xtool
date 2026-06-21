import Foundation

#if canImport(System)
import System

public typealias FilePath = System.FilePath
public typealias FileDescriptor = System.FileDescriptor
public typealias Errno = System.Errno
#else
import SystemPackage

public typealias FilePath = SystemPackage.FilePath
public typealias FileDescriptor = SystemPackage.FileDescriptor
public typealias Errno = SystemPackage.Errno

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

extension FileDescriptor {
    enum LockMode {
        case shared
        case exclusive

        fileprivate var raw: CInt {
            switch self {
            case .shared: LOCK_SH
            case .exclusive: LOCK_EX
            }
        }
    }

    func tryLock(mode: LockMode) throws -> Bool {
        if flock(rawValue, mode.raw | LOCK_NB) == 0 {
            return true
        }
        let err = errno
        if err == EWOULDBLOCK {
            return false
        }
        throw Errno(rawValue: err)
    }
}
