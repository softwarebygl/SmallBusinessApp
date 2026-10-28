//
//  MBReportTool.swift
//  GLSmallBusiness — AI
//
//  `report`: summary answers from live numbers, computed by the SAME code the screens use — the
//  model never adds anything up itself (contract §3, §5):
//    money_summary        StatsEngine (the Statistics screen), over any span of days, plus payroll
//                         and subcontractor pay (which the screen's net leaves out) listed apart
//    owed_to_me           the Invoices screen's "Owed to you" (every invoice not yet paid)
//    i_owe                employees' accrued pay, subcontractors' owed work
//    schedule             ScheduleQueries' days → jobs, repeats expanded, with workdays
//    openings             ScheduleQueries' openings / next available / next clear date
//    expiring_documents   GLCertificateStatus over every certificate, exemption and license
//    estimate_pipeline    open / accepted / declined / expired, and the win rate
//    job_profit           the job's billing roll-ups minus the costs tied to it (approximate, says why)
//    payments_setup       derived booleans only — never the account
//    card_payment_status  the card link's status from the card-payments Worker (a read)
//    backup_status        when this device last backed up, and whether the backup is paused
//

import Foundation
import SwiftData
import GoldLifeAI

@MainActor
struct MBReportTool: GLAIReadOnlyTool {
    let entry: GLAIManifest.Tool
    let env: MBToolEnvironment

    var name: String { entry.name }
    var summary: String { entry.summary }
    var parameters: GLAISchema { entry.parameters }
    var area: GLAIToolArea { entry.area }

    /// The longest schedule a report walks, in days.
    static let maxScheduleDays = 62
    static let onDeviceRows = 5

    func run(_ call: GLAIToolCall, context: GLAIToolContext) async -> GLAIToolOutcome {
        guard context.isStillCurrent, let store = env.context() else { return MBToolFailure.unavailable }
        let args = MBArguments(json: call.arguments)
        let v = MBValue(calendar: env.calendar)
        var from: Date?
        var to: Date?
        if let text = args.string("date_from") {
            guard let date = v.parseDay(text) else { return MBToolFailure.invalid("date_from must be YYYY-MM-DD.") }
            from = date
        }
        if let text = args.string("date_to") {
            guard let date = v.parseDay(text) else { return MBToolFailure.invalid("date_to must be YYYY-MM-DD.") }
            to = date
        }
        let dto = MBRecordDTO(env: env, context: store)
        let query = args.string("query")
        let onDevice = context.outputCharacterLimit != nil

        let output: [String: GLAIJSON]
        let trim: [String]
        switch args.string("kind") ?? "" {
        case "money_summary": output = moneySummary(store, from: from, to: to, query: query, v: v); trim = ["expenses_by_category"]
        case "owed_to_me": output = owedToMe(store, dto: dto, v: v); trim = ["customers"]
        case "i_owe": output = iOwe(store, dto: dto, v: v); trim = ["subcontractors", "employees"]
        case "schedule": output = scheduleReport(store, from: from, to: to, dto: dto, v: v); trim = ["days"]
        case "openings": output = openings(store, from: from, dto: dto, v: v); trim = ["openings"]
        case "expiring_documents": output = expiring(store, to: to, dto: dto, v: v); trim = ["documents"]
        case "estimate_pipeline": output = pipeline(store, from: from, to: to, dto: dto, v: v); trim = ["open_estimates"]
        case "job_profit":
            guard let job = MBRecordLookup.record(.job, id: args.string("id"), as: ScheduledJob.self, in: store) else {
                return args.string("id") == nil ? MBToolFailure.invalid("job_profit needs the job's id.") : MBToolFailure.notFound(.job)
            }
            output = jobProfit(job, dto: dto, v: v); trim = []
        case "payments_setup": output = paymentsSetup(store); trim = []
        case "card_payment_status":
            guard let invoice = MBRecordLookup.record(.invoice, id: args.string("id"), as: Invoice.self, in: store) else {
                return args.string("id") == nil ? MBToolFailure.invalid("card_payment_status needs the invoice's id.") : MBToolFailure.notFound(.invoice)
            }
            output = await cardPaymentStatus(invoice, dto: dto, v: v)
            trim = []
            // The store may have gone while the Worker answered: nothing below reads it again.
        case "backup_status": output = backupStatus(store, v: v); trim = []
        default:
            return MBToolFailure.invalid("kind must be one of the listed reports.")
        }
        var object = output
        object["report"] = .string(args.string("kind") ?? "")
        if onDevice { object = Self.capLists(object, keys: trim, to: Self.onDeviceRows) }
        return .result(MBOutputFit.fit(object, trimming: trim, budget: MBOutputFit.budget(context)))
    }

