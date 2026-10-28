//
//  SubcontractorCoverageTests.swift
//  GLSmallBusinessTests
//
//  THE home of the subcontractor area: the owed/paid ledger (SubPayment, paidDate nil = owed), the
//  display helpers, the $600 / $2,000 1099-NEC threshold, the W-9 / TIN capture (TINFormatter,
//  SecureTINStore-backed per-sub TINs), the 1099-NEC generation path, and every STATE VARIANT of the
//  screens that plain "does it render" tests never reach — empty vs populated, owed vs paid vs past
//  due, W-9 on file vs not, EIN vs SSN, photo vs none, active vs inactive, deleted-out-from-under-
//  you, light + dark, and accessibility type sizes.
//
//  Screens are hosted through GLTestHost; the demo dataset comes from TestStore.demoWorld(); every
//  other fixture is a TS builder with `in: context` so the screens' @Query sees it. The
//  `matchesSearch` predicates live in RecordSearchTests, the business-side W-9 form in
//  PDFRenderTests / KeychainAndW9Tests. Nothing is asserted in two places.
//
//  Non-ASCII characters are written as \u{...} escapes on purpose: this file asserts on tax-form
//  output, and a double-encoded bullet or dash would be invisible in a diff.
//

import Testing
import Foundation
import SwiftUI
import GoldLifeUI
import SwiftData
import UIKit
import PDFKit
@testable import GLSmallBusiness

@Suite(.serialized)
@MainActor
struct SubcontractorCoverageTests {

    // MARK: - Clock-relative dates
    //
    // `owedStatus` ("past due" is `date < startOfToday`), the no-argument `totalPaid()` /
    // `requires1099()`, and the screens' past-due cues read the DEVICE clock and calendar, so
    // these two are deliberately `Calendar.current` — a fixed `TS.day` cannot stand in for
    // "yesterday" or "this tax year". Fixed dates everywhere else use TS.day.

    private var startOfToday: Date { Calendar.current.startOfDay(for: .now) }
    private var thisYear: Int { Calendar.current.component(.year, from: .now) }

    // MARK: - Ledger math: nothing recorded

    @Test func subWithNoPaymentsIsEntirelyZero() {
        let sub = TS.subcontractor(first: "Nora", last: "New")
        #expect(sub.sortedPayments.isEmpty)
        #expect(close(sub.outstanding, 0))
        #expect(!sub.hasOutstanding)
        #expect(sub.owedStatus == .none)
        #expect(close(sub.totalPaid(year: 2026), 0))
        #expect(close(sub.lifetimePaid, 0))
        #expect(!sub.requires1099(year: 2026))
        #expect(!sub.hasTIN && !sub.hasW9OnFile)
    }

    /// `payments` is an optional relationship — a brand-new @Model has nil, not [].
    @Test func nilPaymentsRelationshipNeverTraps() {
        let sub = Subcontractor()
        #expect(sub.payments == nil)
        #expect(sub.sortedPayments.isEmpty)
        #expect(sub.owedStatus == .none)
        #expect(close(sub.outstanding, 0))
        #expect(Subcontractor1099Summary.forYear([sub], year: thisYear).count1099 == 0)
    }

    @Test func newSubPaymentDefaultsToAnOwedZeroCheckEntry() {
        let entry = SubPayment()
        #expect(close(entry.amount, 0) && close(entry.hours, 0))
        #expect(entry.paidDate == nil && !entry.isPaid)     // paidDate nil IS the "owed" signal
        #expect(entry.method == .check)
        #expect(entry.detail.isEmpty)
        #expect(entry.subcontractor == nil && entry.customer == nil)
    }

    /// A sub's TIN is keyed by `tinKey`, not object identity — the value follows the key, which is
    /// what makes it survive a CloudKit round-trip that re-materializes the model.
    @Test func tinFollowsTheKeyNotTheModelInstance() {
        let original = TS.subcontractor(first: "Key", last: "Ed")
        defer { original.clearSecureTIN() }
        original.updateTIN("44-4444444")

        let rehydrated = TS.subcontractor(first: "Key", last: "Ed")
        rehydrated.tinKey = original.tinKey                 // same record, new instance
        #expect(rehydrated.secureTIN == "44-4444444" && rehydrated.hasTIN)
        #expect(rehydrated.maskedTIN == original.maskedTIN)
    }

    // MARK: - Ledger math: owed and paid mixed

    /// Paid and owed never mix, `totalPaid(year:)` scopes to its year, and `lifetimePaid` spans them.
    @Test func owedAndPaidAreTalliedSeparately() {
        let sub = TS.subcontractor()
        TS.paySub(sub, 500, date: TS.day(2025, 12, 30))
        TS.paySub(sub, 1_000, date: TS.day(2026, 2, 1))
        TS.paySub(sub, 500, date: TS.day(2026, 3, 1))
        TS.oweSub(sub, 250, date: TS.day(2026, 4, 1))
        TS.oweSub(sub, 125, date: TS.day(2026, 4, 2))
        #expect(close(sub.outstanding, 375))
        #expect(sub.hasOutstanding)
        #expect(close(sub.totalPaid(year: 2026), 1_500))
        #expect(close(sub.totalPaid(year: 2025), 500))
        #expect(close(sub.lifetimePaid, 2_000))            // every year, never the owed rows
        #expect(sub.sortedPayments.count == 5)
    }

    @Test func markingAnOwedEntryPaidMovesItAcross() {
        let sub = TS.subcontractor()
        let owed = TS.oweSub(sub, 2_000, date: TS.day(2026, 5, 1))
        #expect(!owed.isPaid && close(sub.outstanding, 2_000) && !sub.requires1099(year: 2026))
        owed.paidDate = TS.day(2026, 5, 9)
        #expect(owed.isPaid && close(sub.outstanding, 0) && close(sub.totalPaid(year: 2026), 2_000))
        #expect(sub.requires1099(year: 2026))
        owed.paidDate = nil                       // and back again — nil is the single source of truth
        #expect(!owed.isPaid && close(sub.outstanding, 2_000) && close(sub.totalPaid(year: 2026), 0))
    }

    /// The 1099 is cash-basis: an entry paid in a LATER year counts in the year it was paid.
    @Test func paidYearFollowsPaidDateNotWorkDate() {
        let sub = TS.subcontractor()
        let entry = TS.paySub(sub, 3_000, date: TS.day(2025, 12, 28))
        entry.paidDate = TS.day(2026, 1, 4)
        #expect(close(sub.totalPaid(year: 2025), 0))
        #expect(close(sub.totalPaid(year: 2026), 3_000))
        #expect(sub.requires1099(year: 2026) && !sub.requires1099(year: 2025))
    }

    /// The no-argument `totalPaid()` / `requires1099()` read the device's current year.
    @Test func defaultYearComputedsUseCurrentYear() {
        let sub = TS.subcontractor()
        TS.paySub(sub, 2_500, date: TS.day(thisYear, 1, 10))
        #expect(close(sub.totalPaid(), 2_500))   // no-arg → current year
        #expect(sub.requires1099())              // no-arg → current year, over any year's threshold
    }

    // MARK: - 1099-NEC vs 1099-K (F86)
    //
    // IRS Instructions for Forms 1099-MISC and 1099-NEC (irs.gov/instructions/i1099mec, Reminders):
    // payments made with a credit card or payment card, and third-party network transactions, are
    // reported on Form 1099-K by the payment settlement entity and are not subject to reporting on
    // Form 1099-NEC. So box 1 and the "1099-NEC due" flag count only cash, check, bank transfer,
    // Zelle and Other.

    /// A $3,000 Venmo payment is money paid (the ledger total) but never box 1 or the due flag.
    @Test func venmoPaymentIsLeftOutOfBox1AndTheDueFlag() {
        let sub = TS.subcontractor()
        TS.paySub(sub, 3_000, date: TS.day(2026, 3, 2), method: .venmo)
        TS.paySub(sub, 500, date: TS.day(2026, 3, 9), method: .check)
        #expect(close(sub.totalPaid(year: 2026), 3_500))         // what actually went out
        #expect(close(sub.form1099NECAmount(year: 2026), 500))   // box 1: the check only
        #expect(close(sub.paidOn1099K(year: 2026), 3_000))       // why the two differ
        #expect(!sub.requires1099(year: 2026))                   // $500 < $2,000: nothing due
    }

