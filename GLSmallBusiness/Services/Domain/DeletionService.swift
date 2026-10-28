//
//  DeletionService.swift
//  GLSmallBusiness
//
//  THE one way a person (or, later, the assistant) deletes a record. Every list swipe, bulk
//  delete, detail-screen Delete button and document Remove ends here, so the rules can't drift
//  between them:
//    - read-only (lapsed or offline) for each kind's OWN delete operation;
//    - liveness: a record already gone refuses the whole batch;
//    - the paid lock — an invoice that is paid (`Invoice.isMoneyLocked`), a customer with a paid
//      invoice (`Customer.hasPaidInvoice`), a change order billed to a paid invoice
//      (`ChangeOrder.isBilledToLockedInvoice`). The server refuses these too, but a refused delete
//      is parked for good, so the phone must refuse first;
//    - the Worker's 500-row cap on one delete op's cascade (sync.ts), checked per root before
//      anything is touched — for a TOOL only: the screens have always deleted a big customer
//      locally, and whether a tap should be refused instead is the owner's call (the Worker then
//      refuses that op, and the rows stay on the server);
//    - all-or-nothing: one refusal refuses the batch (the CustomersScreen bulk rule);
//    - payments are append-only and are never deleted (law 60): `Kind.payment` always refuses,
//      and so does any delete that would take one with it — an invoice holding a recorded
//      payment, paid in full or not (`Invoice.hasRecordedPayments`), or a customer with such an
//      invoice (`Customer.hasInvoiceWithPayments`). The server refuses the same set
//      (`has_payments`, QA F148), after the paid lock, which answers first here too. Projects and
//      jobs never cascade an invoice, so they never reach a payment;
//    - the per-kind steps: change orders take their billed items off the invoice first,
//      subcontractors lose their Keychain TIN first, everything (price items included, a sync type
//      since 2026-10-03) goes through `deleteSynced`;
//    - one `saveChanges()` at the end, so the queued delete op persists with the delete.
//  A batch of more than 25 roots is allowed but reported: that many tombstones in one pull trips
//  the mass-delete breaker on the owner's other devices (GLSyncEngine), pausing their sync until
//  someone taps continue there.
//

import Foundation
import OSLog
import SwiftData

@MainActor
enum DeletionService {

    /// The Worker refuses a delete op whose cascade names more rows than this (`sync.ts`).
    static let maxCascadeRows = 500
    /// More roots than this in one batch trips the other devices' mass-delete breaker.
    static let otherDevicesBreakerRoots = 25

    // MARK: Kinds and targets

    /// The record kinds, named the way the assistant's tools name them.
    enum Kind: String, CaseIterable, Sendable {
        case customer, estimate, contract, invoice
        case changeOrder = "change_order"
        case job, receipt
        case priceItem = "price_item"
        case employee, subcontractor, project
        case timeEntry = "time_entry"
        case paycheck
        case subPayment = "sub_payment"
        case attachment
        /// A customer's package extra (`CustomerDocument`).
        case document
        /// Invoice payments. Named so a request for one gets a plain refusal, never a delete.
        case payment

        /// The `MBWriteOperation` a delete of this kind is gated (and logged) as.
        var operation: MBWriteOperation {
            switch self {
            case .customer: return .deleteCustomer
            case .estimate: return .deleteEstimate
            case .contract: return .deleteContract
            case .invoice: return .deleteInvoice
            case .changeOrder: return .deleteChangeOrder
            case .job: return .deleteJob
            case .receipt: return .deleteReceipt
            case .priceItem: return .deletePriceSheetItem
            case .employee: return .deleteEmployee
            case .subcontractor: return .deleteSubcontractor
            case .project: return .deleteProject
            case .timeEntry: return .deleteHours
            case .paycheck: return .deletePaycheck
            case .subPayment: return .deleteSubcontractorPayment
            case .attachment: return .deleteJobAttachment
            case .document: return .deleteDocument
            case .payment: return .deletePayment
            }
        }
    }

    /// One record to delete.
    enum Target {
        case customer(Customer)
        case estimate(Estimate)
        case contract(Contract)
        case invoice(Invoice)
        case changeOrder(ChangeOrder)
        case job(ScheduledJob)
        case receipt(Receipt)
        case priceItem(PriceSheetItem)
        case employee(Employee)
        case subcontractor(Subcontractor)
        case project(Project)
        case timeEntry(TimeEntry)
        case paycheck(Paycheck)
        case subPayment(SubPayment)
        /// A job or invoice photo or document (`JobAttachment`).
        case attachment(JobAttachment)
        /// A customer's package extra.
        case customerDocument(CustomerDocument)

