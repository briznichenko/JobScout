//
//  Models.swift
//  JobScout
//
//  Created by Andrii Bryzhnychenko on 10/29/26.
//

import Foundation

public enum ApplicationStatus: String, CaseIterable, Codable, Identifiable, Sendable {
    case new = "New"
    case interested = "Interested"
    case applied = "Applied"
    case rejected = "Rejected"
    case ignored = "Ignored"

    public var id: String { rawValue }
    public var isActive: Bool { self == .new || self == .interested }
}

public struct Vacancy: Codable, Identifiable, Sendable {
    public let id: Int
    public var status: ApplicationStatus
    public let created: String
    public let updated: String
    public let kind: String
    public let payload: VacancyContent
    public let assessment: Assessment
    public let listings: [SourceListing]
    public let trackerEntries: [TrackerEntry]?

    public init(id: Int, status: ApplicationStatus, created: String, updated: String, kind: String, payload: VacancyContent, assessment: Assessment, listings: [SourceListing], trackerEntries: [TrackerEntry]?) {
        self.id = id
        self.status = status
        self.created = created
        self.updated = updated
        self.kind = kind
        self.payload = payload
        self.assessment = assessment
        self.listings = listings
        self.trackerEntries = trackerEntries
    }

    enum CodingKeys: String, CodingKey {
        case id, status, created, updated, kind, payload, assessment, listings
        case trackerEntries = "tracker_entries"
    }

    public var isActive: Bool {
        status.isActive && assessment.decision != "rejected" && !listings.allSatisfy(\.potentiallyRemoved)
    }

    public var searchableText: String {
        ([payload.title, payload.company, payload.description, payload.location, payload.salary] + (trackerEntries ?? []).flatMap { Array($0.fields.values) })
            .joined(separator: " ")
    }

    public func hasSource(_ source: String) -> Bool {
        listings.contains { $0.source == source } || (trackerEntries ?? []).contains { $0.platform == source }
    }
}

public struct TrackerEntry: Codable, Identifiable, Sendable {
    public let key: String
    public let sheet: String
    public let row: Int
    public let sheetURL: String
    public let vacancyURL: String
    public let originalStatus: String
    public let dateSent: String
    public let struckOut: Bool
    public let fields: [String: String]
    public let platform: String?
    public var id: String { key }

    public init(key: String, sheet: String, row: Int, sheetURL: String, vacancyURL: String, originalStatus: String, dateSent: String, struckOut: Bool, fields: [String: String], platform: String?) {
        self.key = key
        self.sheet = sheet
        self.row = row
        self.sheetURL = sheetURL
        self.vacancyURL = vacancyURL
        self.originalStatus = originalStatus
        self.dateSent = dateSent
        self.struckOut = struckOut
        self.fields = fields
        self.platform = platform
    }

    enum CodingKeys: String, CodingKey {
        case key, sheet, row, fields, platform
        case sheetURL = "sheet_url"
        case vacancyURL = "vacancy_url"
        case originalStatus = "original_status"
        case dateSent = "date_sent"
        case struckOut = "struck_out"
    }
}

public struct SourceInfo: Codable, Identifiable, Sendable {
    public let id: String
    public let mode: String
    public let enabled: Bool
    public let count: Int
    public let failures: [String]
    public let searchURL: String
    public let directory: String

    public init(id: String, mode: String, enabled: Bool, count: Int, failures: [String], searchURL: String, directory: String) {
        self.id = id
        self.mode = mode
        self.enabled = enabled
        self.count = count
        self.failures = failures
        self.searchURL = searchURL
        self.directory = directory
    }

    enum CodingKeys: String, CodingKey {
        case id, mode, enabled, count, failures, directory
        case searchURL = "search_url"
    }
}

public struct VacancyContent: Codable, Sendable {
    public let source: String
    public let url: String
    public let title: String
    public let description: String
    public let company: String
    public let location: String
    public let salary: String
    public let published: String
    public init(source: String, url: String, title: String, description: String, company: String, location: String, salary: String, published: String) {
        self.source = source
        self.url = url
        self.title = title
        self.description = description
        self.company = company
        self.location = location
        self.salary = salary
        self.published = published
    }

}

public struct Assessment: Codable, Sendable {
    public let score: Int
    public let decision: String
    public let role: String
    public let positive: [String]
    public let negative: [String]
    public let missing: [String]
    public let uncertainty: [String]
    public let rejected: [String]
    public let components: [String: Int]
    public init(score: Int, decision: String, role: String, positive: [String], negative: [String], missing: [String], uncertainty: [String], rejected: [String], components: [String: Int]) {
        self.score = score
        self.decision = decision
        self.role = role
        self.positive = positive
        self.negative = negative
        self.missing = missing
        self.uncertainty = uncertainty
        self.rejected = rejected
        self.components = components
    }

}

