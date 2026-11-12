import Testing
@testable import XKit

struct SMSPhoneNumberTests {
    @Test(arguments: [
        // the body from #424: Apple lists the only trusted number, with ID 2
        (#"{"success":0,"trustedPhoneNumbers":[{"nonFTEU":true,"pushMode":"sms","id":2}],"mode":"sms"}"#, 2),
        (#"{"trustedPhoneNumbers":[{"pushMode":"voice","id":3},{"pushMode":"sms","id":4}]}"#, 4),
        (#"{"trustedPhoneNumbers":[{"id":5}]}"#, 5),
    ])
    func picksTrustedNumber(body: String, expected: Int) {
        #expect(GrandSlamTwoFactorAuthenticateOperation.smsPhoneNumberID(in: body) == expected)
    }

    @Test(arguments: [nil, "", "not json", #"{"trustedPhoneNumbers":[]}"#, #"{"success":0}"#])
    func noTrustedNumber(body: String?) {
        #expect(GrandSlamTwoFactorAuthenticateOperation.smsPhoneNumberID(in: body) == nil)
    }
}
