//
//  GLCertificateStatusTests.swift
//  GLSmallBusinessTests
//
//  "Is this certificate still good?" (GLCertificateStatus.swift). The one rule every
//  certificate slot shares: unknown is NOT expired, expired is strictly before today,
//  and "soon" is the 30-day window.
//

import Testing
import Foundation
@testable import GLSmallBusiness

@MainActor
struct GLCertificateStatusTests {

    private func days(_ n: Int) -> Date {
        Calendar.current.date(byAdding: .day, value: n, to: .now)!
    }

    // MARK: - isExpired

    @Test func anUnknownDateIsNotExpired() {
        #expect(!GLCertificateStatus.isExpired(nil))
    }

    @Test func yesterdayIsExpiredTodayIsNot() {
        #expect(GLCertificateStatus.isExpired(days(-1)))
        // Valid through the WHOLE day it names: `now` (any time today) is not before today's start.
        #expect(!GLCertificateStatus.isExpired(.now))
        #expect(!GLCertificateStatus.isExpired(Calendar.current.startOfDay(for: .now)))
    }

    // MARK: - isExpiringSoon

    @Test func unknownAndExpiredAreNeverExpiringSoon() {
        #expect(!GLCertificateStatus.isExpiringSoon(nil))
        #expect(!GLCertificateStatus.isExpiringSoon(days(-1)), "already expired is a different state")
    }

    @Test func theThirtyDayWindowIsInclusive() {
        #expect(GLCertificateStatus.warningWindowDays == 30)
        #expect(GLCertificateStatus.isExpiringSoon(days(1)))
        #expect(GLCertificateStatus.isExpiringSoon(days(30)))
        #expect(!GLCertificateStatus.isExpiringSoon(days(31)))
    }

    // MARK: - caption

    @Test func captionIsNilForAnUnknownDate() {
        #expect(GLCertificateStatus.caption(nil) == nil)
    }

    @Test func captionNamesTheStateAndTheDate() throws {
        // The caption is localized, so it resolves against the CHOSEN language. Pin it, or this
        // assertion silently becomes "whatever language the test sim happens to be in". Safe to
        // mutate the global: the setter is MainActor-only and this body never suspends.
        let savedLanguage = MBLocalization.shared.language
        defer { MBLocalization.shared.language = savedLanguage }
        MBLocalization.shared.language = .en

        func when(_ date: Date) -> String {
            date.formatted(.dateTime.month(.abbreviated).day().year())
        }

        let expired = days(-10)
        #expect(GLCertificateStatus.caption(expired) == "Expired \(when(expired))")

        let soon = days(7)
        #expect(GLCertificateStatus.caption(soon) == "Expires \(when(soon))")

        let good = days(90)
        #expect(GLCertificateStatus.caption(good) == "Good through \(when(good))")

        // Each caption carries the date, never a bare state word.
        let caption = try #require(GLCertificateStatus.caption(good))
        #expect(caption.hasPrefix("Good through "))
        #expect(caption.count > "Good through ".count)
    }
}
