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

    // MARK: Sync identity (platform Phase 0 — additive into GLSchemaV1)
    /// Stable identity for the coming server sync. Optional, NOT `= UUID()`: a SwiftData
    /// attribute default is captured once in schema metadata, so migration would give
    /// every existing record the SAME uuid. SyncIdentityBackfill mints these uniquely.
    /// `.preserveValueOnDeletion` keeps the uuid in the DELETE tombstone. Without it the
    /// tombstone is empty, the syncID dies with the row, and the server can never be told
    /// the record went away — i.e. deletes do not sync at all (GLSYNC-SPEC.md §2a).
    @Attribute(.preserveValueOnDeletion) var syncID: UUID?
    /// Last local edit, stamped by `saveChanges`. Autosaved edits are not stamped yet —
    /// the GLSync client owns real change capture when it lands (migration Phase 3).
    var updatedAt: Date?
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
        return trimmed.isEmpty ? mbLoc("Project") : trimmed
    }

    var sortedJobs: [ScheduledJob] { liveRows(jobs).sorted { $0.startDate < $1.startDate } }
    var hasMasterAgreement: Bool { masterAgreementData != nil }

    // Roll-ups across the project's jobs (each computed from that job's billing invoices).
    // Sums of amounts each job already shows (whole cents, law 60).
    var contractedValue: Double { DomainMoney.roundedSum(sortedJobs.map(\.contractedValue)) }
    var invoicedTotal: Double { DomainMoney.roundedSum(sortedJobs.map(\.invoicedTotal)) }
    var amountPaid: Double { DomainMoney.roundedSum(sortedJobs.map(\.amountPaid)) }
    var balanceDue: Double { DomainMoney.roundedSum(sortedJobs.map(\.balanceDue)) }
    var remainingToInvoice: Double { DomainMoney.remaining(contractedValue, less: invoicedTotal) }
}
