//
//  RowReconcilerTests.swift
//  GLSmallBusinessTests
//
//  The in-place save for a document's child rows (Models/RowReconciler.swift). The
//  delete-everything-and-rebuild save it replaces was the root of the deleted-model render
//  crashes, turned one edit into N delete + N create sync ops, made a paid invoice
//  un-editable (paid_locked), and broke every other device's references to the rows.
//
//  Six claims, every one on real SwiftData rows in a real container:
//   (1) untouched drafts hand back the very same rows — identity, persistentModelID,
//       syncID — and leave the context CLEAN: no change means no history row and no
//       outbox op;
//   (2) a dropped draft deletes exactly its row and nothing else;
//   (3) a new draft lands at its draft position, and a reorder rewrites sortIndex only;
//   (4) a row deleted under the form (a sync pull) is neither read nor resurrected — its
//       draft inserts a fresh row, and the dead one is never touched;
//   (5) groups nest: the group update closure reconciles that group's lines;
//   (6) setIfChanged leaves an equal value untouched and writes a different one.
//
//  Drafts are built AFTER the setup save: a temporary persistentModelID becomes a permanent
//  one on the first save, and the form only ever sees saved rows.
//
//  Those six claims pin the RECONCILER. They cannot pin the three forms that call it, whose
//  save() bodies are private and whose whole safety rests on five one-line assignments and five
//  delete closures. `FormRowIdentityWiringTests` at the bottom of this file is the source scan
//  that pins those call sites — the same instrument, and for the same reason, as
//  LiveRowsTests.everyRelationshipReadGoesThroughLiveRows and
//  GLSyncCascadeDeleteTests.everyDeleteInTheAppRoutesThroughTheSyncQueue (GLSyncHardeningTests.swift).
//

import Testing
import Foundation
import SwiftData
@testable import GLSmallBusiness

/// What a form's line draft carries into `save()`: the fields, plus the saved row's identity
/// (nil for a line typed into the form).
@MainActor
private struct LineDraft {
    var name: String
    var unitPrice: Double
    var modelID: PersistentIdentifier?

    init(name: String, unitPrice: Double, modelID: PersistentIdentifier? = nil) {
        self.name = name
        self.unitPrice = unitPrice
        self.modelID = modelID
    }

    init(from item: EstimateLineItem) {
        self.init(name: item.name, unitPrice: item.unitPrice, modelID: item.persistentModelID)
    }
}

/// The group half of the same shape: its own identity plus its lines, in order.
@MainActor
private struct GroupDraft {
    var name: String
    var lines: [LineDraft]
    var modelID: PersistentIdentifier?

    init(name: String, lines: [LineDraft], modelID: PersistentIdentifier? = nil) {
        self.name = name
        self.lines = lines
        self.modelID = modelID
    }

    init(from group: EstimateGroup) {
        self.init(name: group.name,
                  lines: group.sortedLineItems.map(LineDraft.init(from:)),
                  modelID: group.persistentModelID)
    }
}

@MainActor
struct RowReconcilerTests {

    // MARK: - Fixtures

    /// A saved estimate with one group of `lines`: syncIDs minted by `saveChanges`, identifiers
    /// permanent, context clean.
    private func savedEstimate(
        lines: [(Double, Bool)] = [(1000, false), (500, false), (250, false)]
    ) throws -> (context: ModelContext, estimate: Estimate, group: EstimateGroup) {
        let container = try TestStore.makeContainer()
        let context = container.mainContext
        let estimate = TS.estimate(number: "EST-RR-0001", lines: lines, in: context)
        context.saveChanges()
        let group = try #require(estimate.sortedGroups.first)
        return (context, estimate, group)
    }

