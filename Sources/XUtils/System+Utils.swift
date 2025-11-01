#if canImport(System)
import System
public typealias FilePath = System.FilePath
public typealias FileDescriptor = System.FileDescriptor
#else
import SystemPackage
public typealias FilePath = SystemPackage.FilePath
public typealias FileDescriptor = SystemPackage.FileDescriptor
#endif