    /// Once the NEC-reportable methods alone cross the threshold, the flag trips on that amount.
    @Test func dueFlagCountsOnlyNECMethods() {
        let sub = TS.subcontractor()
        TS.paySub(sub, 1_500, date: TS.day(2026, 1, 5), method: .zelle)
        TS.paySub(sub, 1_000, date: TS.day(2026, 1, 6), method: .paypal)
        #expect(!sub.requires1099(year: 2026))                   // $1,500 NEC < $2,000
        TS.paySub(sub, 500, date: TS.day(2026, 1, 7), method: .transfer)
        #expect(close(sub.form1099NECAmount(year: 2026), 2_000))
        #expect(sub.requires1099(year: 2026))
    }

    /// The whole method list, pinned: card and payment apps go on the 1099-K; the rest on the 1099-NEC.
    @Test func everyPaymentMethodIsClassified() {
        let onK: Set<PaymentMethod> = [.card, .venmo, .cashApp, .appleCash, .paypal, .googlePay, .square, .stripe]
        for method in PaymentMethod.allCases {
            #expect(Subcontractor.isReportedOn1099K(method) == onK.contains(method), "\(method)")
        }
    }

    /// The summary header's 1099 count follows the same rule.
    @Test func yearSummaryCountsOnlyNECReportableSubs() {
        let venmoOnly = TS.subcontractor(first: "Vic", last: "Venmo")
        TS.paySub(venmoOnly, 5_000, date: TS.day(2026, 2, 1), method: .venmo)
        let checkPaid = TS.subcontractor(first: "Cal", last: "Check")
        TS.paySub(checkPaid, 5_000, date: TS.day(2026, 2, 1), method: .check)
        let totals = Subcontractor1099Summary.forYear([venmoOnly, checkPaid], year: 2026)
        #expect(close(totals.totalPaid, 10_000))
        #expect(totals.count1099 == 1)
    }

    /// Pay Now's overpayment footer promises "counts toward the 1099" only for a method that does.
    @Test func payNowFooterNeverPromisesA1099ForAppPayments() {
        let check = PaySubcontractorSheet.footer(owed: 100, amount: 150, method: .check)
        let venmo = PaySubcontractorSheet.footer(owed: 100, amount: 150, method: .venmo)
        #expect(check.contains("counts toward the 1099"))
        #expect(!venmo.contains("1099"))
        #expect(venmo.contains("recorded as its own paid entry"))
    }

    // MARK: - W-9 / COI row titles (L6)

    /// Nothing on file: the row names what it holds ("Their W-9"); "on file" only once one is.
    @Test func w9AndCOIRowTitlesFollowWhatIsOnFile() {
        #expect(SubcontractorDetailScreen.w9RowTitle(onFile: false) == "Their W-9")
        #expect(SubcontractorDetailScreen.w9RowTitle(onFile: true) == "W-9 on file")
        #expect(SubcontractorDetailScreen.coiRowTitle(onFile: false) == "Their certificate of insurance")
        #expect(SubcontractorDetailScreen.coiRowTitle(onFile: true) == "COI on file")
    }

    // MARK: - Ledger math: edge amounts

    @Test func zeroHourEntryIsAFlatAmount() {
        let sub = TS.subcontractor()
        let owed = TS.oweSub(sub, 400, hours: 0, date: TS.day(2026, 6, 1))
        #expect(close(owed.hours, 0))
        #expect(close(sub.outstanding, 400))
        let paid = TS.paySub(sub, 400, date: TS.day(2026, 6, 2))
        #expect(close(paid.hours, 0) && close(sub.totalPaid(year: 2026), 400))
    }

    /// Hours WITHOUT money: a 5-hour entry logged at a $0 rate. It's a real, unpaid row that
    /// contributes nothing to the balance — and must not flip the sub into an "owes money" state.
    @Test func zeroAmountEntryWithHoursDoesNotCreateABalance() {
        let sub = TS.subcontractor()
        let entry = TS.oweSub(sub, 0, hours: 5, date: TS.day(2026, 1, 2))
        #expect(sub.sortedPayments.count == 1 && close(entry.hours, 5))
        #expect(close(sub.outstanding, 0))
        #expect(!sub.hasOutstanding)
        #expect(sub.owedStatus == .none)         // guarded by hasOutstanding, so never "past due"
    }

    @Test func outstandingHonoursTheHalfCentTolerance() {
        let under = TS.subcontractor()
        TS.oweSub(under, 0.004, date: TS.day(2026, 1, 1))
        #expect(!under.hasOutstanding && under.owedStatus == .none)

        let over = TS.subcontractor()
        TS.oweSub(over, 0.006, date: TS.day(2026, 1, 1))
        #expect(over.hasOutstanding)
    }

    /// DOCUMENTS CURRENT BEHAVIOR: a negative (credit / correction) entry nets against the balance,
    /// and a net-negative balance reads as "nothing owed" — `hasOutstanding` is `> 0.005`, not `!= 0`.
    @Test func negativeEntriesNetAgainstTheBalance() {
        let partial = TS.subcontractor()
        TS.oweSub(partial, 500, date: TS.day(2026, 1, 1))
        TS.oweSub(partial, -200, date: TS.day(2026, 1, 2))
        #expect(close(partial.outstanding, 300) && partial.hasOutstanding)

        let credit = TS.subcontractor()
        TS.oweSub(credit, -100, date: TS.day(2026, 1, 1))
        #expect(close(credit.outstanding, -100))
        #expect(!credit.hasOutstanding)          // negative balance is NOT "owed"
        #expect(credit.owedStatus == .none)      // …so the row never turns red
    }

    @Test func veryLargeAmountsStaySummable() {
        let sub = TS.subcontractor()
        TS.paySub(sub, 1_000_000_000, date: TS.day(2026, 1, 1))
        TS.paySub(sub, 1_000_000_000, date: TS.day(2026, 2, 1))
        TS.oweSub(sub, 999_999_999.99, date: TS.day(2026, 3, 1))
        #expect(close(sub.totalPaid(year: 2026), 2_000_000_000, eps: 0.5))
        #expect(close(sub.outstanding, 999_999_999.99, eps: 0.5))
        #expect(sub.requires1099(year: 2026))
    }

    @Test func sortedPaymentsIsNewestFirstAndKeepsTies() {
        let sub = TS.subcontractor()
        let day = TS.day(2026, 4, 4)
        TS.paySub(sub, 10, date: TS.day(2026, 4, 1))
        TS.paySub(sub, 20, date: day)
        TS.oweSub(sub, 30, date: day)
        TS.paySub(sub, 40, date: TS.day(2026, 4, 9))
        let sorted = sub.sortedPayments
        #expect(sorted.count == 4)
        #expect(close(sorted.first?.amount ?? 0, 40))
        #expect(close(sorted.last?.amount ?? 0, 10))
        #expect(Set(sorted.dropFirst().dropLast().map(\.amount)) == Set([20.0, 30.0]))
    }

    // MARK: - Owed status (the list-row / ledger-card tint rule)

    @Test func owedStatusUpcomingForFutureDatedWork() {
        let sub = TS.subcontractor()
        TS.oweSub(sub, 300, date: startOfToday.addingTimeInterval(3 * 86_400))
        #expect(sub.owedStatus == .upcoming)
    }

    @Test func owedStatusPastDueOnceIncurred() {
        let sub = TS.subcontractor()
        TS.oweSub(sub, 300, date: startOfToday.addingTimeInterval(-86_400))
        #expect(sub.owedStatus == .pastDue)
    }

    /// BOUNDARY: the rule is `date < startOfToday`, so work dated TODAY is upcoming, not past due.
    @Test func owedStatusTodayIsUpcomingNotPastDue() {
        let today = TS.subcontractor()
        TS.oweSub(today, 300, date: startOfToday)
        #expect(today.owedStatus == .upcoming)

        let aSecondEarlier = TS.subcontractor()
        TS.oweSub(aSecondEarlier, 300, date: startOfToday.addingTimeInterval(-1))
        #expect(aSecondEarlier.owedStatus == .pastDue)
    }