    /// The line half of a form's save, wired exactly as the forms wire it: the inverse set
    /// BEFORE insert, every write through `setIfChanged`, removals through `deleteSynced`.
    /// `deleted` is what the reconciler handed to `delete`, so a test can assert on it.
    private func reconcileLines(
        of group: EstimateGroup, drafts: [LineDraft], in context: ModelContext
    ) -> (rows: [EstimateLineItem], deleted: [EstimateLineItem]) {
        var deleted: [EstimateLineItem] = []
        let rows = RowReconciler.reconcile(
            existing: group.liveRows(group.lineItems), drafts: drafts,
            modelID: { $0.modelID },
            make: { draft in
                let item = EstimateLineItem(name: draft.name, quantity: 1, unit: .job,
                                            unitPrice: draft.unitPrice)
                item.group = group
                context.insert(item)
                return item
            },
            update: { item, draft, index in
                setIfChanged(item, \.name, draft.name)
                setIfChanged(item, \.unitPrice, draft.unitPrice)
                setIfChanged(item, \.sortIndex, index)
            },
            delete: { item in
                deleted.append(item)
                context.deleteSynced(item)
            })
        return (rows, deleted)
    }

    // MARK: - (1) identity

    @Test func untouchedRowsKeepTheirIdentity() throws {
        let (context, _, group) = try savedEstimate()
        let before = group.sortedLineItems
        let ids = before.map(\.persistentModelID)
        let syncIDs = before.map(\.syncID)
        #expect(before.count == 3)
        #expect(syncIDs.allSatisfy { $0 != nil }, "saveChanges mints syncIDs — without them the claim below is empty")
        #expect(!context.hasChanges)

        let result = reconcileLines(of: group, drafts: before.map(LineDraft.init(from:)), in: context)

        #expect(result.rows.count == 3)
        #expect(zip(result.rows, before).allSatisfy { $0 === $1 },
                "an untouched draft must hand back the very row it came from")
        #expect(result.rows.map(\.persistentModelID) == ids)
        #expect(result.rows.map(\.syncID) == syncIDs)
        #expect(result.deleted.isEmpty)
        #expect(!context.hasChanges,
                "an untouched row must produce no SwiftData change — no history row, no outbox op")
        #expect(context.insertedModelsArray.isEmpty)
        #expect(context.changedModelsArray.isEmpty)
        #expect(context.deletedModelsArray.isEmpty)
    }

    // MARK: - (2) removal

    @Test func removedDraftsDeleteOnlyTheirRows() throws {
        let (context, _, group) = try savedEstimate()
        let before = group.sortedLineItems
        let (first, middle, last) = (before[0], before[1], before[2])

        let result = reconcileLines(of: group, drafts: [LineDraft(from: first), LineDraft(from: last)],
                                    in: context)

        #expect(result.deleted.count == 1)
        #expect(result.deleted.first === middle)
        #expect(result.rows.count == 2)
        #expect(result.rows[0] === first)
        #expect(result.rows[1] === last)
        #expect(middle.isDeleted, "the dropped row went through deleteSynced")
        #expect(!first.isDeleted && !last.isDeleted)
        #expect(first.name == "Line 0" && last.name == "Line 2")
        #expect(first.sortIndex == 0)
        #expect(last.sortIndex == 1, "the kept rows close the gap")

        context.saveChanges()
        // Only `modelContext` is read on the dead row from here on — anything else can trap.
        #expect(middle.modelContext == nil)
        #expect(group.sortedLineItems.count == 2)
        #expect(group.sortedLineItems[0] === first)
        #expect(group.sortedLineItems[1] === last)
        #expect(close(group.subtotal, 1250))
    }

    // MARK: - (3) order

    @Test func newDraftsInsertInDraftOrder() throws {
        let (context, _, group) = try savedEstimate(lines: [(1000, false), (500, false)])
        let before = group.sortedLineItems
        let (a, b) = (before[0], before[1])
        let (aID, bID) = (a.persistentModelID, b.persistentModelID)

        // A pure reorder: the same two rows swap sortIndex and nothing else moves.
        let reordered = reconcileLines(of: group, drafts: [LineDraft(from: b), LineDraft(from: a)],
                                       in: context)
        #expect(reordered.rows.count == 2)
        #expect(reordered.rows[0] === b && reordered.rows[1] === a)
        #expect(reordered.deleted.isEmpty)
        #expect(context.insertedModelsArray.isEmpty, "a reorder inserts nothing")
        #expect(context.deletedModelsArray.isEmpty, "a reorder deletes nothing")
        #expect(b.sortIndex == 0 && a.sortIndex == 1)
        #expect(a.name == "Line 0" && b.name == "Line 1")
        #expect(close(a.unitPrice, 1000) && close(b.unitPrice, 500))
        #expect(a.persistentModelID == aID && b.persistentModelID == bID)
        context.saveChanges()
        #expect(group.sortedLineItems.map(\.name) == ["Line 1", "Line 0"])

        // A new draft between them lands at its draft position; the existing rows renumber.
        let drafts = [LineDraft(from: b), LineDraft(name: "Grout", unitPrice: 200), LineDraft(from: a)]
        let inserted = reconcileLines(of: group, drafts: drafts, in: context)
        #expect(inserted.rows.count == 3)
        #expect(inserted.deleted.isEmpty)
        #expect(inserted.rows[0] === b)
        #expect(inserted.rows[2] === a)
        let fresh = inserted.rows[1]
        #expect(fresh !== a && fresh !== b)
        #expect(fresh.name == "Grout" && close(fresh.unitPrice, 200))
        #expect(fresh.group === group, "the inverse is set before insert, as the forms do")
        #expect(fresh.modelContext === context)
        #expect(context.insertedModelsArray.count == 1)
        #expect(context.insertedModelsArray.first === fresh)
        #expect(inserted.rows.map(\.sortIndex) == [0, 1, 2])
        context.saveChanges()
        #expect(fresh.syncID != nil, "a fresh row gets its sync identity on the save")
        #expect(group.sortedLineItems.map(\.name) == ["Line 1", "Grout", "Line 0"])
        #expect(group.sortedLineItems[1] === fresh)
        #expect(close(group.subtotal, 1700))
    }

    // MARK: - (4) deleted under the form

    @Test func aRowDeletedUnderTheFormIsNotResurrectedOrRead() throws {
        let (context, _, group) = try savedEstimate()
        let before = group.sortedLineItems
        let (first, doomed, last) = (before[0], before[1], before[2])
        // The form opened on all three rows...
        let drafts = before.map(LineDraft.init(from:))
        let doomedID = doomed.persistentModelID
        // ...then a sync pull deleted the middle one and committed. Only `modelContext` is read
        // on the dead row from here on — anything else on a committed-deleted @Model can trap.
        context.delete(doomed)
        context.saveChanges()
        #expect(doomed.modelContext == nil)
        #expect(group.liveRows(group.lineItems).count == 2,
                "the dead row is out of `existing` before the reconcile — that is the whole fence")

        let result = reconcileLines(of: group, drafts: drafts, in: context)

        #expect(result.deleted.isEmpty, "nothing live was dropped")
        #expect(result.rows.count == 3)
        #expect(result.rows[0] === first && result.rows[2] === last)
        let fresh = result.rows[1]
        #expect(fresh !== doomed, "the dead row must not come back")
        #expect(fresh.persistentModelID != doomedID)
        #expect(fresh.modelContext === context)
        #expect(fresh.name == "Line 1" && close(fresh.unitPrice, 500))
        #expect(result.rows.map(\.sortIndex) == [0, 1, 2])
        context.saveChanges()
        #expect(group.sortedLineItems.map(\.name) == ["Line 0", "Line 1", "Line 2"])
        #expect(group.sortedLineItems[1] === fresh)
        #expect(close(group.subtotal, 1750))
    }

    // MARK: - (5) nesting

    @Test func nestedReconcileHandlesGroupsAndLines() throws {
        let container = try TestStore.makeContainer()
        let context = container.mainContext
        let estimate = TS.twoGroupEstimate(number: "EST-RR-0005", in: context)
        context.saveChanges()
        let work = try #require(estimate.sortedGroups.first)      // "Work": Line 0 @ 1000
        let extras = try #require(estimate.sortedGroups.last)     // "Extras": Line 0 @ 250
        let workLine = try #require(work.sortedLineItems.first)
        let extrasLine = try #require(extras.sortedLineItems.first)

        // The person moves Extras above Work, renames Work's line and adds one, swaps Extras'
        // only line for a new one, and adds a third group.
        var extrasDraft = GroupDraft(from: extras)
        extrasDraft.lines = [LineDraft(name: "Demo", unitPrice: 300)]
        var workDraft = GroupDraft(from: work)
        workDraft.lines[0].name = "Tile"
        workDraft.lines.append(LineDraft(name: "Grout", unitPrice: 200))
        let cleanupDraft = GroupDraft(name: "Cleanup", lines: [LineDraft(name: "Haul-off", unitPrice: 50)])

        var deletedGroups: [EstimateGroup] = []
        var deletedLines: [EstimateLineItem] = []
        let groups = RowReconciler.reconcile(
            existing: estimate.liveRows(estimate.groups),
            drafts: [extrasDraft, workDraft, cleanupDraft],
            modelID: { $0.modelID },
            make: { draft in
                let group = EstimateGroup(name: draft.name)
                group.estimate = estimate
                context.insert(group)
                return group
            },
            update: { group, draft, index in
                setIfChanged(group, \.name, draft.name)
                setIfChanged(group, \.sortIndex, index)
                deletedLines += reconcileLines(of: group, drafts: draft.lines, in: context).deleted
            },
            delete: { group in
                deletedGroups.append(group)
                context.deleteSynced(group)
            })

        #expect(groups.count == 3)
        #expect(groups[0] === extras && groups[1] === work)
        let cleanup = groups[2]
        #expect(cleanup !== extras && cleanup !== work)
        #expect(deletedGroups.isEmpty)
        #expect(deletedLines.count == 1)
        #expect(deletedLines.first === extrasLine)
        context.saveChanges()

        // The tree, read back the way every screen reads it.
        let sorted = estimate.sortedGroups
        #expect(sorted.map(\.name) == ["Extras", "Work", "Cleanup"])
        #expect(sorted.count == 3 && sorted[0] === extras && sorted[1] === work && sorted[2] === cleanup)
        #expect(sorted.map(\.sortIndex) == [0, 1, 2])
        #expect(extras.sortedLineItems.map(\.name) == ["Demo"])
        #expect(extrasLine.modelContext == nil, "the swapped-out line is gone")
        #expect(work.sortedLineItems.map(\.name) == ["Tile", "Grout"])
        #expect(work.sortedLineItems.first === workLine, "a renamed line keeps its row")
        #expect(work.sortedLineItems.map(\.sortIndex) == [0, 1])
        #expect(cleanup.sortedLineItems.map(\.name) == ["Haul-off"])
        #expect(cleanup.sortedLineItems.first?.group === cleanup)
        #expect(cleanup.estimate === estimate)
        #expect(estimate.allLineItems.count == 4)
        #expect(close(estimate.total, 1550))
        #expect(sorted.allSatisfy { $0.syncID != nil })
        #expect(estimate.allLineItems.allSatisfy { $0.syncID != nil })
    }

    // MARK: - (6) setIfChanged

    @Test func setIfChangedLeavesEqualValuesUntouched() throws {
        let (context, _, group) = try savedEstimate(lines: [(1000, false)])
        let item = try #require(group.sortedLineItems.first)
        #expect(!context.hasChanges)

        setIfChanged(item, \.name, item.name)      // String
        setIfChanged(item, \.unitPrice, 1000)      // Double
        setIfChanged(item, \.unit, .job)           // enum — the fixture's unit
        setIfChanged(item, \.isTaxable, false)     // Bool
        #expect(!context.hasChanges, "an equal value must not touch the row")
        #expect(context.changedModelsArray.isEmpty)

        setIfChanged(item, \.name, "Porcelain tile")
        #expect(context.hasChanges)
        #expect(item.name == "Porcelain tile")
        #expect(context.changedModelsArray.count == 1)
        #expect(context.changedModelsArray.first === item)

        context.saveChanges()
        #expect(!context.hasChanges)
        setIfChanged(item, \.name, "Porcelain tile")
        #expect(!context.hasChanges, "equal stays untouched after a save too")
    }

    // MARK: - (7) Wrapper and Status Mapping (C30 / Law 87)

    @Test func editingOneLineThroughWrapperProducesOneChange() throws {
        let (context, estimate, group) = try savedEstimate()
        let line = try #require(group.sortedLineItems.first)
        context.saveChanges()
        #expect(!context.hasChanges)

        var draft = EstimateDraft(estimate)
        draft.groups[0].lines[0].unitPrice = 1200.0

        try EstimateService.update(estimate, with: draft, origin: .screen, in: context)

        #expect(line.unitPrice == 1200.0)
        #expect(estimate.sortedGroups[0].sortedLineItems[0].unitPrice == 1200.0)
    }

    @Test func everyEstimateStatusMapsToPackageAndBack() {
        for status in EstimateStatus.allCases {
            let pkgStatus = status.documentStatus
            let roundTripped = EstimateStatus.from(documentStatus: pkgStatus, wasSent: status == .sent)
            #expect(roundTripped == status, "Status \(status) did not round-trip via package status \(pkgStatus)")
        }
    }
}

