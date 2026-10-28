//
//  CompletionPackageTests.swift
//  GLSmallBusinessTests
//
//  The completion package renders to a valid, openable PDF (cover + paid-in-full receipt, plus a
//  warranty page when warranty text is set).
//

import Testing
import Foundation
import PDFKit
@testable import GLSmallBusiness

@MainActor
struct CompletionPackageTests {
    @Test func rendersAnOpenablePDF() throws {
        let job = ScheduledJob(title: "Backsplash install", agreedPrice: 1200, status: .completed)
        let url = try #require(CompletionPackagePDF.render(job: job, business: nil))
        let document = try #require(PDFDocument(url: url))
        #expect(document.pageCount >= 2)   // cover + receipt (no warranty without business text)
    }

    @Test func includesWarrantyPageWhenSet() throws {
        let business = BusinessProfile()
        business.businessName = "Gold Standard Tile"
        business.warrantyText = "One-year workmanship warranty on all installed tile."
        let job = ScheduledJob(title: "Shower tile", agreedPrice: 3000, status: .completed)
        let url = try #require(CompletionPackagePDF.render(job: job, business: business))
        let document = try #require(PDFDocument(url: url))
        #expect(document.pageCount >= 3)   // cover + receipt + warranty
    }

    @Test func messageFallsBackToDefaultsWithoutOverrides() {
        let job = ScheduledJob(title: "Patio", customerName: "Jane Doe")
        #expect(CompletionPackageMessage.intro(business: nil) == CompletionPackageMessage.defaultIntro)
        #expect(CompletionPackageMessage.closing(business: nil) == CompletionPackageMessage.defaultClosing)
        #expect(CompletionPackageMessage.subject(job: job, business: nil).contains("Patio"))
        #expect(CompletionPackageMessage.body(job: job, business: nil).contains("Jane Doe"))
    }

    @Test func messageUsesOverridesAndAppendsCompany() {
        let business = BusinessProfile()
        business.businessName = "Summit Tile"
        let job = ScheduledJob(title: "Deck")
        // No subject override → default subject + company appended; body greets "there" with no name.
        let subject = CompletionPackageMessage.subject(job: job, business: business)
        #expect(subject.contains("Deck") && subject.contains("Summit Tile"))
        #expect(CompletionPackageMessage.body(job: job, business: business).contains("— Summit Tile"))

        business.completionMessageSubject = "Custom subject"
        business.completionMessageIntro = "Custom intro"
        business.completionMessageClosing = "Custom closing"
        #expect(CompletionPackageMessage.subject(job: job, business: business) == "Custom subject")
        #expect(CompletionPackageMessage.intro(business: business) == "Custom intro")
        #expect(CompletionPackageMessage.closing(business: business) == "Custom closing")
    }
}
