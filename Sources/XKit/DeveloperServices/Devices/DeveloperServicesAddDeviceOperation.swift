import Foundation
import DeveloperAPI

public struct DeveloperServicesAddDeviceOperation: DeveloperServicesOperation {
    public let context: SigningContext
    public init(context: SigningContext) {
        self.context = context
    }

    public func perform() async throws {
        guard let targetDevice = context.targetDevice else { return }

        // try to register the device
        let response = try await context.developerAPIClient.devicesCreateInstance(
            body: .json(.init(data: .init(
                _type: .devices,
                attributes: .init(
                    name: targetDevice.name,
                    platform: .init(.ios),
                    udid: targetDevice.udid
                )
            )))
        )

        // we get a 409 CONFLICT if the device was already registered.
        // handle this by returning gracefully.
        if (try? response.conflict) != nil {
            return
        }

        // otherwise, we should get a 201 CREATED to indicate that the device
        // was added. any other case is unexpected, and this will throw.
        _ = try response.created
    }

}