// MARK: - The wiring the reconciler is useless without

/// `RowReconciler` is only half the fix; the other half is five one-line assignments and five
/// delete closures spread across the three document drafts and their three services (the forms'
/// save bodies moved into Services/Domain on 2026-09-22 so the assistant runs the same code), and
/// NOTHING above observes them. The domain tests exercise the saves; these scans pin the wiring. Delete the single line
/// `modelID = item.persistentModelID` from EstimateFormScreen's `LineItemDraft.init(from:)` and
/// the tree still compiles with zero warnings, all six tests above still pass, and every estimate
/// edit silently reverts to delete-and-rebuild for its LINE ITEMS: dead-row render crashes,
/// N delete + N create sync ops per edit, and a lost syncID on every other device that
/// referenced those rows. (The groups survive — their draft still carries an identity — which is
/// exactly why the damage is so easy to miss by hand.)
///
/// Three facts about CALL SITES, which are exactly the defects no amount of unit-testing the
/// callee can catch — the reason LiveRowsTests.everyRelationshipReadGoesThroughLiveRows and
/// GLSyncCascadeDeleteTests.everyDeleteInTheAppRoutesThroughTheSyncQueue
/// (GLSyncHardeningTests.swift) are scans too:
///
///  1. a draft opened from a saved row of its OWN document carries that row's
///     `persistentModelID`, so the reconciler can match it and update in place;
///  2. a draft COPIED from another document's row (an estimate carried onto a new invoice) does
///     NOT carry an identity — if it did, saving the invoice would reach across and rewrite the
///     estimate's own line items;
///  3. no form deletes a row by name any more: every row delete left in those files is the
///     reconciler's `delete:` closure, and every `reconcile` call has exactly one.
///
/// Each scan is a pure function over source text, self-tested on a probe first — a scan that
/// matches nothing passes for the wrong reason.
struct FormRowIdentityWiringTests {

