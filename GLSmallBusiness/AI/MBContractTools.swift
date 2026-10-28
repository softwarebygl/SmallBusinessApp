//
//  MBContractTools.swift
//  GLSmallBusiness — AI
//
//  `create_contract`, `edit_contract`, and `invoice_from_contract` — providing full CRUD
//  and conversion capabilities for Contracts, mirroring ContractFormScreen, EstimateDetailScreen,
//  and InvoiceFromContractSheet.
//

import Foundation
import SwiftData
import GoldLifeAI

// MARK: - create_contract

@MainActor
struct MBCreateContractTool: GLAITool {
    let entry: GLAIManifest.Tool
    let env: MBToolEnvironment

    var name: String { entry.name }
    var summary: String { entry.summary }
    var parameters: GLAISchema { entry.parameters }
    var area: GLAIToolArea { entry.area }

    func run(_ call: GLAIToolCall, context: GLAIToolContext) async -> GLAIToolOutcome {
        guard context.isStillCurrent, let store = env.context() else { return MBToolFailure.unavailable }
        if ReadOnlyGate.isReadOnly(env.subscription()) {
            return MBToolFailure.domain(DomainError.readOnly(operation: "contract", lapsed: true))
        }
        let args = MBArguments(json: call.arguments)
        let value = MBValue(calendar: env.calendar)
        let dto = MBRecordDTO(env: env, context: store)
        let existingContracts = MBRecordLookup.all(Contract.self, in: store)
        let profile = MBRecordLookup.businessProfile(in: store)

        // Door 1: Convert from Estimate
        if let estimateID = args.string("from_estimate_id") {
            guard let estimate = MBRecordLookup.record(.estimate, id: estimateID, as: Estimate.self, in: store) else {
                return MBToolFailure.notFound(.estimate)
            }
            let contractNum = args.string("number") ?? Contract.nextNumber(after: existingContracts, profile: profile)
            let title = args.string("title") ?? (estimate.jobTitle.isEmpty ? estimate.customerDisplayName : estimate.jobTitle)
            let contract = Contract(
                number: contractNum,
                title: title,
                customerName: estimate.customerDisplayName,
                customerEmail: estimate.customerEmail,
                customerPhone: estimate.customerPhone,
                startDate: value.parseDay(args.string("start_date")) ?? .now,
                durationDays: max(1, args.int("duration_days") ?? 1),
                isAllDay: args.bool("is_all_day") ?? true,
                notes: args.string("notes") ?? estimate.customerNotes,
                terms: args.string("terms") ?? estimate.terms,
                serviceAddress: args.has("service_address") ? MBWriteValue.address(estimate.serviceAddress, patch: args.object("service_address")) : estimate.serviceAddress,
                agreedPrice: args.money("agreed_price"),
                status: .draft,
                customer: estimate.customer,
                estimate: estimate
            )
            store.insert(contract)

            for (gIndex, group) in estimate.sortedGroups.enumerated() {
                let contractGroup = ContractGroup(name: group.name, note: group.note, sortIndex: gIndex)
                contractGroup.contract = contract
                store.insert(contractGroup)
                for (lIndex, item) in group.sortedLineItems.enumerated() {
                    let line = ContractLineItem(
                        name: item.name,
                        details: item.details,
                        quantity: item.quantity,
                        unit: item.unit,
                        unitPrice: item.unitPrice,
                        kind: item.kind,
                        isTaxable: item.isTaxable,
                        sortIndex: lIndex
                    )
                    line.group = contractGroup
                    store.insert(line)
                }
            }

            if estimate.status != .accepted {
                estimate.status = .accepted
            }

            let job = ScheduledJob(customer: estimate.customer)
            job.title = contract.title
            job.contract = contract
            job.estimate = estimate
            job.customerName = contract.customerName
            job.startDate = contract.startDate
            job.durationDays = contract.durationDays
            job.isAllDay = contract.isAllDay
            job.serviceAddress = contract.serviceAddress
            if let agreed = contract.agreedPrice {
                job.agreedPrice = agreed
            }
            contract.scheduledJob = job
            store.insert(job)

            store.saveChanges()

            let recordID = MBIDs.id(contract, env)
            let ref = MBWrite.ref(.contract, recordID)
            env.ledger.note(recordID, MBFingerprint.of(contract))
            return .result(["ok": true, "id": .string(recordID), "contract": dto.row(contract)],
                           activity: [GLAIActivity(kind: .created, symbol: MBWriteSymbol.contract,
                                                   title: MBWriteStrings.contractCreated,
                                                   detail: "\(contract.number) · \(contract.displayTitle)", record: ref)],
                           undo: undoCreate(ref, number: contract.number, env: env))
        }

        // Door 2: Create from scratch
        guard let customerID = args.string("customer_id") else {
            return MBToolFailure.invalid("customer_id or from_estimate_id is required.")
        }
        guard let customer = MBRecordLookup.record(.customer, id: customerID, as: Customer.self, in: store) else {
            return MBToolFailure.notFound(.customer)
        }
        guard let title = args.string("title"), !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return MBToolFailure.invalid("title is required.")
        }

