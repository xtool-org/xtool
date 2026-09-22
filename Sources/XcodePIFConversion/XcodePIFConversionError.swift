public struct XcodePIFConversionError: Error, CustomStringConvertible {
    public let description: String

    public init(_ description: String) {
        self.description = description
    }
}

// for convenience
typealias ConversionError = XcodePIFConversionError
