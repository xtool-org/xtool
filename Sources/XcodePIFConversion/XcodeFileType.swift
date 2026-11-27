// swiftlint:disable file_length

import Foundation
import XcodeProjects
import XPIF

/// An Xcode file type (e.g. `sourcecode.swift`), along with everything xtool knows about how Xcode treats it.
///
/// This is the single source of truth for file type identifiers: other code refers to the constants declared
/// here (or resolves identifiers read from a project with ``init(identifier:)``) rather than spelling them out.
/// The data mirrors what `xcodebuild -dumpPIF` reports. Xcode also inspects file contents (e.g. Mach-O headers,
/// XML plists, shebangs); we only use names, so binaries are typed by their conventional extension.
struct XcodeFileType: Hashable, Sendable, CustomStringConvertible {
    let identifier: String
    /// The identifier of the type this one is based on, if any.
    let parentIdentifier: String?

    /// File names that have this type regardless of their extension.
    let fileNames: [String]
    /// Extensions of files that have this type. Matched exactly first (e.g. `.H` is C++), then case-insensitively.
    let fileExtensions: [String]
    /// Extensions of directories that have this type.
    let directoryExtensions: [String]

    /// The kinds of build phase that a synchronized folder member of this type can implicitly join.
    /// `nil` defers to the parent type.
    let implicitPhases: Set<XCSchema.BuildPhase.Kind>?
    /// Whether a synchronized folder member of this type (or a subtype) joins the target's Resources phase
    /// when no other phase accepts it.
    let fallsBackToResources: Bool
    /// Whether this type (or a subtype) refers to another project, and so never joins a target.
    let isProjectReference: Bool
    /// The code generation visibility Xcode records for a source of this type that doesn't specify one.
    /// `nil` defers to the parent type; types without one don't generate code.
    let defaultGeneratedCodeVisibility: XPIF.BuildFile.GeneratedCodeVisibility?
    /// The language that sources of exactly this type count towards when picking a target's predominant language.
    let sourceCodeLanguage: String?
    /// Whether files of exactly this type need their text encoding spelled out, since Swift Build can't
    /// autodetect it on Linux.
    let requiresExplicitTextEncoding: Bool

    fileprivate init(
        _ identifier: String,
        basedOn parent: XcodeFileType?? = nil,
        fileNames: [String] = [],
        extensions: [String] = [],
        fileExtensions: [String] = [],
        directoryExtensions: [String] = [],
        implicitPhases: Set<XCSchema.BuildPhase.Kind>? = nil,
        fallsBackToResources: Bool = false,
        isProjectReference: Bool = false,
        defaultGeneratedCodeVisibility: XPIF.BuildFile.GeneratedCodeVisibility? = nil,
        sourceCodeLanguage: String? = nil,
        requiresExplicitTextEncoding: Bool = false
    ) {
        self.identifier = identifier
        switch parent {
        case .some(let parent):
            // An explicit parent, or `.some(nil)` for a root type.
            self.parentIdentifier = parent?.identifier
        case .none:
            // By default, a type is based on its identifier with the last component dropped.
            self.parentIdentifier = identifier.lastIndex(of: ".").map { String(identifier[..<$0]) }
        }
        self.fileNames = fileNames
        self.fileExtensions = extensions + fileExtensions
        self.directoryExtensions = extensions + directoryExtensions
        self.implicitPhases = implicitPhases
        self.fallsBackToResources = fallsBackToResources
        self.isProjectReference = isProjectReference
        self.defaultGeneratedCodeVisibility = defaultGeneratedCodeVisibility
        self.sourceCodeLanguage = sourceCodeLanguage
        self.requiresExplicitTextEncoding = requiresExplicitTextEncoding
    }

    /// The known type with this identifier, or an otherwise unknown type.
    init(identifier: String) {
        self = Self.byIdentifier[identifier] ?? Self(identifier)
    }

    init(_ fileTypeID: XCSchema.FileTypeID) {
        self.init(identifier: fileTypeID.rawValue)
    }

    var fileTypeID: XCSchema.FileTypeID {
        .init(rawValue: identifier)
    }

    var description: String {
        identifier
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.identifier == rhs.identifier
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(identifier)
    }
}

// MARK: - Hierarchy

extension XcodeFileType {
    var parent: XcodeFileType? {
        parentIdentifier.map(XcodeFileType.init(identifier:))
    }

    /// The type followed by each of the types it's based on, most specific first.
    var ancestry: some Sequence<XcodeFileType> {
        sequence(first: self) { $0.parent }
    }

