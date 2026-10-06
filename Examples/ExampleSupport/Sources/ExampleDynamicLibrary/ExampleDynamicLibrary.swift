import Foundation

public func exampleDynamicLibraryFunction() -> String {
    guard let bundled = #bundle.url(forResource: "response", withExtension: "txt")
        else { fatalError("Missing bundled.txt resource") }
    // swiftlint:disable:next force_try
    let contents = try! String(contentsOf: bundled, encoding: .utf8)
    return "Hello \(contents)"
}
