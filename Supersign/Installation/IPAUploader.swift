//
//  IPAUploader.swift
//  Supersign
//
//  Created by Kabir Oberai on 14/11/19.
//  Copyright © 2019 Kabir Oberai. All rights reserved.
//

import Foundation
import SwiftyMobileDevice

class IPAUploader {

    private static let packagePath = URL(fileURLWithPath: "PublicStaging")

    private let client: AFCClient
    init(connection: Connection) throws {
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
                let written = try destFile.write(buf)
                bufWritten += written
                totalWritten += written
                progress(Double(totalWritten) / Double(size))
            }
        } while !buf.isEmpty
    }

    func upload(ipa: URL, withBundleID bundleID: String, progress: (Double) -> Void) throws -> URL {
        if try !client.fileExists(at: Self.packagePath) {
            try client.createDirectory(at: Self.packagePath)
        }

        let dest = Self.packagePath.appendingPathComponent(bundleID)
        try upload(ipa, to: dest, progress: progress)

        return dest
    }

}
