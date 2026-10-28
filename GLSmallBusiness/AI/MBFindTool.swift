//
//  MBFindTool.swift
//  GLSmallBusiness — AI
//
//  `find`: search any record kind and return compact rows with ids (contract §5). Filters are the
//  app's own: the lists' `matchesSearch` rules (the Jobs, Receipts and Price Sheet screens'
//  searches included) through the one matcher, `RecordSearch.matches` — every word of the query
//  in some field, so "John Smith" finds a first and last name — statuses as the screens derive
//  them (paid / overdue / expired are never stored), and the date each list sorts by. Newest
//  first, people by name.
//
//  Online: up to 50 rows (default 10) in ≤ 8 KB, `truncated: true` when rows had to go.
//  On device (`outputCharacterLimit` set): up to 5 rows, the fewest fields, ≤ 1,200 characters.
//

import Foundation
import SwiftData
import GoldLifeAI

@MainActor
struct MBFindTool: GLAIReadOnlyTool {
    let entry: GLAIManifest.Tool
    let env: MBToolEnvironment

    var name: String { entry.name }
    var summary: String { entry.summary }
    var parameters: GLAISchema { entry.parameters }
    var area: GLAIToolArea { entry.area }

    static let defaultLimit = 10
    static let maxLimit = 50
    static let onDeviceLimit = 5

    /// Which statuses fit which kind (the manifest's `status` description).
    static let statuses: [MBRecordKind: Set<String>] = [
        .estimate: ["draft", "sent", "accepted", "declined", "expired"],
        .contract: ["draft", "signed", "inProgress", "completed"],
        .invoice: ["draft", "sent", "unpaid", "partiallyPaid", "paid", "overdue"],
        .changeOrder: ["pending", "approved", "declined"],
        .job: ["scheduled", "inProgress", "completed"],
        .employee: ["active", "inactive"],
        .subcontractor: ["active", "inactive"],
        .timeEntry: ["owed", "paid"],
        .subPayment: ["owed", "paid"],
    ]

    func run(_ call: GLAIToolCall, context: GLAIToolContext) async -> GLAIToolOutcome {
        guard context.isStillCurrent, let store = env.context() else { return MBToolFailure.unavailable }
        let args = MBArguments(json: call.arguments)
        guard let kindName = args.string("kind"), let kind = MBRecordKind(rawValue: kindName), !kind.isSingleton else {
            return MBToolFailure.invalid("kind must be one of the record kinds; use get for business, work_schedule or app_settings.")
        }
        let v = MBValue(calendar: env.calendar)
        let onDevice = context.outputCharacterLimit != nil

        var filter = Filter(query: args.string("query"))
        if let status = args.string("status") {
            guard Self.statuses[kind]?.contains(status) == true else {
                return MBToolFailure.invalid("status \(status) doesn't fit kind \(kind.rawValue).")
            }
            filter.status = status
        }
        if let text = args.string("date_from") {
            guard let date = v.parseDay(text) else { return MBToolFailure.invalid("date_from must be YYYY-MM-DD.") }
            filter.from = date
        }
        if let text = args.string("date_to") {
            guard let date = v.parseDay(text) else { return MBToolFailure.invalid("date_to must be YYYY-MM-DD.") }
            filter.to = date
        }
        if let id = args.string("customer_id") {
            guard let customer = MBRecordLookup.record(.customer, id: id, as: Customer.self, in: store) else {
                return MBToolFailure.notFound(.customer)
            }
            filter.customer = customer
        }
        if let id = args.string("job_id") {
            guard let job = MBRecordLookup.record(.job, id: id, as: ScheduledJob.self, in: store) else {
                return MBToolFailure.notFound(.job)
            }
            filter.job = job
        }
        if let id = args.string("person_id") {
            if let employee = MBRecordLookup.record(.employee, id: id, as: Employee.self, in: store) {
                filter.employee = employee
            } else if let sub = MBRecordLookup.record(.subcontractor, id: id, as: Subcontractor.self, in: store) {
                filter.subcontractor = sub
            } else {
                return MBToolFailure.invalid("person_id is not an employee or subcontractor id. Use find to get it.")
            }
        }

        let requested = args.int("limit") ?? Self.defaultLimit
        let limit = onDevice ? min(max(1, requested), Self.onDeviceLimit) : min(max(1, requested), Self.maxLimit)
        let dto = MBRecordDTO(env: env, context: store)
        let matches = rows(kind, filter: filter, store: store, dto: dto, limit: limit)

        var output: [String: GLAIJSON] = [
            "kind": .string(kind.rawValue),
            "count": v.int(matches.total),
            "results": .array(onDevice ? matches.rows.map(Self.compact) : matches.rows),
        ]
        if matches.total > matches.rows.count { output["more"] = v.int(matches.total - matches.rows.count) }
        return .result(MBOutputFit.fit(output, trimming: ["results"], budget: MBOutputFit.budget(context)))
    }