    /// On device: the top rows of each list plus how many more ("top 5 + totals + more: n").
    static func capLists(_ object: [String: GLAIJSON], keys: [String], to count: Int) -> [String: GLAIJSON] {
        var out = object
        for key in keys {
            guard let array = object[key]?.arrayValue, array.count > count else { continue }
            out[key] = .array(Array(array.prefix(count)))
            out["more_\(key)"] = .number(Double(array.count - count))
        }
        return out
    }

    // MARK: - Money

    private func moneySummary(_ store: ModelContext, from: Date?, to: Date?, query: String?, v: MBValue) -> [String: GLAIJSON] {
        let cal = env.calendar
        let today = cal.startOfDay(for: env.now())
        // No period given: this year so far.
        let start = from ?? cal.date(from: cal.dateComponents([.year], from: today)) ?? today
        let end = to ?? (from == nil ? today : start)
        let period = StatsPeriod.days(from: start, to: end)
        let invoices = MBRecordLookup.all(Invoice.self, in: store)
        let receipts = MBRecordLookup.all(Receipt.self, in: store)
        let summary = StatsEngine.summary(period: period, invoices: invoices,
                                          estimates: MBRecordLookup.all(Estimate.self, in: store),
                                          receipts: receipts, calendar: cal)
        // Each paycheck and sub payment as it shows (whole cents, law 60), added up.
        let payroll = DomainMoney.roundedSum(MBRecordLookup.all(Paycheck.self, in: store)
            .filter { period.contains($0.payDate, calendar: cal) }.map(\.grossAmount))
        let subs = DomainMoney.roundedSum(MBRecordLookup.all(SubPayment.self, in: store)
            .filter { $0.isPaid && period.contains($0.paidDate ?? $0.date, calendar: cal) }.map(\.amount))
        var output: [String: GLAIJSON] = [
            "from": v.day(min(start, end)),
            "to": v.day(max(start, end)),
            "collected": v.money(summary.collected),
            "expenses": v.money(summary.expenses),
            "processing_fees": v.money(summary.processingFees),
            "net": v.money(summary.net),
            "payroll_paid": v.money(payroll),
            "subcontractors_paid": v.money(subs),
            "invoiced": v.money(summary.invoiced),
            "sales_tax": v.money(summary.salesTax),
            "invoice_count": v.int(summary.invoiceCount),
            "still_owed_on_these_invoices": v.money(summary.outstanding),
            "overdue_count": v.int(summary.overdueCount),
            "estimates": [
                "count": v.int(summary.estimatesTotal),
                "quoted": v.money(summary.estimatesQuoted),
                "accepted": v.int(summary.estimatesAccepted),
                "declined": v.int(summary.estimatesDeclined),
                "pending": v.int(summary.estimatesPending),
                "win_rate_percent": summary.winRate.map { v.number($0 * 100) } ?? .null,
            ],
            "expenses_by_category": .array(summary.expensesByCategory.prefix(12).map {
                ["category": v.text($0.category, limit: 60), "amount": v.money($0.amount)]
            }),
            "how": "collected = payments dated in the period; expenses = receipts dated in the period; net = collected - expenses - processing fees. Payroll and subcontractor pay are listed separately and are not in net. Invoiced, sales tax and still owed count invoices created in the period.",
        ]
        if let query {
            let matching = receipts.filter {
                period.contains($0.date, calendar: cal)
                    && RecordSearch.matches(query, in: [$0.category, $0.vendor])
            }
            output["expenses_matching"] = ["words": v.text(query, limit: 60),
                                           "amount": v.money(DomainMoney.roundedSum(matching.map(\.total))),
                                           "receipts": v.int(matching.count)]
        }
        return output
    }

