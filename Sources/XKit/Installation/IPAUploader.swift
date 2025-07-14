//
//  IPAUploader.swift
//  XKit
//
//  Created by Kabir Oberai on 14/11/19.
//  Copyright © 2019 Kabir Oberai. All rights reserved.
//

import Foundation
import SwiftyMobileDevice

public final class IPAUploader: Sendable {

    public enum Error: Swift.Error {
        case unexpectedSymlink(at: URL)
    }

    private static let packagePath = URL(fileURLWithPath: "/PublicStaging")
    private static let bufferSize = 1 << 20 // 1 MB

    public final class UploadedIPA: Sendable {
        public let uploader: IPAUploader
        let location: URL
        fileprivate init(uploader: IPAUploader, location: URL) {
            self.uploader = uploader
            self.location = location
        }

        deinit { delete() }

        public func delete() {
            try? uploader.client.removeItemAndContents(at: location)
        }
    }

    private let client: AFCClient
    public init(connection: Connection) async throws {
        self.client = try await connection.startClient()
    }

    private func upload(_ src: URL, to dest: URL, progress: (Double) -> Void) async throws {
        let srcData = try Data(contentsOf: src)
        let size = srcData.count
        let sizeDouble = Double(size)
        let destFile = try client.open(dest, mode: .writeOnly)

        let bufferSize = Self.bufferSize

        var totalWritten = 0
        while totalWritten != size {
            if totalWritten != 0 {
                await Task.yield()
                try Task.checkCancellation()
            }
            let buf = srcData.dropFirst(totalWritten).prefix(bufferSize)
            let bufSize = buf.count
            var bufWritten = 0
            while bufWritten < bufSize {
                // not sure if rewriting the same buf is a bug but ideviceinstaller does it this way
                let written = try destFile.write(buf)
                bufWritten += written
                totalWritten += written
                progress(Double(totalWritten) / sizeDouble)
            }
        }
    }

    public func upload(app: URL, progress: (Double) -> Void) async throws -> UploadedIPA {
        if try !client.fileExists(at: Self.packagePath) {
            try client.createDirectory(at: Self.packagePath)
        }

        let dest = Self.packagePath.appendingPathComponent("XTool-App")
        if try client.fileExists(at: dest) {
            try client.removeItemAndContents(at: dest)
        }

        try await upload(app, to: dest, progress: progress)

        return UploadedIPA(uploader: self, location: dest)
    }

}
