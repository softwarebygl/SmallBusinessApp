//
//  SubcontractorServiceTests.swift
//  GLSmallBusinessTests — Domain
//
//  The subcontractor save path shared by the Subcontractor form (all but tax fields), the Record
//  Amount / Pay Now sheets and the assistant. Pay Now's rules are pinned case by case: oldest
//  first, the mid-entry split with prorated hours, and the surplus entry.
//

import Foundation
import SwiftData
import Testing
@testable import GLSmallBusiness

@MainActor
@Suite(.serialized)
struct SubcontractorServiceTests {

    private let day1 = TS.day(2026, 9, 1)
    private let day2 = TS.day(2026, 9, 2)
    private let paidOn = TS.day(2026, 9, 12)

    // MARK: The subcontractor

    @Test func createTrimsSavesIsCappedAndNeverTouchesTaxFields() throws {
        let context = try DomainFixtures.context()
        let draft = SubcontractorDraft(firstName: " ", lastName: "", businessName: " Boyd Electric ",
                                       address: Address(street1: " 5 Elm ", street2: "", city: "Tally",
                                                        state: "FL", postalCode: "32301"),
                                       hourlyRate: 45, notes: " licensed ")
        let boyd = try DomainState.neverSubscribed.run { try SubcontractorService.create(draft, in: context) }
        #expect(boyd.businessName == "Boyd Electric" && boyd.notes == "licensed")
        #expect(boyd.addressStreet1 == "5 Elm" && boyd.addressStreet2 == "")
        #expect(boyd.hourlyRate == 45)
        #expect(boyd.tinKey.isEmpty && boyd.w9TINTypeRaw == nil && boyd.w9Data == nil)
        #expect(boyd.syncID != nil && !context.hasChanges)

        _ = try DomainState.neverSubscribed.run { try SubcontractorService.create(SubcontractorDraft(firstName: "Lee"), in: context) }
        #expect(DomainState.neverSubscribed.run { domainError { try SubcontractorService.create(SubcontractorDraft(firstName: "Max"), in: context) } }
                == .freeLimitReached(operation: "saveSubcontractor"))
        #expect(DomainState.subscribed.run { domainError { try SubcontractorService.create(SubcontractorDraft(email: "x@y.z"), in: context) } }
                == .nameRequired)
        #expect(DomainState.subscribed.run { domainError { try SubcontractorService.create(SubcontractorDraft(firstName: "A", hourlyRate: -3), in: context) } }
                == .negativeValue)
        #expect(try context.fetchCount(FetchDescriptor<Subcontractor>()) == FreeTier.subcontractors)
    }

    @Test func updateLeavesTaxFieldsAlone() throws {
        let context = try DomainFixtures.context()
        let sub = TS.subcontractor(in: context)
        sub.tinKey = "fixture-key"
        sub.w9TINType = .ein
        sub.w9Data = Data([1])
        context.saveChanges()
        var edit = SubcontractorDraft(sub)
        edit.phone = "(850) 555-0111"
        edit.isActive = false
        try DomainState.subscribed.run { try SubcontractorService.update(sub, with: edit, in: context) }
        #expect(sub.phone == "(850) 555-0111" && !sub.isActive)
        #expect(sub.tinKey == "fixture-key" && sub.w9TINType == .ein && sub.w9Data == Data([1]))
        #expect(!context.hasChanges)
        #expect(DomainState.lapsed.run { domainError { try SubcontractorService.update(sub, with: SubcontractorDraft(firstName: "Z"), in: context) } }
                == .readOnly(operation: "saveSubcontractor", lapsed: true))
        #expect(sub.firstName == "Lee")
    }

    @Test func photoAndCertificate() throws {
        let context = try DomainFixtures.context()
        let sub = TS.subcontractor(in: context)
        let expiry = TS.day(2027, 1, 31)
        try DomainState.subscribed.run {
            try SubcontractorService.setPhoto(Data([1]), for: sub, in: context)
            try DocumentService.set(.subcontractorCOI(sub), data: Data([2]), name: "coi.pdf", in: context)
            try DocumentService.setExpiry(.subcontractorCOI(sub), expiry, in: context)
        }
        #expect(sub.profileImageData == Data([1]) && sub.coiData == Data([2]) && sub.coiName == "coi.pdf")
        #expect(sub.coiExpiresOn == expiry && !context.hasChanges)
        #expect(DomainState.offline.run { domainError { try DocumentService.set(.subcontractorCOI(sub), data: nil, name: "", in: context) } }
                == .readOnly(operation: "deleteDocument", lapsed: false))
        try DomainState.subscribed.run {
            try DocumentService.set(.subcontractorCOI(sub), data: nil, name: "x", in: context)
            try DocumentService.setExpiry(.subcontractorCOI(sub), nil, in: context)
            try SubcontractorService.setPhoto(nil, for: sub, in: context)
        }
        #expect(sub.coiData == nil && sub.coiName == "" && sub.coiExpiresOn == nil && sub.profileImageData == nil)
    }

    // MARK: Ledger entries

    @Test func recordEntryInEachModeAndThePaidToggle() throws {
        let context = try DomainFixtures.context()
        let sub = TS.subcontractor(in: context)
        let customer = TS.customer(in: context)
        let start = day1.addingTimeInterval(8 * 3600)
        try DomainState.subscribed.run {
            let range = try SubcontractorService.recordEntry(
                .range(start: start, end: start.addingTimeInterval(5 * 3600), rate: 40),
                detail: " rough-in ", customer: customer, paidOn: nil, method: .check,
                for: sub, in: context)
            #expect(range.hours == 5 && range.amount == 200 && range.date == start)
            #expect(range.detail == "rough-in" && range.customer === customer && !range.isPaid)
            #expect(range.syncID != nil && !context.hasChanges)

            // Edit: to a paid flat amount — hours cleared, paid date and method written.
            try SubcontractorService.recordEntry(.dollars(350, on: day2), detail: "", customer: nil,
                                                 paidOn: paidOn, method: .zelle, for: sub,
                                                 editing: range, in: context)
            #expect(range.hours == 0 && range.amount == 350 && range.date == day2)
            #expect(range.paidDate == paidOn && range.method == .zelle && range.customer == nil)

            // Un-toggle paid.
            try SubcontractorService.recordEntry(.dollars(350, on: day2), detail: "", customer: nil,
                                                 paidOn: nil, method: .zelle, for: sub,
                                                 editing: range, in: context)
            #expect(!range.isPaid && close(sub.outstanding, 350))

            let hours = try SubcontractorService.recordEntry(.hours(3, on: day1, rate: 50), detail: "",
                                                             customer: nil, paidOn: nil, method: .check,
                                                             for: sub, in: context)
            #expect(hours.hours == 3 && hours.amount == 150)
        }
        #expect(sub.sortedPayments.count == 2)
    }

    @Test func recordEntryRefusalsAndDelete() throws {
        let context = try DomainFixtures.context()
        let sub = TS.subcontractor(in: context)
        let other = TS.subcontractor(first: "Other", in: context)
        let othersEntry = TS.oweSub(other, 100, in: context)
        let entry = TS.oweSub(sub, 100, in: context)
        context.saveChanges()
        DomainState.subscribed.run {
            #expect(domainError { try SubcontractorService.recordEntry(.dollars(0, on: day1), detail: "", customer: nil, paidOn: nil, method: .check, for: sub, in: context) }
                    == .amountRequired)
            #expect(domainError { try SubcontractorService.recordEntry(.hours(2, on: day1, rate: 0), detail: "", customer: nil, paidOn: nil, method: .check, for: sub, in: context) }
                    == .hoursAndRateRequired)
            #expect(domainError { try SubcontractorService.recordEntry(.dollars(5, on: day1), detail: "", customer: nil, paidOn: nil, method: .check, for: sub, editing: othersEntry, in: context) }
                    == .recordNotFound)
        }
        #expect(DomainState.lapsed.run { domainError { try DeletionService.delete([.subPayment(entry)], in: context) } }
                == .readOnly(operation: "deleteSubcontractorPayment", lapsed: true))
        _ = try DomainState.subscribed.run { try DeletionService.delete([.subPayment(entry)], in: context) }
        #expect(sub.sortedPayments.isEmpty && othersEntry.amount == 100 && !context.hasChanges)
    }

    // MARK: Pay now

    @Test func payNowSettlesOldestFirstAndSplitsWithProratedHours() throws {
        let context = try DomainFixtures.context()
        let sub = TS.subcontractor(in: context)
        let customer = TS.customer(in: context)
        let older = TS.oweSub(sub, 200, date: day1, in: context)
        let newer = TS.oweSub(sub, 400, hours: 8, date: day2, detail: "tile", customer: customer, in: context)
        context.saveChanges()

        let paid = try DomainState.subscribed.run {
            try SubcontractorService.payNow(300, paidDate: paidOn, method: .venmo, for: sub, in: context)
        }
        #expect(older.paidDate == paidOn && older.method == .venmo)
        #expect(newer.paidDate == nil && newer.amount == 300 && newer.hours == 6, "the rest stays owed, hours prorated")
        #expect(paid.count == 2)
        let slice = try #require(paid.last)
        #expect(slice.amount == 100 && slice.hours == 2 && slice.paidDate == paidOn && slice.method == .venmo)
        #expect(slice.date == day2 && slice.detail == "tile" && slice.customer === customer)
        #expect(close(sub.outstanding, 300))
        #expect(slice.syncID != nil && !context.hasChanges)
    }

    @Test func payNowBooksTheSurplusAsItsOwnPaidEntry() throws {
        let context = try DomainFixtures.context()
        let sub = TS.subcontractor(in: context)
        TS.oweSub(sub, 200, date: day1, in: context)
        context.saveChanges()
        let paid = try DomainState.subscribed.run {
            try SubcontractorService.payNow(250, paidDate: paidOn, method: .check, for: sub, in: context)
        }
        let extra = try #require(paid.last)
        #expect(paid.count == 2 && extra.amount == 50 && extra.date == paidOn && extra.paidDate == paidOn)
        #expect(sub.outstanding == 0 && close(sub.lifetimePaid, 250))

        // With nothing owed, the whole payment is one paid entry.
        let solo = try DomainState.subscribed.run {
            try SubcontractorService.payNow(75, paidDate: paidOn, method: .cash, for: sub, in: context)
        }
        #expect(solo.count == 1 && solo[0].amount == 75)
    }

    @Test func payNowRefusalsWriteNothing() throws {
        let context = try DomainFixtures.context()
        let sub = TS.subcontractor(in: context)
        let owed = TS.oweSub(sub, 200, in: context)
        context.saveChanges()
        func pay(_ amount: Double) -> DomainError? {
            domainError { try SubcontractorService.payNow(amount, paidDate: paidOn, method: .check, for: sub, in: context) }
        }
        #expect(DomainState.lapsed.run { pay(100) } == .readOnly(operation: "recordSubcontractorPayment", lapsed: true))
        #expect(DomainState.offline.run { pay(100) } == .readOnly(operation: "recordSubcontractorPayment", lapsed: false))
        #expect(DomainState.subscribed.run { pay(0.004) } == .amountRequired)
        #expect(DomainState.subscribed.run { pay(-1) } == .negativeValue)
        #expect(!owed.isPaid && sub.sortedPayments.count == 1 && !context.hasChanges)
    }
}
