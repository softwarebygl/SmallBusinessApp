//
//  MBTeamTools.swift
//  GLSmallBusiness — AI
//
//  The `team` area: employees, their hours and paychecks, subcontractors and their ledger —
//  through `EmployeeService` and `SubcontractorService`, the same calls the Employee form, the
//  Log Hours / Log Bonus / Pay Now sheets and the subcontractor's Record Amount / Pay Now sheets
//  make (law 58).
//
//  TAX FIELDS ARE NOT HERE. `save_subcontractor` writes no TIN, no TIN type and no W-9: those
//  stay on the form, behind Face ID and the Keychain (contract §5 quarantine). The tool tells the
//  model to offer to OPEN the subcontractor instead.
//
//  Money is always confirmed (contract §5): `pay_employee`, `edit_paycheck`, `pay_subcontractor`
//  and a `log_sub_work` that records the work as already paid. A confirmed change keeps no Undo.
//

import Foundation
import SwiftData
import GoldLifeAI

// MARK: - save_employee

@MainActor
struct MBSaveEmployeeTool: GLAITool {
    let entry: GLAIManifest.Tool
    let env: MBToolEnvironment

    var name: String { entry.name }
    var summary: String { entry.summary }
    var parameters: GLAISchema { entry.parameters }
    var area: GLAIToolArea { entry.area }

    func run(_ call: GLAIToolCall, context: GLAIToolContext) async -> GLAIToolOutcome {
        guard context.isStillCurrent, let store = env.context() else { return MBToolFailure.unavailable }
        let args = MBArguments(json: call.arguments)
        let value = MBValue(calendar: env.calendar)
        let dto = MBRecordDTO(env: env, context: store)

        if let id = args.string("id") {
            guard let employee = MBRecordLookup.record(.employee, id: id, as: Employee.self, in: store) else {
                return MBToolFailure.notFound(.employee)
            }
            let recordID = MBIDs.id(employee, env)
            let ref = MBWrite.ref(.employee, recordID)
            let before = EmployeeDraft(employee)
            switch Self.patched(before, args, value) {
            case .outcome(let outcome): return outcome
            case .value(let draft):
                do {
                    try EmployeeService.update(employee, with: draft, in: store, subscription: env.subscription())
                } catch {
                    return MBToolFailure.unexpected(error, ref)
                }
                env.ledger.note(recordID, MBFingerprint.stamp(employee))
                return .result(["ok": true, "employee": dto.row(employee)],
                               activity: [GLAIActivity(kind: .updated, symbol: MBWriteSymbol.employee,
                                                       title: MBWriteStrings.employeeUpdated,
                                                       detail: employee.fullName, record: ref)],
                               undo: Self.undoEdit(recordID, before: before, env: env))
            }
        }

        var blank = EmployeeDraft()
        blank.anchorPayday = env.calendar.startOfDay(for: env.now())
        blank.hireDate = env.calendar.startOfDay(for: env.now())
        switch Self.patched(blank, args, value) {
        case .outcome(let outcome): return outcome
        case .value(let draft):
            let employee: Employee
            do {
                employee = try EmployeeService.create(draft, in: store, subscription: env.subscription())
            } catch {
                return MBToolFailure.unexpected(error)
            }
            let recordID = MBIDs.id(employee, env)
            let ref = MBWrite.ref(.employee, recordID)
            env.ledger.note(recordID, MBFingerprint.stamp(employee))
            return .result(["ok": true, "employee": dto.row(employee)],
                           activity: [GLAIActivity(kind: .created, symbol: MBWriteSymbol.employee,
                                                   title: MBWriteStrings.employeeAdded,
                                                   detail: employee.fullName, record: ref)],
                           undo: Self.undoCreate(recordID, name: employee.fullName, env: env))
        }
    }

    static func patched(_ base: EmployeeDraft, _ args: MBArguments, _ value: MBValue) -> MBStep<EmployeeDraft> {
        var draft = base
        if let text = args.json["first_name"]?.stringValue { draft.firstName = text }
        if let text = args.json["last_name"]?.stringValue { draft.lastName = text }
        if let text = args.json["email"]?.stringValue { draft.email = text }
        if let text = args.json["phone"]?.stringValue { draft.phone = text }
        if let type = args.raw("pay_type", PayType.self) { draft.payType = type }
        if let rate = args.number("hourly_rate") { draft.hourlyRate = rate }
        if let salary = args.number("annual_salary") { draft.annualSalary = salary }
        if let frequency = args.raw("pay_frequency", PayFrequency.self) { draft.payFrequency = frequency }
        if args.has("next_payday") {
            guard let date = value.parseDay(args.string("next_payday")) else {
                return .outcome(MBToolFailure.invalid("next_payday must be a day, YYYY-MM-DD."))
            }
            draft.anchorPayday = date
        }
        if args.has("hire_date") {
            guard let date = value.parseDay(args.string("hire_date")) else {
                return .outcome(MBToolFailure.invalid("hire_date must be a day, YYYY-MM-DD."))
            }
            draft.hireDate = date
        }
        if let active = args.bool("active") { draft.isActive = active }
        if let notes = args.json["notes"]?.stringValue { draft.notes = notes }
        return .value(draft)
    }

    // MARK: Undo

