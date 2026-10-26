import SwiftUI

struct SidebarView: View {
    @Bindable var store: JobStore

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "briefcase.fill")
                    .font(.title2)
                    .foregroundStyle(.teal)
                VStack(alignment: .leading, spacing: 2) {
                    Text("JobScout").font(.title3.bold())
                    Text("Your next opportunity").font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.top, 20)
            .padding(.bottom, 16)
            List(selection: $store.mailbox) {
                Section("Discover") {
                    row(.inbox)
                    row(.strong)
                }
                Section("Applications") {
                    row(.interested)
                    row(.applied)
                    row(.rejected)
                    row(.ignored)
                }
                Section("Review") {
                    row(.tracker)
                    row(.audit)
                    row(.all)
                }
            }
            .listStyle(.sidebar)
            Divider()
            VStack(alignment: .leading, spacing: 7) {
                Label("Local · No AI calls", systemImage: "internaldrive")
                    .font(.caption.weight(.medium))
                if store.isBusy {
                    Text(store.activity).font(.caption).foregroundStyle(.secondary)
                } else if let notice = store.notice {
                    Text(notice).font(.caption).foregroundStyle(.secondary)
                } else if let scan = store.snapshot?.lastRun {
                    Text("Last scan \(readableDate(scan.finished))")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Run a scan to get started").font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
        }
        .navigationTitle("JobScout")
    }

    private func row(_ mailbox: Mailbox) -> some View {
        HStack {
            Label(mailbox.rawValue, systemImage: mailbox.symbol)
            Spacer()
            Text(store.count(mailbox), format: .number)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .tag(mailbox)
        .padding(.vertical, 3)
    }
}
