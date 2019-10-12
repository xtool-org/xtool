//
//  CHelpers.swift
//  Supersign
//
//  Created by Kabir Oberai on 13/10/19.
//  Copyright © 2019 Kabir Oberai. All rights reserved.
//

import Foundation

extension Data {
    init?(cFunc: (UnsafeMutablePointer<Int>?) -> UnsafeMutablePointer<Int8>?) {
        var len = 0
        guard let bytes = cFunc(&len) else { return nil }
        defer { free(bytes) }
        self.init(bytes: UnsafeRawPointer(bytes), count: len)
    }
}