    /// On device: only the fields a short spoken answer needs.
    static func compact(_ row: GLAIJSON) -> GLAIJSON {
        guard case .object(let object) = row else { return row }
        let keep: Set<String> = ["id", "number", "title", "name", "vendor", "status", "total", "balance_due",
                                 "owes", "owed", "date", "start_date", "amount", "paid", "unit_price"]
        var out = object.filter { keep.contains($0.key) && $0.value != .null }
        if let customer = object["customer"]?["name"] { out["customer"] = customer }
        return .object(out)
    }

    // MARK: - Filtering

    struct Filter {
        var query: String?
        var status: String?
        var from: Date?
        var to: Date?
        var customer: Customer?
        var job: ScheduledJob?
        var employee: Employee?
        var subcontractor: Subcontractor?

        var hasRange: Bool { from != nil || to != nil }

        func inRange(_ date: Date, calendar: Calendar) -> Bool {
            guard hasRange else { return true }
            let lo = from ?? .distantPast
            let hi = to.flatMap { calendar.date(byAdding: .day, value: 1, to: $0) } ?? .distantFuture
            return date >= lo && date < hi
        }

        /// The query against fields a kind has no `matchesSearch` for — the same one matcher.
        func matches(_ fields: [String]) -> Bool {
            RecordSearch.matches(query ?? "", in: fields)
        }

        func sameCustomer(_ other: Customer?) -> Bool {
            guard let customer else { return true }
            return other?.persistentModelID == customer.persistentModelID
        }

        func sameJob(_ other: ScheduledJob?) -> Bool {
            guard let job else { return true }
            return other?.persistentModelID == job.persistentModelID
        }
    }

