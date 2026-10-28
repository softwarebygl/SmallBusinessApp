//
//  MBDeleteTool.swift
//  GLSmallBusiness — AI
//
//  `delete`: up to 25 records, through `DeletionService` — the ONE delete path (law 58, Pillar 5).
//  Nothing here touches a model: the service runs every check a swipe runs (read-only, liveness,
//  the paid lock, the cascade cap, all-or-nothing), takes a change order's billed items off its
//  invoice first, clears a subcontractor's Keychain tax id, and deletes through `deleteSynced`.
//
//  The person is always asked first (contract §5), in one alert that names every record and what
//  goes with it — `DeletionService.plan`, which changes nothing. A confirmed delete keeps no Undo.
//  Payments are never deleted: that refusal offers a credit change order instead.
//
//  A CUSTOMER (a client) is different (owner ruling 2026-09-25 (7)): one per call, alone, and
//  the alert is the typed-name gate — it shows the client's name, says everything tied to them
//  goes too, and Delete stays off until the name is typed (GLAIConfirmation.typedName, the same
//  GoldLifeUI gate the Customers screen uses). Every other kind keeps the standard alert.
//

import Foundation
import SwiftData
import GoldLifeAI

@MainActor
struct MBDeleteTool: GLAITool {
    let entry: GLAIManifest.Tool
    let env: MBToolEnvironment

    var name: String { entry.name }
    var summary: String { entry.summary }
    var parameters: GLAISchema { entry.parameters }
    var area: GLAIToolArea { entry.area }

    func run(_ call: GLAIToolCall, context: GLAIToolContext) async -> GLAIToolOutcome {
        guard context.isStillCurrent, let store = env.context() else { return MBToolFailure.unavailable }
        let args = MBArguments(json: call.arguments)
        let entries = args.objects("records")
        guard !entries.isEmpty else { return MBToolFailure.invalid("Send at least one record to delete.") }
        guard entries.count <= 25 else {
            return MBToolFailure.invalid("Delete at most 25 records in one call.")
        }

        // Clients are confirmed one at a time, by name: a call that mixes a customer with anything
        // else, or names two, is sent back to be split (the model then makes one call per client).
        let customerCount = entries.filter { $0["kind"]?.stringValue == DeletionService.Kind.customer.rawValue }.count
        if customerCount > 0, entries.count > 1 {
            return MBToolFailure.invalid(Self.oneCustomerPerCall)
        }

        var targets: [DeletionService.Target] = []
        var ids: [String] = []
        for entry in entries {
            guard let kindName = entry["kind"]?.stringValue,
                  let kind = DeletionService.Kind(rawValue: kindName) else {
                return MBToolFailure.invalid("Each record needs a kind the app knows (customer, estimate, invoice, …).")
            }
            guard let idText = entry["id"]?.stringValue, let id = MBIDs.uuid(idText) else {
                return MBToolFailure.invalid("Each record needs its id, as find or get returned it.")
            }
            do {
                targets.append(try DeletionService.target(kind: kind, id: id, in: store))
                ids.append(idText)
            } catch let error as DomainError {
                return MBToolFailure.domain(error, MBWrite.ref(MBRecordKind(rawValue: kindName) ?? .customer, idText))
            } catch {
                return MBToolFailure.unexpected(error)
            }
        }

        let plan: DeletionService.Plan
        do {
            plan = try DeletionService.plan(targets, in: store, subscription: env.subscription())
        } catch let error as DomainError {
            return MBToolFailure.domain(error)
        } catch {
            return MBToolFailure.unexpected(error)
        }

        // What the alert says: every record by name, then what goes with them, then (over 25 roots)
        // the note about the owner's other devices.
        // A client is named the way the gate asks for it to be typed ("Ana Lopez"), so the title
        // and the name to type agree.
        let typedName: String? = targets.count == 1 ? Self.typedName(for: targets[0]) : nil
        let named = typedName.map { MBWriteStrings.phrase(.customer, $0, attachment: nil) }
            ?? targets.map { label(for: $0, named: true) }.joined(separator: ", ")
        var effects = plan.effects
        if plan.tripsOtherDevicesBreaker { effects.append(DeletionService.otherDevicesBreakerNote) }
        let line = effects.isEmpty
            ? MBWriteStrings.confirmDelete(named)
            : MBWriteStrings.confirmDelete(named, effects.joined(separator: " "))

        let rows = targets.map { DeletedRecord(kind: $0.kind, label: label(for: $0, named: false),
                                               symbol: MBWriteSymbol.symbol(for: $0.kind, attachment: attachment($0)),
                                               title: MBWriteStrings.deleted($0.kind, attachment: attachment($0))) }
        let englishNames = targets.map { "\($0.kind.rawValue) \(label(for: $0, named: false))" }
            .joined(separator: ", ")
        let kinds = targets.map(\.kind.rawValue)
        return .needsConfirmation(GLAIConfirmation(
            recordIDs: ids,
            line: line,
            actionLabel: MBWriteStrings.confirmDeleteAction,
            isDestructive: true,
            declinedMessage: "The user chose not to delete \(englishNames).",
            typedName: typedName,
            perform: { [env] in Self.delete(ids: ids, kinds: kinds, rows: rows, env: env) }))
    }