    static func employee(_ recordID: String, _ env: MBToolEnvironment) -> Employee? {
        guard let store = env.context() else { return nil }
        return MBRecordLookup.record(.employee, id: recordID, as: Employee.self, in: store)
    }

    static func undoCreate(_ recordID: String, name: String, env: MBToolEnvironment) -> GLAIUndo {
        let ref = MBWrite.ref(.employee, recordID)
        return MBUndo.entry(ref, title: MBWriteStrings.undoTitle(employee: name), ledger: env.ledger,
                            fingerprint: { employee(recordID, env).map(MBFingerprint.stamp) }) {
            guard let store = env.context(), let person = employee(recordID, env) else { return MBUndo.recordGone }
            // Someone who has picked up hours or a paycheck since is kept: deleting takes those too.
            let dependents = person.liveRows(person.timeEntries).count + person.liveRows(person.paychecks).count
            guard dependents == 0 else { return .failed(MBWriteStrings.undoKeptHasRecords) }
            let label = person.fullName
            do {
                try DeletionService.delete([.employee(person)], in: store, subscription: env.subscription())
            } catch {
                return MBWrite.revertFailure(error)
            }
            return MBUndo.reverted(.deleted, MBWriteSymbol.employee, MBWriteStrings.deleted(.employee),
                                   detail: label, record: nil)
        }
    }

    static func undoEdit(_ recordID: String, before: EmployeeDraft, env: MBToolEnvironment) -> GLAIUndo {
        let ref = MBWrite.ref(.employee, recordID)
        return MBUndo.entry(ref, title: MBWriteStrings.undoTitle(employee: before.trimmed.firstName),
                            ledger: env.ledger,
                            fingerprint: { employee(recordID, env).map(MBFingerprint.stamp) }) {
            guard let store = env.context(), let person = employee(recordID, env) else { return MBUndo.recordGone }
            do {
                try EmployeeService.update(person, with: before, in: store, subscription: env.subscription())
            } catch {
                return MBWrite.revertFailure(error)
            }
            env.ledger.note(recordID, MBFingerprint.stamp(person))
            return MBUndo.reverted(.updated, MBWriteSymbol.employee, MBWriteStrings.employeeRestored,
                                   detail: person.fullName, record: ref)
        }
    }
}

// MARK: - log_time

@MainActor
struct MBLogTimeTool: GLAITool {
    let entry: GLAIManifest.Tool
    let env: MBToolEnvironment

    var name: String { entry.name }
    var summary: String { entry.summary }
    var parameters: GLAISchema { entry.parameters }
    var area: GLAIToolArea { entry.area }

    func run(_ call: GLAIToolCall, context: GLAIToolContext) async -> GLAIToolOutcome {
        guard context.isStillCurrent, let store = env.context() else { return MBToolFailure.unavailable }
        let args = MBArguments(json: call.arguments)
        let value = MBValue(calendar: env.calendar)

        let existing: TimeEntry?
        let employee: Employee
        if let id = args.string("id") {
            guard let found = MBRecordLookup.record(.timeEntry, id: id, as: TimeEntry.self, in: store),
                  let owner = found.employee else { return MBToolFailure.notFound(.timeEntry) }
            existing = found
            employee = owner
        } else {
            guard let id = args.string("employee_id"),
                  let owner = MBRecordLookup.record(.employee, id: id, as: Employee.self, in: store) else {
                return MBToolFailure.invalid("A new entry needs employee_id. Use find to get the employee id.")
            }
            existing = nil
            employee = owner
        }

        let mode = args.string("mode") ?? (existing.map { $0.amount > DomainMoney.epsilon ? "dollars" : "hours" } ?? "")
        let day = value.parseDay(args.string("date"))
            ?? existing?.date
            ?? env.calendar.startOfDay(for: env.now())
        let note = args.json["note"]?.stringValue ?? existing?.note ?? ""

        var customer: Customer? = existing?.customer
        if args.has("customer_id") {
            if args.isNull("customer_id") {
                customer = nil
            } else {
                guard let id = args.string("customer_id"),
                      let found = MBRecordLookup.record(.customer, id: id, as: Customer.self, in: store) else {
                    return MBToolFailure.notFound(.customer)
                }
                customer = found
            }
        }

        let employeeID = MBIDs.id(employee, env)
        let ref = MBWrite.ref(.employee, employeeID)
        let rate = args.number("rate") ?? (existing.map { $0.rateSnapshot > 0 ? $0.rateSnapshot : employee.hourlyRate }
                                          ?? employee.hourlyRate)

        // Snapshotted BEFORE the write: `existing` is the very row the service edits in place.
        let before = existing.map(MBTimeEntrySnapshot.init)
        let written: TimeEntry
        do {
            switch mode {
            case "bonus":
                guard let amount = args.money("amount") ?? existing.map(\.amount) else {
                    return MBToolFailure.domain(.amountRequired, ref)
                }
                written = try EmployeeService.logBonus(amount, on: day, note: note, for: employee,
                                                       editing: existing, in: store,
                                                       subscription: env.subscription())
            case "dollars":
                guard let amount = args.money("amount") ?? existing.map(\.amount) else {
                    return MBToolFailure.domain(.amountRequired, ref)
                }
                written = try EmployeeService.logTime(.dollars(amount, on: day), customer: customer, note: note,
                                                      for: employee, editing: existing, in: store,
                                                      subscription: env.subscription())
            case "range":
                guard let start = value.parseMoment(args.string("start")),
                      let end = value.parseMoment(args.string("end")) else {
                    return MBToolFailure.invalid("range needs start and end as ISO 8601 date-times with an offset.")
                }
                written = try EmployeeService.logTime(.range(start: start, end: end, rate: rate),
                                                      customer: customer, note: note, for: employee,
                                                      editing: existing, in: store,
                                                      subscription: env.subscription())
            case "hours":
                guard let hours = args.number("hours") ?? existing.map(\.hours) else {
                    return MBToolFailure.domain(.hoursAndRateRequired, ref)
                }
                written = try EmployeeService.logTime(.hours(hours, on: day, rate: rate), customer: customer,
                                                      note: note, for: employee, editing: existing, in: store,
                                                      subscription: env.subscription())
            default:
                return MBToolFailure.invalid("mode must be hours, range, dollars or bonus.")
            }
        } catch {
            return MBToolFailure.unexpected(error, ref)
        }

        let recordID = MBIDs.id(written, env)
        let entryRef = MBWrite.ref(.timeEntry, recordID)
        env.ledger.note(recordID, MBFingerprint.stamp(written))
        let dto = MBRecordDTO(env: env, context: store)
        let isBonus = mode == "bonus"
        let detail = "\(employee.fullName) · \(MBWriteValue.amount(written.grossValue))"
        return .result(["ok": true, "time_entry": dto.row(written), "employee": dto.row(employee)],
                       activity: [GLAIActivity(kind: existing == nil ? .created : .updated,
                                               symbol: MBWriteSymbol.hours,
                                               title: existing != nil ? MBWriteStrings.hoursUpdated
                                                   : (isBonus ? MBWriteStrings.bonusLogged : MBWriteStrings.hoursLogged),
                                               detail: detail, record: entryRef)],
                       undo: Self.undo(recordID, label: detail, isNew: existing == nil,
                                       before: before, env: env))
    }

