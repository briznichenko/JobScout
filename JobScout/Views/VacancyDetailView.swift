import SwiftUI

struct VacancyDetailView: View {
    let job: Vacancy
    @Bindable var store: JobStore
    @State private var showsBreakdown = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                actions
                metadata
                trackerHistory
                if job.assessment.decision == "rejected" {
                    FactorSection(title: "Why this was filtered", symbol: "line.3.horizontal.decrease.circle", color: .orange, factors: job.assessment.rejected)
                }
                FactorSection(title: "Why it fits", symbol: "checkmark.circle", color: .teal, factors: job.assessment.positive)
                FactorSection(title: "Concerns", symbol: "exclamationmark.circle", color: .orange, factors: job.assessment.negative)
                FactorSection(title: "Missing or unverified requirements", symbol: "questionmark.diamond", color: .orange, factors: job.assessment.missing)
                FactorSection(title: "Check before applying", symbol: "checklist", color: .secondary, factors: job.assessment.uncertainty)
                breakdown
                VStack(alignment: .leading, spacing: 12) {
                    Text("Vacancy description").font(.title3.bold())
                    Text(job.payload.description)
                        .font(.system(size: 13))
                        .lineSpacing(5)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Divider()
                VStack(alignment: .leading, spacing: 12) {
                    Text("Original sources").font(.headline)
                    ForEach(job.listings) { listing in
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 4) {
                                if let url = URL(string: listing.url), ["https", "http"].contains(url.scheme) {
                                    Link(destination: url) {
                                        Label(sourceName(listing.source), systemImage: "arrow.up.right.square")
                                    }
                                }
                                Text("Last seen \(readableDate(listing.lastSeen))")
                                    .font(.caption).foregroundStyle(.secondary)
                                if listing.potentiallyRemoved {
                                    Text("Potentially removed in complete snapshots")
                                        .font(.caption).foregroundStyle(.orange)
                                }
                            }
                            Spacer()
                        }
                    }
                    Text("Discovered \(readableDate(job.created)). RSS feeds may omit requirements and work-format details. A score is a ranking, not a hiring probability.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(28)
            .frame(maxWidth: 880, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(.background)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    Tag(text: job.assessment.role == "apple" ? "Apple engineering" : job.assessment.role == "support" ? "Technical support" : "Manual role review", color: .teal)
                    if job.assessment.decision == "review" {
                        Tag(text: "Needs review", color: .orange)
                    }
                }
                Text(job.payload.title)
                    .font(.system(size: 25, weight: .bold))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Text(job.payload.company.isEmpty ? "Company not provided by the feed" : job.payload.company)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 0)
            VStack(spacing: 8) {
                ScoreBadge(score: job.assessment.score, size: 80, minimumScore: store.minimumScore, strongThreshold: store.strongThreshold)
                Text("FIT SCORE")
                    .font(.system(size: 9, weight: .semibold)).tracking(1.2).foregroundStyle(.secondary)
            }
        }
    }

    private var actions: some View {
        HStack(spacing: 12) {
            if let url = URL(string: job.payload.url), ["https", "http"].contains(url.scheme) {
                Link(destination: url) {
                    Label(job.payload.source == "google_sheets" && URL(string: job.payload.url)?.host == "docs.google.com" ? "Open tracker row" : "Open vacancy", systemImage: "arrow.up.right")
                }
                .buttonStyle(.borderedProminent)
            }
            Picker("Status", selection: Binding(get: { job.status }, set: { store.updateStatus($0, for: job.id) })) {
                ForEach(ApplicationStatus.allCases) { status in Text(status.rawValue).tag(status) }
            }
            .pickerStyle(.menu)
            .fixedSize()
            .disabled(store.isBusy)
            Spacer(minLength: 0)
        }
    }

    private var metadata: some View {
        Panel {
            Label(job.payload.location.isEmpty ? "Location and remote eligibility unconfirmed" : job.payload.location, systemImage: "mappin.and.ellipse")
            Label(job.payload.salary.isEmpty ? "Salary not published in the feed" : job.payload.salary, systemImage: "banknote")
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }

    private var breakdown: some View {
        DisclosureGroup("Score breakdown", isExpanded: $showsBreakdown) {
            VStack(spacing: 10) {
                ForEach(job.assessment.components.keys.sorted(), id: \.self) { key in
                    HStack {
                        Text(key == "missing_penalty" ? "Missing requirements" : key.capitalized)
                        Spacer()
                        Text(job.assessment.components[key] ?? 0, format: .number.sign(strategy: .always()))
                            .monospacedDigit()
                    }
                    .font(.callout)
                }
                Divider()
                HStack {
                    Text("Final score").fontWeight(.semibold)
                    Spacer()
                    Text("\(job.assessment.score) / 100").monospacedDigit()
                }
            }
            .padding(.top, 14)
        }
        .padding(16)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder private var trackerHistory: some View {
        ForEach(job.trackerEntries ?? []) { entry in
            Panel {
                Label("Application tracker", systemImage: "tablecells").font(.headline)
                Text("\(entry.sheet), row \(entry.row) · Original status: \(entry.originalStatus.isEmpty ? "Not recorded" : entry.originalStatus)")
                    .font(.callout)
                if !entry.dateSent.isEmpty {
                    Text("Date sent: \(entry.dateSent)").font(.callout)
                }
                if entry.struckOut {
                    Text("Crossed out in the tracker. This does not by itself mean employer rejection.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(["last update", "follow-up due", "gaps to prep", "notes", "retrospective", "salary warning"], id: \.self) { key in
                    if let value = entry.fields[key], !value.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(key.capitalized).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            Text(value).font(.callout).textSelection(.enabled)
                        }
                    }
                }
                if let url = URL(string: entry.sheetURL) {
                    Link("Open original tracker row", destination: url)
                }
            }
        }
    }
}
