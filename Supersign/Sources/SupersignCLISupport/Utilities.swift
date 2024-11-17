import Foundation
import Supersign

func withSyncContinuation<T>(
    _ action: (_ cont: @escaping (T) -> Void) -> Void
) -> T {
    var value: T!
    let sem = DispatchSemaphore(value: 0)
    action {
        value = $0
        sem.signal()
    }
    sem.wait()
    return value
}

func withSyncContinuation<T>(
    _ action: (_ cont: @escaping (Result<T, Error>) -> Void) -> Void
) throws -> T {
    try withSyncContinuation(action).get()
}
