//
//  InvoiceServiceTests.swift
//  GLSmallBusinessTests — Domain
//
//  The one invoice save path: the Invoice form (standalone and job billing), Record Payment, Ask
//  for a Deposit, the Pay-button toggle, job-photo import, and the assistant.
//

import Foundation
import SwiftData
import Testing
@testable import GLSmallBusiness

@MainActor
@Suite(.serialized)
struct InvoiceServiceTests {

    private func draft(title: String = "Kitchen", price: Double = 1000) -> InvoiceDraft {
        var draft = InvoiceDraft()
        draft.jobTitle = title
        var line = InvoiceLineDraft()
        line.name = "Tile"
        line.unitPrice = price
        draft.groups = [InvoiceGroupDraft(name: "Work", lines: [line])]
        return draft
    }

    // MARK: Create

    @Test func createNumbersSeedsThePayButtonDatesAndSaves() throws {
        let context = try DomainFixtures.context()
        let customer = TS.customer(in: context)
        let profile = BusinessProfile()
        profile.lastInvoiceNumber = 41
        profile.payLinkDefaultOn = false
        context.insert(profile)
        context.saveChanges()

        var input = draft()
        input.paymentTerms = .net15
        input.dueDate = TS.day(2020, 1, 1)          // ignored: only custom terms keep a picked date
        let invoice = try DomainState.subscribed.run { try InvoiceService.create(input, for: customer, in: context) }
        #expect(invoice.number == "INV-0042" && profile.lastInvoiceNumber == 42)
        #expect(invoice.includePayLink == false, "nil = the Get Paid default")
        #expect(invoice.dueDate == PaymentTerms.net15.dueDate(from: invoice.createdAt))
        #expect(invoice.total == 1000 && invoice.customer === customer)
        #expect(invoice.syncID != nil && !context.hasChanges)

        var custom = draft()
        custom.paymentTerms = .custom
        custom.dueDate = TS.day(2027, 3, 1)
        custom.includePayLink = true
        let second = try DomainState.subscribed.run { try InvoiceService.create(custom, for: customer, in: context) }
        #expect(second.dueDate == TS.day(2027, 3, 1) && second.includePayLink)
    }

