//
//  SendOutcomeTests.swift
//  GLSmallBusinessTests
//
//  The Mail / Messages result -> SendOutcome mapping. This is what decides whether the user is told
//  "couldn't send" — so a failed/cancelled compose must map correctly, and a delivery error must win
//  over a "sent" result. (A contractor must never think a document went out when it didn't.)
//

import Testing
import Foundation
import MessageUI
@testable import GLSmallBusiness

@MainActor
struct SendOutcomeTests {

    // MARK: - Mail

    @Test func mailSentIsSent() {
        #expect(SendOutcome(mailResult: .sent, error: nil) == .sent)
    }

    @Test func mailFailedIsFailed() {
        #expect(SendOutcome(mailResult: .failed, error: nil) == .failed)
    }

    @Test func mailErrorBeatsResult() {
        // Even if the result says "sent", a non-nil error means it didn't go.
        #expect(SendOutcome(mailResult: .sent, error: NSError(domain: "mail", code: 1)) == .failed)
    }

    @Test func mailCancelledIsCancelled() {
        #expect(SendOutcome(mailResult: .cancelled, error: nil) == .cancelled)
    }

    @Test func mailSavedToDraftsCountsAsCancelled() {
        // Saved to drafts was NOT actually sent — don't claim success.
        #expect(SendOutcome(mailResult: .saved, error: nil) == .cancelled)
    }

    // MARK: - Messages

    @Test func messageSentIsSent() {
        #expect(SendOutcome(messageResult: .sent) == .sent)
    }

    @Test func messageFailedIsFailed() {
        #expect(SendOutcome(messageResult: .failed) == .failed)
    }

    @Test func messageCancelledIsCancelled() {
        #expect(SendOutcome(messageResult: .cancelled) == .cancelled)
    }
}
