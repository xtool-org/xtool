//
//  DeveloperServicesAPIVersion.swift
//  Supersign
//
//  Created by Kabir Oberai on 10/04/20.
//  Copyright © 2020 Kabir Oberai. All rights reserved.
//

import Foundation

public protocol DeveloperServicesAPIVersion {
    func url(forAction action: String) -> URL?
    var contentType: String { get }
    var accept: String { get }
    func body(withParameters parameters: [String: Any]) throws -> Data
    func decode<R: Decodable>(response: Data) throws -> R
}

public struct DeveloperServicesAPIVersionOld: DeveloperServicesAPIVersion {

    public struct Error: LocalizedError {
        public let code: Int
        public let reason: String?

        public var errorDescription: String? {
            if let reason = reason {
                return String.localizedStringWithFormat(
                    NSLocalizedString(
                        "developer_services_api.old.error.reason_and_code",
                        value: "%@ (%@)",
                        comment: "First reason, then code"
                    ),
                    reason, "\(code)"
                )
            } else {
                return String.localizedStringWithFormat(
                    NSLocalizedString(
                        "developer_services_api.old.error.only_code",
                        value: "An unknown error occurred (%@)",
                        comment: ""
                    ),
                    "\(code)"
                )
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

public struct DeveloperServicesAPIVersionV1: DeveloperServicesAPIVersion {

    public struct UnknownError: Swift.Error {}

    public struct Error: LocalizedError, Decodable {
        public let status: String
        public let code: String
        public let title: String
        public let detail: String

        public var errorDescription: String? {
            "\(code) (\(status)): \(title)\n\(detail)"
        }
    }

    private struct Response<T: Decodable>: Decodable {
        private let errors: [Error]?
        private let data: T?

        fileprivate var result: Result<T, Swift.Error> {
            if let data = data { return .success(data) }
            let errors = self.errors ?? []
            switch errors.count {
            case 0: return .failure(UnknownError())
            case 1: return .failure(errors[0])
            default: return .failure(ErrorList(errors))
            }
        }
    }

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSZ"
        decoder.dateDecodingStrategy = .formatted(formatter)
        return decoder
    }()

    public func url(forAction action: String) -> URL? {
        let urlString = "https://developerservices2.apple.com/services/v1/\(action)"
        return URL(string: urlString)
    }

    public let contentType = "application/vnd.api+json"
    public let accept = "application/vnd.api+json"

    public func body(withParameters parameters: [String: Any]) throws -> Data {
        var components = URLComponents()
        components.queryItems = parameters.map { URLQueryItem(name: $0, value: "\($1)") }
        let query = components.query ?? ""
        let dict = ["urlEncodedQueryParams": query]
        return try JSONSerialization.data(withJSONObject: dict)
    }

    public func decode<R: Decodable>(response: Data) throws -> R {
        // If `response` is empty and R is EmptyResponse, just return a new EmptyResponse
        // instead of crashing
        if let type = R.self as? EmptyResponse.Type {
            // swiftlint:disable:next force_cast
            return type.init() as! R
        } else {
            return try Self.decoder
                .decode(Response<R>.self, from: response)
                .result.get()
        }
    }

}
