//
//  SmokeTests.swift
//  GLSmallBusinessTests
//
//  Confirms the test target is wired up and `@testable import` exposes the app's internals.
//

import Testing
@testable import GLSmallBusiness

struct SmokeTests {
    @Test func changeOrderNumbering() {
        #expect(ChangeOrder.nextNumber(after: []) == "CO-0001")
    }
}
