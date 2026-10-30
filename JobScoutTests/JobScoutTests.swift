//
//  JobScoutTests.swift
//  JobScout
//
//  Created by Andrii Bryzhnychenko on 10/29/26.
//

import Foundation
import Testing
@testable import JobScout

enum Fixtures {
    static func job(id: Int = 1, status: ApplicationStatus = .new, score: Int = 85, decision: String = "review", role: String = "apple", tracker: Bool = false) throws -> Vacancy {
        var value: [String: Any] = [
            "id": id, "status": status.rawValue, "created": "2026-10-26T10:00:00+00:00", "updated": "2026-10-26T10:00:00+00:00", "kind": "new",
            "payload": ["source": "dou", "url": "https://example.com/\(id)", "title": "Senior iOS Engineer", "company": "Example", "location": "Remote", "salary": "", "published": "", "description": "Swift UIKit API debugging"],
            "assessment": ["score": score, "decision": decision, "role": role, "positive": ["Swift"], "negative": [], "missing": [], "uncertainty": ["Salary unknown"], "rejected": decision == "rejected" ? ["Mandatory relocation"] : [], "components": ["role": 30]],
            "listings": [["source": "dou", "url": "https://example.com/\(id)", "last_seen": "2026-10-26T10:00:00+00:00", "potentially_removed": 0]]
        ]
        if tracker {
            value["tracker_entries"] = [["key": "record", "sheet": "iOS", "row": 2, "sheet_url": "https://docs.google.com/spreadsheets/d/test/edit#range=A2", "vacancy_url": "https://www.linkedin.com/jobs/view/1/", "original_status": "No response", "date_sent": "2026-10-01", "struck_out": true, "platform": "linkedin", "fields": ["notes": "Preparation note"]]]
        }
        return try JSONDecoder().decode(Vacancy.self, from: JSONSerialization.data(withJSONObject: value))
    }

    static func snapshot(jobs: [Vacancy]) -> JobSnapshot {
        JobSnapshot(jobs: jobs, lastRun: nil, workspace: "/tmp/test", reportPath: "/tmp/test/report.md", message: nil, minimumScore: 45, strongThreshold: 70, sources: nil)
    }

    static let emptyJSON = #"{"jobs":[],"last_run":null,"workspace":"/tmp/test","report_path":"/tmp/test/report.md","minimum_score":45,"strong_threshold":70}"#
}

@Suite("Vacancy review")
struct VacancyTests {
    @Test func dismissalAndAutomaticRejectionAreSeparate() throws {
        let filtered = try Fixtures.job(decision: "rejected")
        #expect(filtered.status == .new)
        #expect(Mailbox.audit.contains(filtered, minimumScore: 45, strongThreshold: 70))
        #expect(!Mailbox.inbox.contains(filtered, minimumScore: 45, strongThreshold: 70))
        let ignored = try Fixtures.job(status: .ignored)
        #expect(!Mailbox.strong.contains(ignored, minimumScore: 45, strongThreshold: 70))
        #expect(Mailbox.ignored.contains(ignored, minimumScore: 45, strongThreshold: 70))
    }

    @Test func lowScoresRemainAuditable() throws {
        let low = try Fixtures.job(score: 20)
        #expect(!Mailbox.inbox.contains(low, minimumScore: 45, strongThreshold: 70))
        #expect(Mailbox.all.contains(low, minimumScore: 45, strongThreshold: 70))
    }

