//
//  Fixtures.swift
//  GLSmallBusinessTests — Harness
//
//  Builders that assemble model objects (and their relationships) in memory. Every builder
//  takes `in context:`; leave it nil to build a detached object graph (reading computed
//  values — totals, balances, the Stats engine — only needs the objects + relationships),
//  or pass a context to have every object the builder creates inserted into it, wired
//  exactly the same way. Containers come from `TestStore` (Harness/TestStore.swift).
//

import Foundation
import SwiftData
@testable import GLSmallBusiness

/// True when two doubles are within `eps` — money math accumulates tiny float error.
func close(_ a: Double, _ b: Double, eps: Double = 0.005) -> Bool { abs(a - b) < eps }

@MainActor
enum TS {

    // MARK: - Dates

    /// The calendar every fixture date is built in: Gregorian, Eastern (where the business
    /// and its books live), weeks starting Sunday. Fixed rather than `Calendar.current` so a
    /// date-sensitive assertion means the same thing on a CI box in another time zone.
    nonisolated static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        calendar.firstWeekday = 1
        return calendar
    }()

    /// Midnight on `year`-`month`-`d` in `calendar` (defaults to `TS.calendar`).
    static func day(_ year: Int, _ month: Int, _ d: Int, calendar: Calendar = TS.calendar) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: d))!
    }

    // MARK: - Customers

    /// The demo dataset's primary customer by default (Marcus Reed of Reed General
    /// Contracting), so a fixture reads the same as the seeded world it stands in for.
    @discardableResult
    static func customer(
        first: String = "Marcus",
        last: String = "Reed",
        email: String = "marcus@reedgc.com",
        phone: String = "(850) 555-0193",
        business: String? = "Reed General Contracting",
        address: Address = Address(street1: "1180 Capital Cir NE", city: "Miami",
                                   state: "FL", postalCode: "32308"),
        in context: ModelContext? = nil
    ) -> Customer {
        let customer = Customer(firstName: first, lastName: last, email: email,
                                phoneNumber: phone, businessName: business, address: address)
        context?.insert(customer)
        return customer
    }

    // MARK: - Invoices

    /// An invoice with one group of line items `(unitPrice, isTaxable)`.
    static func invoice(
        number: String = "INV-0001",
        createdAt: Date = .now,
        status: InvoiceStatus = .draft,
        taxRatePercent: Double = 0,
        discountType: AdjustmentType = .none,
        discountValue: Double = 0,
        lines: [(Double, Bool)] = [(1000, false)],
        in context: ModelContext? = nil
    ) -> Invoice {
        let inv = Invoice(number: number, jobTitle: "Job", createdAt: createdAt, status: status)
        inv.taxRatePercent = taxRatePercent
        inv.discountType = discountType
        inv.discountValue = discountValue
        context?.insert(inv)   // root first, children after — the seeder's order
        let group = InvoiceGroup(name: "Work")
        var items: [InvoiceLineItem] = []
        for (i, (price, taxable)) in lines.enumerated() {
            let item = InvoiceLineItem(name: "Line \(i)", quantity: 1, unit: .job,
                                       unitPrice: price, isTaxable: taxable, sortIndex: i)
            item.group = group
            items.append(item)
        }
        group.lineItems = items
        group.invoice = inv
        inv.groups = [group]
        if let context {
            context.insert(group)
            items.forEach(context.insert)
        }
        return inv
    }

    @discardableResult
    static func pay(_ invoice: Invoice, _ amount: Double,
                    date: Date = .now, method: PaymentMethod = .check,
                    in context: ModelContext? = nil) -> InvoicePayment {
        let p = InvoicePayment(amount: amount, date: date, method: method)
        p.invoice = invoice
        invoice.payments = (invoice.payments ?? []) + [p]
        context?.insert(p)
        return p
    }

    @discardableResult
    static func changeOrder(
        _ invoice: Invoice,
        number: String = "CO-0001",
        status: ChangeOrderStatus = .pending,
        taxRatePercent: Double = 0,
        applied: Bool = false,
        lines: [(Double, Bool)] = [(100, false)],
        in context: ModelContext? = nil
    ) -> ChangeOrder {
        let co = ChangeOrder(number: number, title: "Change", taxRatePercent: taxRatePercent)
        co.status = status
        co.appliedToInvoice = applied
        co.invoice = invoice
        context?.insert(co)   // root first, children after — the seeder's order
        var items: [ChangeOrderLineItem] = []
        for (i, (price, taxable)) in lines.enumerated() {
            let item = ChangeOrderLineItem(name: "CO line \(i)", quantity: 1, unit: .job,
                                           unitPrice: price, isTaxable: taxable, sortIndex: i)
            item.changeOrder = co
            items.append(item)
        }
        co.lineItems = items
        invoice.changeOrders = (invoice.changeOrders ?? []) + [co]
        if let context { items.forEach(context.insert) }
        return co
    }

    // MARK: - Estimates

    /// An estimate with one group of line items `(unitPrice, isTaxable)`.
    static func estimate(
        number: String = "EST-0001",
        createdAt: Date = .now,
        status: EstimateStatus = .draft,
        taxRatePercent: Double = 0,
        lines: [(Double, Bool)] = [(1000, false)],
        in context: ModelContext? = nil
    ) -> Estimate {
        let est = Estimate(number: number, jobTitle: "Job", createdAt: createdAt, status: status)
        est.taxRatePercent = taxRatePercent
        context?.insert(est)   // root first, children after — the seeder's order
        est.groups = [estimateGroup(name: "Work", sortIndex: 0, lines: lines, on: est, in: context)]
        return est
    }

    /// An OPTIONS estimate — `combineTotals` off, one group per entry in `groups`, each
    /// priced on its own so the customer picks one (see `Estimate.isOptionsMode`).
    static func optionsEstimate(
        number: String = "EST-0001",
        taxRatePercent: Double = 0,
        groups: [(name: String, lines: [(Double, Bool)])],
        in context: ModelContext? = nil
    ) -> Estimate {
        let est = Estimate(number: number, jobTitle: "Job", createdAt: .now, status: .draft)
        est.taxRatePercent = taxRatePercent
        est.combineTotals = false
        context?.insert(est)   // root first, children after — the seeder's order
        est.groups = groups.enumerated().map { index, spec in
            estimateGroup(name: spec.name, sortIndex: index, lines: spec.lines, on: est, in: context)
        }
        return est
    }

    /// One estimate group wired to `est`, its lines named `Line 0…` in order.
    private static func estimateGroup(name: String, sortIndex: Int, lines: [(Double, Bool)],
                                      on est: Estimate, in context: ModelContext?) -> EstimateGroup {
        let group = EstimateGroup(name: name, sortIndex: sortIndex)
        context?.insert(group)
        var items: [EstimateLineItem] = []
        for (i, (price, taxable)) in lines.enumerated() {
            let item = EstimateLineItem(name: "Line \(i)", quantity: 1, unit: .job,
                                        unitPrice: price, isTaxable: taxable, sortIndex: i)
            item.group = group
            items.append(item)
        }
        group.lineItems = items
        group.estimate = est
        if let context { items.forEach(context.insert) }
        return group
    }

    // MARK: - Jobs

    /// A job for `customer` (its name snapshot taken the way the form does). All-day by default,
    /// `days` workdays from `start`; pass `hour` for a TIMED job — a window opening at
    /// `hour`:`minute` on `start`'s day in `calendar`, `minutes` long (60 when nil), with
    /// `startDate` pinned to that day's midnight. Recurrence lands on the raw fields directly
    /// (nil = a one-off), so a test can also build the shapes only a synced record produces.
    @discardableResult
    static func job(
        _ title: String = "",
        start: Date,
        days: Int = 1,
        hour: Int? = nil,
        minute: Int = 0,
        minutes: Int? = nil,
        customer: Customer? = nil,
        price: Double? = nil,
        status: JobStatus = .scheduled,
        recurrence: RecurrenceFrequency? = nil,
        weekdayMask: Int = 0,
        recurrenceCount: Int = 0,
        recurrenceEnd: Date? = nil,
        calendar: Calendar = TS.calendar,
        in context: ModelContext? = nil
    ) -> ScheduledJob {
        let job = ScheduledJob(title: title, customerName: customer?.listDisplayName ?? "",
                               startDate: hour == nil ? start : calendar.startOfDay(for: start),
                               durationDays: days, customer: customer, agreedPrice: price, status: status)
        if let hour {
            job.isAllDay = false
            job.startTime = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: start)
            job.durationMinutes = minutes ?? 60
        }
        job.recurrenceFrequencyRaw = recurrence?.rawValue ?? ""
        job.recurrenceWeekdayMask = weekdayMask
        job.recurrenceCount = recurrenceCount
        job.recurrenceEndDate = recurrenceEnd
        context?.insert(job)
        return job
    }

    // MARK: - Receipts

    static func receipt(total: Double, category: String, date: Date,
                        in context: ModelContext? = nil) -> Receipt {
        let receipt = Receipt(vendor: "Vendor", date: date, total: total, category: category)
        context?.insert(receipt)
        return receipt
    }

    // MARK: - Employees

    static func employee(
        first: String = "Jane",
        last: String = "Doe",
        email: String = "",
        phone: String = "",
        payType: PayType = .hourly,
        hourlyRate: Double = 25,
        annualSalary: Double = 0,
        payFrequency: PayFrequency = .weekly,
        anchorPayday: Date = .now,
        hireDate: Date = .now,
        isActive: Bool = true,
        in context: ModelContext? = nil
    ) -> Employee {
        let employee = Employee(firstName: first, lastName: last, email: email, phone: phone,
                                payType: payType, hourlyRate: hourlyRate, annualSalary: annualSalary,
                                payFrequency: payFrequency, anchorPayday: anchorPayday,
                                hireDate: hireDate, isActive: isActive)
        context?.insert(employee)
        return employee
    }

    /// Logs hours on `employee`, wiring the relationship both ways (like `pay`).
    /// `rate` overrides the snapshot; otherwise it captures the employee's current hourly rate.
    @discardableResult
    static func logHours(_ employee: Employee, _ hours: Double, date: Date = .now,
                         rate: Double? = nil, customer: Customer? = nil,
                         in context: ModelContext? = nil) -> TimeEntry {
        let entry = TimeEntry(date: date, hours: hours,
                              rateSnapshot: rate ?? (employee.payType == .hourly ? employee.hourlyRate : 0),
                              customer: customer)
        entry.employee = employee
        employee.timeEntries = (employee.timeEntries ?? []) + [entry]
        context?.insert(entry)
        return entry
    }

    @discardableResult
    static func paycheck(_ employee: Employee, gross: Double, hours: Double = 0,
                         periodStart: Date, periodEnd: Date, payDate: Date,
                         method: PaymentMethod = .check,
                         in context: ModelContext? = nil) -> Paycheck {
        let check = Paycheck(payPeriodStart: periodStart, payPeriodEnd: periodEnd, payDate: payDate,
                             grossAmount: gross, hoursPaid: hours, method: method)
        check.employee = employee
        employee.paychecks = (employee.paychecks ?? []) + [check]
        context?.insert(check)
        return check
    }

    // MARK: - Subcontractors

    static func subcontractor(
        first: String = "Lee",
        last: String = "Sub",
        business: String = "",
        email: String = "",
        phone: String = "",
        address: Address = Address(),
        isActive: Bool = true,
        in context: ModelContext? = nil
    ) -> Subcontractor {
        let sub = Subcontractor(firstName: first, lastName: last, businessName: business,
                                email: email, phone: phone, address: address, isActive: isActive)
        context?.insert(sub)
        return sub
    }

    /// A PAID ledger entry (paidDate = date), so it counts toward totals / the 1099.
    @discardableResult
    static func paySub(_ sub: Subcontractor, _ amount: Double, date: Date = .now,
                       method: PaymentMethod = .check, detail: String = "",
                       customer: Customer? = nil,
                       in context: ModelContext? = nil) -> SubPayment {
        let payment = SubPayment(amount: amount, date: date, paidDate: date, method: method,
                                 detail: detail, customer: customer)
        payment.subcontractor = sub
        sub.payments = (sub.payments ?? []) + [payment]
        context?.insert(payment)
        return payment
    }

    /// An OWED (unpaid) ledger entry — paidDate stays nil, so it's outstanding, not yet paid.
    @discardableResult
    static func oweSub(_ sub: Subcontractor, _ amount: Double, hours: Double = 0, date: Date = .now,
                       detail: String = "", customer: Customer? = nil,
                       in context: ModelContext? = nil) -> SubPayment {
        let entry = SubPayment(amount: amount, hours: hours, date: date, detail: detail, customer: customer)
        entry.subcontractor = sub
        sub.payments = (sub.payments ?? []) + [entry]
        context?.insert(entry)
        return entry
    }
}
