//
//  DeveloperServicesAPIVersion.swift
//  Supersign
//
//  Created by Kabir Oberai on 10/04/20.
//  Copyright © 2020 Kabir Oberai. All rights reserved.
//

import Foundation
import Superutils

public protocol DeveloperServicesAPIVersion: Sendable {
    func url(forAction action: String) -> URL?
    var contentType: String { get }
    var accept: String { get }
    func body(withParameters parameters: [String: Any]) throws -> Data
    func decode<R: Decodable>(response: Data) throws -> R
}

public struct DeveloperServicesAPIVersionLegacy: DeveloperServicesAPIVersion {

    public struct Error: LocalizedError {
        public let code: Int
        public let reason: String?

        public var errorDescription: String? {
            return "\(code)".withCString { codeC in
                if let reason = reason {
                    return reason.withCString { reasonC in
                        String.localizedStringWithFormat(
                            NSLocalizedString(
                                "developer_services_api.old.error.reason_and_code",
                                value: "%s (%s)",
                                comment: "First reason, then code"
                            ),
                            reasonC, codeC
                        )
                    }
                } else {
                    return String.localizedStringWithFormat(
                        NSLocalizedString(
                            "developer_services_api.old.error.only_code",
                            value: "An unknown error occurred (%s)",
                            comment: ""
                        ),
                        codeC
                    )
                }
            }
        }
    }

    private struct Response<T: Decodable>: Decodable {
        private let resultCode: PossiblyStringifiedNumber
        private let resultString: String?
        private let userString: String?
        private let inner: T?

        private enum CodingKeys: String, CodingKey {
            case resultCode
            case resultString
            case userString
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.resultCode = try container.decode(PossiblyStringifiedNumber.self, forKey: .resultCode)
            self.resultString = try container.decodeIfPresent(String.self, forKey: .resultString)
            self.userString = try container.decodeIfPresent(String.self, forKey: .userString)

            self.inner = resultCode.value == 0 ?
                try decoder.singleValueContainer().decode(T.self) :
                nil
        }

        var result: Result<T, Swift.Error> {
            if let inner = inner {
                return .success(inner)
            } else {
                return .failure(Error(
                    code: resultCode.value,
                    reason: userString ?? resultString
                ))
            }
        }
    }

    private static let serviceProtocolVersion = "QH65B2"
    private static let clientID = "XABBG36SBA"
    private static let decoder = PropertyListDecoder()

    public func url(forAction action: String) -> URL? {
        let urlString = """
        https://developerservices2.apple.com/services/\
        \(Self.serviceProtocolVersion)/\(action).action?\
        clientId=\(Self.clientID)
        """
        return URL(string: urlString)
    }

    public let contentType = "text/x-xml-plist"
    public let accept = "text/x-xml-plist"

    public func body(withParameters parameters: [String: Any]) throws -> Data {
        var parameters = parameters
        parameters["requestId"] = UUID().uuidString
        parameters["clientId"] = Self.clientID
        parameters["protocolVersion"] = Self.serviceProtocolVersion
        parameters["userLocale"] = [Locale.current.identifier]
        return try PropertyListSerialization.data(fromPropertyList: parameters, format: .xml, options: 0)
    }

    public func decode<R: Decodable>(response: Data) throws -> R {
        try Self.decoder
            .decode(Response<R>.self, from: response)
            .result.get()
    }

}