    static func timeEntry(_ recordID: String, _ env: MBToolEnvironment) -> TimeEntry? {
        guard let store = env.context() else { return nil }
        return MBRecordLookup.record(.timeEntry, id: recordID, as: TimeEntry.self, in: store)
    }

    static func undo(_ recordID: String, label: String, isNew: Bool, before: MBTimeEntrySnapshot?,
                     env: MBToolEnvironment) -> GLAIUndo {
        let ref = MBWrite.ref(.timeEntry, recordID)
        return MBUndo.entry(ref, title: MBWriteStrings.undoTitle(hours: label), ledger: env.ledger,
                            fingerprint: { timeEntry(recordID, env).map(MBFingerprint.stamp) },
                            dropReason: {
                                guard let entry = timeEntry(recordID, env), entry.paycheck != nil else { return nil }
                                return MBWriteStrings.undoDroppedPaymentRecorded
                            }) {
            guard let store = env.context(), let entry = timeEntry(recordID, env) else { return MBUndo.recordGone }
            if isNew {
                do {
                    try DeletionService.delete([.timeEntry(entry)], in: store, subscription: env.subscription())
                } catch {
                    return MBWrite.revertFailure(error)
                }
                return MBUndo.reverted(.deleted, MBWriteSymbol.hours, MBWriteStrings.deleted(.timeEntry),
                                       detail: label, record: nil)
            }
            guard let before, let employee = entry.employee else { return MBUndo.recordGone }
            do {
                try before.restore(entry, employee: employee, in: store, env: env)
            } catch {
                return MBWrite.revertFailure(error)
            }
            env.ledger.note(recordID, MBFingerprint.stamp(entry))
            return MBUndo.reverted(.updated, MBWriteSymbol.hours, MBWriteStrings.hoursRestored,
                                   detail: label, record: ref)
        }
    }
}

/// A time entry's "before" values, kept as plain values and ids.
@MainActor
struct MBTimeEntrySnapshot {
    let hours: Double
    let amount: Double
    let rate: Double
    let date: Date
    let note: String
    let customerID: String?

    init(_ entry: TimeEntry) {
        hours = entry.hours
        amount = entry.amount
        rate = entry.rateSnapshot
        date = entry.date
        note = entry.note
        customerID = entry.customer?.syncID?.uuidString
    }

    func restore(_ entry: TimeEntry, employee: Employee, in store: ModelContext,
                 env: MBToolEnvironment) throws {
        let customer = customerID.flatMap {
            MBRecordLookup.record(.customer, id: $0, as: Customer.self, in: store)
        }
        if amount > DomainMoney.epsilon, hours <= 0 {
            _ = try EmployeeService.logTime(.dollars(amount, on: date), customer: customer, note: note,
                                            for: employee, editing: entry, in: store,
                                            subscription: env.subscription())
        } else {
            _ = try EmployeeService.logTime(.hours(hours, on: date, rate: rate > 0 ? rate : employee.hourlyRate),
                                            customer: customer, note: note, for: employee, editing: entry,
                                            in: store, subscription: env.subscription())
        }
    }
}

// MARK: - pay_employee

