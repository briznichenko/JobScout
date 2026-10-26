import AppKit
import SwiftUI

struct VacancyListView: View {
    @Bindable var store: JobStore

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 13) {
                HStack(alignment: .firstTextBaseline) {
                    Text((store.mailbox ?? .inbox).rawValue).font(.title2.bold())
                    Spacer()
                    Text(store.visibleJobs.count, format: .number)
                        .font(.title3.monospacedDigit()).foregroundStyle(.secondary)
                }
                Picker("Role", selection: $store.role) {
                    ForEach(RoleFilter.allCases) { role in Text(role.rawValue).tag(role) }
                }
                .pickerStyle(.segmented)
                HStack {
                    Menu {
                        Picker("Source", selection: $store.source) {
                            Text("All sources").tag("All sources")
                            ForEach(store.sources, id: \.self) { Text(sourceName($0)).tag($0) }
                        }
                    } label: {
                        Label(store.source == "All sources" ? "All sources" : sourceName(store.source), systemImage: "line.3.horizontal.decrease")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    Spacer()
                    Picker("Sort", selection: $store.sort) {
                        ForEach(VacancySort.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                }
                .font(.caption)
            }
            .padding(16)
            if let failures = store.snapshot?.lastRun?.failures, !failures.isEmpty {
                Label("\(failures.count) feed request(s) failed. Successful results are saved.", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.orange.opacity(0.08))
                    .help(failures.joined(separator: "\n"))
            }
            Divider()
            List(selection: $store.selection) {
                ForEach(store.visibleJobs) { job in
                    VacancyRow(job: job, minimumScore: store.minimumScore, strongThreshold: store.strongThreshold)
                        .tag(job.id)
                        .contextMenu {
                            ForEach(ApplicationStatus.allCases) { status in
                                Button("Mark \(status.rawValue)") { store.updateStatus(status, for: job.id) }
                                    .disabled(store.isBusy)
                            }
                        }
                }
            }
            .listStyle(.inset)
            .overlay {
                if store.visibleJobs.isEmpty {
                    ContentUnavailableView {
                        Label(store.isBusy ? "Loading…" : "No vacancies here", systemImage: "tray")
                    } description: {
                        Text(store.jobs.isEmpty ? "Scan the job feeds or import alerts." : "Try another view or clear your filters.")
                    } actions: {
                        if store.jobs.isEmpty {
                            Button("Scan job feeds") { store.scan() }.disabled(store.isBusy)
                        } else {
                            Button("Show all vacancies") {
                                store.mailbox = .all
                                store.search = ""
                                store.role = .all
                                store.source = "All sources"
                            }
                        }
                    }
                }
            }
            Divider()
            HStack {
                Text(store.mailbox == .audit ? "Automatic decisions · application status is separate" : "Ranked by your profile · review unknown requirements")
                    .font(.caption2).foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .padding(12)
        }
        .searchable(text: $store.search, prompt: "Title, company, or skill")
    }
}

private struct VacancyRow: View {
    let job: Vacancy
    let minimumScore: Int
    let strongThreshold: Int

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ScoreBadge(score: job.assessment.score, minimumScore: minimumScore, strongThreshold: strongThreshold)
                .padding(.top, 3)
            VStack(alignment: .leading, spacing: 5) {
                Text(job.payload.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(2)
                Text(job.payload.company.isEmpty ? "Company not provided" : job.payload.company)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                HStack(spacing: 5) {
                    Text(job.listings.map { sourceName($0.source) }.uniqued().joined(separator: " · "))
                        .font(.caption2).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    if job.assessment.decision == "rejected" {
                        Tag(text: "Filtered", color: .orange)
                    } else if job.status != .new {
                        Tag(text: job.status.rawValue, color: .teal)
                    } else if job.kind == "new" || job.kind == "updated" {
                        Tag(text: job.kind.capitalized, color: .teal)
                    }
                }
            }
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
