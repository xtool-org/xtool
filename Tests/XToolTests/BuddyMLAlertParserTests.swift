import Foundation
import Testing
@testable import XKit

@Test func parsesAlertFromIssue283Fixture() throws {
    let xml = """
    <xmlui action="showModal">
      <alert title="No Trusted Phone Numbers" \
    message="You do not have any trusted phone numbers associated with your Apple Account. \
    You can add a trusted phone number by verifying your identity.">
        <button name="ak-button" ak-action="cancel"></button>
        <button httpMethod="GET" url="https://gsa.apple.com/iforgot/phone/add"></button>
      </alert>
    </xmlui>
    """
    let data = Data(xml.utf8)
    let alert = BuddyMLAlertParser.parse(data)
    #expect(alert?.title == "No Trusted Phone Numbers")
    #expect(alert?.message.hasPrefix("You do not have any trusted phone numbers") == true)
}

@Test func returnsNilForBuddyMLWithoutAlert() {
    let data = Data("<xmlui action=\"showModal\"></xmlui>".utf8)
    #expect(BuddyMLAlertParser.parse(data) == nil)
}

@Test func returnsNilForEmptyData() {
    #expect(BuddyMLAlertParser.parse(Data()) == nil)
}

@Test func returnsNilForMalformedXML() {
    let data = Data("not xml at all <<<".utf8)
    #expect(BuddyMLAlertParser.parse(data) == nil)
}

@Test func stopsAtFirstAlert() {
    let xml = """
    <xmlui>
      <alert title="First" message="first-message"/>
      <alert title="Second" message="second-message"/>
    </xmlui>
    """
    let alert = BuddyMLAlertParser.parse(Data(xml.utf8))
    #expect(alert?.title == "First")
    #expect(alert?.message == "first-message")
}
