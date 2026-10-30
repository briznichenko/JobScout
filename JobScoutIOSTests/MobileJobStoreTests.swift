//
//  MobileJobStoreTests.swift
//  JobScout
//
//  Created by Andrii Bryzhnychenko on 10/29/26.
//

import Foundation
import JobScoutKit
import Testing
@testable import JobScoutIOS

private final class FixtureResponses: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: @Sendable (URLRequest) throws -> (Int, Data) = { _ in (500, Data()) }

    func set(_ handler: @escaping @Sendable (URLRequest) throws -> (Int, Data)) {
        lock.lock()
        defer { lock.unlock() }
        self.handler = handler
    }

    func response(_ request: URLRequest) throws -> (Int, Data) {
        lock.lock()
        let value = handler
        lock.unlock()
        return try value(request)
    }
}

private final class FixtureProtocol: URLProtocol, @unchecked Sendable {
    static let responses = FixtureResponses()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        do {
            let (code, data) = try Self.responses.response(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
}

@Suite(.serialized) @MainActor
struct MobileJobStoreTests {
    private let snapshot = #"{"jobs":[],"last_run":null,"workspace":"/server","report_path":"/server/report","minimum_score":45,"strong_threshold":70}"#

    private func client() -> JobScoutAPI {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FixtureProtocol.self]
        return JobScoutAPI(baseURL: URL(string: "http://fixture.local:8765")!, token: "fixture-token", session: URLSession(configuration: config))
    }

    @Test func refreshRecoversServerScanAndCancellationIsExplicit() async {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let data = snapshot
        FixtureProtocol.responses.set { request in
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-token")
            if request.url?.path == "/v1/snapshot" { return (200, Data(data.utf8)) }
            if request.url?.path == "/v1/scans/current" {
                return (200, Data(#"{"operation":{"id":"scan-1","state":"running","message":"Searching","started":"today","finished":null}}"#.utf8))
            }
            #expect(request.httpMethod == "POST")
            #expect(request.url?.path == "/v1/scans/scan-1/cancel")
            return (200, Data(#"{"id":"scan-1","state":"cancelled","message":"Cancelled","started":"today","finished":"now"}"#.utf8))
        }
        let store = MobileJobStore(api: client(), cacheDirectory: directory)
        await store.refresh()
        #expect(store.snapshot != nil)
        #expect(store.scanning)
        #expect(!store.isCached)
        await store.cancelScan()
        #expect(!store.scanning)
        #expect(store.operation?.state == "cancelled")
        #expect(store.errorMessage == nil)
    }

    @Test func disconnectedRefreshKeepsCachedReadingAndDoesNotInventSuccess() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        defaults.set("http://fixture.local:8765", forKey: "serverAddress")
        let value = try JSONDecoder().decode(JobSnapshot.self, from: Data(snapshot.utf8))
        try SnapshotCache(directory: directory, serverURL: URL(string: "http://fixture.local:8765")!).save(value)
        FixtureProtocol.responses.set { _ in throw URLError(.notConnectedToInternet) }
        let store = MobileJobStore(defaults: defaults, api: client(), cacheDirectory: directory)
        #expect(store.isCached)
        await store.refresh()
        #expect(store.snapshot?.workspace == "/server")
        #expect(store.isCached)
        #expect(store.errorMessage?.contains("Could not connect") == true)
        await store.startScan()
        #expect(store.operation == nil)
        #expect(!store.isBusy)
    }

    @Test func filtersIntersectAndResetKeepsMailboxAndSort() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await loadedStore(jobs: [
            vacancy(id: 1, score: 80, title: "Swift engineer", source: "dou"),
            vacancy(id: 2, score: 90, title: "Swift support", role: "support", source: "dou"),
            vacancy(id: 3, score: 85, title: "Swift engineer", source: "linkedin"),
            vacancy(id: 4, score: 75, title: "Kotlin engineer", source: "dou")
        ], directory: directory)
        store.mailbox = .strong
        store.role = .apple
        store.source = "dou"
        store.search = "swift"
        store.sort = .recent
        #expect(store.jobs.map(\.id) == [1])
        #expect(store.hasFilters)

        store.resetFilters()

        #expect(!store.hasFilters)
        #expect(store.search.isEmpty)
        #expect(store.role == .all)
        #expect(store.source == "All sources")
        #expect(store.mailbox == .strong)
        #expect(store.sort == .recent)
        #expect(store.jobs.count == 4)
    }

    @Test func recentSortUsesScoreThenStableIDForMatchingDates() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await loadedStore(jobs: [
            vacancy(id: 4, score: 80, created: "2026-10-28T12:00:00Z"),
            vacancy(id: 3, score: 80, created: "2026-10-28T12:00:00Z"),
            vacancy(id: 2, score: 90, created: "2026-10-28T12:00:00Z"),
            vacancy(id: 1, score: 50, created: "2026-10-29T12:00:00Z")
        ], directory: directory)
        store.mailbox = .all
        #expect(store.jobs.map(\.id) == [2, 3, 4, 1])
        store.sort = .recent
        #expect(store.jobs.map(\.id) == [1, 2, 3, 4])
    }

    @Test func mailboxCountsIgnorePresentationFiltersAndRespectServerThresholds() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await loadedStore(jobs: [
            vacancy(id: 1, score: 80),
            vacancy(id: 2, score: 60),
            vacancy(id: 3, score: 90, status: .applied),
            vacancy(id: 4, score: 95, decision: "rejected"),
            vacancy(id: 5, score: 40)
        ], directory: directory)
        store.search = "does not match"
        store.role = .support
        store.source = "linkedin"

        #expect(store.jobs.isEmpty)
        #expect(store.count(.inbox) == 2)
        #expect(store.count(.strong) == 1)
        #expect(store.count(.applied) == 1)
        #expect(store.count(.audit) == 1)
        #expect(store.count(.all) == 5)
        #expect(store.sources == ["dou", "linkedin"])
    }

    private func loadedStore(jobs: [Vacancy], directory: URL) async throws -> MobileJobStore {
        let snapshot = JobSnapshot(jobs: jobs, lastRun: nil, workspace: "/server", reportPath: "/server/report", message: nil, minimumScore: 55, strongThreshold: 75, sources: [
            SourceInfo(id: "linkedin", mode: "import", enabled: true, count: 0, failures: [], searchURL: "", directory: "")
        ])
        let data = try JSONEncoder().encode(snapshot)
        FixtureProtocol.responses.set { request in
            if request.url?.path == "/v1/snapshot" { return (200, data) }
            #expect(request.url?.path == "/v1/scans/current")
            return (200, Data(#"{"operation":null}"#.utf8))
        }
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let store = MobileJobStore(defaults: defaults, api: client(), cacheDirectory: directory)
        await store.refresh()
        #expect(store.errorMessage == nil)
        return store
    }

    private func vacancy(id: Int, score: Int, title: String = "Engineer", role: String = "apple", source: String = "dou", created: String = "2026-10-29T12:00:00Z", status: ApplicationStatus = .new, decision: String = "accepted") -> Vacancy {
        Vacancy(id: id, status: status, created: created, updated: created, kind: "new", payload: VacancyContent(source: source, url: "https://example.com/jobs/\(id)", title: title, description: "", company: "Example", location: "Remote", salary: "", published: created), assessment: Assessment(score: score, decision: decision, role: role, positive: [], negative: [], missing: [], uncertainty: [], rejected: [], components: [:]), listings: [SourceListing(source: source, url: "https://example.com/jobs/\(id)", lastSeen: created, potentiallyRemoved: false)], trackerEntries: nil)
    }
}
