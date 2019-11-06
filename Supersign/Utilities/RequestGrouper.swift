//
//  RequestGrouper.swift
//  Supersign
//
//  Created by Kabir Oberai on 14/10/19.
//  Copyright © 2019 Kabir Oberai. All rights reserved.
//

import Foundation

public struct ErrorList<E: Error>: LocalizedError {

    public let errors: [E]
    public init(_ errors: [E]) {
        self.errors = errors
    }

    public var errorDescription: String? {
        return errors.map { $0.legibleLocalizedDescription }.joined(separator: ", ")
    }

}

class RequestGrouper<T, E: Error> {

    private let waitQueue = DispatchQueue(label: "request-wait-queue", attributes: .concurrent)
    private let group = DispatchGroup()

    private var values: [T] = []
    private var errors: [E] = []

    func add(request: (_ completion: @escaping (Result<T, E>) -> Void) -> Void) {
        group.enter()
        request { result in
            defer { self.group.leave() }
            switch result {
            case .failure(let error): self.errors.append(error)
            case .success(let value): self.values.append(value)
            }
        }
    }

    func onComplete(_ completion: @escaping (Result<[T], Error>) -> Void) {
        waitQueue.async {
            self.group.wait()
            switch self.errors.count {
            case 0: completion(.success(self.values))
            case 1: completion(.failure(self.errors[0]))
            default: completion(.failure(ErrorList(self.errors)))
            }
        }
    }

}