    /// Model-facing: why a call naming a customer alongside anything else is sent back.
    static let oneCustomerPerCall = "Delete a customer in a call of its own, one customer per call: the person confirms each client by typing their name. Call delete again for anything else."

    /// The name typed to confirm deleting this record — a customer's only (owner ruling
    /// 2026-09-25 (7)); nil keeps the standard alert.
    static func typedName(for target: DeletionService.Target) -> String? {
        guard case .customer(let customer) = target else { return nil }
        return CustomerDeleteConfirmation.typedName(for: customer)
    }

    /// What the card says about one deleted record — captured BEFORE the delete, because a deleted
    /// model can't be read.
    struct DeletedRecord: Sendable {
        let kind: DeletionService.Kind
        let label: String
        let symbol: String
        let title: LocalizedStringResource
    }

    /// The delete itself, re-found by id (contract §4) and run as one all-or-nothing batch.
    static func delete(ids: [String], kinds: [String], rows: [DeletedRecord],
                       env: MBToolEnvironment) -> GLAIToolOutcome {
        guard let store = env.context() else { return MBToolFailure.unavailable }
        var targets: [DeletionService.Target] = []
        for (idText, kindName) in zip(ids, kinds) {
            guard let kind = DeletionService.Kind(rawValue: kindName), let id = MBIDs.uuid(idText) else {
                return MBToolFailure.invalid("Each record needs a kind and an id.")
            }
            do {
                targets.append(try DeletionService.target(kind: kind, id: id, in: store))
            } catch let error as DomainError {
                return MBToolFailure.domain(error)
            } catch {
                return MBToolFailure.unexpected(error)
            }
        }
        let outcome: DeletionService.Outcome
        do {
            outcome = try DeletionService.delete(targets, in: store, subscription: env.subscription())
        } catch let error as DomainError {
            return MBToolFailure.domain(error)
        } catch {
            return MBToolFailure.unexpected(error)
        }
        guard case .deleted(let report) = outcome else {
            return MBToolFailure.unexpected(DomainError.recordNotFound)
        }
        var output: [String: GLAIJSON] = [
            "ok": true,
            "deleted": .number(Double(report.deleted)),
            "records": .array(rows.map { ["kind": .string($0.kind.rawValue), "name": .string($0.label)] }),
        ]
        if report.itemsLeftOnInvoice {
            output["items_left_on_invoice"] = true
            output["message"] = "A change order's billed items couldn't be matched on its invoice, so they are still there. Tell the user to remove them on the invoice."
        }
        if report.tripsOtherDevicesBreaker {
            output["pauses_sync_on_other_devices"] = true
        }
        // Confirmed: no Undo (contract §5).
        return .result(.object(output),
                       activity: rows.map {
                           GLAIActivity(kind: .deleted, symbol: $0.symbol, title: $0.title, detail: $0.label)
                       })
    }

    // MARK: Names

    private func attachment(_ target: DeletionService.Target) -> JobAttachment? {
        if case .attachment(let file) = target { return file }
        return nil
    }

    /// The record's own words. `named` wraps it in its kind for the alert ("Invoice INV-0003").
    private func label(for target: DeletionService.Target, named: Bool) -> String {
        let value = MBValue(calendar: env.calendar)
        let plain: String
        switch target {
        case .customer(let m): plain = m.listDisplayName
        case .estimate(let m): plain = m.number
        case .contract(let m): plain = m.number
        case .invoice(let m): plain = m.number
        case .changeOrder(let m): plain = m.number
        case .job(let m): plain = m.displayTitle
        case .receipt(let m): plain = "\(m.displayVendor) · \(value.dayString(m.date))"
        case .priceItem(let m): plain = m.name
        case .employee(let m): plain = m.fullName
        case .subcontractor(let m): plain = m.listDisplayName
        case .project(let m): plain = m.displayName
        case .timeEntry(let m): plain = value.dayString(m.date)
        case .paycheck(let m): plain = "\(MBWriteValue.amount(m.grossAmount)) · \(value.dayString(m.payDate))"
        case .subPayment(let m): plain = "\(MBWriteValue.amount(m.amount)) · \(value.dayString(m.date))"
        case .attachment(let m): plain = m.name
        case .customerDocument(let m): plain = m.name
        }
        return named ? MBWriteStrings.phrase(target.kind, plain, attachment: attachment(target)) : plain
    }
}