    func conforms(to other: XcodeFileType) -> Bool {
        ancestry.contains(other)
    }

    /// The value of `property` for the most specific type in the ancestry that declares one.
    func inherited<Value>(_ property: KeyPath<XcodeFileType, Value?>) -> Value? {
        ancestry.lazy.compactMap { $0[keyPath: property] }.first
    }
}

// MARK: - Detection

extension XcodeFileType {
    static func forFile(named name: String) -> XcodeFileType? {
        if let type = byFileName[name] {
            return type
        }
        return lookup((name as NSString).pathExtension, in: byFileExtension)
    }

    static func forDirectory(named name: String) -> XcodeFileType? {
        lookup((name as NSString).pathExtension, in: byDirectoryExtension)
    }

    /// Detects the type of the item at `url`. Items that can't be found on disk (e.g. SDK frameworks
    /// when cross-compiling, or not-yet-built products) are typed by name alone.
    static func forItem(at url: URL?, named name: String) -> XcodeFileType? {
        var directory = ObjCBool(false)
        guard let url, FileManager.default.fileExists(atPath: url.path, isDirectory: &directory) else {
            return forFile(named: name) ?? forDirectory(named: name)
        }
        return directory.boolValue ? forDirectory(named: name) : forFile(named: name)
    }

    private static func lookup(_ pathExtension: String, in table: [String: XcodeFileType]) -> XcodeFileType? {
        guard !pathExtension.isEmpty else {
            return nil
        }
        return table[pathExtension] ?? table[pathExtension.lowercased()]
    }

    private static let byIdentifier = index(\.identifier)
    private static let byFileName = index(\.fileNames)
    private static let byFileExtension = index(\.fileExtensions)
    private static let byDirectoryExtension = index(\.directoryExtensions)

    private static func index(_ keys: KeyPath<XcodeFileType, String>) -> [String: XcodeFileType] {
        Dictionary(uniqueKeysWithValues: all.map { ($0[keyPath: keys], $0) })
    }

    private static func index(_ keys: KeyPath<XcodeFileType, [String]>) -> [String: XcodeFileType] {
        Dictionary(uniqueKeysWithValues: all.flatMap { type in
            type[keyPath: keys].map { ($0, type) }
        })
    }
}

// MARK: - Known Types

@CollectXcodeFileTypes
extension XcodeFileType {
    // MARK: - archive
    static let archive = XcodeFileType(
        "archive",
        basedOn: .file
    )
    static let archiveAr = XcodeFileType(
        "archive.ar",
        fileExtensions: ["a", "lib"],
        implicitPhases: [.frameworks]
    )
    static let archiveAsdictionary = XcodeFileType(
        "archive.asdictionary",
        extensions: ["asdictionary"]
    )
    static let archiveBinhex = XcodeFileType(
        "archive.binhex",
        extensions: ["hqx"]
    )
    static let archiveEar = XcodeFileType(
        "archive.ear",
        basedOn: .archiveJar,
        extensions: ["ear"]
    )
    static let archiveGzip = XcodeFileType(
        "archive.gzip",
        extensions: ["gz"]
    )
    static let archiveJar = XcodeFileType(
        "archive.jar",
        basedOn: .archiveZip,
        extensions: ["jar"],
        implicitPhases: [.frameworks]
    )
    static let archiveMacbinary = XcodeFileType(
        "archive.macbinary",
        extensions: ["bin"]
    )
    static let archiveMetalLibrary = XcodeFileType(
        "archive.metal-library",
        extensions: ["metallib"],
        fallsBackToResources: true
    )
    static let archivePpob = XcodeFileType(
        "archive.ppob",
        basedOn: .archiveRsrc,
        extensions: ["ppob"]
    )
    static let archiveRsrc = XcodeFileType(
        "archive.rsrc",
        extensions: ["rsrc", "view"],
        implicitPhases: [.rez],
        fallsBackToResources: true
    )
    static let archiveStuffit = XcodeFileType(
        "archive.stuffit",
        extensions: ["sit"]
    )
    static let archiveTar = XcodeFileType(
        "archive.tar",
        extensions: ["tar"]
    )
    static let archiveWar = XcodeFileType(
        "archive.war",
        basedOn: .archiveJar,
        extensions: ["war"]
    )
    static let archiveZip = XcodeFileType(
        "archive.zip",
        extensions: ["zip"]
    )

