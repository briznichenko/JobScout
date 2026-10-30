import JobScoutKit
import SwiftUI

struct MobileVacancyDetailView: View {
    @Bindable var store: MobileJobStore
    let id: Int
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .title3) private var scoreSize = 56
    @State private var showsFitReasons = false
    @State private var showsBreakdown = false
    @State private var showsSources = false

    private var vacancy: Vacancy? { store.snapshot?.jobs.first { $0.id == id } }

    var body: some View {
        Group {
            if let vacancy {
                ScrollView {
                    VStack(alignment: .leading, spacing: 28) {
                        header(vacancy)
                        metadata(vacancy)
                        connectionNotices
                        assessment(vacancy)
                        trackerHistory(vacancy)
                        description(vacancy)
                        supportingDetails(vacancy)
                    }
                    .padding(20)
                    .frame(maxWidth: 760, alignment: .leading)
                    .frame(maxWidth: .infinity)
                }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    actions(vacancy)
                }
            } else {
                ContentUnavailableView("Vacancy unavailable", systemImage: "doc.questionmark", description: Text("Refresh the list to load the latest saved data."))
            }
        }
        .background(Color(uiColor: .systemBackground))
        .navigationTitle("Vacancy")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func header(_ job: Vacancy) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(job.assessment.role == "apple" ? "Apple engineering" : job.assessment.role == "support" ? "Technical support" : "Role needs review")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if job.assessment.decision == "review" {
                Tag(text: "Needs review")
            }
            Text(job.payload.title)
                .font(.title.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Text(job.payload.company.isEmpty ? "Company not provided" : job.payload.company)
                .font(.title3)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }

    private func metadata(_ job: Vacancy) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(job.payload.location.isEmpty ? "Location and remote eligibility unconfirmed" : job.payload.location, systemImage: "mappin.and.ellipse")
            Label(job.payload.salary.isEmpty ? "Salary not provided" : job.payload.salary, systemImage: "banknote")
            Label("Status: \(job.status.rawValue)", systemImage: "bookmark")
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .textSelection(.enabled)
    }

    private var connectionNotices: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let error = store.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if store.isCached {
                Label("Saved copy · connect to save status changes", systemImage: "wifi.slash")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func actions(_ job: Vacancy) -> some View {
        VStack(spacing: 10) {
            if let url = webURL(job.payload.url) {
                Link(destination: url) {
                    Label(job.payload.source == "google_sheets" && url.host == "docs.google.com" ? "Open tracker" : "Open listing", systemImage: "arrow.up.right")
                        .frame(maxWidth: .infinity, minHeight: 28)
                }
                .buttonStyle(.borderedProminent)
            }
            if dynamicTypeSize.isAccessibilitySize {
                statusMenu(job)
                    .buttonStyle(.bordered)
                    .disabled(store.isBusy || store.isCached)
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) {
                        statusButton(.interested, job: job)
                        statusButton(.applied, job: job)
                        statusMenu(job)
                    }
                    VStack(spacing: 8) {
                        statusButton(.interested, job: job)
                        statusButton(.applied, job: job)
                        statusMenu(job)
                    }
                }
                .buttonStyle(.bordered)
                .disabled(store.isBusy || store.isCached)
            }
        }
        .frame(maxWidth: 720)
        .controlSize(.large)
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    private func statusButton(_ status: ApplicationStatus, job: Vacancy) -> some View {
        Button {
            Task { await store.updateStatus(status, id: id) }
        } label: {
            Label(status.rawValue, systemImage: status == .interested ? (job.status == status ? "star.fill" : "star") : (job.status == status ? "checkmark.circle.fill" : "paperplane"))
                .fixedSize(horizontal: true, vertical: false)
                .frame(maxWidth: .infinity, minHeight: 28)
        }
        .disabled(job.status == status)
    }

    private func statusMenu(_ job: Vacancy) -> some View {
        Menu {
            Text("Status: \(job.status.rawValue)")
            ForEach(ApplicationStatus.allCases) { status in
                Button {
                    Task { await store.updateStatus(status, id: id) }
                } label: {
                    if status == job.status {
                        Label(status.rawValue, systemImage: "checkmark")
                    } else {
                        Text(status.rawValue)
                    }
                }
                .disabled(status == job.status)
            }
        } label: {
            if dynamicTypeSize.isAccessibilitySize {
                Label("Status: \(job.status.rawValue)", systemImage: "ellipsis")
                    .frame(minHeight: 28)
            } else {
                Image(systemName: "ellipsis")
                    .frame(minWidth: 28, minHeight: 28)
            }
        }
        .accessibilityLabel("Application status: \(job.status.rawValue). More actions")
    }

    private func assessment(_ job: Vacancy) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Divider()
            HStack(alignment: .top, spacing: 12) {
                ScoreBadge(score: job.assessment.score, size: scoreSize)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Fit assessment").font(.title3.weight(.semibold))
                    Text("A ranking against your profile, not a hiring probability.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            if job.assessment.decision == "rejected" {
                factors("Why it was filtered", symbol: "line.3.horizontal.decrease.circle", values: job.assessment.rejected)
            }
            if !job.assessment.positive.isEmpty {
                DisclosureGroup("Why it fits (\(job.assessment.positive.count))", isExpanded: $showsFitReasons) {
                    factors("Matching factors", symbol: "checkmark.circle", values: job.assessment.positive)
                        .padding(.top, 10)
                }
            }
            factors("Concerns", symbol: "exclamationmark.circle", values: job.assessment.negative)
            factors("Requirements to verify", symbol: "questionmark.circle", values: job.assessment.missing)
            factors("Check before applying", symbol: "checklist", values: job.assessment.uncertainty)
            DisclosureGroup("Score breakdown", isExpanded: $showsBreakdown) {
                VStack(spacing: 12) {
                    ForEach(job.assessment.components.keys.sorted(), id: \.self) { key in
                        HStack(alignment: .firstTextBaseline) {
                            Text(key == "missing_penalty" ? "Missing requirements" : key.replacingOccurrences(of: "_", with: " ").capitalized)
                            Spacer(minLength: 12)
                            Text(job.assessment.components[key] ?? 0, format: .number.sign(strategy: .always()))
                                .monospacedDigit()
                        }
                    }
                    Divider()
                    HStack {
                        Text("Final score").fontWeight(.semibold)
                        Spacer()
                        Text("\(job.assessment.score) / 100").monospacedDigit()
                    }
                }
                .font(.subheadline)
                .padding(.top, 12)
            }
            Divider()
        }
    }

    @ViewBuilder private func factors(_ title: String, symbol: String, values: [String]) -> some View {
        if !values.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Label(title, systemImage: symbol).font(.headline)
                ForEach(Array(values.enumerated()), id: \.offset) { _, value in
                    HStack(alignment: .firstTextBaseline, spacing: 9) {
                        Text("•").foregroundStyle(.secondary)
                        Text(value)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                    .font(.subheadline)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder private func description(_ job: Vacancy) -> some View {
        if !job.payload.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                Text("Job description").font(.title3.weight(.semibold))
                Text(job.payload.description)
                    .font(.body)
                    .lineSpacing(5)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            Label("No description saved. Open the original listing for the full requirements.", systemImage: "doc.text")
                .foregroundStyle(.secondary)
        }
    }

    private func supportingDetails(_ job: Vacancy) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Divider()
            DisclosureGroup("Sources & listing history", isExpanded: $showsSources) {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(job.listings) { listing in
                        VStack(alignment: .leading, spacing: 6) {
                            if let url = webURL(listing.url) {
                                Link(destination: url) {
                                    Label(sourceName(listing.source), systemImage: "arrow.up.right.square")
                                        .padding(.vertical, 6)
                                }
                            }
                            Text("Last seen \(readableDate(listing.lastSeen))")
                                .foregroundStyle(.secondary)
                            if listing.potentiallyRemoved {
                                Label("May no longer be available", systemImage: "exclamationmark.triangle")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    Text("Discovered \(readableDate(job.created))")
                        .foregroundStyle(.secondary)
                }
                .font(.subheadline)
                .padding(.top, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Text("Saved feeds may omit requirements or remote-work details. Verify them in the original listing.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private func trackerHistory(_ job: Vacancy) -> some View {
        ForEach(job.trackerEntries ?? []) { entry in
            VStack(alignment: .leading, spacing: 12) {
                Label("Application history", systemImage: "tablecells").font(.title3.weight(.semibold))
                Text("\(entry.sheet), row \(entry.row) · Original status: \(entry.originalStatus.isEmpty ? "Not recorded" : entry.originalStatus)")
                if !entry.dateSent.isEmpty {
                    Text("Date sent: \(entry.dateSent)")
                }
                if entry.struckOut {
                    Text("Crossed out in the tracker. This alone does not mean employer rejection.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                ForEach(["last update", "follow-up due", "gaps to prep", "notes", "retrospective", "salary warning"], id: \.self) { key in
                    if let value = entry.fields[key], !value.isEmpty {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(key.capitalized).font(.subheadline.weight(.semibold))
                            Text(value).font(.subheadline).textSelection(.enabled)
                        }
                    }
                }
                if let url = webURL(entry.sheetURL) {
                    Link("Open original tracker row", destination: url)
                        .padding(.vertical, 6)
                }
                Divider()
            }
        }
    }

    private func webURL(_ value: String) -> URL? {
        guard let url = URL(string: value), ["https", "http"].contains(url.scheme) else { return nil }
        return url
    }
}
