import AppKit
import SwiftUI

struct SettingsView: View {
    @Bindable var store: JobStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
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
        .frame(width: 600)
    }
}