        let contractNum = args.string("number") ?? Contract.nextNumber(after: existingContracts, profile: profile)
        let sAddr = args.has("service_address")
            ? MBWriteValue.address(customer.serviceAddress, patch: args.object("service_address"))
            : customer.serviceAddress

        let contract = Contract(
            number: contractNum,
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            customerName: customer.listDisplayName,
            customerEmail: customer.email,
            customerPhone: customer.phoneNumber,
            startDate: value.parseDay(args.string("start_date")) ?? .now,
            durationDays: max(1, args.int("duration_days") ?? 1),
            isAllDay: args.bool("is_all_day") ?? true,
            notes: args.string("notes") ?? "",
            terms: args.string("terms") ?? "",
            serviceAddress: sAddr,
            agreedPrice: args.money("agreed_price"),
            status: .draft,
            customer: customer
        )
        if let timeStr = args.string("start_time") {
            contract.startTime = value.parseMoment(timeStr)
        }
        if let durationMins = args.int("duration_minutes") {
            contract.durationMinutes = durationMins
        }
        store.insert(contract)

        // Parse optional groups
        let rawGroups = args.objects("groups")
        for (gIndex, rawGroup) in rawGroups.enumerated() {
            let groupName = rawGroup["name"]?.stringValue ?? ""
            let groupNote = rawGroup["note"]?.stringValue ?? ""
            let group = ContractGroup(name: groupName, note: groupNote, sortIndex: gIndex)
            group.contract = contract
            store.insert(group)

            let rawLines = rawGroup["lines"]?.arrayValue ?? []
            for (lIndex, rawLine) in rawLines.enumerated() {
                let name = rawLine["name"]?.stringValue ?? "Item"
                let details = rawLine["details"]?.stringValue ?? ""
                let quantity = rawLine["quantity"]?.doubleValue ?? 1.0
                let unit = rawLine["unit"]?.stringValue.flatMap { UnitOfMeasure(rawValue: $0) } ?? .squareFoot
                let unitPrice = rawLine["unit_price"]?.doubleValue ?? 0.0
                let kind = (rawLine["kind"]?.stringValue == "material") ? LineItemKind.material : LineItemKind.labor
                let taxable = rawLine["taxable"]?.boolValue ?? false

                let line = ContractLineItem(
                    name: name,
                    details: details,
                    quantity: quantity,
                    unit: unit,
                    unitPrice: unitPrice,
                    kind: kind,
                    isTaxable: taxable,
                    sortIndex: lIndex
                )
                line.group = group
                store.insert(line)
            }
        }

        let job = ScheduledJob(customer: customer)
        job.title = contract.title
        job.contract = contract
        job.customerName = contract.customerName
        job.startDate = contract.startDate
        job.durationDays = contract.durationDays
        job.isAllDay = contract.isAllDay
        job.startTime = contract.startTime
        job.durationMinutes = contract.durationMinutes
        job.notes = contract.notes
        job.serviceAddress = contract.serviceAddress
        if let agreed = contract.agreedPrice {
            job.agreedPrice = agreed
        }
        contract.scheduledJob = job
        store.insert(job)

        store.saveChanges()