    private func rows(_ kind: MBRecordKind, filter f: Filter, store: ModelContext, dto: MBRecordDTO,
                      limit: Int) -> (rows: [GLAIJSON], total: Int) {
        let cal = env.calendar
        func take<T>(_ items: [T], _ row: (T) -> GLAIJSON) -> (rows: [GLAIJSON], total: Int) {
            (items.prefix(limit).map(row), items.count)
        }
        switch kind {
        case .customer:
            let items = MBRecordLookup.all(Customer.self, in: store)
                // The Customers list's fields, plus the office phone.
                .filter { f.matches($0.searchFields + [$0.officePhone]) && f.inRange($0.createdAt, calendar: cal) }
                .filter { f.customer == nil || f.sameCustomer($0) }
                .sorted { $0.listDisplayName.localizedCaseInsensitiveCompare($1.listDisplayName) == .orderedAscending }
            return take(items, dto.row)

        case .estimate:
            let items = MBRecordLookup.all(Estimate.self, in: store)
                .filter { e in
                    e.matchesSearch(f.query ?? "") && f.sameCustomer(e.customer) && f.inRange(e.createdAt, calendar: cal)
                        && (f.job == nil || e.liveRows(e.scheduledJobs).contains { f.sameJob($0) })
                        && (f.status.map { dto.estimateStatus(e) == $0 } ?? true)
                }
                .sorted { $0.createdAt > $1.createdAt }
            return take(items, dto.row)

        case .contract:
            let items = MBRecordLookup.all(Contract.self, in: store)
                .filter { c in
                    c.matchesSearch(f.query ?? "") && f.sameCustomer(c.customer) && f.inRange(c.createdAt, calendar: cal)
                        && (f.job == nil || f.sameJob(c.scheduledJob))
                        && (f.status.map { c.status.rawValue == $0 } ?? true)
                }
                .sorted { $0.createdAt > $1.createdAt }
            return take(items, dto.row)

        case .invoice:
            let items = MBRecordLookup.all(Invoice.self, in: store)
                .filter { i in
                    i.matchesSearch(f.query ?? "") && f.sameCustomer(i.customer) && f.inRange(i.createdAt, calendar: cal)
                        && (f.job == nil || f.sameJob(i.job) || i.liveRows(i.scheduledJobs).contains { f.sameJob($0) })
                        && (f.status.map { Self.invoice(i, is: $0, dto: dto) } ?? true)
                }
                .sorted { $0.createdAt > $1.createdAt }
            return take(items, dto.row)

        case .changeOrder:
            let items = MBRecordLookup.all(ChangeOrder.self, in: store)
                .filter { c in
                    c.matchesSearch(f.query ?? "") && f.sameCustomer(c.invoice?.customer ?? c.contract?.customer)
                        && (f.job == nil || f.sameJob(c.invoice?.job ?? c.contract?.scheduledJob)) && f.inRange(c.createdAt, calendar: cal)
                        && (f.status.map { c.status.rawValue == $0 } ?? true)
                }
                .sorted { $0.createdAt > $1.createdAt }
            return take(items, dto.row)

        case .job:
            let jobs = MBRecordLookup.all(ScheduledJob.self, in: store)
                .filter { j in
                    // The Jobs screen's search: title or customer name.
                    j.matchesSearch(f.query ?? "") && f.sameCustomer(j.customer)
                        && (f.job == nil || f.sameJob(j))
                        && (f.status.map { j.status.rawValue == $0 } ?? true)
                        && (!f.hasRange || occupies(j, f, schedule: dto.schedule))
                }
                .sorted { $0.startDate > $1.startDate }
            return take(jobs, dto.row)

        case .receipt:
            let items = MBRecordLookup.all(Receipt.self, in: store)
                .filter { r in
                    // The Receipts screen's search: vendor, category, notes, customer.
                    r.matchesSearch(f.query ?? "")
                        && f.sameCustomer(r.customer) && (f.job == nil || f.sameJob(r.job))
                        && f.inRange(r.date, calendar: cal)
                }
                .sorted { $0.date > $1.date }
            return take(items, dto.row)

        case .priceItem:
            let items = PriceSheetService.search(MBRecordLookup.all(PriceSheetItem.self, in: store), query: f.query ?? "")
                .filter { f.inRange($0.createdAt, calendar: cal) }
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            return take(items, dto.row)

        case .employee:
            let items = MBRecordLookup.all(Employee.self, in: store)
                .filter { e in
                    e.matchesSearch(f.query ?? "") && f.inRange(e.createdAt, calendar: cal)
                        && (f.employee == nil || e.persistentModelID == f.employee?.persistentModelID)
                        && (f.status.map { ($0 == "active") == e.isActive } ?? true)
                }
                .sorted { $0.listDisplayName.localizedCaseInsensitiveCompare($1.listDisplayName) == .orderedAscending }
            return take(items, dto.row)

        case .subcontractor:
            let items = MBRecordLookup.all(Subcontractor.self, in: store)
                .filter { s in
                    s.matchesSearch(f.query ?? "") && f.inRange(s.createdAt, calendar: cal)
                        && (f.subcontractor == nil || s.persistentModelID == f.subcontractor?.persistentModelID)
                        && (f.status.map { ($0 == "active") == s.isActive } ?? true)
                }
                .sorted { $0.listDisplayName.localizedCaseInsensitiveCompare($1.listDisplayName) == .orderedAscending }
            return take(items, dto.row)

        case .project:
            let items = MBRecordLookup.all(Project.self, in: store)
                .filter { p in
                    f.matches([p.displayName, p.customer?.listDisplayName ?? ""]) && f.sameCustomer(p.customer)
                        && (f.job == nil || p.sortedJobs.contains { f.sameJob($0) }) && f.inRange(p.createdAt, calendar: cal)
                }
                .sorted { $0.createdAt > $1.createdAt }
            return take(items, dto.row)

        case .payment:
            let items = MBRecordLookup.all(InvoicePayment.self, in: store)
                .filter { p in
                    guard let invoice = p.invoice, !invoice.isDeleted else { return false }
                    return f.matches([invoice.number, invoice.customerDisplayName, p.method.label, p.note])
                        && f.sameCustomer(invoice.customer) && (f.job == nil || f.sameJob(invoice.job))
                        && f.inRange(p.date, calendar: cal)
                }
                .sorted { $0.date > $1.date }
            return take(items, dto.row)

        case .timeEntry:
            let items = MBRecordLookup.all(TimeEntry.self, in: store)
                .filter { t in
                    t.employee != nil && t.matchesSearch(f.query ?? "") && f.sameCustomer(t.customer)
                        && (f.employee == nil || t.employee?.persistentModelID == f.employee?.persistentModelID)
                        && f.subcontractor == nil
                        && (f.status.map { ($0 == "paid") == (t.paycheck != nil) } ?? true)
                        && f.inRange(t.date, calendar: cal)
                }
                .sorted { $0.date > $1.date }
            return take(items, dto.row)

        case .paycheck:
            let items = MBRecordLookup.all(Paycheck.self, in: store)
                .filter { p in
                    p.employee != nil && p.matchesSearch(f.query ?? "")
                        && (f.employee == nil || p.employee?.persistentModelID == f.employee?.persistentModelID)
                        && f.subcontractor == nil && f.inRange(p.payDate, calendar: cal)
                }
                .sorted { $0.payDate > $1.payDate }
            return take(items, dto.row)

        case .subPayment:
            let items = MBRecordLookup.all(SubPayment.self, in: store)
                .filter { s in
                    s.subcontractor != nil && s.matchesSearch(f.query ?? "") && f.sameCustomer(s.customer)
                        && (f.subcontractor == nil || s.subcontractor?.persistentModelID == f.subcontractor?.persistentModelID)
                        && f.employee == nil
                        && (f.status.map { ($0 == "paid") == s.isPaid } ?? true)
                        && f.inRange(s.date, calendar: cal)
                }
                .sorted { $0.date > $1.date }
            return take(items, dto.row)

        case .attachment:
            let items = MBRecordLookup.all(JobAttachment.self, in: store)
                .filter { a in
                    (a.job != nil || a.invoice != nil || a.contract != nil) && f.matches([a.name, a.caption])
                        && (f.job == nil || f.sameJob(a.job))
                        && (f.customer == nil || f.sameCustomer(a.job?.customer ?? a.invoice?.customer ?? a.contract?.customer))
                        && f.inRange(a.createdAt, calendar: cal)
                }
                .sorted { $0.createdAt > $1.createdAt }
            return take(items, dto.row)

        case .document:
            let items = MBRecordLookup.all(CustomerDocument.self, in: store)
                .filter { d in
                    d.customer != nil && f.matches([d.name]) && f.sameCustomer(d.customer)
                        && f.inRange(d.createdAt, calendar: cal)
                }
                .sorted { $0.createdAt > $1.createdAt }
            return take(items, dto.row)

        case .business, .workSchedule, .appSettings, .goldLifeID, .deviceInfo:
            return ([], 0)
        }
    }

