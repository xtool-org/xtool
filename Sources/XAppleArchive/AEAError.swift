/// An error encountered while reading an Apple Encrypted Archive.
public struct AEAError: Error, CustomStringConvertible, Sendable {
    public var description: String

    init(_ description: String) {
        self.description = description
    }
}
