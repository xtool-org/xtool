import Foundation
import XUtils

/// Library products get an executable wrapper; executable products build directly;
/// prebuilt inputs are copied only after target compatibility validation.
public enum ProductSource: Sendable, Equatable, Codable {
    case library(product: String)
    case executable(product: String)
    case prebuilt(path: String)

    private enum Kind: String, Codable { case library, executable, prebuilt }
    private enum CodingKeys: String, CodingKey { case kind, product, path }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try values.decode(Kind.self, forKey: .kind)
        switch kind {
        case .library, .executable:
            guard !values.contains(.path) else {
                throw StringError("SwiftPM product sources cannot specify a prebuilt path")
            }
            let name = try values.decode(String.self, forKey: .product)
            self = kind == .library ? .library(product: name) : .executable(product: name)
        case .prebuilt:
            guard !values.contains(.product) else {
                throw StringError("Prebuilt sources cannot specify a SwiftPM product")
            }
            self = .prebuilt(path: try values.decode(String.self, forKey: .path))
        }
        try validate()
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .library(let product):
            try values.encode(Kind.library, forKey: .kind)
            try values.encode(product, forKey: .product)
        case .executable(let product):
            try values.encode(Kind.executable, forKey: .kind)
            try values.encode(product, forKey: .product)
        case .prebuilt(let path):
            try values.encode(Kind.prebuilt, forKey: .kind)
            try values.encode(path, forKey: .path)
        }
    }

    public func validate() throws {
        switch self {
        case .library(let value), .executable(let value), .prebuilt(let value):
            guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw StringError("Product source must specify a nonempty product or path")
            }
        }
    }
}
