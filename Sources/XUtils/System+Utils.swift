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
    /// Writes every byte, waiting for capacity if the descriptor is nonblocking.
    package func writeAllWaiting(_ bytes: UnsafeRawBufferPointer) throws {
        var offset = 0
        while offset < bytes.count {
            do {
                // Swift System retries EINTR; retain the offset when a write is partial.
                let count = try write(UnsafeRawBufferPointer(rebasing: bytes[offset...]))
                guard count > 0 else { throw Errno.ioError }
                offset += count
            } catch let error as Errno where error.rawValue == EAGAIN || error.rawValue == EWOULDBLOCK {
                var descriptor = pollfd(fd: rawValue, events: Int16(POLLOUT), revents: 0)
                while poll(&descriptor, 1, -1) == -1 {
                    let error = Errno(rawValue: errno)
                    guard error != .interrupted else { continue }
                    throw error
                }
                // Retry write to report terminal errors (including POLLERR/POLLNVAL).
            }
        }
    }

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
