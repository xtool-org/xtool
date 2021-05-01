//
//  DDIMounter.swift
//  Supersign
//
//  Created by Kabir Oberai on 25/03/21.
//  Copyright © 2021 Kabir Oberai. All rights reserved.
//

import Foundation
import SwiftyMobileDevice

public final class DDIMounter {

    public struct DDILoc {
        public let dmg: URL
        public let signature: URL

        public init(dmg: URL, signature: URL) {
            self.dmg = dmg
            self.signature = signature
        }
    }

    private class RequestDelegate: NSObject, URLSessionTaskDelegate, URLSessionDataDelegate {
        enum Verdict {
            case streamData(size: Int)
            case downloadFull(URL)
            case failed(Swift.Error)
        }

        private var verdict: Verdict?
        private let cache: URL
        private let fileStream: OutputStream
        private let pipedStream: OutputStream
        private let onVerdict: (Verdict) -> Void
        init(stream: OutputStream, cache: URL, onVerdict: @escaping (Verdict) -> Void) {
            self.pipedStream = stream
            self.cache = cache
            self.fileStream = OutputStream(url: cache, append: false)!
            self.onVerdict = onVerdict
            stream.open()
            fileStream.open()
        }

        func urlSession(
            _ session: URLSession,
            dataTask: URLSessionDataTask,
            didReceive response: URLResponse,
            completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
        ) {
            let len = response.expectedContentLength
            completionHandler(.allow)
            if len == -1 {
                verdict = .downloadFull(cache)
            } else {
                let verdict: Verdict = .streamData(size: Int(len))
                self.verdict = verdict
                onVerdict(verdict)
            }
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            data.withUnsafeBytes { bytes in
                let buf = bytes.bindMemory(to: UInt8.self)
                pipedStream.write(buf.baseAddress!, maxLength: buf.count)
                fileStream.write(buf.baseAddress!, maxLength: buf.count)
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Swift.Error?) {
            pipedStream.close()
            fileStream.close()
            if case let .downloadFull(url) = verdict {
                onVerdict(error.map(Verdict.failed) ?? .downloadFull(url))
            }
        }
    }

    private enum MounterStatus: String, Decodable {
        case complete = "Complete"
    }

    private struct MountedImage: Decodable {
        let status: MounterStatus
        let signature: [Data]?

        private enum CodingKeys: String, CodingKey {
            case signature = "ImageSignature"
            case status = "Status"
        }
    }

    private struct MountResult: Decodable {
        let status: MounterStatus?
        let error: String?

        private enum CodingKeys: String, CodingKey {
            case status = "Status"
            case error = "Error"
        }
    }

    public struct Error: Swift.Error, LocalizedError {
        public let message: String?
        public var errorDescription: String? { message }
    }

    private let client: MobileImageMounterClient
    public init(connection: Connection) throws {
        self.client = try connection.startClient()
    }

    private func mount(file: InputStream, size: Int, signature: Data) throws {
        file.open()
        defer { file.close() }

        try client.upload(imageType: "Developer", file: file, size: size, signature: signature)
        let result = try client.mount(imageType: "Developer", signature: signature, resultType: MountResult.self)
        guard result.status == .complete else {
            throw Error(message: result.error)
        }
    }

    public func mountIfNeeded(local: DDILoc, fetchRemote: () throws -> DDILoc) throws {
        let mounted = try client.lookup(imageType: "Developer", resultType: MountedImage.self)
        if mounted.signature != nil { return }

        if local.dmg.exists,
           local.signature.exists,
           let file = InputStream(url: local.dmg),
           let fileSize = try? local.dmg.resourceValues(forKeys: [.fileSizeKey]).fileSize,
           let signature = try? Data(contentsOf: local.signature) {
            return try mount(file: file, size: fileSize, signature: signature)
        }

        let remote = try fetchRemote()

        var istream: InputStream!
        var ostream: OutputStream!
        Stream.getBoundStreams(withBufferSize: 1024, inputStream: &istream, outputStream: &ostream)

        let group = DispatchGroup()

        var mode: RequestDelegate.Verdict!
        group.enter()
        let delegate = RequestDelegate(stream: ostream, cache: local.dmg) { m in
            mode = m
            group.leave()
        }

        let dmgReq = URLRequest(url: remote.dmg)
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        session.dataTask(with: dmgReq).resume()

        let sigReq = URLRequest(url: remote.signature)
        var sigRes: Result<Data, Swift.Error>!
        group.enter()
        URLSession.shared.dataTask(with: sigReq) { data, _, err in
            if let data = data {
                sigRes = .success(data)
            } else {
                sigRes = .failure(err ?? Error(message: nil))
            }
            group.leave()
            try? data?.write(to: local.signature)
        }.resume()

        group.wait()
        let signature = try sigRes.get()

        switch mode! {
        case .downloadFull(let url):
            let file = InputStream(url: url)!
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize!
            try mount(file: file, size: size, signature: signature)
        case .streamData(let size):
            try mount(file: istream, size: size, signature: signature)
        case .failed(let error):
            throw error
        }

        _ = delegate
    }

}
