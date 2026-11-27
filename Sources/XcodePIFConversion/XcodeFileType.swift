import Foundation

/// Xcode's file type identifiers, as detected for files discovered in synchronized folders.
///
/// The tables mirror what `xcodebuild -dumpPIF` reports. Xcode also inspects file contents
/// (e.g. Mach-O headers, XML plists, shebangs); we only use names, so binaries are typed by
/// their conventional extension and unrecognized files are plain `file`s.
enum XcodeFileType {
    static func forFile(named name: String) -> String? {
        if let type = fileNames[name] { return type }
        return lookup((name as NSString).pathExtension, in: fileExtensions)
    }

    static func forDirectory(named name: String) -> String? {
        lookup((name as NSString).pathExtension, in: directoryExtensions)
    }

    /// Detects the type of the item at `url`. Items that can't be found on disk (e.g. SDK frameworks
    /// when cross-compiling, or not-yet-built products) are typed by name alone.
    static func forItem(at url: URL?, named name: String) -> String? {
        var directory = ObjCBool(false)
        guard let url, FileManager.default.fileExists(atPath: url.path, isDirectory: &directory) else {
            return forFile(named: name) ?? forDirectory(named: name)
        }
        return directory.boolValue ? forDirectory(named: name) : forFile(named: name)
    }

    /// The type followed by each of the types it's based on, most specific first.
    static func ancestry(of type: String) -> [String] {
        var result: [String] = []
        var current: String? = type
        while let type = current {
            result.append(type)
            if let parent = parents[type] {
                current = parent
            } else if let dot = type.lastIndex(of: ".") {
                current = String(type[..<dot])
            } else {
                current = nil
            }
        }
        return result
    }

    /// Extensions match exactly first (e.g. `.H` is C++), then case-insensitively.
    private static func lookup(_ pathExtension: String, in table: [String: String]) -> String? {
        guard !pathExtension.isEmpty else { return nil }
        return table[pathExtension] ?? table[pathExtension.lowercased()]
    }

    private static let fileNames: [String: String] = [
        "Makefile": "sourcecode.make", "makefile": "sourcecode.make",
        "AppIntents.vocabulary": "text.plist.vocabulary", "project.pbxproj": "text.pbxproject",
    ]

