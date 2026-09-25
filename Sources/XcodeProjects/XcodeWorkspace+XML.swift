import Foundation
private import XcodeProj

extension XcodeWorkspace {
    public init(url: URL) throws {
        let workspace = try XCWorkspace(pathString: url.path)
        self.init(workspace.data)
    }

    public func dataRepresentation() throws -> Data {
        try xcWorkspaceData.dataRepresentation() ?? Data()
    }

    public func write(to url: URL) throws {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try self.dataRepresentation()
            .write(to: url.appendingPathComponent("contents.xcworkspacedata"))
    }
}

// MARK: - Conversion

extension XcodeWorkspace {
    fileprivate init(_ xcWorkspaceData: XCWorkspaceData) {
        self.init(children: xcWorkspaceData.children.map { .init(from: $0) })
    }

    fileprivate var xcWorkspaceData: XCWorkspaceData {
        XCWorkspaceData(children: children.map(\.xcWorkspaceDataElement))
    }
}

extension XcodeWorkspace.Element {
    fileprivate init(from xcWorkspaceDataElement: XCWorkspaceDataElement) {
        switch xcWorkspaceDataElement {
        case .file(let file):
            self = .file(.init(file.location))
        case .group(let group):
            self = .group(.init(group))
        case .fileSystemSynchronizedGroup(let group):
            self = .fileSystemSynchronizedGroup(.init(group))
        }
    }

    fileprivate var xcWorkspaceDataElement: XCWorkspaceDataElement {
        switch self {
        case .file(let location):
            .file(.init(location: location.xcWorkspaceLocation))
        case .group(let group):
            .group(group.xcWorkspaceDataElement)
        case .fileSystemSynchronizedGroup(let group):
            .fileSystemSynchronizedGroup(group.xcWorkspaceDataElement)
        }
    }
}

extension XcodeWorkspace.Location {
    fileprivate init(_ xcWorkspaceDataElementLocation: XCWorkspaceDataElementLocationType) {
        self.base = .init(rawValue: xcWorkspaceDataElementLocation.schema)
        self.path = xcWorkspaceDataElementLocation.path
    }

    fileprivate var xcWorkspaceLocation: XCWorkspaceDataElementLocationType {
        .other(base.rawValue, path)
    }
}

extension XcodeWorkspace.Group {
    fileprivate init(_ xcWorkspaceDataGroup: XCWorkspaceDataGroup) {
        self.init(
            location: .init(xcWorkspaceDataGroup.location),
            name: xcWorkspaceDataGroup.name,
            children: xcWorkspaceDataGroup.children.map { .init(from: $0) }
        )
    }

    fileprivate var xcWorkspaceDataElement: XCWorkspaceDataGroup {
        .init(
            location: self.location.xcWorkspaceLocation,
            name: name,
            children: children.map(\.xcWorkspaceDataElement)
        )
    }
}
