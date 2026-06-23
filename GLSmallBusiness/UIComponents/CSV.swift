//
//  CSV.swift
//  GLSmallBusiness
//
//  Created by Gold Life LLC on 6/22/26.
//
//  CSV field escaping shared by every accountant export (subcontractor 1099 ledger, employee pay,
//  stats). One place for the two rules so all three exports behave identically and the logic is
//  unit-testable:
//    • Formula-injection guard — a field starting with = + - @ or tab is run as a formula by
//      Excel / Numbers, so it's neutralized with a leading apostrophe.
//    • RFC-4180 quoting — fields containing a comma, quote, or newline are wrapped in quotes with
//      embedded quotes doubled.
//

import Foundation

enum CSV {
    static func field(_ field: String) -> String {
        var value = field
        if let first = value.first, "=+-@\t".contains(first) {
            value = "'" + value
        }
        guard value.contains(",") || value.contains("\"") || value.contains("\n") || value.contains("\r") else {
            return value
        }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
