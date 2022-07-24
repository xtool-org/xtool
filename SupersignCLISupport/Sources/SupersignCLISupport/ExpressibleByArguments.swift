import ArgumentParser

public protocol ExpressibleByArguments {
    associatedtype Arguments: ParsableArguments
    static func from(_ arguments: Arguments) throws -> Self
}

@propertyWrapper
struct FromArguments<Inner: ExpressibleByArguments>: ParsableArguments {
    @OptionGroup private var arguments: Inner.Arguments
    private var decoded: Inner?

    var wrappedValue: Inner {
        guard let decoded = decoded else {
            fatalError("Value has not yet been parsed")
        }
        return decoded
    }

    private enum CodingKeys: String, CodingKey {
        case arguments
    }

    mutating func validate() throws {
        decoded = try .from(arguments)
    }
}
