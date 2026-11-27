import Foundation
import Testing
import Crypto
import X509
import XKit

// serial number from https://github.com/xtool-org/xtool/issues/305
private let leadingZeroSerial: [UInt8] = [
    0x03, 0x37, 0x42, 0x57, 0x0D, 0x6F, 0x96, 0x84,
    0xA2, 0x33, 0x11, 0x71, 0x19, 0x56, 0xA0, 0x84,
]

@Test func serialNumberKeepsLeadingZeroNibble() throws {
    let certificate = try makeCertificate(serialNumber: leadingZeroSerial)
    #expect(certificate.serialNumber() == "033742570D6F9684A23311711956A084")
}

@Test func serialNumberOmitsDERSignPadding() throws {
    // the high bit is set, so DER encodes this serial with a leading 0x00 byte
    var serial = leadingZeroSerial
    serial[0] = 0x83
    let certificate = try makeCertificate(serialNumber: serial)
    #expect(certificate.serialNumber() == "833742570D6F9684A23311711956A084")
}

@Test func hasSerialNumberIgnoresCaseAndLeadingZeros() throws {
    let certificate = try makeCertificate(serialNumber: leadingZeroSerial)
    #expect(certificate.hasSerialNumber("033742570D6F9684A23311711956A084"))
    #expect(certificate.hasSerialNumber("033742570d6f9684a23311711956a084"))
    #expect(certificate.hasSerialNumber("33742570D6F9684A23311711956A084"))
    #expect(certificate.hasSerialNumber("0033742570D6F9684A23311711956A084"))
    #expect(!certificate.hasSerialNumber("133742570D6F9684A23311711956A084"))
    #expect(!certificate.hasSerialNumber(""))
}

/// Creates a self-signed certificate and round-trips it through DER,
/// like the certificates we get from the developer API.
private func makeCertificate(serialNumber: [UInt8]) throws -> XKit.Certificate {
    let key = P256.Signing.PrivateKey()
    let name = try DistinguishedName {
        CommonName("xtool tests")
    }
    let now = Date()
    let certificate = try X509.Certificate(
        version: .v3,
        serialNumber: .init(bytes: serialNumber),
        publicKey: .init(key.publicKey),
        notValidBefore: now,
        notValidAfter: now + 3600,
        issuer: name,
        subject: name,
        signatureAlgorithm: .ecdsaWithSHA256,
        extensions: .init(),
        issuerPrivateKey: .init(key)
    )
    return try XKit.Certificate(data: XKit.Certificate(raw: certificate).data())
}
