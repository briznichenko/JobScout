//
//  BackendClient.swift
//  JobScout
//
//  Created by Andrii Bryzhnychenko on 10/29/26.
//

import Foundation
import JobScoutKit

struct AppRuntime: Sendable {
    let backend: URL
    let seed: URL?
    let workspace: URL

    static func live(bundle: Bundle = .main) throws -> AppRuntime {
        guard let resources = bundle.resourceURL else { throw BackendError.resourcesMissing }
        let backend = resources.appending(path: "Backend", directoryHint: .isDirectory)
        guard FileManager.default.fileExists(atPath: backend.appending(path: "jobscout/service.py").path) else {
            throw BackendError.resourcesMissing
        }
        let arguments = ProcessInfo.processInfo.arguments
        let workspace: URL
        if let index = arguments.firstIndex(of: "--workspace"), arguments.indices.contains(index + 1) {
            workspace = URL(filePath: arguments[index + 1], directoryHint: .isDirectory)
        } else {
            workspace = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                .appending(path: "JobScout", directoryHint: .isDirectory)
        }
        return AppRuntime(backend: backend, seed: resources.appending(path: "Seed/jobs.sqlite"), workspace: workspace)
    }

    func prepare() throws {
        let manager = FileManager.default
        try manager.createDirectory(at: workspace.appending(path: "data"), withIntermediateDirectories: true)
        let config = workspace.appending(path: "config.toml")
        if !manager.fileExists(atPath: config.path) {
            try manager.copyItem(at: backend.appending(path: "config.toml"), to: config)
        }
        let database = workspace.appending(path: "data/jobs.sqlite")
        if !manager.fileExists(atPath: database.path), let seed, manager.fileExists(atPath: seed.path) {
            try manager.copyItem(at: seed, to: database)
        }
    }

    static var defaultPython: String {
        ["/Library/Frameworks/Python.framework/Versions/3.12/bin/python3",
         "/opt/homebrew/bin/python3.14", "/opt/homebrew/bin/python3.13", "/opt/homebrew/bin/python3.12",
         "/opt/homebrew/bin/python3", "/usr/local/bin/python3"]
            .first { FileManager.default.isExecutableFile(atPath: $0) } ?? "/usr/bin/python3"
    }
}

enum BackendError: LocalizedError, Sendable {
    case resourcesMissing
    case invalidPython
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .resourcesMissing: "The bundled crawler is missing. Rebuild JobScout from its Xcode project."
        case .invalidPython: "Choose an executable Python 3.12 or newer in Settings."
        case .failed(let message): message
        }
    }
}

enum BackendCommand: Sendable, Equatable {
    case snapshot
    case scan
    case resumeScan
    case updateStatus(ApplicationStatus, id: Int)
    case importFile(URL, kind: ImportKind)
    case rescore
    case report

    enum ImportKind: Sendable, Equatable {
        case vacancies(adapter: String?)
        case tracker
        case source(String)
    }

    var isScan: Bool {
        switch self {
        case .scan, .resumeScan: true
        default: false
        }
    }
}

protocol JobBackend: Sendable {
    func execute(_ command: BackendCommand, python: String) async throws -> JobSnapshot
    func cancelScan() async throws
    func scanInProgress() async throws -> Bool
}

extension JobBackend {
    func cancelScan() async throws {}
    func scanInProgress() async throws -> Bool { false }
}