    private func owedToMe(_ store: ModelContext, dto: MBRecordDTO, v: MBValue) -> [String: GLAIJSON] {
        let unpaid = MBRecordLookup.all(Invoice.self, in: store).filter { !$0.isPaid && $0.balanceDue > DomainMoney.epsilon }
        var groups: [PersistentIdentifier?: [Invoice]] = [:]
        for invoice in unpaid { groups[invoice.customer?.persistentModelID, default: []].append(invoice) }
        let customers = groups.values
            .map { invoices -> (Double, GLAIJSON) in
                let owed = DomainMoney.roundedSum(invoices.map(\.balanceDue))
                let sorted = invoices.sorted { $0.dueDate < $1.dueDate }
                let customer = invoices.first?.customer
                return (owed, [
                    "customer": dto.ref(customer),
                    "customer_name": v.text(customer?.listDisplayName ?? invoices.first?.customerDisplayName ?? "", limit: 120),
                    "owes": v.money(owed),
                    "invoices": .array(sorted.prefix(6).map { invoice -> GLAIJSON in
                        ["id": .string(MBIDs.id(invoice, env)), "number": .string(invoice.number),
                         "balance_due": v.money(invoice.balanceDue), "due_date": v.day(invoice.dueDate),
                         "status": .string(dto.invoiceStatus(invoice))]
                    }),
                ])
            }
            .sorted { $0.0 > $1.0 }
        return [
            "total_owed": v.money(DomainMoney.roundedSum(unpaid.map(\.balanceDue))),
            "invoice_count": v.int(unpaid.count),
            "overdue_total": v.money(DomainMoney.roundedSum(unpaid.filter(\.isOverdue).map(\.balanceDue))),
            "customers": .array(customers.map(\.1)),
        ]
    }

    private func iOwe(_ store: ModelContext, dto: MBRecordDTO, v: MBValue) -> [String: GLAIJSON] {
        let now = env.now()
        let employees = MBRecordLookup.all(Employee.self, in: store)
            .filter { $0.accruedGross > DomainMoney.epsilon }
            .sorted { $0.accruedGross > $1.accruedGross }
        let subs = MBRecordLookup.all(Subcontractor.self, in: store)
            .filter(\.hasOutstanding)
            .sorted { $0.outstanding > $1.outstanding }
        let payroll = DomainMoney.roundedSum(employees.map(\.accruedGross))
        let subTotal = DomainMoney.roundedSum(subs.map(\.outstanding))
        return [
            "total": v.money(DomainMoney.roundedSum([payroll, subTotal])),
            "payroll_total": v.money(payroll),
            "subcontractors_total": v.money(subTotal),
            "employees": .array(employees.map { employee -> GLAIJSON in
                [
                    "employee": dto.ref(employee),
                    "owed": v.money(employee.accruedGross),
                    "unpaid_hours": v.number(employee.unpaidHours),
                    "next_payday": v.day(employee.nextPayday(onOrAfter: now)),
                    "past_due": .bool(employee.owedStatus == .pastDue),
                ]
            }),
            "subcontractors": .array(subs.map { sub -> GLAIJSON in
                ["subcontractor": dto.ref(sub), "owed": v.money(sub.outstanding), "past_due": .bool(sub.owedStatus == .pastDue)]
            }),
        ]
    }

    // MARK: - Schedule

