//
//  DeviceInfo+Fetching.swift
//  Supersign
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
            count = (gethostuuid(buf.baseAddress!, &waitTime) == 0) ? buf.count : 0
        }
        guard !bytes.isEmpty else { return nil }
        return bytes.withUnsafeBufferPointer { buf in
            UUID(uuid: UnsafeRawPointer(buf.baseAddress!).load(as: uuid_t.self)).uuidString
        }
    }

    private static func hardwareProperty(forKey key: String) -> Data? {
        let entry = IORegistryEntryFromPath(kIOMasterPortDefault, "IODeviceTree:/options")
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
        let service = IOServiceGetMatchingService(kIOMasterPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        return IORegistryEntryCreateCFProperty(
            service, "IOPlatformSerialNumber" as CFString, kCFAllocatorDefault, 0
        )?.takeRetainedValue() as? String
    }

    private static func fetchHardwareModel() -> String? {
        var modelSize = 0
        guard sysctlbyname("hw.model", nil, &modelSize, nil, 0) == 0 else { return nil }
        guard let rawString = malloc(modelSize) else { return nil }
        guard sysctlbyname("hw.model", rawString, &modelSize, nil, 0) == 0 else {
            free(rawString)
            return nil
        }
        return String(bytesNoCopy: rawString, length: modelSize - 1, encoding: .utf8, freeWhenDone: true)
    }

    public static func current() -> DeviceInfo? {
        guard let deviceID = fetchDeviceID(),
            let romAddress = fetchROMAddress(),
            let mlbSerialNumber = fetchMLBSerialNumber(),
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
#endif
