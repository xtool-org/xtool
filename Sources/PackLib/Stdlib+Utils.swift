package struct StringError: Error, CustomStringConvertible {
    package var description: String
    package init(_ description: String) {
        self.description = description
    }
}