    // MARK: - audio
    static let audio = XcodeFileType(
        "audio",
        basedOn: .file
    )
    static let audioAiff = XcodeFileType(
        "audio.aiff",
        extensions: ["aiff", "cdda"]
    )
    static let audioAu = XcodeFileType(
        "audio.au",
        extensions: ["au"]
    )
    static let audioMidi = XcodeFileType(
        "audio.midi",
        extensions: ["mid", "midi"]
    )
    static let audioMp3 = XcodeFileType(
        "audio.mp3",
        extensions: ["mp3"]
    )
    static let audioWav = XcodeFileType(
        "audio.wav",
        extensions: ["wav"]
    )

    // MARK: - com
    static let comAppleInstrumentsInstrdst = XcodeFileType(
        "com.apple.instruments.instrdst",
        basedOn: .wrapper,
        directoryExtensions: ["instrdst"]
    )
    static let comAppleInstrumentsPackageDefinition = XcodeFileType(
        "com.apple.instruments.package-definition",
        basedOn: .textXml,
        fileExtensions: ["instrpkg"]
    )

    // MARK: - compiled
    static let compiled = XcodeFileType(
        "compiled",
        basedOn: .file
    )
    static let compiledAir = XcodeFileType(
        "compiled.air",
        extensions: ["air"]
    )
    static let compiledJavaclass = XcodeFileType(
        "compiled.javaclass",
        extensions: ["class"]
    )
    static let compiledMachO = XcodeFileType("compiled.mach-o")
    static let compiledMachODylib = XcodeFileType(
        "compiled.mach-o.dylib",
        fileExtensions: ["dll", "dylib"],
        implicitPhases: [.frameworks]
    )
    static let compiledMachOObjfile = XcodeFileType(
        "compiled.mach-o.objfile",
        fileExtensions: ["o"],
        implicitPhases: [.frameworks]
    )
    static let compiledObjectLibrary = XcodeFileType(
        "compiled.object-library",
        basedOn: .compiledMachO,
        directoryExtensions: ["o"]
    )
    static let compiledRcx = XcodeFileType(
        "compiled.rcx",
        extensions: ["rcx"]
    )

    // MARK: - file
    static let file = XcodeFileType("file")
    static let fileIntentdefinition = XcodeFileType(
        "file.intentdefinition",
        basedOn: .sourcecode,
        fileExtensions: ["intentdefinition"],
        fallsBackToResources: true,
        defaultGeneratedCodeVisibility: .public
    )
    static let fileMlmodel = XcodeFileType(
        "file.mlmodel",
        basedOn: .sourcecode,
        fileExtensions: ["mlkitmodel", "mlmodel"],
        defaultGeneratedCodeVisibility: .project
    )
    static let filePlayground = XcodeFileType(
        "file.playground",
        basedOn: .wrapper,
        directoryExtensions: ["playground"],
        implicitPhases: []
    )
    static let fileReferenceobject = XcodeFileType(
        "file.referenceobject",
        basedOn: .sourcecode,
        fileExtensions: ["referenceobject"],
        implicitPhases: [.sources]
    )
    static let fileScp = XcodeFileType(
        "file.scp",
        extensions: ["scnp"]
    )
    static let fileSks = XcodeFileType(
        "file.sks",
        extensions: ["sks"]
    )
    static let fileSkybox = XcodeFileType(
        "file.skybox",
        extensions: ["skybox"]
    )
    static let fileStoryboard = XcodeFileType(
        "file.storyboard",
        extensions: ["storyboard"]
    )
    static let fileSwiftpmManifest = XcodeFileType(
        "file.swiftpm-manifest",
        basedOn: .sourcecodeSwift,
        isProjectReference: true
    )
    static let fileUicatalog = XcodeFileType(
        "file.uicatalog",
        extensions: ["uicatalog"]
    )
    static let fileXcplaygroundpage = XcodeFileType(
        "file.xcplaygroundpage",
        basedOn: .wrapper,
        directoryExtensions: ["xcplaygroundpage"]
    )
    static let fileXib = XcodeFileType(
        "file.xib",
        extensions: ["xib"]
    )