    @Test func owedStatusIsPastDueIfAnySingleEntryIs() {
        let sub = TS.subcontractor()
        TS.oweSub(sub, 100, date: startOfToday.addingTimeInterval(5 * 86_400))
        TS.oweSub(sub, 100, date: startOfToday.addingTimeInterval(-5 * 86_400))
        #expect(sub.owedStatus == .pastDue)
    }

    @Test func owedStatusIgnoresAlreadyPaidOldEntries() {
        let sub = TS.subcontractor()
        TS.paySub(sub, 5_000, date: startOfToday.addingTimeInterval(-90 * 86_400))
        TS.oweSub(sub, 100, date: startOfToday.addingTimeInterval(2 * 86_400))
        #expect(sub.owedStatus == .upcoming)
    }

    /// `OwedStatus` is shared with Employee — this is its one home for the tint + subtitle copy.
    @Test func owedStatusTintAndSubtitleCopy() {
        // Law 32: past-due wears the fleet statusCritical token, not raw red.
        #expect(OwedStatus.pastDue.tint(in: .light) == GLTheme.resolved(GLTheme.statusCritical, in: .light))
        // The gold now comes from the shared package (GLColor was deleted with the
        // GoldLifeUI migration). Same values either side, so this still pins that an
        // upcoming payment is tinted with the brand accent rather than a status hue.
        #expect(OwedStatus.upcoming.tint(in: .light) == GLTheme.resolved(GLTheme.accentFill, in: .light))
        #expect(OwedStatus.upcoming.tint(in: .dark) == GLTheme.resolved(GLTheme.accentFill, in: .dark))
        // Every status resolves to real color data in both schemes — never a trap on `.none`.
        for scheme in [ColorScheme.light, .dark] {
            _ = OwedStatus.none.tint(in: scheme)
            _ = OwedStatus.upcoming.tint(in: scheme)
            _ = OwedStatus.pastDue.tint(in: scheme)
        }

        let base = "Owed: " + 500.0.formatted(.currency(code: "USD"))
        #expect(OwedStatus.none.owedSubtitle(500) == base)
        #expect(OwedStatus.upcoming.owedSubtitle(500) == base)
        #expect(OwedStatus.pastDue.owedSubtitle(500).hasPrefix(base))
        #expect(OwedStatus.pastDue.owedSubtitle(500).hasSuffix("Past due"))
        // Zero and negative balances still format (the row shows whatever the ledger nets to).
        #expect(OwedStatus.none.owedSubtitle(0) == "Owed: " + 0.0.formatted(.currency(code: "USD")))
        #expect(OwedStatus.none.owedSubtitle(-25).contains("25"))
    }

    // MARK: - The $600 / $2,000 1099-NEC threshold

    @Test func thresholdIsYearAware() {
        #expect(close(Subcontractor.form1099Threshold(for: 1999), 600))
        #expect(close(Subcontractor.form1099Threshold(for: 2024), 600))
        #expect(close(Subcontractor.form1099Threshold(for: 2025), 600))
        #expect(close(Subcontractor.form1099Threshold(for: 2026), 2_000))
        #expect(close(Subcontractor.form1099Threshold(for: 2099), 2_000))
        #expect(close(Subcontractor.form1099Threshold(for: 0), 600))     // nonsense year → old bar
        #expect(close(Subcontractor.form1099Threshold(for: -1), 600))
    }

    /// The bar is inclusive to the half cent, year-aware ($600 through 2025, $2,000 from 2026 —
    /// OBBBA), and summed across the year's payments.
    @Test func requires1099BoundaryUsesHalfCentTolerance() {
        let just2025 = TS.subcontractor()
        TS.paySub(just2025, 599.996, date: TS.day(2025, 5, 1))
        #expect(just2025.requires1099(year: 2025))       // within the half-cent tolerance

        let under2025 = TS.subcontractor()
        TS.paySub(under2025, 599.99, date: TS.day(2025, 5, 1))
        #expect(!under2025.requires1099(year: 2025))

        let just2026 = TS.subcontractor()
        TS.paySub(just2026, 1_999.996, date: TS.day(2026, 5, 1))
        #expect(just2026.requires1099(year: 2026))

        let under2026 = TS.subcontractor()
        TS.paySub(under2026, 1_999.99, date: TS.day(2026, 5, 1))
        #expect(!under2026.requires1099(year: 2026))

        let midway2026 = TS.subcontractor()
        TS.paySub(midway2026, 800, date: TS.day(2026, 3, 1))
        #expect(!midway2026.requires1099(year: 2026))    // $800 cleared the OLD bar, not 2026's $2,000

        let summed2026 = TS.subcontractor()
        TS.paySub(summed2026, 1_200, date: TS.day(2026, 1, 1))
        TS.paySub(summed2026, 800, date: TS.day(2026, 2, 1))
        #expect(summed2026.requires1099(year: 2026))     // $2,000 exactly, across two payments → required
        #expect(!summed2026.requires1099(year: 2025))    // none paid in 2025
    }

    @Test func owedMoneyNeverTriggersA1099() {
        let sub = TS.subcontractor()
        TS.oweSub(sub, 25_000, date: TS.day(2026, 1, 1))
        #expect(!sub.requires1099(year: 2026))
        #expect(close(sub.totalPaid(year: 2026), 0))
        let totals = Subcontractor1099Summary.forYear([sub], year: 2026)
        #expect(close(totals.totalPaid, 0) && totals.count1099 == 0)
    }

    /// The roll-up sums the year's PAID money only — owed rows, other years, and empty subs all
    /// fall out — and counts the subs over the bar.
    @Test func yearRollUpAcrossAMixedRoster() {
        let over = TS.subcontractor(first: "O", last: "Ver")
        TS.paySub(over, 2_500, date: TS.day(2026, 4, 1))
        let under = TS.subcontractor(first: "U", last: "Nder")
        TS.paySub(under, 900, date: TS.day(2026, 4, 1))
        let owedOnly = TS.subcontractor(first: "W", last: "Aiting")
        TS.oweSub(owedOnly, 4_000, date: TS.day(2026, 4, 1))
        let prior = TS.subcontractor(first: "P", last: "Rior")
        TS.paySub(prior, 5_000, date: TS.day(2025, 4, 1))       // wrong year — excluded from 2026
        let empty = TS.subcontractor(first: "E", last: "Mpty")

        let totals = Subcontractor1099Summary.forYear([over, under, owedOnly, prior, empty], year: 2026)
        #expect(close(totals.totalPaid, 3_400))
        #expect(totals.count1099 == 1)

        let none = Subcontractor1099Summary.forYear([], year: 2026)
        #expect(close(none.totalPaid, 0) && none.count1099 == 0)
    }

    // MARK: - Display names / initials (unicode + whitespace)

    @Test func displayNamesTrimAndFallBack() {
        #expect(TS.subcontractor(first: "Luis", last: "Mendoza").fullName == "Luis Mendoza")
        #expect(TS.subcontractor(first: "Luis", last: "Mendoza").listDisplayName == "Mendoza, Luis")
        #expect(TS.subcontractor(first: "  ", last: "  ", business: "  ").listDisplayName == "No name")
        #expect(TS.subcontractor(first: "  ", last: "  ", business: " Boyd Electric ").listDisplayName == "Boyd Electric")
        #expect(TS.subcontractor(first: "Ann", last: "  ").listDisplayName == "Ann")
        #expect(TS.subcontractor(first: "  ", last: "Lee").listDisplayName == "Lee")
        #expect(TS.subcontractor(first: " Ann ", last: " Lee ").fullName == "Ann Lee")
        // A whitespace-only business name must not become the 1099 payee.
        #expect(TS.subcontractor(first: "Ann", last: "Lee", business: "   ").payeeName == "Ann Lee")
        #expect(TS.subcontractor(first: "Ann", last: "Lee", business: "Lee Tile").payeeName == "Lee Tile")
        #expect(TS.subcontractor(first: "", last: "", business: "").payeeName == "")
    }

    @Test func initialsHandleUnicodeAndEmpties() {
        #expect(TS.subcontractor(first: "Luis", last: "Mendoza").initials == "LM")
        #expect(TS.subcontractor(first: "\u{00E9}mile", last: "dupont").initials == "\u{00C9}D")
        #expect(TS.subcontractor(first: "", last: "", business: "\u{00F8}re Tile").initials == "\u{00D8}")
        #expect(TS.subcontractor(first: "  ", last: "  ", business: "  ").initials == "?")
        #expect(TS.subcontractor(first: "Ann", last: "  ").initials == "A")
    }

