//
//  MobileJobStore.swift
//  JobScout
//
//  Created by Andrii Bryzhnychenko on 10/29/26.
//

import Foundation
import JobScoutKit
import Observation

@MainActor @Observable
final class MobileJobStore {
    private(set) var snapshot: JobSnapshot?
    private(set) var operation: ScanOperation?
    private(set) var isBusy = false
    private(set) var isCached = false
    private(set) var connectionRevision = 0
    var errorMessage: String?
    var notice: String?
    var search = ""
    var role: RoleFilter = .all
    var source = "All sources"
    var sort: VacancySort = .fit
    var mailbox: Mailbox = .inbox
    var serverAddress: String
    var token: String

    @ObservationIgnored private var api: JobScoutAPI?
    @ObservationIgnored private var serverIdentity: String
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let cacheDirectory: URL

    init(defaults: UserDefaults = .standard, api: JobScoutAPI? = nil, cacheDirectory: URL = URL.applicationSupportDirectory.appending(path: "JobScoutCache", directoryHint: .isDirectory)) {
        self.defaults = defaults
        self.cacheDirectory = cacheDirectory
        let server = defaults.string(forKey: "serverAddress") ?? "http://Mac.local:8765"
        serverAddress = server
        serverIdentity = server
        token = api == nil ? IOSCredentialStore.read(server: server) : ""
        configure()
        if let api { self.api = api }
    }

    var sources: [String] {
        snapshot?.sourceIDs ?? []
    }

    var hasFilters: Bool { !search.isEmpty || role != .all || source != "All sources" }

    var jobs: [Vacancy] {
        snapshot?.vacancies(in: mailbox, role: role, source: source, search: search, sort: sort) ?? []
    }

    func count(_ mailbox: Mailbox) -> Int {
        snapshot?.count(in: mailbox) ?? 0
    }

    func resetFilters() {
        search = ""
        role = .all
        source = "All sources"
    }

    var scanning: Bool { operation?.isRunning == true }

    func saveConnection() {
        let address = serverAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: address), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.host != nil, url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil,
              url.path.isEmpty || url.path == "/" else {
            errorMessage = "Enter a server address such as http://your-mac.local:8765."
            return
        }
        do {
            token = token.trimmingCharacters(in: .whitespacesAndNewlines)
            try IOSCredentialStore.save(token, server: address)
            defaults.set(address, forKey: "serverAddress")
            serverAddress = address
            serverIdentity = address
            connectionRevision += 1
            snapshot = nil
            operation = nil
            errorMessage = nil
            notice = nil
            isBusy = false
            configure()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func observeServer() async {
        let revision = connectionRevision
        await refresh()
        while !Task.isCancelled, revision == connectionRevision {
            do {
                try await Task.sleep(for: .seconds(scanning ? 2 : 10))
                guard revision == connectionRevision, !isBusy, let api else { continue }
                let prior = scanning
                let reconnecting = isCached || errorMessage != nil
                let current = try await api.currentScan()
                try Task.checkCancellation()
                guard revision == connectionRevision else { return }
                operation = current
                if prior && !scanning {
                    notice = current?.message ?? "Search \(current?.state ?? "finished")."
                }
                if (prior && !scanning) || reconnecting { await refresh() }
            } catch is CancellationError {
                return
            } catch {
                guard revision == connectionRevision else { return }
                errorMessage = error.localizedDescription
                isCached = snapshot != nil
            }
        }
    }

    func refresh() async {
        guard !isBusy, let api else { return }
        let revision = connectionRevision
        isBusy = true
        defer { if revision == connectionRevision { isBusy = false } }
        do {
            let value = try await api.snapshot()
            let current = try await api.currentScan()
            try Task.checkCancellation()
            guard revision == connectionRevision else { return }
            accept(value)
            operation = current
            errorMessage = nil
        } catch is CancellationError {
        } catch {
            guard revision == connectionRevision else { return }
            errorMessage = error.localizedDescription
            isCached = snapshot != nil
        }
    }

    func startScan() async {
        guard !isBusy, !scanning, let api else { return }
        let revision = connectionRevision
        isBusy = true
        defer { if revision == connectionRevision { isBusy = false } }
        do {
            let value = try await api.startScan()
            guard revision == connectionRevision else { return }
            operation = value
            errorMessage = nil
            notice = nil
        } catch {
            guard revision == connectionRevision else { return }
            errorMessage = error.localizedDescription
        }
    }

    func cancelScan() async {
        guard !isBusy, let id = operation?.id, let api else { return }
        let revision = connectionRevision
        isBusy = true
        defer { if revision == connectionRevision { isBusy = false } }
        do {
            let value = try await api.cancelScan(id: id)
            guard revision == connectionRevision else { return }
            operation = value
            notice = value.message ?? "Cancellation requested."
        } catch {
            guard revision == connectionRevision else { return }
            errorMessage = error.localizedDescription
        }
    }

    func updateStatus(_ status: ApplicationStatus, id: Int) async {
        guard !isBusy, let api else { return }
        let revision = connectionRevision
        isBusy = true
        defer { if revision == connectionRevision { isBusy = false } }
        do {
            let value = try await api.updateStatus(status, for: id)
            try Task.checkCancellation()
            guard revision == connectionRevision else { return }
            accept(value)
            errorMessage = nil
        } catch is CancellationError {
        } catch {
            guard revision == connectionRevision else { return }
            errorMessage = error.localizedDescription
        }
    }

    private func configure() {
        guard let url = URL(string: serverIdentity) else { return }
        api = JobScoutAPI(baseURL: url, token: token)
        if let value = cache()?.load() {
            snapshot = value
            isCached = true
        }
    }

    private func accept(_ value: JobSnapshot) {
        snapshot = value
        isCached = false
        do {
            try cache()?.save(value)
        } catch {
            notice = "Loaded vacancies, but could not save an offline copy."
        }
    }

    private func cache() -> SnapshotCache? {
        guard let url = URL(string: serverIdentity) else { return nil }
        return SnapshotCache(directory: cacheDirectory, serverURL: url)
    }
}
