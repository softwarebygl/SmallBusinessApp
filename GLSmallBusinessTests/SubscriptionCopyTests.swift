//
//  SubscriptionCopyTests.swift
//  GLSmallBusinessTests
//
//  QA audit F75 / law 88: the Subscription screen lists only what subscribing REMOVES. The free
//  tier already has Stripe payments, payroll and backup, so a benefit naming them is a lie.
//

import Testing
import Foundation
@testable import GLSmallBusiness

struct SubscriptionCopyTests {
    private static let subscriptionScreen = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("GLSmallBusiness/Screens/SubscriptionScreen.swift")

    @Test func noListedBenefitIsSomethingFreeUsersAlreadyHave() throws {
        let source = try String(contentsOf: Self.subscriptionScreen, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line in line.range(of: "//").map { String(line[..<$0.lowerBound]) } ?? String(line) }
            .joined(separator: "\n")
        let benefits = source.components(separatedBy: "benefits: [").dropFirst().first?
            .components(separatedBy: "],").first ?? ""
        for free in ["Stripe", "Payroll", "Backup", "sync"] {
            #expect(!benefits.contains(free), "\(free) is free for everyone; it is not a reason to subscribe")
        }
        // What it DOES list is exactly the caps: the five record kinds, and the 2 + 2 people.
        #expect(benefits.contains("Unlimited customers, estimates, invoices, jobs, and receipts"))
        #expect(benefits.contains("More than 2 employees and 2 subcontractors"))
        #expect(FreeTier.employees == 2 && FreeTier.subcontractors == 2)
    }

    @Test func theFooterSaysEverythingElseStaysFree() throws {
        let source = try String(contentsOf: Self.subscriptionScreen, encoding: .utf8)
        #expect(source.contains("Everything else stays free."))
    }
}