public struct SourceListing: Codable, Identifiable, Sendable {
    public let source: String
    public let url: String
    public let lastSeen: String
    public let potentiallyRemoved: Bool

    public var id: String { source + "|" + url }

    enum CodingKeys: String, CodingKey {
        case source, url
        case lastSeen = "last_seen"
        case potentiallyRemoved = "potentially_removed"
    }

    public init(source: String, url: String, lastSeen: String, potentiallyRemoved: Bool) {
        self.source = source
        self.url = url
        self.lastSeen = lastSeen
        self.potentiallyRemoved = potentiallyRemoved
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(source, forKey: .source)
        try container.encode(url, forKey: .url)
        try container.encode(lastSeen, forKey: .lastSeen)
        try container.encode(potentiallyRemoved ? 1 : 0, forKey: .potentiallyRemoved)
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        source = try container.decode(String.self, forKey: .source)
        url = try container.decode(String.self, forKey: .url)
        lastSeen = try container.decode(String.self, forKey: .lastSeen)
        potentiallyRemoved = try container.decode(Int.self, forKey: .potentiallyRemoved) != 0
    }
}

public struct ScanSummary: Codable, Sendable {
    public let id: Int
    public let started: String
    public let finished: String
    public let failures: [String]
    public let newCount: Int
    public let updatedCount: Int
    public let unchangedCount: Int

    public init(id: Int, started: String, finished: String, failures: [String], newCount: Int, updatedCount: Int, unchangedCount: Int) {
        self.id = id
        self.started = started
        self.finished = finished
        self.failures = failures
        self.newCount = newCount
        self.updatedCount = updatedCount
        self.unchangedCount = unchangedCount
    }

    enum CodingKeys: String, CodingKey {
        case id, started, finished, failures
        case newCount = "new_count"
        case updatedCount = "updated_count"
        case unchangedCount = "unchanged_count"
    }
}

public struct JobSnapshot: Codable, Sendable {
    public let jobs: [Vacancy]
    public let lastRun: ScanSummary?
    public let workspace: String
    public let reportPath: String
    public let message: String?
    public let minimumScore: Int
    public let strongThreshold: Int
    public let sources: [SourceInfo]?
    public var browser: BrowserReadiness? = nil

    public init(jobs: [Vacancy], lastRun: ScanSummary?, workspace: String, reportPath: String, message: String?, minimumScore: Int, strongThreshold: Int, sources: [SourceInfo]?, browser: BrowserReadiness? = nil) {
        self.jobs = jobs
        self.lastRun = lastRun
        self.workspace = workspace
        self.reportPath = reportPath
        self.message = message
        self.minimumScore = minimumScore
        self.strongThreshold = strongThreshold
        self.sources = sources
        self.browser = browser
    }

    enum CodingKeys: String, CodingKey {
        case jobs, workspace, message, sources, browser
        case lastRun = "last_run"
        case reportPath = "report_path"
        case minimumScore = "minimum_score"
        case strongThreshold = "strong_threshold"
    }
}

public struct BrowserReadiness: Codable, Sendable {
    public let ready: Bool
    public let message: String
    public init(ready: Bool, message: String) {
        self.ready = ready
        self.message = message
    }

}

public enum Mailbox: String, CaseIterable, Identifiable, Sendable {
    case inbox = "Inbox"
    case strong = "Strong matches"
    case interested = "Interested"
    case applied = "Applied"
    case audit = "Filter audit"
    case rejected = "Rejected"
    case ignored = "Ignored"
    case all = "All vacancies"
    case tracker = "Application tracker"

    public var id: String { rawValue }

    public var symbol: String {
        switch self {
        case .inbox: "tray"
        case .strong: "sparkle.magnifyingglass"
        case .interested: "star"
        case .applied: "paperplane"
        case .audit: "line.3.horizontal.decrease.circle"
        case .rejected: "xmark.circle"
        case .ignored: "archivebox"
        case .all: "square.stack"
        case .tracker: "tablecells"
        }
    }

    public func contains(_ job: Vacancy, minimumScore: Int, strongThreshold: Int) -> Bool {
        switch self {
        case .inbox: job.isActive && job.assessment.score >= minimumScore
        case .strong: job.isActive && job.assessment.score >= strongThreshold
        case .interested: job.status == .interested
        case .applied: job.status == .applied
        case .audit: job.assessment.decision == "rejected"
        case .rejected: job.status == .rejected
        case .ignored: job.status == .ignored
        case .all: true
        case .tracker: !(job.trackerEntries ?? []).isEmpty
        }
    }
}

public enum RoleFilter: String, CaseIterable, Identifiable, Sendable {
    case all = "All roles"
    case apple = "Apple"
    case support = "Support"
    public var id: String { rawValue }
}

public enum VacancySort: String, CaseIterable, Identifiable, Sendable {
    case fit = "Best fit"
    case recent = "Recently discovered"
    public var id: String { rawValue }
}