    /// Where the drafts live (their `init(from …)` identities), app-target-relative.
    private static let formPaths = [
        "Services/Domain/EstimateDraft.swift",
        "Services/Domain/InvoiceDraft.swift",
        "Services/Domain/ChangeOrderDraft.swift",
    ]

    /// Where the saves live (their reconcile calls and row deletes), app-target-relative.
    private static let savePaths = [
        "Services/Domain/EstimateService.swift",
        "Services/Domain/InvoiceService.swift",
        "Services/Domain/ChangeOrderService.swift",
    ]

    /// The routed delete closure every reconcile call in the services hands over.
    private static let routedDelete = "delete: { context.deleteSynced($0) })"

    /// Every `init(from …)` in those files, and whether it must claim the source row's identity.
    ///
    /// `true` — the draft EDITS that very row, so `save()` must find and update it in place.
    /// `false` — the draft is a COPY onto a different document; claiming the source's identity
    /// would make saving this document rewrite the other one's rows.
    ///
    /// Every init found in those files must appear here, so a new converter cannot be added
    /// without someone deciding which kind it is.
    private static let identityContract: [String: [String: Bool]] = [
        "Services/Domain/EstimateDraft.swift": [
            "init(from item: EstimateLineItem)": true,      // EstimateLineDraft — this estimate's line
            "init(from group: EstimateGroup)": true,        // EstimateGroupDraft — this estimate's group
        ],
        "Services/Domain/InvoiceDraft.swift": [
            "init(from item: InvoiceLineItem)": true,       // InvoiceLineDraft — this invoice's line
            "init(from group: InvoiceGroup)": true,         // InvoiceGroupDraft — this invoice's group
            "init(from item: EstimateLineItem)": false,     // carried from an estimate — a NEW row here
            "init(from group: EstimateGroup)": false,       // carried from an estimate — a NEW row here
        ],
        "Services/Domain/ChangeOrderDraft.swift": [
            "init(from item: ChangeOrderLineItem)": true,   // ChangeOrderLineDraft — this change order's line
        ],
    ]

