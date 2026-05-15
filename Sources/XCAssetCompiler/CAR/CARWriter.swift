import Foundation

/// Orchestrates the BOM container and CAR-specific blocks/trees.
struct CARWriter: Sendable {
    var deploymentTarget: String
    var renditions: [Rendition]

    func write() throws -> Data {
        var bom = BOMWriter()

        // Build all blocks first; defer setVariable calls until the end so
        // we can emit the BOM vars table in the canonical order CoreUI
        // expects. (Empirically iOS's UIImage(named:) lookup walks the vars
        // table in order and rejects catalogs whose ordering doesn't match
        // the reference shape: CARHEADER, RENDITIONS, FACETKEYS,
        // APPEARANCEKEYS, KEYFORMAT, EXTENDED_METADATA, BITMAPKEYS.)

        let kindForName: [String: FacetKeys.Kind] = renditions.reduce(into: [:]) { acc, rendition in
            let kind: FacetKeys.Kind = {
                switch rendition.body {
                case .bitmap(let body):
                    switch body.kind {
                    case .appIcon: return .appIcon
                    case .image: return .image
                    }
                case .color: return .color
                }
            }()
            acc[rendition.name] = kind
        }

        // CARHEADER block
        let header = CARHeaderBlock.data(renditionCount: UInt32(renditions.count))
        let headerBlockID = bom.addBlock(header)

        // RENDITIONS tree (packed key tuple -> CSI bytes)
        let renditionEntries: [BOMTree.Entry] = renditions.map { rendition in
            let key = RenditionKey(rendition: rendition).encode()
            let value: Data
            switch rendition.body {
            case .bitmap(let body):
                let scaleFactor = UInt32(rendition.scale?.factor ?? 1) * 100
                value = CSIWriter.bitmap(name: rendition.name, body: body, scaleFactor: scaleFactor)
            case .color(let body):
                value = CSIWriter.color(name: rendition.name, body: body)
            }
            return BOMTree.Entry(key: key, value: value)
        }
        let renditionsTreeID = BOMTree.insert(into: &bom, entries: renditionEntries)

        // FACETKEYS tree (asset name -> attribute pairs)
        let facetEntries = kindForName.keys.sorted().map { name in
            BOMTree.Entry(
                key: Data(name.utf8),
                value: FacetKeys.value(for: name, kind: kindForName[name]!)
            )
        }
        let facetTreeID = BOMTree.insert(into: &bom, entries: facetEntries)

        // APPEARANCEKEYS tree
        let appearanceTreeID = BOMTree.insert(into: &bom, entries: AppearanceKeys.entries())

        // KEYFORMAT block
        let kfmt = KeyFormatBlock.data()
        let kfmtBlockID = bom.addBlock(kfmt)

        // EXTENDED_METADATA block
        let extendedMetadata = ExtendedMetadata.data(deploymentTarget: deploymentTarget)
        let extendedMetadataBlockID = bom.addBlock(extendedMetadata)

        // BITMAPKEYS tree -- per-asset bitmap descriptors keyed by
        // inline NameIdentifier. Required for UIImage(named:) lookup of
        // generic `.imageset` assets at runtime.
        let bitmapAssets: [(name: String, descriptor: BitmapKeys.Descriptor)] =
            kindForName.keys.sorted().compactMap { name -> (String, BitmapKeys.Descriptor)? in
                guard let kind = kindForName[name] else { return nil }
                if case .color = kind { return nil }
                let renditionsForName = renditions.filter { $0.name == name }
                let idiomSubtypes = Set(renditionsForName.map { rendition -> UInt32 in
                    let idiom = UInt32(rendition.idiom.rawValueByte)
                    let subtype: UInt32 = 0
                    return (idiom << 16) | subtype
                })
                let descKind: BitmapKeys.Descriptor.Kind = {
                    switch kind {
                    case .appIcon: return .appIcon
                    case .image: return .image
                    case .color: return .image
                    }
                }()
                return (name, BitmapKeys.Descriptor(
                    kind: descKind,
                    idiomSubtypeCount: UInt32(idiomSubtypes.count)
                ))
            }
        let bitmapKeysTreeID: UInt32? = bitmapAssets.isEmpty ? nil : BOMTree.insertInlineKey(
            into: &bom,
            entries: BitmapKeys.entries(for: bitmapAssets),
            blockSize: 1024
        )

        // Canonical vars table order. Matches actool's reference output.
        bom.setVariable("CARHEADER", blockID: headerBlockID)
        bom.setVariable("RENDITIONS", blockID: renditionsTreeID)
        bom.setVariable("FACETKEYS", blockID: facetTreeID)
        bom.setVariable("APPEARANCEKEYS", blockID: appearanceTreeID)
        bom.setVariable("KEYFORMAT", blockID: kfmtBlockID)
        bom.setVariable("EXTENDED_METADATA", blockID: extendedMetadataBlockID)
        if let bitmapKeysTreeID {
            bom.setVariable("BITMAPKEYS", blockID: bitmapKeysTreeID)
        }

        return bom.finalize()
    }
}
