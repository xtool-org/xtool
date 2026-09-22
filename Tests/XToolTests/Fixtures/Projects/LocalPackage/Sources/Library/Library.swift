import Foundation
import Helper

public func libraryMessage() throws -> String {
    let url = Bundle.module.url(forResource: "Message", withExtension: "txt")!
    return helperMessage() + (try String(contentsOf: url, encoding: .utf8))
}
