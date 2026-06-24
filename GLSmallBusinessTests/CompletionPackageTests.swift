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
}