actor BackendClient: JobBackend {
    private let runtime: AppRuntime
    private var service: Process?
    private var serverURL: URL
    private var cancellationRequested = false
    private var activeScanCommand = false
    private var suppliedToken: String

    init(runtime: AppRuntime, serverURL: URL = URL(string: "http://127.0.0.1:8765")!, token: String = "") {
        self.runtime = runtime
        self.serverURL = serverURL
        suppliedToken = token
    }

    func configure(serverURL: URL, token: String) {
        self.serverURL = serverURL
        suppliedToken = token
    }

    private func client(python: String) async throws -> JobScoutAPI {
        let url = serverURL
        let local = ["127.0.0.1", "localhost", "::1"].contains(url.host ?? "") && url.port == 8765
        if local && suppliedToken.isEmpty {
            try runtime.prepare()
            let tokenURL = runtime.workspace.appending(path: "server-token")
            if let token = try? String(contentsOf: tokenURL, encoding: .utf8) {
                let existing = JobScoutAPI(baseURL: url, token: token.trimmingCharacters(in: .whitespacesAndNewlines))
                do {
                    _ = try await existing.snapshot()
                    return existing
                } catch APIError.unauthorized {
                    throw APIError.unauthorized
                } catch {}
            }
            if service?.isRunning != true {
                guard FileManager.default.isExecutableFile(atPath: python) else { throw BackendError.invalidPython }
                let process = Process()
                process.executableURL = URL(filePath: python)
                process.arguments = ["-B", "-m", "jobscout.service", "--workspace", runtime.workspace.path]
                process.currentDirectoryURL = runtime.backend
                process.standardInput = FileHandle.nullDevice
                let logURL = runtime.workspace.appending(path: "server.log")
                if !FileManager.default.fileExists(atPath: logURL.path) {
                    FileManager.default.createFile(atPath: logURL.path, contents: nil)
                }
                let log = try FileHandle(forWritingTo: logURL)
                try log.seekToEnd()
                process.standardOutput = log
                process.standardError = log
                defer { try? log.close() }
                try process.run()
                service = process
            }
            for _ in 0..<50 {
                try Task.checkCancellation()
                if let token = try? String(contentsOf: tokenURL, encoding: .utf8) {
                    let api = JobScoutAPI(baseURL: url, token: token.trimmingCharacters(in: .whitespacesAndNewlines))
                    if (try? await api.snapshot()) != nil { return api }
                }
                if service?.isRunning == false { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            throw BackendError.failed("The local service could not start. Check Python and server.log in your data folder.")
        }
        return JobScoutAPI(baseURL: url, token: suppliedToken)
    }

    func settings(python: String) async throws -> ServerSettings {
        try await client(python: python).settings()
    }

    func saveSettings(_ config: String, python: String) async throws {
        _ = try await client(python: python).saveSettings(config: config)
    }

    func execute(_ command: BackendCommand, python: String) async throws -> JobSnapshot {
        let scanning = command.isScan
        if scanning { activeScanCommand = true }
        defer {
            if scanning {
                activeScanCommand = false
                cancellationRequested = false
            }
        }
        let api = try await client(python: python)
        switch command {
        case .snapshot:
            return try await api.snapshot()
        case .resumeScan:
            if let current = try await api.currentScan(), current.isRunning {
                if cancellationRequested { _ = try await api.cancelScan(id: current.id) }
                try await wait(current, api: api)
            }
            return try await api.snapshot()
        case .scan:
            try Task.checkCancellation()
            if cancellationRequested { throw CancellationError() }
            let operation: ScanOperation
            if let current = try await api.currentScan(), current.isRunning {
                operation = current
            } else {
                operation = try await api.startScan()
            }
            if cancellationRequested { _ = try await api.cancelScan(id: operation.id) }
            try await wait(operation, api: api)
            return try await api.snapshot()
        case .updateStatus(let status, let id):
            return try await api.updateStatus(status, for: id)
        case .importFile(let url, let kind):
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let data = try Data(contentsOf: url)
            switch kind {
            case .vacancies(let adapter):
                return try await api.importFile(data: data, filename: url.lastPathComponent, kind: "vacancies", adapter: adapter)
            case .tracker:
                return try await api.importFile(data: data, filename: url.lastPathComponent, kind: "tracker")
            case .source(let source):
                return try await api.importFile(data: data, filename: url.lastPathComponent, kind: "source", source: source)
            }
        case .rescore:
            return try await api.rescore()
        case .report:
            return try await api.report()
        }
    }

    private func wait(_ operation: ScanOperation, api: JobScoutAPI) async throws {
        var current = operation
        while current.isRunning {
            try await Task.sleep(for: .milliseconds(500))
            current = try await api.scan(id: current.id)
        }
        if current.state == "cancelled" { throw CancellationError() }
        if current.state == "failed" { throw BackendError.failed(current.message ?? "Search failed.") }
    }

    func scanInProgress() async throws -> Bool {
        let token = suppliedToken.isEmpty
            ? (try String(contentsOf: runtime.workspace.appending(path: "server-token"), encoding: .utf8)).trimmingCharacters(in: .whitespacesAndNewlines)
            : suppliedToken
        return try await JobScoutAPI(baseURL: serverURL, token: token).currentScan()?.isRunning ?? false
    }

    func cancelScan() async throws {
        cancellationRequested = true
        defer { if !activeScanCommand { cancellationRequested = false } }
        let token: String
        if suppliedToken.isEmpty {
            guard let saved = try? String(contentsOf: runtime.workspace.appending(path: "server-token"), encoding: .utf8) else { return }
            token = saved.trimmingCharacters(in: .whitespacesAndNewlines)
        } else { token = suppliedToken }
        let api = JobScoutAPI(baseURL: serverURL, token: token)
        if let current = try await api.currentScan(), current.isRunning {
            _ = try await api.cancelScan(id: current.id)
        }
    }
}