    /// A `deleteSynced(x)` whose argument is one of these deletes a whole DOCUMENT, not a row of
    /// the document being edited; its children go with it through the sync cascade. Whole-record
    /// deletes live in DeletionService (not a scanned file); this stays so a scanned file that ever
    /// deletes a whole change order is not mistaken for a hand-rolled row delete.
    private static let documentDeletes: Set<String> = ["changeOrder"]

    // MARK: - Reading the source

    /// Every `init(from …)` declaration in `text`, as its whitespace-collapsed signature and its
    /// brace-balanced body. A doc comment writes `init(from:)` with no space after `from`, so the
    /// search string steps over it, and a match whose signature runs past its own line is skipped.
    private static func draftInits(in text: String) -> [(signature: String, body: String)] {
        var out: [(signature: String, body: String)] = []
        var cursor = text.startIndex
        while let start = text.range(of: "init(from ", range: cursor..<text.endIndex) {
            cursor = start.upperBound
            guard let close = text.range(of: ") {", range: start.upperBound..<text.endIndex) else { continue }
            let raw = String(text[start.lowerBound..<close.lowerBound]) + ")"
            guard !raw.contains("\n") else { continue }
            let signature = raw.split(whereSeparator: \.isWhitespace).joined(separator: " ")

            let open = text.index(before: close.upperBound)      // the `{`
            var depth = 0
            var index = open
            var body: String?
            while index < text.endIndex {
                let character = text[index]
                if character == "{" { depth += 1 }
                if character == "}" {
                    depth -= 1
                    if depth == 0 {
                        body = String(text[text.index(after: open)..<index])
                        break
                    }
                }
                index = text.index(after: index)
            }
            guard let body else { continue }
            out.append((signature, body))
            cursor = index
        }
        return out
    }