    private static let fileExtensions: [String: String] = [
        "a": "archive.ar", "lib": "archive.ar", "asdictionary": "archive.asdictionary", "hqx": "archive.binhex",
        "ear": "archive.ear", "gz": "archive.gzip", "jar": "archive.jar", "bin": "archive.macbinary",
        "metallib": "archive.metal-library", "ppob": "archive.ppob", "rsrc": "archive.rsrc", "view": "archive.rsrc",
        "sit": "archive.stuffit", "tar": "archive.tar", "war": "archive.war", "zip": "archive.zip",
        "aiff": "audio.aiff", "cdda": "audio.aiff", "au": "audio.au", "mid": "audio.midi", "midi": "audio.midi",
        "mp3": "audio.mp3", "wav": "audio.wav", "instrpkg": "com.apple.instruments.package-definition",
        "air": "compiled.air", "class": "compiled.javaclass", "dll": "compiled.mach-o.dylib",
        "dylib": "compiled.mach-o.dylib", "o": "compiled.mach-o.objfile", "rcx": "compiled.rcx",
        "intentdefinition": "file.intentdefinition", "mlkitmodel": "file.mlmodel", "mlmodel": "file.mlmodel",
        "referenceobject": "file.referenceobject", "scnp": "file.scp", "sks": "file.sks", "skybox": "file.skybox",
        "storyboard": "file.storyboard", "uicatalog": "file.uicatalog", "xib": "file.xib", "bmp": "image.bmp",
        "gif": "image.gif", "icns": "image.icns", "ico": "image.ico", "jpeg": "image.jpeg", "jpg": "image.jpeg",
        "pdf": "image.pdf", "pct": "image.pict", "pict": "image.pict", "png": "image.png", "tif": "image.tiff",
        "tiff": "image.tiff", "markdown": "net.daringfireball.markdown", "md": "net.daringfireball.markdown",
        "mdown": "net.daringfireball.markdown", "text": "net.daringfireball.markdown", "ada": "sourcecode.ada",
        "adb": "sourcecode.ada", "ads": "sourcecode.ada", "applescript": "sourcecode.applescript",
        "s": "sourcecode.asm", "asm": "sourcecode.asm.asm", "ll": "sourcecode.asm.llvm", "llx": "sourcecode.asm.llvm",
        "c": "sourcecode.c.c", "i": "sourcecode.c.c.preprocessed", "h": "sourcecode.c.h", "pch": "sourcecode.c.h",
        "m": "sourcecode.c.objc", "mi": "sourcecode.c.objc.preprocessed", "clp": "sourcecode.clips",
        "C": "sourcecode.cpp.cpp", "c++": "sourcecode.cpp.cpp", "cc": "sourcecode.cpp.cpp", "cp": "sourcecode.cpp.cpp",
        "cpp": "sourcecode.cpp.cpp", "cxx": "sourcecode.cpp.cpp", "tcc": "sourcecode.cpp.cpp",
        "ii": "sourcecode.cpp.cpp.preprocessed", "H": "sourcecode.cpp.h", "h++": "sourcecode.cpp.h",
        "hh": "sourcecode.cpp.h", "hp": "sourcecode.cpp.h", "hpp": "sourcecode.cpp.h", "hxx": "sourcecode.cpp.h",
        "ipp": "sourcecode.cpp.h", "pch++": "sourcecode.cpp.h", "M": "sourcecode.cpp.objcpp",
        "mm": "sourcecode.cpp.objcpp", "mii": "sourcecode.cpp.objcpp.preprocessed", "d": "sourcecode.dtrace",
        "dylan": "sourcecode.dylan", "lid": "sourcecode.dylan", "exp": "sourcecode.exports", "f": "sourcecode.fortran",
        "for": "sourcecode.fortran", "f77": "sourcecode.fortran.f77", "f90": "sourcecode.fortran.f90",
        "f95": "sourcecode.fortran.f90", "ctrl": "sourcecode.glsl", "eval": "sourcecode.glsl",
        "frag": "sourcecode.glsl", "fragment": "sourcecode.glsl", "fs": "sourcecode.glsl", "fsh": "sourcecode.glsl",
        "geom": "sourcecode.glsl", "geometry": "sourcecode.glsl", "gs": "sourcecode.glsl", "gsh": "sourcecode.glsl",
        "vert": "sourcecode.glsl", "vertex": "sourcecode.glsl", "vs": "sourcecode.glsl", "vsh": "sourcecode.glsl",
        "iig": "sourcecode.iig", "java": "sourcecode.java", "javascript": "sourcecode.javascript",
        "js": "sourcecode.javascript", "jscript": "sourcecode.javascript", "l": "sourcecode.lex",
        "lm": "sourcecode.lex", "lmm": "sourcecode.lex", "lp": "sourcecode.lex", "lpp": "sourcecode.lex",
        "lxx": "sourcecode.lex", "gmk": "sourcecode.make", "mak": "sourcecode.make", "make": "sourcecode.make",
        "metal": "sourcecode.metal", "defs": "sourcecode.mig", "mig": "sourcecode.mig", "map": "sourcecode.module-map",
        "modulemap": "sourcecode.module-map", "nasm": "sourcecode.nasm", "nqc": "sourcecode.nqc",
        "cl": "sourcecode.opencl", "inc": "sourcecode.pascal", "p": "sourcecode.pascal", "pas": "sourcecode.pascal",
        "pp": "sourcecode.pascal", "proto": "sourcecode.protobuf", "r": "sourcecode.rez", "rez": "sourcecode.rez",
        "swift": "sourcecode.swift", "tbd": "sourcecode.text-based-dylib-definition", "ts": "sourcecode.typescript",
        "tsx": "sourcecode.typescript", "y": "sourcecode.yacc", "ym": "sourcecode.yacc", "ymm": "sourcecode.yacc",
        "yp": "sourcecode.yacc", "ypp": "sourcecode.yacc", "yxx": "sourcecode.yacc", "yy": "sourcecode.yacc",
        "txt": "text", "apinotes": "text.apinotes", "css": "text.css", "htm": "text.html", "html": "text.html",
        "jsp": "text.html.other", "rhtml": "text.html.other", "shtml": "text.html.other", "json": "text.json",
        "xcstrings": "text.json.xcstrings", "1": "text.man", "pbxproj": "text.pbxproject", "dict": "text.plist",
        "privacy": "text.plist.app-privacy", "entitlements": "text.plist.entitlements",
        "classdescription": "text.plist.ibClassDescription", "classdescriptions": "text.plist.ibClassDescription",
        "pbfilespec": "text.plist.pbfilespec", "pblangspec": "text.plist.pblangspec",
        "scriptSuite": "text.plist.scriptSuite", "scriptTerminology": "text.plist.scriptTerminology",
        "strings": "text.plist.strings", "stringsdict": "text.plist.stringsdict",
        "xcappextensionpoints": "text.plist.xcappextensionpoints", "xcbuildrules": "text.plist.xcbuildrules",
        "xclangspec": "text.plist.xclangspec", "xcspec": "text.plist.xcspec", "xcsynspec": "text.plist.xcsynspec",
        "xctxtmacro": "text.plist.xctxtmacro", "plist": "text.plist.xml", "rtf": "text.rtf", "csh": "text.script.csh",
        "perl": "text.script.perl", "pl": "text.script.perl", "pm": "text.script.perl", "php": "text.script.php",
        "php3": "text.script.php", "php4": "text.script.php", "phtml": "text.script.php", "py": "text.script.python",
        "rb": "text.script.ruby", "rbw": "text.script.ruby", "sh": "text.script.sh",
        "worksheet": "text.script.worksheet", "xcconfig": "text.xcconfig", "xcfilelist": "text.xcfilelist",
        "dtd": "text.xml", "xconf": "text.xml", "xhtml": "text.xml", "xmap": "text.xml", "xml": "text.xml",
        "xsl": "text.xml", "xslt": "text.xml", "xsp": "text.xml", "dae": "text.xml.dae",
        "archivingdescription": "text.xml.ibArchivingDescription", "yaml": "text.yaml", "yml": "text.yaml",
        "avi": "video.avi", "mpeg": "video.mpeg", "mpg": "video.mpeg", "qtz": "video.quartz-composer",
        "moov": "video.quicktime", "mov": "video.quicktime", "storyboardc": "wrapper.storyboardc",
        "xcdatamodel": "wrapper.xcdatamodel", "xcmappingmodel": "wrapper.xcmappingmodel",
    ]

