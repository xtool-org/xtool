import Foundation
#if canImport(Darwin)
import CoreFoundation
#endif

extension String.Encoding {
    var backportedIANAName: String? {
        let name: String?
        #if canImport(Darwin)
        if #available(macOS 26.4, iOS 26.4, tvOS 26.4, watchOS 26.4, visionOS 26.4, *) {
            name = self.ianaName
        } else {
            name = self.legacyIANAName
        }
        #else
        name = self.ianaName
        #endif
        // Foundation's casing differs between platforms; retain the existing PIF representation.
        return name?.lowercased()
    }

    #if canImport(Darwin)
    private var legacyIANAName: String? {
        let cfEncoding = CFStringConvertNSStringEncodingToEncoding(self.rawValue)
        guard let charset = CFStringConvertEncodingToIANACharSetName(cfEncoding) else { return nil }
        return charset as String
    }
    #endif
}
