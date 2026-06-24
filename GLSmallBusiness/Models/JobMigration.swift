//
//  JobMigration.swift
//  GLSmallBusiness
//
//  One-time, in-code enrichment of bookings created before Jobs became first-class. The schema change
//  is additive (new optional/defaulted fields fold into the schema), but a CloudKit lightweight
//  migration can only write literal defaults — it can't derive a per-record value. So on first launch
//  of this build we link each legacy booking back to its source document's customer and copy the
//  source's service address, so old bookings get the same first-class shape as new ones.
//
//  Deliberately conservative: it does NOT auto-flip status to "completed" from a paid invoice — a paid
//  invoice doesn't always mean the work is finished, so completion stays an explicit user action.
//

import Foundation
import SwiftData

enum JobMigration {
    private static let didRunKey = "didBackfillJobsFirstClass_v1"

    @MainActor
    static func runIfNeeded(_ context: ModelContext) {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: didRunKey) else { return }
        defaults.set(true, forKey: didRunKey)

        let jobs = (try? context.fetch(FetchDescriptor<ScheduledJob>())) ?? []
        guard !jobs.isEmpty else { return }

        for job in jobs {
            // Link the source document's customer (keeping the customerName snapshot if it's already set).
            if job.customer == nil, let source = job.invoice?.customer ?? job.estimate?.customer {
                job.customer = source
                if job.customerName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    job.customerName = source.listDisplayName
                }
            }
            // Carry over the source invoice's service address when the job has none.
            if job.serviceAddress.isEmpty, let address = job.invoice?.serviceAddress, !address.isEmpty {
                job.serviceAddress = address
            }
        }
        context.saveChanges()
    }
}
