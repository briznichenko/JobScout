import JobScoutKit
import SwiftUI

struct MobileVacanciesView: View {
    @Bindable var store: MobileJobStore
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var showsSettings = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    filters
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                if store.isCached || store.errorMessage != nil || store.notice != nil || store.scanning || !(store.snapshot?.lastRun?.failures.isEmpty ?? true) {
                    Section { connectionStatus }
                }
                Section {
                    ForEach(store.jobs) { vacancy in
                        NavigationLink(value: vacancy.id) {
                            MobileVacancyRow(job: vacancy)
                        }
                        .contextMenu {
                            ForEach(ApplicationStatus.allCases) { status in
                                Button("Mark \(status.rawValue)") {
                                    Task { await store.updateStatus(status, id: vacancy.id) }
                                }
                                .disabled(store.isBusy || store.isCached || vacancy.status == status)
                            }
                        }
                    }
                    if store.jobs.isEmpty { emptyState }
                } header: {
                    HStack {
                        Text("Vacancies")
                        Spacer()
                        Text(store.jobs.count, format: .number).monospacedDigit()
                    }
                } footer: {
                    if store.mailbox == .audit {
                        Text("Automatic filtering is separate from application status.")
                    } else if let scan = store.snapshot?.lastRun {
                        Text("Last search \(readableDate(scan.finished))")
                    }
                }
            }
            .listStyle(.insetGrouped)
            .searchable(text: $store.search, prompt: "Search vacancies")
            .navigationTitle(store.mailbox.rawValue)
            .navigationDestination(for: Int.self) { id in
                MobileVacancyDetailView(store: store, id: id)
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { mailboxMenu }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button("Connection", systemImage: "gear") { showsSettings = true }
                    Button("Search sources", systemImage: "arrow.clockwise") {
                        Task { await store.startScan() }
                    }
                    .disabled(store.isBusy || store.scanning)
                }
            }
            .refreshable { await store.refresh() }
            .sheet(isPresented: $showsSettings) { MobileConnectionView(store: store) }
            .task(id: "\(store.connectionRevision)-\(scenePhase == .active)") {
                if scenePhase == .active, ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil {
                    await store.observeServer()
                }
            }
        }
    }

    private var mailboxMenu: some View {
        Menu {
            mailboxSection("Find work", mailboxes: [.inbox, .strong, .all])
            mailboxSection("Applications", mailboxes: [.interested, .applied, .rejected, .ignored, .tracker])
            mailboxSection("Review", mailboxes: [.audit])
        } label: {
            Label("Mailboxes", systemImage: "sidebar.left")
        }
        .accessibilityValue(store.mailbox.rawValue)
    }

    private func mailboxSection(_ title: String, mailboxes: [Mailbox]) -> some View {
        Section(title) {
            ForEach(mailboxes) { mailbox in
                Button {
                    store.mailbox = mailbox
                } label: {
                    Label("\(mailbox.rawValue) (\(store.count(mailbox)))", systemImage: store.mailbox == mailbox ? "checkmark" : mailbox.symbol)
                }
            }
        }
    }

    private var filters: some View {
        VStack(alignment: .leading, spacing: 12) {
            if dynamicTypeSize.isAccessibilitySize {
                rolePicker.pickerStyle(.menu).labelsHidden()
            } else {
                rolePicker.pickerStyle(.segmented)
            }
            ViewThatFits(in: .horizontal) {
                HStack {
                    sourcePicker
                    Spacer(minLength: 8)
                    sortPicker
                }
                VStack(alignment: .leading, spacing: 8) {
                    sourcePicker
                    sortPicker
                }
            }
            if store.hasFilters {
                HStack {
                    Text("Filters active").foregroundStyle(.secondary)
                    Spacer()
                    Button("Clear filters") { store.resetFilters() }
                }
                .font(.subheadline)
            }
        }
    }

    private var rolePicker: some View {
        Picker("Role", selection: $store.role) {
            ForEach(RoleFilter.allCases) { Text($0.rawValue).tag($0) }
        }
    }

    private var sourcePicker: some View {
        Picker("Source", selection: $store.source) {
            Text("All sources").tag("All sources")
            ForEach(store.sources, id: \.self) { Text(sourceName($0)).tag($0) }
        }
        .pickerStyle(.menu)
        .labelsHidden()
    }

    private var sortPicker: some View {
        Picker("Sort", selection: $store.sort) {
            ForEach(VacancySort.allCases) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.menu)
        .labelsHidden()
    }

    @ViewBuilder private var connectionStatus: some View {
        if store.isCached {
            Label("Saved copy · connect to refresh", systemImage: "externaldrive")
                .font(.subheadline).foregroundStyle(.secondary)
        }
        if let error = store.errorMessage {
            VStack(alignment: .leading, spacing: 8) {
                Label("Connection needs attention", systemImage: "wifi.exclamationmark").font(.headline)
                Text(error).font(.subheadline).foregroundStyle(.secondary)
                Button("Retry") { Task { await store.refresh() } }.disabled(store.isBusy)
            }
        }
        if let notice = store.notice { Text(notice).font(.subheadline).foregroundStyle(.secondary) }
        if !(store.snapshot?.lastRun?.failures.isEmpty ?? true) {
            Label("Some sources need attention. Available results are saved. Review sources on your Mac.", systemImage: "exclamationmark.triangle")
                .font(.subheadline).foregroundStyle(.secondary)
        }
        if store.scanning {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    ProgressView()
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Search running on Mac").font(.subheadline.weight(.medium))
                        Text(store.operation?.message ?? "You can leave this screen while it runs.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Button("Cancel search", role: .destructive) { Task { await store.cancelScan() } }
                    .disabled(store.isBusy)
            }
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label(store.isBusy ? "Loading vacancies…" : "No vacancies here", systemImage: "tray")
        } description: {
            Text((store.snapshot?.jobs.isEmpty ?? true) ? "Connect to your Mac and search your sources to get started." : "Change the mailbox or clear your filters to see more vacancies.")
        } actions: {
            if store.hasFilters {
                Button("Clear filters") { store.resetFilters() }
            } else if !(store.snapshot?.jobs.isEmpty ?? true) {
                Button("Show all vacancies") { store.mailbox = .all }
            } else {
                Button("Search now") { Task { await store.startScan() } }
                    .disabled(store.isBusy || store.scanning)
            }
        }
    }
}

