//
//  CHelpers.swift
//  XKit
//
//  Created by Kabir Oberai on 13/10/19.
//  Copyright © 2019 Kabir Oberai. All rights reserved.
//

import Foundation
import CXKit
#if os(Android)
import Android
#endif

#if os(Android)
package var stdoutSafe: OpaquePointer {
    get_stdout()
}
#else
package var stdoutSafe: UnsafeMutablePointer<FILE> {
    get_stdout()
}
#endif

extension Data {
    init?(deallocator: Deallocator = .free, acceptor: (inout Int) -> UnsafeMutableRawPointer?) {
        var count = 0
        guard let bytes = acceptor(&count) else { return nil }
        self.init(bytesNoCopy: bytes, count: count, deallocator: deallocator)
    }

    init(deallocator: Deallocator = .free, acceptor: (inout Int) -> UnsafeMutableRawPointer) {
        var count = 0
        let bytes = acceptor(&count)
        self.init(bytesNoCopy: bytes, count: count, deallocator: deallocator)
    }
}