@MainActor
struct MBPayEmployeeTool: GLAITool {
    let entry: GLAIManifest.Tool
    let env: MBToolEnvironment

    var name: String { entry.name }
    var summary: String { entry.summary }
    var parameters: GLAISchema { entry.parameters }
    var area: GLAIToolArea { entry.area }

    func run(_ call: GLAIToolCall, context: GLAIToolContext) async -> GLAIToolOutcome {
        guard context.isStillCurrent, let store = env.context() else { return MBToolFailure.unavailable }
        let args = MBArguments(json: call.arguments)
        let value = MBValue(calendar: env.calendar)

        if let done = env.ledger.recordedPayment(call.idempotencyKey) {
            return .result(done.setting("already_recorded", to: true))
        }
        guard let id = args.string("employee_id"),
              let employee = MBRecordLookup.record(.employee, id: id, as: Employee.self, in: store) else {
            return MBToolFailure.notFound(.employee)
        }
        let recordID = MBIDs.id(employee, env)
        let ref = MBWrite.ref(.employee, recordID)
        let bonus = args.money("bonus") ?? 0
        let amount = args.money("amount") ?? DomainMoney.roundedToCents(employee.accruedGross)
        guard amount + bonus > DomainMoney.epsilon else { return MBToolFailure.domain(.amountRequired, ref) }
        let method = args.raw("method", PaymentMethod.self)
            ?? employee.sortedPaychecks.first?.method
            ?? .check
        let payDate = value.parseDay(args.string("pay_date")) ?? env.calendar.startOfDay(for: env.now())
        let note = args.json["note"]?.stringValue ?? ""
        let name = employee.fullName
        let total = MBWriteValue.amount(amount + bonus)
        let key = call.idempotencyKey

        return .needsConfirmation(GLAIConfirmation(
            recordIDs: [recordID],
            line: MBWriteStrings.confirmPayPerson(amount: total, person: name),
            actionLabel: MBWriteStrings.confirmRecordPaymentAction,
            isDestructive: false,
            declinedMessage: "The user chose not to record that paycheck for \(name).",
            perform: { [env] in
                Self.pay(recordID, amount: amount, bonus: bonus, payDate: payDate, method: method,
                         note: note, key: key, env: env)
            }))
    }

    static func pay(_ recordID: String, amount: Double, bonus: Double, payDate: Date,
                    method: PaymentMethod, note: String, key: String,
                    env: MBToolEnvironment) -> GLAIToolOutcome {
        let ref = MBWrite.ref(.employee, recordID)
        guard let store = env.context(), let employee = MBSaveEmployeeTool.employee(recordID, env) else {
            return MBToolFailure.notFound(.employee)
        }
        if let done = env.ledger.recordedPayment(key) { return .result(done.setting("already_recorded", to: true)) }
        let check: Paycheck
        do {
            check = try EmployeeService.recordPaycheck(for: employee, amount: amount, bonus: bonus,
                                                       payDate: payDate, method: method, note: note,
                                                       in: store, subscription: env.subscription())
        } catch {
            return MBToolFailure.unexpected(error, ref)
        }
        env.ledger.note(recordID, MBFingerprint.stamp(employee))
        let dto = MBRecordDTO(env: env, context: store)
        let output: GLAIJSON = ["ok": true, "paycheck": dto.row(check), "employee": dto.row(employee)]
        env.ledger.notePayment(key, output)
        return .result(output,
                       activity: [GLAIActivity(kind: .recorded, symbol: MBWriteSymbol.paycheck,
                                               title: MBWriteStrings.paycheckRecorded,
                                               detail: "\(employee.fullName) · \(MBWriteValue.amount(check.grossAmount))",
                                               record: MBWrite.ref(.paycheck, MBIDs.id(check, env)))])
    }
}

// MARK: - edit_paycheck

@MainActor
struct MBEditPaycheckTool: GLAITool {
    let entry: GLAIManifest.Tool
    let env: MBToolEnvironment

    var name: String { entry.name }
    var summary: String { entry.summary }
    var parameters: GLAISchema { entry.parameters }
    var area: GLAIToolArea { entry.area }

    func run(_ call: GLAIToolCall, context: GLAIToolContext) async -> GLAIToolOutcome {
        guard context.isStillCurrent, let store = env.context() else { return MBToolFailure.unavailable }
        let args = MBArguments(json: call.arguments)
        let value = MBValue(calendar: env.calendar)
        guard let id = args.string("id"),
              let check = MBRecordLookup.record(.paycheck, id: id, as: Paycheck.self, in: store) else {
            return MBToolFailure.notFound(.paycheck)
        }
        let recordID = MBIDs.id(check, env)
        let ref = MBWrite.ref(.paycheck, recordID)
        let payDate = value.parseDay(args.string("pay_date")) ?? check.payDate
        let gross = args.money("gross_amount") ?? check.grossAmount
        guard gross > DomainMoney.epsilon else { return MBToolFailure.domain(.amountRequired, ref) }
        let method = args.raw("method", PaymentMethod.self) ?? check.method
        let note = args.json["note"]?.stringValue ?? check.note
        let name = check.employee?.fullName ?? ""
        let amountText = MBWriteValue.amount(gross)

        return .needsConfirmation(GLAIConfirmation(
            recordIDs: [recordID],
            line: MBWriteStrings.confirmEditPaycheck(person: name, amount: amountText),
            actionLabel: MBWriteStrings.confirmContinue,
            isDestructive: false,
            declinedMessage: "The user chose not to change that paycheck.",
            perform: { [env] in
                Self.apply(recordID, payDate: payDate, gross: gross, method: method, note: note, env: env)
            }))
    }

