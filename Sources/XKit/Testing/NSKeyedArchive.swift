//
//  NSKeyedArchive.swift
//  XKit
//
//  A from-scratch, minimal implementation of Apple's NSKeyedArchiver wire format, needed because
//  DTX (see Testing/DTX/DTXMessage.swift) serializes selector names and method-call arguments
//  using it, and Foundation's own NSKeyedArchiver on Linux does not correctly emit custom
//  `$classname` values for user-defined NSCoding types (verified empirically: `setClassName(_:
//  for:)`, both the static and archiver-instance overloads, had no effect on the emitted
//  `$objects` entry when tested against this toolchain's swift-corelibs-foundation) -- and DTX
//  payloads like `XCTestConfiguration` specifically need to be tagged with Apple's real
//  Objective-C class name for testmanagerd to recognize them.
//
//  The archive format itself (a `bplist00` binary property list containing `$archiver`/
//  `$version`/`$top`/`$objects`, with cross-references via the plist `UID` primitive) was
//  confirmed against this toolchain's real `NSKeyedArchiver` output for standard Foundation
//  types (NSURL, NSUUID, NSDictionary, NSData all matched exactly), and the specific
//  inline-vs-boxed encoding rules below follow the documented, working reference implementation
//  in appium-ios-device's `lib/instrument/transformer/nskeyed.js` (Apache-2.0 -- read for
//  protocol structure, rewritten from scratch here).

import Foundation
import plist

/// A value to be archived in NSKeyedArchiver's wire format.
public indirect enum NSKeyedValue: Sendable {
    case string(String)
    case data(Data)
    case int(Int64)
    case double(Double)
    case bool(Bool)
    case array([NSKeyedValue])
    /// Archives as `NSSet` (`$class` name + `NS.objects`), not `NSArray` -- distinct cases because
    /// the two aren't interchangeable on the wire: `XCTestConfiguration.testsToRun`/`testsToSkip`
    /// are declared as `NSSet<NSString>` on the real Apple type, and archiving them as `.array`
    /// instead (i.e. tagging the archived object `$class` as `NSArray`) is silently ignored by the
    /// on-device runner when unarchiving -- confirmed against real hardware (this session): `--only`/
    /// `--test-target` filters had no effect at all before this fix, with no error surfaced
    /// anywhere in the runner's own logs.
    case set([NSKeyedValue])
    /// Archives as `NSMutableArray`, not `NSArray` -- needed for
    /// `XCTTestIdentifierSet.identifiers`, which is typed `NSMutableArray<XCTTestIdentifier *>`
    /// on the real Apple type (confirmed against pymobiledevice3's `xctest_types.py`, which
    /// explicitly calls this out: "Must be NSMutableArray"). Same class-of-archived-object
    /// mismatch problem `.set`'s doc comment describes for `NSArray` vs `NSSet` -- confirmed
    /// against real hardware (this session): passing multiple `--only`/expanded `--test-target`
    /// identifiers with this array archived as plain `NSArray` silently kept only the *last*
    /// identifier in effect, discarding the rest, rather than erroring outright.
    case mutableArray([NSKeyedValue])
    case dictionary([String: NSKeyedValue])
    /// A reference to a custom Objective-C class (e.g. `NSURL`, `NSUUID`, `XCTestConfiguration`).
    /// `properties` are encoded in the given order; primitive values (`int`/`double`/`bool`) are
    /// inlined by default unless wrapped in `.boxed`, matching how NSKeyedArchiver only indirects
    /// through an `$objects` entry for values encoded via `encodeObject:forKey:` (as opposed to
    /// primitive coder methods like `encodeInt64:forKey:`).
    case object(className: String, extraClasses: [String] = ["NSObject"], properties: [(String, NSKeyedValue)])
    /// Forces a primitive value to be boxed as its own `$objects` entry rather than inlined.
    /// `XCTestConfiguration.formatVersion` is the one documented case that needs this.
    case boxed(NSKeyedValue)
    case null
}

enum NSKeyedArchive {
    private static let archiverName = "NSKeyedArchiver"
    private static let archiveVersion: UInt64 = 100_000

    // MARK: - Encoding

    private final class Archiver {
        var objects: [PlistValue] = [.string("$null")]

        /// Always creates a new `$objects` entry and returns a UID reference to it.
        func archive(_ value: NSKeyedValue) -> PlistValue {
            switch value {
            case .null:
                return .uid(0)
            case .string(let string):
                return push(.string(string))
            case .data(let data):
                return push(.data(data))
            case .int(let int):
                return push(.uint(UInt64(bitPattern: int)))
            case .double(let double):
                return push(.real(double))
            case .bool(let bool):
                return push(.bool(bool))
            case .array(let array):
                return archiveList(className: "NSArray", items: array)
            case .set(let set):
                return archiveList(className: "NSSet", items: set)
            case .mutableArray(let array):
                return archiveList(className: "NSMutableArray", items: array)
            case .dictionary(let dict):
                return archiveDictionary(dict)
            case .object(let className, let extraClasses, let properties):
                return archiveObject(className: className, extraClasses: extraClasses, properties: properties)
            case .boxed(let inner):
                return archive(inner)
            }
        }