    // MARK: - folder
    static let folder = XcodeFileType("folder")
    static let folderAbstractassetcatalog = XcodeFileType(
        "folder.abstractassetcatalog",
        basedOn: .wrapper
    )
    static let folderAimodel = XcodeFileType(
        "folder.aimodel",
        basedOn: .wrapper,
        directoryExtensions: ["aimodel"],
        implicitPhases: [.sources]
    )
    static let folderAssetcatalog = XcodeFileType(
        "folder.assetcatalog",
        basedOn: .folderAbstractassetcatalog,
        directoryExtensions: ["xcassets"]
    )
    static let folderDocumentationcatalog = XcodeFileType(
        "folder.documentationcatalog",
        basedOn: .wrapper,
        directoryExtensions: ["docc"],
        implicitPhases: [.sources]
    )
    static let folderFmadapter = XcodeFileType(
        "folder.fmadapter",
        implicitPhases: [.sources]
    )
    static let folderIconcomposerIcon = XcodeFileType(
        "folder.iconcomposer.icon",
        basedOn: .folderAbstractassetcatalog,
        directoryExtensions: ["icon"]
    )
    static let folderIconset = XcodeFileType(
        "folder.iconset",
        basedOn: .wrapper,
        directoryExtensions: ["iconset"]
    )
    static let folderImagecatalog = XcodeFileType(
        "folder.imagecatalog",
        basedOn: .folderAssetcatalog,
        directoryExtensions: ["imagecatalog"]
    )
    static let folderMlasset = XcodeFileType(
        "folder.mlasset",
        implicitPhases: [.sources]
    )
    static let folderMlpackage = XcodeFileType(
        "folder.mlpackage",
        basedOn: .wrapper,
        directoryExtensions: ["mlpackage"],
        implicitPhases: [.sources],
        defaultGeneratedCodeVisibility: .project
    )
    static let folderRkassets = XcodeFileType(
        "folder.rkassets",
        basedOn: .some(nil),
        directoryExtensions: ["rkassets"]
    )
    static let folderSkatlas = XcodeFileType(
        "folder.skatlas",
        basedOn: .wrapper,
        directoryExtensions: ["atlas"]
    )
    static let folderStickers = XcodeFileType(
        "folder.stickers",
        basedOn: .folderAbstractassetcatalog,
        directoryExtensions: ["xcstickers"]
    )

    // MARK: - image
    static let image = XcodeFileType(
        "image",
        basedOn: .file
    )
    static let imageBmp = XcodeFileType(
        "image.bmp",
        extensions: ["bmp"]
    )
    static let imageGif = XcodeFileType(
        "image.gif",
        extensions: ["gif"]
    )
    static let imageIcns = XcodeFileType(
        "image.icns",
        extensions: ["icns"]
    )
    static let imageIco = XcodeFileType(
        "image.ico",
        extensions: ["ico"]
    )
    static let imageJpeg = XcodeFileType(
        "image.jpeg",
        extensions: ["jpeg", "jpg"]
    )
    static let imagePdf = XcodeFileType(
        "image.pdf",
        extensions: ["pdf"]
    )
    static let imagePict = XcodeFileType(
        "image.pict",
        extensions: ["pct", "pict"]
    )
    static let imagePng = XcodeFileType(
        "image.png",
        extensions: ["png"]
    )
    static let imageTiff = XcodeFileType(
        "image.tiff",
        extensions: ["tif", "tiff"]
    )

    // MARK: - net
    static let netDaringfireballMarkdown = XcodeFileType(
        "net.daringfireball.markdown",
        basedOn: .sourcecode,
        fileExtensions: ["markdown", "md", "mdown", "text"],
        implicitPhases: [.resources],
        sourceCodeLanguage: "Markdown"
    )