    /// Every way a form's draft inits can break the in-place save: an own-row init that stopped
    /// claiming its row, a cross-document copy that started claiming one, and an init nobody
    /// classified (which is the first two hiding).
    static func identityOffenders(in files: [(path: String, text: String)],
                                  contract: [String: [String: Bool]]) -> [String] {
        var offenders: [String] = []
        for (path, expectations) in contract.sorted(by: { $0.key < $1.key }) {
            guard let text = files.first(where: { $0.path == path })?.text else {
                offenders.append("\(path) — not found; this scan read nothing for it")
                continue
            }
            let found = Self.draftInits(in: text)

            for (signature, body) in found {
                guard let mustClaim = expectations[signature] else {
                    offenders.append("""
                        \(path) — `\(signature)` is not in identityContract. Decide which it is: \
                        a draft that EDITS that row (assign `modelID = …persistentModelID`, map to \
                        `true`) or a COPY onto another document (assign nothing, map to `false`).
                        """)
                    continue
                }
                // `init(from item:` → `item`; `init(from group:` → `group`.
                let binding = signature.dropFirst("init(from ".count).prefix { $0 != ":" }
                if mustClaim {
                    let assignment = "modelID = \(binding).persistentModelID"
                    if !body.contains(assignment) {
                        offenders.append("""
                            \(path) — `\(signature)` does not assign `\(assignment)`. Without it \
                            every draft matches nothing, so save() deletes and re-creates every \
                            row: dead-row render crashes, N delete + N create sync ops, lost syncIDs.
                            """)
                    }
                } else if body.contains("persistentModelID") {
                    offenders.append("""
                        \(path) — `\(signature)` copies a row from ANOTHER document and must not \
                        take its identity; saving this document would rewrite the source's rows.
                        """)
                }
            }

            let missing = Set(expectations.keys).subtracting(found.map(\.signature))
            for signature in missing.sorted() {
                offenders.append("""
                    \(path) — `\(signature)` is in identityContract but no longer in the file. \
                    Update the contract if it was renamed or removed on purpose.
                    """)
            }
        }
        return offenders
    }

