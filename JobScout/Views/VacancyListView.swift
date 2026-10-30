//
//  VacancyListView.swift
//  JobScout
//
//  Created by Andrii Bryzhnychenko on 10/29/26.
//

import SwiftUI

struct VacancyListView: View {
    @Bindable var store: JobStore
    @FocusState private var searchIsFocused: Bool

    private var hasFilters: Bool {
        !store.search.isEmpty || store.role != .all || store.source != "All sources"
    }

    var body: some View {
        VStack(spacing: 0) {
            filters
                .fixedSize(horizontal: false, vertical: true)
            if let failures = store.snapshot?.lastRun?.failures, !failures.isEmpty {
                sourceNotice(failures)
            }
            Divider()
            List(selection: $store.selection) {
                ForEach(store.visibleJobs) { job in
                    VacancyRow(job: job)
                        .tag(job.id)
                        .contextMenu {
                            ForEach(ApplicationStatus.allCases) { status in
                                Button("Mark \(status.rawValue)") { store.updateStatus(status, for: job.id) }
                                    .disabled(store.isBusy || job.status == status)
                            }
                        }
                }
            }
            .listStyle(.inset)
            .overlay {
                if store.visibleJobs.isEmpty {
                    emptyState
                }
            }
            if store.mailbox == .audit {
                Divider()
                Text("Automatic filtering is separate from application status.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
            }
        }
        .background {
            Button("Find vacancies") { searchIsFocused = true }
                .keyboardShortcut("f", modifiers: .command)
                .hidden()
                .accessibilityHidden(true)
        }
    }

    private var filters: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text((store.mailbox ?? .inbox).rawValue)
                    .font(.title2.weight(.semibold))
                Spacer()
                Text(store.visibleJobs.count, format: .number)
                    .font(.body.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("\(store.visibleJobs.count) vacancies")
            }
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search vacancies", text: $store.search)
                    .textFieldStyle(.plain)
                    .focused($searchIsFocused)
                    .accessibilityLabel("Search title, company, location, or skill")
                if !store.search.isEmpty {
                    Button {
                        store.search = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Clear search")
                    .accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(.background, in: RoundedRectangle(cornerRadius: 7))
            .overlay {
                RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(.separator, lineWidth: 0.5)
            }
            Picker("", selection: $store.role) {
                ForEach(RoleFilter.allCases) { role in Text(role.rawValue).tag(role) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityLabel("Role")
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 8) {
                Picker("Source", selection: $store.source) {
                    Text("All sources").tag("All sources")
                    ForEach(store.sources, id: \.self) { Text(sourceName($0)).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .help("Filter by source")
                Picker("Sort", selection: $store.sort) {
                    ForEach(VacancySort.allCases) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .help("Sort vacancies")
            }
            .controlSize(.regular)
            if hasFilters {
                HStack {
                    Text("Filters active")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Clear filters", action: clearFilters)
                        .buttonStyle(.link)
                }
                .font(.callout)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 12)
    }

    private func sourceNotice(_ failures: [String]) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text("Some sources need attention")
                    .font(.callout.weight(.medium))
                Text("Available results are saved.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button("Review sources") { store.showsSettings = true }
                    .buttonStyle(.link)
                    .font(.callout)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.35))
        .help(failures.joined(separator: "\n"))
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label(store.isBusy ? "Loading vacancies…" : "No vacancies here", systemImage: "tray")
        } description: {
            Text(store.jobs.isEmpty ? "Search your sources or import saved alerts to get started." : "Change the view or clear your filters to see more vacancies.")
        } actions: {
            if store.jobs.isEmpty {
                Button("Search now") { store.scan() }
                    .disabled(store.isBusy)
            } else if hasFilters {
                Button("Clear filters", action: clearFilters)
            } else {
                Button("Show all vacancies") { store.mailbox = .all }
            }
        }
    }

    private func clearFilters() {
        store.search = ""
        store.role = .all
        store.source = "All sources"
    }
}

private struct VacancyRow: View {
    let job: Vacancy

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ScoreBadge(score: job.assessment.score)
            VStack(alignment: .leading, spacing: 6) {
                Text(job.payload.title)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Text(job.payload.company.isEmpty ? "Company not provided" : job.payload.company)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if !job.payload.salary.isEmpty {
                    Text(job.payload.salary)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                }
                if !job.payload.location.isEmpty {
                    Text(job.payload.location)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                HStack(spacing: 6) {
                    Text(job.listings.map { sourceName($0.source) }.uniqued().joined(separator: " · "))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if job.assessment.decision == "rejected" {
                        Tag(text: "Filtered")
                    } else if job.status != .new {
                        Tag(text: job.status.rawValue)
                    } else if job.kind == "new" || job.kind == "updated" {
                        Tag(text: job.kind.capitalized)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
    }
}

private extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen: Set<Element> = []
        return filter { seen.insert($0).inserted }
    }
}
