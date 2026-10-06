#if canImport(Subprocess)
import Subprocess
import Foundation

extension ExecutionResult {
    @discardableResult
    public func checkSuccess() throws(SubprocessFailure) -> Self {
        try terminationStatus.checkSuccess()
        return self
    }
}

extension TerminationStatus {
    fileprivate func checkSuccess() throws(SubprocessFailure) {
        if let failure { throw failure }
    }

    private var failure: SubprocessFailure? {
        if isSuccess { return nil }
        switch self {
        case .exited(let code): return .exited(code)
        case .signaled(let code): return .signaled(code)
        }
    }
}

public enum SubprocessFailure: Error {
    case exited(TerminationStatus.Code)
    case signaled(TerminationStatus.Code)
}

extension PlatformOptions {
    public static var withGracefulShutDown: Self {
        .init().withGracefulShutDown
    }

    public var withGracefulShutDown: Self {
        var copy = self
        copy.teardownSequence = [
            .gracefulShutDown(
                allowedDurationToNextStep: .milliseconds(500)
            )
        ]
        return copy
    }
}

extension Environment {
    public static func currentMap() -> [Environment.Key: String] {
        Dictionary(
            uniqueKeysWithValues: ProcessInfo.processInfo.environment.map {
                (Environment.Key(rawValue: $0)!, $1)
            }
        )
    }
}
#endif
