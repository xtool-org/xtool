//
//  PersonalizedDDIMounter.swift
//  XKit
//

#if os(Linux)
import Foundation
import SwiftyMobileDevice
import libimobiledevice
import plist
import CTatsu
import Crypto

/// Mounts the "Personalized" Developer Disk Image used on iOS 17+, where Apple replaced the
/// single shared DDI with a per-device image tied to the device's ECID via a TSS ticket.
///
/// The device-side protocol (query nonce/personalization identifiers/manifest, upload, mount
/// with options) is implemented in `libimobiledevice` (see `mobile_image_mounter.h`), and the
/// TSS request/response transport is implemented in `libtatsu`. Neither is wrapped by
/// `SwiftyMobileDevice` yet, so this type talks to both C libraries directly via the `.raw`
/// handle `MobileImageMounterClient` already exposes publicly.
///
/// The exact TSS request field set below is transcribed (not copied verbatim -- rewritten in
/// Swift against the plist C API) from the documented, working reference implementation in
/// pymobiledevice3's `PersonalizedImageMounter.get_manifest_from_tss` (GPL-3.0; read only to
/// document the protocol, not copied, so it doesn't carry its license into this MIT-licensed
/// project).
///
/// - Important: This has been validated to compile and exercises real `libimobiledevice`/
///   `libtatsu` C APIs, but has **not** been exercised against a real device/TSS round trip
///   (no physical iOS 17+ device was available while writing this). Treat as unverified until
///   run against real hardware.
public final class PersonalizedDDIMounter: Sendable {

    public struct Resources: Sendable {
        /// The personalized `.dmg` image data (device-independent; only the manifest/ticket is
        /// device-specific).
        public let image: Data
        /// `BuildManifest.plist` contents describing the trusted manifest per board/chip ID.
        public let buildManifest: Data
        /// The image's loadable trust cache, passed to the device as `ImageTrustCache`.
        public let trustCache: Data
        /// Optional `ImageInfoPlist` extra.
        public let infoPlist: [String: Sendable]?

        public init(image: Data, buildManifest: Data, trustCache: Data, infoPlist: [String: Sendable]? = nil) {
            self.image = image
            self.buildManifest = buildManifest
            self.trustCache = trustCache
            self.infoPlist = infoPlist
        }
    }

    public struct Error: Swift.Error, LocalizedError {
        public let message: String
        public init(_ message: String) { self.message = message }
        public var errorDescription: String? { message }
    }

    private static let imageType = "Personalized"
    private static let personalizedImageType = "DeveloperDiskImage"
    private static let tssControllerURL = "https://gs.apple.com/TSS/controller?action=2"

    private let client: MobileImageMounterClient
    private let ecid: UInt64

    /// - Parameter ecid: the target device's ECID (as reported by lockdown's `UniqueChipID`),
    ///   required as part of the TSS request.
    public init(connection: Connection, ecid: UInt64) async throws {
        self.client = try await connection.startClient()
        self.ecid = ecid
    }

    public func isMounted() throws -> Bool {
        // Checks the lookup's actual content (a non-empty `ImageSignature`), not just whether the
        // call succeeded -- see `DDIMounter.MountedImage`'s doc comment for why the latter always
        // reports "mounted" regardless of real state.
        guard let mounted = try? client.lookup(imageType: Self.imageType, resultType: DDIMounter.MountedImage.self) else {
            return false
        }
        return mounted.signature?.isEmpty == false
    }

    public func mount(resources: Resources) async throws {
        let imageDigest = Data(Crypto.SHA384.hash(data: resources.image))

        // Prefer a manifest the device already has cached for this exact image; only fall back
        // to a fresh TSS round trip if it doesn't (mirrors pymobiledevice3's approach, which
        // notes the service connection must be re-established after a MissingManifest failure).
        let manifest: Data
        if let cached = try? client.queryPersonalizationManifest(
            imageType: Self.personalizedImageType,
            signature: imageDigest
        ) {
            manifest = cached
        } else {
            manifest = try await requestManifestFromTSS(buildManifest: resources.buildManifest)
        }

        try client.uploadPersonalized(imageType: Self.imageType, image: resources.image, manifest: manifest)

        try client.mountPersonalized(
            imageType: Self.imageType,
            signature: manifest,
            trustCache: resources.trustCache,
            infoPlist: resources.infoPlist
        )
    }

