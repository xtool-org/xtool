//
//  ResultWaiter.swift
//  SupersignTests
//
//  Created by Kabir Oberai on 30/10/19.
//  Copyright © 2019 Kabir Oberai. All rights reserved.
//

import Foundation
import XCTest

class ResultWaiter<T> {

    private let waiter = XCTWaiter()
    private let expectation: XCTestExpectation
    private(set) var completion: ((Result<T, Error>) -> Void)
    private var result: Result<T, Error>?

    init(description: String) {
        let expectation = XCTestExpectation(description: description)
        self.expectation = expectation
        // this stub is needed to allow the initialization phase to finish,
        // since we can't access self.result until that's done
        self.completion = { _ in }
        self.completion = { result in
            self.result = result
            expectation.fulfill()
        }
    }

    func wait(timeout: TimeInterval, file: StaticString = #file, line: UInt = #line) throws -> T {
        waiter.wait(for: [expectation], timeout: timeout)
        return try XCTUnwrap(result, file: file, line: line).get()
    }

}