    private static let directoryExtensions: [String: String] = [
        "asdictionary": "archive.asdictionary", "hqx": "archive.binhex", "ear": "archive.ear", "gz": "archive.gzip",
        "jar": "archive.jar", "bin": "archive.macbinary", "metallib": "archive.metal-library", "ppob": "archive.ppob",
        "rsrc": "archive.rsrc", "view": "archive.rsrc", "sit": "archive.stuffit", "tar": "archive.tar",
        "war": "archive.war", "zip": "archive.zip", "aiff": "audio.aiff", "cdda": "audio.aiff", "au": "audio.au",
        "mid": "audio.midi", "midi": "audio.midi", "mp3": "audio.mp3", "wav": "audio.wav",
        "instrdst": "com.apple.instruments.instrdst", "air": "compiled.air", "class": "compiled.javaclass",
        "o": "compiled.object-library", "rcx": "compiled.rcx", "playground": "file.playground", "scnp": "file.scp",
        "sks": "file.sks", "skybox": "file.skybox", "storyboard": "file.storyboard", "uicatalog": "file.uicatalog",
        "xcplaygroundpage": "file.xcplaygroundpage", "xib": "file.xib", "aimodel": "folder.aimodel",
        "xcassets": "folder.assetcatalog", "docc": "folder.documentationcatalog", "icon": "folder.iconcomposer.icon",
        "iconset": "folder.iconset", "imagecatalog": "folder.imagecatalog", "mlpackage": "folder.mlpackage",
        "rkassets": "folder.rkassets", "atlas": "folder.skatlas", "xcstickers": "folder.stickers", "bmp": "image.bmp",
        "gif": "image.gif", "icns": "image.icns", "ico": "image.ico", "jpeg": "image.jpeg", "jpg": "image.jpeg",
        "pdf": "image.pdf", "pct": "image.pict", "pict": "image.pict", "png": "image.png", "tif": "image.tiff",
        "tiff": "image.tiff", "avi": "video.avi", "mpeg": "video.mpeg", "mpg": "video.mpeg",
        "qtz": "video.quartz-composer", "moov": "video.quicktime", "mov": "video.quicktime", "fs": "wrapper",
        "pluginkit": "wrapper.app-extension", "app": "wrapper.application", "artifactbundle": "wrapper.artifactbundle",
        "dext": "wrapper.driver-extension", "dSYM": "wrapper.dsym", "dsym": "wrapper.dsym",
        "appex": "wrapper.extensionkit-extension", "framework": "wrapper.framework", "htmld": "wrapper.htmld",
        "mpkg": "wrapper.installer-mpkg", "pkg": "wrapper.installer-pkg", "kext": "wrapper.kernel-extension",
        "nib": "wrapper.nib", "xcode": "wrapper.pb-project", "xcodeproj": "wrapper.pb-project",
        "xctarget": "wrapper.pb-target", "bundle": "wrapper.plug-in", "rtfd": "wrapper.rtfd",
        "scnassets": "wrapper.scnassets", "scncache": "wrapper.scncache", "mdimporter": "wrapper.spotlight-importer",
        "storyboardc": "wrapper.storyboardc", "systemextension": "wrapper.system-extension",
        "xcworkspace": "wrapper.workspace", "xcclassmodel": "wrapper.xcclassmodel",
        "xcdatamodel": "wrapper.xcdatamodel", "xcframework": "wrapper.xcframework",
        "xcmappingmodel": "wrapper.xcmappingmodel", "xpc": "wrapper.xpc-service",
        "xcdatamodeld": "wrapper.xcdatamodeld",
    ]

