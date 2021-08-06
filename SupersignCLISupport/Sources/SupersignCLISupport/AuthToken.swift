import Foundation
import Supersign

struct AuthToken {
    let appleID: String
    let dsToken: DeveloperServicesLoginToken
}

extension AuthToken {

    // encoded format:
    // - appleID (null terminated string)
    // - adsid (null terminated string)
    // - expiry (double)
    // - token (data)

    init?(string: String) {
        guard string.hasPrefix("@") else { return nil }
        guard let data = Data(base64Encoded: String(string.dropFirst())) else { return nil }
        let components = data.split(separator: 0, maxSplits: 2, omittingEmptySubsequences: false)
        guard components.count == 3,
              let appleID = String(data: components[0], encoding: .utf8),
              !appleID.isEmpty,
              let adsid = String(data: components[1], encoding: .utf8),
              !adsid.isEmpty
        else { return nil }

        let rest = components[2]
        guard rest.count > MemoryLayout<Double>.size else { return nil }
        var expiry: Double = 0
        withUnsafeMutableBytes(of: &expiry) { _ = rest.copyBytes(to: $0) }

        let token = rest.advanced(by: MemoryLayout<Double>.size).base64EncodedString()

        self.appleID = appleID
        self.dsToken = DeveloperServicesLoginToken(
            adsid: adsid,
            token: token,
            expiry: Date(timeIntervalSince1970: expiry)
        )
    }

    var string: String? {
        guard var data = appleID.data(using: .utf8)
            else { return nil }
        data.append(0)
        guard let adsidData = dsToken.adsid.data(using: .utf8)
            else { return nil }
        data.append(adsidData)
        data.append(0)
        withUnsafeBytes(of: dsToken.expiry.timeIntervalSince1970) {
            data.append(Data($0))
        }
        guard let rawToken = Data(base64Encoded: dsToken.token)
            else { return nil }
        data.append(rawToken)
        return "@\(data.base64EncodedString())"
    }

}
