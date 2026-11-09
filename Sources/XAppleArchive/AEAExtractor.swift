import Dependencies
import Foundation
import XUtils

/// Extracts Apple Encrypted Archives (`.aea`), such as the ones Xcode is distributed as.
///
/// The archive's contents are integrity-checked as they are extracted. Note that
/// its signing certificate is not validated.
public struct AEAExtractor: DependencyKey, Sendable {
    public struct Options: Sendable {
        /// Called with the path of each entry, relative to the root of the archive.
        /// Return `false` to skip the entry.
        public var filter: (@Sendable (_ path: String) -> Bool)?

        public init(filter: (@Sendable (_ path: String) -> Bool)? = nil) {
            self.filter = filter
        }
    }

    public var extractArchive: @Sendable (
        _ archive: FilePath,
        _ destination: FilePath,
        _ options: Options,
        _ progress: @escaping @Sendable (_ fractionCompleted: Double) -> Void
    ) async throws -> Void

    public init(
        extractArchive: @escaping @Sendable (
            FilePath, FilePath, Options, @escaping @Sendable (Double) -> Void
        ) async throws -> Void
    ) {
        self.extractArchive = extractArchive
    }

    /// Extracts the archive at `archive` into the directory `destination`, creating it if needed.
    ///
    /// Supports cooperative cancellation. `progress` is called with the fraction
    /// of the archive that has been extracted so far.
    public func extract(
        _ archive: FilePath,
        to destination: FilePath,
        options: Options = .init(),
        progress: @escaping @Sendable (_ fractionCompleted: Double) -> Void = { _ in }
    ) async throws {
        try await extractArchive(archive, destination, options, progress)
    }

    public static var liveValue: Self {
        Self { archive, destination, options, progress in
            let archive = try AEAArchive(path: archive)
            try await archive.extract(
                to: destination,
                filter: options.filter,
                progress: { progress($0.fractionCompleted) }
            )
        }
    }

    public static var testValue: Self {
        Self(extractArchive: unimplemented("AEAExtractor.extractArchive"))
    }
}

extension DependencyValues {
    public var aeaExtractor: AEAExtractor {
        get { self[AEAExtractor.self] }
        set { self[AEAExtractor.self] = newValue }
    }
}
