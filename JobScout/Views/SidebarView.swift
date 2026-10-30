//
//  SidebarView.swift
//  JobScout
//
//  Created by Andrii Bryzhnychenko on 10/29/26.
//

import SwiftUI

struct SidebarView: View {
    @Bindable var store: JobStore

    var body: some View {
        VStack(spacing: 0) {
            List(selection: $store.mailbox) {
                Section("Find work") {
                    row(.inbox)
                    row(.strong)
                    row(.all)
                }
                Section("Applications") {
                    row(.interested)
                    row(.applied)
                    row(.rejected)
                    row(.ignored)
                    row(.tracker)
                }
                Section("Review") {
                    row(.audit)
                }
            }
            .listStyle(.sidebar)
            .font(.body)
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                if store.isBusy {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text(store.activity)
                            .font(.callout)
                    }
                } else if let notice = store.notice {
                    Text(notice)
                        .font(.callout)
                }
                if let scan = store.snapshot?.lastRun {
                    Text("Last search \(readableDate(scan.finished))")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else if !store.isBusy {
                    Text("Search your sources to get started.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
        }
        .navigationTitle("JobScout")
    }

    private func row(_ mailbox: Mailbox) -> some View {
        HStack(spacing: 8) {
            Label(mailbox.rawValue, systemImage: mailbox.symbol)
                .lineLimit(1)
            Spacer(minLength: 4)
            Text(store.count(mailbox), format: .number)
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .tag(mailbox)
        .padding(.vertical, 5)
        .accessibilityElement(children: .combine)
    }
}