        var kind: Kind {
            switch self {
            case .customer: return .customer
            case .estimate: return .estimate
            case .contract: return .contract
            case .invoice: return .invoice
            case .changeOrder: return .changeOrder
            case .job: return .job
            case .receipt: return .receipt
            case .priceItem: return .priceItem
            case .employee: return .employee
            case .subcontractor: return .subcontractor
            case .project: return .project
            case .timeEntry: return .timeEntry
            case .paycheck: return .paycheck
            case .subPayment: return .subPayment
            case .attachment: return .attachment
            case .customerDocument: return .document
            }
        }

        /// The `MBWriteOperation` this delete is gated (and logged) as.
        var operation: MBWriteOperation { kind.operation }

        var model: any PersistentModel {
            switch self {
            case .customer(let m): return m
            case .estimate(let m): return m
            case .contract(let m): return m
            case .invoice(let m): return m
            case .changeOrder(let m): return m
            case .job(let m): return m
            case .receipt(let m): return m
            case .priceItem(let m): return m
            case .employee(let m): return m
            case .subcontractor(let m): return m
            case .project(let m): return m
            case .timeEntry(let m): return m
            case .paycheck(let m): return m
            case .subPayment(let m): return m
            case .attachment(let m): return m
            case .customerDocument(let m): return m
            }
        }

        /// The synced record. Every kind is one (the Price Sheet since 2026-10-03, QA finding F3).
        fileprivate var syncRecord: GLSyncRecord? {
            switch self {
            case .customer(let m): return m
            case .estimate(let m): return m
            case .contract: return nil
            case .invoice(let m): return m
            case .changeOrder(let m): return m
            case .job(let m): return m
            case .receipt(let m): return m
            case .priceItem(let m): return m
            case .employee(let m): return m
            case .subcontractor(let m): return m
            case .project(let m): return m
            case .timeEntry(let m): return m
            case .paycheck(let m): return m
            case .subPayment(let m): return m
            case .attachment(let m): return m
            case .customerDocument(let m): return m
            }
        }

        /// What goes with it, in the words the confirmations already use (CustomersScreen and
        /// friends), so the assistant's confirmation reads like the button's.
        var cascadeDescription: String {
            switch self {
            // Payments are never in these lists: a record holding one can't be deleted (law 60).
            // A customer's documents are their insurance certificates and package extras.
            case .customer:
                return mbLoc("Their estimates, invoices, change orders, receipts, and documents are removed too. This can’t be undone.")
            case .contract:
                return mbLoc("Its change orders, scheduled job, and draft items are removed too. This can’t be undone.")
            case .invoice:
                return mbLoc("Their line items, change orders, photos, and documents are removed too. This can’t be undone.")
            case .estimate:
                return mbLoc("Their line items are removed too. This can’t be undone.")
            case .changeOrder(let order) where order.appliedToInvoice:
                return mbLoc("Its items come off the invoice too. This can’t be undone.")
            case .job:
                return mbLoc("Its photos and documents are removed too. This can’t be undone.")
            case .project:
                return mbLoc("Its jobs are kept. This can’t be undone.")
            case .employee:
                return mbLoc("Their hours and paychecks are removed too. This can’t be undone.")
            case .subcontractor:
                return mbLoc("Their payment history is removed too. This can’t be undone.")
            case .paycheck:
                return mbLoc("The pay it covered goes back to owed. This can’t be undone.")
            default:
                return mbLoc("This can’t be undone.")
            }
        }

        /// The same effect WITHOUT the closing "This can’t be undone." — the assistant's
        /// confirmation alert says that line itself (law 8: a destructive alert always does), so
        /// it must not be said twice. Nil when nothing else goes with the record.
        var cascadeEffect: String? {
            switch self {
            case .customer:
                return mbLoc("Their estimates, invoices, change orders, receipts, and documents are removed too.")
            case .contract:
                return mbLoc("Its change orders, scheduled job, and draft items are removed too.")
            case .invoice: return mbLoc("Their line items, change orders, photos, and documents are removed too.")
            case .estimate: return mbLoc("Their line items are removed too.")
            case .changeOrder(let order) where order.appliedToInvoice:
                return mbLoc("Its items come off the invoice too.")
            case .job: return mbLoc("Its photos and documents are removed too.")
            case .project: return mbLoc("Its jobs are kept.")
            case .employee: return mbLoc("Their hours and paychecks are removed too.")
            case .subcontractor: return mbLoc("Their payment history is removed too.")
            case .paycheck: return mbLoc("The pay it covered goes back to owed.")
            default: return nil
            }
        }
    }

