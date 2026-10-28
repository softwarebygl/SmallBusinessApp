//
//  MBToolTestSupport.swift
//  GLSmallBusinessTests — AI
//
//  Runs the assistant's read tools the way the conversation loop does (a `GLAIToolContext`,
//  online or with the on-device output budget), and builds `MBToolWorld`: a store holding a
//  FULLY populated record of every kind — every blob set, every quarantined field planted with a
//  sentinel — for the quarantine sweep and the round trips.
//

import Foundation
import SwiftData
import Testing
import GoldLifeAI
@testable import GLSmallBusiness

/// Card payments without the network: answers what it is told and counts its calls.
@MainActor
final class FakeCardPayments: MBCardPaymentReading {
    var answer: Result<StripePayLinkStatusResponse, Error> =
        .success(StripePayLinkStatusResponse(status: "open", amountPaidCents: nil, paidAt: nil))
    private(set) var calls: [String] = []

    nonisolated init() {}

    func payLinkStatus(appInvoiceID: String) async throws -> StripePayLinkStatusResponse {
        calls.append(appInvoiceID)
        return try answer.get()
    }
}

@MainActor
enum MBToolHarness {
    /// Monday 2026-09-21, 10:00 Eastern — every test's "now".
    static let now: Date = TS.calendar.date(from: DateComponents(year: 2026, month: 9, day: 21, hour: 10)) ?? .now

    static func environment(_ context: ModelContext, cards: FakeCardPayments = FakeCardPayments(),
                            pause: GLSyncBreakerTrip? = nil) -> MBToolEnvironment {
        MBToolEnvironment(
            context: { context },
            subscription: { .shared },
            now: { now },
            calendar: TS.calendar,
            legacyMask: { SchedulingPrefs.defaultWorkdaysMask },
            cardPayments: cards,
            backupPause: { pause }
        )
    }

    static func toolbox(_ context: ModelContext, cards: FakeCardPayments = FakeCardPayments(),
                        pause: GLSyncBreakerTrip? = nil) throws -> MBToolbox {
        try MBToolbox(environment: environment(context, cards: cards, pause: pause))
    }

    /// One call, as the loop makes it. `onDevice` passes the on-device output budget (1,200).
    static func run(_ box: MBToolbox, _ name: String, _ arguments: GLAIJSON, onDevice: Bool = false) async -> GLAIToolOutcome {
        let toolbox = onDevice ? box.onDevice : box.online
        guard let tool = toolbox.executor(named: name) else {
            Issue.record("\(name) is not bound (\(onDevice ? "on device" : "online"))")
            return .failure(GLAIFailure(reason: "unbound", message: "", personReason: GLAIStrings.notAvailableHere))
        }
        let context = GLAIToolContext(turnId: "turn", step: 0, onScreen: nil, accountEpoch: 1,
                                      outputCharacterLimit: onDevice ? 1_200 : nil, currentEpoch: { 1 })
        return await DomainState.subscribed.runAsync {
            await tool.run(GLAIToolCall(id: "call", name: name, arguments: arguments, turnId: "turn"), context: context)
        }
    }

    /// The model-facing output of a `.result`, recording an issue for anything else.
    static func output(_ outcome: GLAIToolOutcome, sourceLocation: SourceLocation = #_sourceLocation) -> GLAIJSON {
        switch outcome {
        case .result(let output, let activity, let undo):
            #expect(activity.isEmpty && undo == nil, "a read tool reported a change", sourceLocation: sourceLocation)
            return output
        case .failure(let failure):
            Issue.record("expected a result, got \(failure.reason): \(failure.message)", sourceLocation: sourceLocation)
        case .needsConfirmation, .handoff:
            Issue.record("a read tool asked for a confirmation or a hand-off", sourceLocation: sourceLocation)
        }
        return .null
    }

    static func failureReason(_ outcome: GLAIToolOutcome) -> String? {
        if case .failure(let failure) = outcome { return failure.reason }
        return nil
    }

    static func results(_ output: GLAIJSON) -> [GLAIJSON] { output["results"]?.arrayValue ?? [] }

    static func ids(_ output: GLAIJSON) -> [String] { results(output).compactMap { $0["id"]?.stringValue } }
}

/// A store with one fully populated record of every kind (and the singletons), every blob set
/// and every quarantined field planted with a sentinel the sweep searches for.
@MainActor
struct MBToolWorld {
    /// Planted in every quarantined text field. Must never appear in any tool output.
    static let sentinel = "SECRET"
    /// A blob's bytes: 0xAB… encodes to "q6ur…" in base64 — searched for too.
    static let blob = Data(repeating: 0xAB, count: 256)
    static let blobBase64Prefix = "q6ur"
    /// The planted tax ID digits.
    static let taxID = "987654321"

