// Adapted from SwiftBuild/BuildSettings.swift: mutable Xcode PIF support and lossless JSON fields.

import Foundation

extension XPIF {
    public struct BuildSettings: Sendable, Hashable {
        public enum SingleValueSetting: String, CaseIterable, Sendable, Equatable, Codable {
            case APPLICATION_EXTENSION_API_ONLY
            case BUILT_PRODUCTS_DIR
            case CLANG_CXX_LANGUAGE_STANDARD
            case CLANG_ENABLE_MODULES
            case CLANG_DISABLE_CXX_MODULES
            case CLANG_ENABLE_OBJC_ARC
            case CODE_SIGNING_REQUIRED
            case CODE_SIGN_IDENTITY
            case COMBINE_HIDPI_IMAGES
            case COPY_PHASE_STRIP
            case DEBUG_INFORMATION_FORMAT
            case DEFINES_MODULE
            case DEPLOYMENT_POSTPROCESSING
            case DOCC_EXTRACT_SPI_DOCUMENTATION
            case DOCC_EXTRACT_PROJECT_HEADERS_DOCUMENTATION
            case DRIVERKIT_DEPLOYMENT_TARGET
            case DYLIB_INSTALL_NAME_BASE
            case EMBEDDED_CONTENT_CONTAINS_SWIFT
            case ENABLE_NS_ASSERTIONS
            case ENABLE_TESTABILITY
            case ENABLE_TESTING_SEARCH_PATHS
            case ENTITLEMENTS_REQUIRED
            case EXECUTABLE_PREFIX
            case GENERATE_INFOPLIST_FILE
            case GCC_C_LANGUAGE_STANDARD
            case GCC_OPTIMIZATION_LEVEL
            case GENERATE_PRELINK_OBJECT_FILE
            case INDEX_ENABLE_DATA_STORE
            case INFOPLIST_FILE
            case IPHONEOS_DEPLOYMENT_TARGET
            case KEEP_PRIVATE_EXTERNS
            case CLANG_COVERAGE_MAPPING_LINKER_ARGS
            case MACH_O_TYPE
            case MACOSX_DEPLOYMENT_TARGET
            case MODULEMAP_FILE
            case MODULEMAP_FILE_CONTENTS
            case MODULEMAP_PATH
            case MODULE_CACHE_DIR
            case ONLY_ACTIVE_ARCH
            case PACKAGE_RESOURCE_BUNDLE_NAME
            case PACKAGE_RESOURCE_TARGET_KIND
            case PRODUCT_BUNDLE_IDENTIFIER
            case PRODUCT_MODULE_NAME
            case PRODUCT_NAME
            case PROJECT_NAME
            case SDKROOT
            case SDK_VARIANT
            case SKIP_INSTALL
            case INSTALL_PATH
            case SUPPORTS_MACCATALYST
            case SWIFT_SERIALIZE_DEBUGGING_OPTIONS
            case SWIFT_INSTALL_OBJC_HEADER
            case SWIFT_OBJC_INTERFACE_HEADER_NAME
            case SWIFT_OBJC_INTERFACE_HEADER_DIR
            case SWIFT_OPTIMIZATION_LEVEL
            case SWIFT_VERSION
            case SYMBOL_GRAPH_EXTRACTOR_OUTPUT_DIR
            case TARGET_NAME
            case TARGET_TEMP_DIR_SUFFIX
            case TARGET_BUILD_DIR
            case TVOS_DEPLOYMENT_TARGET
            case USE_HEADERMAP
            case USES_SWIFTPM_UNSAFE_FLAGS
            case WATCHOS_DEPLOYMENT_TARGET
            case XROS_DEPLOYMENT_TARGET
            case _IOS_DEPLOYMENT_TARGET
            case MARKETING_VERSION
            case CURRENT_PROJECT_VERSION
            case SWIFT_EMIT_MODULE_INTERFACE
            case GENERATE_RESOURCE_ACCESSORS
            case BUILD_LIBRARY_FOR_DISTRIBUTION
            case BUILD_PACKAGE_FOR_DISTRIBUTION
            case COMPILER_WORKING_DIRECTORY
            case COREML_CODEGEN_LANGUAGE
            case COREML_COMPILER_CONTAINER
            case EXECUTABLE_NAME
            case GENERATE_EMBED_IN_CODE_ACCESSORS
            case INSTALLAPI_COPY_PHASE
            case INSTALLHDRS_COPY_PHASE
            case IS_ZIPPERED
            case PACKAGE_REGISTRY_SIGNATURE
            case PACKAGE_TARGET_NAME_CONFLICTS_WITH_PRODUCT_NAME
            case SKIP_BUILDING_DOCUMENTATION
            case SKIP_CLANG_STATIC_ANALYZER
            case STRIP_INSTALLED_PRODUCT
            case SUPPORTS_TEXT_BASED_API
            case SUPPRESS_WARNINGS
            case SWIFT_TREAT_WARNINGS_AS_ERRORS
            case SWIFT_COMPILE_FOR_STATIC_LINKING
            case SWIFT_DISABLE_PARSE_AS_LIBRARY
            case SWIFT_ENABLE_BARE_SLASH_REGEX
            case SWIFT_INDEX_STORE_ENABLE
            case SWIFT_INSTALL_MODULE
            case SWIFT_LIBRARIES_ONLY
            case SWIFT_PACKAGE_NAME
            case SWIFT_USER_MODULE_VERSION
            case TAPI_DYLIB_INSTALL_NAME
            case TAPI_EXTRACT_API_OUTPUT_DIR
            case TARGETED_DEVICE_FAMILY
            case LINKER_DRIVER
            case LIBTOOL_NO_WARNING_FOR_NO_SYMBOLS
            case LD_WARN_DUPLICATE_LIBRARIES

