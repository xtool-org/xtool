//
//  AnisetteDataProvider.swift
//  Supersign
//
//  Created by Kabir Oberai on 19/11/19.
//  Copyright © 2019 Kabir Oberai. All rights reserved.
//

import Foundation

public protocol AnisetteDataProvider {
    // This is a suggestion and not a requirement. The default implementation
    // does nothing.
    func resetProvisioning() async

    func fetchAnisetteData() async throws -> AnisetteData
}

extension AnisetteDataProvider {
    public func resetProvisioning() async {}
}
