//
//  MenuGoldLifeIDMembershipTests.swift
//  GLSmallBusinessTests
//
//  Audit 2026-10-03 F74. The Gold Life ID card says "Thank you", carries the thank-you letter
//  and "GOLD LIFE MEMBER" only for members (PARITY.md, owner ruling 2026-08-23: "the word only
//  for members"). Build 88 dropped My Business's own card, and the package card told every
//  account it was a member. The Menu now passes its membership: a subscriber, a comp/owner
//  account, or a status not known yet (a cold launch or offline never strips a paying owner's
//  card, the rule build 88 removed).
//

import Testing
@testable import GLSmallBusiness

@Suite struct MenuGoldLifeIDMembershipTests {
    @Test func aFreeAccountIsNotAMember() {
        #expect(MenuScreen.isGoldLifeMember(isSubscribed: false, serverEntitled: false, statusKnown: true) == false)
    }

    @Test func aSubscriberIsAMember() {
        #expect(MenuScreen.isGoldLifeMember(isSubscribed: true, serverEntitled: false, statusKnown: true))
    }

    @Test func aCompOrOwnerAccountIsAMember() {
        #expect(MenuScreen.isGoldLifeMember(isSubscribed: false, serverEntitled: true, statusKnown: true))
    }

    @Test func anUnknownStatusNeverStripsTheCard() {
        #expect(MenuScreen.isGoldLifeMember(isSubscribed: false, serverEntitled: false, statusKnown: false))
    }
}
