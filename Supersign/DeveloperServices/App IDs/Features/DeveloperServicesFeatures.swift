//
//  DeveloperServicesFeatures.swift
//  Supercharge
//
//  Created by Kabir Oberai on 19/09/19.
//  Copyright © 2019 Kabir Oberai. All rights reserved.
//

import Foundation
import ProtoCodable

struct DeveloperServicesFeatureContainer: ProtoCodableContainer {
    var value: DeveloperServicesFeature
}

typealias DeveloperServicesFeatures = ProtoCodableKeyValueContainer<DeveloperServicesFeatureContainer>