    /// Paid, overdue and partially paid are derived; "unpaid" is the Invoices screen's "Owed to
    /// you" rule (anything not paid); "sent" is sent and still open.
    static func invoice(_ invoice: Invoice, is status: String, dto: MBRecordDTO) -> Bool {
        switch status {
        case "unpaid": return !invoice.isPaid && invoice.balanceDue > DomainMoney.epsilon
        case "sent": return invoice.status == .sent && !invoice.isPaid
        case "draft": return invoice.status == .draft && !invoice.isPaid
        default: return dto.invoiceStatus(invoice) == status
        }
    }

    /// True when the job (or one of its repeats) is on any day of the range.
    private func occupies(_ job: ScheduledJob, _ f: Filter, schedule: WorkSchedule) -> Bool {
        let cal = env.calendar
        let start = f.from ?? cal.startOfDay(for: env.now())
        let endDay = f.to ?? start
        guard let end = cal.date(byAdding: .day, value: 1, to: max(start, endDay)) else { return false }
        // Occurrences are expanded from 120 days back so a long job that began earlier still counts.
        let expandFrom = cal.date(byAdding: .day, value: -JobScheduling.lookbackDays, to: start) ?? start
        let range = DateInterval(start: expandFrom, end: end)
        return SchedulingEngine.expand([job], in: range, calendar: cal).contains { occurrence in
            occurrence.occupiedDays(schedule: schedule, calendar: cal).contains { $0 >= start && $0 < end }
        }
    }
}