private struct MobileVacancyRow: View {
    let job: Vacancy
    @ScaledMetric(relativeTo: .body) private var scoreSize = 44
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var layout: AnyLayout {
        dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
            : AnyLayout(HStackLayout(alignment: .top, spacing: 12))
    }

    var body: some View {
        layout {
            ScoreBadge(score: job.assessment.score, size: scoreSize)
            VStack(alignment: .leading, spacing: 6) {
                Text(job.payload.title).font(.headline).foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(job.payload.company.isEmpty ? "Company not provided" : job.payload.company)
                    .font(.subheadline).foregroundStyle(.secondary)
                if !job.payload.salary.isEmpty {
                    Text(job.payload.salary).font(.subheadline.weight(.medium)).foregroundStyle(.primary)
                }
                if !job.payload.location.isEmpty {
                    Text(job.payload.location).font(.subheadline).foregroundStyle(.secondary)
                }
                Text(Array(Set(job.listings.map { sourceName($0.source) })).sorted().joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
                if job.assessment.decision == "rejected" {
                    Tag(text: "Filtered")
                } else if job.status != .new {
                    Tag(text: job.status.rawValue)
                } else if job.kind == "new" || job.kind == "updated" {
                    Tag(text: job.kind.capitalized)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
    }
}

private struct MobileConnectionView: View {
    @Bindable var store: MobileJobStore
    @Environment(\.dismiss) private var dismiss
    @State private var discovery = LANDiscovery()

    var body: some View {
        NavigationStack {
            Form {
                Section("Mac server") {
                    TextField("http://your-mac.local:8765", text: $store.serverAddress)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Server token", text: $store.token)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Text("Use your Mac’s LAN address and the token in its JobScout workspace. Both devices must be on the same network. The token is stored in this device’s Keychain.")
                        .font(.caption)
                    Text("HTTP sends vacancies and the token without encryption. Use it only on a trusted private LAN; use HTTPS when the server has a trusted certificate.")
                        .font(.caption)
                }
                Section("Nearby servers") {
                    Button("Find servers on this network") { discovery.start() }
                    ForEach(discovery.servers) { server in
                        Button {
                            store.serverAddress = server.url.absoluteString
                            store.token = ""
                        } label: {
                            VStack(alignment: .leading) {
                                Text(server.name)
                                Text(server.url.absoluteString).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    if let message = discovery.message { Text(message).font(.caption) }
                    Text("Confirm the server address before entering its token. Discovery does not authenticate the server.")
                        .font(.caption)
                }
                if let error = store.errorMessage {
                    Section { Text(error).foregroundStyle(.red) }
                }
            }
            .navigationTitle("Connection")
            .onDisappear { discovery.stop() }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        store.saveConnection()
                        if store.errorMessage == nil { dismiss() }
                    }
                }
            }
        }
    }
}