    @Test func createRefusals() throws {
        let context = try DomainFixtures.context()
        let customer = TS.customer(in: context)
        for i in 0..<FreeTier.invoices { context.insert(Invoice(number: "INV-X\(i)")) }
        context.saveChanges()
        #expect(DomainState.neverSubscribed.run { domainError { try InvoiceService.create(draft(), for: customer, in: context) } }
                == .freeLimitReached(operation: "saveInvoice"))
        #expect(DomainState.offline.run { domainError { try InvoiceService.create(draft(), for: customer, in: context) } }
                == .readOnly(operation: "saveInvoice", lapsed: false))
        #expect(DomainState.subscribed.run { domainError { try InvoiceService.create(draft(title: " "), for: customer, in: context) } }
                == .titleRequired)
        #expect(DomainState.subscribed.run { domainError { try InvoiceService.create(draft(price: -1), for: customer, in: context) } }
                == .negativeValue)
        var negativeDue = draft()
        negativeDue.amountDueNow = -10
        #expect(DomainState.subscribed.run { domainError { try InvoiceService.create(negativeDue, for: customer, in: context) } }
                == .negativeValue)
        #expect(try context.fetchCount(FetchDescriptor<Invoice>()) == FreeTier.invoices)
    }

    @Test func jobBillingLinksTheJobCopiesChosenFilesAndCarriesScopeOnce() throws {
        let context = try DomainFixtures.context()
        let customer = TS.customer(in: context)
        let job = TS.job("Bath remodel", start: TS.day(2026, 9, 1), customer: customer, in: context)
        let estimate = TS.estimate(taxRatePercent: 6, lines: [(2000, true)], in: context)
        job.estimate = estimate
        context.insert(JobAttachment(kind: .photo, name: "Before", data: Data([1]), job: job))
        context.insert(JobAttachment(kind: .document, name: "Permit.pdf", data: Data([2]), job: job))
        context.saveChanges()

        let carry = InvoiceService.jobBillingDraft(for: job)
        #expect(carry.jobTitle == job.displayTitle)
        #expect(carry.taxRatePercent == 6 && carry.groups.flatMap(\.lines).map(\.unitPrice) == [2000])
        #expect(carry.groups.allSatisfy { $0.modelID == nil }, "carried rows are copies, never the estimate's rows")

        let invoice = try DomainState.subscribed.run {
            try InvoiceService.create(carry, for: customer, job: job,
                                      attachments: JobAttachmentSelection(photos: true), in: context)
        }
        #expect(invoice.job === job)
        #expect(invoice.photos.count == 1 && invoice.documents.isEmpty, "only the chosen kind was copied")
        #expect(invoice.total == 2120)
        #expect(estimate.sortedGroups[0].sortedLineItems.count == 1, "the estimate's own rows were not touched")

        let next = InvoiceService.jobBillingDraft(for: job)
        #expect(next.groups.flatMap(\.lines).allSatisfy { $0.name.isEmpty }, "later draws start blank")
        #expect(next.taxRatePercent == 0)
    }

    /// An options estimate is a menu, not a scope: until the owner says which option the customer
    /// chose, the job's first invoice carries no option's lines, and it never carries the
    /// estimate-level discount or deposit (convert-to-invoice's rules, `Invoice.make`).
    @Test func optionsEstimateJobCarriesNoOptionUntilChosenAndNoEstimateDiscount() throws {
        let context = try DomainFixtures.context()
        let job = TS.job("Deck", start: TS.day(2026, 9, 1), in: context)
        let estimate = TS.optionsEstimate(taxRatePercent: 6,
                                          groups: [("Silver", [(1000, false)]), ("Gold", [(3000, false)])], in: context)
        estimate.discountType = .fixed
        estimate.discountValue = 100
        estimate.depositType = .percentage
        estimate.depositValue = 30
        job.estimate = estimate
        context.saveChanges()
        let carry = InvoiceService.jobBillingDraft(for: job)
        #expect(carry.groups.flatMap(\.lines).allSatisfy { $0.name.isEmpty && $0.unitPrice == 0 },
                "no option is carried before one is chosen")
        #expect(carry.discountType == .none && carry.discountValue == 0, "the estimate discount is never carried")
        #expect(carry.amountDueNow == 0 && carry.amountDueDetail.isEmpty, "the options deposit is never carried")
        #expect(carry.taxRatePercent == 6)
    }

    /// The customer picked Gold: the job's first invoice bills only Gold, at the option's own total
    /// (no estimate discount, no deposit), and the picker is asked only while nothing bills the job.
    @Test func optionsEstimateJobBillsOnlyTheChosenOption() throws {
        let context = try DomainFixtures.context()
        let customer = TS.customer(in: context)
        let job = TS.job("Deck", start: TS.day(2026, 9, 1), customer: customer, in: context)
        let estimate = TS.optionsEstimate(taxRatePercent: 6,
                                          groups: [("Silver", [(1000, true)]), ("Gold", [(3000, true)])], in: context)
        estimate.discountType = .fixed
        estimate.discountValue = 100
        estimate.depositType = .percentage
        estimate.depositValue = 30
        job.estimate = estimate
        context.saveChanges()
        #expect(InvoiceService.jobBillingNeedsOptionChoice(for: job))

        let gold = try #require(estimate.sortedGroups.first { $0.name == "Gold" })
        let carry = InvoiceService.jobBillingDraft(for: job, chosenGroupIDs: [gold.persistentModelID])
        #expect(carry.groups.map(\.name) == ["Gold"])
        #expect(carry.groups.flatMap(\.lines).map(\.unitPrice) == [3000])
        #expect(carry.discountType == .none && carry.discountValue == 0)
        #expect(carry.amountDueNow == 0)
        #expect(abs(carry.totals.total - 3180) < 0.005, "the Gold option's own total: 3000 + 6% tax")
        #expect(abs(carry.totals.total - gold.optionTotals(taxRatePercent: 6).total) < 0.005,
                "the invoice bills what the picker showed for that option")

        let invoice = try DomainState.subscribed.run {
            try InvoiceService.create(carry, for: customer, job: job, origin: .screen, in: context)
        }
        #expect(abs(invoice.total - 3180) < 0.005)
        #expect(!InvoiceService.jobBillingNeedsOptionChoice(for: job), "later draws start blank, no picker")
    }

    @Test func onlyAnOptionsEstimateJobAsksForAnOption() throws {
        let context = try DomainFixtures.context()
        let classicJob = TS.job("Bath", start: TS.day(2026, 9, 1), in: context)
        classicJob.estimate = TS.estimate(lines: [(2000, false)], in: context)
        let bareJob = TS.job("Paint", start: TS.day(2026, 9, 2), in: context)
        context.saveChanges()
        #expect(!InvoiceService.jobBillingNeedsOptionChoice(for: classicJob))
        #expect(!InvoiceService.jobBillingNeedsOptionChoice(for: bareJob))
    }

    /// A classic estimate's deposit is requested on the job's first invoice, as Convert does.
    @Test func classicEstimateJobCarriesTheDepositAsAmountDueNow() throws {
        let context = try DomainFixtures.context()
        let job = TS.job("Bath", start: TS.day(2026, 9, 1), in: context)
        let estimate = TS.estimate(lines: [(2000, false)], in: context)
        estimate.depositType = .percentage
        estimate.depositValue = 30
        job.estimate = estimate
        context.saveChanges()
        let carry = InvoiceService.jobBillingDraft(for: job)
        #expect(carry.amountDueNow == 600)
        #expect(carry.amountDueDetail == "Deposit to start")
        #expect(carry.groups.flatMap(\.lines).map(\.unitPrice) == [2000])
    }

    /// The carried deposit note lands on the form and the customer's PDF, so it follows the
    /// app's chosen language.
    @Test func classicEstimateJobDepositNoteFollowsTheAppLanguage() throws {
        let saved = MBLocalization.shared.language
        defer { MBLocalization.shared.language = saved }
        let context = try DomainFixtures.context()
        let job = TS.job("Bath", start: TS.day(2026, 9, 1), in: context)
        let estimate = TS.estimate(lines: [(2000, false)], in: context)
        estimate.depositType = .percentage
        estimate.depositValue = 30
        job.estimate = estimate
        context.saveChanges()
        MBLocalization.shared.language = .es
        #expect(InvoiceService.jobBillingDraft(for: job).amountDueDetail == "Depósito para comenzar")
        MBLocalization.shared.language = .en
        #expect(InvoiceService.jobBillingDraft(for: job).amountDueDetail == "Deposit to start")
    }

    // MARK: Update + lock

    @Test func updateInPlaceAndRefusedOncePaid() throws {
        let context = try DomainFixtures.context()
        let invoice = TS.invoice(lines: [(1000, false)], in: context)
        context.saveChanges()
        let lineID = invoice.allLineItems[0].persistentModelID

        try DomainState.subscribed.run { try InvoiceService.update(invoice, with: InvoiceDraft(invoice), in: context) }
        #expect(!context.hasChanges, "an untouched edit queues nothing")

        var edit = InvoiceDraft(invoice)
        edit.groups[0].lines[0].unitPrice = 900
        edit.discountType = .percentage
        edit.discountValue = 10
        try DomainState.subscribed.run { try InvoiceService.update(invoice, with: edit, in: context) }
        #expect(invoice.allLineItems[0].persistentModelID == lineID && invoice.total == 810)

        TS.pay(invoice, 810, in: context)
        context.saveChanges()
        #expect(invoice.isMoneyLocked)
        #expect(DomainState.subscribed.run { domainError { try InvoiceService.update(invoice, with: edit, in: context) } }
                == .paidLocked)
        #expect(DomainState.subscribed.run { domainError { try InvoiceService.setStatus(invoice, .sent, in: context) } }
                == .paidLocked)
        #expect(DomainState.subscribed.run { domainError { try InvoiceService.setPaymentTerms(invoice, .net15, in: context) } }
                == .paidLocked)
        // Lock-exempt writes still work on a paid invoice.
        try DomainState.subscribed.run {
            try InvoiceService.setAmountDue(invoice, amount: 0, detail: " ", in: context)
            try InvoiceService.setIncludePayLink(invoice, true, in: context)
        }
        #expect(invoice.includePayLink && invoice.amountDueDetail.isEmpty)
    }

    @Test func changeOrderLinesRoundTripUnvalidatedAndKeepTheirLink() throws {
        let context = try DomainFixtures.context()
        let invoice = TS.invoice(lines: [(1000, false)], in: context)
        let credit = TS.changeOrder(invoice, status: .approved, lines: [(-200, false)], in: context)
        credit.addItemsToInvoice(using: context)
        context.saveChanges()
        #expect(invoice.total == 800)

        var edit = InvoiceDraft(invoice)
        edit.jobTitle = "Renamed"
        try DomainState.subscribed.run { try InvoiceService.update(invoice, with: edit, in: context) }
        #expect(invoice.total == 800, "the credit line kept its negative price and its flag")
        #expect(credit.invoiceGroup != nil && credit.invoiceGroup?.changeOrder === credit)
    }

    /// A tool can't add, edit or re-link change-order rows on the invoice itself (credits come only
    /// through a change order); an untouched round trip still saves.
    @Test func aToolCannotForgeOrEditChangeOrderRows() throws {
        let context = try DomainFixtures.context()
        let invoice = TS.invoice(number: "INV-0001", lines: [(1000, false)], in: context)
        let credit = TS.changeOrder(invoice, status: .approved, lines: [(-200, false)], in: context)
        credit.addItemsToInvoice(using: context)
        let other = TS.invoice(number: "INV-0002", lines: [(500, false)], in: context)
        let otherOrder = TS.changeOrder(other, status: .approved, lines: [(50, false)], in: context)
        otherOrder.addItemsToInvoice(using: context)
        context.saveChanges()

        try DomainState.subscribed.run {
            var forged = InvoiceDraft(invoice)
            var fake = InvoiceLineDraft()
            fake.name = "Discount"
            fake.unitPrice = -500
            fake.fromChangeOrder = true
            forged.groups[0].lines.append(fake)
            #expect(domainError { try InvoiceService.update(invoice, with: forged, in: context) } == .changeOrderLinesReadOnly)

            var edited = InvoiceDraft(invoice)
            let coGroup = try #require(edited.groups.firstIndex { $0.changeOrder != nil })
            edited.groups[coGroup].lines[0].unitPrice = -900
            #expect(domainError { try InvoiceService.update(invoice, with: edited, in: context) } == .changeOrderLinesReadOnly)

            var relinked = InvoiceDraft(invoice)
            relinked.groups[0].changeOrder = otherOrder
            #expect(domainError { try InvoiceService.update(invoice, with: relinked, in: context) } == .changeOrderLinesReadOnly)

            var newInvoice = draft()
            newInvoice.groups[0].lines[0].fromChangeOrder = true
            #expect(domainError { try InvoiceService.create(newInvoice, for: TS.customer(in: context), in: context) }
                    == .changeOrderLinesReadOnly)

            var fine = InvoiceDraft(invoice)
            fine.jobTitle = "Renamed"
            try InvoiceService.update(invoice, with: fine, in: context)
        }
        #expect(invoice.total == 800 && invoice.jobTitle == "Renamed")
        #expect(otherOrder.invoiceGroup?.invoice === other, "the other invoice kept its change-order group")
    }

    /// Tax is a percentage too, and the totals never clamp it (150% would bill 150%): no origin may
    /// save one past 100 — the form caps the field, and the service refuses a screen too (owner fix
    /// 2026-09-22). Exactly 100 is allowed. An invoice stored with a higher rate must be fixed first.
    @Test func taxOver100IsRefusedForEveryOrigin() throws {
        let context = try DomainFixtures.context()
        let customer = TS.customer(in: context)
        context.saveChanges()
        var input = draft()
        input.taxRatePercent = 150
        #expect(DomainState.subscribed.run { domainError { try InvoiceService.create(input, for: customer, in: context) } }
                == .percentOutOfRange)
        #expect(DomainState.subscribed.run {
            domainError { try InvoiceService.create(input, for: customer, origin: .screen, in: context) }
        } == .percentOutOfRange)
        #expect(try context.fetchCount(FetchDescriptor<Invoice>()) == 0)
        input.taxRatePercent = 100
        let invoice = try DomainState.subscribed.run {
            try InvoiceService.create(input, for: customer, origin: .screen, in: context)
        }
        #expect(invoice.taxRatePercent == 100)

        let stored = TS.invoice(number: "INV-0099", taxRatePercent: 150, in: context)
        stored.customer = customer
        context.saveChanges()
        var edit = InvoiceDraft(stored)
        edit.jobTitle = "Renamed"
        #expect(DomainState.subscribed.run {
            domainError { try InvoiceService.update(stored, with: edit, origin: .screen, in: context) }
        } == .percentOutOfRange)
        #expect(stored.jobTitle == "Job" && stored.taxRatePercent == 150, "nothing was written")
        edit.taxRatePercent = 15
        try DomainState.subscribed.run { try InvoiceService.update(stored, with: edit, origin: .screen, in: context) }
        #expect(stored.jobTitle == "Renamed" && stored.taxRatePercent == 15)
    }

    @Test func billingAnotherCustomersJobIsRefused() throws {
        let context = try DomainFixtures.context()
        let alice = TS.customer(first: "Alice", in: context)
        let bob = TS.customer(first: "Bob", in: context)
        let bobsJob = TS.job("Deck", start: TS.day(2026, 9, 1), customer: bob, in: context)
        context.insert(JobAttachment(kind: .photo, name: "Bob's deck", data: Data([1]), job: bobsJob))
        context.saveChanges()
        #expect(DomainState.subscribed.run {
            domainError { try InvoiceService.create(draft(), for: alice, job: bobsJob,
                                                    attachments: JobAttachmentSelection(photos: true), in: context) }
        } == .jobBelongsToAnotherCustomer)
        #expect(try context.fetchCount(FetchDescriptor<Invoice>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<JobAttachment>()) == 1, "no photo was copied")
    }

    /// A job scheduled from an invoice with applied change orders: its first billing invoice carries
    /// the change-order lines still flagged `fromChangeOrder`, so a credit stays a credit (signed,
    /// not floored to $0) and change-order work stays outside the invoice discount. The carried
    /// invoice bills exactly what the source bills (owner fix 2026-09-22: it used to overbill).
    @Test func aCarriedCreditStaysACreditAndTheTotalMatchesTheSource() throws {
        let context = try DomainFixtures.context()
        let customer = TS.customer(in: context)
        let source = TS.invoice(taxRatePercent: 6, discountType: .percentage, discountValue: 10,
                                lines: [(1000, true)], in: context)
        source.customer = customer
        // Signed at the invoice's 6%, as ChangeOrderService.create snapshots it (the order's own
        // rate is what the invoice bills it at — law 87, QA F82).
        let order = TS.changeOrder(source, status: .approved, taxRatePercent: 6,
                                   lines: [(-200, true), (300, false)], in: context)
        order.addItemsToInvoice(using: context)
        let job = TS.job("Bath", start: TS.day(2026, 9, 1), customer: customer, in: context)
        job.invoice = source
        context.saveChanges()
        // 1000 − 10% = 900, tax 6% of 900 = 54; change order −200 + 300 at full price, tax −12.
        #expect(abs(source.total - 1042) < 0.005)

        let carry = InvoiceService.jobBillingDraft(for: job)
        let carried = carry.groups.flatMap(\.lines)
        #expect(carried.contains { $0.unitPrice == -200 && $0.fromChangeOrder })
        #expect(carried.filter(\.fromChangeOrder).count == 2 && carried.filter { !$0.fromChangeOrder }.count == 1)
        #expect(carry.groups.allSatisfy { $0.changeOrder == nil && $0.modelID == nil })
        #expect(abs(carry.totals.total - source.total) < 0.005, "the form's Summary shows the source's total")

        let invoice = try DomainState.subscribed.run {
            try InvoiceService.create(carry, for: customer, job: job, origin: .screen, in: context)
        }
        #expect(abs(invoice.total - source.total) < 0.005, "the carried invoice bills what the source bills")
        #expect(invoice.allLineItems.contains { $0.unitPrice == -200 && $0.fromChangeOrder })
        #expect(order.invoiceGroup?.invoice === source, "the source keeps its change-order group")
        #expect(order.invoice === source && abs(source.total - 1042) < 0.005)

        // Editing it again from the form keeps working and keeps the total.
        var edit = InvoiceDraft(invoice)
        edit.jobTitle = "Bath, phase 1"
        try DomainState.subscribed.run { try InvoiceService.update(invoice, with: edit, origin: .screen, in: context) }
        #expect(invoice.jobTitle == "Bath, phase 1" && !context.hasChanges)
        #expect(abs(invoice.total - 1042) < 0.005)
        // The carried rows are this invoice's own, unchanged: a tool may re-save them too, but not alter them.
        edit.jobTitle = "Bath, phase 2"
        try DomainState.subscribed.run { try InvoiceService.update(invoice, with: edit, in: context) }
        #expect(invoice.jobTitle == "Bath, phase 2")
        var altered = InvoiceDraft(invoice)
        for g in altered.groups.indices {
            for l in altered.groups[g].lines.indices where altered.groups[g].lines[l].unitPrice == -200 {
                altered.groups[g].lines[l].unitPrice = -500
            }
        }
        #expect(DomainState.subscribed.run { domainError { try InvoiceService.update(invoice, with: altered, in: context) } }
                == .changeOrderLinesReadOnly)
    }

    /// An invoice saved before that fix holds the credit as an ORDINARY negative line: the form can
    /// still re-save it; a tool is held to "credits only through a change order".
    @Test func anOlderCarriedCreditLineStillSavesFromTheForm() throws {
        let context = try DomainFixtures.context()
        let customer = TS.customer(in: context)
        let invoice = TS.invoice(lines: [(1000, false), (-200, false)], in: context)
        invoice.customer = customer
        context.saveChanges()
        #expect(invoice.total == 1000, "as ordinary scope the old credit line counts as 0")
        var edit = InvoiceDraft(invoice)
        edit.jobTitle = "Bath, phase 1"
        try DomainState.subscribed.run { try InvoiceService.update(invoice, with: edit, origin: .screen, in: context) }
        #expect(invoice.jobTitle == "Bath, phase 1" && !context.hasChanges)
        #expect(DomainState.subscribed.run { domainError { try InvoiceService.update(invoice, with: edit, in: context) } }
                == .negativeValue)
    }

    @Test func statusAndTerms() throws {
        let context = try DomainFixtures.context()
        let invoice = TS.invoice(createdAt: TS.day(2026, 9, 1), in: context)
        context.saveChanges()
        try DomainState.subscribed.run {
            try InvoiceService.setStatus(invoice, .sent, in: context)
            try InvoiceService.setPaymentTerms(invoice, .dueOnReceipt, in: context)
        }
        #expect(invoice.status == .sent)
        #expect(invoice.dueDate == PaymentTerms.dueOnReceipt.dueDate(from: TS.day(2026, 9, 1)))
        try DomainState.subscribed.run {
            try InvoiceService.setPaymentTerms(invoice, .custom, customDueDate: TS.day(2026, 10, 9), in: context)
        }
        #expect(invoice.paymentTerms == .custom && invoice.dueDate == TS.day(2026, 10, 9))
        #expect(!context.hasChanges)
    }

    // MARK: Payments

    @Test func recordPaymentValidatesDrawsDownAndSaves() throws {
        let context = try DomainFixtures.context()
        let invoice = TS.invoice(status: .sent, lines: [(1000, false)], in: context)
        invoice.amountDueNow = 300
        invoice.amountDueDetail = "Deposit"
        context.saveChanges()

        #expect(DomainState.subscribed.run {
            domainError { try InvoiceService.recordPayment(on: invoice, amount: 0, method: .cash, in: context) }
        } == .amountRequired)
        #expect(DomainState.subscribed.run {
            domainError { try InvoiceService.recordPayment(on: invoice, amount: 1000.01, method: .cash, in: context) }
        } == .exceedsBalance)
        #expect(DomainState.lapsed.run {
            domainError { try InvoiceService.recordPayment(on: invoice, amount: 10, method: .cash, in: context) }
        } == .readOnly(operation: "recordPayment", lapsed: true))
        #expect(invoice.sortedPayments.isEmpty)

        let payment = try DomainState.subscribed.run {
            try InvoiceService.recordPayment(on: invoice, amount: 300, method: .check, note: " #101 ", in: context)
        }
        #expect(payment.note == "#101" && payment.syncID != nil, "saved now, not at the next autosave")
        #expect(invoice.amountDueNow == 0 && invoice.amountDueDetail.isEmpty, "the deposit request was drawn down")
        #expect(invoice.balanceDue == 700 && !context.hasChanges)

        // Inside the half-cent tolerance is allowed; a Stripe-reconciled payment may exceed it.
        try DomainState.subscribed.run {
            _ = try InvoiceService.recordPayment(on: invoice, amount: 700.004, method: .cash, in: context)
        }
        #expect(invoice.isPaid)
        // The screen's paid prompt passes the link it showed, as it always has.
        let over = try DomainState.subscribed.run {
            try InvoiceService.recordPayment(on: invoice, amount: 50, method: .stripe, stripeLinkId: "plink_1",
                                             origin: .screen, in: context)
        }
        #expect(over.stripePaymentLinkId == "plink_1")
    }

    /// From a tool, only the invoice's OWN unclaimed link lifts the over-balance refusal; any other
    /// id is a hand-entered amount.
    @Test func aToolCannotOverpayWithAnArbitraryLinkID() throws {
        let context = try DomainFixtures.context()
        let invoice = TS.invoice(status: .sent, lines: [(1000, false)], in: context)
        invoice.stripePaymentLinkId = "plink_A"
        context.saveChanges()
        try DomainState.subscribed.run {
            #expect(domainError { try InvoiceService.recordPayment(on: invoice, amount: 1200, method: .stripe,
                                                                   stripeLinkId: "x", in: context) } == .exceedsBalance)
            let paid = try InvoiceService.recordPayment(on: invoice, amount: 1200, method: .stripe,
                                                        stripeLinkId: "plink_A", in: context)
            #expect(paid.stripePaymentLinkId == "plink_A" && invoice.isPaid)
            #expect(domainError { try InvoiceService.recordPayment(on: invoice, amount: 10, method: .stripe,
                                                                   stripeLinkId: "plink_A", in: context) } == .exceedsBalance,
                    "a link already claimed by a payment is a hand-entered amount")
        }
        #expect(invoice.sortedPayments.count == 1)
    }

    @Test func aCardPaymentMatchingTheOpenLinkIsStampedOnce() throws {
        let context = try DomainFixtures.context()
        let invoice = TS.invoice(status: .sent, lines: [(1000, false)], in: context)
        invoice.stripePaymentLinkId = "plink_A"
        invoice.stripePaymentLinkAmountCents = 25_000
        invoice.stripePaymentLinkMintedAt = TS.day(2026, 9, 10)
        context.saveChanges()

        try DomainState.subscribed.run {
            let early = try InvoiceService.recordPayment(on: invoice, amount: 250, date: TS.day(2026, 9, 1),
                                                         method: .card, in: context)
            #expect(early.stripePaymentLinkId.isEmpty, "dated before the link existed — an earlier milestone")
            let cash = try InvoiceService.recordPayment(on: invoice, amount: 250, date: TS.day(2026, 9, 12),
                                                        method: .cash, in: context)
            #expect(cash.stripePaymentLinkId.isEmpty, "cash can't settle a card link")
            let card = try InvoiceService.recordPayment(on: invoice, amount: 250, date: TS.day(2026, 9, 12),
                                                        method: .card, in: context)
            #expect(card.stripePaymentLinkId == "plink_A")
            let another = try InvoiceService.recordPayment(on: invoice, amount: 250, date: TS.day(2026, 9, 13),
                                                           method: .card, in: context)
            #expect(another.stripePaymentLinkId.isEmpty, "the link is already claimed")
        }
    }

    @Test func amountDueAndPayButton() throws {
        let context = try DomainFixtures.context()
        let invoice = TS.invoice(in: context)
        context.saveChanges()
        try DomainState.subscribed.run {
            try InvoiceService.setAmountDue(invoice, amount: 5000, detail: "  Milestone 1 ", in: context)
            try InvoiceService.setIncludePayLink(invoice, true, in: context)
        }
        #expect(invoice.amountDueNow == 5000 && invoice.amountDueDetail == "Milestone 1")
        #expect(invoice.currentAmountDue == 1000, "capped at the balance when read")
        #expect(invoice.includePayLink && !context.hasChanges)
        #expect(DomainState.subscribed.run { domainError { try InvoiceService.setAmountDue(invoice, amount: -1, detail: "", in: context) } }
                == .negativeValue)
        #expect(DomainState.offline.run { domainError { try InvoiceService.setIncludePayLink(invoice, false, in: context) } }
                == .readOnly(operation: "togglePayLink", lapsed: false))
    }

    @Test func zelleSeedingToggleAndMessageInclusion() throws {
        let context = try DomainFixtures.context()
        let customer = TS.customer(in: context)
        let profile = BusinessProfile()
        profile.businessName = "Gold Life Tile"
        profile.zelleTag = "GoldLifeZelle"
        profile.zelleEmail = "zelle@goldlife.com"
        profile.zellePhone = "850-555-0199"
        profile.zelleDefaultOn = true
        context.insert(profile)
        context.saveChanges()

        let seeded = try DomainState.subscribed.run {
            try InvoiceService.create(draft(), for: customer, in: context)
        }
        #expect(seeded.includeZelle, "seeded from profile.zelleDefaultOn when zelleIsConfigured")

        let plainOn = InvoiceMessage.plainBody(invoice: seeded, business: profile)
        let htmlOn = InvoiceMessage.htmlBody(invoice: seeded, business: profile)
        #expect(plainOn.contains("GoldLifeZelle") && plainOn.contains("zelle@goldlife.com"))
        #expect(htmlOn.contains("GoldLifeZelle") && htmlOn.contains("zelle@goldlife.com"))

        // QR-code-only Zelle profile still gives clear instructions in plain and HTML bodies (SA4).
        profile.zelleTag = ""
        profile.zelleEmail = ""
        profile.zellePhone = ""
        profile.zelleQRCodeData = Data([0x89, 0x50])
        let qrPlain = InvoiceMessage.plainBody(invoice: seeded, business: profile)
        let qrHTML = InvoiceMessage.htmlBody(invoice: seeded, business: profile)
        #expect(qrPlain.contains("Scan the Zelle QR code on the attached invoice PDF."))
        #expect(qrHTML.contains("Scan the Zelle QR code on the attached invoice PDF."))

        try DomainState.subscribed.run {
            try InvoiceService.setIncludeZelle(seeded, false, in: context)
        }
        #expect(!seeded.includeZelle && !context.hasChanges)
        let plainOff = InvoiceMessage.plainBody(invoice: seeded, business: profile)
        #expect(!plainOff.contains("Pay with Zelle"))
        #expect(DomainState.offline.run { domainError { try InvoiceService.setIncludeZelle(seeded, true, in: context) } }
                == .readOnly(operation: "togglePayLink", lapsed: false))
    }

    // MARK: Attachments

    @Test func importJobAttachmentsCopiesEachKind() throws {
        let context = try DomainFixtures.context()
        let job = TS.job("Bath", start: TS.day(2026, 9, 1), in: context)
        context.insert(JobAttachment(kind: .photo, name: "A", data: Data([1]), job: job))
        context.insert(JobAttachment(kind: .photo, name: "B", data: Data([2]), job: job))
        context.insert(JobAttachment(kind: .document, name: "Permit.pdf", data: Data([3]), job: job))
        let receipt = TS.receipt(total: 42, category: "Materials", date: TS.day(2026, 9, 2), in: context)
        receipt.scanData = Data([4])
        receipt.job = job
        let invoice = TS.invoice(in: context)
        context.saveChanges()

        let copied = try DomainState.subscribed.run {
            try InvoiceService.importJobAttachments(JobAttachmentSelection(photos: true, documents: true, expenses: true),
                                                    from: job, into: invoice, in: context)
        }
        #expect(copied == 4)
        #expect(invoice.photos.count == 2 && invoice.documents.count == 2)
        #expect(invoice.documents.contains { $0.name == "Vendor Receipt.jpg" })
        #expect(job.photos.count == 2, "copies, not moves")
        #expect(!context.hasChanges)
        #expect(DomainState.lapsed.run {
            domainError { _ = try InvoiceService.importJobAttachments(JobAttachmentSelection(photos: true), from: job, into: invoice, in: context) }
        } == .readOnly(operation: "addJobAttachment", lapsed: true))
    }
}