    // MARK: - W-9 / TIN capture (Keychain-backed, per record)

    @Test func einAndSsnTINsRoundTripIndependently() {
        let ein = TS.subcontractor(first: "E", last: "In")
        let ssn = TS.subcontractor(first: "S", last: "Sn")
        defer { ein.clearSecureTIN(); ssn.clearSecureTIN() }

        ein.w9TINType = .ein
        #expect(ein.updateTIN("12-3456789"))
        ssn.w9TINType = .ssn
        #expect(ssn.updateTIN("123-45-6789"))

        #expect(ein.secureTIN == "12-3456789" && ein.w9TINType == .ein && ein.hasTIN)
        #expect(ssn.secureTIN == "123-45-6789" && ssn.w9TINType == .ssn && ssn.hasTIN)
        #expect(ein.tinKey != ssn.tinKey && !ein.tinKey.isEmpty)

        // Masked display is four bullets + the last four, whichever grouping was stored.
        #expect(ein.maskedTIN == "\u{2022}\u{2022}\u{2022}\u{2022} 6789")
        #expect(ssn.maskedTIN == "\u{2022}\u{2022}\u{2022}\u{2022} 6789")
    }

    @Test func clearingOneSubsTINLeavesTheOthersAlone() {
        let a = TS.subcontractor(first: "A", last: "One")
        let b = TS.subcontractor(first: "B", last: "Two")
        defer { a.clearSecureTIN(); b.clearSecureTIN() }
        a.updateTIN("111-11-1111")
        b.updateTIN("222-22-2222")
        a.clearSecureTIN()
        #expect(!a.hasTIN && a.secureTIN == "" && a.maskedTIN == "")
        #expect(a.tinKey != "")                    // the key survives, only the secret is gone
        #expect(b.secureTIN == "222-22-2222")
    }

    @Test func updateTINTrimsAndOverwrites() {
        let sub = TS.subcontractor()
        defer { sub.clearSecureTIN() }
        #expect(sub.updateTIN("   12-3456789   "))
        #expect(sub.secureTIN == "12-3456789")
        #expect(sub.updateTIN("98-7654321"))
        #expect(sub.secureTIN == "98-7654321")     // replaced, not appended
        #expect(sub.updateTIN("   "))              // whitespace-only clears
        #expect(sub.secureTIN == "" && !sub.hasTIN)
    }

    @Test func blankTINOnAFreshSubNeverAllocatesAKey() {
        let sub = Subcontractor()
        #expect(sub.updateTIN(""))
        #expect(sub.tinKey == "")
        #expect(sub.updateTIN("\n\t "))
        #expect(sub.tinKey == "")
        #expect(sub.secureTIN == "" && !sub.hasTIN && sub.maskedTIN == "")
        sub.clearSecureTIN()                       // no key → no-op, must not trap
        #expect(sub.tinKey == "")
    }

    /// DOCUMENTS CURRENT BEHAVIOR: the model layer does no length validation. A short/malformed TIN
    /// is stored verbatim; only the UI (TINField) and the 1099 sheet's 9-digit gate stop it reaching
    /// a filed form. `maskedTIN` degrades to "" below four digits rather than leaking a partial ID.
    @Test func malformedAndShortTINsAreStoredButMaskUnhelpfully() {
        let short = TS.subcontractor(first: "S", last: "Hort")
        let four = TS.subcontractor(first: "F", last: "Our")
        let junk = TS.subcontractor(first: "J", last: "Unk")
        defer { short.clearSecureTIN(); four.clearSecureTIN(); junk.clearSecureTIN() }

        short.updateTIN("123")
        #expect(short.hasTIN)                      // stored, no complaint
        #expect(short.maskedTIN == "")             // …but nothing to mask

        four.updateTIN("1234")
        #expect(four.maskedTIN.hasSuffix("1234") && four.maskedTIN.count == 9)

        junk.updateTIN("not-a-tin")
        #expect(junk.hasTIN && junk.secureTIN == "not-a-tin")
        #expect(junk.maskedTIN == "")              // zero ASCII digits
    }

    @Test func maskedTINCountsOnlyASCIIDigits() {
        let sub = TS.subcontractor()
        defer { sub.clearSecureTIN() }
        sub.updateTIN("\u{0661}\u{0662}\u{0663}\u{0664}")   // Arabic-Indic 1234
        #expect(sub.hasTIN)
        #expect(sub.maskedTIN == "")               // non-ASCII numerals are not digits here
        sub.updateTIN("12\u{0663}4-5678")          // mixed: 7 ASCII digits
        #expect(sub.maskedTIN.hasSuffix("5678"))
    }

    @Test func tinTypeRawRoundTripsAndRejectsGarbage() {
        let sub = TS.subcontractor()
        #expect(sub.w9TINType == nil && sub.w9TINTypeRaw == nil)
        sub.w9TINType = .ssn
        #expect(sub.w9TINTypeRaw == W9TINType.ssn.rawValue && sub.w9TINType == .ssn)
        sub.w9TINType = .ein
        #expect(sub.w9TINType == .ein)
        sub.w9TINTypeRaw = "itin"                  // an unknown raw (a future/corrupt value)
        #expect(sub.w9TINType == nil)
        sub.w9TINType = nil
        #expect(sub.w9TINTypeRaw == nil && sub.w9TINType == nil)
    }

    /// Switching the ID type does NOT re-group an already-stored string — the stored value keeps
    /// whatever dashes it was written with, so the type is a label, not a re-formatter.
    @Test func switchingTINTypeDoesNotRewriteTheStoredValue() {
        let sub = TS.subcontractor()
        defer { sub.clearSecureTIN() }
        sub.w9TINType = .ssn
        sub.updateTIN("123-45-6789")
        sub.w9TINType = .ein
        #expect(sub.secureTIN == "123-45-6789")
        #expect(sub.maskedTIN.hasSuffix("6789"))
    }

    /// DEFECT (documented): a zero-byte upload counts as "W-9 on file" — the badge and the Face ID
    /// gate both switch on, but there is no readable PDF behind them.
    @Test func w9OnFileFlagIsPresenceOnlyNotValidity() {
        let sub = TS.subcontractor()
        #expect(!sub.hasW9OnFile)
        sub.w9Data = Data()
        sub.w9Name = ""
        #expect(sub.hasW9OnFile)                   // zero bytes still reads as "on file"
        sub.w9Data = Data("%PDF-1.4".utf8)
        sub.w9Name = "Mendoza-W9.pdf"
        #expect(sub.hasW9OnFile && sub.w9Name == "Mendoza-W9.pdf")
        sub.w9Data = nil
        #expect(!sub.hasW9OnFile)
    }

    @Test func secureTINStorePerSubAccountsAreDistinctAndScoped() {
        let key = UUID().uuidString
        let account = SecureTINStore.subcontractorAccount(key)
        #expect(account.hasSuffix(key))
        #expect(SecureTINStore.subcontractorAccount("a") != SecureTINStore.subcontractorAccount("b"))
        #expect(SecureTINStore.read(account: account) == "")     // nothing stored yet
        #expect(SecureTINStore.write("55-5555555", account: account))
        #expect(SecureTINStore.read(account: account) == "55-5555555")
        #expect(SecureTINStore.write("", account: account))      // clearing an existing item succeeds
        #expect(SecureTINStore.read(account: account) == "")
        #expect(SecureTINStore.write("", account: account))      // clearing a MISSING item also succeeds
    }

    // MARK: - TIN formatting (the field's atomic formatter)

    @Test func tinFormatterRegroupsTheSameDigitsWhenTypeSwitches() {
        let ssn = TINFormatter.format("123456789", kind: .ssn)
        #expect(ssn == "123-45-6789")
        #expect(TINFormatter.format(ssn, kind: .ein) == "12-3456789")
        #expect(TINFormatter.format(TINFormatter.format(ssn, kind: .ein), kind: .ssn) == "123-45-6789")
    }