        let recordID = MBIDs.id(contract, env)
        let ref = MBWrite.ref(.contract, recordID)
        env.ledger.note(recordID, MBFingerprint.of(contract))
        return .result(["ok": true, "id": .string(recordID), "contract": dto.row(contract)],
                       activity: [GLAIActivity(kind: .created, symbol: MBWriteSymbol.contract,
                                               title: MBWriteStrings.contractCreated,
                                               detail: "\(contract.number) · \(contract.displayTitle)", record: ref)],
                       undo: undoCreate(ref, number: contract.number, env: env))
    }

    private func undoCreate(_ ref: GLAIRecordRef, number: String, env: MBToolEnvironment) -> GLAIUndo {
        MBUndo.entry(ref, title: MBWriteStrings.undoTitle(contract: number), ledger: env.ledger,
                     fingerprint: { MBWrite.contract(ref.id, env).map(MBFingerprint.of) }) {
            guard let store = env.context(), let contract = MBWrite.contract(ref.id, env) else {
                return MBUndo.recordGone
            }
            guard contract.liveRows(contract.billingInvoices).isEmpty else {
                return .failed(MBWriteStrings.undoKeptHasRecords)
            }
            if let job = contract.scheduledJob {
                store.deleteSynced(job)
            }
            store.delete(contract)
            store.saveChanges()
            return MBUndo.reverted(.deleted, MBWriteSymbol.contract, MBWriteStrings.deleted(.contract),
                                   detail: number, record: nil)
        }
    }
}

// MARK: - edit_contract

@MainActor
struct MBEditContractTool: GLAITool {
    let entry: GLAIManifest.Tool
    let env: MBToolEnvironment

    var name: String { entry.name }
    var summary: String { entry.summary }
    var parameters: GLAISchema { entry.parameters }
    var area: GLAIToolArea { entry.area }

    func run(_ call: GLAIToolCall, context: GLAIToolContext) async -> GLAIToolOutcome {
        guard context.isStillCurrent, let store = env.context() else { return MBToolFailure.unavailable }
        if ReadOnlyGate.isReadOnly(env.subscription()) {
            return MBToolFailure.domain(DomainError.readOnly(operation: "contract", lapsed: true))
        }
        let args = MBArguments(json: call.arguments)
        let value = MBValue(calendar: env.calendar)
        let dto = MBRecordDTO(env: env, context: store)

        guard let id = args.string("id") else {
            return MBToolFailure.invalid("id is required.")
        }
        guard let contract = MBRecordLookup.record(.contract, id: id, as: Contract.self, in: store) else {
            return MBToolFailure.notFound(.contract)
        }

        let before = ContractDraft(contract)

        if let title = args.string("title"), !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            contract.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let customerID = args.string("customer_id"),
           let customer = MBRecordLookup.record(.customer, id: customerID, as: Customer.self, in: store) {
            contract.customer = customer
            contract.customerName = customer.listDisplayName
            contract.customerEmail = customer.email
            contract.customerPhone = customer.phoneNumber
        }
        if let day = value.parseDay(args.string("start_date")) {
            contract.startDate = day
        }
        if let days = args.int("duration_days") {
            contract.durationDays = max(1, days)
        }
        if let allDay = args.bool("is_all_day") {
            contract.isAllDay = allDay
        }
        if let timeStr = args.string("start_time") {
            contract.startTime = value.parseMoment(timeStr)
        }
        if let mins = args.int("duration_minutes") {
            contract.durationMinutes = mins
        }
        if let notes = args.string("notes") {
            contract.notes = notes
        }
        if let terms = args.string("terms") {
            contract.terms = terms
        }
        if args.has("service_address") {
            contract.serviceAddress = MBWriteValue.address(contract.serviceAddress, patch: args.object("service_address"))
        }
        if args.has("agreed_price") {
            contract.agreedPrice = args.money("agreed_price")
        }
        if let statusRaw = args.string("status"), let status = ContractStatus(rawValue: statusRaw) {
            contract.statusRaw = status.rawValue
            if status == .completed {
                contract.completedAt = .now
            }
        }

        // Keep linked ScheduledJob in sync
        if let job = contract.scheduledJob {
            job.title = contract.title
            job.startDate = contract.startDate
            job.durationDays = contract.durationDays
            job.isAllDay = contract.isAllDay
            job.startTime = contract.startTime
            job.durationMinutes = contract.durationMinutes
            job.notes = contract.notes
            job.serviceAddress = contract.serviceAddress
            if let agreed = contract.agreedPrice {
                job.agreedPrice = agreed
            }
        }

        store.saveChanges()

        let recordID = MBIDs.id(contract, env)
        let ref = MBWrite.ref(.contract, recordID)
        env.ledger.note(recordID, MBFingerprint.of(contract))
        let token = env.ledger.stash(.contract(before))

        return .result(["ok": true, "id": .string(recordID), "contract": dto.row(contract)],
                       activity: [GLAIActivity(kind: .updated, symbol: MBWriteSymbol.contract,
                                               title: MBWriteStrings.contractUpdated,
                                               detail: "\(contract.number) · \(contract.displayTitle)", record: ref)],
                       undo: undoEdit(ref, number: contract.number, token: token, env: env))
    }

