import Foundation
import HTTPTypes
import OpenAPIRuntime

/// The observer receives an operation name, never headers, credentials, or payloads.
/// Task-local scope includes pagination, retry attempts, and shared-group requests.
public enum ProvisioningAPICallObserver {
    @TaskLocal static var suppressResponseBodies = false
    @TaskLocal public static var observer: @Sendable (String) -> Void = { _ in }
}

struct DeveloperServicesAPIObservationMiddleware: ClientMiddleware {
    func intercept(
        _ request: HTTPRequest,
        body: HTTPBody?,
        baseURL: URL,
        operationID: String,
        next: @Sendable (HTTPRequest, HTTPBody?, URL) async throws -> (HTTPResponse, HTTPBody?)
    ) async throws -> (HTTPResponse, HTTPBody?) {
        try Task.checkCancellation()
        ProvisioningAPICallObserver.observer(operationID)
        return try await next(request, body, baseURL)
    }
}