    // MARK: - sourcecode
    static let sourcecode = XcodeFileType(
        "sourcecode",
        basedOn: .text,
        implicitPhases: [.sources]
    )
    static let sourcecodeAda = XcodeFileType(
        "sourcecode.ada",
        fileExtensions: ["ada", "adb", "ads"]
    )
    static let sourcecodeApplescript = XcodeFileType(
        "sourcecode.applescript",
        fileExtensions: ["applescript"],
        implicitPhases: [.sources, .appleScript]
    )
    static let sourcecodeAsm = XcodeFileType(
        "sourcecode.asm",
        fileExtensions: ["s"]
    )
    static let sourcecodeAsmAsm = XcodeFileType(
        "sourcecode.asm.asm",
        fileExtensions: ["asm"]
    )
    static let sourcecodeAsmLlvm = XcodeFileType(
        "sourcecode.asm.llvm",
        basedOn: .sourcecode,
        fileExtensions: ["ll", "llx"]
    )
    static let sourcecodeC = XcodeFileType("sourcecode.c")
    static let sourcecodeCC = XcodeFileType(
        "sourcecode.c.c",
        fileExtensions: ["c"],
        sourceCodeLanguage: "C"
    )
    static let sourcecodeCCPreprocessed = XcodeFileType(
        "sourcecode.c.c.preprocessed",
        fileExtensions: ["i"]
    )
    static let sourcecodeCH = XcodeFileType(
        "sourcecode.c.h",
        fileExtensions: ["h", "pch"],
        implicitPhases: [.headers],
        sourceCodeLanguage: "Objective-C-Plus-Plus"
    )
    static let sourcecodeCObjc = XcodeFileType(
        "sourcecode.c.objc",
        fileExtensions: ["m"],
        sourceCodeLanguage: "Objective-C"
    )
    static let sourcecodeCObjcPreprocessed = XcodeFileType(
        "sourcecode.c.objc.preprocessed",
        fileExtensions: ["mi"]
    )
    static let sourcecodeClips = XcodeFileType(
        "sourcecode.clips",
        fileExtensions: ["clp"]
    )
    static let sourcecodeCpp = XcodeFileType(
        "sourcecode.cpp",
        basedOn: .sourcecodeC
    )
    static let sourcecodeCppCpp = XcodeFileType(
        "sourcecode.cpp.cpp",
        fileExtensions: ["C", "c++", "cc", "cp", "cpp", "cxx", "tcc"],
        sourceCodeLanguage: "C-Plus-Plus"
    )
    static let sourcecodeCppCppPreprocessed = XcodeFileType(
        "sourcecode.cpp.cpp.preprocessed",
        fileExtensions: ["ii"]
    )
    static let sourcecodeCppH = XcodeFileType(
        "sourcecode.cpp.h",
        fileExtensions: ["H", "h++", "hh", "hp", "hpp", "hxx", "ipp", "pch++"],
        implicitPhases: [.headers],
        sourceCodeLanguage: "Objective-C-Plus-Plus"
    )
    static let sourcecodeCppObjcpp = XcodeFileType(
        "sourcecode.cpp.objcpp",
        fileExtensions: ["M", "mm"],
        sourceCodeLanguage: "Objective-C-Plus-Plus"
    )
    static let sourcecodeCppObjcppPreprocessed = XcodeFileType(
        "sourcecode.cpp.objcpp.preprocessed",
        fileExtensions: ["mii"]
    )
    static let sourcecodeDtrace = XcodeFileType(
        "sourcecode.dtrace",
        fileExtensions: ["d"]
    )
    static let sourcecodeDylan = XcodeFileType(
        "sourcecode.dylan",
        fileExtensions: ["dylan", "lid"]
    )
    static let sourcecodeExports = XcodeFileType(
        "sourcecode.exports",
        fileExtensions: ["exp"]
    )
    static let sourcecodeFortran = XcodeFileType(
        "sourcecode.fortran",
        fileExtensions: ["f", "for"]
    )
    static let sourcecodeFortranF77 = XcodeFileType(
        "sourcecode.fortran.f77",
        fileExtensions: ["f77"]
    )
    static let sourcecodeFortranF90 = XcodeFileType(
        "sourcecode.fortran.f90",
        fileExtensions: ["f90", "f95"]
    )
    static let sourcecodeGlsl = XcodeFileType(
        "sourcecode.glsl",
        fileExtensions: [
            "ctrl",
            "eval",
            "frag",
            "fragment",
            "fs",
            "fsh",
            "geom",
            "geometry",
            "gs",
            "gsh",
            "vert",
            "vertex",
            "vs",
            "vsh",
        ],
        implicitPhases: [.resources]
    )
    static let sourcecodeIig = XcodeFileType(
        "sourcecode.iig",
        basedOn: .sourcecodeC,
        fileExtensions: ["iig"]
    )
    static let sourcecodeJava = XcodeFileType(
        "sourcecode.java",
        fileExtensions: ["java"]
    )
    static let sourcecodeJavascript = XcodeFileType(
        "sourcecode.javascript",
        fileExtensions: ["javascript", "js", "jscript"],
        implicitPhases: [.resources]
    )
    static let sourcecodeLex = XcodeFileType(
        "sourcecode.lex",
        fileExtensions: ["l", "lm", "lmm", "lp", "lpp", "lxx"]
    )
    static let sourcecodeMake = XcodeFileType(
        "sourcecode.make",
        fileNames: ["Makefile", "makefile"],
        fileExtensions: ["gmk", "mak", "make"]
    )
    static let sourcecodeMetal = XcodeFileType(
        "sourcecode.metal",
        fileExtensions: ["metal"]
    )
    static let sourcecodeMig = XcodeFileType(
        "sourcecode.mig",
        fileExtensions: ["defs", "mig"]
    )
    static let sourcecodeModuleMap = XcodeFileType(
        "sourcecode.module-map",
        fileExtensions: ["map", "modulemap"],
        implicitPhases: []
    )
    static let sourcecodeNasm = XcodeFileType(
        "sourcecode.nasm",
        fileExtensions: ["nasm"]
    )
    static let sourcecodeNqc = XcodeFileType(
        "sourcecode.nqc",
        fileExtensions: ["nqc"]
    )
    static let sourcecodeOpencl = XcodeFileType(
        "sourcecode.opencl",
        fileExtensions: ["cl"]
    )
    static let sourcecodePascal = XcodeFileType(
        "sourcecode.pascal",
        fileExtensions: ["inc", "p", "pas", "pp"]
    )
    static let sourcecodeProtobuf = XcodeFileType(
        "sourcecode.protobuf",
        fileExtensions: ["proto"]
    )
    static let sourcecodeRez = XcodeFileType(
        "sourcecode.rez",
        fileExtensions: ["r", "rez"],
        implicitPhases: [.rez]
    )
    static let sourcecodeScpt = XcodeFileType(
        "sourcecode.scpt",
        implicitPhases: [.appleScript]
    )
    static let sourcecodeSwift = XcodeFileType(
        "sourcecode.swift",
        fileExtensions: ["swift"],
        sourceCodeLanguage: "Swift"
    )
    static let sourcecodeTextBasedDylibDefinition = XcodeFileType(
        "sourcecode.text-based-dylib-definition",
        fileExtensions: ["tbd"],
        implicitPhases: [.frameworks]
    )
    static let sourcecodeTypescript = XcodeFileType(
        "sourcecode.typescript",
        fileExtensions: ["ts", "tsx"],
        implicitPhases: []
    )
    static let sourcecodeYacc = XcodeFileType(
        "sourcecode.yacc",
        fileExtensions: ["y", "ym", "ymm", "yp", "ypp", "yxx", "yy"]
    )