    let context: ModelContext
    let customer: Customer
    let estimate: Estimate
    let contract: Contract
    let invoice: Invoice
    let changeOrder: ChangeOrder
    let job: ScheduledJob
    let receipt: Receipt
    let priceItem: PriceSheetItem
    let employee: Employee
    let subcontractor: Subcontractor
    let project: Project
    let payment: InvoicePayment
    let timeEntry: TimeEntry
    let paycheck: Paycheck
    let subPayment: SubPayment
    let attachment: JobAttachment
    let document: CustomerDocument

    init() throws {
        let context = try DomainFixtures.context()
        self.context = context
        let cal = TS.calendar
        let now = MBToolHarness.now
        let soon = cal.date(byAdding: .day, value: 10, to: now) ?? now

        let profile = BusinessProfile()
        profile.businessName = "Gold Tile Co"
        profile.ownerFirstName = "Owner\(Self.sentinel)First"
        profile.ownerLastName = "Owner\(Self.sentinel)Last"
        profile.phone = "(850) 555-0100"
        profile.email = "office@goldtile.example"
        profile.websiteURL = "https://goldtile.example"
        profile.reviewsURL = "https://reviews.example/goldtile"
        profile.includeReviewLinkOnReceipts = true
        profile.licenseNumber = "CGC-1234"
        profile.address = Address(street1: "1 Main St", street2: "Suite 2", city: "Miami", state: "FL", postalCode: "32301")
        profile.logoData = Self.blob
        profile.logoDataDark = Self.blob
        profile.emailSignatureText = "Licensed and insured"
        profile.warrantyText = "One-year workmanship warranty."
        profile.messageIntro = "Here is your estimate."
        profile.invoiceMessageIntro = "Here is your invoice."
        profile.w9Name = "W9\(Self.sentinel)Name"
        profile.w9TaxClassificationRaw = "llc"
        profile.w9LLCClassification = "S"
        profile.w9TINTypeRaw = "ein"
        profile.w9TIN = Self.taxID
        profile.w9ExemptPayeeCode = "EX\(Self.sentinel)"
        profile.w9FATCACode = "FA\(Self.sentinel)"
        profile.wcExemptionData = Self.blob
        profile.wcExemptionName = "exemption.pdf"
        profile.wcExemptionExpiresOn = soon
        profile.licenseDocumentData = Self.blob
        profile.licenseDocumentName = "license.pdf"
        profile.licenseExpiresOn = cal.date(byAdding: .day, value: -3, to: now)
        profile.ownerReferenceCOIData = Self.blob
        profile.proofOfInsuranceData = Self.blob
        profile.wcInsuranceData = Self.blob
        profile.stripeConnectedAccountId = "acct_\(Self.sentinel)1"
        profile.stripeChargesEnabled = true
        profile.stripeAccountClaim = "claim_\(Self.sentinel)"
        context.insert(profile)

        let person = UserProfile()
        person.useMyNameInEmails = true
        context.insert(person)

        let customer = TS.customer(in: context)
        customer.middleName = "Q"
        customer.officePhone = "(850) 555-0199"
        customer.profileImageData = Self.blob
        customer.coiData = Self.blob
        customer.coiName = "gl.pdf"
        customer.coiExpiresOn = soon
        customer.wcCoiData = Self.blob
        customer.wcCoiName = "wc.pdf"
        customer.wcCoiExpiresOn = cal.date(byAdding: .day, value: 200, to: now)
        self.customer = customer

        let document = CustomerDocument(name: "Extra.pdf", data: Self.blob, createdAt: now, customer: customer)
        context.insert(document)
        self.document = document

        let estimate = TS.estimate(number: "EST-0007", createdAt: now, status: .sent, taxRatePercent: 7,
                                   lines: [(1200, true), (300, false)], in: context)
        estimate.customer = customer
        estimate.customerFirstName = customer.firstName
        estimate.customerLastName = customer.lastName
        estimate.customerNotes = "Thanks for the opportunity."
        estimate.terms = "Net 30."
        estimate.serviceAddress = Address(street1: "9 Oak Ln", city: "Miami", state: "FL", postalCode: "32303")
        estimate.depositType = .percentage
        estimate.depositValue = 25
        self.estimate = estimate

        let contract = Contract(
            number: "CON-0001",
            title: "Remodel Contract",
            customerName: customer.fullName,
            customerEmail: customer.email,
            customerPhone: customer.phoneNumber,
            startDate: now,
            durationDays: 5,
            isAllDay: true,
            notes: "Contract notes.",
            terms: "Standard terms.",
            serviceAddress: Address(street1: "9 Oak Ln", city: "Miami", state: "FL", postalCode: "32303"),
            agreedPrice: 5000,
            status: .signed,
            customer: customer,
            estimate: estimate
        )
        contract.signatureData = Self.blob
        context.insert(contract)
        let contractGroup = ContractGroup(name: "Tile work", note: "Bathroom", sortIndex: 0)
        contractGroup.contract = contract
        context.insert(contractGroup)
        let contractLine = ContractLineItem(name: "Floor tile", details: "Porcelain", quantity: 100, unit: .squareFoot, unitPrice: 25, kind: .labor, isTaxable: true, sortIndex: 0)
        contractLine.group = contractGroup
        context.insert(contractLine)
        self.contract = contract

        let invoice = TS.invoice(number: "INV-0007", createdAt: now, status: .sent, taxRatePercent: 7,
                                 lines: [(1000, true), (500, false)], in: context)
        invoice.customer = customer
        invoice.customerFirstName = customer.firstName
        invoice.customerLastName = customer.lastName
        invoice.customerNotes = "Thank you."
        invoice.terms = "Due on receipt."
        invoice.amountDueNow = 200
        invoice.amountDueDetail = "Deposit"
        invoice.includePayLink = true
        invoice.stripeAppInvoiceId = "appinv_\(Self.sentinel)"
        invoice.stripePaymentLinkId = "plink_\(Self.sentinel)"
        invoice.stripePaymentLinkURL = "https://buy.example/\(Self.sentinel)"
        invoice.stripePaymentLinkAccountId = "acct_\(Self.sentinel)2"
        invoice.stripePaymentLinkAmountCents = 20_000
        invoice.stripePayLinkStatusRaw = "open"
        self.invoice = invoice

        let payment = TS.pay(invoice, 300, date: now, method: .card, in: context)
        payment.note = "First payment"
        payment.stripePaymentLinkId = "plink_\(Self.sentinel)"
        self.payment = payment

        let order = TS.changeOrder(invoice, number: "CO-0001", status: .approved, taxRatePercent: 7,
                                   lines: [(-150, false), (400, true)], in: context)
        order.note = "Extra tile"
        self.changeOrder = order

        let project = Project(name: "Reed Remodel", customer: customer)
        project.masterAgreementData = Self.blob
        project.masterAgreementName = "msa.pdf"
        context.insert(project)
        self.project = project

        let job = TS.job("Kitchen backsplash", start: now, days: 2, customer: customer, price: 2500, in: context)
        job.notes = "Gate code 1234."
        job.estimate = estimate
        job.invoice = invoice
        job.project = project
        job.serviceAddress = Address(street1: "9 Oak Ln", city: "Miami", state: "FL", postalCode: "32303")
        invoice.job = job
        self.job = job

        let attachment = JobAttachment(kind: .photo, name: "before.jpg", caption: "Before", data: Self.blob,
                                       createdAt: now, job: job, invoice: invoice)
        context.insert(attachment)
        context.insert(JobAttachment(kind: .document, name: "permit.pdf", caption: "Permit", data: Self.blob,
                                     createdAt: now, job: job))
        self.attachment = attachment

        let receipt = Receipt(vendor: "Tile Depot", date: now, total: 123.45, category: "Materials",
                              notes: "Grout", recognizedText: "TILE DEPOT\nGROUT 2 @ 12.00\nTOTAL 123.45",
                              scanData: Self.blob, customer: customer, job: job)
        context.insert(receipt)
        self.receipt = receipt

        let item = PriceSheetItem(name: "Backsplash install", details: "Per square foot", defaultQuantity: 1,
                                  unit: .squareFoot, unitPrice: 18, kind: .labor, isTaxable: false, category: "Tile")
        context.insert(item)
        self.priceItem = item

        let employee = TS.employee(first: "Ana", last: "Ruiz", email: "ana@example.com", phone: "(850) 555-0111",
                                   hourlyRate: 30, anchorPayday: now, hireDate: now, in: context)
        employee.profileImageData = Self.blob
        employee.notes = "Tile setter"
        self.timeEntry = TS.logHours(employee, 8, date: now, customer: customer, in: context)
        self.paycheck = TS.paycheck(employee, gross: 240, hours: 8, periodStart: now, periodEnd: now, payDate: now, in: context)
        TS.logHours(employee, 4, date: now, customer: customer, in: context)
        self.employee = employee

        let sub = TS.subcontractor(first: "Lee", last: "Pipe", business: "Lee Plumbing", email: "lee@example.com",
                                   phone: "(850) 555-0122",
                                   address: Address(street1: "5 Elm", city: "Miami", state: "FL", postalCode: "32304"),
                                   in: context)
        sub.hourlyRate = 45
        sub.tinKey = "tinkey_\(Self.sentinel)"
        sub.w9TINTypeRaw = "ssn"
        sub.w9Data = Self.blob
        sub.w9Name = "W9Sub\(Self.sentinel)"
        sub.coiData = Self.blob
        sub.coiName = "sub-coi.pdf"
        sub.coiExpiresOn = soon
        sub.profileImageData = Self.blob
        self.subPayment = TS.oweSub(sub, 450, hours: 10, date: now, detail: "Rough-in", customer: customer, in: context)
        TS.paySub(sub, 200, date: now, detail: "Trip", in: context)
        self.subcontractor = sub

        let state = GLSyncState()
        state.lastSyncAt = now
        context.insert(state)

        context.saveChanges()
        // The Price Sheet is a sync type since 2026-10-03 (QA F3): `saveChanges` mints its id like
        // every synced record's.
        #expect(item.syncID != nil)
    }
}
