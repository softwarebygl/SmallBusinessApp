//
//  GLSyncHardeningTests.swift
//  GLSmallBusinessTests
//
//  The regression net for the seven data-integrity defects fixed before the sync client ever
//  reached TestFlight. Each test below FAILS against the code as it was written, and each one
//  names the damage in its own words — these are not shape assertions, they are the difference
//  between a contractor's books being right and being quietly wrong on every device but one.
//
//  Same house rules as GLSyncEngineTests.swift: every container comes from
//  `TestStore.makeContainer()` (retained for the process — project_swiftdata_test_process_trap),
//  fixtures are seeded and saved before the store is built, and read-back always goes through a
//  fresh `ModelContext`. `SyncFix` and `TS` are shared with that file rather than re-declared.
//
//  TWO of these are SOURCE SCANS, and deliberately so. "Every delete in the app routes through
//  the sync queue" and "every exit from a session stops the engine" are facts about call sites,
//  not about a value a function returns; the defects they pin were both *missing calls*, which
//  no amount of unit-testing the callee can catch. `GLSyncEngine` has no injection point for a
//  transport or a token (that gap is documented in GLSyncEngineTests.swift's header), so a scan
//  is the honest instrument, not a substitute for one. The scanner itself is the shared
//  `GLSource` (Harness/SourceScan.swift); `GLSyncSource` is its original name.
//

import Testing
import Foundation
import SwiftData
import GoldLifeCloud
@testable import GLSmallBusiness

// MARK: - 1. Cascading deletes (the negative-balance defect)

@MainActor
struct GLSyncCascadeDeleteTests {

