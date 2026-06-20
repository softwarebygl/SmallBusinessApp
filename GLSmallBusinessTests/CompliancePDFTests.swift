//
//  CompliancePDFTests.swift
//  GLSmallBusinessTests
//
//  CompliancePDF.tempURL — writes a certificate to a temp file for sharing, honoring the given
//  name and falling back when it's blank.
//

import Testing
import Foundation
@testable import GLSmallBusiness

@MainActor
struct CompliancePDFTests {
    @Test func writesDataUnderGivenName() throws {
        let data = Data("a-certificate".utf8)
        let url = try #require(CompliancePDF.tempURL(data, name: "Cert.pdf", fallback: "fallback.pdf"))
        #expect(url.lastPathComponent == "Cert.pdf")
        #expect(try Data(contentsOf: url) == data)
    }

    @Test func usesFallbackWhenNameEmpty() throws {
        let url = try #require(CompliancePDF.tempURL(Data("x".utf8), name: "", fallback: "fallback.pdf"))
        #expect(url.lastPathComponent == "fallback.pdf")
    }
}
