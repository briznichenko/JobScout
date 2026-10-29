import AppKit
import SwiftUI

struct SettingsView: View {
    @Bindable var store: JobStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
          VStack(alignment: .leading, spacing: 22) {
            HStack {
                Image(systemName: "briefcase.fill").font(.title).foregroundStyle(.teal)
                VStack(alignment: .leading, spacing: 3) {
                    Text("JobScout settings").font(.title2.bold())
                    Text("Local crawling. Deterministic scoring. No AI calls.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
            }
            GroupBox("Python runtime") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Python 3.12 or newer is required. Select the interpreter path used by your local installation.")
                        .font(.callout).foregroundStyle(.secondary)
                    TextField("Python executable", text: $store.pythonPath)
                        .font(.system(.callout, design: .monospaced))
                        .textFieldStyle(.roundedBorder)
                    Button("Save & reload") { store.saveSettings() }
                        .disabled(store.isBusy)
                    if let browser = store.snapshot?.browser {
                        Label(browser.ready ? "Browser collection ready" : "Browser setup required", systemImage: browser.ready ? "checkmark.circle" : "exclamationmark.circle")
                            .foregroundStyle(browser.ready ? Color.secondary : Color.orange)
                        Text(browser.message)
                            .font(.caption)
                            .textSelection(.enabled)
                    }
                }
                .padding(10)
            }
            GroupBox("Profile and filtering") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Edit the TOML rules to change your profile, sources, score weights, or exclusions. Recalculate scores after saving. Application statuses are preserved.")
                        .font(.callout).foregroundStyle(.secondary)
                    HStack {
                        Button("Open rules…") {
                            if let url = store.workspace?.appending(path: "config.toml") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        Button("Recalculate scores") { store.rescore() }
                            .disabled(store.isBusy || store.snapshot == nil)
                    }
                }
                .padding(10)
            }
            GroupBox("Sources") {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(store.snapshot?.sources ?? []) { source in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(sourceName(source.id)).fontWeight(.semibold)
                                Spacer()
                                Text("\(source.count) saved").foregroundStyle(.secondary)
                                if !source.enabled { Text("Disabled").foregroundStyle(.secondary) }
                            }
                            Text(source.mode).font(.caption).foregroundStyle(.secondary)
                            if let failure = source.failures.first {
                                Text(failure).font(.caption).foregroundStyle(.orange).lineLimit(3)
                            } else if source.id == "linkedin" {
                                Text("Reads saved alerts; does not crawl LinkedIn.").font(.caption).foregroundStyle(.secondary)
                            } else if source.id == "google_sheets" {
                                Text("Private Sheet: import an XLSX export to refresh both tabs.").font(.caption).foregroundStyle(.secondary)
                            }
                            HStack {
                                if let url = URL(string: source.searchURL) {
                                    Link(source.id == "google_sheets" ? "Open Sheet" : "Open search", destination: url)
                                }
                                if ["google_sheets", "workua", "robota", "linkedin"].contains(source.id) {
                                    Button("Import…") {
                                        store.requestedImport = source.id
                                        dismiss()
                                    }
                                    .disabled(store.isBusy)
                                }
                                Button("Inbox folder") {
                                    let url = URL(filePath: source.directory)
                                    do {
                                        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                                        NSWorkspace.shared.open(url)
                                    } catch { store.errorMessage = error.localizedDescription }
                                }
                            }
                            .font(.caption)
                        }
                        if source.id != store.snapshot?.sources?.last?.id { Divider() }
                    }
                    Text("Search Now reads saved inbox files as well as accessible live sources. Enable or disable sources in the TOML rules.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(10)
            }
            if let workspace = store.workspace {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Your data").font(.headline)
                    Text(workspace.path).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                    Button("Show data folder in Finder") { NSWorkspace.shared.open(workspace) }
                }
            }
            if let failures = store.snapshot?.lastRun?.failures, !failures.isEmpty {
                GroupBox("Latest source failures") {
                    ScrollView {
                        Text(failures.joined(separator: "\n\n"))
                            .font(.caption).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 120)
                    .padding(8)
                }
            }
            HStack {
                Text("Scheduling is managed by the CLI launchd command.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Done") {
                    store.showsSettings = false
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
          }
        .padding(28)
        }
        .frame(width: 660, height: 780)
    }
}
