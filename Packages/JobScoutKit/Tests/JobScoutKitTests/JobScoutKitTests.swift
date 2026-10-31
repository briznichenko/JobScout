//
//  JobScoutKitTests.swift
//  JobScout
//
//  Created by Andrii Bryzhnychenko on 10/29/26.
//

import Foundation
import Testing
@testable import JobScoutKit

private let emptySnapshot = #"{"jobs":[],"last_run":null,"workspace":"/tmp/test","report_path":"/tmp/test/report.md","minimum_score":45,"strong_threshold":70}"#

private final class ResponseStore: @unchecked Sendable {
    private let lock = NSLock()
    private var response: @Sendable (URLRequest) throws -> (Int, Data) = { _ in (500, Data()) }

    func set(_ response: @escaping @Sendable (URLRequest) throws -> (Int, Data)) {
        lock.lock()
        defer { lock.unlock() }
        self.response = response
    }

    func respond(_ request: URLRequest) throws -> (Int, Data) {
        lock.lock()
        let handler = response
        lock.unlock()
        return try handler(request)
    }
}

private final class MockProtocol: URLProtocol, @unchecked Sendable {
    static let store = ResponseStore()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        do {
            let (code, data) = try Self.store.respond(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
}

@Suite(.serialized)
struct JobScoutKitTests {
    private func api() -> JobScoutAPI {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockProtocol.self]
        return JobScoutAPI(baseURL: URL(string: "http://localhost:8765")!, token: "test-secret", session: URLSession(configuration: configuration))
    }

    @Test func authenticatedStatusUsesCorrectRoute() async throws {
        MockProtocol.store.set { request in
            #expect(request.url?.path == "/v1/vacancies/42/status")
            #expect(request.httpMethod == "PATCH")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-secret")
            return (200, Data(emptySnapshot.utf8))
        }
        let result = try await api().updateStatus(.applied, for: 42)
        #expect(result.minimumScore == 45)
    }

    @Test func unauthorizedAndConflictAreDistinct() async throws {
        let client = api()
        MockProtocol.store.set { _ in (401, Data(#"{"error":"Denied"}"#.utf8)) }
        do {
            _ = try await client.snapshot()
            Issue.record("Unauthorized request succeeded")
        } catch APIError.unauthorized {}
        MockProtocol.store.set { _ in (409, Data(#"{"error":"Scan already running"}"#.utf8)) }
        do {
            _ = try await client.startScan()
            Issue.record("Overlapping scan succeeded")
        } catch APIError.conflict(let message) {
            #expect(message == "Scan already running")
        }
    }

    @Test func reconnectFindsServerOwnedScan() async throws {
        MockProtocol.store.set { request in
            #expect(request.url?.path == "/v1/scans/current")
            return (200, Data(#"{"operation":{"id":"abc","state":"running","started":"2026-10-29","finished":null,"message":"Searching"}}"#.utf8))
        }
        let operation = try await api().currentScan()
        #expect(operation?.id == "abc")
        #expect(operation?.isRunning == true)
    }

    @Test func cacheRoundTripsSQLiteFlagsAndSeparatesServers() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = SnapshotCache(directory: directory, serverURL: URL(string: "http://mac.local:8765")!)
        let job = Vacancy(id: 1, status: .new, created: "now", updated: "now", kind: "new", payload: VacancyContent(source: "dou", url: "https://example.com", title: "iOS", description: "Swift", company: "Test", location: "Remote", salary: "", published: ""), assessment: Assessment(score: 80, decision: "review", role: "apple", positive: [], negative: [], missing: [], uncertainty: [], rejected: [], components: [:]), listings: [SourceListing(source: "dou", url: "https://example.com", lastSeen: "now", potentiallyRemoved: false)], trackerEntries: nil)
        let snapshot = JobSnapshot(jobs: [job], lastRun: nil, workspace: "/tmp/test", reportPath: "", message: nil, minimumScore: 45, strongThreshold: 70, sources: nil)
        try cache.save(snapshot)
        #expect(cache.load()?.jobs.first?.isActive == true)
        let other = SnapshotCache(directory: directory, serverURL: URL(string: "http://other.local:8765")!)
        #expect(other.load() == nil)
        let encoded = try JSONEncoder().encode(job.listings[0])
        let object = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        #expect(object["potentially_removed"] as? Int == 0)
    }

    @Test func snapshotQueriesRespectThresholdsAndTrackerSources() {
        let job = Vacancy(
            id: 2, status: .new, created: "2026-10-29", updated: "2026-10-29", kind: "new",
            payload: VacancyContent(
                source: "dou", url: "https://example.com/2", title: "Swift engineer", description: "UIKit",
                company: "Example", location: "Remote", salary: "", published: ""
            ),
            assessment: Assessment(
                score: 80, decision: "review", role: "apple", positive: [], negative: [],
                missing: [], uncertainty: [], rejected: [], components: [:]
            ),
            listings: [SourceListing(source: "dou", url: "https://example.com/2", lastSeen: "today", potentiallyRemoved: false)],
            trackerEntries: [TrackerEntry(
                key: "row", sheet: "iOS", row: 2, sheetURL: "https://example.com/tracker",
                vacancyURL: "https://example.com/2", originalStatus: "Draft", dateSent: "", struckOut: false,
                fields: ["notes": "Interview preparation"], platform: "linkedin"
            )]
        )
        let snapshot = JobSnapshot(
            jobs: [job], lastRun: nil, workspace: "/test", reportPath: "", message: nil,
            minimumScore: 85, strongThreshold: 90,
            sources: [SourceInfo(id: "linkedin", mode: "import", enabled: true, count: 0, failures: [], searchURL: "", directory: "")]
        )
        #expect(snapshot.count(in: .inbox) == 0)
        #expect(snapshot.count(in: .strong) == 0)
        #expect(snapshot.count(in: .tracker) == 1)
        #expect(snapshot.sourceIDs == ["dou", "linkedin"])
        #expect(snapshot.vacancies(in: .all, role: .apple, source: "linkedin", search: "preparation", sort: .fit).map(\.id) == [2])
        #expect(snapshot.vacancies(in: .all, role: .support, source: "All sources", search: "", sort: .fit).isEmpty)
    }

    @Test func malformedAddressFailsBeforeNetworkAccess() async throws {
        let client = JobScoutAPI(baseURL: URL(string: "file:///tmp/server")!, token: "token")
        do {
            _ = try await client.snapshot()
            Issue.record("Invalid address succeeded")
        } catch APIError.invalidAddress {}
    }
}
