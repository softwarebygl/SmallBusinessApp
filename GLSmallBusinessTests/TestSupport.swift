//
//  TestSupport.swift
//  GLSmallBusinessTests
//
//  Builders that assemble model objects (and their relationships) entirely in memory. We do NOT
//  create a second ModelContainer in-process — the test-host app already owns one for these model
//  types, and a second *CloudKit-backed* container trips a SwiftData assertion. Reading computed
//  values (totals, balances, the Stats engine) only needs the objects + relationships, not a store.
//
//  Exception: an in-memory container with CloudKit disabled is safe and coexists with the host's —
//  see `TestStore` in ModelContextTests.swift, used by the few tests that genuinely need a live
//  ModelContext (Invoice.make / the demo seeder).
//

import Foundation
@testable import GLSmallBusiness

/// True when two doubles are within `eps` — money math accumulates tiny float error.
func close(_ a: Double, _ b: Double, eps: Double = 0.005) -> Bool { abs(a - b) < eps }

@MainActor
enum TS {
    static func day(_ year: Int, _ month: Int, _ d: Int) -> Date {
        Calendar.current.date(from: DateComponents(year: year, month: month, day: d))!
    }

    /// An invoice with one group of line items `(unitPrice, isTaxable)`.
    static func invoice(
        number: String = "INV-0001",
        createdAt: Date = .now,
        status: InvoiceStatus = .draft,
        taxRatePercent: Double = 0,
        discountType: AdjustmentType = .none,
        discountValue: Double = 0,
        lines: [(Double, Bool)] = [(1000, false)]
    ) -> Invoice {
        let inv = Invoice(number: number, jobTitle: "Job", createdAt: createdAt, status: status)
        inv.taxRatePercent = taxRatePercent
        inv.discountType = discountType
        inv.discountValue = discountValue
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
        return inv
    }

    @discardableResult
    static func pay(_ invoice: Invoice, _ amount: Double,
                    date: Date = .now, method: PaymentMethod = .check) -> InvoicePayment {
        let p = InvoicePayment(amount: amount, date: date, method: method)
        p.invoice = invoice
        invoice.payments = (invoice.payments ?? []) + [p]
        return p
    }

    @discardableResult
    static func changeOrder(
        _ invoice: Invoice,
        number: String = "CO-0001",
        status: ChangeOrderStatus = .pending,
        taxRatePercent: Double = 0,
        applied: Bool = false,
        lines: [(Double, Bool)] = [(100, false)]
    ) -> ChangeOrder {
        let co = ChangeOrder(number: number, title: "Change", taxRatePercent: taxRatePercent)
        co.status = status
        co.appliedToInvoice = applied
        co.invoice = invoice
        var items: [ChangeOrderLineItem] = []
        for (i, (price, taxable)) in lines.enumerated() {
            let item = ChangeOrderLineItem(name: "CO line \(i)", quantity: 1, unit: .job,
                                           unitPrice: price, isTaxable: taxable, sortIndex: i)
            item.changeOrder = co
            items.append(item)
        }
        co.lineItems = items
        invoice.changeOrders = (invoice.changeOrders ?? []) + [co]
        return co
    }

    static func estimate(
        number: String = "EST-0001",
        createdAt: Date = .now,
        status: EstimateStatus = .draft,
        taxRatePercent: Double = 0,
        lines: [(Double, Bool)] = [(1000, false)]
    ) -> Estimate {
        let est = Estimate(number: number, jobTitle: "Job", createdAt: createdAt, status: status)
        est.taxRatePercent = taxRatePercent
        let group = EstimateGroup(name: "Work")
        var items: [EstimateLineItem] = []
        for (i, (price, taxable)) in lines.enumerated() {
            let item = EstimateLineItem(name: "Line \(i)", quantity: 1, unit: .job,
                                        unitPrice: price, isTaxable: taxable, sortIndex: i)
            item.group = group
            items.append(item)
        }
        group.lineItems = items
        group.estimate = est
        est.groups = [group]
        return est
    }

    static func receipt(total: Double, category: String, date: Date) -> Receipt {
        Receipt(vendor: "Vendor", date: date, total: total, category: category)
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
        isActive: Bool = true
    ) -> Employee {
        Employee(firstName: first, lastName: last, email: email, phone: phone,
                 payType: payType, hourlyRate: hourlyRate, annualSalary: annualSalary,
                 payFrequency: payFrequency, anchorPayday: anchorPayday,
                 hireDate: hireDate, isActive: isActive)
    }

    /// Logs hours on `employee`, wiring the relationship both ways (no container, like `pay`).
    /// `rate` overrides the snapshot; otherwise it captures the employee's current hourly rate.
    @discardableResult
    static func logHours(_ employee: Employee, _ hours: Double, date: Date = .now,
                         rate: Double? = nil, customer: Customer? = nil) -> TimeEntry {
        let entry = TimeEntry(date: date, hours: hours,
                              rateSnapshot: rate ?? (employee.payType == .hourly ? employee.hourlyRate : 0),
                              customer: customer)
        entry.employee = employee
        employee.timeEntries = (employee.timeEntries ?? []) + [entry]
        return entry
    }

    @discardableResult
    static func paycheck(_ employee: Employee, gross: Double, hours: Double = 0,
                         periodStart: Date, periodEnd: Date, payDate: Date,
                         method: PaymentMethod = .check) -> Paycheck {
        let check = Paycheck(payPeriodStart: periodStart, payPeriodEnd: periodEnd, payDate: payDate,
                             grossAmount: gross, hoursPaid: hours, method: method)
        check.employee = employee
        employee.paychecks = (employee.paychecks ?? []) + [check]
        return check
    }
}