    static func apply(_ recordID: String, payDate: Date, gross: Double, method: PaymentMethod,
                      note: String, env: MBToolEnvironment) -> GLAIToolOutcome {
        let ref = MBWrite.ref(.paycheck, recordID)
        guard let store = env.context(),
              let check = MBRecordLookup.record(.paycheck, id: recordID, as: Paycheck.self, in: store) else {
            return MBToolFailure.notFound(.paycheck)
        }
        do {
            try EmployeeService.editPaycheck(check, payDate: payDate, gross: gross, method: method,
                                             note: note, in: store, subscription: env.subscription())
        } catch {
            return MBToolFailure.unexpected(error, ref)
        }
        env.ledger.note(recordID, MBFingerprint.stamp(check))
        let dto = MBRecordDTO(env: env, context: store)
        return .result(["ok": true, "paycheck": dto.row(check)],
                       activity: [GLAIActivity(kind: .updated, symbol: MBWriteSymbol.paycheck,
                                               title: MBWriteStrings.paycheckUpdated,
                                               detail: MBWriteValue.amount(check.grossAmount), record: ref)])
    }
}

// MARK: - save_subcontractor

@MainActor
struct MBSaveSubcontractorTool: GLAITool {
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

        if let id = args.string("id") {
            guard let sub = MBRecordLookup.record(.subcontractor, id: id, as: Subcontractor.self, in: store) else {
                return MBToolFailure.notFound(.subcontractor)
            }
            let recordID = MBIDs.id(sub, env)
            let ref = MBWrite.ref(.subcontractor, recordID)
            let before = SubcontractorDraft(sub)
            let draft = Self.patched(before, args)
            do {
                try SubcontractorService.update(sub, with: draft, in: store, subscription: env.subscription())
            } catch {
                return MBToolFailure.unexpected(error, ref)
            }
            env.ledger.note(recordID, MBFingerprint.stamp(sub))
            return .result(["ok": true, "subcontractor": dto.row(sub)],
                           activity: [GLAIActivity(kind: .updated, symbol: MBWriteSymbol.subcontractor,
                                                   title: MBWriteStrings.subcontractorUpdated,
                                                   detail: sub.fullName, record: ref)],
                           undo: Self.undoEdit(recordID, before: before, env: env))
        }

        let draft = Self.patched(SubcontractorDraft(), args)
        let sub: Subcontractor
        do {
            sub = try SubcontractorService.create(draft, in: store, subscription: env.subscription())
        } catch {
            return MBToolFailure.unexpected(error)
        }
        let recordID = MBIDs.id(sub, env)
        let ref = MBWrite.ref(.subcontractor, recordID)
        env.ledger.note(recordID, MBFingerprint.stamp(sub))
        return .result(["ok": true, "subcontractor": dto.row(sub)],
                       activity: [GLAIActivity(kind: .created, symbol: MBWriteSymbol.subcontractor,
                                               title: MBWriteStrings.subcontractorAdded,
                                               detail: sub.fullName, record: ref)],
                       undo: Self.undoCreate(recordID, name: sub.fullName, env: env))
    }

    /// No tax field is read here on purpose (see the file header).
    static func patched(_ base: SubcontractorDraft, _ args: MBArguments) -> SubcontractorDraft {
        var draft = base
        if let text = args.json["first_name"]?.stringValue { draft.firstName = text }
        if let text = args.json["last_name"]?.stringValue { draft.lastName = text }
        if let text = args.json["business_name"]?.stringValue { draft.businessName = text }
        if let text = args.json["email"]?.stringValue { draft.email = text }
        if let text = args.json["phone"]?.stringValue { draft.phone = text }
        if args.has("hourly_rate") {
            draft.hourlyRate = args.isNull("hourly_rate") ? 0 : (args.number("hourly_rate") ?? draft.hourlyRate)
        }
        draft.address = MBWriteValue.address(draft.address, patch: args.object("address"))
        if let active = args.bool("active") { draft.isActive = active }
        if let notes = args.json["notes"]?.stringValue { draft.notes = notes }
        return draft
    }

    // MARK: Undo

    static func sub(_ recordID: String, _ env: MBToolEnvironment) -> Subcontractor? {
        guard let store = env.context() else { return nil }
        return MBRecordLookup.record(.subcontractor, id: recordID, as: Subcontractor.self, in: store)
    }

    static func undoCreate(_ recordID: String, name: String, env: MBToolEnvironment) -> GLAIUndo {
        let ref = MBWrite.ref(.subcontractor, recordID)
        return MBUndo.entry(ref, title: MBWriteStrings.undoTitle(subcontractor: name), ledger: env.ledger,
                            fingerprint: { sub(recordID, env).map(MBFingerprint.stamp) }) {
            guard let store = env.context(), let person = sub(recordID, env) else { return MBUndo.recordGone }
            guard person.liveRows(person.payments).isEmpty else {
                return .failed(MBWriteStrings.undoKeptHasRecords)
            }
            let label = person.fullName
            do {
                try DeletionService.delete([.subcontractor(person)], in: store, subscription: env.subscription())
            } catch {
                return MBWrite.revertFailure(error)
            }
            return MBUndo.reverted(.deleted, MBWriteSymbol.subcontractor,
                                   MBWriteStrings.deleted(.subcontractor), detail: label, record: nil)
        }
    }

    static func undoEdit(_ recordID: String, before: SubcontractorDraft, env: MBToolEnvironment) -> GLAIUndo {
        let ref = MBWrite.ref(.subcontractor, recordID)
        return MBUndo.entry(ref, title: MBWriteStrings.undoTitle(subcontractor: before.trimmed.firstName),
                            ledger: env.ledger,
                            fingerprint: { sub(recordID, env).map(MBFingerprint.stamp) }) {
            guard let store = env.context(), let person = sub(recordID, env) else { return MBUndo.recordGone }
            do {
                try SubcontractorService.update(person, with: before, in: store, subscription: env.subscription())
            } catch {
                return MBWrite.revertFailure(error)
            }
            env.ledger.note(recordID, MBFingerprint.stamp(person))
            return MBUndo.reverted(.updated, MBWriteSymbol.subcontractor,
                                   MBWriteStrings.subcontractorRestored, detail: person.fullName, record: ref)
        }
    }
}