    // MARK: Plan and outcome

    /// What a delete would do — for a confirmation, before anything is touched.
    struct Plan: Equatable {
        /// The records that would be deleted, by kind. A record already inside another one's
        /// cascade (an invoice of a customer in the same batch) is not counted twice.
        let kinds: [Kind]
        /// Rows that go with them on the server (every root's cascade, summed).
        let cascadeRows: Int
        /// Plain-English description of what goes with them, one sentence per distinct effect.
        let summary: String
        /// The same effects, one per distinct kind and WITHOUT the "This can’t be undone." line —
        /// for a caller (the assistant) whose alert already says that itself.
        let effects: [String]
        /// More than 25 roots: the other devices will pause syncing until someone continues there.
        let tripsOtherDevicesBreaker: Bool

        var rootCount: Int { kinds.count }
    }

    struct Report: Equatable {
        let deleted: Int
        /// A change order's billed items couldn't be matched on its invoice, so they are still there.
        let itemsLeftOnInvoice: Bool
        let tripsOtherDevicesBreaker: Bool
    }

    enum Outcome: Equatable {
        case deleted(Report)
        /// Nothing was deleted: a change order's billed items couldn't be matched and the caller asked
        /// to stop there (the change order screen asks "Remove items by hand" first).
        case itemsUnmatched
    }

    /// The note for a batch that trips the breaker, for a confirmation that wants to say so.
    static var otherDevicesBreakerNote: String {
        mbLoc("Deleting more than 25 at once pauses syncing on your other devices until you continue there.")
    }

    // MARK: Entry points

    /// Runs every check a delete would, deletes nothing, and describes the result.
    static func plan(_ targets: [Target], origin: WriteOrigin = .tool, in context: ModelContext,
                     subscription: SubscriptionManager? = nil) throws -> Plan {
        let roots = try checked(targets, origin, in: context, subscription)
        let messages = roots.reduce(into: [String]()) { list, root in
            let message = root.target.cascadeDescription
            if !list.contains(message) { list.append(message) }
        }
        var summary = messages.count > 1
            ? messages.filter { $0 != mbLoc("This can’t be undone.") }.joined(separator: "\n")
            : messages.first ?? ""
        let breaker = roots.count > otherDevicesBreakerRoots
        if breaker { summary += (summary.isEmpty ? "" : "\n") + otherDevicesBreakerNote }
        let effects = roots.reduce(into: [String]()) { list, root in
            guard let effect = root.target.cascadeEffect, !list.contains(effect) else { return }
            list.append(effect)
        }
        return Plan(kinds: roots.map(\.target.kind),
                    cascadeRows: roots.reduce(0) { $0 + $1.cascadeRows },
                    summary: summary,
                    effects: effects,
                    tripsOtherDevicesBreaker: breaker)
    }

    /// Deletes `targets` after every check passes, then saves once. `evenIfItemsUnmatched: false`
    /// stops before deleting anything when a change order's billed items can't be matched on its
    /// invoice (any order already un-applied in the batch stays un-applied, and is saved so).
    @discardableResult
    static func delete(_ targets: [Target], evenIfItemsUnmatched: Bool = true, origin: WriteOrigin = .tool,
                       in context: ModelContext, subscription: SubscriptionManager? = nil) throws -> Outcome {
        let roots = try checked(targets, origin, in: context, subscription)
        guard !roots.isEmpty else {
            return .deleted(Report(deleted: 0, itemsLeftOnInvoice: false, tripsOtherDevicesBreaker: false))
        }
        let breaker = roots.count > otherDevicesBreakerRoots
        if breaker {
            Logger.domain.notice(
                "domain delete: \(roots.count, privacy: .public) roots — other devices' mass-delete breaker will trip")
        }

        // Change orders first: their billed items come off the invoice while the order still
        // exists. The cascade covers linked groups; a pre-link legacy apply needs this pass.
        var unmatched = false
        for root in roots {
            guard case .changeOrder(let order) = root.target else { continue }
            if !order.removeItemsFromInvoice(using: context) {
                unmatched = true
                if !evenIfItemsUnmatched {
                    context.saveChanges()
                    return .itemsUnmatched
                }
            }
        }

        for root in roots { remove(root.target, in: context) }
        context.saveChanges()
        return .deleted(Report(deleted: roots.count, itemsLeftOnInvoice: unmatched,
                               tripsOtherDevicesBreaker: breaker))
    }

