import AppKit
import SwiftUI

struct SettingsView: View {
    @Bindable var store: JobStore
    @Environment(\.dismiss) private var dismiss
    @State private var selectedTab = SettingsTab.sources

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $selectedTab) {
                sourcesTab
                    .tabItem { Label("Sources", systemImage: "tray.2") }
                    .tag(SettingsTab.sources)
                matchingTab
                    .tabItem { Label("Matching", systemImage: "slider.horizontal.3") }
                    .tag(SettingsTab.matching)
                runtimeTab
                    .tabItem { Label("Runtime & Data", systemImage: "gearshape") }
                    .tag(SettingsTab.runtime)
            }
            .padding(20)
            Divider()
            HStack(spacing: 12) {
                if store.isBusy {
                    ProgressView().controlSize(.small)
                    Text(store.activity)
                } else {
                    Text("Changes to rules take effect after recalculating scores.")
                }
                Spacer(minLength: 12)
                Button("Done") {
                    store.showsSettings = false
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(16)
        }
        .frame(width: 720, height: 700)
    }

    private var sourcesTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                heading("Job sources", detail: "Search Now checks enabled sources and reads saved files from their inbox folders.")
                if let sources = store.snapshot?.sources, !sources.isEmpty {
                    VStack(spacing: 0) {
                        ForEach(sources) { source in
                            sourceRow(source)
                            if source.id != sources.last?.id { Divider() }
                        }
                    }
                } else {
                    ContentUnavailableView("Sources aren’t loaded", systemImage: "tray.2", description: Text("Check the Python runtime, then reload your saved data."))
                    Button("Reload sources") { store.refresh() }
                        .disabled(store.isBusy)
                }
                HStack {
                    Text("Enable or disable sources in your rules file.")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Open rules…", action: openRules)
                        .disabled(store.workspace == nil)
                }
                .font(.callout)
                if let failures = store.snapshot?.lastRun?.failures, !failures.isEmpty {
                    DisclosureGroup("Latest search details (\(failures.count))") {
                        Text(failures.joined(separator: "\n\n"))
                            .font(.callout)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 8)
                    }
                }
            }
            .padding(20)
        }
    }

    private var matchingTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                heading("Your matching rules", detail: "Adjust your profile, role preferences, exclusions, and score weights in the rules file.")
                VStack(alignment: .leading, spacing: 12) {
                    Label("1. Edit and save your rules", systemImage: "doc.text")
                        .font(.headline)
                    Text("The rules open in your default text editor.")
                        .foregroundStyle(.secondary)
                    Button("Open rules…", action: openRules)
                        .disabled(store.workspace == nil)
                }
                Divider()
                VStack(alignment: .leading, spacing: 12) {
                    Label("2. Update existing matches", systemImage: "arrow.clockwise")
                        .font(.headline)
                    Text("Recalculate fit scores after saving. Your application statuses are preserved.")
                        .foregroundStyle(.secondary)
                    Button("Recalculate scores") { store.rescore() }
                        .disabled(store.isBusy || store.snapshot == nil)
                }
            }
            .font(.body)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(24)
        }
    }

    private var runtimeTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                heading("Runtime & data", detail: "JobScout runs locally using Python 3.12 or newer.")
                VStack(alignment: .leading, spacing: 12) {
                    Text("Python executable").font(.headline)
                    TextField("Path to Python", text: $store.pythonPath)
                        .font(.system(.body, design: .monospaced))
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Python executable path")
                    Button("Save & reload") { store.saveSettings() }
                        .disabled(store.isBusy)
                    if let browser = store.snapshot?.browser {
                        Label(browser.ready ? "Browser collection ready" : "Browser setup required", systemImage: browser.ready ? "checkmark.circle" : "exclamationmark.triangle")
                            .font(.callout.weight(.medium))
                        DisclosureGroup("Browser setup details") {
                            Text(browser.message)
                                .font(.callout)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.top, 6)
                        }
                    }
                }
                Divider()
                if let workspace = store.workspace {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Your data").font(.headline)
                        Text("Vacancies, saved imports, reports, and your rules are stored here.")
                            .foregroundStyle(.secondary)
                        Text(workspace.path)
                            .font(.system(.callout, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        Button("Show data folder in Finder") { NSWorkspace.shared.open(workspace) }
                    }
                }
                Text("Background scheduling is configured with the CLI launchd command.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(24)
        }
    }

    private func sourceRow(_ source: SourceInfo) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(sourceName(source.id)).font(.headline)
                if !source.enabled {
                    Text("Disabled").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(source.count) saved")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Text(source.id == "linkedin" ? "Import saved alerts from LinkedIn." : source.id == "google_sheets" ? "Import an XLSX export to refresh both tracker tabs." : source.mode)
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack(spacing: 12) {
                if let url = URL(string: source.searchURL) {
                    Link(destination: url) {
                        Label(source.id == "google_sheets" ? "Open Sheet" : "Open search", systemImage: "arrow.up.right.square")
                    }
                }
                if ["google_sheets", "workua", "robota", "linkedin"].contains(source.id) {
                    Button("Import…", systemImage: "square.and.arrow.down") {
                        store.requestedImport = source.id
                        store.showsSettings = false
                        dismiss()
                    }
                    .disabled(store.isBusy)
                }
                Spacer(minLength: 0)
                Button("Inbox folder", systemImage: "folder") { openInbox(source) }
            }
            .controlSize(.regular)
            if !source.failures.isEmpty {
                DisclosureGroup {
                    Text(source.failures.joined(separator: "\n\n"))
                        .font(.callout)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 6)
                } label: {
                    Label("Source needs attention", systemImage: "exclamationmark.triangle")
                        .font(.callout)
                }
            }
        }
        .padding(.vertical, 16)
    }

    private func heading(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.title2.bold())
            Text(detail).font(.body).foregroundStyle(.secondary)
        }
    }

    private func openRules() {
        if let url = store.workspace?.appending(path: "config.toml") {
            NSWorkspace.shared.open(url)
        }
    }

    private func openInbox(_ source: SourceInfo) {
        let url = URL(filePath: source.directory)
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            NSWorkspace.shared.open(url)
        } catch {
            store.errorMessage = error.localizedDescription
        }
    }

    private enum SettingsTab: Hashable {
        case sources
        case matching
        case runtime
    }
}
