//
//  AppRouterTests.swift
//  GLSmallBusinessTests
//
//  The Contacts merge's routing contract: the -demoScreen screenshot deep link must
//  land on the right segment, or the 46-shot marketing pipeline silently captures
//  the WRONG list under the right filename (the names customers/employees/
//  subcontractors survived the merge on purpose).
//

import Testing
@testable import GLSmallBusiness

@MainActor
struct AppRouterTests {

    @Test func demoScreenNamesMapToTheirSegments() {
        #expect(AppRouter(demoScreen: "employees").contactsKind == .employees)
        #expect(AppRouter(demoScreen: "subcontractors").contactsKind == .subcontractors)
        #expect(AppRouter(demoScreen: "customers").contactsKind == .customers)
    }

    /// Non-people names (and no name at all) leave the default segment alone —
    /// Calendar/Jobs shots and normal launches start on Customers.
    @Test func otherScreensAndPlainLaunchDefaultToCustomers() {
        #expect(AppRouter(demoScreen: "calendar").contactsKind == .customers)
        #expect(AppRouter(demoScreen: "invoice").contactsKind == .customers)
        #expect(AppRouter(demoScreen: nil).contactsKind == .customers)
    }

    /// The fallback exists for router-less render sites (previews, the test host).
    /// It must be ONE stable instance — the picker and the panes only agree because
    /// they resolve to the same object — and it must accept writes like the real one.
    @Test func fallbackIsOneStableWritableInstance() {
        let a = AppRouter.fallback
        let b = AppRouter.fallback
        #expect(a === b)
        let before = a.contactsKind
        a.contactsKind = .employees
        #expect(AppRouter.fallback.contactsKind == .employees)
        a.contactsKind = before   // leave shared state as found
    }
}
