//
//  Components.swift
//  JobScout
//
//  Created by Andrii Bryzhnychenko on 10/29/26.
//

import SwiftUI

struct ScoreBadge: View {
    let score: Int
    var size: CGFloat = 44

    var body: some View {
        VStack(spacing: 2) {
            Text(score, format: .number)
                .font(.system(size: size * 0.34, weight: .semibold))
                .monospacedDigit()
            if size > 50 {
                Text("/ 100").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Fit score \(score) out of 100")
    }
}

struct Tag: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .foregroundStyle(.primary)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 4))
    }
}

struct Panel<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
    }
}

struct FactorSection: View {
    let title: String
    let symbol: String
    let factors: [String]

    var body: some View {
        if !factors.isEmpty {
            Panel {
                Label(title, systemImage: symbol)
                    .font(.headline)
                    .foregroundStyle(.primary)
                ForEach(Array(factors.enumerated()), id: \.offset) { _, factor in
                    Text(factor)
                        .font(.callout)
                        .foregroundStyle(.primary.opacity(0.85))
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
        }
    }
}

func readableDate(_ value: String) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let date = formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    return date?.formatted(date: .abbreviated, time: .shortened) ?? value
}

func sourceName(_ source: String) -> String {
    switch source {
    case "dou": "DOU"
    case "workua": "Work.ua"
    case "robota": "Robota.ua"
    case "linkedin": "LinkedIn"
    case "google_sheets": "Google Sheets"
    default: source.capitalized
    }
}