    // MARK: - text
    static let text = XcodeFileType(
        "text",
        basedOn: .file,
        fileExtensions: ["txt"]
    )
    static let textApinotes = XcodeFileType(
        "text.apinotes",
        basedOn: .textYaml,
        fileExtensions: ["apinotes"],
        implicitPhases: [.headers]
    )
    static let textCss = XcodeFileType(
        "text.css",
        fileExtensions: ["css"]
    )
    static let textHtml = XcodeFileType(
        "text.html",
        fileExtensions: ["htm", "html"]
    )
    static let textHtmlOther = XcodeFileType(
        "text.html.other",
        fileExtensions: ["jsp", "rhtml", "shtml"]
    )
    static let textJson = XcodeFileType(
        "text.json",
        fileExtensions: ["json"]
    )
    static let textJsonXcstrings = XcodeFileType(
        "text.json.xcstrings",
        fileExtensions: ["xcstrings"]
    )
    static let textMan = XcodeFileType(
        "text.man",
        fileExtensions: ["1"]
    )
    static let textPbxproject = XcodeFileType(
        "text.pbxproject",
        fileNames: ["project.pbxproj"],
        fileExtensions: ["pbxproj"]
    )
    static let textPlist = XcodeFileType(
        "text.plist",
        fileExtensions: ["dict"]
    )
    static let textPlistAppPrivacy = XcodeFileType(
        "text.plist.app-privacy",
        fileExtensions: ["privacy"]
    )
    static let textPlistEntitlements = XcodeFileType(
        "text.plist.entitlements",
        fileExtensions: ["entitlements"],
        implicitPhases: []
    )
    static let textPlistIbClassDescription = XcodeFileType(
        "text.plist.ibClassDescription",
        fileExtensions: ["classdescription", "classdescriptions"]
    )
    static let textPlistInfo = XcodeFileType(
        "text.plist.info",
        basedOn: .textPlistXml
    )
    static let textPlistPbfilespec = XcodeFileType(
        "text.plist.pbfilespec",
        fileExtensions: ["pbfilespec"]
    )
    static let textPlistPblangspec = XcodeFileType(
        "text.plist.pblangspec",
        fileExtensions: ["pblangspec"]
    )
    static let textPlistScriptSuite = XcodeFileType(
        "text.plist.scriptSuite",
        fileExtensions: ["scriptSuite"]
    )
    static let textPlistScriptTerminology = XcodeFileType(
        "text.plist.scriptTerminology",
        fileExtensions: ["scriptTerminology"]
    )
    static let textPlistStrings = XcodeFileType(
        "text.plist.strings",
        basedOn: .text,
        fileExtensions: ["strings"],
        requiresExplicitTextEncoding: true
    )
    static let textPlistStringsdict = XcodeFileType(
        "text.plist.stringsdict",
        basedOn: .text,
        fileExtensions: ["stringsdict"]
    )
    static let textPlistVocabulary = XcodeFileType(
        "text.plist.vocabulary",
        basedOn: .textPlistXml,
        fileNames: ["AppIntents.vocabulary"]
    )
    static let textPlistXcappextensionpoints = XcodeFileType(
        "text.plist.xcappextensionpoints",
        fileExtensions: ["xcappextensionpoints"]
    )
    static let textPlistXcbuildrules = XcodeFileType(
        "text.plist.xcbuildrules",
        fileExtensions: ["xcbuildrules"]
    )
    static let textPlistXclangspec = XcodeFileType(
        "text.plist.xclangspec",
        fileExtensions: ["xclangspec"]
    )
    static let textPlistXcspec = XcodeFileType(
        "text.plist.xcspec",
        fileExtensions: ["xcspec"]
    )
    static let textPlistXcsynspec = XcodeFileType(
        "text.plist.xcsynspec",
        fileExtensions: ["xcsynspec"]
    )
    static let textPlistXctxtmacro = XcodeFileType(
        "text.plist.xctxtmacro",
        fileExtensions: ["xctxtmacro"]
    )
    static let textPlistXml = XcodeFileType(
        "text.plist.xml",
        fileExtensions: ["plist"]
    )
    static let textRtf = XcodeFileType(
        "text.rtf",
        fileExtensions: ["rtf"]
    )
    static let textScriptCsh = XcodeFileType(
        "text.script.csh",
        fileExtensions: ["csh"]
    )
    static let textScriptPerl = XcodeFileType(
        "text.script.perl",
        fileExtensions: ["perl", "pl", "pm"]
    )
    static let textScriptPhp = XcodeFileType(
        "text.script.php",
        fileExtensions: ["php", "php3", "php4", "phtml"]
    )
    static let textScriptPython = XcodeFileType(
        "text.script.python",
        fileExtensions: ["py"]
    )
    static let textScriptRuby = XcodeFileType(
        "text.script.ruby",
        fileExtensions: ["rb", "rbw"]
    )
    static let textScriptSh = XcodeFileType(
        "text.script.sh",
        fileExtensions: ["sh"]
    )
    static let textScriptWorksheet = XcodeFileType(
        "text.script.worksheet",
        fileExtensions: ["worksheet"]
    )
    static let textXcconfig = XcodeFileType(
        "text.xcconfig",
        fileExtensions: ["xcconfig"]
    )
    static let textXcfilelist = XcodeFileType(
        "text.xcfilelist",
        fileExtensions: ["xcfilelist"]
    )
    static let textXml = XcodeFileType(
        "text.xml",
        fileExtensions: ["dtd", "xconf", "xhtml", "xmap", "xml", "xsl", "xslt", "xsp"]
    )
    static let textXmlDae = XcodeFileType(
        "text.xml.dae",
        fileExtensions: ["dae"]
    )
    static let textXmlIbArchivingDescription = XcodeFileType(
        "text.xml.ibArchivingDescription",
        fileExtensions: ["archivingdescription"],
        implicitPhases: [.sources]
    )
    static let textXmlIbCodingDescription = XcodeFileType(
        "text.xml.ibCodingDescription",
        implicitPhases: [.sources]
    )
    static let textYaml = XcodeFileType(
        "text.yaml",
        fileExtensions: ["yaml", "yml"]
    )

