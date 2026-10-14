import Foundation
import XUtils

/// Structural validation for a relocated Mac bundle, independent of signing and host tools.
public enum MacBundleAudit {
    public static func executable(in bundle: URL) throws -> URL {
        let root = bundle.resolvingSymlinksInPath().standardizedFileURL
        let plist = root.appendingPathComponent("Contents/Info.plist")
        let info = try PropertyListSerialization.propertyList(from: Data(contentsOf: plist), format: nil)
        guard let info = info as? [String: Any], info["CFBundlePackageType"] as? String == "APPL",
              let name = info["CFBundleExecutable"] as? String, !name.contains("/") else {
            throw StringError("Expected a macOS application with CFBundleExecutable: \(bundle.path)")
        }
        try ResourceDestination.validateRelativePath(name)
        let executable = root.appendingPathComponent("Contents/MacOS/\(name)").resolvingSymlinksInPath()
        guard executable.path.hasPrefix(root.path + "/"), FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw StringError("Application executable is missing or escapes its bundle")
        }
        return executable
    }

    @discardableResult
    public static func validate(bundle: URL, target: ResolvedTarget) throws -> [String] {
        guard target.platform == .macOS else { throw StringError("Expected a macOS artifact target") }
        let root = bundle.resolvingSymlinksInPath().standardizedFileURL
        let main = try executable(in: root)
        let inventory = try ArtifactInventory(directory: root, hashContents: false)
        var code: [String: MachOBinary.Slice] = [:]
        var signing: Set<String> = []
        for (path, entry) in inventory.files where entry.kind == "file" {
            let url = root.appendingPathComponent(path)
            let handle = try FileHandle(forReadingFrom: url)
            let prefix = try handle.read(upToCount: 4) ?? Data()
            try handle.close()
            guard [Data([0xcf, 0xfa, 0xed, 0xfe]), Data([0xca, 0xfe, 0xba, 0xbe]),
                   Data([0xbe, 0xba, 0xfe, 0xca])].contains(prefix) else { continue }
            let slices = try MachOBinary.inspect([UInt8](Data(contentsOf: url)))
            let cpu: UInt32 = target.architecture == "arm64" ? 0x0100000c : 0x01000007
            guard let slice = slices.first(where: { $0.cpu == cpu }), [2, 6, 8].contains(slice.fileType),
                  slice.platform == 1, slice.minimumOS <= MachOBinary.packedVersion(target.deploymentTarget) else {
                throw StringError("Incompatible nested code: \(path)")
            }
            code[path] = slice
            let node = try signingPath(for: path, in: root)
            guard signing.insert(node).inserted else {
                throw StringError("Multiple principal executables share signing node '\(node)'; keep one framework version")
            }
        }
        let mainPath = String(main.path.dropFirst(root.path.count + 1))
        guard code[mainPath]?.fileType == 2 else { throw StringError("Application executable is not macOS Mach-O code") }
        try validateDependencies(code, root: root, main: mainPath)
        return signing.sorted {
            let left = $0.split(separator: "/").count, right = $1.split(separator: "/").count
            return left == right ? $0 < $1 : left > right
        }
    }

    /// Maps only a bundle's declared principal executable to its signing node.
    /// Additional Mach-O files remain separate nodes, even in Contents/MacOS.
    public static func signingPath(for executablePath: String, in bundle: URL) throws -> String {
        try ResourceDestination.validateRelativePath(executablePath)
        let root = bundle.resolvingSymlinksInPath().standardizedFileURL
        let executable = root.appendingPathComponent(executablePath).resolvingSymlinksInPath().standardizedFileURL
        guard executable.path.hasPrefix(root.path + "/") else {
            throw StringError("Signing executable escapes bundle: \(executablePath)")
        }
        let path = String(executable.path.dropFirst(root.path.count + 1))
        let parts = path.split(separator: "/").map(String.init)
        if let index = parts.lastIndex(where: { $0.hasSuffix(".framework") }) {
            let frameworkPath = parts[...index].joined(separator: "/")
            let framework = root.appendingPathComponent(frameworkPath)
            let version = executable.deletingLastPathComponent()
            let candidates = [version.appendingPathComponent("Resources/Info.plist"),
                              framework.appendingPathComponent("Resources/Info.plist"),
                              framework.appendingPathComponent("Info.plist")]
            if let plist = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) {
                let info = try metadata(at: plist)
                if let name = info["CFBundleExecutable"] as? String {
                    try ResourceDestination.validateRelativePath(name)
                    guard !name.contains("/") else { throw StringError("Invalid framework executable name") }
                    let expected = version.appendingPathComponent(name).resolvingSymlinksInPath()
                    // A helper's directory is not a framework principal location.
                    let principalDirectory = parts.count == index + 2 ||
                        (parts.count == index + 4 && parts[index + 1] == "Versions")
                    if principalDirectory && expected == executable { return frameworkPath }
                }
            } else if String(parts[index].dropLast(".framework".count)) == parts.last,
                      parts.count == index + 2 || (parts.count == index + 4 && parts[index + 1] == "Versions") {
                // Preserve support for minimal frameworks without metadata.
                return frameworkPath
            }
        }
        if parts.count >= 3, parts[parts.count - 3] == "Contents", parts[parts.count - 2] == "MacOS" {
            let bundlePath = parts.dropLast(3).joined(separator: "/")
            let plist = root.appendingPathComponent(bundlePath).appendingPathComponent("Contents/Info.plist")
            if FileManager.default.fileExists(atPath: plist.path),
               try metadata(at: plist)["CFBundleExecutable"] as? String == parts.last {
                return bundlePath
            }
        }
        return path
    }

    private static func metadata(at url: URL) throws -> [String: Any] {
        guard let info = try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil)
            as? [String: Any] else { throw StringError("Invalid bundle metadata: \(url.path)") }
        return info
    }

    private static func validateDependencies(_ code: [String: MachOBinary.Slice], root: URL, main: String) throws {
        func systemLibrary(_ path: String) -> Bool {
            guard path.hasPrefix("/") else { return false }
            let canonical = URL(fileURLWithPath: path).standardizedFileURL.path
            return canonical.hasPrefix("/System/Library/") || canonical.hasPrefix("/usr/lib/")
        }
        func resolved(_ path: String, loader: String, executable: String) -> String? {
            if systemLibrary(path) { return path }
            let expanded: String
            if path.hasPrefix("@loader_path/") {
                expanded = (loader as NSString).deletingLastPathComponent + "/" + path.dropFirst(13)
            } else if path.hasPrefix("@executable_path/") {
                expanded = (executable as NSString).deletingLastPathComponent + "/" + path.dropFirst(17)
            } else { return nil }
            let url = root.appendingPathComponent(expanded).resolvingSymlinksInPath().standardizedFileURL
            guard url.path.hasPrefix(root.path + "/") else { return nil }
            return String(url.path.dropFirst(root.path.count + 1))
        }
        func visit(_ path: String, executable: String, inherited: [String], visited: inout Set<String>) throws {
            guard visited.insert(path).inserted, let slice = code[path] else { return }
            let rpaths = slice.rpaths.compactMap { resolved($0 + "/", loader: path, executable: executable) } + inherited
            for dependency in slice.dependencies {
                let name = dependency.path
                if systemLibrary(name) { continue }
                let candidates: [String]
                if name.hasPrefix("@rpath/") {
                    candidates = rpaths.map { $0 + "/" + name.dropFirst(7) }
                } else {
                    candidates = resolved(name, loader: path, executable: executable).map { [$0] } ?? []
                }
                let match = candidates.compactMap { candidate -> String? in
                    let url = root.appendingPathComponent(candidate).resolvingSymlinksInPath().standardizedFileURL
                    guard url.path.hasPrefix(root.path + "/") else { return nil }
                    let relative = String(url.path.dropFirst(root.path.count + 1))
                    return code[relative] != nil ? relative : nil
                }.first
                guard let match else {
                    if dependency.weak { continue }
                    // Swift's back-deployment runtime is referenced through @rpath and ships with the OS.
                    // Any other @rpath library must be embedded; a system rpath alone does not resolve it.
                    if name.hasPrefix("@rpath/libswift"), candidates.contains(where: systemLibrary) { continue }
                    throw StringError("Unresolved runtime dependency '\(name)' in \(path)")
                }
                try visit(match, executable: executable, inherited: rpaths, visited: &visited)
            }
        }
        var covered: Set<String> = []
        for (path, slice) in code where slice.fileType == 2 {
            var visited: Set<String> = []
            try visit(path, executable: path, inherited: [], visited: &visited)
            covered.formUnion(visited)
        }
        // Also check code loaded dynamically and therefore absent from LC_LOAD_DYLIB edges.
        let mainRpaths = code[main]?.rpaths.compactMap { resolved($0 + "/", loader: main, executable: main) } ?? []
        for (path, slice) in code where slice.fileType != 2 && !covered.contains(path) {
            var visited: Set<String> = []
            try visit(path, executable: main, inherited: mainRpaths, visited: &visited)
        }
    }
}