    /// Types whose parent isn't the identifier with its last component dropped (`nil` for roots).
    private static let parents: [String: String?] = [
        "folder.rkassets": nil, "archive.ear": "archive.jar", "archive.war": "archive.jar",
        "archive.ppob": "archive.rsrc", "archive.jar": "archive.zip", "compiled.object-library": "compiled.mach-o",
        "archive": "file", "audio": "file", "compiled": "file", "image": "file", "text": "file", "video": "file",
        "wrapper": "folder", "folder.assetcatalog": "folder.abstractassetcatalog",
        "folder.iconcomposer.icon": "folder.abstractassetcatalog", "folder.stickers": "folder.abstractassetcatalog",
        "folder.imagecatalog": "folder.assetcatalog", "file.intentdefinition": "sourcecode",
        "file.mlmodel": "sourcecode", "file.referenceobject": "sourcecode",
        "net.daringfireball.markdown": "sourcecode", "sourcecode.asm.llvm": "sourcecode",
        "wrapper.xcdatamodel": "sourcecode", "wrapper.xcdatamodeld": "sourcecode",
        "wrapper.xcmappingmodel": "sourcecode", "sourcecode.cpp": "sourcecode.c", "sourcecode.iig": "sourcecode.c",
        "file.swiftpm-manifest": "sourcecode.swift", "sourcecode": "text", "text.plist.strings": "text",
        "text.plist.stringsdict": "text", "text.plist.info": "text.plist.xml",
        "text.plist.vocabulary": "text.plist.xml", "com.apple.instruments.package-definition": "text.xml",
        "text.apinotes": "text.yaml", "com.apple.instruments.instrdst": "wrapper", "file.playground": "wrapper",
        "file.xcplaygroundpage": "wrapper", "folder.abstractassetcatalog": "wrapper", "folder.aimodel": "wrapper",
        "folder.documentationcatalog": "wrapper", "folder.iconset": "wrapper", "folder.mlpackage": "wrapper",
        "folder.skatlas": "wrapper", "wrapper.extensionkit-extension": "wrapper.app-extension",
        "wrapper.application": "wrapper.cfbundle", "wrapper.framework": "wrapper.cfbundle",
        "wrapper.plug-in": "wrapper.cfbundle", "wrapper.spotlight-importer": "wrapper.cfbundle",
        "wrapper.xpc-service": "wrapper.cfbundle", "wrapper.pb-target": "wrapper.pb-project",
        "wrapper.kernel-extension": "wrapper.plug-in", "wrapper.system-extension": "wrapper.plug-in",
        "wrapper.driver-extension": "wrapper.system-extension", "wrapper.app-extension": "wrapper.xpc-service",
    ]
}
