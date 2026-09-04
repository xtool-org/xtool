//
//  PlistValue.swift
//  XKit
//

import Foundation
import libimobiledevice
import plist

/// A small, self-contained bridge between `plist_t` (from `libplist`, used by
/// `libimobiledevice`, `libtatsu`, and the NSKeyedArchiver-compatible encoding in
/// `Testing/NSKeyedArchive.swift`) and a Swift value, covering only the node types xtool needs
/// (dict/array/string/data/uint/bool/uid). Intentionally not a general-purpose PropertyList
/// implementation -- `PropertyListSerialization` already covers that for the XML/binary formats
/// used elsewhere in xtool; this exists because some C APIs (`mobile_image_mounter`, `libtatsu`)
/// hand back/expect raw `plist_t` graphs directly, and because NSKeyedArchiver's wire format
/// relies on the `UID` plist primitive, which `PropertyListSerialization` doesn't expose.
///
/// `libimobiledevice` and `plist` (both from xtool-core) are available as direct XKit
/// dependencies on every platform xtool supports (Linux via system `.systemLibrary`, macOS/
/// Windows via xtool-core's prebuilt xcframeworks), so this type is not platform-gated.
enum PlistValue {
    case dictionary([String: PlistValue])
    case array([PlistValue])
    case string(String)
    case data(Data)
    case uint(UInt64)
    case real(Double)
    case bool(Bool)
    /// The `UID` plist primitive used by NSKeyedArchiver's `$objects` back-references. Not a
    /// general-purpose plist type outside of that context.
    case uid(UInt64)

    init?(plistT node: plist_t) {
        switch plist_get_node_type(node) {
        case PLIST_DICT:
            var iter: plist_dict_iter?
            plist_dict_new_iter(node, &iter)
            var dict: [String: PlistValue] = [:]
            while true {
                var keyPtr: UnsafeMutablePointer<CChar>?
                var value: plist_t?
                plist_dict_next_item(node, iter, &keyPtr, &value)
                guard let keyPtr, let value else { break }
                defer { free(keyPtr) }
                dict[String(cString: keyPtr)] = PlistValue(plistT: value)
            }
            self = .dictionary(dict)
        case PLIST_ARRAY:
            let count = plist_array_get_size(node)
            var array: [PlistValue] = []
            array.reserveCapacity(Int(count))
            for i in 0..<count {
                guard let item = plist_array_get_item(node, i), let value = PlistValue(plistT: item) else { continue }
                array.append(value)
            }
            self = .array(array)
        case PLIST_STRING:
            guard let cString = plist_get_string_ptr(node, nil) else { return nil }
            self = .string(String(cString: cString))
        case PLIST_DATA:
            var length: UInt64 = 0
            guard let ptr = plist_get_data_ptr(node, &length) else { return nil }
            self = .data(ptr.withMemoryRebound(to: UInt8.self, capacity: Int(length)) { Data(bytes: $0, count: Int(length)) })
        case PLIST_INT:
            var value: UInt64 = 0
            plist_get_uint_val(node, &value)
            self = .uint(value)
        case PLIST_REAL:
            var value: Double = 0
            plist_get_real_val(node, &value)
            self = .real(value)
        case PLIST_BOOLEAN:
            var value: UInt8 = 0
            plist_get_bool_val(node, &value)
            self = .bool(value != 0)
        case PLIST_UID:
            var value: UInt64 = 0
            plist_get_uid_val(node, &value)
            self = .uid(value)
        default:
            return nil
        }
    }

    /// Parses an XML property list (as produced by `PropertyListSerialization`) into a
    /// `PlistValue` tree via `plist_from_memory`.
    static func parse(xml data: Data) -> PlistValue? {
        var node: plist_t?
        data.withUnsafeBytes { buf in
            let bound = buf.bindMemory(to: Int8.self)
            plist_from_memory(bound.baseAddress, UInt32(bound.count), &node, nil)
        }
        guard let node else { return nil }
        defer { plist_free(node) }
        return PlistValue(plistT: node)
    }

    /// Parses a binary property list (`bplist00`, the format NSKeyedArchiver payloads and some
    /// DTX auxiliary values use) into a `PlistValue` tree via `plist_from_bin`.
    static func parse(binary data: Data) -> PlistValue? {
        var node: plist_t?
        data.withUnsafeBytes { buf in
            let bound = buf.bindMemory(to: Int8.self)
            plist_from_bin(bound.baseAddress, UInt32(bound.count), &node)
        }
        guard let node else { return nil }
        defer { plist_free(node) }
        return PlistValue(plistT: node)
    }

    func toPlistT() -> plist_t {
        switch self {
        case .dictionary(let dict):
            // swiftlint:disable:next force_unwrapping
            let node = plist_new_dict()!
            for (key, value) in dict {
                plist_dict_set_item(node, key, value.toPlistT())
            }
            return node
        case .array(let array):
            // swiftlint:disable:next force_unwrapping
            let node = plist_new_array()!
            for value in array {
                plist_array_append_item(node, value.toPlistT())
            }
            return node
        case .string(let string):
            // swiftlint:disable:next force_unwrapping
            return plist_new_string(string)!
        case .data(let data):
            return data.withUnsafeBytes { buf in
                // swiftlint:disable:next force_unwrapping
                plist_new_data(buf.bindMemory(to: Int8.self).baseAddress, UInt64(buf.count))!
            }
        case .uint(let value):
            // swiftlint:disable:next force_unwrapping
            return plist_new_uint(value)!
        case .real(let value):
            // swiftlint:disable:next force_unwrapping
            return plist_new_real(value)!
        case .bool(let value):
            // swiftlint:disable:next force_unwrapping
            return plist_new_bool(value ? 1 : 0)!
        case .uid(let value):
            // swiftlint:disable:next force_unwrapping
            return plist_new_uid(value)!
        }
    }

    /// Serializes to the binary property list (`bplist00`) wire format via `plist_to_bin`.
    func toBinaryData() -> Data {
        let node = toPlistT()
        defer { plist_free(node) }
        var bytes: UnsafeMutablePointer<CChar>?
        var length: UInt32 = 0
        plist_to_bin(node, &bytes, &length)
        guard let bytes else { return Data() }
        defer { free(bytes) }
        return bytes.withMemoryRebound(to: UInt8.self, capacity: Int(length)) { Data(bytes: $0, count: Int(length)) }
    }
}