// MARK: - log_sub_work

@MainActor
struct MBLogSubWorkTool: GLAITool {
    let entry: GLAIManifest.Tool
    let env: MBToolEnvironment

    var name: String { entry.name }
    var summary: String { entry.summary }
    var parameters: GLAISchema { entry.parameters }
    var area: GLAIToolArea { entry.area }

    func run(_ call: GLAIToolCall, context: GLAIToolContext) async -> GLAIToolOutcome {
        guard context.isStillCurrent, let store = env.context() else { return MBToolFailure.unavailable }
        let args = MBArguments(json: call.arguments)
        let value = MBValue(calendar: env.calendar)

        let existing: SubPayment?
        let sub: Subcontractor
        if let id = args.string("id") {
            guard let found = MBRecordLookup.record(.subPayment, id: id, as: SubPayment.self, in: store),
                  let owner = found.subcontractor else { return MBToolFailure.notFound(.subPayment) }
            existing = found
            sub = owner
        } else {
            guard let id = args.string("subcontractor_id"),
                  let owner = MBRecordLookup.record(.subcontractor, id: id, as: Subcontractor.self, in: store) else {
                return MBToolFailure.invalid("A new entry needs subcontractor_id. Use find to get the id.")
            }
            existing = nil
            sub = owner
        }

        let subID = MBIDs.id(sub, env)
        let subRef = MBWrite.ref(.subcontractor, subID)
        let mode = args.string("mode") ?? (existing.map { $0.hours > 0 ? "hours" : "dollars" } ?? "")
        let day = value.parseDay(args.string("date")) ?? existing?.date ?? env.calendar.startOfDay(for: env.now())
        let rate = args.number("rate")
            ?? (existing.flatMap { $0.hours > 0 ? $0.amount / $0.hours : nil })
            ?? sub.hourlyRate
        let detailText = args.json["detail"]?.stringValue ?? existing?.detail ?? ""

        var customer: Customer? = existing?.customer
        if args.has("customer_id") {
            if args.isNull("customer_id") {
                customer = nil
            } else {
                guard let id = args.string("customer_id"),
                      let found = MBRecordLookup.record(.customer, id: id, as: Customer.self, in: store) else {
                    return MBToolFailure.notFound(.customer)
                }
                customer = found
            }
        }

        let work: LoggedWork
        switch mode {
        case "range":
            guard let start = value.parseMoment(args.string("start")),
                  let end = value.parseMoment(args.string("end")) else {
                return MBToolFailure.invalid("range needs start and end as ISO 8601 date-times with an offset.")
            }
            work = .range(start: start, end: end, rate: rate)
        case "hours":
            guard let hours = args.number("hours") ?? existing.map(\.hours) else {
                return MBToolFailure.domain(.hoursAndRateRequired, subRef)
            }
            work = .hours(hours, on: day, rate: rate)
        case "dollars":
            guard let amount = args.money("amount") ?? existing.map(\.amount) else {
                return MBToolFailure.domain(.amountRequired, subRef)
            }
            work = .dollars(amount, on: day)
        default:
            return MBToolFailure.invalid("mode must be hours, range or dollars.")
        }

        let wantsPaid = args.bool("paid") ?? (existing?.isPaid ?? false)
        let paidOn = wantsPaid
            ? (value.parseDay(args.string("paid_date")) ?? existing?.paidDate
               ?? env.calendar.startOfDay(for: env.now()))
            : nil
        let method = args.raw("method", PaymentMethod.self) ?? existing?.method ?? .check
        let existingID = existing.map { MBIDs.id($0, env) }
        let isNew = existing == nil

        // Recording work as already paid is money going out: the person is asked first, and a
        // confirmed write keeps no Undo (contract §5).
        guard wantsPaid else {
            // Unpaid work is a plain edit: freely repeatable, so it carries no payment key.
            return Self.write(subID, existingID: existingID, work: work, detail: detailText,
                              customerID: customer.map { MBIDs.id($0, env) }, paidOn: nil,
                              method: method, isNew: isNew, env: env, keepUndo: true, paymentKey: nil)
        }
        // Logging work as ALREADY PAID is money out, so this step carries the same idempotency key
        // the other three money tools do (contract §4): a re-dispatched step can never pay twice.
        let key = call.idempotencyKey
        if let done = env.ledger.recordedPayment(key) {
            return .result(done.setting("already_recorded", to: true))
        }
        // The amount the ledger will store: hours × rate worked out exactly, rounded once (law 60).
        let amountText = MBWriteValue.amount(work.flatAmount > 0
            ? work.flatAmount : DomainMoney.roundedToCents(DomainMoney.product(work.hours, work.rate)))
        let name = sub.fullName
        let customerID = customer.map { MBIDs.id($0, env) }
        return .needsConfirmation(GLAIConfirmation(
            recordIDs: [subID] + (existingID.map { [$0] } ?? []),
            line: MBWriteStrings.confirmPayPerson(amount: amountText, person: name),
            actionLabel: MBWriteStrings.confirmRecordPaymentAction,
            isDestructive: false,
            declinedMessage: "The user chose not to record that payment to \(name).",
            perform: { [env] in
                Self.write(subID, existingID: existingID, work: work, detail: detailText,
                           customerID: customerID, paidOn: paidOn, method: method, isNew: isNew,
                           env: env, keepUndo: false, paymentKey: key)
            }))
    }

