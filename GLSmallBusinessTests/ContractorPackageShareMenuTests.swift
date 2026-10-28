//
//  ContractorPackageShareMenuTests.swift
//  GLSmallBusinessTests
//
//  Law 51 (audit 2026-10-03 F128): the Contractor Package toolbar's share control is a Menu only
//  when it holds two rows. With a complete business profile and no way to email the package (the
//  customer has no email, or this device has no Mail account), the only row would be "Share
//  package…", so the toolbar shows the share button itself.
//

import Testing
@testable import GLSmallBusiness

struct ContractorPackageShareMenuTests {

    @Test func emailAndShareMakeAMenu() {
        #expect(ContractorPackageSheet.shareNeedsMenu(profileIsComplete: true,
                                                      customerEmail: "gc@example.com", canSendMail: true))
    }

    @Test func noMailAccountLeavesOnlyShare() {
        #expect(!ContractorPackageSheet.shareNeedsMenu(profileIsComplete: true,
                                                       customerEmail: "gc@example.com", canSendMail: false))
    }

    @Test func noCustomerEmailLeavesOnlyShare() {
        #expect(!ContractorPackageSheet.shareNeedsMenu(profileIsComplete: true,
                                                       customerEmail: "", canSendMail: true))
    }

    /// An incomplete profile swaps Email for the setup row, so the menu still has two rows.
    @Test func incompleteProfileKeepsTheSetupRowBesideShare() {
        #expect(ContractorPackageSheet.shareNeedsMenu(profileIsComplete: false,
                                                      customerEmail: "", canSendMail: false))
        #expect(ContractorPackageSheet.shareNeedsMenu(profileIsComplete: false,
                                                      customerEmail: "gc@example.com", canSendMail: true))
    }
}