            // @available(*, deprecated, renamed: "GENERATE_PRELINK_OBJECT_FILE") // can't add @available because it breaks CaseIterable
            case GENERATE_MASTER_OBJECT_FILE // ignore-unacceptable-language
        }

        public enum MultipleValueSetting: String, CaseIterable, Sendable, Hashable, Codable {
            case ARCHS
            case BUILD_SERVER_PROTOCOL_TARGET_TAGS
            case EMBED_PACKAGE_RESOURCE_BUNDLE_NAMES
            case FRAMEWORK_SEARCH_PATHS
            case GCC_PREPROCESSOR_DEFINITIONS
            case HEADER_SEARCH_PATHS
            case LD_RUNPATH_SEARCH_PATHS
            case LIBRARY_SEARCH_PATHS
            case OTHER_CFLAGS
            case OTHER_CPLUSPLUSFLAGS
            case OTHER_LDFLAGS
            case OTHER_LDRFLAGS
            case OTHER_SWIFT_FLAGS
            case PRELINK_FLAGS
            case SPECIALIZATION_SDK_OPTIONS
            case SUPPORTED_PLATFORMS
            case SWIFT_ACTIVE_COMPILATION_CONDITIONS
            case SWIFT_DISABLE_COMPILATION_FOR_STATIC_LINKING_WHEN_ANY_TARGET_IS_PROMOTED_TO_DYNAMIC
            case SWIFT_IMPLEMENTS_MACROS_FOR_MODULE_NAMES
            case SWIFT_MODULE_ALIASES
            case SWIFT_SDK_TOOLSETS
            case SWIFT_WARNINGS_AS_WARNINGS_GROUPS
            case SWIFT_WARNINGS_AS_ERRORS_GROUPS
        }

        public enum Platform: Hashable, CaseIterable, Sendable {
            case macOS
            case macCatalyst
            case iOS

            // Special case to support arm64e-only iOS app builds with SwiftPM dependencies. Don't use it for anything else!
            case _iOSDevice

            case tvOS
            case watchOS
            case xrOS

            case driverKit

            case linux
            case android
            case windows
            case wasi
            case openbsd
            case freebsd

