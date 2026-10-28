//
//  Stats.swift
//  GLSmallBusiness
//
//  Created by Gold Life LLC on 5/29/26.
//

import Foundation

// MARK: - The app-language calendar

extension Calendar {
    /// The phone's own calendar (its kind, time zone and first weekday) naming months and weekdays
    /// in the app's chosen language (law 25). `Calendar.current` names them in the PHONE's
    /// language: the Spanish app showed Jan…Dec on the Statistics chart and Sunday…Saturday on the
    /// work schedule (QA 2026-10-03 F44). Dates and sums are the same with either; only the names
    /// differ.
    nonisolated static var appLanguage: Calendar {
        var calendar = Calendar.current
        calendar.locale = MBLocalization.currentLocale
        return calendar
    }
}

// MARK: - Period

/// The time window the Stats screen (and the accountant export) is scoped to.
enum StatsPeriod: Hashable {
    case all
    case year(Int)
    case month(year: Int, month: Int)
    /// Any span of whole days, `from`'s day through `to`'s day inclusive (the assistant's
    /// `report money_summary` period). Backwards dates are read as the same span.
    case days(from: Date, to: Date)

    func contains(_ date: Date, calendar: Calendar = .current) -> Bool {
        switch self {
        case .days(let from, let to):
            return DateRangeFilter.custom(from: from, to: to).matches(date, calendar: calendar)
        case .all:
            return true
        case .year(let year):
            return calendar.component(.year, from: date) == year
        case .month(let year, let month):
            let parts = calendar.dateComponents([.year, .month], from: date)
            return parts.year == year && parts.month == month
        }
    }

    var label: String {
        switch self {
        case .all:
            return mbLoc("All time")
        case .year(let year):
            return String(year)
        case .month(let year, let month):
            var components = DateComponents()
            components.year = year
            components.month = month
            let date = Calendar.current.date(from: components) ?? .now
            return date.formatted(.dateTime.month(.wide).year().locale(MBLocalization.currentLocale))
        case .days(let from, let to):
            let format = Date.FormatStyle.dateTime.month(.abbreviated).day().year().locale(MBLocalization.currentLocale)
            return "\(min(from, to).formatted(format)) – \(max(from, to).formatted(format))"
        }
    }
}

// MARK: - Aggregated values

struct CategoryAmount: Identifiable {
    let id = UUID()
    let category: String
    let amount: Double
}

struct InOutBucket: Identifiable {
    let id = UUID()
    let label: String
    let sortKey: Int
    let moneyIn: Double
    let moneyOut: Double
}

struct StatsSummary {
    var collected: Double = 0          // payments received in the period (cash-basis income)
    var expenses: Double = 0           // receipts dated in the period
    var processingFees: Double = 0     // payment-processor fees on payments received in the period (deductible)
    var invoiced: Double = 0           // invoices created in the period
    var salesTax: Double = 0           // tax on invoices created in the period
    var outstanding: Double = 0        // unpaid balance on the period's invoices
    var estimatesQuoted: Double = 0
    var estimatesAccepted: Int = 0
    var estimatesDeclined: Int = 0
    var estimatesPending: Int = 0
    var estimatesTotal: Int = 0
    var invoiceCount: Int = 0
    var invoiceTotal: Double = 0
    var overdueCount: Int = 0
    var expensesByCategory: [CategoryAmount] = []
    var inOut: [InOutBucket] = []

    // Every figure here adds its amounts exactly and is rounded once (`DomainMoney.Tally`, law 60) —
    // the same rule as an invoice's amount paid, so Collected agrees with the ledger to the cent; the
    // two derived ones are worked out exactly and rounded once, like every other amount.
    var net: Double {
        DomainMoney.roundedToCents(DomainMoney.decimal(collected) - DomainMoney.decimal(expenses)
                                   - DomainMoney.decimal(processingFees))
    }

    var invoiceAverage: Double {
        invoiceCount > 0 ? DomainMoney.roundedToCents(DomainMoney.decimal(invoiceTotal) / Decimal(invoiceCount)) : 0
    }

    /// Accepted / (accepted + declined). Nil when no estimate has been decided yet.
    var winRate: Double? {
        let decided = estimatesAccepted + estimatesDeclined
        return decided > 0 ? Double(estimatesAccepted) / Double(decided) : nil
    }
}

// MARK: - Engine

enum StatsEngine {
    /// Years that have any activity, newest first — used to populate the period picker.
    static func availableYears(invoices: [Invoice], estimates: [Estimate], receipts: [Receipt], calendar: Calendar = .current) -> [Int] {
        var years = Set<Int>()
        for invoice in invoices { years.insert(calendar.component(.year, from: invoice.createdAt)) }
        for estimate in estimates { years.insert(calendar.component(.year, from: estimate.createdAt)) }
        for receipt in receipts { years.insert(calendar.component(.year, from: receipt.date)) }
        for invoice in invoices {
            for payment in invoice.sortedPayments { years.insert(calendar.component(.year, from: payment.date)) }
        }
        if years.isEmpty { years.insert(calendar.component(.year, from: .now)) }
        return years.sorted(by: >)
    }

    /// Whether an invoice counts as billed in Invoiced, Sales tax and Outstanding: it isn't a
    /// draft, or it is a draft that has taken money.
    static func isBilled(_ invoice: Invoice) -> Bool {
        invoice.status != .draft || invoice.amountPaid > DomainMoney.epsilon
    }