    private func scheduleReport(_ store: ModelContext, from: Date?, to: Date?, dto: MBRecordDTO, v: MBValue) -> [String: GLAIJSON] {
        let cal = env.calendar
        let start = from ?? cal.startOfDay(for: env.now())
        let requestedEnd = to ?? cal.date(byAdding: .day, value: 6, to: start) ?? start
        let lastAllowed = cal.date(byAdding: .day, value: Self.maxScheduleDays - 1, to: start) ?? start
        let end = min(max(requestedEnd, start), lastAllowed)
        let endExclusive = cal.date(byAdding: .day, value: 1, to: end) ?? end
        let expandFrom = cal.date(byAdding: .day, value: -JobScheduling.lookbackDays, to: start) ?? start
        let range = DateInterval(start: expandFrom, end: endExclusive)

        // day → [(sort time, entry)]; each occurrence names its stored series.
        var byDay: [Date: [(Date, GLAIJSON)]] = [:]
        for job in MBRecordLookup.all(ScheduledJob.self, in: store) {
            let id = MBIDs.id(job, env)
            for occurrence in SchedulingEngine.expand([job], in: range, calendar: cal) {
                for day in occurrence.occupiedDays(schedule: dto.schedule, calendar: cal) where day >= start && day < endExclusive {
                    let timed = !occurrence.isAllDay && occurrence.startTime != nil
                    var item: [String: GLAIJSON] = [
                        "id": .string(id),
                        "title": v.text(job.displayTitle, limit: 100),
                        "customer_name": v.text(job.customerName, limit: 80),
                        "status": .string(job.status.rawValue),
                        "all_day": .bool(!timed),
                    ]
                    if timed, let startTime = occurrence.startTime {
                        item["start_time"] = v.clock(startTime)
                        if let minutes = occurrence.durationMinutes, minutes > 0 {
                            item["end_time"] = v.clock(startTime.addingTimeInterval(TimeInterval(minutes * 60)))
                        }
                    }
                    byDay[day, default: []].append((timed ? occurrence.startTime ?? day : day, .object(item)))
                }
            }
        }
        var days: [GLAIJSON] = []
        var day = start
        while day < endExclusive {
            let jobs = (byDay[day] ?? []).sorted { $0.0 < $1.0 }.map(\.1)
            let workday = WorkCalendar.isWorkday(day, schedule: dto.schedule, calendar: cal)
            var entry: [String: GLAIJSON] = ["date": v.day(day), "workday": .bool(workday), "jobs": .array(jobs)]
            if workday, let hours = WorkCalendar.workingHours(day, schedule: dto.schedule, calendar: cal).first {
                entry["hours"] = .string("\(v.clock(hours.start).stringValue ?? "")-\(v.clock(hours.end).stringValue ?? "")")
            }
            days.append(.object(entry))
            guard let next = cal.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        var output: [String: GLAIJSON] = [
            "from": v.day(start), "to": v.day(end),
            "job_days": v.int(byDay.values.reduce(0) { $0 + $1.count }),
            "days": .array(days),
        ]
        if requestedEnd > lastAllowed { output["note"] = .string("Only \(Self.maxScheduleDays) days at a time; ask again from the next day.") }
        return output
    }

    private func openings(_ store: ModelContext, from: Date?, dto: MBRecordDTO, v: MBValue) -> [String: GLAIJSON] {
        let cal = env.calendar
        let now = env.now()
        let start = from.map { max($0, cal.startOfDay(for: now)) } ?? now
        let expanded = ScheduleQueries.expandedJobs(in: store, now: now, calendar: cal)
        let list = ScheduleQueries.openings(expanded, schedule: dto.schedule, from: start, calendar: cal)
        let rows = list.prefix(20).map { opening -> GLAIJSON in
            if let window = opening.window {
                return ["type": "time_window", "date": v.day(window.start), "start_time": v.clock(window.start),
                        "end_time": v.clock(window.end), "minutes": v.int(Int(window.duration / 60))]
            }
            return ["type": "full_days", "start": v.day(opening.start), "end": v.day(opening.end),
                    "workdays": v.int(opening.workdays)]
        }
        return [
            "from": v.day(start),
            "next_available": v.day(ScheduleQueries.nextAvailable(expanded, schedule: dto.schedule, from: start, calendar: cal)),
            "next_clear_date": v.day(ScheduleQueries.clearDate(expanded, schedule: dto.schedule, from: start, calendar: cal)),
            "open_ended_repeats": .bool(ScheduleQueries.hasOpenEndedRecurrence(MBRecordLookup.all(ScheduledJob.self, in: store))),
            "openings": .array(rows),
        ]
    }

    // MARK: - Documents and estimates

    private func expiring(_ store: ModelContext, to: Date?, dto: MBRecordDTO, v: MBValue) -> [String: GLAIJSON] {
        let cal = env.calendar
        let today = cal.startOfDay(for: env.now())
        let horizon = to ?? cal.date(byAdding: .day, value: GLCertificateStatus.warningWindowDays, to: today) ?? today
        var found: [(Date, GLAIJSON)] = []
        var undated = 0
        func consider(_ document: String, onFile: Bool, expires: Date?, owner: GLAIJSON, ownerName: String) {
            guard onFile else { return }
            guard let expires else { undated += 1; return }
            guard expires <= horizon || GLCertificateStatus.isExpired(expires) else { return }
            found.append((expires, [
                "document": .string(document), "owner": owner, "owner_name": v.text(ownerName, limit: 120),
                "expires_on": v.day(expires), "expired": .bool(GLCertificateStatus.isExpired(expires)),
            ]))
        }
        for customer in MBRecordLookup.all(Customer.self, in: store) {
            consider("customer_coi", onFile: customer.hasCOI, expires: customer.coiExpiresOn,
                     owner: dto.ref(customer), ownerName: customer.listDisplayName)
            consider("customer_wc_coi", onFile: customer.hasWCCOI, expires: customer.wcCoiExpiresOn,
                     owner: dto.ref(customer), ownerName: customer.listDisplayName)
        }
        for sub in MBRecordLookup.all(Subcontractor.self, in: store) {
            consider("subcontractor_coi", onFile: sub.coiData != nil, expires: sub.coiExpiresOn,
                     owner: dto.ref(sub), ownerName: sub.listDisplayName)
        }
        if let profile = MBRecordLookup.businessProfile(in: store) {
            consider("wc_exemption", onFile: profile.hasWCExemption, expires: profile.wcExemptionExpiresOn,
                     owner: .null, ownerName: profile.businessName)
            consider("license", onFile: profile.hasLicenseDocument, expires: profile.licenseExpiresOn,
                     owner: .null, ownerName: profile.businessName)
        }
        return [
            "through": v.day(horizon),
            "count": v.int(found.count),
            "on_file_without_a_date": v.int(undated),
            "documents": .array(found.sorted { $0.0 < $1.0 }.map(\.1)),
        ]
    }

    private func pipeline(_ store: ModelContext, from: Date?, to: Date?, dto: MBRecordDTO, v: MBValue) -> [String: GLAIJSON] {
        let cal = env.calendar
        var estimates = MBRecordLookup.all(Estimate.self, in: store)
        if from != nil || to != nil {
            let filter = DateRangeFilter.custom(from: from ?? .distantPast, to: to ?? cal.startOfDay(for: env.now()))
            estimates = estimates.filter { filter.matches($0.createdAt, calendar: cal) }
        }
        func total(_ list: [Estimate]) -> GLAIJSON { v.money(DomainMoney.roundedSum(list.filter { !$0.isOptionsMode }.map(\.total))) }
        let open = estimates.filter { ($0.status == .draft || $0.status == .sent) && !$0.isExpired }
        let accepted = estimates.filter { $0.status == .accepted }
        let declined = estimates.filter { $0.status == .declined }
        let expired = estimates.filter(\.isExpired)
        let decided = accepted.count + declined.count
        return [
            "from": from.map { v.day($0) } ?? .null,
            "to": to.map { v.day($0) } ?? .null,
            "open": ["count": v.int(open.count), "total": total(open)],
            "accepted": ["count": v.int(accepted.count), "total": total(accepted)],
            "declined": ["count": v.int(declined.count), "total": total(declined)],
            "expired": ["count": v.int(expired.count), "total": total(expired)],
            "win_rate_percent": decided > 0 ? v.number(Double(accepted.count) / Double(decided) * 100) : .null,
            "note": "Totals leave out options estimates, which have no single total.",
            "open_estimates": .array(open.sorted { $0.validUntil < $1.validUntil }.prefix(15).map { dto.row($0) }),
        ]
    }

    // MARK: - Job profit

    /// Approximate on purpose, and it says why: receipts are tied to jobs, but hours and
    /// subcontractor work are tagged to a CUSTOMER — they count only when that customer has this
    /// one job, so another job's costs never land here.
    private func jobProfit(_ job: ScheduledJob, dto: MBRecordDTO, v: MBValue) -> [String: GLAIJSON] {
        let receipts = DomainMoney.roundedSum(job.sortedReceipts.map(\.total))
        var reasons = ["Receipts attached to this job are counted as costs."]
        var labor = 0.0
        var subs = 0.0
        if let customer = job.customer, !customer.isDeleted {
            let jobCount = customer.liveRows(customer.scheduledJobs).count
            if jobCount == 1 {
                labor = DomainMoney.roundedSum(customer.liveRows(customer.timeEntries).map(\.grossValue))
                subs = DomainMoney.roundedSum(customer.liveRows(customer.subPayments).map(\.amount))
                reasons.append("Employee hours and subcontractor work are tagged to the customer; this customer has only this job, so all of them are counted.")
            } else {
                reasons.append("Employee hours and subcontractor work are tagged to the customer, not the job; this customer has \(jobCount) jobs, so they're left out.")
            }
        } else {
            reasons.append("The job has no customer, so no employee hours or subcontractor work could be tied to it.")
        }
        reasons.append("Hours are valued at the logged pay rate, without payroll taxes.")
        let costs = DomainMoney.roundedSum([receipts, labor, subs])
        return [
            "job": dto.ref(job),
            "approximate": true,
            "contracted": v.money(job.contractedValue),
            "invoiced": v.money(job.invoicedTotal),
            "collected": v.money(job.amountPaid),
            "costs": ["receipts": v.money(receipts), "labor": v.money(labor), "subcontractors": v.money(subs),
                      "total": v.money(costs)],
            "profit_on_contract": v.money(job.contractedValue - costs),
            "profit_so_far": v.money(job.amountPaid - costs),
            "reasons": .array(reasons.map { .string($0) }),
        ]
    }

    // MARK: - Payments and backup

    private func paymentsSetup(_ store: ModelContext) -> [String: GLAIJSON] {
        let profile = MBRecordLookup.businessProfile(in: store)
        return [
            "card_payments_connected": .bool(profile?.stripeIsConnected ?? false),
            "card_charges_enabled": .bool(profile?.stripeChargesEnabled ?? false),
            "pay_button_on_new_invoices": .bool(profile?.payLinkDefaultOn ?? true),
            "business_details_complete": .bool(profile?.isComplete ?? false),
        ]
    }

    private func cardPaymentStatus(_ invoice: Invoice, dto: MBRecordDTO, v: MBValue) async -> [String: GLAIJSON] {
        // Everything read from the invoice is read BEFORE the await.
        let appID = invoice.stripeAppInvoiceId
        let linkID = invoice.stripePaymentLinkId
        let hasLink = !linkID.isEmpty && !invoice.stripePaymentLinkURL.isEmpty
        var output: [String: GLAIJSON] = [
            "invoice": dto.ref(invoice),
            "pay_button": .bool(invoice.includePayLink),
            "link_created": .bool(hasLink),
            "balance_due": v.money(invoice.balanceDue),
            "recorded_in_app": .bool(invoice.sortedPayments.contains { !linkID.isEmpty && $0.stripePaymentLinkId == linkID }),
            "last_known": .string(invoice.stripePayLinkStatus.rawValue),
        ]
        guard hasLink, !appID.isEmpty else {
            output["status"] = "none"
            return output
        }
        do {
            let status = try await env.cardPayments.payLinkStatus(appInvoiceID: appID)
            output["status"] = .string(["open", "paid", "none"].contains(status.status) ? status.status : "unknown")
            if let cents = status.amountPaidCents { output["amount_paid"] = v.money(Double(cents) / 100) }
            if let millis = status.paidAt { output["paid_on"] = v.day(Date(timeIntervalSince1970: Double(millis) / 1000)) }
        } catch {
            output["status"] = "unknown"
            output["message"] = "Couldn't reach card payments just now; last_known is the app's last check."
        }
        return output
    }

    private func backupStatus(_ store: ModelContext, v: MBValue) -> [String: GLAIJSON] {
        let last = MBRecordLookup.all(GLSyncState.self, in: store).compactMap(\.lastSyncAt).max()
        let pause = env.backupPause()
        return [
            "backed_up": .bool(last != nil),
            "last_backup_at": last.map(v.moment) ?? .null,
            "paused": .bool(pause != nil),
            "paused_deletions": pause.map { v.int($0.deletions) } ?? .null,
            "note": pause == nil ? "Records back up to the Gold Life ID while signed in." :
                "This device paused its backup because another device deleted an unusual number of items. The person can continue in Settings.",
        ]
    }
}
