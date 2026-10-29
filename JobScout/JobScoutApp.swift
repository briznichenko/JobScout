import SwiftUI

@main
struct JobScoutApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var store = JobStore()

    var body: some Scene {
        Window("JobScout", id: "main") {
            ContentView(store: store)
                .tint(.primary)
                .frame(minWidth: 1080, minHeight: 680)
                .onAppear { delegate.store = store }
        }
        .defaultSize(width: 1380, height: 880)
        .commands {
            CommandMenu("Search") {
                Button("Search Now") { store.scan() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                    .disabled(store.isBusy)
                Button("Refresh Stored Vacancies") { store.refresh() }
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(store.isBusy)
                Button("Cancel Search") { store.cancel() }.disabled(!store.isBusy)
                Divider()
                Button("Import Google Sheets Tracker…") { store.requestedImport = "google_sheets" }
                    .disabled(store.isBusy)
                ForEach(store.snapshot?.sources ?? []) { source in
                    if let url = URL(string: source.searchURL) {
                        Button(source.id == "google_sheets" ? "Open Application Tracker" : "Open \(sourceName(source.id)) Search") { NSWorkspace.shared.open(url) }
                    }
                }
            }
        }
        Settings {
            SettingsView(store: store)
                .tint(.primary)
        }
        MenuBarExtra("JobScout", systemImage: "briefcase.fill") {
            JobScoutMenu(store: store)
        }
        .menuBarExtraStyle(.menu)
    }
}

private struct JobScoutMenu: View {
    @Bindable var store: JobStore
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text("JobScout")
        if store.isBusy {
            Text(store.activity)
        } else if store.snapshot != nil {
            Text("\(store.count(.inbox)) opportunities · \(store.count(.strong)) strong matches")
        }
        Divider()
        Button("Search Now", systemImage: "arrow.clockwise") { store.scan() }
            .disabled(store.isBusy)
        if store.isBusy {
            Button("Cancel Search", systemImage: "stop.circle") { store.cancel() }
        }
        Button("Open JobScout", systemImage: "macwindow") {
            openWindow(id: "main")
            NSApp.activate()
        }
        Divider()
        Button("Quit JobScout", systemImage: "power") { NSApp.terminate(nil) }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var store: JobStore?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let store, store.isBusy else { return .terminateNow }
        Task {
            await store.stopBeforeQuit()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