    // MARK: - TSS

    private func requestManifestFromTSS(buildManifest: Data) async throws -> Data {
        guard let manifestPlist = PlistValue.parse(xml: buildManifest),
              case .dictionary(let manifestDict) = manifestPlist,
              case .array(let buildIdentities)? = manifestDict["BuildIdentities"]
        else {
            throw Error("Could not parse BuildManifest.plist")
        }

        let identifiers = try client.queryPersonalizationIdentifiers(imageType: nil)
        guard case .uint(let boardID)? = identifiers["BoardId"],
              case .uint(let chipID)? = identifiers["ChipID"]
        else {
            throw Error("Device did not report BoardId/ChipID personalization identifiers")
        }

        guard let buildIdentity = buildIdentities.first(where: { identity in
            guard case .dictionary(let dict) = identity,
                  case .string(let apBoardID)? = dict["ApBoardID"],
                  case .string(let apChipID)? = dict["ApChipID"],
                  let parsedBoardID = UInt64(apBoardID.dropFirst(2), radix: 16),
                  let parsedChipID = UInt64(apChipID.dropFirst(2), radix: 16)
            else { return false }
            return parsedBoardID == boardID && parsedChipID == chipID
        }), case .dictionary(let buildIdentityDict) = buildIdentity,
        case .dictionary(let manifestEntries)? = buildIdentityDict["Manifest"]
        else {
            throw Error("Could not find a build identity matching board 0x\(String(boardID, radix: 16)) / chip 0x\(String(chipID, radix: 16))")
        }

        let nonce = try client.queryNonce(imageType: Self.personalizedImageType)

        var request: [String: PlistValue] = [:]
        for (key, value) in identifiers where key.hasPrefix("Ap,") {
            request[key] = value
        }
        request["@ApImg4Ticket"] = .bool(true)
        request["@BBTicket"] = .bool(true)
        request["ApBoardID"] = .uint(boardID)
        request["ApChipID"] = .uint(chipID)
        request["ApECID"] = .uint(ecid)
        request["ApNonce"] = .data(nonce)
        request["ApProductionMode"] = .bool(true)
        request["ApSecurityDomain"] = .uint(1)
        request["ApSecurityMode"] = .bool(true)
        request["SepNonce"] = .data(Data(count: 20))
        request["UID_MODE"] = .bool(false)

        for (key, entry) in manifestEntries {
            guard case .dictionary(var entryDict) = entry, entryDict["Info"] != nil else { continue }
            guard case .bool(true)? = entryDict["Trusted"] else { continue }
            entryDict["Info"] = nil
            if entryDict["Digest"] == nil {
                entryDict["Digest"] = .data(Data())
            }
            request[key] = .dictionary(entryDict)
        }

        let requestPlist = PlistValue.dictionary(request).toPlistT()
        defer { plist_free(requestPlist) }

        guard let fullRequest = tss_request_new(requestPlist) else {
            throw Error("tss_request_new failed")
        }
        defer { plist_free(fullRequest) }

        guard let response = tss_request_send(fullRequest, Self.tssControllerURL) else {
            throw Error("TSS request failed (no response, or server rejected the request)")
        }
        defer { plist_free(response) }

        var ticketPtr: UnsafeMutablePointer<UInt8>?
        var ticketLength: UInt32 = 0
        guard tss_response_get_ap_img4_ticket(response, &ticketPtr, &ticketLength) == 0, let ticketPtr else {
            throw Error("TSS response did not contain an ApImg4Ticket")
        }
        defer { free(ticketPtr) }
        return Data(bytes: ticketPtr, count: Int(ticketLength))
    }

}