    /// Every `deleteSynced(` in `files` whose argument is neither the reconciler's closure
    /// parameter nor an allow-listed whole-document delete.
    static func rowDeleteOffenders(in files: [(path: String, text: String)]) -> [String] {
        var offenders: [String] = []
        for file in files {
            for (number, line) in file.text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                var rest = line
                while let call = rest.range(of: "deleteSynced(") {
                    let after = rest[call.upperBound...]
                    let argument = String(after.prefix { $0 != ")" })
                    rest = after
                    if argument == "$0" { continue }                        // the reconciler's delete closure
                    if Self.documentDeletes.contains(argument) { continue }  // a whole document, not a row
                    offenders.append("""
                        \(file.path):\(number + 1): `deleteSynced(\(argument))` deletes a named row \
                        directly. Row removal belongs to RowReconciler's `delete:` closure; a hand-rolled \
                        delete here is the delete-and-rebuild bug class coming back: \
                        \(line.trimmingCharacters(in: .whitespaces))
                        """)
                }
            }
        }
        return offenders
    }

    // MARK: - The scanners have to catch the thing they exist to catch

    /// A dropped assignment, a stolen identity, and an unclassified init — on a probe, so the
    /// clean scan of the real forms below means something.
    @Test func theIdentityScanCatchesEveryWayTheWiringBreaks() {
        let probe = """
        struct D {
            /// Set ONLY by `init(from:)`.
            var modelID: PersistentIdentifier? = nil
            init(from item: LineItem) {
                modelID = item.persistentModelID
                name = item.name
            }
            init(from group: Group) {
                name = group.name
                lines = group.lines.map { LineItemDraft(from: $0) }
            }
            init(from item: OtherLineItem) {
                name = item.name
            }
            init(from item: StolenLineItem) {
                modelID = item.persistentModelID
            }
            init(from item: UnclassifiedLineItem) {
                name = item.name
            }
        }
        """
        let contract = ["Probe.swift": [
            "init(from item: LineItem)": true,          // correct — claims its row
            "init(from group: Group)": true,            // BROKEN — the assignment was deleted
            "init(from item: OtherLineItem)": false,    // correct — a copy, claims nothing
            "init(from item: StolenLineItem)": false,   // BROKEN — a copy that took the identity
            "init(from item: GoneLineItem)": true,      // BROKEN — contracted but not in the file
        ]]
        let caught = Self.identityOffenders(in: [(path: "Probe.swift", text: probe)], contract: contract)

        #expect(caught.count == 4, "expected exactly four offenders, got:\n\(caught.joined(separator: "\n"))")
        #expect(caught.contains { $0.contains("`init(from group: Group)`") && $0.contains("does not assign") },
                "a deleted `modelID = group.persistentModelID` was missed — the whole point of this scan")
        #expect(caught.contains { $0.contains("`init(from item: StolenLineItem)`") && $0.contains("must not") },
                "a cross-document copy taking the source row's identity was missed")
        #expect(caught.contains { $0.contains("`init(from item: UnclassifiedLineItem)`") },
                "an init nobody classified was missed")
        #expect(caught.contains { $0.contains("`init(from item: GoneLineItem)`") },
                "a contract entry with no init left in the file was missed")
        #expect(!caught.contains { $0.contains("`init(from item: LineItem)`") },
                "the correctly-wired init was flagged")
        #expect(!caught.contains { $0.contains("`init(from item: OtherLineItem)`") },
                "the correct cross-document copy was flagged")

        // A file the scan cannot read is an offender, never a silent pass.
        #expect(Self.identityOffenders(in: [], contract: contract).count == 1)
    }

    /// The body reader has to survive the shapes these files actually contain: a nested closure,
    /// a sibling init after the target, and a doc comment that writes `init(from:)`.
    @Test func theBodyReaderIsBraceBalancedAndSkipsDocComments() {
        let fixture = """
        struct D {
            /// The live row this draft came from. Set ONLY by `init(from:)`.
            init(from group: Group) {
                lines = group.lines.map { LineItemDraft(from: $0) }
                if lines.isEmpty { lines = [LineItemDraft()] }
                modelID = group.persistentModelID
            }
            init() { lines = [] }
            func unrelated() { never() }
        }
        """
        let found = Self.draftInits(in: fixture)
        #expect(found.map(\.signature) == ["init(from group: Group)"],
                "the doc comment's `init(from:)` or the no-argument init leaked in: \(found.map(\.signature))")
        let body = found.first?.body
        #expect(body?.contains("modelID = group.persistentModelID") == true,
                "the body was cut off at the first nested closing brace")
        #expect(body?.contains("never()") == false, "the body ran into a later declaration")
        #expect(Self.draftInits(in: "init(from x: Y) { if a {").isEmpty,
                "an unbalanced body must be dropped, not returned half-read")
    }

    /// A hand-rolled row delete is caught; the reconciler's closure and the whole-document
    /// deletes are not.
    @Test func theRowDeleteScanCatchesAHandRolledDelete() {
        let probe = """
                    delete: { modelContext.deleteSynced($0) })
                for item in group.lineItems { modelContext.deleteSynced(item) }
                modelContext.deleteSynced(changeOrder)
                modelContext.deleteSynced(group)
        """
        let caught = Self.rowDeleteOffenders(in: [(path: "Probe.swift", text: probe)])
        #expect(caught.count == 2, "expected exactly two offenders, got:\n\(caught.joined(separator: "\n"))")
        #expect(caught.contains { $0.hasPrefix("Probe.swift:2:") }, "the hand-rolled line delete was missed")
        #expect(caught.contains { $0.hasPrefix("Probe.swift:4:") }, "the hand-rolled group delete was missed")
        #expect(!caught.contains { $0.hasPrefix("Probe.swift:1:") }, "the reconciler's delete closure was flagged")
        #expect(!caught.contains { $0.hasPrefix("Probe.swift:3:") }, "the whole-document delete was flagged")
    }

    // MARK: - The forms themselves

    /// Every draft that opens on a saved row of its own document claims that row, every draft
    /// copied from another document claims nothing, and nothing in those files is unclassified.
    @Test func everyDraftOpenedFromASavedRowCarriesItsIdentity() {
        let files = GLSource.files().filter { Self.formPaths.contains($0.path) }
        // Vacuity gate: a scan of nothing passes for the wrong reason.
        #expect(files.map(\.path).sorted() == Self.formPaths.sorted(),
                "the three draft files were not readable — this scan proves nothing: \(files.map(\.path))")
        let declared = files.reduce(0) { $0 + Self.draftInits(in: $1.text).count }
        #expect(declared == 7, "expected the 7 contracted `init(from …)` declarations, found \(declared)")

        let found = Self.identityOffenders(in: files, contract: Self.identityContract)
        #expect(found.isEmpty, """
            \(found.count) form draft(s) no longer carry row identity correctly. Each one turns an \
            edit back into delete-and-rebuild, or makes one document rewrite another's rows:
            \(found.joined(separator: "\n"))
            """)
    }

    /// The only row deletes left in the three forms are the reconciler's `delete:` closures.
    @Test func noFormDeletesARowByName() {
        let files = GLSource.files().filter { Self.savePaths.contains($0.path) }
        #expect(files.count == Self.savePaths.count,
                "the three document services were not readable — this scan proves nothing")

        let found = Self.rowDeleteOffenders(in: files)
        #expect(found.isEmpty, """
            \(found.count) row delete(s) in the forms bypass RowReconciler. This is the \
            delete-and-rebuild save the whole change removed:
            \(found.joined(separator: "\n"))
            """)
    }

    /// Each `reconcile` call is wired to exactly one routed delete closure, in the shape the
    /// three forms use. This is the denominator for the scan above: five reconcile calls (two
    /// per document form for groups and lines, one for the change order), five routed deletes.
    @Test func everyReconcileCallIsWiredToARoutedDelete() {
        let files = GLSource.files().filter { Self.savePaths.contains($0.path) }
        #expect(files.count == Self.savePaths.count, "the three document services were not readable")

        var totalReconciles = 0
        for file in files {
            let reconciles = file.text.components(separatedBy: "RowReconciler.reconcile(").count - 1
            let routed = file.text.components(separatedBy: Self.routedDelete).count - 1
            #expect(reconciles > 0, "\(file.path) no longer calls RowReconciler.reconcile — the in-place save is gone")
            #expect(reconciles == routed, """
                \(file.path) has \(reconciles) RowReconciler.reconcile call(s) but \(routed) routed \
                delete closure(s). Every reconcile removes unclaimed rows through \
                `\(Self.routedDelete)`.
                """)
            totalReconciles += reconciles
        }
        #expect(totalReconciles == 5,
                "expected 5 reconcile calls across the three services (groups + lines, groups + lines, lines), found \(totalReconciles)")
    }
}