    static func summary(
        period: StatsPeriod,
        invoices: [Invoice],
        estimates: [Estimate],
        receipts: [Receipt],
        calendar: Calendar = .appLanguage   // the chart's month names in the app's language
    ) -> StatsSummary {
        var summary = StatsSummary()

        // Income — money actually collected in the period.
        var collected = DomainMoney.Tally(), fees = DomainMoney.Tally()
        for invoice in invoices {
            for payment in invoice.sortedPayments where period.contains(payment.date, calendar: calendar) {
                collected.add(payment.amount)
                fees.add(payment.processingFee)
            }
        }
        summary.collected = collected.amount
        summary.processingFees = fees.amount

        // Invoices created in the period. An unpaid draft hasn't been billed, so it adds nothing to
        // Invoiced, Sales tax or Outstanding (the accountant's tax summary reads these). A draft that
        // has taken money was billed (emailing or texting doesn't move it off Draft), so it counts:
        // otherwise tax the business collected would go missing. Collected above counts every payment.
        var invoiced = DomainMoney.Tally(), salesTax = DomainMoney.Tally(), outstanding = DomainMoney.Tally()
        for invoice in invoices where Self.isBilled(invoice) && period.contains(invoice.createdAt, calendar: calendar) {
            let totals = invoice.totals          // worked out once per invoice, not once per figure
            invoiced.add(totals.total)
            salesTax.add(totals.tax)
            outstanding.add(InvoiceMath.owed(total: totals.total, paid: invoice.amountPaid))
            summary.invoiceCount += 1
            if invoice.isOverdue { summary.overdueCount += 1 }
        }
        summary.invoiced = invoiced.amount
        summary.invoiceTotal = invoiced.amount
        summary.salesTax = salesTax.amount
        summary.outstanding = outstanding.amount

        // Estimates created in the period.
        var quoted = DomainMoney.Tally()
        for estimate in estimates where period.contains(estimate.createdAt, calendar: calendar) {
            summary.estimatesTotal += 1
            // An options estimate has no single quoted figure — its groups are
            // mutually exclusive alternatives, and summing them inflated the
            // pipeline by the whole menu (QA 2026-09-01).
            if !estimate.isOptionsMode { quoted.add(estimate.total) }
            switch estimate.status {
            case .accepted: summary.estimatesAccepted += 1
            case .declined: summary.estimatesDeclined += 1
            default: summary.estimatesPending += 1
            }
        }
        summary.estimatesQuoted = quoted.amount

        // Expenses — receipts dated in the period.
        var expenses = DomainMoney.Tally()
        var categoryTotals: [String: DomainMoney.Tally] = [:]
        for receipt in receipts where period.contains(receipt.date, calendar: calendar) {
            expenses.add(receipt.total)
            let key = receipt.category.trimmingCharacters(in: .whitespacesAndNewlines)
            categoryTotals[key.isEmpty ? mbLoc("Uncategorized") : key, default: DomainMoney.Tally()].add(receipt.total)
        }
        summary.expenses = expenses.amount
        summary.expensesByCategory = categoryTotals
            .map { CategoryAmount(category: $0.key, amount: $0.value.amount) }
            .sorted { $0.amount > $1.amount }

        summary.inOut = inOutBuckets(period: period, invoices: invoices, receipts: receipts, calendar: calendar)
        return summary
    }

    /// Money in vs. out, bucketed for the period: by month for a year, by year for all-time, or a
    /// single bucket for a specific month.
    private static func inOutBuckets(
        period: StatsPeriod,
        invoices: [Invoice],
        receipts: [Receipt],
        calendar: Calendar
    ) -> [InOutBucket] {
        // Which bucket a date falls in for this period (month-of-year, year, or the single month),
        // or nil when the date is outside the period. One pass over payments + receipts fills both
        // dictionaries, instead of re-scanning every row once per bucket.
        func bucketKey(for date: Date) -> Int? {
            let parts = calendar.dateComponents([.year, .month], from: date)
            switch period {
            case .year(let year):
                guard parts.year == year, let month = parts.month else { return nil }
                return month
            case .all:
                return parts.year
            case .month(let year, let month):
                guard parts.year == year, parts.month == month else { return nil }
                return 0
            case .days:
                return period.contains(date, calendar: calendar) ? 0 : nil
            }
        }

        var inTally: [Int: DomainMoney.Tally] = [:]
        var outTally: [Int: DomainMoney.Tally] = [:]
        for invoice in invoices {
            for payment in invoice.liveRows(invoice.payments) {   // order doesn't matter for a sum — skip the sort
                if let key = bucketKey(for: payment.date) {
                    inTally[key, default: DomainMoney.Tally()].add(payment.amount)
                    outTally[key, default: DomainMoney.Tally()].add(payment.processingFee)   // fees are money out, when the payment came in
                }
            }
        }
        for receipt in receipts {
            if let key = bucketKey(for: receipt.date) { outTally[key, default: DomainMoney.Tally()].add(receipt.total) }
        }
        let inByKey = inTally.mapValues(\.amount)
        let outByKey = outTally.mapValues(\.amount)

        switch period {
        case .year:
            let symbols = calendar.shortMonthSymbols
            return (1...12).map { month in
                InOutBucket(label: symbols[month - 1], sortKey: month,
                            moneyIn: inByKey[month] ?? 0, moneyOut: outByKey[month] ?? 0)
            }
        case .all:
            let years = availableYears(invoices: invoices, estimates: [], receipts: receipts, calendar: calendar).sorted()
            return years.map { year in
                InOutBucket(label: String(year), sortKey: year,
                            moneyIn: inByKey[year] ?? 0, moneyOut: outByKey[year] ?? 0)
            }
        case .month, .days:
            return [InOutBucket(label: period.label, sortKey: 0,
                                moneyIn: inByKey[0] ?? 0, moneyOut: outByKey[0] ?? 0)]
        }
    }
}
