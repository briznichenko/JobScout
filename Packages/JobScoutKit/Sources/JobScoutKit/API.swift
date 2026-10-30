//
//  API.swift
//  JobScout
//
//  Created by Andrii Bryzhnychenko on 10/29/26.
//

import Foundation

public struct ScanOperation: Codable, Identifiable, Sendable {
    public let id: String
    public let state: String
    public let message: String?
    public let started: String
    public let finished: String?
    public var isRunning: Bool { state == "running" || state == "cancelling" }
}

public struct ServerSettings: Codable, Sendable {
    public let config: String
    public init(config: String) { self.config = config }
}

public enum APIError: LocalizedError, Sendable {
    case invalidAddress
    case connection(String)
    case unauthorized
    case conflict(String)
    case server(Int, String)
    case invalidResponse(String)

    public var errorDescription: String? {
        switch self {
        case .invalidAddress: "Enter a server URL beginning with http:// or https://."
        case .connection(let detail): "Could not connect to JobScout. Check the server address, network access, and that the service is running. \(detail)"
        case .unauthorized: "The server rejected the access token. Check it in connection settings."
        case .conflict(let message): message
        case .server(let code, let message): "JobScout server returned \(code): \(message)"
        case .invalidResponse(let message): "Could not read the JobScout server response. \(message)"
        }
    }
}

public actor JobScoutAPI {
    private struct Failure: Decodable { let error: String }

    private let baseURL: URL
    private let token: String
    private let session: URLSession

    public init(baseURL: URL, token: String, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.token = token
        self.session = session
    }

    public func snapshot() async throws -> JobSnapshot {
        try await request("GET", path: "snapshot")
    }

    public func vacancy(id: Int) async throws -> Vacancy {
        try await request("GET", path: "vacancies/\(id)")
    }

    public func updateStatus(_ status: ApplicationStatus, for id: Int) async throws -> JobSnapshot {
        try await request("PATCH", path: "vacancies/\(id)/status", body: ["status": status.rawValue])
    }

    public func startScan() async throws -> ScanOperation {
        try await request("POST", path: "scans")
    }

    public func currentScan() async throws -> ScanOperation? {
        struct Current: Decodable { let operation: ScanOperation? }
        let result: Current = try await request("GET", path: "scans/current")
        return result.operation
    }

    public func scan(id: String) async throws -> ScanOperation {
        try await request("GET", path: "scans/\(try operationID(id))")
    }

    public func cancelScan(id: String) async throws -> ScanOperation {
        try await request("POST", path: "scans/\(try operationID(id))/cancel")
    }

    public func importFile(data: Data, filename: String, kind: String, adapter: String? = nil, source: String? = nil) async throws -> JobSnapshot {
        var body = ["filename": filename, "content_base64": data.base64EncodedString(), "kind": kind]
        if let adapter { body["adapter"] = adapter }
        if let source { body["source"] = source }
        return try await request("POST", path: "imports", body: body)
    }

    public func rescore() async throws -> JobSnapshot {
        try await request("POST", path: "rescore")
    }

    public func report() async throws -> JobSnapshot {
        try await request("POST", path: "report")
    }

    public func settings() async throws -> ServerSettings {
        try await request("GET", path: "settings")
    }

    public func saveSettings(config: String) async throws -> ServerSettings {
        try await request("PUT", path: "settings", body: ["config": config])
    }

    private func operationID(_ value: String) throws -> String {
        guard !value.isEmpty, value.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_")).contains($0) }) else {
            throw APIError.invalidResponse("Invalid scan identifier.")
        }
        return value
    }

    private func request<Response: Decodable & Sendable>(_ method: String, path: String, body: [String: String]? = nil) async throws -> Response {
        guard let scheme = baseURL.scheme?.lowercased(), ["http", "https"].contains(scheme),
              baseURL.host != nil, baseURL.user == nil, baseURL.password == nil,
              baseURL.query == nil, baseURL.fragment == nil else { throw APIError.invalidAddress }
        let url = baseURL.appending(path: "v1").appending(path: path)
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 120
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = try JSONEncoder().encode(body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw APIError.connection(error.localizedDescription)
        }
        guard let response = response as? HTTPURLResponse else { throw APIError.invalidResponse("Expected HTTP.") }
        guard (200..<300).contains(response.statusCode) else {
            let message = (try? JSONDecoder().decode(Failure.self, from: data).error) ?? HTTPURLResponse.localizedString(forStatusCode: response.statusCode)
            switch response.statusCode {
            case 401, 403: throw APIError.unauthorized
            case 409: throw APIError.conflict(message)
            default: throw APIError.server(response.statusCode, message)
            }
        }
        do {
            return try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw APIError.invalidResponse(error.localizedDescription)
        }
    }
}
