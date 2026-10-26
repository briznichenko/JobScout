import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Bindable var store: JobStore
    @State private var showsImporter = false
    @State private var importAdapter: String?

    var body: some View {
        NavigationSplitView {
            SidebarView(store: store)
                .navigationSplitViewColumnWidth(min: 195, ideal: 215, max: 250)
        } content: {
            VacancyListView(store: store)
                .navigationSplitViewColumnWidth(min: 325, ideal: 390, max: 480)
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
                } label: {
                    Label("Import", systemImage: "square.and.arrow.down")
                }
                .disabled(store.isBusy)
                .help("Import job alerts or a saved RSS feed")
                Button("Report", systemImage: "doc.richtext") { store.openReport() }
                    .disabled(store.isBusy || store.snapshot?.lastRun == nil)
                    .help("Generate and open the Markdown report")
                SettingsLink { Label("Settings", systemImage: "gearshape") }
                    .help("Python and scoring settings")
                Button("Scan", systemImage: "arrow.clockwise") { store.scan() }
                    .disabled(store.isBusy)
                    .help("Scan DOU and Djinni (⇧⌘R)")
            }
        }
        .fileImporter(isPresented: $showsImporter, allowedContentTypes: importAdapter == nil ? [.json] : [.xml]) { result in
            switch result {
            case .success(let url): store.importFile(url, adapter: importAdapter)
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
        .task { if store.snapshot == nil { store.refresh() } }
        .onChange(of: store.mailbox) { store.reconcileSelection() }
        .onChange(of: store.role) { store.reconcileSelection() }
        .onChange(of: store.source) { store.reconcileSelection() }
        .onChange(of: store.search) { store.reconcileSelection() }
    }

    private func beginImport(adapter: String?) {
        importAdapter = adapter
        showsImporter = true
    }
}