// MARK: - MobileImageMounterClient extensions for personalization calls not yet wrapped by
// SwiftyMobileDevice. Operates on the public `.raw` handle only, so no changes to
// SwiftyMobileDevice are required.

extension MobileImageMounterClient {

    func queryNonce(imageType: String) throws -> Data {
        var noncePtr: UnsafeMutablePointer<UInt8>?
        var nonceLength: UInt32 = 0
        let status = mobile_image_mounter_query_nonce(raw, imageType, &noncePtr, &nonceLength)
        guard status == MOBILE_IMAGE_MOUNTER_E_SUCCESS, let noncePtr else {
            throw Error(status) ?? Error.unknown
        }
        defer { free(noncePtr) }
        return Data(bytes: noncePtr, count: Int(nonceLength))
    }

    func queryPersonalizationIdentifiers(imageType: String?) throws -> [String: PlistValue] {
        var result: plist_t?
        let status = mobile_image_mounter_query_personalization_identifiers(raw, imageType, &result)
        guard status == MOBILE_IMAGE_MOUNTER_E_SUCCESS, let result else {
            throw Error(status) ?? Error.unknown
        }
        defer { plist_free(result) }
        guard case .dictionary(let dict) = PlistValue(plistT: result) else {
            throw Swift.type(of: self).Error.unknown
        }
        return dict
    }

    func queryPersonalizationManifest(imageType: String, signature: Data) throws -> Data {
        var manifestPtr: UnsafeMutablePointer<UInt8>?
        var manifestLength: UInt32 = 0
        let status = signature.withUnsafeBytes { buf -> mobile_image_mounter_error_t in
            let bound = buf.bindMemory(to: UInt8.self)
            return mobile_image_mounter_query_personalization_manifest(
                raw, imageType, bound.baseAddress, UInt32(bound.count), &manifestPtr, &manifestLength
            )
        }
        guard status == MOBILE_IMAGE_MOUNTER_E_SUCCESS, let manifestPtr else {
            throw Error(status) ?? Error.unknown
        }
        defer { free(manifestPtr) }
        return Data(bytes: manifestPtr, count: Int(manifestLength))
    }

    func uploadPersonalized(imageType: String, image: Data, manifest: Data) throws {
        let stream = InputStream(data: image)
        stream.open()
        defer { stream.close() }
        try upload(imageType: imageType, file: stream, size: image.count, signature: manifest)
    }

    func mountPersonalized(
        imageType: String,
        signature: Data,
        trustCache: Data,
        infoPlist: [String: Sendable]?
    ) throws {
        var options: [String: PlistValue] = [
            "ImageTrustCache": .data(trustCache),
        ]
        if let infoPlist {
            let data = try PropertyListSerialization.data(fromPropertyList: infoPlist, format: .xml, options: 0)
            if let parsed = PlistValue.parse(xml: data) {
                options["ImageInfoPlist"] = parsed
            }
        }
        let optionsPlist = PlistValue.dictionary(options).toPlistT()
        defer { plist_free(optionsPlist) }

        var result: plist_t?
        let status = signature.withUnsafeBytes { buf -> mobile_image_mounter_error_t in
            let bound = buf.bindMemory(to: UInt8.self)
            return mobile_image_mounter_mount_image_with_options(
                raw, "", bound.baseAddress, UInt32(bound.count), imageType, optionsPlist, &result
            )
        }
        defer { if let result { plist_free(result) } }
        guard status == MOBILE_IMAGE_MOUNTER_E_SUCCESS else {
            throw Error(status) ?? Error.unknown
        }
        guard let result, case .dictionary(let dict) = PlistValue(plistT: result),
              case .string(let statusString)? = dict["Status"], statusString == "Complete"
        else {
            throw type(of: self).Error.commandFailed
        }
    }

}
#endif