    static func write(_ subID: String, existingID: String?, work: LoggedWork, detail: String,
                      customerID: String?, paidOn: Date?, method: PaymentMethod, isNew: Bool,
                      env: MBToolEnvironment, keepUndo: Bool,
                      paymentKey: String?) -> GLAIToolOutcome {
        let subRef = MBWrite.ref(.subcontractor, subID)
        guard let store = env.context(), let sub = MBSaveSubcontractorTool.sub(subID, env) else {
            return MBToolFailure.notFound(.subcontractor)
        }
        if let paymentKey, let done = env.ledger.recordedPayment(paymentKey) {
            return .result(done.setting("already_recorded", to: true))
        }
        let existing = existingID.flatMap {
            MBRecordLookup.record(.subPayment, id: $0, as: SubPayment.self, in: store)
        }
        let before = existing.map(MBSubEntrySnapshot.init)
        let customer = customerID.flatMap {
            MBRecordLookup.record(.customer, id: $0, as: Customer.self, in: store)
        }
        let written: SubPayment
        do {
            written = try SubcontractorService.recordEntry(work, detail: detail, customer: customer,
                                                           paidOn: paidOn, method: method, for: sub,
                                                           editing: existing, in: store,
                                                           subscription: env.subscription())
        } catch {
            return MBToolFailure.unexpected(error, subRef)
        }
        let recordID = MBIDs.id(written, env)
        let ref = MBWrite.ref(.subPayment, recordID)
        env.ledger.note(recordID, MBFingerprint.stamp(written))
        let dto = MBRecordDTO(env: env, context: store)
        let label = "\(sub.fullName) · \(MBWriteValue.amount(written.amount))"
        let undo = keepUndo ? Self.undo(recordID, label: label, isNew: isNew, before: before, env: env) : nil
        let output: GLAIJSON = ["ok": true, "sub_payment": dto.row(written), "subcontractor": dto.row(sub)]
        if let paymentKey { env.ledger.notePayment(paymentKey, output) }
        return .result(output,
                       activity: [GLAIActivity(kind: isNew ? .created : .updated,
                                               symbol: MBWriteSymbol.subcontractor,
                                               title: isNew ? MBWriteStrings.subWorkLogged
                                                   : MBWriteStrings.subWorkUpdated,
                                               detail: label, record: ref)],
                       undo: undo)
    }

    static func entry(_ recordID: String, _ env: MBToolEnvironment) -> SubPayment? {
        guard let store = env.context() else { return nil }
        return MBRecordLookup.record(.subPayment, id: recordID, as: SubPayment.self, in: store)
    }

    static func undo(_ recordID: String, label: String, isNew: Bool, before: MBSubEntrySnapshot?,
                     env: MBToolEnvironment) -> GLAIUndo {
        let ref = MBWrite.ref(.subPayment, recordID)
        return MBUndo.entry(ref, title: MBWriteStrings.undoTitle(entry: label), ledger: env.ledger,
                            fingerprint: { entry(recordID, env).map(MBFingerprint.stamp) },
                            dropReason: {
                                guard let row = entry(recordID, env), row.isPaid else { return nil }
                                return MBWriteStrings.undoDroppedPaymentRecorded
                            }) {
            guard let store = env.context(), let row = entry(recordID, env) else { return MBUndo.recordGone }
            if isNew {
                do {
                    try DeletionService.delete([.subPayment(row)], in: store, subscription: env.subscription())
                } catch {
                    return MBWrite.revertFailure(error)
                }
                return MBUndo.reverted(.deleted, MBWriteSymbol.subcontractor,
                                       MBWriteStrings.deleted(.subPayment), detail: label, record: nil)
            }
            guard let before, let sub = row.subcontractor else { return MBUndo.recordGone }
            do {
                try before.restore(row, sub: sub, in: store, env: env)
            } catch {
                return MBWrite.revertFailure(error)
            }
            env.ledger.note(recordID, MBFingerprint.stamp(row))
            return MBUndo.reverted(.updated, MBWriteSymbol.subcontractor, MBWriteStrings.subWorkRestored,
                                   detail: label, record: ref)
        }
    }
}