    private func undoEdit(_ ref: GLAIRecordRef, number: String, token: UUID, env: MBToolEnvironment) -> GLAIUndo {
        MBUndo.entry(ref, title: MBWriteStrings.undoTitle(contract: number), ledger: env.ledger,
                     fingerprint: { MBWrite.contract(ref.id, env).map(MBFingerprint.of) }) {
            guard let store = env.context(), let contract = MBWrite.contract(ref.id, env),
                  case .contract(let before)? = env.ledger.snapshot(token) else { return MBUndo.recordGone }

            contract.title = before.title
            if let custID = before.customerID,
               let customer = MBRecordLookup.record(.customer, id: custID.uuidString, as: Customer.self, in: store) {
                contract.customer = customer
            }
            contract.customerName = before.customerName
            contract.customerEmail = before.customerEmail
            contract.customerPhone = before.customerPhone
            contract.startDate = before.startDate
            contract.durationDays = before.durationDays
            contract.isAllDay = before.isAllDay
            contract.startTime = before.startTime
            contract.durationMinutes = before.durationMinutes
            contract.notes = before.notes
            contract.terms = before.terms
            contract.serviceAddress = before.serviceAddress
            contract.agreedPrice = before.agreedPrice
            contract.statusRaw = before.status.rawValue

            if let job = contract.scheduledJob {
                job.title = contract.title
                job.startDate = contract.startDate
                job.durationDays = contract.durationDays
                job.isAllDay = contract.isAllDay
                job.startTime = contract.startTime
                job.durationMinutes = contract.durationMinutes
                job.notes = contract.notes
                job.serviceAddress = contract.serviceAddress
                if let agreed = contract.agreedPrice {
                    job.agreedPrice = agreed
                }
            }

            store.saveChanges()
            env.ledger.note(ref.id, MBFingerprint.of(contract))
            return MBUndo.reverted(.updated, MBWriteSymbol.contract, MBWriteStrings.contractRestored,
                                   detail: contract.number, record: ref)
        }
    }
}

// MARK: - invoice_from_contract

@MainActor
struct MBInvoiceFromContractTool: GLAITool {
    let entry: GLAIManifest.Tool
    let env: MBToolEnvironment

    var name: String { entry.name }
    var summary: String { entry.summary }
    var parameters: GLAISchema { entry.parameters }
    var area: GLAIToolArea { entry.area }

