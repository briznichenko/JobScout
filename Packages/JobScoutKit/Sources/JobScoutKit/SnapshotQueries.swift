//
//  SnapshotQueries.swift
//  JobScoutKit
//
//  Created by Andrii Bryzhnychenko on 10/31/26.
//

import Foundation

extension JobSnapshot {
    public var sourceIDs: [String] {
        Set(jobs.flatMap { $0.listings.map(\.source) } + (sources ?? []).map(\.id)).sorted()
    }

    public func count(in mailbox: Mailbox) -> Int {
        jobs.filter { mailbox.contains($0, minimumScore: minimumScore, strongThreshold: strongThreshold) }.count
    }

    public func vacancies(in mailbox: Mailbox, role: RoleFilter, source: String, search: String, sort: VacancySort) -> [Vacancy] {
        jobs.filter { job in
            mailbox.contains(job, minimumScore: minimumScore, strongThreshold: strongThreshold)
                && (role == .all || job.assessment.role == role.rawValue.lowercased())
                && (source == "All sources" || job.hasSource(source))
                && (search.isEmpty || job.searchableText.localizedStandardContains(search))
        }.sorted { left, right in
            if sort == .recent, left.created != right.created {
                return left.created > right.created
            }
            if left.assessment.score != right.assessment.score {
                return left.assessment.score > right.assessment.score
            }
            return left.id < right.id
        }
    }
}
