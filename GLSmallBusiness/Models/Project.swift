//
//  Project.swift
//  GLSmallBusiness
//
//  An OPTIONAL grouping above jobs — invisible until a contractor reaches for it. A Project bundles
//  several jobs (e.g. the phases of a remodel) plus a signed master agreement, and rolls their billing
//  up to one total. Solo / single-job users never see it; it appears via "Add to project" on a job.
//

import Foundation
import SwiftData

@Model
final class Project {
    var name: String = ""
    var createdAt: Date = Date.now

    /// The signed master agreement for the whole project (PDF or image), optional.
    @Attribute(.externalStorage) var masterAgreementData: Data?
    var masterAgreementName: String = ""

    /// The customer this project is for. Optional + nullify so deleting a customer keeps the project.
    var customer: Customer?

    /// The jobs grouped under this project. Nullify on delete so removing a project keeps its jobs.
    @Relationship(deleteRule: .nullify, inverse: \ScheduledJob.project)
    var jobs: [ScheduledJob]?

    init(name: String = "", customer: Customer? = nil) {
        self.name = name
        self.customer = customer
    }
}

extension Project {
    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? String(localized: "Project") : trimmed
    }

    var sortedJobs: [ScheduledJob] { (jobs ?? []).sorted { $0.startDate < $1.startDate } }
    var hasMasterAgreement: Bool { masterAgreementData != nil }

    // Roll-ups across the project's jobs (each computed from that job's billing invoices).
    var contractedValue: Double { sortedJobs.reduce(0) { $0 + $1.contractedValue } }
    var invoicedTotal: Double { sortedJobs.reduce(0) { $0 + $1.invoicedTotal } }
    var amountPaid: Double { sortedJobs.reduce(0) { $0 + $1.amountPaid } }
    var balanceDue: Double { sortedJobs.reduce(0) { $0 + $1.balanceDue } }
    var remainingToInvoice: Double { max(0, contractedValue - invoicedTotal) }
}
