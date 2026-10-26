import Foundation

struct AppRuntime: Sendable {
    let backend: URL
    let seed: URL?
    let workspace: URL

    static func live(bundle: Bundle = .main) throws -> AppRuntime {
        guard let resources = bundle.resourceURL else { throw BackendError.resourcesMissing }
        let backend = resources.appending(path: "Backend", directoryHint: .isDirectory)
        guard FileManager.default.fileExists(atPath: backend.appending(path: "jobscout/gui.py").path) else {
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
    case unreadableResponse(String)

    var errorDescription: String? {
        switch self {
        case .resourcesMissing: "The bundled crawler is missing. Rebuild JobScout from its Xcode project."
        case .invalidPython: "Choose an executable Python 3.12 or newer in Settings."
        case .failed(let message): message
        case .unreadableResponse(let message): "Could not read the crawler response. \(message)"
        }
    }
}

protocol JobBackend: Sendable {
    func execute(_ command: [String], python: String) async throws -> JobSnapshot
}

actor BackendClient: JobBackend {
    private struct Running {
        let process: Process
        let directory: URL
        let continuation: CheckedContinuation<Data, any Error>
        var cancelled = false
    }

    private let runtime: AppRuntime
    private var running: [UUID: Running] = [:]

    init(runtime: AppRuntime) {
        self.runtime = runtime
    }

    func execute(_ command: [String], python: String) async throws -> JobSnapshot {
        try Task.checkCancellation()
        guard FileManager.default.isExecutableFile(atPath: python) else { throw BackendError.invalidPython }
        try runtime.prepare()
        let result = try await run(executable: python, arguments: ["-B", "-m", "jobscout.gui", "--workspace", runtime.workspace.path] + command)
        try Task.checkCancellation()
        do {
            return try JSONDecoder().decode(JobSnapshot.self, from: result)
        } catch {
            throw BackendError.unreadableResponse(error.localizedDescription)
        }
    }

    private func run(executable: String, arguments: [String]) async throws -> Data {
        let id = UUID()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                let directory = FileManager.default.temporaryDirectory.appending(path: "jobscout-\(id.uuidString)")
                do {
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    let output = directory.appending(path: "stdout")
                    let errors = directory.appending(path: "stderr")
                    FileManager.default.createFile(atPath: output.path, contents: nil)
                    FileManager.default.createFile(atPath: errors.path, contents: nil)
                    let stdout = try FileHandle(forWritingTo: output)
                    let stderr = try FileHandle(forWritingTo: errors)
                    defer {
                        try? stdout.close()
                        try? stderr.close()
                    }
                    let process = Process()
                    process.executableURL = URL(filePath: executable)
                    process.arguments = arguments
                    process.currentDirectoryURL = runtime.backend
                    process.standardInput = FileHandle.nullDevice
                    process.standardOutput = stdout
                    process.standardError = stderr
                    var environment = ProcessInfo.processInfo.environment
                    environment["PYTHONDONTWRITEBYTECODE"] = "1"
                    environment["PYTHONIOENCODING"] = "utf-8"
                    process.environment = environment
                    process.terminationHandler = { [weak self] process in
                        let exitCode = process.terminationStatus
                        Task { await self?.finished(id: id, exitCode: exitCode) }
                    }
                    running[id] = Running(process: process, directory: directory, continuation: continuation)
                    try process.run()
                } catch {
                    running.removeValue(forKey: id)
                    try? FileManager.default.removeItem(at: directory)
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            Task { await self.cancel(id: id) }
        }
    }

    private func cancel(id: UUID) {
        guard var operation = running[id] else { return }
        operation.cancelled = true
        running[id] = operation
        if operation.process.isRunning { operation.process.terminate() }
    }

    private func finished(id: UUID, exitCode: Int32) {
        guard let operation = running.removeValue(forKey: id) else { return }
        defer { try? FileManager.default.removeItem(at: operation.directory) }
        if operation.cancelled {
            operation.continuation.resume(throwing: CancellationError())
            return
        }
        do {
            if exitCode == 0 {
                let data = try Data(contentsOf: operation.directory.appending(path: "stdout"))
                operation.continuation.resume(returning: data)
            } else {
                let data = try Data(contentsOf: operation.directory.appending(path: "stderr"))
                let details = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                let message = details.isEmpty ? "The crawler stopped with exit code \(exitCode)." : details
                operation.continuation.resume(throwing: BackendError.failed(message))
            }
        } catch {
            operation.continuation.resume(throwing: error)
        }
    }
}