    /// THE call-site rule. A bare `context.delete(record)` reaches the server as one
    /// INDEPENDENT delete op per row with no cascade: the Worker refuses `invoice_payment`
    /// (`append_only`) and refuses the parent (a live child it was never told about could be
    /// somebody's payment), so only the leaves are tombstoned — and every other device then
    /// shows an invoice with no line items and the original payments still attached.
    ///
    /// A line carrying `GLSYNC-LINT-OK` opts out, for the day a comment genuinely needs to
    /// write the words down.
    @Test func everyDeleteInTheAppRoutesThroughTheSyncQueue() {
        let receivers = ["modelContext.delete(", "context.delete(", "ctx.delete(",
                         "mainContext.delete(", "Context.delete("]
        let scanned = GLSyncSource.files(excludingDirectory: "Sync/")
        // Vacuity gate: a scan that reads nothing passes for the wrong reason.
        #expect(scanned.count > 50, "the app sources were not readable — this scan proves nothing")
        var offenders: [String] = []
        for file in scanned {
            for (number, line) in file.text.split(separator: "\n", omittingEmptySubsequences: false)
                .enumerated() where !line.contains("GLSYNC-LINT-OK") {
                guard receivers.contains(where: { line.contains($0) }) else { continue }
                offenders.append("\(file.path):\(number + 1) — \(line.trimmingCharacters(in: .whitespaces))")
            }
        }
        #expect(offenders.isEmpty, """
            \(offenders.count) delete site(s) bypass ModelContext.deleteSynced(_:). Each one \
            reaches the server as an independent per-row delete, which tombstones the line items \
            and leaves the invoice and its payments alive — a negative balance on a real \
            customer's books:
            \(offenders.joined(separator: "\n"))
            """)
    }

    /// The routed path reads the cascade off the LIVE object graph and then deletes. One op,
    /// carrying the whole subtree the Worker will verify.
    @Test func deleteSyncedQueuesTheWholeCascadeBeforeTheRowIsGone() throws {
        let container = try TestStore.makeContainer()
        let context = SyncFix.reader(container)
        let customer = Customer(firstName: "Routed", lastName: "Owner")
        let invoice = TS.invoice(number: "INV-9001", lines: [(100, false), (200, false)])
        invoice.customer = customer
        TS.pay(invoice, 40)
        context.insert(customer)
        context.insert(invoice)
        SyncFix.seed(context)

        let invoiceID = try #require(invoice.syncID)
        let customerID = try #require(customer.syncID)
        let groupID = try #require(invoice.groups?.first?.syncID)
        let lineIDs = Set((invoice.groups?.first?.lineItems ?? []).compactMap(\.syncID))
        let paymentID = try #require(invoice.payments?.first?.syncID)

        context.deleteSynced(invoice)
        context.saveChanges()

        let rows = SyncFix.outboxRows(container)
        #expect(rows.count == 1, "a routed delete must be ONE op, not one per row")
        let row = try #require(rows.first)
        #expect(row.isDelete)
        #expect(row.recordID == invoiceID)
        #expect(row.parentID == customerID)
        let cascade = Set(row.cascade)
        #expect(cascade.contains(groupID))
        #expect(cascade.isSuperset(of: lineIDs))
        #expect(cascade.contains(paymentID),
                "the payment is not named in the cascade — the Worker will refuse the whole delete")
        #expect(SyncFix.loadInvoice(invoiceID, in: container) == nil,
                "the record must actually be deleted, not merely queued")
    }

    /// SwiftData emits a tombstone for every cascaded row, so the fold sees the echo of a
    /// delete the routed path already shipped whole. Re-queuing those rows is the corruption
    /// again by another door.
    @Test func aTombstoneAlreadyNamedInAQueuedCascadeIsNotQueuedAgain() throws {
        let container = try TestStore.makeContainer()
        let context = SyncFix.reader(container)
        let invoice = TS.invoice(number: "INV-9002", lines: [(100, false)])
        context.insert(invoice)
        SyncFix.seed(context)
        let invoiceID = try #require(invoice.syncID)
        let groupID = try #require(invoice.groups?.first?.syncID)
        let lineID = try #require(invoice.groups?.first?.lineItems?.first?.syncID)

        let store = SyncFix.store(container)
        #expect(store.enqueueDelete(recordID: invoiceID, type: "invoice"))

        #expect(store.enqueueResolvedDelete(recordID: lineID, type: "invoice_line_item") == false)
        #expect(store.enqueueResolvedDelete(recordID: groupID, type: "invoice_group") == false)
        SyncFix.flush(store)

        #expect(SyncFix.outboxRows(container).count == 1,
                "the cascade's own rows were re-queued as independent deletes")
    }

    /// An `invoice_payment` has no delete of its own on the wire at all. Queuing one buys a
    /// guaranteed `refused: append_only` and parks a row for a record the person can no longer
    /// open to un-park.
    @Test func anAppendOnlyRecordIsNeverQueuedAsItsOwnDelete() throws {
        let container = try TestStore.makeContainer()
        let store = SyncFix.store(container)

        #expect(store.enqueueResolvedDelete(recordID: UUID(), type: "invoice_payment") == false)
        SyncFix.flush(store)
        #expect(SyncFix.outboxRows(container).isEmpty)
    }

    /// The fold fallback's ordering. Writes go parent-before-child (a child without its parent
    /// is `bad_parent`); DELETES go child-before-parent, because the Worker refuses to tombstone
    /// a row that still has a live child the op never named. Ship them parent-first and the
    /// leaves die while the parent is refused — exactly the half-deleted invoice this whole
    /// change exists to prevent.
    @Test func deletesAreOrderedLeafFirstWhileWritesStayParentFirst() throws {
        let container = try TestStore.makeContainer()
        let context = SyncFix.reader(container)
        let edit = UUID(), invoice = UUID(), group = UUID(), line = UUID()

        SyncFix.outbox(record: invoice, type: "invoice", isDelete: true,
                       dirtiedAt: SyncFix.firstDirtied, in: context)
        SyncFix.outbox(record: line, type: "invoice_line_item", isDelete: true,
                       dirtiedAt: SyncFix.firstDirtied.addingTimeInterval(1), in: context)
        SyncFix.outbox(record: group, type: "invoice_group", isDelete: true,
                       dirtiedAt: SyncFix.firstDirtied.addingTimeInterval(2), in: context)
        SyncFix.outbox(record: edit, type: "customer", fields: ["firstName": "Still here"],
                       dirtiedAt: SyncFix.firstDirtied.addingTimeInterval(3), in: context)

        let store = SyncFix.store(container)
        let ops = store.pendingOps(limit: 50)

        #expect(ops.map(\.recordID) == [edit, line, group, invoice], """
            push order was \(ops.map(\.recordType)) — a parent delete ahead of its children is \
            refused while the children die anyway, leaving an invoice with no line items and \
            its payments still attached
            """)
    }
}

// MARK: - 2. The mass-delete breaker (the permanently wedged device)

@MainActor
struct GLSyncBreakerHardeningTests {

    /// Deleting ONE large invoice on another device emits a tombstone per row. Counted per row
    /// that is 32 deletions against a threshold of 25 and the device stops; counted per cascade
    /// ROOT it is one decision a person made, and it goes through.
    @Test func aCascadeOfTombstonesCountsAsOneDeletionNotThirtyTwo() throws {
        let container = try TestStore.makeContainer()
        let context = SyncFix.reader(container)
        let invoice = TS.invoice(number: "INV-9100",
                                 lines: (0..<30).map { _ in (100.0, false) })
        context.insert(invoice)
        SyncFix.seed(context)

        let invoiceID = try #require(invoice.syncID)
        let groupID = try #require(invoice.groups?.first?.syncID)
        let lineIDs = (invoice.groups?.first?.lineItems ?? []).compactMap(\.syncID)
        #expect(lineIDs.count == 30)

        var page = [SyncFix.tombstone(invoiceID, type: "invoice", seq: 900)]
        page.append(SyncFix.tombstone(groupID, type: "invoice_group", seq: 901))
        page += lineIDs.enumerated().map { offset, id in
            SyncFix.tombstone(id, type: "invoice_line_item", seq: 902 + offset)
        }

        let store = SyncFix.store(container)
        let verdict = store.applyChanges(page)

        _ = try #require(SyncFix.outcome(verdict), """
            one deleted invoice tripped the breaker. That wedges the device: the pause used to \
            be in-memory, so a relaunch re-pulled the same page and tripped again, forever
            """)
        #expect(SyncFix.loadInvoice(invoiceID, in: container) == nil,
                "the page applied but the invoice is still here")
        #expect(store.persistedState().breaker == nil, "the breaker recorded a trip it never made")
    }

    /// A page of 26 UNRELATED roots is still refused — a breaker that never trips is as broken
    /// as one that always does.
    @Test func unrelatedRootsStillCountOneEachAndStillTrip() throws {
        let container = try TestStore.makeContainer()
        let ids = SyncFix.customers(30, in: SyncFix.reader(container), prefix: "Roots")

        let store = SyncFix.store(container)
        let refusal = try #require(SyncFix.refusal(
            store.applyChanges(SyncFix.tombstones(ids.prefix(26), from: 1000))))
        #expect(refusal.deletions == 26)
        #expect(SyncFix.customerCount(container) == 30)
    }

    /// The trip is written to disk. Without this the pause lived only in
    /// `GLSyncEngine.state`, so a relaunch reset to `.idle`, re-pulled the same page from the
    /// same un-advanced cursor, tripped again — forever, with no override and nothing on screen.
    @Test func aTrippedBreakerSurvivesARelaunch() throws {
        let container = try TestStore.makeContainer()
        let ids = SyncFix.customers(30, in: SyncFix.reader(container), prefix: "Persist")

        let store = SyncFix.store(container)
        #expect(SyncFix.refusal(store.applyChanges(SyncFix.tombstones(ids.prefix(26), from: 1100))) != nil)

        // A fresh store over the same container is what a relaunch looks like from here.
        let afterRelaunch = SyncFix.store(container)
        let trip = try #require(afterRelaunch.persistedState().breaker,
                                "the pause was forgotten on relaunch — the device re-pulls and re-trips forever")
        #expect(trip.deletions == 26)
        #expect(trip.threshold == 25)
    }

    /// The way out. "Yes, that was me" is an answer about ONE page, so the override is spent by
    /// the pull it lets through and a second surprise stops again.
    @Test func continuingAfterReviewLetsOnePageThroughAndThenReArms() throws {
        let container = try TestStore.makeContainer()
        let context = SyncFix.reader(container)
        let first = SyncFix.customers(30, in: context, prefix: "Wave1")
        let second = SyncFix.customers(30, in: context, prefix: "Wave2")

        let store = SyncFix.store(container)
        #expect(SyncFix.refusal(store.applyChanges(SyncFix.tombstones(first.prefix(26), from: 1200))) != nil)

        store.armBreakerOverride()
        #expect(store.persistedState().breaker == nil, "continuing must clear the pause")

        let outcome = try #require(SyncFix.outcome(
            store.applyChanges(SyncFix.tombstones(first.prefix(26), from: 1200))),
            "the page the person approved was refused anyway")
        #expect(outcome.deleted == 26)

        let refusal = try #require(SyncFix.refusal(
            store.applyChanges(SyncFix.tombstones(second.prefix(26), from: 1300))),
            "the override outlived the page it was for — a later mass delete now lands unseen")
        #expect(refusal.deletions == 26)
    }

    /// The sentence a person actually reads. It has to name the number and the next action;
    /// "Sync paused — something looked wrong." did neither.
    @Test func thePauseMessageNamesTheNumberAndWhatToDo() {
        let text = GLSyncEngine.pauseMessage(deletions: 212)
        #expect(text.contains("212"), "the message does not say how many: \(text)")
        #expect(text.localizedCaseInsensitiveContains("settings")
                || text.localizedCaseInsensitiveContains("ajustes"),
                "the message does not say where to go: \(text)")
    }
}

// MARK: - 3. A parked row must not freeze its record in both directions

@MainActor
struct GLSyncParkedRowTests {

    /// THE freeze. A parked row cannot push (that is what parking means) — so if it also blocks
    /// the pull, the cursor advances past the skipped row, the row is never offered again, and
    /// every later edit anyone makes to that customer on any other device silently never
    /// arrives. Permanently.
    @Test func aParkedRowDoesNotBlockThePull() throws {
        let container = try TestStore.makeContainer()
        let context = SyncFix.reader(container)
        let id = try #require(SyncFix.customers(1, in: context, prefix: "Frozen").first)
        let row = SyncFix.outbox(record: id, type: "customer",
                                 fields: ["firstName": "Refused value"], in: context)
        row.park("paid_locked")
        context.saveChanges()

        let store = SyncFix.store(container)
        let verdict = store.applyChanges([
            SyncFix.liveRow(id, type: "customer", version: 4, seq: 1400,
                            payload: ["firstName": "FromTheOtherPhone"])
        ])

        let outcome = try #require(SyncFix.outcome(verdict))
        #expect(outcome.applied == 1, """
            a parked record skipped the pull. It cannot push either, so this row is frozen in \
            both directions and every later edit from any other device is lost forever
            """)
        #expect(SyncFix.loadCustomer(id, in: container)?.firstName == "FromTheOtherPhone")
        let parked = try #require(SyncFix.outboxRow(id, in: container))
        #expect(parked.isParked, "the park itself must survive — it still holds the person's value")
        #expect(GLSyncValue.string(parked.fields, "firstName") == "Refused value",
                "the parked VALUE is what makes a side-by-side pick possible later")
    }

    /// The half that does not change: a parked row is still held back from the wire, because
    /// re-pushing it only repeats an argument the server has already settled.
    @Test func aParkedRowIsStillHeldBackFromThePush() throws {
        let container = try TestStore.makeContainer()
        let context = SyncFix.reader(container)
        let id = try #require(SyncFix.customers(1, in: context, prefix: "Held").first)
        let row = SyncFix.outbox(record: id, type: "customer",
                                 fields: ["firstName": "Held"], in: context)
        row.park("conflict")
        context.saveChanges()

        let store = SyncFix.store(container)
        #expect(store.pendingOps(limit: 50).isEmpty, "a parked row was queued for the wire")
    }

    /// An UNPARKED row still blocks the pull. This is the rule the whole layer exists for and
    /// widening the parked exception must not touch it.
    @Test func anUnsentEditStillBlocksThePull() throws {
        let container = try TestStore.makeContainer()
        let context = SyncFix.reader(container)
        let id = try #require(SyncFix.customers(1, in: context, prefix: "Unsent").first)
        SyncFix.outbox(record: id, type: "customer", fields: ["firstName": "Mine"], in: context)

        let store = SyncFix.store(container)
        let outcome = try #require(SyncFix.outcome(store.applyChanges([
            SyncFix.liveRow(id, type: "customer", version: 2, seq: 1500,
                            payload: ["firstName": "Server"])
        ])))
        #expect(outcome.skipped == 1)
        #expect(SyncFix.loadCustomer(id, in: container)?.firstName == "Unsent0")
    }

    /// The record is gone server-side, so a parked row for it can never push and can never be
    /// un-parked (that needs a fresh edit to a record nobody can open). It is swept with the row.
    @Test func aPulledTombstoneSweepsTheParkedRowForThatRecord() throws {
        let container = try TestStore.makeContainer()
        let context = SyncFix.reader(container)
        let id = try #require(SyncFix.customers(1, in: context, prefix: "Gone").first)
        let row = SyncFix.outbox(record: id, type: "customer",
                                 fields: ["firstName": "Contested"], in: context)
        row.park("conflict")
        context.saveChanges()

        let store = SyncFix.store(container)
        let outcome = try #require(SyncFix.outcome(
            store.applyChanges([SyncFix.tombstone(id, seq: 1600)])))
        #expect(outcome.deleted == 1)
        #expect(SyncFix.outboxRow(id, in: container) == nil,
                "a parked row outlived the record it belongs to")
    }
}

// MARK: - 4. A verdict must only ever land on the row it was about

@MainActor
struct GLSyncStaleRowVerdictTests {

    /// A fresh edit that lands WHILE the push is in flight re-mints the op id. The `.applied`
    /// branch already guarded on that; `.conflict` did not, so the new edit was parked on a
    /// verdict that was never about it — and a parked row never pushes again until something
    /// un-parks it.
    @Test func aConflictDoesNotParkAnEditThatLandedMidFlight() throws {
        let container = try TestStore.makeContainer()
        let context = SyncFix.reader(container)
        let id = UUID()
        let row = SyncFix.outbox(record: id, type: "invoice", base: 3,
                                 fields: ["taxRatePercent": 7.0], in: context)

        let store = SyncFix.store(container)
        let op = try #require(store.pendingOps(limit: 1).first)

        // …the person edits again while the request is on the wire. Through the app's own
        // context, which is where a real edit comes from, and re-read through a fresh store so
        // the assertion cannot be answered by a stale registered object.
        row.coalesce(["taxRatePercent": 8.25], parentID: nil)
        context.saveChanges()

        _ = SyncFix.store(container)
            .applyResults([op.opID: SyncFix.result(.conflict, version: 5)], for: [op])

        let saved = try #require(SyncFix.outboxRow(id, in: container))
        #expect(saved.isParked == false, """
            the newer edit was parked on a verdict about the older one. A parked row is held \
            back from every future push, so that edit never reaches the server at all
            """)
        #expect(GLSyncValue.double(saved.fields, "taxRatePercent") == 8.25)
        #expect(saved.isReadyToPush)
    }

    /// Same guard, `.refused` branch.
    @Test func aRefusalDoesNotParkAnEditThatLandedMidFlight() throws {
        let container = try TestStore.makeContainer()
        let context = SyncFix.reader(container)
        let id = UUID()
        let row = SyncFix.outbox(record: id, type: "invoice_line_item", base: 2,
                                 fields: ["unitPrice": 125.0], in: context)

        let store = SyncFix.store(container)
        let op = try #require(store.pendingOps(limit: 1).first)

        row.coalesce(["unitPrice": 150.0], parentID: nil)
        context.saveChanges()

        let outcome = SyncFix.store(container)
            .applyResults([op.opID: SyncFix.result(.refused, reason: .paidLocked)], for: [op])

        let saved = try #require(SyncFix.outboxRow(id, in: container))
        #expect(saved.isParked == false, "a refusal about the previous value froze the newer one")
        #expect(GLSyncValue.double(saved.fields, "unitPrice") == 150.0)
        #expect(outcome.messages.isEmpty == false,
                "the person's edit WAS refused — a newer edit does not make that untrue")
    }

    /// The unchanged half: when the row IS the one that was sent, a conflict still parks it.
    @Test func aConflictStillParksTheRowItWasAbout() throws {
        let container = try TestStore.makeContainer()
        let context = SyncFix.reader(container)
        let id = UUID()
        SyncFix.outbox(record: id, type: "invoice", base: 3,
                       fields: ["taxRatePercent": 7.0], in: context)

        let store = SyncFix.store(container)
        let op = try #require(store.pendingOps(limit: 1).first)
        let outcome = store.applyResults(
            [op.opID: SyncFix.result(.conflict, version: 5)], for: [op])

        #expect(outcome.parked == 1)
        #expect(SyncFix.outboxRow(id, in: container)?.parkReason == "conflict")
    }
}

// MARK: - 5. Last-writer-wins must mean last EDITOR, not last syncer

@MainActor
struct GLSyncEditTimeTests {

    /// `client_ts` is what the server's LWW compares (merge.ts §3.4). Stamping the whole chunk
    /// with push time hands every argument to whichever device syncs LAST: a note typed on
    /// Monday in a basement beats one typed on Tuesday, purely because Monday's phone surfaced
    /// on Wednesday.
    @Test func eachOpCarriesTheMomentItsOwnRecordWasEdited() throws {
        let container = try TestStore.makeContainer()
        let context = SyncFix.reader(container)
        let monday = UUID()
        let tuesday = UUID()
        let mondayAt = Date(timeIntervalSince1970: 1_700_000_000)
        let tuesdayAt = mondayAt.addingTimeInterval(86_400)

        SyncFix.outbox(record: monday, type: "customer", fields: ["notes": "Monday"],
                       dirtiedAt: mondayAt, in: context)
        SyncFix.outbox(record: tuesday, type: "customer", fields: ["notes": "Tuesday"],
                       dirtiedAt: tuesdayAt, in: context)

        let store = SyncFix.store(container)
        let ops = store.pendingOps(limit: 50)
        let stamps = Dictionary(uniqueKeysWithValues: ops.map { ($0.recordID, $0.clientTS) })

        #expect(stamps[monday] == Int(mondayAt.timeIntervalSince1970 * 1000),
                "the op did not carry the moment the person typed")
        #expect(stamps[tuesday] == Int(tuesdayAt.timeIntervalSince1970 * 1000))
        #expect(stamps[monday] != stamps[tuesday], """
            both ops carried the same timestamp — that is push time, so last-writer-wins is \
            decided by who found signal last instead of who edited last
            """)
    }

    /// The patch carries the LAST value of every field, so it has to be judged by the last edit
    /// time. A record dirtied at 09:00 and edited again at 17:00 that shipped 09:00 would lose
    /// its 5pm price to another device's noon one — the newer value, judged by the older clock.
    /// Push ORDER still keys on the first-dirtied stamp, which must not move.
    @Test func aLaterEditMovesTheEditTimeForwardButNotThePushOrder() throws {
        let container = try TestStore.makeContainer()
        let context = SyncFix.reader(container)
        let id = UUID()
        let nineAM = Date(timeIntervalSince1970: 1_700_000_000)
        let fivePM = nineAM.addingTimeInterval(8 * 3600)
        let row = SyncFix.outbox(record: id, type: "invoice_line_item", base: 2,
                                 fields: ["unitPrice": 100.0], dirtiedAt: nineAM, in: context)

        row.coalesce(["unitPrice": 175.0], parentID: nil, at: fivePM)
        context.saveChanges()

        let store = SyncFix.store(container)
        let op = try #require(store.pendingOps(limit: 1).first)
        #expect(op.clientTS == Int(fivePM.timeIntervalSince1970 * 1000), """
            the op shipped the 5pm price stamped 9am — it loses last-writer-wins to any device \
            that touched the same field in between
            """)
        #expect(SyncFix.outboxRow(id, in: container)?.firstDirtiedAt == nineAM,
                "push order must key on when the record FIRST went dirty, and that never moves")
    }

    /// A row materialised without an edit time reads `.distantPast`; sending that would lose
    /// every LWW tie for the life of the row. It degrades to push time instead.
    @Test func aRowWithNoRecordedEditTimeDegradesToPushTime() throws {
        let container = try TestStore.makeContainer()
        let context = SyncFix.reader(container)
        let id = UUID()
        SyncFix.outbox(record: id, type: "customer", fields: ["notes": "Ancient"],
                       dirtiedAt: .distantPast, in: context)

        let before = Int(Date().timeIntervalSince1970 * 1000)
        let store = SyncFix.store(container)
        let op = try #require(store.pendingOps(limit: 1).first)
        let after = Int(Date().timeIntervalSince1970 * 1000)

        #expect(op.clientTS >= before && op.clientTS <= after,
                "a distant-past edit time reached the wire and loses every tie forever")
    }
}

// MARK: - 6. A session that ends must stop the engine

@MainActor
struct GLSyncSessionTeardownTests {

    /// `GLSyncEngine.signedOut()` had exactly one caller repo-wide, and it was a test. Signing
    /// out left the engine running on a cached 15-minute app token and a cached document key:
    /// hand the phone to somebody who signs in with their own Gold Life ID inside that window
    /// and their invoices upload into the previous owner's account, and any W-9 is sealed with
    /// the previous owner's key — unreadable to them forever.
    @Test func everyExitFromASessionTearsDownTheSyncEngine() throws {
        let source = try #require(GLSyncSource.file("Services/GoldLifeAuth.swift"))
        for name in ["signOut", "handleSessionExpired", "deleteAccount"] {
            let body = try #require(GLSyncSource.functionBody(name, in: source),
                                    "GoldLifeAuth.\(name)() not found — did it move?")
            #expect(body.contains("stopSync()"), """
                GoldLifeAuth.\(name)() ends a session without stopping GLSync. The engine keeps \
                syncing under the PREVIOUS person's identity for the rest of the app token's \
                15-minute life
                """)
        }
        let teardown = try #require(GLSyncSource.functionBody("stopSync", in: source))
        #expect(teardown.contains("signedOut()"),
                "stopSync() does not reach GLSyncEngine.signedOut()")
    }

    /// None of the above is possible unless the engine is reachable from outside the sync
    /// layer. `attach` is the one place that can publish it, and it is not driveable from a test
    /// (it starts the real triggers and a real cycle), so this reads the wiring instead of
    /// pretending to exercise it.
    @Test func attachingTheEnginePublishesItForTeardown() throws {
        let source = try #require(GLSyncSource.file("Sync/GLSyncEngine.swift"))
        let body = try #require(GLSyncSource.functionBody("attach", in: source))
        #expect(body.contains("current = engine"),
                "GLSyncEngine.attach does not publish the engine — nothing outside Sync/ can stop it")
    }

    /// Signing out drops the pause banner with everything else — a stopped backup belonging to
    /// a session that no longer exists is not a thing to keep telling the next person about.
    @Test func signingOutClearsThePausedBanner() async throws {
        let container = try TestStore.makeContainer()
        let engine = GLSyncEngine(container: container)
        GLSyncStatus.shared.setPausedByMassDelete(
            GLSyncBreakerTrip(deletions: 99, threshold: 25, at: .now))
        #expect(GLSyncStatus.shared.pausedByMassDelete != nil)

        await engine.signedOut()

        let state = await engine.state
        #expect(GLSyncStatus.shared.pausedByMassDelete == nil)
        #expect(state == .signedOut)
        await engine.stop()
    }

    /// The binding key itself. `sub` is the canonical Gold Life ID the Worker partitions every
    /// record by, so reading it wrong would bind a cursor to the wrong account — the exact
    /// failure the binding exists to prevent.
    @Test func theAppTokensSubjectIsReadFromItsPayload() {
        // {"sub":"user-abc","aud":"gl-business"} — base64url, unpadded, as a real JWT arrives.
        let payload = Data(#"{"sub":"user-abc","aud":"gl-business"}"#.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        #expect(GLSyncTokenProvider.subject(ofJWT: "header.\(payload).signature") == "user-abc")
        #expect(GLSyncTokenProvider.subject(ofJWT: "not-a-jwt") == nil)
        #expect(GLSyncTokenProvider.subject(ofJWT: "a.!!!!.c") == nil)
    }
}

// MARK: - 7. The sync state belongs to ONE account

@MainActor
struct GLSyncAccountBindingTests {

    /// A store that has never synced adopts the first account that signs in, and keeps
    /// everything it already had — that is the migration, not a change of hands.
    @Test func theFirstAccountToSignInAdoptsTheStoreIntact() throws {
        let container = try TestStore.makeContainer()
        let context = SyncFix.reader(container)
        let id = try #require(SyncFix.customers(1, in: context, prefix: "Mine").first)
        SyncFix.outbox(record: id, type: "customer", fields: ["firstName": "Mine0"], in: context)

        let store = SyncFix.store(container)
        #expect(store.bind(owner: "user-a") == false, "a first binding is not a change of hands")

        let state = store.persistedState()
        #expect(state.ownerID == "user-a")
        #expect(state.suppressBootstrapUpload == false,
                "the first account must still upload the records already on this device")
        #expect(SyncFix.outboxRows(container).count == 1, "the person's unsent edit was thrown away")
    }

    /// The defect. `seq` is per-user, so an inherited cursor is a number from a DIFFERENT
    /// counter: the second person starts above their own account's entire history and pulls
    /// nothing, forever, while `bootstrapComplete` says there is nothing to catch up on.
    @Test func aDifferentAccountResetsTheCursorAndTheBookmark() throws {
        let container = try TestStore.makeContainer()
        let store = SyncFix.store(container)
        store.bind(owner: "user-a")
        store.advance(cursor: 8_421, historyToken: Data([1, 2, 3]))
        store.markBootstrapComplete(cursor: 8_421)
        let firstDevice = store.persistedState().deviceID

        #expect(store.bind(owner: "user-b"), "signing in as somebody else is a change of hands")

        let state = store.persistedState()
        #expect(state.ownerID == "user-b")
        #expect(state.cursor == 0, """
            the second account inherited a cursor of 8421 from a per-user counter that is not \
            theirs — they will never pull a single row of their own account
            """)
        #expect(state.historyToken == nil)
        #expect(state.bootstrapComplete == false)
        #expect(state.deviceID != firstDevice,
                "the LWW tie-break identity of the previous owner's device was reused")
    }

    /// The other half of the same harm: the records on this device are the FIRST person's, and
    /// one tap of "sign in" must not move somebody's books into somebody else's account.
    @Test func aStoreThatChangedHandsDoesNotUploadThePreviousOwnersRecords() throws {
        let container = try TestStore.makeContainer()
        let context = SyncFix.reader(container)
        let id = try #require(SyncFix.customers(1, in: context, prefix: "Theirs").first)
        SyncFix.outbox(record: id, type: "customer", fields: ["firstName": "Theirs0"], in: context)
        SyncFix.stampVersionRow(id, 4, in: context)

        let store = SyncFix.store(container)
        store.bind(owner: "user-a")
        #expect(store.bind(owner: "user-b"))

        #expect(store.persistedState().suppressBootstrapUpload, """
            the previous owner's records would be enqueued as creates and uploaded into the \
            account that just signed in
            """)
        #expect(SyncFix.outboxRows(container).isEmpty,
                "queued ops address the previous account's rows and must never be pushed")
        #expect(SyncFix.storedVersion(id, in: container) == nil,
                "version rows describe the previous account's server state")

        // Spent by the bootstrap it suppressed: a later self-heal must still be able to upload.
        store.markBootstrapComplete(cursor: 0)
        #expect(store.persistedState().suppressBootstrapUpload == false)
    }

    /// Re-binding the SAME account is a no-op. A cursor thrown away on every launch would make
    /// every device re-bootstrap forever.
    @Test func rebindingTheSameAccountChangesNothing() throws {
        let container = try TestStore.makeContainer()
        let store = SyncFix.store(container)
        store.bind(owner: "user-a")
        store.advance(cursor: 77, historyToken: Data([9]))

        #expect(store.bind(owner: "user-a") == false)
        #expect(store.persistedState().cursor == 77)
    }
}


// MARK: - 8. An engine that is done listens to nothing (QA 2026-10-03 F150)

/// Every sign-in attaches a NEW engine, and each one starts a path monitor and four
/// notification loops. They used to outlive the engine: the wipe only dropped its reference,
/// and the loops never checked whether their engine was still there, so a shared iPad
/// collected one monitor and a handful of parked tasks per sign-in all day long.
@MainActor
@Suite(.serialized)
struct GLSyncTriggerTeardownTests {

    /// An engine with no session (nothing reaches the network), its triggers started.
    private static func startedEngine() async throws -> GLSyncEngine {
        let container = try TestStore.makeContainer()
        let engine = GLSyncEngine(
            container: container,
            tokens: GLSyncTokenProvider(storedSessionJWT: { nil }, onSessionExpired: {}),
            cloud: .shared,
            documents: GLSyncDocumentCrypto(storedSessionJWT: { nil }, onSessionExpired: {}))
        await engine.begin()
        return engine
    }

    /// Whether every task has finished within `seconds`. A loop that never ends leaves its
    /// waiter parked, which is the failure being reported.
    private static func allEnd(_ tasks: [Task<Void, Never>], within seconds: Double) async -> Bool {
        let finished = FinishFlag()
        Task.detached {
            for task in tasks { await task.value }
            finished.set()
        }
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if finished.isSet { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return finished.isSet
    }

    @Test func stopEndsEveryTriggerLoopAndThePathMonitor() async throws {
        let engine = try await Self.startedEngine()
        let tasks = await engine.triggerTasks
        #expect(!tasks.isEmpty, "precondition: begin() starts the trigger loops")

        await engine.stop()

        #expect(await Self.allEnd(tasks, within: 5), "stop() left a trigger loop running")
        #expect(await engine.triggerTasks.isEmpty)
    }

    /// The loops hold their engine weakly, so nothing keeps it alive. When it goes, they go:
    /// none of them may sit parked on a notification that will never find an engine again.
    @Test func anEngineThatIsReleasedTakesItsTriggerLoopsWithIt() async throws {
        var engine: GLSyncEngine? = try await Self.startedEngine()
        let tasks = await engine?.triggerTasks ?? []
        #expect(!tasks.isEmpty, "precondition: begin() starts the trigger loops")
        weak let released = engine
        engine = nil
        #expect(released == nil, "precondition: nothing else holds the engine")

        #expect(await Self.allEnd(tasks, within: 5), """
            the trigger loops outlived their engine — every sign-in leaks a path monitor and \
            its notification loops
            """)
    }

    /// The session wipe (sign-out, a session Stytch ended) stops the engine it drops. Held
    /// strongly elsewhere — a cycle still finishing holds it — a dropped engine kept its
    /// monitor and loops for good.
    @Test func wipingTheLocalCopyStopsTheEngineItDrops() async throws {
        let key = UserScopedStore.pendingDefaultStoreWipeKey
        let saved = UserDefaults.standard.object(forKey: key)
        defer { UserDefaults.standard.set(saved, forKey: key) }
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("GLTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let engine = try await Self.startedEngine()
        let tasks = await engine.triggerTasks
        UserScopedStore.shared.activeEngine = engine

        UserScopedStore.shared.wipeLocalCopy(appSupport: root)

        #expect(UserScopedStore.shared.activeEngine == nil)
        #expect(await Self.allEnd(tasks, within: 5),
                "the wipe dropped the engine without stopping it — its monitor and loops live on")
    }

    /// Account deletion's wipe, the same rule.
    @Test func theAccountDeletionWipeStopsTheEngineItDrops() async throws {
        let key = UserScopedStore.pendingDefaultStoreWipeKey
        let saved = UserDefaults.standard.object(forKey: key)
        defer { UserDefaults.standard.set(saved, forKey: key) }
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("GLTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let engine = try await Self.startedEngine()
        let tasks = await engine.triggerTasks
        UserScopedStore.shared.activeEngine = engine

        UserScopedStore.shared.wipeOnAccountDeletion(appSupport: root)

        #expect(UserScopedStore.shared.activeEngine == nil)
        #expect(await Self.allEnd(tasks, within: 5),
                "the deletion wipe dropped the engine without stopping it")
    }
}

/// Set once from any thread, read from the test.
nonisolated final class FinishFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.lock(); value = true; lock.unlock() }
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
}
