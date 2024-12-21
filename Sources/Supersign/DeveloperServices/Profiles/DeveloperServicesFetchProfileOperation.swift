//
//  DeveloperServicesFetchProfileOperation.swift
//  Supersign
//
//  Created by Kabir Oberai on 13/10/19.
//  Copyright © 2019 Kabir Oberai. All rights reserved.
//

import Foundation
import Superutils
import DeveloperAPI

public struct DeveloperServicesFetchProfileOperation: DeveloperServicesOperation {

    public enum Errors: Error {
        case bundleIDNotFound
        case tooManyMatchingBundleIDs
        case invalidProfileData
    }

    public let context: SigningContext
    public let bundleID: String
    public init(context: SigningContext, bundleID: String) {
        self.context = context
        self.bundleID = bundleID
    }

    public func perform() async throws -> Mobileprovision {
        let bundleIDs = try await context.developerAPIClient
            .bundleIdsGetCollection(query: .init(
                filter_lbrack_identifier_rbrack_: [bundleID],
                include: [.profiles]
            ))
            .ok.body.json

        let bundleID: Components.Schemas.BundleId
        switch bundleIDs.data.count {
        case 0:
            throw Errors.bundleIDNotFound
        case 1:
            bundleID = bundleIDs.data[0]
        default:
            throw Errors.tooManyMatchingBundleIDs
        }

        let profiles = bundleIDs
            .included?
            .compactMap { included -> Components.Schemas.Profile? in
                if case .Profile(let profile) = included {
                    profile
                } else {
                    nil
                }
            } ?? []

        switch profiles.count {
        case 0:
            // we're good
            break
        case 1:
            _ = try await context.developerAPIClient.profilesDeleteInstance(path: .init(id: profiles[0].id)).noContent
        default:
            // if the user has >1 profile, it's probably okay to add another one (acceptable for non-free accounts?)
            break
        }

        let response = try await context.developerAPIClient.profilesCreateInstance(
            body: .json(
                .init(
                    data: .init(
                        _type: .profiles,
                        attributes: .init(
                            name: "SC profile \(bundleID)",
                            profileType: .iosAppDevelopment
                        ),
                        relationships: .init(
                            bundleId: .init(
                                data: .init(
                                    _type: .bundleIds,
                                    id: bundleID.id
                                )
                            ),
                            certificates: .init(data: [])
                        )
                    )
                )
            )
        )
        .created.body.json.data

        guard let contentString = response.attributes?.profileContent,
              let contentData = Data(base64Encoded: contentString)
              else { throw Errors.invalidProfileData }

        return try Mobileprovision(data: contentData)
    }

}
