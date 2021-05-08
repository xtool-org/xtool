//
//  Entitlement+DeveloperServicesFeature.swift
//  Supersign
//
//  Created by Kabir Oberai on 09/10/19.
//  Copyright © 2019 Kabir Oberai. All rights reserved.
//

import Foundation

protocol BaseEntitlementWithFeature: Entitlement {
    func baseFeature() -> DeveloperServicesFeature
}

protocol EntitlementWithFeature: BaseEntitlementWithFeature {
    associatedtype Feature: DeveloperServicesFeature
    func typedFeature() -> Feature
}
extension EntitlementWithFeature {
    func baseFeature() -> DeveloperServicesFeature {
        return typedFeature()
    }
}

extension EntitlementWithFeature
    where Self: RawRepresentable,
    Feature: RawRepresentable,
    RawValue == Feature.RawValue {
    func typedFeature() -> Feature {
        return Feature(rawValue: rawValue)!
    }
}

public extension Entitlement {
    func feature() -> DeveloperServicesFeature? {
        return (self as? BaseEntitlementWithFeature)?.baseFeature()
    }
}
