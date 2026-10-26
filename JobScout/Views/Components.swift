import SwiftUI

struct ScoreBadge: View {
    let score: Int
    var size: CGFloat = 44
    var minimumScore: Int = 45
    var strongThreshold: Int = 70

    private var color: Color { score >= strongThreshold ? .teal : score >= minimumScore ? .orange : .secondary }

    var body: some View {
        ZStack {
            Circle().stroke(color.opacity(0.14), lineWidth: size > 50 ? 6 : 3)
            Circle()
                .trim(from: 0, to: CGFloat(score) / 100)
                .stroke(color, style: StrokeStyle(lineWidth: size > 50 ? 6 : 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: 0) {
                Text(score, format: .number)
                    .font(.system(size: size * 0.34, weight: .semibold, design: .rounded))
                if size > 50 {
                    Text("/ 100").font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: size, height: size)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Fit score \(score) out of 100")
    }
}

struct Tag: View {
    let text: String
    var color: Color = .secondary

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .foregroundStyle(color)
            .background(color.opacity(0.10), in: Capsule())
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
    let color: Color
    let factors: [String]

    var body: some View {
        if !factors.isEmpty {
            Panel {
                Label(title, systemImage: symbol)
                    .font(.headline)
                    .foregroundStyle(color)
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