    @Test func tinFormatterEdges() {
        #expect(TINFormatter.format("", kind: .ein) == "")
        #expect(TINFormatter.format("       ", kind: .ssn) == "")
        #expect(TINFormatter.format("0", kind: .ein) == "0")
        #expect(TINFormatter.format("000000000", kind: .ssn) == "000-00-0000")
        #expect(TINFormatter.format("12", kind: .ein) == "12")
        #expect(TINFormatter.format("1234567890", kind: .ein) == "12-3456789")   // capped at 9
        // An emoji-laden paste keeps only ASCII digits.
        #expect(TINFormatter.format("1\u{1F600}2\u{1F600}3", kind: .ssn) == "123")
    }

    // MARK: - 1099-NEC money formatting (must never localize)

    @Test func box1aAmountIsAlwaysUSStyle() {
        #expect(Form1099NECPDF.box1aAmount(3_050) == "3,050.00")
        #expect(Form1099NECPDF.box1aAmount(0) == "0.00")
        #expect(Form1099NECPDF.box1aAmount(0.5) == "0.50")
        #expect(Form1099NECPDF.box1aAmount(1_234.567) == "1,234.57")     // rounds to cents
        #expect(Form1099NECPDF.box1aAmount(1_234_567.891) == "1,234,567.89")
        #expect(Form1099NECPDF.box1aAmount(1_000_000) == "1,000,000.00")
        #expect(Form1099NECPDF.box1aAmount(-50) == "-50.00")
        #expect(Form1099NECPDF.box1aAmount(999_999_999.99) == "999,999,999.99")
    }

    // MARK: - RecordSubPaymentSheet: which entry modes are offered (decided once, at init)
    //
    // Guards the QA fix where clearing a sub's saved rate to $0 coerced an old hours entry to
    // Dollars, and a note-only re-save then silently zeroed its recorded hours. The sheet's init
    // only reads the passed models, so no container is needed.

    @Test func hoursModeSurvivesAClearedSavedRate() {
        let sub = TS.subcontractor()
        sub.hourlyRate = 0
        let entry = TS.oweSub(sub, 160, hours: 8)                  // $20/hr, derivable
        #expect(RecordSubPaymentSheet(subcontractor: sub, existing: entry).hasRate)
    }

    @Test func zeroAmountHoursEntryCannotDeriveARate() {
        let sub = TS.subcontractor()
        sub.hourlyRate = 0
        let entry = TS.oweSub(sub, 0, hours: 8)                    // nothing to divide
        #expect(!RecordSubPaymentSheet(subcontractor: sub, existing: entry).hasRate)

        sub.hourlyRate = 45                                        // …unless the profile has one
        #expect(RecordSubPaymentSheet(subcontractor: sub, existing: entry).hasRate)
    }

    @Test func belowToleranceHoursDoNotDeriveARate() {
        let sub = TS.subcontractor()
        sub.hourlyRate = 0
        let entry = TS.oweSub(sub, 500, hours: 0.004)              // 0.004 <= 0.005 → not "hours"
        #expect(!RecordSubPaymentSheet(subcontractor: sub, existing: entry).hasRate)

        let flat = TS.oweSub(sub, 250)                             // a plain flat amount, no hours at all
        #expect(!RecordSubPaymentSheet(subcontractor: sub, existing: flat).hasRate)
    }

    @Test func savedRateAloneUnlocksHourModesForANewEntry() {
        let withRate = TS.subcontractor()
        withRate.hourlyRate = 0.006                                // just over the tolerance
        #expect(RecordSubPaymentSheet(subcontractor: withRate, existing: nil).hasRate)

        let none = TS.subcontractor()
        none.hourlyRate = 0
        #expect(!RecordSubPaymentSheet(subcontractor: none, existing: nil).hasRate)

        let negative = TS.subcontractor()
        negative.hourlyRate = -10                                  // nonsense rate → dollars only
        #expect(!RecordSubPaymentSheet(subcontractor: negative, existing: nil).hasRate)
    }

    // MARK: - Render: SubcontractorDetailScreen state variants

    @Test func rendersDetailWithNoPaymentsInBothSchemes() throws {
        let world = try TestStore.demoWorld()
        let sub = TS.subcontractor(first: "Nora", last: "New", in: world.context)
        GLTestHost.renderBothSchemes(SubcontractorDetailScreen(subcontractor: sub), container: world.container)
    }

    @Test func rendersDetailWithOwedPastDueAndPaidMixed() throws {
        let world = try TestStore.demoWorld()
        let ctx = world.context
        let sub = TS.subcontractor(first: "Dana", last: "Cole", in: ctx)
        sub.hourlyRate = 55
        TS.paySub(sub, 900, date: startOfToday.addingTimeInterval(-20 * 86_400),
                  detail: "Demo + haul-off", customer: world.primary, in: ctx)
            .paidDate = startOfToday.addingTimeInterval(-18 * 86_400)
        TS.oweSub(sub, 275, hours: 5, date: startOfToday.addingTimeInterval(-4 * 86_400),
                  detail: "5 hrs \u{2014} punch list", in: ctx)
        TS.oweSub(sub, 130, date: startOfToday.addingTimeInterval(-2 * 86_400),
                  customer: world.primary, in: ctx)                // no detail → customer subtitle
        GLTestHost.renderBothSchemes(SubcontractorDetailScreen(subcontractor: sub), container: world.container)
        #expect(sub.owedStatus == .pastDue)
    }

    @Test func rendersDetailWithUpcomingOwedOnly() throws {
        let world = try TestStore.demoWorld()
        let sub = TS.subcontractor(first: "Uri", last: "Pending", in: world.context)
        TS.oweSub(sub, 480, date: startOfToday.addingTimeInterval(6 * 86_400), in: world.context)
        #expect(sub.owedStatus == .upcoming)
        GLTestHost.render(SubcontractorDetailScreen(subcontractor: sub), container: world.container)
    }

    /// More than five entries → the "View All" affordance, plus the divider-between-rows branch.
    @Test func rendersDetailWithMoreThanFiveEntries() throws {
        let world = try TestStore.demoWorld()
        let ctx = world.context
        let sub = TS.subcontractor(first: "Vic", last: "Volume", in: ctx)
        sub.hourlyRate = 40
        for i in 1...9 {
            let day = startOfToday.addingTimeInterval(Double(-i) * 86_400)
            let tagged = i.isMultiple(of: 2) ? world.primary : nil
            let detail = i.isMultiple(of: 4) ? "" : "Day \(i)"
            let entry = i.isMultiple(of: 2)
                ? TS.paySub(sub, Double(i) * 100, date: day, detail: detail, customer: tagged, in: ctx)
                : TS.oweSub(sub, Double(i) * 100, date: day, detail: detail, customer: tagged, in: ctx)
            entry.hours = Double(i)
            entry.method = i.isMultiple(of: 3) ? .zelle : .check
        }
        #expect(sub.sortedPayments.count == 9)
        GLTestHost.render(SubcontractorDetailScreen(subcontractor: sub), container: world.container)
    }

    /// Over the threshold → the "1099-NEC due" flag renders in the ledger card.
    @Test func rendersDetailOverThe1099Threshold() throws {
        let world = try TestStore.demoWorld()
        let sub = TS.subcontractor(first: "Tia", last: "Topaid", business: "Topaid Masonry", in: world.context)
        TS.paySub(sub, 6_400, date: .now, detail: "Slab prep", in: world.context)
        #expect(sub.requires1099(year: thisYear))
        GLTestHost.renderBothSchemes(SubcontractorDetailScreen(subcontractor: sub), container: world.container)
    }

    /// W-9 on file + a profile photo → the checkmark badge, the file name, and "Remove Photo".
    @Test func rendersDetailWithW9OnFileAndAProfilePhoto() throws {
        let world = try TestStore.demoWorld()
        let sub = TS.subcontractor(first: "Wes", last: "Nine", business: "Nine Electric", in: world.context)
        sub.w9Data = Data("%PDF-1.4 nine".utf8)
        sub.w9Name = "Nine-Electric-W9.pdf"
        sub.profileImageData = (UIImage(systemName: "person.fill") ?? UIImage()).jpegData(compressionQuality: 0.8)
        sub.w9TINType = .ein
        defer { sub.clearSecureTIN() }
        sub.updateTIN("12-3456789")
        #expect(sub.hasW9OnFile && sub.hasTIN)
        GLTestHost.renderBothSchemes(SubcontractorDetailScreen(subcontractor: sub), container: world.container)
    }