    func run(_ call: GLAIToolCall, context: GLAIToolContext) async -> GLAIToolOutcome {
        guard context.isStillCurrent, let store = env.context() else { return MBToolFailure.unavailable }
        let args = MBArguments(json: call.arguments)
        let dto = MBRecordDTO(env: env, context: store)

        guard let contractID = args.string("contract_id") else {
            return MBToolFailure.invalid("contract_id is required.")
        }
        guard let contract = MBRecordLookup.record(.contract, id: contractID, as: Contract.self, in: store) else {
            return MBToolFailure.notFound(.contract)
        }
        guard let targetCustomer = contract.customer else {
            return MBToolFailure.invalid("Contract has no associated customer to invoice.")
        }

        let mode = args.string("mode") ?? "full_balance"
        var draft = InvoiceDraft()
        draft.jobTitle = contract.title
        draft.customerNotes = contract.notes
        draft.terms = contract.terms
        draft.serviceAddress = contract.serviceAddress

        switch mode {
        case "percentage":
            guard let percentage = args.number("percentage"), percentage > 0, percentage <= 100 else {
                return MBToolFailure.invalid("percentage must be between 1 and 100.")
            }
            let pct = Int(percentage)
            let calculatedAmount = DomainMoney.roundedToCents(contract.contractedValue * (percentage / 100.0))
            var line = InvoiceLineDraft()
            line.name = "\(pct)% \(mbLoc("Progress Billing")) - \(contract.displayTitle)"
            line.details = "\(mbLoc("Payment for")) \(pct)% \(mbLoc("of contract")) \(contract.number)"
            line.quantity = 1.0
            line.unit = .job
            line.unitPrice = calculatedAmount
            draft.amountDueNow = calculatedAmount
            draft.amountDueDetail = "\(pct)% \(mbLoc("Progress Payment"))"
            draft.groups = [InvoiceGroupDraft(name: mbLoc("Progress Payment"), note: "\(pct)% \(mbLoc("Billing"))", lines: [line])]

        case "specific_line_items":
            let wantedIDs = Set(args.strings("line_item_ids"))
            var matchedLines: [InvoiceLineDraft] = []
            for group in contract.sortedGroups {
                for item in group.sortedLineItems {
                    let itemID = MBIDs.id(item, env)
                    if wantedIDs.contains(itemID) || wantedIDs.contains(item.name) {
                        var line = InvoiceLineDraft()
                        line.name = item.name
                        line.details = item.details
                        line.quantity = item.quantity
                        line.unit = item.unit
                        line.unitPrice = item.unitPrice
                        line.kind = item.kind
                        line.isTaxable = item.isTaxable
                        line.fromChangeOrder = item.fromChangeOrder
                        matchedLines.append(line)
                    }
                }
            }
            guard !matchedLines.isEmpty else {
                return MBToolFailure.invalid("No matching line items found on contract for line_item_ids.")
            }
            draft.groups = [InvoiceGroupDraft(name: contract.title, note: "", lines: matchedLines)]

        default: // full_balance
            for group in contract.sortedGroups {
                let lines = group.sortedLineItems.map { item -> InvoiceLineDraft in
                    var line = InvoiceLineDraft()
                    line.name = item.name
                    line.details = item.details
                    line.quantity = item.quantity
                    line.unit = item.unit
                    line.unitPrice = item.unitPrice
                    line.kind = item.kind
                    line.isTaxable = item.isTaxable
                    line.fromChangeOrder = item.fromChangeOrder
                    return line
                }
                draft.groups.append(InvoiceGroupDraft(name: group.name, note: group.note, lines: lines))
            }
            for co in contract.approvedChangeOrders {
                let coTitle = co.title.isEmpty ? co.number : "\(co.number): \(co.title)"
                let lines = co.sortedLineItems.map { item -> InvoiceLineDraft in
                    var line = InvoiceLineDraft()
                    line.name = item.name
                    line.details = item.details
                    line.quantity = item.quantity
                    line.unit = item.unit
                    line.unitPrice = item.unitPrice
                    line.kind = .labor
                    line.isTaxable = item.isTaxable
                    line.fromChangeOrder = true
                    return line
                }
                draft.groups.append(InvoiceGroupDraft(name: coTitle, note: mbLoc("Change Order"), lines: lines))
            }
        }

        let invoice: Invoice
        do {
            invoice = try InvoiceService.create(
                draft,
                for: targetCustomer,
                contract: contract,
                origin: .tool,
                in: store,
                subscription: env.subscription()
            )
            // Pre-seed reminder settings from defaults
            invoice.autoRemindersEnabled = UserDefaults.standard.bool(forKey: "gl.invoice.defaultAutoRemindersEnabled")
            invoice.reminderStartTriggerRaw = UserDefaults.standard.string(forKey: "gl.invoice.defaultReminderStartTrigger") ?? ReminderStartTrigger.oneWeekBeforeDue.rawValue
            invoice.reminderFrequencyRaw = UserDefaults.standard.string(forKey: "gl.invoice.defaultReminderFrequency") ?? ReminderFrequency.weekly.rawValue
            store.saveChanges()
        } catch let error as DomainError {
            return MBToolFailure.domain(error)
        } catch {
            return MBToolFailure.unexpected(error)
        }

        let recordID = MBIDs.id(invoice, env)
        let ref = MBWrite.ref(.invoice, recordID)
        env.ledger.note(recordID, MBFingerprint.of(invoice))
        return .result(["ok": true, "id": .string(recordID), "invoice": dto.row(invoice)],
                       activity: [GLAIActivity(kind: .created, symbol: MBWriteSymbol.invoice,
                                               title: MBWriteStrings.invoiceCreated,
                                               detail: "\(invoice.number) · \(invoice.jobTitle)", record: ref)],
                       undo: MBInvoiceDraftBuilder.undoCreate(ref, number: invoice.number, env: env, paymentsAtWrite: 0))
    }
}
