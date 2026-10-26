import Foundation
import Testing
@testable import JobScout

enum Fixtures {
    static func job(id: Int = 1, status: ApplicationStatus = .new, score: Int = 85, decision: String = "review", role: String = "apple") throws -> Vacancy {
        let value: [String: Any] = [
            "id": id, "status": status.rawValue, "created": "2026-10-26T10:00:00+00:00", "updated": "2026-10-26T10:00:00+00:00", "kind": "new",
            "payload": ["source": "dou", "url": "https://example.com/\(id)", "title": "Senior iOS Engineer", "company": "Example", "location": "Remote", "salary": "", "published": "", "description": "Swift UIKit API debugging"],
            "assessment": ["score": score, "decision": decision, "role": role, "positive": ["Swift"], "negative": [], "missing": [], "uncertainty": ["Salary unknown"], "rejected": decision == "rejected" ? ["Mandatory relocation"] : [], "components": ["role": 30]],
            "listings": [["source": "dou", "url": "https://example.com/\(id)", "last_seen": "2026-10-26T10:00:00+00:00", "potentially_removed": 0]]
        ]
        return try JSONDecoder().decode(Vacancy.self, from: JSONSerialization.data(withJSONObject: value))
    }

    static func snapshot(jobs: [Vacancy]) -> JobSnapshot {
        JobSnapshot(jobs: jobs, lastRun: nil, workspace: "/tmp/test", reportPath: "/tmp/test/report.md", message: nil, minimumScore: 45, strongThreshold: 70)
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
}

actor RecordingBackend: JobBackend {
    private(set) var calls: [[String]] = []
    var jobs: [Vacancy]

    init(jobs: [Vacancy]) { self.jobs = jobs }

    func execute(_ command: [String], python: String) async throws -> JobSnapshot {
        calls.append(command)
        try await Task.sleep(for: .milliseconds(20))
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

    @Test func overlappingOperationsDoNotStartDuplicateProcesses() async throws {
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

@Suite("Process cancellation")
struct BackendProcessTests {
    @Test func cancellationTerminatesPythonAndNextCommandWorks() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let module = root.appending(path: "backend/jobscout")
        try FileManager.default.createDirectory(at: module, withIntermediateDirectories: true)
        try Data().write(to: module.appending(path: "__init__.py"))
        try Data().write(to: root.appending(path: "backend/config.toml"))
        let marker = root.appending(path: "started")
        let script = """
        import sys,time,pathlib
        if sys.argv[-1] == 'scan':
            pathlib.Path(\(String(reflecting: marker.path))).write_text('started')
            time.sleep(60)
        print(\(String(reflecting: Fixtures.emptyJSON)))
        """
        try script.write(to: module.appending(path: "gui.py"), atomically: true, encoding: .utf8)
        let client = BackendClient(runtime: AppRuntime(backend: root.appending(path: "backend"), seed: nil, workspace: root.appending(path: "workspace")))
        let task = Task { try await client.execute(["scan"], python: AppRuntime.defaultPython) }
        for _ in 0..<300 {
            if FileManager.default.fileExists(atPath: marker.path) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("Cancelled process returned success")
        } catch is CancellationError {
        }
        #expect(FileManager.default.fileExists(atPath: marker.path))
        let snapshot = try await client.execute(["snapshot"], python: AppRuntime.defaultPython)
        #expect(snapshot.jobs.isEmpty)
    }
}