    /// Inactive + business-name-only (no person) → the "Inactive" capsule and the skipped subtitle.
    @Test func rendersDetailInactiveAndBusinessOnly() throws {
        let world = try TestStore.demoWorld()
        let businessOnly = TS.subcontractor(first: "", last: "", business: "Cutwater Concrete",
                                            isActive: false, in: world.context)
        GLTestHost.render(SubcontractorDetailScreen(subcontractor: businessOnly), container: world.container)

        let personAndBusiness = TS.subcontractor(first: "Kay", last: "Ruiz", business: "Ruiz Framing",
                                                 isActive: false, in: world.context)
        GLTestHost.render(SubcontractorDetailScreen(subcontractor: personAndBusiness), container: world.container)
    }

    /// The record vanished out from under the screen (deleted on another device) → DeletedRecordView.
    /// Rendered against a DIFFERENT container so the @Query genuinely can't find it, without
    /// touching an invalidated model object.
    @Test func rendersDetailForARecordThatNoLongerExists() throws {
        let owning = try TestStore.demoWorld()
        let orphan = TS.subcontractor(first: "Gone", last: "Away", in: owning.context)
        TS.oweSub(orphan, 200, date: .now, in: owning.context)
        let other = try TestStore.demoWorld()
        GLTestHost.renderBothSchemes(SubcontractorDetailScreen(subcontractor: orphan), container: other.container)
    }

    /// Accessibility type sizes reflow the ledger card's two-column header and the W-9 rows.
    @Test func rendersDetailAtAccessibilityTypeSizes() throws {
        let world = try TestStore.demoWorld()
        let sub = try world.sub("Mendoza")
        GLTestHost.render(SubcontractorDetailScreen(subcontractor: sub), container: world.container,
                          typeSize: .accessibility3)
        GLTestHost.render(SubcontractorDetailScreen(subcontractor: sub), container: world.container,
                          typeSize: .xSmall)
        GLTestHost.render(SubcontractorDetailScreen(subcontractor: sub), container: world.container,
                          typeSize: .accessibility5, size: CGSize(width: 320, height: 900))
    }

    /// Both demo subs, both schemes — one over the threshold with an EIN, one with an owed entry.
    @Test func rendersEveryDemoSubcontractorDetail() throws {
        let world = try TestStore.demoWorld()
        #expect(world.subcontractors.count >= 2)
        for sub in world.subcontractors {
            GLTestHost.renderBothSchemes(SubcontractorDetailScreen(subcontractor: sub), container: world.container)
        }
    }

    /// Regular width (iPad / split view) takes the `maxWidth: 640` centred-column branch.
    @Test func rendersSubcontractorSurfacesAtIPadWidth() throws {
        let world = try TestStore.demoWorld()
        let sub = try world.sub("Boyd")
        let container = world.container
        let pad = GLTestHost.pad
        GLTestHost.render(SubcontractorDetailScreen(subcontractor: sub), container: container, size: pad)
        GLTestHost.render(SubcontractorDetailsScreen(subcontractor: sub), container: container, size: pad)
        GLTestHost.render(SubcontractorFormScreen(editing: sub), container: container, size: pad)
        GLTestHost.render(AllActivitySheet(subcontractor: sub), container: container, size: pad)
        GLTestHost.render(RecordSubPaymentSheet(subcontractor: sub, existing: nil), container: container, size: pad)
        GLTestHost.render(PaySubcontractorSheet(subcontractor: sub), container: container, size: pad)
        GLTestHost.render(Form1099NECSheet(subcontractor: sub), container: container, size: pad)
        Form1099NECPDF.cleanUp()
    }

    // MARK: - Render: SubcontractorDetailsScreen ("More Info")

    @Test func rendersMoreInfoEmptyAndFullyPopulated() throws {
        let world = try TestStore.demoWorld()

        let bare = TS.subcontractor(first: "Min", last: "Imal", in: world.context)
        GLTestHost.renderBothSchemes(SubcontractorDetailsScreen(subcontractor: bare), container: world.container)

        let full = TS.subcontractor(first: "Full", last: "House", business: "House Tile Co",
                                    email: "full@housetile.example", phone: "(850) 555-0123",
                                    address: Address(street1: "904 Industrial Dr", street2: "Suite 4",
                                                     city: "Miami", state: "FL", postalCode: "32310"),
                                    in: world.context)
        full.hourlyRate = 62.5
        full.notes = "Prefers morning starts. Has own wet saw."
        full.w9TINType = .ein
        defer { full.clearSecureTIN() }
        full.updateTIN("12-3456789")
        GLTestHost.render(SubcontractorDetailsScreen(subcontractor: full), container: world.container, scheme: .dark)
        GLTestHost.render(SubcontractorDetailsScreen(subcontractor: full), container: world.container,
                          typeSize: .accessibility3)
    }

    /// The Tax card's other TIN branch: an SSN label, and a TIN stored with no type set at all.
    @Test func rendersMoreInfoWithSSNAndTypelessTIN() throws {
        let world = try TestStore.demoWorld()
        let ssn = TS.subcontractor(first: "Sal", last: "Sosa", in: world.context)
        ssn.hourlyRate = 30
        defer { ssn.clearSecureTIN() }
        ssn.w9TINType = .ssn
        ssn.updateTIN("123-45-6789")
        GLTestHost.render(SubcontractorDetailsScreen(subcontractor: ssn), container: world.container)

        let typeless = TS.subcontractor(first: "Ty", last: "Peless", in: world.context)
        defer { typeless.clearSecureTIN() }
        typeless.updateTIN("987654321")            // stored, but w9TINType stays nil → "TIN ••••"
        #expect(typeless.hasTIN && typeless.w9TINType == nil)
        GLTestHost.render(SubcontractorDetailsScreen(subcontractor: typeless), container: world.container)
    }

    // MARK: - Render: SubcontractorFormScreen (add / edit / TIN reveal states)

    @Test func rendersFormForANewSubcontractor() throws {
        let world = try TestStore.demoWorld()
        GLTestHost.renderBothSchemes(SubcontractorFormScreen(), container: world.container)
        GLTestHost.render(SubcontractorFormScreen(onSave: { _ in }), container: world.container)   // the iPad add-flow callback
    }

    /// Editing a sub WITH a stored TIN: the masked row, the locked type picker, and the
    /// "Unlock to change the ID type." footer.
    @Test func rendersFormEditingWithAStoredTIN() throws {
        let world = try TestStore.demoWorld()
        let sub = try world.sub("Mendoza")
        #expect(sub.hasTIN && sub.w9TINType == .ein)
        GLTestHost.renderBothSchemes(SubcontractorFormScreen(editing: sub), container: world.container)
        GLTestHost.render(SubcontractorFormScreen(editing: sub), container: world.container,
                          typeSize: .accessibility3)
    }

    /// Editing a sub with NO TIN: the picker is enabled and the row reads "Tap to add".
    @Test func rendersFormEditingWithoutATIN() throws {
        let world = try TestStore.demoWorld()
        let sub = TS.subcontractor(first: "No", last: "Tin", business: "No Tin LLC",
                                   address: Address(street1: "12 Main", city: "Quincy", state: "FL", postalCode: "32351"),
                                   isActive: false, in: world.context)
        sub.hourlyRate = 35
        sub.notes = "Subs out drywall."
        #expect(!sub.hasTIN)
        GLTestHost.render(SubcontractorFormScreen(editing: sub), container: world.container)
    }

    /// An SSN-typed sub — TINField's other grouping, exercised through the form.
    @Test func rendersFormEditingAnSSNSub() throws {
        let world = try TestStore.demoWorld()
        let sub = try world.sub("Boyd")
        #expect(sub.w9TINType == .ssn)
        GLTestHost.render(SubcontractorFormScreen(editing: sub), container: world.container)
    }

    // MARK: - Render: the ledger sheets

