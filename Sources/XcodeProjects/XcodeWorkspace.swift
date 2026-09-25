import Foundation

public struct XcodeWorkspace: Hashable, Sendable {
    public enum Element: Hashable, Sendable {
        case file(Location)
        case group(Group)
        case fileSystemSynchronizedGroup(Group)

        public var location: Location {
            get {
                switch self {
                case let .file(location):
                    location
                case let .group(group):
                    group.location
                case let .fileSystemSynchronizedGroup(group):
                    group.location
                }
            }
            set {
                switch self {
                case .file:
                    self = .file(newValue)
                case .group(var group):
                    group.location = newValue
                    self = .group(group)
                case .fileSystemSynchronizedGroup(var group):
                    group.location = newValue
                    self = .fileSystemSynchronizedGroup(group)
                }
            }
        }
    }

    public struct Group: Hashable, Sendable {
        public var location: Location
        public var name: String?
        public var children: [Element]

        public init(location: Location, name: String?, children: [Element]) {
            self.location = location
            self.name = name
            self.children = children
        }
    }

    public struct Location: Hashable, Sendable {
        public struct Base: Hashable, Sendable, RawRepresentable {
            public var rawValue: String

            public init(rawValue: String) {
                self.rawValue = rawValue
            }
        }

        public var base: Base
        public var path: String

        public init(base: Base, path: String) {
            self.base = base
            self.path = path
        }
    }

    public var children: [Element]

    public init(children: [Element]) {
        self.children = children
    }
}

extension XcodeWorkspace.Location.Base {
    /// Absolute path
    public static let absolute = Self(rawValue: "absolute")
    /// Relative to container
    public static let container = Self(rawValue: "container")
    /// Relative to Developer Directory
    public static let developer = Self(rawValue: "developer")
    /// Relative to group
    public static let group = Self(rawValue: "group")
    /// Single project workspace in xcodeproj directory
    public static let current = Self(rawValue: "self")
}

extension XcodeWorkspace.Location {
    public static var current: Self {
        Self(base: .current, path: "")
    }
}

extension XcodeWorkspace.Location: LosslessStringConvertible, CustomStringConvertible {
    public init?(_ string: String) {
        guard let colon = string.firstIndex(of: ":") else {
            return nil
        }
        self.base = Base(rawValue: String(string[..<colon]))
        self.path = String(string[colon...].dropFirst())
    }

    public var description: String {
        "\(base.rawValue):\(path)"
    }
}
