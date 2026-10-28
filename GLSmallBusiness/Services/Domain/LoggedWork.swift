//
//  LoggedWork.swift
//  GLSmallBusiness
//
//  How a piece of paid work is specified — the three modes the Log Hours (employee) and Record
//  Amount (subcontractor) sheets share: a start/end range, a number of hours, or a flat amount.
//  One type so both services, both sheets and the assistant validate it the same way.
//

import Foundation

nonisolated enum LoggedWork: Equatable, Sendable {
    /// Clock-in/out; `end` may be the next day for overnight work.
    case range(start: Date, end: Date, rate: Double)
    case hours(Double, on: Date, rate: Double)
    /// A flat amount, not tied to hours.
    case dollars(Double, on: Date)

    /// Hours worked: the range length (never negative), the hours given, or 0 for a flat amount.
    var hours: Double {
        switch self {
        case .range(let start, let end, _): return max(0, end.timeIntervalSince(start) / 3600)
        case .hours(let hours, _, _): return hours
        case .dollars: return 0
        }
    }

    /// The rate hours are valued at; 0 for a flat amount.
    var rate: Double {
        switch self {
        case .range(_, _, let rate), .hours(_, _, let rate): return rate
        case .dollars: return 0
        }
    }

    /// The date the work is filed under: the range's start, or the date given.
    var date: Date {
        switch self {
        case .range(let start, _, _): return start
        case .hours(_, let date, _), .dollars(_, let date): return date
        }
    }

    /// The flat amount as it is stored — rounded to the cent (law 60) — or 0 for hours-based work.
    var flatAmount: Double {
        if case .dollars(let amount, _) = self { return DomainMoney.roundedToCents(amount) }
        return 0
    }

    /// The sheets' Save rule, as a refusal: hours-based work needs hours AND a rate above zero (a
    /// $0 snapshot would let a later raise re-price it), a flat amount must be at least a cent as it
    /// will be stored (rounded to the cent, law 60), and nothing may be negative or non-finite.
    @MainActor
    func validate(for operation: MBWriteOperation) throws {
        switch self {
        case .range(_, _, let rate):
            try DomainGate.requireNonNegative(rate, for: operation)
            guard hours > 0, rate > 0 else { throw DomainGate.refusal(.hoursAndRateRequired, operation) }
        case .hours(let hours, _, let rate):
            try DomainGate.requireNonNegative(hours, rate, for: operation)
            guard hours > 0, rate > 0 else { throw DomainGate.refusal(.hoursAndRateRequired, operation) }
        case .dollars(let amount, _):
            try DomainGate.requireNonNegative(amount, for: operation)
            guard DomainMoney.roundedToCents(amount) > 0 else { throw DomainGate.refusal(.amountRequired, operation) }
        }
    }
}