        /// Inlines primitives directly; boxes (archives + returns a UID for) everything else.
        /// Mirrors NSKeyedArchiver's distinction between primitive coder methods
        /// (`encodeInt64:forKey:`, `encodeBytes:length:forKey:`) and object coder methods
        /// (`encodeObject:forKey:`).
        ///
        /// `.data` is inlined, not boxed, confirmed by byte-for-byte comparison against this
        /// toolchain's real `NSKeyedArchiver` archiving a real `NSUUID`: `NS.uuidbytes` holds the
        /// raw 16 bytes directly in the object's own dictionary, not a UID reference to a boxed
        /// `NSData` entry. Boxing it (this code's original behavior) produced a structurally
        /// different archive that `testmanagerd` silently failed to decode as an NSUUID --
        /// confirmed against real hardware: `_IDE_initiateSessionWithIdentifier:forClient:
        /// atPath:protocolVersion:`'s `sessionIdentifier` argument (encoded exactly this way) was
        /// logged device-side as "(null)", and testmanagerd closed the session with "Can't accept
        /// request from client without a session identifier" -- silently breaking every `xtool
        /// test` run's ability to ever receive `_XCT_testBundleReadyWithProtocolVersion:` on that
        /// connection, with no error surfaced back to the client.
        func encode(_ value: NSKeyedValue) -> PlistValue {
            switch value {
            case .int(let int):
                return .uint(UInt64(bitPattern: int))
            case .bool(let bool):
                return .bool(bool)
            case .double(let double):
                return .real(double)
            case .data(let data):
                return .data(data)
            case .boxed(let inner):
                return archive(inner)
            default:
                return archive(value)
            }
        }

        private func push(_ value: PlistValue) -> PlistValue {
            let index = objects.count
            objects.append(value)
            return .uid(UInt64(index))
        }

        private func classReference(_ className: String, extraClasses: [String]) -> PlistValue {
            push(.dictionary([
                "$classname": .string(className),
                "$classes": .array(([className] + extraClasses).map(PlistValue.string)),
            ]))
        }

        private func archiveList(className: String, items: [NSKeyedValue]) -> PlistValue {
            let index = objects.count
            objects.append(.bool(false)) // placeholder reserved so nested archiving doesn't reuse this index
            let itemRefs = items.map { archive($0) }
            let classRef = classReference(className, extraClasses: ["NSObject"])
            objects[index] = .dictionary([
                "NS.objects": .array(itemRefs),
                "$class": classRef,
            ])
            return .uid(UInt64(index))
        }

        private func archiveDictionary(_ dict: [String: NSKeyedValue]) -> PlistValue {
            let index = objects.count
            objects.append(.bool(false)) // placeholder reserved so nested archiving doesn't reuse this index
            // sort keys for deterministic, testable output; wire format doesn't require an order
            let sortedKeys = dict.keys.sorted()
            let keyRefs = sortedKeys.map { archive(.string($0)) }
            let valueRefs = sortedKeys.map { archive(dict[$0]!) }
            let classRef = classReference("NSDictionary", extraClasses: ["NSObject"])
            objects[index] = .dictionary([
                "NS.keys": .array(keyRefs),
                "NS.objects": .array(valueRefs),
                "$class": classRef,
            ])
            return .uid(UInt64(index))
        }

        private func archiveObject(
            className: String,
            extraClasses: [String],
            properties: [(String, NSKeyedValue)]
        ) -> PlistValue {
            let index = objects.count
            objects.append(.bool(false)) // placeholder reserved so nested archiving doesn't reuse this index
            var fields: [String: PlistValue] = [:]
            for (key, value) in properties {
                fields[key] = encode(value)
            }
            fields["$class"] = classReference(className, extraClasses: extraClasses)
            objects[index] = .dictionary(fields)
            return .uid(UInt64(index))
        }
    }

    /// Serializes `value` into an NSKeyedArchiver-compatible `bplist00` buffer.
    static func archive(_ value: NSKeyedValue) -> Data {
        let archiver = Archiver()
        let rootRef = archiver.archive(value)
        let plist = PlistValue.dictionary([
            "$version": .uint(archiveVersion),
            "$archiver": .string(archiverName),
            "$top": .dictionary(["root": rootRef]),
            "$objects": .array(archiver.objects),
        ])
        return plist.toBinaryData()
    }

    // MARK: - Decoding

    /// A decoded NSKeyedArchive object graph. Doesn't attempt to fully recreate specific
    /// Objective-C classes (unlike the Swift-side `NSKeyedValue` used for encoding) -- callers
    /// pattern-match `.object` for the specific classes they care about (test result callbacks
    /// mostly carry plain strings/dictionaries/numbers).
    indirect enum Decoded: Sendable {
        case string(String)
        case data(Data)
        case int(Int64)
        case double(Double)
        case bool(Bool)
        case array([Decoded])
        case dictionary([String: Decoded])
        case object(className: String, fields: [String: Decoded])
        case null
    }

