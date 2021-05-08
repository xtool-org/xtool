//
//  AnisetteDataProvider.swift
//  Supersign
//
//  Created by Kabir Oberai on 19/11/19.
//  Copyright © 2019 Kabir Oberai. All rights reserved.
//

import Foundation

public protocol AnisetteDataProvider {
    func fetchAnisetteData(completion: @escaping (Result<AnisetteData, Error>) -> Void)
}
