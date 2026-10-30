//
//  SettingsView.swift
//  JobScout
//
//  Created by Andrii Bryzhnychenko on 10/29/26.
//

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
        .sheet(isPresented: $store.showsRulesEditor) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Server matching rules").font(.title2.bold())
                TextEditor(text: $store.rulesText)
                    .font(.system(.body, design: .monospaced))
                    .disabled(store.isBusy)
                if let error = store.errorMessage {
                    Text(error).foregroundStyle(.red).font(.callout)
                }
                HStack {
                    Button("Close") { store.showsRulesEditor = false }.disabled(store.isBusy)
                    Spacer()
                    Button("Save rules") { store.saveServerRules() }.disabled(store.isBusy)
                }
            }
            .padding(20)
            .frame(width: 680, height: 560)
        }
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
                    ContentUnavailableView("Sources aren’t loaded", systemImage: "tray.2", description: Text("Check the server connection, then reload your saved data."))
                    Button("Reload sources") { store.refresh() }
                        .disabled(store.isBusy)
                }
                HStack {
                    Text("Enable or disable sources in your rules file.")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(store.isLocalServer ? "Open rules…" : "Edit server rules…", action: openRules)
                        .disabled(store.isBusy)
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
                    Text("Local rules open in your text editor. For a remote connection, edit the server’s rules here.")
                        .foregroundStyle(.secondary)
                    Button(store.isLocalServer ? "Open rules…" : "Edit server rules…", action: openRules)
                        .disabled(store.isBusy)
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
                heading("Runtime & data", detail: "JobScout connects to a Python service on this Mac or your local network.")
                VStack(alignment: .leading, spacing: 12) {
                    Text("Server connection").font(.headline)
                    TextField("http://127.0.0.1:8765", text: $store.serverAddress)
                        .textFieldStyle(.roundedBorder)
                    SecureField("Server token (blank for managed local service)", text: $store.serverToken)
                        .textFieldStyle(.roundedBorder)
                    Text("Use HTTPS for an encrypted LAN connection. HTTP sends your token and vacancy data in plaintext; use it only on a trusted private network.")
                        .font(.callout).foregroundStyle(.secondary)
                    Text("Local Python executable").font(.headline)
                    TextField("Path to Python", text: $store.pythonPath)
                        .font(.system(.body, design: .monospaced))
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Python executable path")
                    Text("Python is used when starting the local service. A running service keeps its interpreter until you restart it.")
                        .font(.callout).foregroundStyle(.secondary)
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
                Text("For service startup at login, use the backend service_login command described in Backend/API.md. Closing JobScout leaves server scans running.")
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
                    .disabled(!store.isLocalServer)
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
        } else {
            store.loadServerRules()
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
