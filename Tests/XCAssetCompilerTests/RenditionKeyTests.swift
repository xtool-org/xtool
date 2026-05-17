import Foundation
import Testing
@testable import XCAssetCompiler

/// `risk-key-packing`: rendition key encode/decode round-trip across the
/// KEYFORMAT attribute space CoreUI 970 expects. The 9-token, 18-byte key
/// matches actool's output verbatim — see `KeyFormat.swift`.
@Suite("RenditionKey round-trip")
struct RenditionKeyTests {
    @Test("Round-trips across a sample of v1 attribute values")
    func roundTrip() throws {
        let appearances: [UInt16] = [0, 1]
        let scales: [UInt16] = [0, 1, 2, 3]
        let idioms: [UInt16] = [0, 1, 2]
        let subtypes: [UInt16] = [0, 1792]
        let dimensions: [UInt16] = [0, 1, 2]
        for appearance in appearances {
            for scale in scales {
                for idiom in idioms {
                    for subtype in subtypes {
                        for dimension in dimensions {
                            let key = RenditionKey(
                                appearance: appearance,
                                localization: 0,
                                scale: scale,
                                idiom: idiom,
                                subtype: subtype,
                                dimension2: dimension,
                                identifier: 6849,
                                element: 85,
                                part: 220
                            )
                            let data = key.encode()
                            #expect(data.count == 18)
                            let decoded = RenditionKey.decode(data)
                            #expect(decoded == key)
                        }
                    }
                }
            }
        }
    }

    @Test("Encodes as little-endian UInt16 tuples in KEYFORMAT order")
    func bytewiseLayout() {
        let key = RenditionKey(
            appearance: 0x0201,
            localization: 0x0403,
            scale: 0x0605,
            idiom: 0x0807,
            subtype: 0x0a09,
            dimension2: 0x0c0b,
            identifier: 0x0e0d,
            element: 0x100f,
            part: 0x1211
        )
        let bytes = [UInt8](key.encode())
        #expect(bytes == [
            0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08,
            0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f, 0x10,
            0x11, 0x12,
        ])
    }

    @Test("Sort order is lexicographic by byte, matching BOM tree binary search")
    func sortOrder() {
        // First differing byte determines the order. Scale lives at bytes 4-5;
        // with appearance/localization both zero, scale orders ascending.
        let scale2 = RenditionKey(scale: 2, idiom: 1).encode()
        let scale3 = RenditionKey(scale: 3, idiom: 1).encode()
        #expect(BOMTree.byteCompare(scale2, scale3) < 0)
        // Idiom is at bytes 6-7, so it only breaks ties when earlier slots match.
        let idiom1 = RenditionKey(scale: 2, idiom: 1).encode()
        let idiom2 = RenditionKey(scale: 2, idiom: 2).encode()
        #expect(BOMTree.byteCompare(idiom1, idiom2) < 0)
        // Appearance is the highest-priority slot.
        let appAny = RenditionKey(appearance: 0, scale: 3).encode()
        let appDark = RenditionKey(appearance: 1, scale: 0).encode()
        #expect(BOMTree.byteCompare(appAny, appDark) < 0)
    }

    @Test("nameHash is stable across calls for the same name")
    func nameHashStable() {
        // CoreUI only requires the identifier to match across our own FACETKEYS
        // and RENDITIONS trees in the same .car; the exact algorithm doesn't
        // need to match actool. We use CRC32-IEEE so the value is reproducible.
        let a = FacetKeys.nameHash("AppIcon")
        let b = FacetKeys.nameHash("AppIcon")
        #expect(a == b)
        #expect(FacetKeys.nameHash("AppIcon") != FacetKeys.nameHash("Accent"))
    }
}