    @Test func rendersAllActivitySheetEmptyAndPopulated() throws {
        let world = try TestStore.demoWorld()
        let empty = TS.subcontractor(first: "Zero", last: "Rows", in: world.context)
        GLTestHost.renderBothSchemes(AllActivitySheet(subcontractor: empty), container: world.container)

        let busy = try world.sub("Boyd")
        GLTestHost.renderBothSchemes(AllActivitySheet(subcontractor: busy), container: world.container)
        GLTestHost.render(AllActivitySheet(subcontractor: busy), container: world.container,
                          typeSize: .accessibility3)
    }

    @Test func rendersRecordSubPaymentSheetEveryEntryShape() throws {
        let world = try TestStore.demoWorld()
        let ctx = world.context

        // No saved rate → Dollars-only (the "add a pay rate" footer).
        let flat = TS.subcontractor(first: "Flat", last: "Rate", in: ctx)
        GLTestHost.render(RecordSubPaymentSheet(subcontractor: flat, existing: nil), container: world.container)

        // Saved rate → the Range / Hours / Dollars picker.
        let hourly = TS.subcontractor(first: "Hour", last: "Ly", in: ctx)
        hourly.hourlyRate = 45
        GLTestHost.render(RecordSubPaymentSheet(subcontractor: hourly, existing: nil), container: world.container,
                          scheme: .light)

        // Editing an hours entry priced at a DIFFERENT rate → the "Reset to saved rate" button.
        let hoursEntry = TS.oweSub(hourly, 320, hours: 8, date: startOfToday.addingTimeInterval(-86_400),
                                   detail: "8 hrs \u{2014} backsplash", customer: world.primary, in: ctx)
        GLTestHost.render(RecordSubPaymentSheet(subcontractor: hourly, existing: hoursEntry), container: world.container)

        // Editing a PAID entry → the paid-date + method rows and the delete section.
        let paidEntry = TS.paySub(hourly, 1_200, date: startOfToday.addingTimeInterval(-10 * 86_400),
                                  method: .zelle, detail: "Deposit", in: ctx)
        paidEntry.paidDate = startOfToday.addingTimeInterval(-9 * 86_400)
        GLTestHost.render(RecordSubPaymentSheet(subcontractor: hourly, existing: paidEntry), container: world.container,
                          scheme: .light)

        // Editing a flat OWED entry on a sub whose saved rate was since cleared to $0.
        hourly.hourlyRate = 0
        let flatEntry = TS.oweSub(hourly, 250, date: .now, in: ctx)
        GLTestHost.render(RecordSubPaymentSheet(subcontractor: hourly, existing: flatEntry), container: world.container)
    }

    @Test func rendersPaySubcontractorSheetOwedAndSettled() throws {
        let world = try TestStore.demoWorld()
        let ctx = world.context

        // Nothing owed → "Nothing is owed right now." and a disabled Pay in full.
        let settled = TS.subcontractor(first: "All", last: "Square", in: ctx)
        TS.paySub(settled, 500, date: .now, in: ctx)
        #expect(!settled.hasOutstanding)
        GLTestHost.renderBothSchemes(PaySubcontractorSheet(subcontractor: settled), container: world.container)

        // Owed → the amount prefills to the full balance ("Full amount entered").
        let owing = TS.subcontractor(first: "Owe", last: "Ing", in: ctx)
        TS.oweSub(owing, 300, date: startOfToday.addingTimeInterval(-86_400), in: ctx)
        TS.oweSub(owing, 175, date: startOfToday.addingTimeInterval(-2 * 86_400), in: ctx).method = .venmo
        #expect(close(owing.outstanding, 475))
        GLTestHost.render(PaySubcontractorSheet(subcontractor: owing), container: world.container)
        GLTestHost.render(PaySubcontractorSheet(subcontractor: owing), container: world.container,
                          typeSize: .accessibility3)

        // A net-credit ledger: outstanding is negative, so the sheet must still build.
        let credit = TS.subcontractor(first: "Cred", last: "It", in: ctx)
        TS.oweSub(credit, -60, date: .now, in: ctx)
        #expect(!credit.hasOutstanding)
        GLTestHost.render(PaySubcontractorSheet(subcontractor: credit), container: world.container)
    }

    // MARK: - Render: the W-9 document screen

    @Test func rendersW9DetailWithAndWithoutADocument() throws {
        let world = try TestStore.demoWorld()
        let none = TS.subcontractor(first: "No", last: "Doc", in: world.context)
        GLTestHost.renderBothSchemes(SubcontractorW9DetailScreen(subcontractor: none), container: world.container)

        let onFile = TS.subcontractor(first: "Has", last: "Doc", business: "Doc Tile", in: world.context)
        onFile.w9Data = Data("%PDF-1.4 w9".utf8)
        onFile.w9Name = "Doc-Tile-W9.pdf"
        GLTestHost.renderBothSchemes(SubcontractorW9DetailScreen(subcontractor: onFile), container: world.container)

        // On file but nameless → the fallback file name ("W-9.pdf").
        let nameless = TS.subcontractor(first: "No", last: "Name", in: world.context)
        nameless.w9Data = Data("%PDF-1.4".utf8)
        nameless.w9Name = "   "
        GLTestHost.render(SubcontractorW9DetailScreen(subcontractor: nameless), container: world.container)
    }

    // MARK: - Render: the 1099-NEC sheet (missing-details vs generate)

    @Test func renders1099SheetWhenDetailsAreMissing() throws {
        let world = try TestStore.demoWorld()
        let noTIN = TS.subcontractor(first: "Miss", last: "Ing", business: "Missing Co", in: world.context)
        #expect(!noTIN.hasTIN)
        GLTestHost.renderBothSchemes(Form1099NECSheet(subcontractor: noTIN), container: world.container)
        GLTestHost.render(Form1099NECSheet(subcontractor: noTIN), container: world.container,
                          typeSize: .accessibility3)
    }

    /// A sub whose TIN is present but SHORT — the 9-digit gate must still route to the checklist.
    @Test func renders1099SheetWithAnIncompleteTIN() throws {
        let world = try TestStore.demoWorld()
        let short = TS.subcontractor(first: "Short", last: "Tin", business: "Short Tin Co", in: world.context)
        defer { short.clearSecureTIN() }
        short.w9TINType = .ssn
        short.updateTIN("123-45")                  // only 5 digits
        #expect(short.hasTIN && short.secureTIN.filter { $0.isASCII && $0.isNumber }.count != 9)
        GLTestHost.render(Form1099NECSheet(subcontractor: short), container: world.container)
    }

    /// The full generate path: DemoSeed gives the payer a name + EIN, and Mendoza has a 9-digit EIN.
    @Test func renders1099SheetForAFullyDocumentedSub() throws {
        let world = try TestStore.demoWorld()
        let sub = try world.sub("Mendoza")
        #expect(sub.secureTIN.filter { $0.isASCII && $0.isNumber }.count == 9)
        GLTestHost.renderBothSchemes(Form1099NECSheet(subcontractor: sub), container: world.container)
        Form1099NECPDF.cleanUp()
    }

    // MARK: - 1099-NEC PDF generation (the real IRS Copy B)

