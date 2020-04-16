//
//  IPAUploader.swift
//  Supersign
//
//  Created by Kabir Oberai on 14/11/19.
//  Copyright © 2019 Kabir Oberai. All rights reserved.
//

import Foundation
import SwiftyMobileDevice

public class IPAUploader {

    private static let packagePath = URL(fileURLWithPath: "PublicStaging")

    public class UploadedIPA {
        public let uploader: IPAUploader
        let location: URL
        fileprivate init(uploader: IPAUploader, location: URL) {
            self.uploader = uploader
            self.location = location
        }

        public private(set) var isDeleted: Bool = false

        deinit { delete() }
        public func delete() {
            guard !isDeleted else { return }
            try? uploader.client.removeItem(at: location)
        }
    }

    private let client: AFCClient
    public init(connection: Connection) throws {
        self.client = try connection.startClient()
    }

    private func upload(_ src: URL, to dest: URL, progress: (Double) -> Void) throws {
        let srcHandle = try FileHandle(forReadingFrom: src)
        let size = srcHandle.seekToEndOfFile()
        srcHandle.seek(toFileOffset: 0)

        let destFile = try client.open(dest, mode: .writeOnly)

        var totalWritten = 0
        var buf: Data
        repeat {
            buf = srcHandle.readData(ofLength: 1 << 20) // 1 MB
            var bufWritten = 0
            while bufWritten < buf.count {
                // not sure if rewriting the same buf is a bug but ideviceinstaller does it this way
                let written = try destFile.write(buf)
                bufWritten += written
                totalWritten += written
                progress(Double(totalWritten) / Double(size))
            }
        } while !buf.isEmpty
    }

    public func upload(ipa: URL, withBundleID bundleID: String, progress: (Double) -> Void) throws -> UploadedIPA {
        if try !client.fileExists(at: Self.packagePath) {
            try client.createDirectory(at: Self.packagePath)
        }

        let dest = Self.packagePath.appendingPathComponent(bundleID)
        try upload(ipa, to: dest, progress: progress)

        return UploadedIPA(uploader: self, location: dest)
    }

}
