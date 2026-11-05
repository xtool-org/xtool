import DeveloperAPI

/// The platform whose development provisioning profile will be requested.
public enum SigningPlatform: String, CaseIterable, Sendable {
    case iOS = "ios"
    case tvOS = "tvos"

    var developmentProfileType:
        Components.Schemas.ProfileCreateRequest.DataPayload.AttributesPayload.ProfileTypePayload.Value1Payload {
        switch self {
        case .iOS: .iosAppDevelopment
        case .tvOS: .tvosAppDevelopment
        }
    }

    var developerServicesPlatform: DeveloperServicesPlatform {
        switch self {
        case .iOS: .iOS
        case .tvOS: .tvOS
        }
    }

    func supports(deviceClass: Components.Schemas.Device.AttributesPayload.DeviceClassPayload.Value1Payload) -> Bool {
        switch (self, deviceClass) {
        case (.iOS, .iphone), (.iOS, .ipad), (.iOS, .ipod), (.tvOS, .appleTv): true
        default: false
        }
    }
}
