import Foundation

extension XPIF {
    /// A macro expression can be supplied as a single string or a list of strings.
    public enum StringList: Sendable, Hashable, Codable {
        case string(String)
        case array([String])

        public init(from decoder: any Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let value = try? container.decode(String.self) {
                self = .string(value)
            } else {
                self = .array(try container.decode([String].self))
            }
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .string(let value): try container.encode(value)
            case .array(let value): try container.encode(value)
            }
        }
    }
}
