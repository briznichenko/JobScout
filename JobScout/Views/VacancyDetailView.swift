//
//  VacancyDetailView.swift
//  JobScout
//
//  Created by Andrii Bryzhnychenko on 10/29/26.
//

import SwiftUI

struct VacancyDetailView: View {
    let job: Vacancy
    @Bindable var store: JobStore
    @State private var showsBreakdown = false
    @State private var showsSources = false
    @State private var showsFitReasons = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                metadata
                assessment
                trackerHistory
                description
                supportingDetails
            }
            .padding(24)
            .frame(maxWidth: 800, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(.background)
        .safeAreaInset(edge: .top, spacing: 0) {
            actions
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
                .frame(maxWidth: 800, alignment: .leading)
                .frame(maxWidth: .infinity)
                .background(.bar)
                .overlay(alignment: .bottom) { Divider() }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text(job.assessment.role == "apple" ? "Apple engineering" : job.assessment.role == "support" ? "Technical support" : "Role needs review")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if job.assessment.decision == "review" {
                    Tag(text: "Needs review")
                }
            }
            Text(job.payload.title)
                .font(.system(size: 28, weight: .semibold))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Text(job.payload.company.isEmpty ? "Company not provided" : job.payload.company)
                .font(.title3)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }

    private var actions: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                listingLink
                    .fixedSize()
                Spacer(minLength: 12)
                statusActions
                    .fixedSize()
            }
            VStack(alignment: .leading, spacing: 10) {
                listingLink
                statusActions
            }
        }
        .controlSize(.large)
    }

    @ViewBuilder private var listingLink: some View {
        if let url = webURL(job.payload.url) {
            Link(destination: url) {
                Label(job.payload.source == "google_sheets" && url.host == "docs.google.com" ? "Open tracker" : "Open listing", systemImage: "arrow.up.right")
                    .frame(minHeight: 20)
            }
            .buttonStyle(.borderedProminent)
            .help("Open the original listing in your browser")
        }
    }

    private var statusActions: some View {
        HStack(spacing: 8) {
            Button {
                store.updateStatus(.interested, for: job.id)
            } label: {
                Label("Interested", systemImage: job.status == .interested ? "star.fill" : "star")
                    .frame(minHeight: 20)
            }
            .help(job.status == .interested ? "Already marked interested" : "Save this vacancy as interested")
            .disabled(store.isBusy || job.status == .interested)
            Button {
                store.updateStatus(.applied, for: job.id)
            } label: {
                Label("Applied", systemImage: job.status == .applied ? "checkmark.circle.fill" : "paperplane")
                    .frame(minHeight: 20)
            }
            .help(job.status == .applied ? "Already marked applied" : "Mark that you have applied")
            .disabled(store.isBusy || job.status == .applied)
            Menu {
                Text("Status: \(job.status.rawValue)")
                Divider()
                ForEach(ApplicationStatus.allCases) { status in
                    Button {
                        store.updateStatus(status, for: job.id)
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
                Image(systemName: "ellipsis")
                    .frame(minWidth: 20, minHeight: 20)
            }
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(store.isBusy)
            .help("Change application status · currently \(job.status.rawValue)")
            .accessibilityLabel("Application status: \(job.status.rawValue). More actions")
        }
        .buttonStyle(.bordered)
    }

    private var metadata: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(job.payload.location.isEmpty ? "Location and remote eligibility unconfirmed" : job.payload.location, systemImage: "mappin.and.ellipse")
            Label(job.payload.salary.isEmpty ? "Salary not provided" : job.payload.salary, systemImage: "banknote")
            Label("Status: \(job.status.rawValue)", systemImage: "bookmark")
        }
        .font(.system(size: 14))
        .foregroundStyle(.secondary)
        .textSelection(.enabled)
    }

    private var assessment: some View {
        VStack(alignment: .leading, spacing: 18) {
            Divider()
            HStack(alignment: .center, spacing: 12) {
                ScoreBadge(score: job.assessment.score, size: 56)
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
            breakdown
            Divider()
        }
    }

    @ViewBuilder private func factors(_ title: String, symbol: String, values: [String]) -> some View {
        if !values.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Label(title, systemImage: symbol)
                    .font(.headline)
                ForEach(Array(values.enumerated()), id: \.offset) { _, value in
                    HStack(alignment: .firstTextBaseline, spacing: 9) {
                        Text("•").foregroundStyle(.secondary)
                        Text(value)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                    .font(.system(size: 14))
                }
            }
        }
    }

    private var breakdown: some View {
        DisclosureGroup("Score breakdown", isExpanded: $showsBreakdown) {
            VStack(spacing: 10) {
                ForEach(job.assessment.components.keys.sorted(), id: \.self) { key in
                    HStack {
                        Text(key == "missing_penalty" ? "Missing requirements" : key.replacingOccurrences(of: "_", with: " ").capitalized)
                        Spacer()
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
            .font(.system(size: 14))
            .padding(.top, 12)
        }
        .font(.subheadline)
    }

    @ViewBuilder private var description: some View {
        if !job.payload.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                Text("Job description").font(.title3.weight(.semibold))
                Text(job.payload.description)
                    .font(.system(size: 15))
                    .lineSpacing(6)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            Label("No description saved. Open the original listing for the full requirements.", systemImage: "doc.text")
                .font(.body)
                .foregroundStyle(.secondary)
        }
    }

    private var supportingDetails: some View {
        VStack(alignment: .leading, spacing: 14) {
            Divider()
            DisclosureGroup("Sources & listing history", isExpanded: $showsSources) {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(job.listings) { listing in
                        VStack(alignment: .leading, spacing: 5) {
                            if let url = webURL(listing.url) {
                                Link(destination: url) {
                                    Label(sourceName(listing.source), systemImage: "arrow.up.right.square")
                                }
                            }
                            Text("Last seen \(readableDate(listing.lastSeen))")
                                .font(.subheadline).foregroundStyle(.secondary)
                            if listing.potentiallyRemoved {
                                Label("May no longer be available", systemImage: "exclamationmark.triangle")
                                    .font(.subheadline).foregroundStyle(.secondary)
                            }
                        }
                    }
                    Text("Discovered \(readableDate(job.created))")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                .padding(.top, 12)
            }
            Text("Saved feeds may omit requirements or remote-work details. Verify them in the original listing.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var trackerHistory: some View {
        ForEach(job.trackerEntries ?? []) { entry in
            VStack(alignment: .leading, spacing: 12) {
                Label("Application history", systemImage: "tablecells").font(.title3.weight(.semibold))
                Text("\(entry.sheet), row \(entry.row) · Original status: \(entry.originalStatus.isEmpty ? "Not recorded" : entry.originalStatus)")
                    .font(.body)
                if !entry.dateSent.isEmpty {
                    Text("Date sent: \(entry.dateSent)").font(.body)
                }
                if entry.struckOut {
                    Text("Crossed out in the tracker. This alone does not mean employer rejection.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                ForEach(["last update", "follow-up due", "gaps to prep", "notes", "retrospective", "salary warning"], id: \.self) { key in
                    if let value = entry.fields[key], !value.isEmpty {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(key.capitalized).font(.subheadline.weight(.semibold))
                            Text(value).font(.system(size: 14)).textSelection(.enabled)
                        }
                    }
                }
                if let url = webURL(entry.sheetURL) {
                    Link("Open original tracker row", destination: url)
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
