import Foundation

package struct Console {
    package struct Error: Swift.Error, CustomStringConvertible, LocalizedError {
        package let description: String

        package init(_ description: String) {
            self.description = description
        }

        package var errorDescription: String? {
            description
        }
    }
}