    /// The record a tool names by kind and id. A payment is refused (append-only); an id that
    /// isn't there (or is being deleted) is `recordNotFound`.
    static func target(kind: Kind, id: UUID, in context: ModelContext) throws -> Target {
        func synced<T: PersistentModel>(_ key: String, _ type: T.Type) -> T? {
            guard let record = GLSyncRegistry.entry(for: key)?.fetch(id, context) as? T,
                  !record.isDeleted else { return nil }
            return record
        }
        let found: Target?
        switch kind {
        case .payment:
            throw DomainGate.refusal(.paymentsCannotBeDeleted, .deletePayment)
        case .customer: found = synced("customer", Customer.self).map(Target.customer)
        case .estimate: found = synced("estimate", Estimate.self).map(Target.estimate)
        case .contract:
            let descriptor = FetchDescriptor<Contract>(predicate: #Predicate { $0.syncID == id })
            found = ((try? context.fetch(descriptor)) ?? []).first { !$0.isDeleted }.map(Target.contract)
        case .invoice: found = synced("invoice", Invoice.self).map(Target.invoice)
        case .changeOrder: found = synced("change_order", ChangeOrder.self).map(Target.changeOrder)
        case .job: found = synced("scheduled_job", ScheduledJob.self).map(Target.job)
        case .receipt: found = synced("receipt", Receipt.self).map(Target.receipt)
        case .employee: found = synced("employee", Employee.self).map(Target.employee)
        case .subcontractor: found = synced("subcontractor", Subcontractor.self).map(Target.subcontractor)
        case .project: found = synced("project", Project.self).map(Target.project)
        case .timeEntry: found = synced("time_entry", TimeEntry.self).map(Target.timeEntry)
        case .paycheck: found = synced("paycheck", Paycheck.self).map(Target.paycheck)
        case .subPayment: found = synced("sub_payment", SubPayment.self).map(Target.subPayment)
        case .attachment: found = synced("job_attachment", JobAttachment.self).map(Target.attachment)
        case .document: found = synced("customer_document", CustomerDocument.self).map(Target.customerDocument)
        case .priceItem: found = synced("price_sheet_item", PriceSheetItem.self).map(Target.priceItem)
        }
        guard let found else { throw DomainGate.refusal(.recordNotFound, kind.operation) }
        return found
    }

    // MARK: Checks

    private struct Root {
        let target: Target
        /// Server rows its delete op(s) carry in `cascade`.
        let cascadeRows: Int
    }

    /// Every refusal, in the order a tap meets them, before anything is written. Returns the
    /// roots to delete: targets inside another target's cascade are dropped (they go with it).
    private static func checked(_ targets: [Target], _ origin: WriteOrigin, in context: ModelContext,
                                _ subscription: SubscriptionManager?) throws -> [Root] {
        var gated: Set<MBWriteOperation> = []
        for target in targets where gated.insert(target.operation).inserted {
            try DomainGate.requireWritable(target.operation, subscription)
        }
        for target in targets { try DomainGate.requireLive(target.model, target.operation) }
        for target in targets where isPaidLocked(target) {
            throw DomainGate.refusal(.paidLocked, target.operation)
        }
        // After the paid lock, so a paid invoice keeps its own answer (the server's order too).
        for target in targets where wouldTakeRecordedPayments(target) {
            let isCustomer: Bool
            if case .customer = target { isCustomer = true } else { isCustomer = false }
            throw DomainGate.refusal(.hasRecordedPayments(customer: isCustomer), target.operation)
        }

        var ops: [(target: Target, id: UUID?, subtrees: [[GLSyncChildRef]])] = []
        for target in targets {
            let subtrees = wireSubtrees(of: target, in: context)
            if origin == .tool, subtrees.contains(where: { $0.count > maxCascadeRows }) {
                throw DomainGate.refusal(.tooMuchToDelete, target.operation)
            }
            ops.append((target, target.syncRecord?.glSyncID, subtrees))
        }
        let covered = Set(ops.flatMap { $0.subtrees.flatMap { $0.map(\.id) } })
        var seen: Set<PersistentIdentifier> = []
        return ops.compactMap { op in
            if let id = op.id, covered.contains(id) { return nil }
            guard seen.insert(op.target.model.persistentModelID).inserted else { return nil }
            return Root(target: op.target, cascadeRows: op.subtrees.reduce(0) { $0 + $1.count })
        }
    }

    private static func isPaidLocked(_ target: Target) -> Bool {
        switch target {
        case .invoice(let invoice): return invoice.isMoneyLocked
        case .customer(let customer): return customer.hasPaidInvoice
        case .contract(let contract): return contract.balanceDue <= 0 && contract.amountPaid > 0
        case .changeOrder(let order): return order.isBilledToLockedInvoice
        default: return false
        }
    }

    /// True when deleting `target` would cascade a recorded payment away (law 60). Only an
    /// invoice and the customer above it hold invoices; every other kind keeps its payments
    /// out of reach (a job or project nullifies its invoices, a change order owns none).
    private static func wouldTakeRecordedPayments(_ target: Target) -> Bool {
        switch target {
        case .invoice(let invoice): return invoice.hasRecordedPayments
        case .customer(let customer): return customer.hasInvoiceWithPayments
        case .contract(let contract): return contract.amountPaid > 0
        default: return false
        }
    }

    /// The cascade of each delete op the target will queue: its own, plus — for an applied change
    /// order — its invoice group's, which rides as a separate op (GLSyncDeleteQueue).
    private static func wireSubtrees(of target: Target, in context: ModelContext) -> [[GLSyncChildRef]] {
        guard let record = target.syncRecord, let id = record.glSyncID else { return [] }
        var subtrees = [GLSyncDeleteQueue.subtree(of: record, recordID: id, in: context)]
        if case .changeOrder(let order) = target, let group = order.invoiceGroup, let groupID = group.syncID {
            subtrees.append(GLSyncDeleteQueue.subtree(of: group, recordID: groupID, in: context))
        }
        return subtrees
    }

    // MARK: The delete itself

    private static func remove(_ target: Target, in context: ModelContext) {
        // Already gone with an earlier root's cascade (SwiftData rules reach further than the
        // manifest's, e.g. an invoice's attachments): nothing left to do, and touching it traps.
        guard target.model.modelContext != nil, !target.model.isDeleted else { return }
        switch target {
        case .customer(let m): context.deleteSynced(m)
        case .estimate(let m): context.deleteSynced(m)
        case .contract(let m):
            if let job = m.scheduledJob {
                context.deleteSynced(job)
            }
            context.delete(m)   // GLSYNC-LINT-OK: Contract is local, not in GLSyncMappable manifest
        case .invoice(let m): context.deleteSynced(m)
        case .changeOrder(let m): context.deleteSynced(m)
        case .job(let m): context.deleteSynced(m)
        case .receipt(let m): context.deleteSynced(m)
        case .priceItem(let m): context.deleteSynced(m)
        case .employee(let m): context.deleteSynced(m)
        case .subcontractor(let m):
            // Their SSN/EIN lives in the Keychain, outside the store; it must not outlive them.
            m.clearSecureTIN()
            context.deleteSynced(m)
        case .project(let m): context.deleteSynced(m)
        case .timeEntry(let m): context.deleteSynced(m)
        case .paycheck(let m): context.deleteSynced(m)
        case .subPayment(let m): context.deleteSynced(m)
        case .attachment(let m): context.deleteSynced(m)
        case .customerDocument(let m): context.deleteSynced(m)
        }
    }
}

extension Invoice {
    /// True when any payment is recorded on this invoice — paid in full or not, and whatever its
    /// amount (a $0 or refund row is still a record). Payments are append-only (law 60), so an
    /// invoice holding one can't be deleted (`DeletionService`). Deliberately not `isMoneyLocked`:
    /// that lock stays "paid in full", so a partly paid invoice still takes line edits. The server
    /// asks the same question of its live `invoice_payment` rows (`hasRecordedPayments`).
    var hasRecordedPayments: Bool { !liveRows(payments).isEmpty }
}
