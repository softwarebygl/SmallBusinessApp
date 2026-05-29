//
//  Stats.swift
//  GLSmallBusiness
//
//  Created by Gold Life LLC on 5/29/26.
//

import Foundation

// MARK: - Period

/// The time window the Stats screen (and the accountant export) is scoped to.
enum StatsPeriod: Hashable {
    case all
    case year(Int)
    case month(year: Int, month: Int)

    func contains(_ date: Date, calendar: Calendar = .current) -> Bool {
        switch self {
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
            return "All time"
        case .year(let year):
            return String(year)
        case .month(let year, let month):
            var components = DateComponents()
            components.year = year
            components.month = month
            let date = Calendar.current.date(from: components) ?? .now
            return date.formatted(.dateTime.month(.wide).year())
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

    var net: Double { collected - expenses }

    var invoiceAverage: Double { invoiceCount > 0 ? invoiceTotal / Double(invoiceCount) : 0 }

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

    static func summary(
        period: StatsPeriod,
        invoices: [Invoice],
        estimates: [Estimate],
        receipts: [Receipt],
        calendar: Calendar = .current
    ) -> StatsSummary {
        var summary = StatsSummary()

        // Income — money actually collected in the period.
        for invoice in invoices {
            for payment in invoice.sortedPayments where period.contains(payment.date, calendar: calendar) {
                summary.collected += payment.amount
            }
        }

        // Invoices created in the period.
        for invoice in invoices where period.contains(invoice.createdAt, calendar: calendar) {
            summary.invoiced += invoice.total
            summary.salesTax += invoice.taxAmount
            summary.outstanding += invoice.balanceDue
            summary.invoiceTotal += invoice.total
            summary.invoiceCount += 1
            if invoice.isOverdue { summary.overdueCount += 1 }
        }

        // Estimates created in the period.
        for estimate in estimates where period.contains(estimate.createdAt, calendar: calendar) {
            summary.estimatesTotal += 1
            summary.estimatesQuoted += estimate.total
            switch estimate.status {
            case .accepted: summary.estimatesAccepted += 1
            case .declined: summary.estimatesDeclined += 1
            default: summary.estimatesPending += 1
            }
        }

        // Expenses — receipts dated in the period.
        var categoryTotals: [String: Double] = [:]
        for receipt in receipts where period.contains(receipt.date, calendar: calendar) {
            summary.expenses += receipt.total
            let key = receipt.category.trimmingCharacters(in: .whitespacesAndNewlines)
            categoryTotals[key.isEmpty ? "Uncategorized" : key, default: 0] += receipt.total
        }
        summary.expensesByCategory = categoryTotals
            .map { CategoryAmount(category: $0.key, amount: $0.value) }
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
        func moneyIn(where matches: (Date) -> Bool) -> Double {
            invoices.reduce(0) { running, invoice in
                running + invoice.sortedPayments.filter { matches($0.date) }.reduce(0) { $0 + $1.amount }
            }
        }
        func moneyOut(where matches: (Date) -> Bool) -> Double {
            receipts.filter { matches($0.date) }.reduce(0) { $0 + $1.total }
        }

        switch period {
        case .year(let year):
            let symbols = calendar.shortMonthSymbols
            return (1...12).map { month in
                let matches: (Date) -> Bool = {
                    let parts = calendar.dateComponents([.year, .month], from: $0)
                    return parts.year == year && parts.month == month
                }
                return InOutBucket(label: symbols[month - 1], sortKey: month,
                                   moneyIn: moneyIn(where: matches), moneyOut: moneyOut(where: matches))
            }
        case .all:
            let years = availableYears(invoices: invoices, estimates: [], receipts: receipts, calendar: calendar).sorted()
            return years.map { year in
                let matches: (Date) -> Bool = { calendar.component(.year, from: $0) == year }
                return InOutBucket(label: String(year), sortKey: year,
                                   moneyIn: moneyIn(where: matches), moneyOut: moneyOut(where: matches))
            }
        case .month(let year, let month):
            let matches: (Date) -> Bool = {
                let parts = calendar.dateComponents([.year, .month], from: $0)
                return parts.year == year && parts.month == month
            }
            return [InOutBucket(label: period.label, sortKey: 0,
                                moneyIn: moneyIn(where: matches), moneyOut: moneyOut(where: matches))]
        }
    }
}
