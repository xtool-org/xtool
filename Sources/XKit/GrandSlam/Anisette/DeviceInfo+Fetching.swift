//
//  DeviceInfo+Fetching.swift
//  XKit
//
//  Created by Kabir Oberai on 18/06/20.
//  Copyright © 2020 Kabir Oberai. All rights reserved.
//

import Foundation

#if os(macOS)
extension DeviceInfo {

    private static func fetchDeviceID() -> String? {
        var waitTime = timespec(tv_sec: 0, tv_nsec: 0) // wait indefinitely
        let bytes = [UInt8](unsafeUninitializedCapacity: MemoryLayout<uuid_t>.size) { buf, count in
            // force unwrapping is safe because uuid_t has a non-zero size
            count = (gethostuuid(buf.baseAddress!, &waitTime) == 0) ? buf.count : 0
        }
        guard !bytes.isEmpty else { return nil }
        return bytes.withUnsafeBufferPointer {
            UUID(uuid: UnsafeRawBufferPointer($0).load(as: uuid_t.self)).uuidString
        }
    }

    private static func hardwareProperty(forKey key: String) -> Data? {
        let entry = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/options")
        guard entry != 0 else { return nil }
        defer { IOObjectRelease(entry) }

        return IORegistryEntryCreateCFProperty(
            entry, key as CFString, kCFAllocatorDefault, 0
        )?.takeRetainedValue() as? Data
    }

    private static func fetchROMAddress() -> String? {
        hardwareProperty(forKey: "4D1EDE05-38C7-4a6a-9CC6-4BCCA8B38C14:ROM")?
            .map { String(format: "%02hhx", $0) }
            .joined()
    }

    private static func fetchMLBSerialNumber() -> String? {
        hardwareProperty(forKey: "4D1EDE05-38C7-4a6a-9CC6-4BCCA8B38C14:MLB")?
            .map { String(format: isprint(Int32($0)) != 0 ? "%c" : "%02hhx", $0) }
            .joined()
    }

    private static func fetchSerialNumber() -> String? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        return IORegistryEntryCreateCFProperty(
            service, "IOPlatformSerialNumber" as CFString, kCFAllocatorDefault, 0
        )?.takeRetainedValue() as? String
    }

    private static func fetchHardwareModel() -> String? {
        var modelSize = 0
        guard sysctlbyname("hw.model", nil, &modelSize, nil, 0) == 0,
              modelSize > 0 else { return nil }
        return String(unsafeUninitializedCapacity: modelSize) { buf in
            var len = modelSize
            guard sysctlbyname("hw.model", buf.baseAddress, &len, nil, 0) == 0,
                  len == modelSize else { return 0 }
            return len - 1 // exclude NUL
        }
    }

    public static func current() -> DeviceInfo? {
        let romAddress = fetchROMAddress() ?? ""
        let mlbSerialNumber = fetchMLBSerialNumber() ?? ""

        guard let deviceID = fetchDeviceID(),
            let serialNumber = fetchSerialNumber(),
            let modelID = fetchHardwareModel()
            else { return nil }
        return DeviceInfo(
            deviceID: deviceID,
            romAddress: romAddress,
            mlbSerialNumber: mlbSerialNumber,
            serialNumber: serialNumber,
            modelID: modelID
        )
    }

}
#else
extension DeviceInfo {
    public static func current() -> DeviceInfo? {
        return DeviceInfo(
            deviceID: "99B5D9D4-B068-5CEE-A799-5EBB5B0894A6",
            romAddress: "94f6a300e9a0",
            mlbSerialNumber: "C02520301W0GF2D1U",
            serialNumber: "C02PQKRJG8WP",
            modelID: "Mac16,1"
        )
    }
}
#endif

// FIXME: Figure out DeviceInfo.current() outside macOS
// (see above)
