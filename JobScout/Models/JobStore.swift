//
//  JobStore.swift
//  JobScout
//
//  Created by Andrii Bryzhnychenko on 10/29/26.
//

import AppKit
import Foundation
import Observation
import JobScoutKit

@MainActor @Observable
final class JobStore {
    private(set) var snapshot: JobSnapshot?
    private(set) var isBusy = false
    private(set) var activity = ""
    private(set) var isScanning = false
    private(set) var notice: String?
    var errorMessage: String?
    var selection: Int?
    var mailbox: Mailbox? = .inbox
    var search = ""
    var role: RoleFilter = .all
    var source = "All sources"
    var sort: VacancySort = .fit
    var pythonPath: String
    var serverAddress: String
    var serverToken: String
    private(set) var isOffline = false
    var showsSettings = false
    var requestedImport: String?
    var rulesText = ""
    var showsRulesEditor = false

    @ObservationIgnored private let backend: (any JobBackend)?
    @ObservationIgnored private let runtime: AppRuntime?
    @ObservationIgnored private var operation: Task<Void, Never>?
    @ObservationIgnored private var wantsScanCancellation = false
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var cache: SnapshotCache?

    init(backend: (any JobBackend)? = nil, runtime: AppRuntime? = nil, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let address = defaults.string(forKey: "serverAddress") ?? "http://127.0.0.1:8765"
        let token = MacCredentialStore.load(server: address)
        serverAddress = address
        serverToken = token
        pythonPath = defaults.string(forKey: "pythonPath") ?? AppRuntime.defaultPython
        if let backend {
            self.backend = backend
            self.runtime = runtime
        } else {
            do {
                let resolved = try runtime ?? AppRuntime.live()
                self.runtime = resolved
                self.backend = BackendClient(runtime: resolved, serverURL: URL(string: address) ?? URL(string: "http://127.0.0.1:8765")!, token: token)
            } catch {
                self.runtime = nil
                self.backend = nil
                errorMessage = error.localizedDescription
            }
        }
        if backend == nil, let url = URL(string: address), let directory = try? FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true) {
            let snapshotCache = SnapshotCache(directory: directory.appending(path: "JobScout"), serverURL: url)
            cache = snapshotCache
            let saved = snapshotCache.load()
            snapshot = saved
            isOffline = saved != nil
        }
    }

    var jobs: [Vacancy] { snapshot?.jobs ?? [] }
    var selectedJob: Vacancy? { jobs.first { $0.id == selection } }
    var sources: [String] { snapshot?.sourceIDs ?? [] }
    var workspace: URL? { isLocalServer ? runtime?.workspace : nil }
    var isLocalServer: Bool {
        guard let url = URL(string: serverAddress) else { return false }
        return ["localhost", "127.0.0.1", "::1"].contains(url.host ?? "")
    }

    var visibleJobs: [Vacancy] {
        snapshot?.vacancies(in: mailbox ?? .inbox, role: role, source: source, search: search, sort: sort) ?? []
    }

    func count(_ mailbox: Mailbox) -> Int {
        snapshot?.count(in: mailbox) ?? 0
    }

    func refresh() {
        perform(.snapshot, activity: "Loading vacancies…")
    }

    func scan() {
        perform(.scan, activity: "Searching configured sources…", completion: "Search complete")
    }

    func updateStatus(_ status: ApplicationStatus, for id: Int) {
        perform(.updateStatus(status, id: id), activity: "Saving status…", completion: "Status saved")
    }

    func importFile(_ url: URL, adapter: String?) {
        perform(.importFile(url, kind: .vacancies(adapter: adapter)), activity: "Importing vacancies…", completion: "Import complete")
    }

    func importTracker(_ url: URL) {
        perform(.importFile(url, kind: .tracker), activity: "Importing application tracker…", completion: "Application tracker imported")
    }

    func importSource(_ url: URL, source: String) {
        perform(.importFile(url, kind: .source(source)), activity: "Importing \(sourceName(source))…", completion: "Source imported")
    }

    func rescore() {
        perform(.rescore, activity: "Recalculating fit scores…", completion: "Fit scores updated")
    }

    func openReport() {
        perform(.report, activity: "Generating report…", openReport: true)
    }

    func saveSettings() {
        guard !isBusy else { return }
        errorMessage = nil
        serverToken = serverToken.trimmingCharacters(in: .whitespacesAndNewlines)
        pythonPath = NSString(string: pythonPath.trimmingCharacters(in: .whitespacesAndNewlines)).expandingTildeInPath
        guard let url = URL(string: serverAddress.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["http", "https"].contains(url.scheme), url.host != nil, url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil, url.path.isEmpty || url.path == "/" else {
            errorMessage = "Enter an HTTP or HTTPS server address, including its port."
            return
        }
        serverAddress = url.absoluteString
        do { try MacCredentialStore.save(serverToken, server: serverAddress) }
        catch { errorMessage = error.localizedDescription; return }
        defaults.set(pythonPath, forKey: "pythonPath")
        defaults.set(serverAddress, forKey: "serverAddress")
        if let directory = try? FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true) {
            cache = SnapshotCache(directory: directory.appending(path: "JobScout"), serverURL: url)
            snapshot = cache?.load()
            isOffline = snapshot != nil
            selection = nil
        }
        refresh()
    }

    func loadServerRules() {
        guard !isBusy, let client = backend as? BackendClient else { return }
        isBusy = true
        activity = "Loading server rules…"
        let executable = pythonPath
        operation = Task {
            defer { isBusy = false; activity = ""; operation = nil }
            do {
                let settings = try await client.settings(python: executable)
                try Task.checkCancellation()
                rulesText = settings.config
                showsRulesEditor = true
            } catch is CancellationError {
            } catch { errorMessage = error.localizedDescription }
        }
    }

    func saveServerRules() {
        guard !isBusy, let client = backend as? BackendClient else { return }
        isBusy = true
        activity = "Saving server rules…"
        let config = rulesText
        let executable = pythonPath
        operation = Task {
            defer { isBusy = false; activity = ""; operation = nil }
            do {
                try await client.saveSettings(config, python: executable)
                try Task.checkCancellation()
                showsRulesEditor = false
                notice = "Rules saved. Recalculate scores to apply them to saved vacancies."
            } catch is CancellationError {
            } catch { errorMessage = error.localizedDescription }
        }
    }

    func cancel() {
        guard let backend else { return }
        guard isScanning else { operation?.cancel(); return }
        wantsScanCancellation = true
        Task {
            do {
                try await backend.cancelScan()
            } catch { errorMessage = error.localizedDescription }
        }
    }

    func stopBeforeQuit() async {
        let pending = operation
        pending?.cancel()
        await pending?.value
    }

    private func perform(_ command: BackendCommand, activity: String, completion: String? = nil, openReport: Bool = false) {
        guard !isBusy, let backend else { return }
        isBusy = true
        wantsScanCancellation = false
        isScanning = command.isScan
        self.activity = activity
        notice = nil
        let executable = pythonPath
        let address = serverAddress
        let token = serverToken
        operation = Task {
            var resumeScan = false
            defer {
                isBusy = false
                isScanning = false
                self.activity = ""
                operation = nil
                if resumeScan && !Task.isCancelled { perform(.resumeScan, activity: "Search running on server…", completion: "Search complete") }
            }
            do {
                if let client = backend as? BackendClient, let url = URL(string: address) {
                    await client.configure(serverURL: url, token: token)
                }
                if isScanning && wantsScanCancellation { throw CancellationError() }
                let result = try await backend.execute(command, python: executable)
                try Task.checkCancellation()
                snapshot = result
                errorMessage = nil
                isOffline = false
                try? cache?.save(result)
                notice = completion
                if command.isScan, let failures = result.lastRun?.failures, !failures.isEmpty {
                    notice = "Search finished with \(failures.count) source issue(s). Successful results are saved."
                }
                reconcileSelection()
                if command == .snapshot { resumeScan = (try? await backend.scanInProgress()) ?? false }
                if openReport {
                    if isLocalServer { NSWorkspace.shared.open(URL(filePath: result.reportPath)) }
                    else { notice = "Report generated on the server at \(result.reportPath)." }
                }
            } catch is CancellationError {
                notice = "Cancelled. Refresh to see any work saved before cancellation."
            } catch {
                isOffline = snapshot != nil
                errorMessage = error.localizedDescription
                if isOffline { notice = "Showing cached vacancies. Connect to the server to refresh or make changes." }
            }
        }
    }

    func reconcileSelection() {
        if !visibleJobs.contains(where: { $0.id == selection }) {
            selection = visibleJobs.first?.id
        }
    }
}
