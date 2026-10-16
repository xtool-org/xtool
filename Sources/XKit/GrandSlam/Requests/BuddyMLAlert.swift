import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

struct BuddyMLAlert: Equatable, Sendable {
    let title: String
    let message: String
}

enum BuddyMLAlertParser {
    static func parse(_ data: Data) -> BuddyMLAlert? {
        guard !data.isEmpty else { return nil }
        let delegate = AlertDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        _ = parser.parse()
        return delegate.alert
    }
}

private final class AlertDelegate: NSObject, XMLParserDelegate {
    var alert: BuddyMLAlert?

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String]
    ) {
        guard alert == nil, elementName == "alert" else { return }
        let title = attributeDict["title"] ?? ""
        let message = attributeDict["message"] ?? ""
        alert = BuddyMLAlert(title: title, message: message)
        parser.abortParsing()
    }
}
