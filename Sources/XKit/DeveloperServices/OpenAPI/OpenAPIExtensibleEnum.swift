import DeveloperAPI

// syntactic sugar to make it nicer to work with `anyOf:` types
public protocol OpenAPIExtensibleEnum {
    associatedtype Value1Payload: RawRepresentable<String>, Codable, Hashable, Sendable, CaseIterable
    var value1: Value1Payload? { get set }
    var value2: String? { get set }

    init(value1: Value1Payload?, value2: String?)
}

extension OpenAPIExtensibleEnum {
    public var rawValue: String {
        value2!
    }

    public init(_ value: Value1Payload) {
        self.init(value1: value, value2: nil)
    }
}

extension Components.Schemas.BundleIdPlatform: OpenAPIExtensibleEnum {}
extension Components.Schemas.CapabilityOption.KeyPayload: OpenAPIExtensibleEnum {}
extension Components.Schemas.CapabilitySetting.KeyPayload: OpenAPIExtensibleEnum {}
extension Components.Schemas.CapabilityType: OpenAPIExtensibleEnum {}
extension Components.Schemas.CertificateType: OpenAPIExtensibleEnum {}
extension Components.Schemas.Device.AttributesPayload.DeviceClassPayload: OpenAPIExtensibleEnum {}
