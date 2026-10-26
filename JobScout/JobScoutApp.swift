import SwiftUI

@main
struct JobScoutApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var store = JobStore()

    var body: some Scene {
        Window("JobScout", id: "main") {
            ContentView(store: store)
                .tint(.teal)
                .frame(minWidth: 1080, minHeight: 680)
                .onAppear { delegate.store = store }
        }
        .defaultSize(width: 1380, height: 880)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Scan for Vacancies") { store.scan() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                    .disabled(store.isBusy)
                Button("Refresh Stored Vacancies") { store.refresh() }
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(store.isBusy)
            }
        }
        Settings {
            SettingsView(store: store)
                .tint(.teal)
        }
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
