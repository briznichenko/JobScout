//
//  SnapshotCache.swift
//  JobScout
//
//  Created by Andrii Bryzhnychenko on 10/29/26.
//

import CryptoKit
import Foundation

public struct SnapshotCache: Sendable {
    private let file: URL

    public init(directory: URL, serverURL: URL) {
        var components = URLComponents(url: serverURL, resolvingAgainstBaseURL: false)
        let scheme = components?.scheme?.lowercased()
        let host = components?.host?.lowercased()
        components?.scheme = scheme
        components?.host = host
        components?.user = nil
        components?.password = nil
        components?.query = nil
        components?.fragment = nil
        let identity = components?.url?.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) ?? serverURL.absoluteString
        let digest = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        file = directory.appending(path: "snapshot-\(digest).json")
    }

    public func load() -> JobSnapshot? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode(JobSnapshot.self, from: data)
    }

    public func save(_ snapshot: JobSnapshot) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(snapshot).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}