    /// No RunLoop spin inside these: `render` wipes its own temp root each call, so the file
    /// assertions must not be interleaved with anything else that renders a 1099.
    @Test func generatesA1099PDFAndItsPreviewImage() throws {
        let world = try TestStore.demoWorld()
        let sub = try world.sub("Mendoza")

        let url = try #require(Form1099NECPDF.render(payer: world.profile, recipient: sub,
                                                     amount: 3_050, year: 2025))
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(url.lastPathComponent == "Form-1099-NEC-Mendoza-Plumbing.pdf")
        let image = try #require(Form1099NECPDF.pageImage(from: url))
        #expect(image.size.width > 100 && image.size.height > 100)

        // Re-rendering the SAME payee lands in a fresh per-generation folder and wipes the prior
        // one, so no TIN-bearing PDF lingers behind a stale URL.
        let again = try #require(Form1099NECPDF.render(payer: world.profile, recipient: sub,
                                                       amount: 3_050, year: 2025))
        #expect(again != url)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(FileManager.default.fileExists(atPath: again.path))
        Form1099NECPDF.cleanUp()
        #expect(!FileManager.default.fileExists(atPath: again.path))
    }

    /// The payee name becomes the file name — unicode, punctuation, and emoji must not produce an
    /// unwritable path, and a nameless sub must not produce a stray dash.
    @Test func generates1099FileNamesSafelyForOddPayeeNames() throws {
        let world = try TestStore.demoWorld()
        let payer = world.profile

        let odd = TS.subcontractor(first: "", last: "", business: "R & R Tile / Stone \u{1F3D7}")
        let oddURL = try #require(Form1099NECPDF.render(payer: payer, recipient: odd, amount: 0, year: 2026))
        #expect(oddURL.lastPathComponent == "Form-1099-NEC-R-R-Tile-Stone.pdf")
        #expect(FileManager.default.fileExists(atPath: oddURL.path))

        // DOCUMENTS CURRENT BEHAVIOR: Foundation's `alphanumerics` set includes combining MARKS, so
        // an emoji variation selector (U+FE0F) is not treated as a separator and survives into the
        // generated file name. Harmless on disk, but it does reach the share sheet's title.
        let marked = TS.subcontractor(first: "", last: "", business: "Stone \u{1F3D7}\u{FE0F}")
        let markedURL = try #require(Form1099NECPDF.render(payer: payer, recipient: marked,
                                                          amount: 0, year: 2026))
        #expect(markedURL.lastPathComponent == "Form-1099-NEC-Stone-\u{FE0F}.pdf")
        #expect(markedURL.lastPathComponent != "Form-1099-NEC-Stone.pdf")

        let nameless = TS.subcontractor(first: "", last: "", business: "")
        let namelessURL = try #require(Form1099NECPDF.render(payer: payer, recipient: nameless,
                                                            amount: 0, year: 2026))
        #expect(namelessURL.lastPathComponent == "Form-1099-NEC.pdf")
        #expect(FileManager.default.fileExists(atPath: namelessURL.path))
        // Each render wipes the previous generation, so no TIN-bearing PDF lingers in tmp.
        #expect(!FileManager.default.fileExists(atPath: oddURL.path))
        #expect(!FileManager.default.fileExists(atPath: markedURL.path))
        Form1099NECPDF.cleanUp()
    }

    /// Blank payer, no TINs, a zero amount and a nonsense year still produce a page rather than
    /// trapping — an incomplete form is the caller's problem, not a crash.
    @Test func generates1099PDFEvenWithEmptyAndExtremeInputs() throws {
        let container = try TestStore.makeContainer()        // NOT seeded: an empty business profile
        let payer = BusinessProfile()
        container.mainContext.insert(payer)
        let sub = TS.subcontractor(first: "Edge", last: "Case")

        let zero = try #require(Form1099NECPDF.render(payer: payer, recipient: sub, amount: 0, year: 0))
        #expect(FileManager.default.fileExists(atPath: zero.path))

        let huge = try #require(Form1099NECPDF.render(payer: payer, recipient: sub,
                                                     amount: 987_654_321.99, year: 9999))
        #expect(FileManager.default.fileExists(atPath: huge.path))

        let negative = try #require(Form1099NECPDF.render(payer: payer, recipient: sub,
                                                         amount: -1_000, year: 2026))
        #expect(FileManager.default.fileExists(atPath: negative.path))
        #expect(Form1099NECPDF.pageImage(from: negative) != nil)
        Form1099NECPDF.cleanUp()
    }

    @Test func pageImageReturnsNilForAMissingOrNonPDFFile() throws {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("gl-not-here-\(UUID().uuidString).pdf")
        #expect(Form1099NECPDF.pageImage(from: missing) == nil)

        let junk = FileManager.default.temporaryDirectory
            .appendingPathComponent("gl-junk-\(UUID().uuidString).pdf")
        try Data("this is not a pdf".utf8).write(to: junk)
        defer { try? FileManager.default.removeItem(at: junk) }
        #expect(Form1099NECPDF.pageImage(from: junk) == nil)
    }

    @Test func cleanUpIsSafeToCallWithNothingGenerated() {
        Form1099NECPDF.cleanUp()
        Form1099NECPDF.cleanUp()               // idempotent — must not throw or trap
    }

    // MARK: - W-9 PDF (the business-side form the sub's W-9 mirrors)

    @Test func generatesAW9PDFAndItsPreviewImage() throws {
        let world = try TestStore.demoWorld()
        let profile = world.profile
        profile.w9TaxClassificationRaw = W9TaxClassification.llc.rawValue
        profile.w9LLCClassification = "S"

        let url = try #require(W9PDF.render(profile))
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(url.lastPathComponent.hasPrefix("Form-W-9"))
        #expect(W9PDF.pageImage(from: url) != nil)
        W9PDF.cleanUp()
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func generatesAW9PDFForEveryTaxClassification() throws {
        let world = try TestStore.demoWorld()
        let profile = world.profile
        for classification in W9TaxClassification.allCases {
            profile.w9TaxClassificationRaw = classification.rawValue
            #expect(W9PDF.render(profile) != nil)
        }
        // And with no classification at all (the `.none` switch arm).
        profile.w9TaxClassificationRaw = ""
        #expect(W9PDF.render(profile) != nil)
        W9PDF.cleanUp()
    }

    /// The stamped values must actually reach the page — a silently blank 1099 is the worst failure
    /// mode here, because it looks fine until the IRS reads it. Pull the text back out of the PDF.
    @Test func the1099PageCarriesThePayerRecipientAmountAndYear() throws {
        let world = try TestStore.demoWorld()
        let payer = world.profile
        let sub = try world.sub("Mendoza")

        let url = try #require(Form1099NECPDF.render(payer: payer, recipient: sub,
                                                     amount: 3_050, year: 2025))
        let text = try #require(PDFDocument(url: url)?.string)
        #expect(text.contains("Mendoza Plumbing"))          // recipient = the business payee name
        #expect(text.contains(payer.businessName))          // payer block
        #expect(text.contains("3,050.00"))                  // Box 1a, US grouping
        #expect(text.contains("2025"))                      // the full 4-digit tax year
        #expect(text.contains("12-3456789"))                // recipient EIN, grouped 2-7
        #expect(text.contains("904 Industrial Dr"))         // recipient street
        Form1099NECPDF.cleanUp()
    }

    /// A $0.00 1099 is a legitimate thing to generate (everything on file, nothing paid that year).
    @Test func generatesAZeroDollar1099ForAFullyDocumentedSub() throws {
        let world = try TestStore.demoWorld()
        let sub = TS.subcontractor(first: "Zed", last: "Ro", business: "Zero Paid Co", in: world.context)
        defer { sub.clearSecureTIN() }
        sub.w9TINType = .ssn
        sub.updateTIN("123-45-6789")
        #expect(close(sub.totalPaid(year: 2025), 0))

        let url = try #require(Form1099NECPDF.render(payer: world.profile, recipient: sub, amount: 0, year: 2025))
        let text = try #require(PDFDocument(url: url)?.string)
        #expect(text.contains("Zero Paid Co"))
        #expect(text.contains("0.00"))
        #expect(text.contains("123-45-6789"))               // SSN grouped 3-2-4
        Form1099NECPDF.cleanUp()
    }

    /// DOCUMENTS CURRENT BEHAVIOR: `formatTIN` falls back to printing the raw stored value when it
    /// isn't 9 digits. The sheet gates on 9 digits, so this only bites a direct/unguarded caller.
    @Test func aShortTINPrintsVerbatimOnTheForm() throws {
        let world = try TestStore.demoWorld()
        let sub = TS.subcontractor(first: "Short", last: "Id", business: "Short Id Co", in: world.context)
        defer { sub.clearSecureTIN() }
        sub.w9TINType = .ssn
        sub.updateTIN("123-45")

        let url = try #require(Form1099NECPDF.render(payer: world.profile, recipient: sub, amount: 100, year: 2025))
        let text = try #require(PDFDocument(url: url)?.string)
        #expect(text.contains("123-45"))                    // raw, ungrouped, on an official form
        Form1099NECPDF.cleanUp()
    }

    @Test func generatesASignedW9() throws {
        let world = try TestStore.demoWorld()
        let signature = UIImage(systemName: "signature") ?? UIImage()
        let url = try #require(W9PDF.render(world.profile, signatureImage: signature, signedDate: TS.day(2026, 3, 1)))
        #expect(FileManager.default.fileExists(atPath: url.path))
        W9PDF.cleanUp()
    }
}