    @Test func sqliteIntegerFlagsDecodeCorrectly() throws {
        #expect(try Fixtures.job().listings.first?.potentiallyRemoved == false)
        let data = Data(#"{"source":"dou","url":"https://example.com/1","last_seen":"today","potentially_removed":1}"#.utf8)
        #expect(try JSONDecoder().decode(SourceListing.self, from: data).potentiallyRemoved)
    }

    @Test func trackerStatusAndPlatformRemainSeparateFromVacancyData() throws {
        let job = try Fixtures.job(status: .applied, tracker: true)
        #expect(job.trackerEntries?.first?.originalStatus == "No response")
        #expect(job.trackerEntries?.first?.struckOut == true)
        #expect(job.hasSource("linkedin"))
        #expect(job.searchableText.contains("Preparation note"))
        #expect(!job.payload.description.contains("Preparation note"))
        #expect(Mailbox.tracker.contains(job, minimumScore: 45, strongThreshold: 70))
        #expect(!Mailbox.inbox.contains(job, minimumScore: 45, strongThreshold: 70))
    }
}

actor RecordingBackend: JobBackend {
    private(set) var calls: [[String]] = []
    var jobs: [Vacancy]
    private var cancelRequested = false

    func cancelScan() { cancelRequested = true }

    init(jobs: [Vacancy]) { self.jobs = jobs }

    func execute(_ command: [String], python: String) async throws -> JobSnapshot {
        calls.append(command)
        try await Task.sleep(for: .milliseconds(20))
        if cancelRequested { throw CancellationError() }
        if command.first == "status", let id = Int(command[1]), let index = jobs.firstIndex(where: { $0.id == id }), let status = ApplicationStatus(rawValue: command[2]) {
            jobs[index].status = status
        }
        return Fixtures.snapshot(jobs: jobs)
    }
}

@Suite("UI state ownership") @MainActor
struct JobStoreTests {
    private func wait(_ store: JobStore) async throws {
        for _ in 0..<200 {
            if !store.isBusy { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw BackendError.failed("Operation did not finish")
    }

    @Test func overlappingRequestsAreSerialized() async throws {
        let backend = RecordingBackend(jobs: [try Fixtures.job()])
        let store = JobStore(backend: backend)
        store.refresh()
        store.scan()
        try await wait(store)
        #expect(await backend.calls.count == 1)
        #expect(store.selection == 1)
    }

    @Test func statusChangeReconcilesSelectionAndKeepsSavedJob() async throws {
        let backend = RecordingBackend(jobs: [try Fixtures.job(), try Fixtures.job(id: 2)])
        let store = JobStore(backend: backend)
        store.refresh()
        try await wait(store)
        store.updateStatus(.ignored, for: 1)
        try await wait(store)
        #expect(store.selection == 2)
        #expect(store.visibleJobs.count == 1)
        store.mailbox = .ignored
        #expect(store.visibleJobs.first?.id == 1)
    }

    @Test func searchIncludesDescriptionAndFiltersPreserveIdentity() async throws {
        let backend = RecordingBackend(jobs: [try Fixtures.job(), try Fixtures.job(id: 2, role: "support")])
        let store = JobStore(backend: backend)
        store.refresh()
        try await wait(store)
        store.search = "debugging"
        store.role = .support
        #expect(store.visibleJobs.map(\.id) == [2])
        store.source = "djinni"
        #expect(store.visibleJobs.isEmpty)
    }

    @Test func cancellationDoesNotBecomeAnErrorAlert() async throws {
        let backend = RecordingBackend(jobs: [])
        let store = JobStore(backend: backend)
        store.scan()
        store.cancel()
        try await wait(store)
        #expect(store.errorMessage == nil)
        #expect(store.notice?.contains("Cancelled") == true)
    }

    @Test func quittingWaitsForCancellationToFinish() async throws {
        let backend = RecordingBackend(jobs: [])
        let store = JobStore(backend: backend)
        store.scan()
        await store.stopBeforeQuit()
        #expect(!store.isBusy)
        #expect(store.errorMessage == nil)
    }
}

@Suite("HTTP workflow")
struct BackendHTTPTests {
    @Test func importingAndStatusUseTheServiceDatabase() async throws {
        let harness = try await ServiceHarness.start()
        defer { harness.stop() }
        let client = harness.client
        let initial = try await client.execute(["snapshot"], python: AppRuntime.defaultPython)
        #expect(initial.jobs.isEmpty)
        let imported = try await client.execute(["import", harness.backend.appending(path: "examples/alerts.json").path], python: AppRuntime.defaultPython)
        #expect(imported.jobs.count == 3)
        let changed = try await client.execute(["status", "1", "Applied"], python: AppRuntime.defaultPython)
        #expect(changed.jobs.first { $0.id == 1 }?.status == .applied)
        let report = try await client.execute(["report"], python: AppRuntime.defaultPython)
        #expect(FileManager.default.fileExists(atPath: report.reportPath))
    }

    @Test func cancellingClientPollingLeavesScanRunningUntilExplicitCancel() async throws {
        let harness = try await ServiceHarness.start()
        defer { harness.stop() }
        let client = harness.client
        let task = Task { try await client.execute(["scan"], python: AppRuntime.defaultPython) }
        for _ in 0..<100 {
            if (try? await client.scanInProgress()) == true { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(try await client.scanInProgress())
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("Cancelled polling returned success")
        } catch is CancellationError {}
        #expect(try await client.scanInProgress())
        try await client.cancelScan()
        for _ in 0..<100 {
            if (try? await client.scanInProgress()) == false { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(try await !client.scanInProgress())
        let snapshot = try await client.execute(["snapshot"], python: AppRuntime.defaultPython)
        #expect(snapshot.jobs.isEmpty)
        let next = Task { try await client.execute(["scan"], python: AppRuntime.defaultPython) }
        for _ in 0..<100 {
            if (try? await client.scanInProgress()) == true { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(try await client.scanInProgress())
        try await client.cancelScan()
        do {
            _ = try await next.value
            Issue.record("Explicitly cancelled scan returned success")
        } catch is CancellationError {}
        #expect(try await !client.scanInProgress())
    }
}

private struct ServiceHarness {
    let process: Process
    let root: URL
    let backend: URL
    let client: BackendClient

    static func start() async throws -> ServiceHarness {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let backend = try AppRuntime.live().backend
        let portFile = root.appending(path: "port")
        let workspace = root.appending(path: "workspace")
        let token = String(repeating: "test-token", count: 4)
        let script = root.appending(path: "service.py")
        let source = """
        import pathlib,signal,sys,threading
        from jobscout.service import Service,HTTPServer
        service=Service(pathlib.Path(\(String(reflecting: workspace.path))),token=\(String(reflecting: token)))
        original=service.command
        def command(arguments):
            if arguments == ['scan']:
                return [sys.executable,'-c','import time;time.sleep(60)']
            return original(arguments)
        service.command=command
        server=HTTPServer(('127.0.0.1',0),service)
        pathlib.Path(\(String(reflecting: portFile.path))).write_text(str(server.server_port))
        def stop(*args):
            if service.current and service.busy():
                service.cancel(service.current)
            threading.Thread(target=server.shutdown).start()
        signal.signal(signal.SIGTERM,stop)
        server.serve_forever()
        server.server_close()
        """
        try source.write(to: script, atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(filePath: AppRuntime.defaultPython)
        process.arguments = ["-B", script.path]
        process.currentDirectoryURL = backend
        var environment = ProcessInfo.processInfo.environment
        environment["PYTHONPATH"] = backend.path
        process.environment = environment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.standardError
        try process.run()
        do {
            for _ in 0..<200 {
                if let port = try? String(contentsOf: portFile, encoding: .utf8), let number = Int(port) {
                    let client = BackendClient(runtime: AppRuntime(backend: backend, seed: nil, workspace: workspace), serverURL: URL(string: "http://127.0.0.1:\(number)")!, token: token)
                    return ServiceHarness(process: process, root: root, backend: backend, client: client)
                }
                guard process.isRunning else { throw BackendError.failed("Test HTTP service exited") }
                try await Task.sleep(for: .milliseconds(20))
            }
            throw BackendError.failed("Test HTTP service did not start")
        } catch {
            if process.isRunning { process.terminate(); process.waitUntilExit() }
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }

    func stop() {
        if process.isRunning { process.terminate(); process.waitUntilExit() }
        try? FileManager.default.removeItem(at: root)
    }
}