/// A subcontractor ledger entry's "before" values.
@MainActor
struct MBSubEntrySnapshot {
    let amount: Double
    let hours: Double
    let date: Date
    let detail: String
    let paidDate: Date?
    let method: PaymentMethod
    let customerID: String?

    init(_ entry: SubPayment) {
        amount = entry.amount
        hours = entry.hours
        date = entry.date
        detail = entry.detail
        paidDate = entry.paidDate
        method = entry.method
        customerID = entry.customer?.syncID?.uuidString
    }

    func restore(_ entry: SubPayment, sub: Subcontractor, in store: ModelContext,
                 env: MBToolEnvironment) throws {
        let customer = customerID.flatMap {
            MBRecordLookup.record(.customer, id: $0, as: Customer.self, in: store)
        }
        let work: LoggedWork = hours > 0
            ? .hours(hours, on: date, rate: hours > 0 ? amount / hours : 0)
            : .dollars(amount, on: date)
        _ = try SubcontractorService.recordEntry(work, detail: detail, customer: customer, paidOn: paidDate,
                                                 method: method, for: sub, editing: entry, in: store,
                                                 subscription: env.subscription())
    }
}

// MARK: - pay_subcontractor

@MainActor
struct MBPaySubcontractorTool: GLAITool {
    let entry: GLAIManifest.Tool
    let env: MBToolEnvironment

    var name: String { entry.name }
    var summary: String { entry.summary }
    var parameters: GLAISchema { entry.parameters }
    var area: GLAIToolArea { entry.area }

    func run(_ call: GLAIToolCall, context: GLAIToolContext) async -> GLAIToolOutcome {
        guard context.isStillCurrent, let store = env.context() else { return MBToolFailure.unavailable }
        let args = MBArguments(json: call.arguments)
        let value = MBValue(calendar: env.calendar)

        if let done = env.ledger.recordedPayment(call.idempotencyKey) {
            return .result(done.setting("already_recorded", to: true))
        }
        guard let id = args.string("subcontractor_id"),
              let sub = MBRecordLookup.record(.subcontractor, id: id, as: Subcontractor.self, in: store) else {
            return MBToolFailure.notFound(.subcontractor)
        }
        let recordID = MBIDs.id(sub, env)
        let ref = MBWrite.ref(.subcontractor, recordID)
        let amount = args.money("amount") ?? DomainMoney.roundedToCents(sub.outstanding)
        guard amount > DomainMoney.epsilon else { return MBToolFailure.domain(.amountRequired, ref) }
        let method = args.raw("method", PaymentMethod.self) ?? .check
        let paidDate = value.parseDay(args.string("paid_date")) ?? env.calendar.startOfDay(for: env.now())
        let name = sub.fullName
        let amountText = MBWriteValue.amount(amount)
        let key = call.idempotencyKey

        return .needsConfirmation(GLAIConfirmation(
            recordIDs: [recordID],
            line: MBWriteStrings.confirmPayPerson(amount: amountText, person: name),
            actionLabel: MBWriteStrings.confirmRecordPaymentAction,
            isDestructive: false,
            declinedMessage: "The user chose not to pay \(name).",
            perform: { [env] in
                Self.pay(recordID, amount: amount, paidDate: paidDate, method: method, key: key, env: env)
            }))
    }

    static func pay(_ recordID: String, amount: Double, paidDate: Date, method: PaymentMethod,
                    key: String, env: MBToolEnvironment) -> GLAIToolOutcome {
        let ref = MBWrite.ref(.subcontractor, recordID)
        guard let store = env.context(), let sub = MBSaveSubcontractorTool.sub(recordID, env) else {
            return MBToolFailure.notFound(.subcontractor)
        }
        if let done = env.ledger.recordedPayment(key) { return .result(done.setting("already_recorded", to: true)) }
        let rows: [SubPayment]
        do {
            rows = try SubcontractorService.payNow(amount, paidDate: paidDate, method: method, for: sub,
                                                   in: store, subscription: env.subscription())
        } catch {
            return MBToolFailure.unexpected(error, ref)
        }
        env.ledger.note(recordID, MBFingerprint.stamp(sub))
        let dto = MBRecordDTO(env: env, context: store)
        let output: GLAIJSON = [
            "ok": true,
            "subcontractor": dto.row(sub),
            "entries_paid": .array(rows.map { dto.row($0) }),
        ]
        env.ledger.notePayment(key, output)
        return .result(output,
                       activity: [GLAIActivity(kind: .recorded, symbol: MBWriteSymbol.payment,
                                               title: MBWriteStrings.subPaid,
                                               detail: "\(sub.fullName) · \(MBWriteValue.amount(amount))",
                                               record: ref)])
    }
}