    enum DecodeError: Swift.Error {
        case notBplist
        case unsupportedArchiver(String?)
        case unsupportedVersion(UInt64?)
        case missingRoot
        case cycle
    }

    /// Parses an NSKeyedArchiver-compatible `bplist00` buffer (as produced by `archive(_:)`, or
    /// received from a device) back into a `Decoded` value tree.
    static func unarchive(_ data: Data) throws -> Decoded {
        guard let root = PlistValue.parse(binary: data), case .dictionary(let plist) = root else {
            throw DecodeError.notBplist
        }
        guard case .string(let archiverName)? = plist["$archiver"], archiverName == Self.archiverName else {
            if case .string(let name)? = plist["$archiver"] {
                throw DecodeError.unsupportedArchiver(name)
            }
            throw DecodeError.unsupportedArchiver(nil)
        }
        guard case .array(let objects)? = plist["$objects"] else {
            throw DecodeError.missingRoot
        }
        guard case .dictionary(let top)? = plist["$top"], case .uid(let rootUID)? = top["root"] else {
            throw DecodeError.missingRoot
        }

        var cache: [Int: Decoded] = [:]
        var inProgress: Set<Int> = []

        func decodeValue(_ value: PlistValue) throws -> Decoded {
            switch value {
            case .uid(let uid):
                guard let intUID = Int(exactly: uid) else { return .null }
                return try decodeUID(intUID)
            case .string(let string):
                return .string(string)
            case .data(let data):
                return .data(data)
            case .uint(let uint):
                return .int(Int64(bitPattern: uint))
            case .real(let real):
                return .double(real)
            case .bool(let bool):
                return .bool(bool)
            case .array(let array):
                return .array(try array.map(decodeValue))
            case .dictionary(let dict):
                return .dictionary(try dict.mapValues(decodeValue))
            }
        }

        func decodeUID(_ uid: Int) throws -> Decoded {
            if uid == 0 { return .null }
            if let cached = cache[uid] { return cached }
            guard uid >= 0, uid < objects.count else { return .null }
            guard !inProgress.contains(uid) else { throw DecodeError.cycle }
            inProgress.insert(uid)
            defer { inProgress.remove(uid) }

            let raw = objects[uid]
            let decoded: Decoded
            switch raw {
            case .string(let string):
                decoded = .string(string)
            case .uint(let uint):
                decoded = .int(Int64(bitPattern: uint))
            case .real(let real):
                decoded = .double(real)
            case .bool(let bool):
                decoded = .bool(bool)
            case .data(let data):
                decoded = .data(data)
            case .dictionary(let fields):
                decoded = try decodeClassedObject(fields)
            default:
                decoded = .null
            }
            cache[uid] = decoded
            return decoded
        }

        func decodeClassedObject(_ fields: [String: PlistValue]) throws -> Decoded {
            guard case .uid(let classUID)? = fields["$class"],
                  classUID >= 0, Int(classUID) < objects.count,
                  case .dictionary(let classInfo) = objects[Int(classUID)],
                  case .string(let className)? = classInfo["$classname"]
            else {
                // not a classed object (e.g. a plain aux-buffer dictionary payload); decode as-is
                var decodedFields: [String: Decoded] = [:]
                for (key, value) in fields where key != "$class" {
                    decodedFields[key] = try decodeValue(value)
                }
                return .dictionary(decodedFields)
            }

            switch className {
            case "NSDictionary", "NSMutableDictionary":
                guard case .array(let keyRefs)? = fields["NS.keys"], case .array(let valueRefs)? = fields["NS.objects"] else {
                    return .object(className: className, fields: [:])
                }
                var dict: [String: Decoded] = [:]
                for (keyRef, valueRef) in zip(keyRefs, valueRefs) {
                    guard case .string(let key) = try decodeValue(keyRef) else { continue }
                    dict[key] = try decodeValue(valueRef)
                }
                return .dictionary(dict)
            case "NSArray", "NSMutableArray", "NSSet", "NSMutableSet":
                guard case .array(let itemRefs)? = fields["NS.objects"] else {
                    return .array([])
                }
                return .array(try itemRefs.map(decodeValue))
            case "NSString", "NSMutableString":
                if case .string(let value)? = fields["NS.string"] {
                    return .string(value)
                }
                return .string("")
            default:
                var decodedFields: [String: Decoded] = [:]
                for (key, value) in fields where key != "$class" {
                    decodedFields[key] = try decodeValue(value)
                }
                return .object(className: className, fields: decodedFields)
            }
        }

        guard let rootIntUID = Int(exactly: rootUID) else { throw DecodeError.missingRoot }
        return try decodeUID(rootIntUID)
    }
}
