import Foundation
import Dependencies

public struct ZIPCompressor: TestDependencyKey, Sendable {
    public var compress: @Sendable (
        _ directory: URL,
        _ progress: @escaping @Sendable (_ currentProgress: Double?) -> Void
    ) async throws -> URL

    public var decompress: @Sendable (
        _ file: URL,
        _ directory: URL,
        _ progress: @escaping @Sendable (_ currentProgress: Double?) -> Void
    ) async throws -> Void

    public init(
        compress: @Sendable @escaping (URL, @Sendable @escaping (Double?) -> Void) async throws -> URL,
        decompress: @Sendable @escaping (URL, URL, @Sendable @escaping (Double?) -> Void) async throws -> Void
    ) {
        self.decompress = decompress
        self.compress = compress
    }

    public static let testValue = ZIPCompressor(
        compress: unimplemented(),
        decompress: unimplemented()
    )

    /// Decompress the zipped ipa file
    ///
    /// - Parameter file: The `ipa` file to decompress.
    /// - Parameter directory: The directory into which `ipa` should be decompressed.
    /// - Parameter progress: A closure to which the callee can provide progress updates.
    ///   - term currentProgress: The current progress, or `nil` to indicate it is indeterminate.
    public func decompress(
        file: URL,
        in directory: URL,
        progress: @escaping @Sendable (_ currentProgress: Double?) -> Void
    ) async throws {
        try await decompress(file, directory, progress)
    }

    // `compress` is required because the only way to upload symlinks via afc is by
    // putting them in a zip archive (afc_make_symlink was disabled due to security or
    // something)

    /// Compress the app before installation.
    ///
    /// - Parameter directory: The `Payload` directory which is to be compressed.
    /// - Parameter progress: A closure to which the callee can provide progress updates.
    ///   - term currentProgress: The current progress, or `nil` to indicate it is indeterminate.
    public func compress(
        directory: URL,
        progress: @escaping @Sendable (_ currentProgress: Double?) -> Void
    ) async throws -> URL {
        try await compress(directory, progress)
    }
}

extension DependencyValues {
    public var zipCompressor: ZIPCompressor {
        get { self[ZIPCompressor.self] }
        set { self[ZIPCompressor.self] = newValue }
    }
}
