// Adapted from SwiftBuild/ProjectModel.swift: mutable Xcode PIF support and lossless JSON fields.

import Foundation

/// Mutable models for authoring and importing the JSON Project Interchange Format.
public enum XPIF: Sendable {}

extension XPIF {
    /// The type used for identifying PIF objects.
    public struct GUID: ExpressibleByStringInterpolation, Hashable, Sendable, Codable {
        public var value: String

        public init(_ value: String) {
            self.value = value
        }

        public init(stringLiteral value: StringLiteralType) {
            self.value = value
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.singleValueContainer()
            self.value = try container.decode(String.self)
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(self.value)
        }
    }

    public enum Error: Swift.Error {
        case duplicatedTargetIdentifier(targetIdentifier: GUID, targetName: String, productName: String)
        case emptyTargetIdentifier(targetName: String, productName: String)
        case emptyTargetName(targetIdentifier: GUID, productName: String)
    }

    /// The PIF schema version supported by the SwiftBuild source this model was adapted from.
    public static var pifEncodingSchemaVersion: Int {
        return 12
    }

    public struct XTag<S, T>: Sendable, Hashable where T: Sendable & Hashable {
        var value: T
    }
    public typealias Tag<S> = XTag<S, GUID>

    @dynamicMemberLookup
    public protocol Common {
        associatedtype Delegate
        var common: Delegate { get set }
    }

    /// Signature for a function to create an instance with a default GUID provided.
    public typealias CreateFn<T> = (GUID) -> T
}

extension XPIF.XTag {
    public init(rawValue: T) {
        self.value = rawValue
    }
}

extension XPIF.Common {
    public subscript<T>(dynamicMember keyPath: KeyPath<Delegate, T>) -> T {
        _read {
            yield common[keyPath: keyPath]
        }
    }
    public subscript<T>(dynamicMember keyPath: WritableKeyPath<Delegate, T>) -> T {
        _read {
            yield common[keyPath: keyPath]
        }
        _modify {
            yield &common[keyPath: keyPath]
        }
    }
}

extension Array where Element: Identifiable {
    subscript(id id: Element.ID) -> Element {
        get {
            first(where: { $0.id == id })!
        }
        set {
            self[firstIndex(where: { $0.id == id })!] = newValue
        }
    }

}
