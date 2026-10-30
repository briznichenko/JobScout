//
//  ContentView.swift
//  JobScout
//
//  Created by Andrii Bryzhnychenko on 10/29/26.
//

import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Bindable var store: JobStore
    @State private var showsImporter = false
    @State private var importAdapter: String?
    @State private var importSource: String?
    @State private var importsTracker = false

    var body: some View {
        NavigationSplitView {
            SidebarView(store: store)
                .navigationSplitViewColumnWidth(min: 220, ideal: 240, max: 280)
        } content: {
            VacancyListView(store: store)
                .navigationSplitViewColumnWidth(min: 345, ideal: 400, max: 500)
        } detail: {
            if let vacancy = store.selectedJob {
                VacancyDetailView(job: vacancy, store: store)
                    .id(vacancy.id)
            } else {
                ContentUnavailableView("Select a vacancy", systemImage: "doc.text.magnifyingglass",
                                       description: Text("Review the fit, requirements, and original listing here."))
            }
        }
        .navigationSplitViewStyle(.balanced)
        .safeAreaInset(edge: .bottom) {
            if store.isOffline {
                Label("Showing saved vacancies. Connect to the server to refresh or save changes.", systemImage: "wifi.slash")
                    .font(.callout)
                    .frame(maxWidth: .infinity)
                    .padding(8)
                    .background(.bar)
            }
        }
        .toolbar {
            ToolbarItemGroup {
                if store.isBusy {
                    ProgressView().controlSize(.small)
                    Button("Cancel", systemImage: "stop.circle") { store.cancel() }
                        .labelStyle(.iconOnly)
                        .help("Cancel the current operation")
                }
                Menu {
                    Button("JSON job alerts…") { beginImport(adapter: nil) }
                    Button("Saved DOU RSS…") { beginImport(adapter: "dou") }
                    Button("Saved Djinni RSS…") { beginImport(adapter: "djinni") }
                    Divider()
                    Button("Google Sheets tracker export…") { beginSourceImport("google_sheets") }
                    Button("Work.ua alerts or saved job…") { beginSourceImport("workua") }
                    Button("Robota.ua alerts or saved job…") { beginSourceImport("robota") }
                    Button("LinkedIn saved alerts…") { beginSourceImport("linkedin") }
                } label: {
                    Label("Import", systemImage: "square.and.arrow.down")
                }
                .disabled(store.isBusy)
                .help("Import job alerts or a saved RSS feed")
                Button("Report", systemImage: "doc.richtext") { store.openReport() }
                    .disabled(store.isBusy || store.snapshot?.lastRun == nil)
                    .help("Generate and open the Markdown report")
                Button("Settings", systemImage: "gearshape") { store.showsSettings = true }
                    .help("Sources, matching rules, and runtime settings")
            }
            ToolbarItem(placement: .primaryAction) {
                Button("Search Now", systemImage: "arrow.clockwise") { store.scan() }
                    .labelStyle(.titleAndIcon)
                    .disabled(store.isBusy)
                    .help("Search configured sources (⇧⌘R)")
            }
        }
        .fileImporter(isPresented: $showsImporter, allowedContentTypes: importTypes) { result in
            switch result {
            case .success(let url):
                if importsTracker { store.importTracker(url) }
                else if let importSource { store.importSource(url, source: importSource) }
                else { store.importFile(url, adapter: importAdapter) }
            case .failure(let error): store.errorMessage = error.localizedDescription
            }
        }
        .alert("JobScout needs attention", isPresented: Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })) {
            Button("OK") { store.errorMessage = nil }
            Button("Settings…") { store.showsSettings = true }
        } message: {
            Text(store.errorMessage ?? "")
        }
        .sheet(isPresented: $store.showsSettings) {
            SettingsView(store: store)
        }
        .task {
            if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil {
                store.refresh()
            }
        }
        .onChange(of: store.mailbox) { store.reconcileSelection() }
        .onChange(of: store.role) { store.reconcileSelection() }
        .onChange(of: store.source) { store.reconcileSelection() }
        .onChange(of: store.search) { store.reconcileSelection() }
        .onChange(of: store.requestedImport) {
            if let source = store.requestedImport {
                store.requestedImport = nil
                beginSourceImport(source)
            }
        }
    }

    private func beginImport(adapter: String?) {
        importAdapter = adapter
        importSource = nil
        importsTracker = false
        showsImporter = true
    }

    private func beginSourceImport(_ source: String) {
        importAdapter = nil
        importSource = source == "google_sheets" ? nil : source
        importsTracker = source == "google_sheets"
        store.showsSettings = false
        showsImporter = true
    }

    private var importTypes: [UTType] {
        if importsTracker { return [.spreadsheet, .commaSeparatedText, .tabSeparatedText] }
        if importSource == "linkedin" { return [.json, .emailMessage] }
        if importSource != nil { return [.json, .emailMessage, .html] }
        return importAdapter == nil ? [.json] : [.xml]
    }
}