    // MARK: - video
    static let video = XcodeFileType(
        "video",
        basedOn: .file
    )
    static let videoAvi = XcodeFileType(
        "video.avi",
        extensions: ["avi"]
    )
    static let videoMpeg = XcodeFileType(
        "video.mpeg",
        extensions: ["mpeg", "mpg"]
    )
    static let videoQuartzComposer = XcodeFileType(
        "video.quartz-composer",
        extensions: ["qtz"]
    )
    static let videoQuicktime = XcodeFileType(
        "video.quicktime",
        extensions: ["moov", "mov"]
    )

    // MARK: - wrapper
    static let wrapper = XcodeFileType(
        "wrapper",
        basedOn: .folder,
        directoryExtensions: ["fs"]
    )
    static let wrapperAppExtension = XcodeFileType(
        "wrapper.app-extension",
        basedOn: .wrapperXpcService,
        directoryExtensions: ["pluginkit"]
    )
    static let wrapperApplication = XcodeFileType(
        "wrapper.application",
        basedOn: .wrapperCfbundle,
        directoryExtensions: ["app"]
    )
    static let wrapperArtifactbundle = XcodeFileType(
        "wrapper.artifactbundle",
        directoryExtensions: ["artifactbundle"]
    )
    static let wrapperCfbundle = XcodeFileType("wrapper.cfbundle")
    static let wrapperDriverExtension = XcodeFileType(
        "wrapper.driver-extension",
        basedOn: .wrapperSystemExtension,
        directoryExtensions: ["dext"]
    )
    static let wrapperDsym = XcodeFileType(
        "wrapper.dsym",
        directoryExtensions: ["dSYM", "dsym"]
    )
    static let wrapperExtensionkitExtension = XcodeFileType(
        "wrapper.extensionkit-extension",
        basedOn: .wrapperAppExtension,
        directoryExtensions: ["appex"]
    )
    static let wrapperFramework = XcodeFileType(
        "wrapper.framework",
        basedOn: .wrapperCfbundle,
        directoryExtensions: ["framework"],
        implicitPhases: [.frameworks]
    )
    static let wrapperHtmld = XcodeFileType(
        "wrapper.htmld",
        directoryExtensions: ["htmld"]
    )
    static let wrapperInstallerMpkg = XcodeFileType(
        "wrapper.installer-mpkg",
        directoryExtensions: ["mpkg"]
    )
    static let wrapperInstallerPkg = XcodeFileType(
        "wrapper.installer-pkg",
        directoryExtensions: ["pkg"]
    )
    static let wrapperKernelExtension = XcodeFileType(
        "wrapper.kernel-extension",
        basedOn: .wrapperPlugIn,
        directoryExtensions: ["kext"]
    )
    static let wrapperNib = XcodeFileType(
        "wrapper.nib",
        directoryExtensions: ["nib"]
    )
    static let wrapperPbProject = XcodeFileType(
        "wrapper.pb-project",
        directoryExtensions: ["xcode", "xcodeproj"],
        isProjectReference: true
    )
    static let wrapperPbTarget = XcodeFileType(
        "wrapper.pb-target",
        basedOn: .wrapperPbProject,
        directoryExtensions: ["xctarget"]
    )
    static let wrapperPlugIn = XcodeFileType(
        "wrapper.plug-in",
        basedOn: .wrapperCfbundle,
        directoryExtensions: ["bundle"]
    )
    static let wrapperRtfd = XcodeFileType(
        "wrapper.rtfd",
        directoryExtensions: ["rtfd"]
    )
    static let wrapperScnassets = XcodeFileType(
        "wrapper.scnassets",
        directoryExtensions: ["scnassets"]
    )
    static let wrapperScncache = XcodeFileType(
        "wrapper.scncache",
        directoryExtensions: ["scncache"]
    )
    static let wrapperSpotlightImporter = XcodeFileType(
        "wrapper.spotlight-importer",
        basedOn: .wrapperCfbundle,
        directoryExtensions: ["mdimporter"]
    )
    static let wrapperStoryboardc = XcodeFileType(
        "wrapper.storyboardc",
        extensions: ["storyboardc"]
    )
    static let wrapperSystemExtension = XcodeFileType(
        "wrapper.system-extension",
        basedOn: .wrapperPlugIn,
        directoryExtensions: ["systemextension"]
    )
    static let wrapperWorkspace = XcodeFileType(
        "wrapper.workspace",
        directoryExtensions: ["xcworkspace"]
    )
    static let wrapperXcclassmodel = XcodeFileType(
        "wrapper.xcclassmodel",
        directoryExtensions: ["xcclassmodel"]
    )
    static let wrapperXcdatamodel = XcodeFileType(
        "wrapper.xcdatamodel",
        basedOn: .sourcecode,
        extensions: ["xcdatamodel"]
    )
    static let wrapperXcdatamodeld = XcodeFileType(
        "wrapper.xcdatamodeld",
        basedOn: .sourcecode,
        directoryExtensions: ["xcdatamodeld"]
    )
    static let wrapperXcframework = XcodeFileType(
        "wrapper.xcframework",
        directoryExtensions: ["xcframework"],
        implicitPhases: [.frameworks]
    )
    static let wrapperXcmappingmodel = XcodeFileType(
        "wrapper.xcmappingmodel",
        basedOn: .sourcecode,
        extensions: ["xcmappingmodel"]
    )
    static let wrapperXpcService = XcodeFileType(
        "wrapper.xpc-service",
        basedOn: .wrapperCfbundle,
        directoryExtensions: ["xpc"]
    )
}
