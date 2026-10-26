import Foundation

enum ApplicationStatus: String, CaseIterable, Codable, Identifiable, Sendable {
    case new = "New"
    case interested = "Interested"
    case applied = "Applied"
    case rejected = "Rejected"
    case ignored = "Ignored"

    var id: String { rawValue }
    var isActive: Bool { self == .new || self == .interested }
}

struct Vacancy: Decodable, Identifiable, Sendable {
    let id: Int
    var status: ApplicationStatus
    let created: String
    let updated: String
    let kind: String
    let payload: VacancyContent
    let assessment: Assessment
    let listings: [SourceListing]

    var isActive: Bool {
        status.isActive && assessment.decision != "rejected" && !listings.allSatisfy(\.potentiallyRemoved)
    }

    var searchableText: String {
        [payload.title, payload.company, payload.description, payload.location, payload.salary]
            .joined(separator: " ")
    }
}

struct VacancyContent: Decodable, Sendable {
    let source: String
    let url: String
    let title: String
    let description: String
    let company: String
    let location: String
    let salary: String
    let published: String
}

struct Assessment: Decodable, Sendable {
    let score: Int
    let decision: String
    let role: String
    let positive: [String]
    let negative: [String]
    let missing: [String]
    let uncertainty: [String]
    let rejected: [String]
    let components: [String: Int]
}

struct SourceListing: Decodable, Identifiable, Sendable {
    let source: String
    let url: String
    let lastSeen: String
    let potentiallyRemoved: Bool

    var id: String { source + "|" + url }

    enum CodingKeys: String, CodingKey {
        case source, url
        case lastSeen = "last_seen"
        case potentiallyRemoved = "potentially_removed"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        source = try container.decode(String.self, forKey: .source)
        url = try container.decode(String.self, forKey: .url)
        lastSeen = try container.decode(String.self, forKey: .lastSeen)
        potentiallyRemoved = try container.decode(Int.self, forKey: .potentiallyRemoved) != 0
    }
}

struct ScanSummary: Decodable, Sendable {
    let id: Int
    let started: String
    let finished: String
    let failures: [String]
    let newCount: Int
    let updatedCount: Int
    let unchangedCount: Int

    enum CodingKeys: String, CodingKey {
        case id, started, finished, failures
        case newCount = "new_count"
        case updatedCount = "updated_count"
        case unchangedCount = "unchanged_count"
    }
}

struct JobSnapshot: Decodable, Sendable {
    let jobs: [Vacancy]
    let lastRun: ScanSummary?
    let workspace: String
    let reportPath: String
    let message: String?
    let minimumScore: Int
    let strongThreshold: Int

    enum CodingKeys: String, CodingKey {
        case jobs, workspace, message
        case lastRun = "last_run"
        case reportPath = "report_path"
        case minimumScore = "minimum_score"
        case strongThreshold = "strong_threshold"
    }
}

enum Mailbox: String, CaseIterable, Identifiable, Sendable {
    case inbox = "Inbox"
    case strong = "Strong matches"
    case interested = "Interested"
    case applied = "Applied"
    case audit = "Filter audit"
    case rejected = "Rejected"
    case ignored = "Ignored"
    case all = "All vacancies"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .inbox: "tray"
        case .strong: "sparkle.magnifyingglass"
        case .interested: "star"
        case .applied: "paperplane"
        case .audit: "line.3.horizontal.decrease.circle"
        case .rejected: "xmark.circle"
        case .ignored: "archivebox"
        case .all: "square.stack"
        }
    }

    func contains(_ job: Vacancy, minimumScore: Int, strongThreshold: Int) -> Bool {
        switch self {
        case .inbox: job.isActive && job.assessment.score >= minimumScore
        case .strong: job.isActive && job.assessment.score >= strongThreshold
        case .interested: job.status == .interested
        case .applied: job.status == .applied
        case .audit: job.assessment.decision == "rejected"
        case .rejected: job.status == .rejected
        case .ignored: job.status == .ignored
        case .all: true
        }
    }
}

enum RoleFilter: String, CaseIterable, Identifiable {
    case all = "All roles"
    case apple = "Apple"
    case support = "Support"
    var id: String { rawValue }
}

enum VacancySort: String, CaseIterable, Identifiable {
    case fit = "Best fit"
    case recent = "Recently discovered"
    var id: String { rawValue }
}
