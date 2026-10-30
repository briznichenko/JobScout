//
//  JobStore.swift
//  JobScout
//
//  Created by Andrii Bryzhnychenko on 10/29/26.
//

import AppKit
import Foundation
import Observation

@MainActor @Observable
final class JobStore {
    private(set) var snapshot: JobSnapshot?
    private(set) var isBusy = false
    private(set) var activity = ""
    private(set) var notice: String?
    var errorMessage: String?
    var selection: Int?
    var mailbox: Mailbox? = .inbox
    var search = ""
    var role: RoleFilter = .all
    var source = "All sources"
    var sort: VacancySort = .fit
    var pythonPath: String
    var showsSettings = false
    var requestedImport: String?

    @ObservationIgnored private let backend: (any JobBackend)?
    @ObservationIgnored private let runtime: AppRuntime?
    @ObservationIgnored private var operation: Task<Void, Never>?
    @ObservationIgnored private let defaults: UserDefaults

    init(backend: (any JobBackend)? = nil, runtime: AppRuntime? = nil, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        pythonPath = defaults.string(forKey: "pythonPath") ?? AppRuntime.defaultPython
        if let backend {
            self.backend = backend
            self.runtime = runtime
        } else {
            do {
                let resolved = try runtime ?? AppRuntime.live()
                self.runtime = resolved
                self.backend = BackendClient(runtime: resolved)
            } catch {
                self.runtime = nil
                self.backend = nil
                errorMessage = error.localizedDescription
            }
        }
    }

    var jobs: [Vacancy] { snapshot?.jobs ?? [] }
    var minimumScore: Int { snapshot?.minimumScore ?? 45 }
    var strongThreshold: Int { snapshot?.strongThreshold ?? 70 }
    var selectedJob: Vacancy? { jobs.first { $0.id == selection } }
    var sources: [String] { Set(jobs.flatMap { $0.listings.map(\.source) } + (snapshot?.sources ?? []).map(\.id)).sorted() }
    var workspace: URL? { runtime?.workspace }

    var visibleJobs: [Vacancy] {
        let selectedMailbox = mailbox ?? .inbox
        return jobs.filter { job in
            selectedMailbox.contains(job, minimumScore: minimumScore, strongThreshold: strongThreshold)
                && (role == .all || job.assessment.role == role.rawValue.lowercased())
                && (source == "All sources" || job.hasSource(source))
                && (search.isEmpty || job.searchableText.localizedStandardContains(search))
        }.sorted { left, right in
            if sort == .recent, left.created != right.created { return left.created > right.created }
            if left.assessment.score != right.assessment.score { return left.assessment.score > right.assessment.score }
            return left.id < right.id
        }
    }

    func count(_ mailbox: Mailbox) -> Int {
        jobs.filter { mailbox.contains($0, minimumScore: minimumScore, strongThreshold: strongThreshold) }.count
    }

    func refresh() {
        perform(["snapshot"], activity: "Loading vacancies…")
    }

    func scan() {
        perform(["scan"], activity: "Searching configured sources…", completion: "Search complete")
    }

    func updateStatus(_ status: ApplicationStatus, for id: Int) {
        perform(["status", String(id), status.rawValue], activity: "Saving status…", completion: "Status saved")
    }

    func importFile(_ url: URL, adapter: String?) {
        var command = ["import", url.path]
        if let adapter { command += ["--adapter", adapter] }
        perform(command, activity: "Importing vacancies…", completion: "Import complete")
    }

    func importTracker(_ url: URL) {
        perform(["import-tracker", url.path], activity: "Importing application tracker…", completion: "Application tracker imported")
    }

    func importSource(_ url: URL, source: String) {
        perform(["import-source", url.path, "--source", source], activity: "Importing \(sourceName(source))…", completion: "Source imported")
    }

    func rescore() {
        perform(["rescore"], activity: "Recalculating fit scores…", completion: "Fit scores updated")
    }

    func openReport() {
        perform(["report"], activity: "Generating report…", openReport: true)
    }

    func saveSettings() {
        pythonPath = NSString(string: pythonPath.trimmingCharacters(in: .whitespacesAndNewlines)).expandingTildeInPath
        defaults.set(pythonPath, forKey: "pythonPath")
        refresh()
    }

    func cancel() {
        operation?.cancel()
    }

    func stopBeforeQuit() async {
        let pending = operation
        pending?.cancel()
        await pending?.value
    }

    private func perform(_ command: [String], activity: String, completion: String? = nil, openReport: Bool = false) {
        guard !isBusy, let backend else { return }
        isBusy = true
        self.activity = activity
        notice = nil
        let executable = pythonPath
        operation = Task {
            defer {
                isBusy = false
                self.activity = ""
                operation = nil
            }
            do {
                let result = try await backend.execute(command, python: executable)
                try Task.checkCancellation()
                snapshot = result
                notice = completion
                if command.first == "scan", let failures = result.lastRun?.failures, !failures.isEmpty {
                    notice = "Search finished with \(failures.count) source issue(s). Successful results are saved."
                }
                reconcileSelection()
                if openReport { NSWorkspace.shared.open(URL(filePath: result.reportPath)) }
            } catch is CancellationError {
                notice = "Cancelled. Refresh to see any work saved before cancellation."
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func reconcileSelection() {
        if !visibleJobs.contains(where: { $0.id == selection }) {
            selection = visibleJobs.first?.id
        }
    }
}
