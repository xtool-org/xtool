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
    func resetProvisioning(completion: @escaping (Result<Void, Error>) -> Void)

    func fetchAnisetteData(completion: @escaping (Result<AnisetteData, Error>) -> Void)
}

extension AnisetteDataProvider {
    public func resetProvisioning(completion: @escaping (Result<Void, Error>) -> Void) {}
}