            public var asConditionStrings: [String] {
                let filters = self.toPlatformFilter().map { (filter: XPIF.PlatformFilter) -> String in
                    if filter.environment.isEmpty {
                        return filter.platform
                    } else {
                        return "\(filter.platform)-\(filter.environment)"
                    }
                }.sorted()
                return ["__platform_filter=\(filters.joined(separator: ";"))"]
            }
        }

        /// Keys are stored verbatim, including arbitrary Xcode conditions and plugin settings.
        public var values: [String: StringList] = [:]

        public init() {}

        public subscript(_ setting: SingleValueSetting) -> String? {
            get { self[single: setting.rawValue] }
            set { self[single: setting.rawValue] = newValue }
        }

        public subscript(single setting: String) -> String? {
            get {
                guard case .string(let value) = values[setting] else { return nil }
                return value
            }
            set { values[setting] = newValue.map(StringList.string) }
        }

        public subscript(_ setting: MultipleValueSetting) -> [String]? {
            get { self[multiple: setting.rawValue] }
            set { self[multiple: setting.rawValue] = newValue }
        }

        public subscript(multiple setting: String) -> [String]? {
            get {
                guard case .array(let value) = values[setting] else { return nil }
                return value
            }
            set { values[setting] = newValue.map(StringList.array) }
        }

        public subscript(_ setting: SingleValueSetting, platform: Platform) -> String? {
            get { self[single: "\(setting.rawValue)[\(platform.asConditionStrings[0])]"] }
            set { self[single: "\(setting.rawValue)[\(platform.asConditionStrings[0])]"] = newValue }
        }

        public subscript(_ setting: MultipleValueSetting, platform: Platform) -> [String]? {
            get { self[multiple: "\(setting.rawValue)[\(platform.asConditionStrings[0])]"] }
            set { self[multiple: "\(setting.rawValue)[\(platform.asConditionStrings[0])]"] = newValue }
        }
    }
}


public extension XPIF.BuildSettings.Platform {
    func toPlatformFilter() -> [XPIF.PlatformFilter] {
        var result: [XPIF.PlatformFilter] = []

        switch self {
        case .macOS:
            result.append(.init(platform: "macos"))

        case .macCatalyst:
            result.append(.init(platform: "ios", environment: "maccatalyst"))

        case .iOS:
            result.append(.init(platform: "ios"))
            result.append(.init(platform: "ios", environment: "simulator"))

        case ._iOSDevice:
            result.append(.init(platform: "ios"))

        case .tvOS:
            result.append(.init(platform: "tvos"))
            result.append(.init(platform: "tvos", environment: "simulator"))

        case .watchOS:
            result.append(.init(platform: "watchos"))
            result.append(.init(platform: "watchos", environment: "simulator"))

        case .xrOS:
            result.append(.init(platform: "xros"))
            result.append(.init(platform: "xros", environment: "simulator"))

        case .driverKit:
            result.append(.init(platform: "driverkit"))

        case .linux:
            result.append(.init(platform: "linux", environment: "gnu"))
            result.append(.init(platform: "linux", environment: "musl"))

        case .android:
            result.append(.init(platform: "linux", environment: "android"))
            result.append(.init(platform: "linux", environment: "androideabi"))

        case .windows:
            result.append(.init(platform: "windows", environment: "msvc"))

        case .wasi:
            result.append(.init(platform: "wasi"))
            result.append(.init(platform: "wasip1"))
            result.append(.init(platform: "wasi", environment: "threads"))
            result.append(.init(platform: "wasip1", environment: "threads"))

        case .openbsd:
            result.append(.init(platform: "openbsd"))

        case .freebsd:
            result.append(.init(platform: "freebsd"))
        }
        return result
    }
}

extension XPIF.BuildSettings: Codable {
    public init(from decoder: any Decoder) throws {
        values = try decoder.singleValueContainer().decode([String: XPIF.StringList].self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(values)
    }
}
