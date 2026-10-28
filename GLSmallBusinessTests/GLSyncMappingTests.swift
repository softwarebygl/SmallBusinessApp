//
//  GLSyncMappingTests.swift
//  GLSmallBusinessTests
//
//  The regression net for the GLSync payload layer (GLSYNC-SPEC.md §8, second bullet).
//
//  This app owns a real business's books and GLSync is what carries them off the device. A
//  field that silently stops riding the wire is not a crash and not a red build — it is a
//  number that quietly stops existing on the server, discovered months later. So this file
//  pins two things:
//
//   1. ROUND TRIP, all 24 types. Build an instance with every stored property set to a
//      distinctive NON-DEFAULT value, take `glSyncPayload()`, apply it to a FRESH instance,
//      and require the second payload to equal the first — field by field, on VALUES. Where
//      a mapper deliberately does not restore something (blob BYTES: no model has a column
//      to stash an incoming sha256 in, and each mapper says so at the point it skips), the
//      gap is asserted EXPLICITLY so it is pinned rather than hidden.
//
//   2. THE PROPERTY GUARD. `GLSyncMapperAudit.*Properties` is each mapper's own declared
//      list of the payload keys it emits. This file reconciles that list against the type's
//      ACTUAL stored properties, so adding a stored property to a @Model without mapping it
//      fails the suite. That failure IS the regression net (GLSchema.swift rule 5).
//
//  WHY THE SCHEMA AND NOT `Mirror`. The @Model macro rewrites every declared property into a
//  COMPUTED accessor over its backing data, so reflection over an instance reports the
//  macro's transient storage and not one declared property NAME — see
//  `mirrorIsNotAValidSourceOfStoredProperties`, which asserts exactly that rather than
//  asking anyone to take it on trust. The SwiftData schema is the real answer:
//  `Schema.Entity.attributesByName` + `relationshipsByName` enumerate precisely the
//  properties SwiftData PERSISTS — the same set the server contract is about — and they
//  classify to-one vs to-many, which is the distinction the mappers turn on (a to-many is a
//  child's inverse and never rides).
//
//  ARMED-GUARD PROOF (property guard). The set math below was replayed against the real
//  audit lists and the real @Model sources in three mutated states before this file was
//  written. In the unmutated tree all 23 types reconcile with zero mismatches; each mutation
//  fails, and the text after the colon is what the `#expect` message prints:
//    A. remove "coiName" from `contactProperties["customer"]`
//         → customer: unmapped=["coiName"] extra=[]
//    B. add `var depositPolicy: String = ""` to `Estimate`
//         → estimate: unmapped=["depositPolicy"] extra=[]
//    C. fix the quarantined defect (add "stripePaymentLinkAccountId" to the invoice audit
//       list) WITHOUT removing it from `unmappedDefects`
//         → invoice: unmapped=[] extra=["stripePaymentLinkAccountId"]
//  Case C is the point of the quarantine: the one known-unmapped field cannot be fixed and
//  forgotten, because fixing it forces the quarantine entry out in the same commit.
//

import Testing
import Foundation
import SwiftData
@testable import GLSmallBusiness
import GoldLifeMoney

// MARK: - Payload comparison
//
// `GLSyncPayload` is `[String: Any]`, so equality needs a real comparator rather than `==`.
// Values are restricted to what `JSONSerialization` accepts (GLSyncMappable.swift); the one
// nested shape that arrives through Foundation rather than from a Swift literal is
// `workScheduleData` (it goes out through `JSONSerialization.jsonObject`), which is why
// NSNumber is handled explicitly. Pure, so `nonisolated` — the target defaults to MainActor.

private nonisolated func glTestValuesEqual(_ lhs: Any, _ rhs: Any) -> Bool {
    if lhs is NSNull || rhs is NSNull { return lhs is NSNull && rhs is NSNull }
    if let a = lhs as? String, let b = rhs as? String { return a == b }
    if let a = lhs as? [String: Any], let b = rhs as? [String: Any] {
        return glTestMismatches(a, b, ignoring: []).isEmpty
    }
    if let a = lhs as? [Any], let b = rhs as? [Any] {
        return a.count == b.count && zip(a, b).allSatisfy { glTestValuesEqual($0, $1) }
    }
    if let a = lhs as? NSNumber, let b = rhs as? NSNumber {
        // objCType as well as value: an Int that came back as a Double is a wire change, not
        // a rounding detail, and the server keys its column types on it.
        return a == b && String(cString: a.objCType) == String(cString: b.objCType)
    }
    return false
}

private nonisolated func glTestDescribe(_ value: Any) -> String {
    value is NSNull ? "null" : String(describing: value)
}

/// Human-readable per-key differences, so a failure names the field instead of dumping two
/// 64-key dictionaries.
private nonisolated func glTestMismatches(
    _ before: GLSyncPayload, _ after: GLSyncPayload, ignoring: Set<String>
) -> [String] {
    var problems: [String] = []
    for key in Set(before.keys).union(after.keys).subtracting(ignoring).sorted() {
        switch (before[key], after[key]) {
        case (nil, nil):
            continue
        case let (lhs?, rhs?):
            if !glTestValuesEqual(lhs, rhs) {
                problems.append("\(key): \(glTestDescribe(lhs)) → \(glTestDescribe(rhs))")
            }
        case let (lhs?, nil):
            problems.append("\(key): \(glTestDescribe(lhs)) → <key gone after apply>")
        case let (nil, rhs?):
            problems.append("\(key): <key absent before apply> → \(glTestDescribe(rhs))")
        }
    }
    return problems
}

// MARK: - Fixture values

private enum GLTestValue {

    /// Recognizable attachment bytes. The round-trip and JSON tests assert this marker never
    /// appears anywhere in a SERIALIZED payload, which is how "blob fields carry no bytes" is
    /// proved rather than assumed.
    nonisolated static let blobMarker = "GLSYNC-BLOB-BYTES"

    nonisolated static func blob(_ label: String) -> Data { Data("\(blobMarker)::\(label)".utf8) }

    /// Whole-second dates on purpose: the wire encoding is `Int(seconds * 1000)`, and a whole
    /// second is exactly representable in both directions, so a round-trip failure is a
    /// MAPPER failure and never float drift. Sub-millisecond truncation gets its own test.
    nonisolated static func date(_ secondsSince1970: Int) -> Date {
        Date(timeIntervalSince1970: Double(secondsSince1970))
    }

    /// Distinctive hours (9:15am–6:45pm, alternating workdays) so a payload that quietly
    /// substituted `WorkSchedule.standard` (Mon–Fri 8:00–17:00) would fail rather than look
    /// plausible.
    nonisolated static func workSchedule() -> Data {
        let week = (0..<7).map { index in
            WeekdayHours(isWorkday: index % 2 == 1,
                         startMinutes: 555 + index,
                         endMinutes: 1125 + index)
        }
        let schedule = WorkSchedule(
            weekdayHours: week,
            holidays: [HolidayState(id: "independence-day", enabled: false, oneTimeYear: 2027)],
            vacations: [DateRangeRule(
                id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
                start: date(1_760_000_000),
                end: date(1_760_600_000))],
            customDaysOff: [],
            overrides: [])
        return (try? JSONEncoder().encode(schedule)) ?? Data()
    }
}

// MARK: - The reference graph
//
// Nullify-style links resolve by fetching the referent's `syncID` out of the context, so a
// round trip can only restore them if the referent actually EXISTS locally. These are those
// referents: inserted and SAVED (a `fetchLimit = 1` fetch against pending-only inserts is not
// something to bet a regression net on), each with a fixed, distinguishable id.
//
// Records under test are created through `GLSyncRegistry.createEmpty` — the same path the
// engine uses for a pulled row — and then filled in. One `fill` per type, hand-written for
// the same reason the mappers are (the no-AI-contingency rule): a generated instance would
// set whatever the generator knew about, which is exactly the blind spot this file closes.

@MainActor
private struct GLSyncFixtures {

    let context: ModelContext
    let businessProfile = BusinessProfile()
    let customer = Customer()
    let employee = Employee()
    let subcontractor = Subcontractor()
    let paycheck = Paycheck()
    let estimate = Estimate()
    let estimateGroup = EstimateGroup()
    let invoice = Invoice()
    let invoiceGroup = InvoiceGroup()
    let changeOrder = ChangeOrder()
    let project = Project()
    let job = ScheduledJob()

    init(_ context: ModelContext) throws {
        self.context = context
        businessProfile.syncID = UUID(uuidString: "F0000000-0000-0000-0000-000000000001")!
        customer.syncID        = UUID(uuidString: "F0000000-0000-0000-0000-000000000002")!
        employee.syncID        = UUID(uuidString: "F0000000-0000-0000-0000-000000000003")!
        subcontractor.syncID   = UUID(uuidString: "F0000000-0000-0000-0000-000000000004")!
        paycheck.syncID        = UUID(uuidString: "F0000000-0000-0000-0000-000000000005")!
        estimate.syncID        = UUID(uuidString: "F0000000-0000-0000-0000-000000000006")!
        estimateGroup.syncID   = UUID(uuidString: "F0000000-0000-0000-0000-000000000007")!
        invoice.syncID         = UUID(uuidString: "F0000000-0000-0000-0000-000000000008")!
        invoiceGroup.syncID    = UUID(uuidString: "F0000000-0000-0000-0000-000000000009")!
        changeOrder.syncID     = UUID(uuidString: "F0000000-0000-0000-0000-00000000000A")!
        project.syncID         = UUID(uuidString: "F0000000-0000-0000-0000-00000000000B")!
        job.syncID             = UUID(uuidString: "F0000000-0000-0000-0000-00000000000C")!

        context.insert(businessProfile)
        context.insert(customer)
        context.insert(employee)
        context.insert(subcontractor)
        context.insert(paycheck)
        context.insert(estimate)
        context.insert(estimateGroup)
        context.insert(invoice)
        context.insert(invoiceGroup)
        context.insert(changeOrder)
        context.insert(project)
        context.insert(job)
        try context.save()
    }

    /// A record of this type with EVERY stored property set to a distinctive non-default
    /// value, inserted and saved.
    func makeRich(_ type: String) throws -> GLSyncRecord {
        guard let entry = GLSyncRegistry.entry(for: type) else {
            throw GLSyncFixtureError.noRegistryEntry(type)
        }
        return try makeRich(entry)
    }

    func makeRich(_ entry: GLSyncTypeEntry) throws -> GLSyncRecord {
        let record = entry.createEmpty(context)
        try populate(record)
        try context.save()
        return record
    }

    private func populate(_ record: GLSyncRecord) throws {
        switch record {
        case let x as BusinessProfile:      fill(x)
        case let x as UserProfile:          fill(x)
        case let x as Customer:             fill(x)
        case let x as CustomerDocument:     fill(x)
        case let x as Employee:             fill(x)
        case let x as TimeEntry:            fill(x)
        case let x as Paycheck:             fill(x)
        case let x as Estimate:             fill(x)
        case let x as EstimateGroup:        fill(x)
        case let x as EstimateLineItem:     fill(x)
        case let x as Invoice:              fill(x)
        case let x as InvoiceGroup:         fill(x)
        case let x as InvoiceLineItem:      fill(x)
        case let x as InvoicePayment:       fill(x)
        case let x as ChangeOrder:          fill(x)
        case let x as ChangeOrderLineItem:  fill(x)
        case let x as PaymentProcessor:     fill(x)
        case let x as Project:              fill(x)
        case let x as ScheduledJob:         fill(x)
        case let x as JobAttachment:        fill(x)
        case let x as Receipt:              fill(x)
        case let x as Subcontractor:        fill(x)
        case let x as SubPayment:           fill(x)
        case let x as PriceSheetItem:       fill(x)
        case let x as BankAccount:          fill(x)
        case let x as BankTransaction:      fill(x)
        case let x as TransactionCategoryRule: fill(x)
        case let x as RecurringSubscription: fill(x)
        default:
            // Unreachable while this switch covers `GLSyncRegistry.allTypes`. Reaching it
            // means a 25th type was added with no round-trip fixture — which is the point.
            throw GLSyncFixtureError.noFixture(String(describing: type(of: record)))
        }
    }

    // MARK: Per-type fixtures
    //
    // Every comment of the form "model default: X" marks a value chosen to DIFFER from the
    // property's default, so a mapper that dropped the field would fail rather than coincide.

    private func fill(_ p: BusinessProfile) {
        p.syncID = UUID(uuidString: "A1000000-0000-0000-0000-000000000001")!
        p.updatedAt = GLTestValue.date(1_700_000_001)
        p.businessName = "Gold Standard Tile"
        p.ownerFirstName = "Adrian"
        p.ownerLastName = "Gutierrez"
        p.phone = "8505550101"
        p.email = "owner@example.com"
        p.websiteURL = "https://example.com"
        p.reviewsURL = "https://example.com/reviews"
        p.includeReviewLinkOnReceipts = true            // model default: false
        p.licenseNumber = "LIC-4471"
        p.address = Address(street1: "1 Tile Way", street2: "Suite 3",
                            city: "Miami", state: "FL", postalCode: "32301")
        p.logoData = GLTestValue.blob("logo")
        p.logoDataDark = GLTestValue.blob("logo-dark")
        p.showLogoOnDocuments = false                   // model default: true
        p.showAddressOnDocuments = false                // model default: true
        p.lastInvoiceNumber = 412
        p.lastEstimateNumber = 87
        p.estimateMessageSubject = "subject:estimate"
        p.messageIntro = "intro:estimate"
        p.messageClosing = "closing:estimate"
        p.invoiceMessageSubject = "subject:invoice"
        p.invoiceMessageIntro = "intro:invoice"
        p.invoiceMessageClosing = "closing:invoice"
        p.receiptMessageSubject = "subject:receipt"
        p.receiptMessageIntro = "intro:receipt"
        p.receiptMessageClosing = "closing:receipt"
        p.changeOrderMessageSubject = "subject:changeOrder"
        p.changeOrderMessageIntro = "intro:changeOrder"
        p.changeOrderMessageClosing = "closing:changeOrder"
        p.packageMessageSubject = "subject:package"
        p.packageMessageIntro = "intro:package"
        p.packageMessageClosing = "closing:package"
        p.completionMessageSubject = "subject:completion"
        p.completionMessageIntro = "intro:completion"
        p.completionMessageClosing = "closing:completion"
        p.workScheduleData = GLTestValue.workSchedule()
        p.warrantyText = "One year on labor."
        p.w9Name = "Gold Life LLC"
        p.w9TaxClassification = .llc
        p.w9LLCClassification = "S"
        p.w9OtherClassification = "n/a"
        p.w9TINType = .ein
        p.w9TIN = "12-3456789"                          // NEVER-SYNCS (GLSYNC-SPEC §6)
        p.w9ExemptPayeeCode = "5"
        p.w9FATCACode = "A"
        p.proofOfInsuranceData = GLTestValue.blob("poi")
        p.proofOfInsuranceName = "proof-of-insurance.pdf"
        p.wcInsuranceData = GLTestValue.blob("wc")
        p.wcInsuranceName = "wc-insurance.pdf"
        p.wcExemptionData = GLTestValue.blob("wc-exempt")
        p.wcExemptionName = "wc-exemption.pdf"
        p.licenseDocumentData = GLTestValue.blob("license")
        p.licenseDocumentName = "license.pdf"
        p.ownerReferenceCOIData = GLTestValue.blob("owner-coi")
        p.ownerReferenceCOIName = "owner-reference-coi.pdf"
        p.coiHolderOffsetX = 12.5
        p.coiHolderOffsetY = -3.25
        p.coiHolderBoxWidth = 220.75
        p.coiCoverExistingHolder = true                 // model default: false
        p.stripeConnectedAccountId = "acct_fixture123"
        p.stripeChargesEnabled = true                   // model default: false
        p.stripeAccountClaim = "claim-token-77"
        p.payLinkInclusion = .customSelect              // model default: .all
        p.payLinkDefaultOn = false                      // model default: true
        p.zelleTag = "GoldLifeZelle"
        p.zelleEmail = "zelle@goldlife.com"
        p.zellePhone = "8505550199"
        p.zelleQRCodeData = GLTestValue.blob("zelle-qr")
        p.zelleDefaultOn = true                         // model default: false
    }

    private func fill(_ p: UserProfile) {
        p.syncID = UUID(uuidString: "A2000000-0000-0000-0000-000000000001")!
        p.updatedAt = GLTestValue.date(1_700_000_002)
        // The one field user_profile still carries; identity lives in the Gold Life ID (law 48).
        p.useMyNameInEmails = true                      // model default: false
    }

    private func fill(_ c: Customer) {
        c.syncID = UUID(uuidString: "A3000000-0000-0000-0000-000000000001")!
        c.updatedAt = GLTestValue.date(1_700_000_003)
        c.firstName = "Marcus"
        c.middleName = "T"
        c.lastName = "Reed"
        c.email = "marcus@example.com"
        c.phoneNumber = "8505550103"
        c.officePhone = "8505550104"
        c.businessName = "Reed Construction"
        c.address = Address(street1: "44 Job St", street2: "Bldg B",
                            city: "Quincy", state: "FL", postalCode: "32351")
        c.createdAt = GLTestValue.date(1_690_000_003)
        c.profileImageData = GLTestValue.blob("customer-photo")
        c.coiData = GLTestValue.blob("customer-coi")
        c.coiName = "reed-coi.pdf"
        c.wcCoiData = GLTestValue.blob("customer-wc-coi")
        c.wcCoiName = "reed-wc-coi.pdf"
    }

    private func fill(_ d: CustomerDocument) {
        d.syncID = UUID(uuidString: "A4000000-0000-0000-0000-000000000001")!
        d.updatedAt = GLTestValue.date(1_700_000_004)
        d.data = GLTestValue.blob("customer-document")
        d.name = "osha-card.pdf"
        d.createdAt = GLTestValue.date(1_690_000_004)
        d.customer = customer                           // cascade parent → rides as parent_id
    }

    private func fill(_ e: Employee) {
        e.syncID = UUID(uuidString: "A5000000-0000-0000-0000-000000000001")!
        e.updatedAt = GLTestValue.date(1_700_000_005)
        e.firstName = "Dana"
        e.lastName = "Ruiz"
        e.email = "dana@example.com"
        e.phone = "8505550105"
        e.payType = .salary                             // model default: .hourly
        e.hourlyRate = 47.5
        e.annualSalary = 91_000
        e.payFrequency = .semimonthly                   // model default: .weekly
        e.anchorPayday = GLTestValue.date(1_695_000_005)
        e.hireDate = GLTestValue.date(1_650_000_005)
        e.isActive = false                              // model default: true
        e.notes = "Lead installer."
        e.createdAt = GLTestValue.date(1_640_000_005)
        e.profileImageData = GLTestValue.blob("employee-photo")
    }

    private func fill(_ t: TimeEntry) {
        t.syncID = UUID(uuidString: "A6000000-0000-0000-0000-000000000001")!
        t.updatedAt = GLTestValue.date(1_700_000_006)
        t.date = GLTestValue.date(1_699_000_006)
        t.hours = 6.25
        t.note = "Grout day two."
        t.rateSnapshot = 47.5
        t.amount = 296.88
        t.customer = customer                           // nullify ref → rides in the payload
        t.paycheck = paycheck                           // nullify ref → rides in the payload
        t.employee = employee                           // cascade parent → rides as parent_id
    }

    private func fill(_ p: Paycheck) {
        p.syncID = UUID(uuidString: "A7000000-0000-0000-0000-000000000001")!
        p.updatedAt = GLTestValue.date(1_700_000_007)
        p.payPeriodStart = GLTestValue.date(1_698_000_007)
        p.payPeriodEnd = GLTestValue.date(1_698_600_007)
        p.payDate = GLTestValue.date(1_698_700_007)
        p.grossAmount = 1_500.55
        p.hoursPaid = 32.5
        p.method = .zelle                               // model default: .check
        p.note = "Second half of October."
        p.employee = employee
    }

    private func fill(_ e: Estimate) {
        e.syncID = UUID(uuidString: "A8000000-0000-0000-0000-000000000001")!
        e.updatedAt = GLTestValue.date(1_700_000_008)
        e.number = "EST-0042"
        e.jobTitle = "Master bath retile"
        e.createdAt = GLTestValue.date(1_692_000_008)
        e.validUntil = GLTestValue.date(1_694_000_008)
        e.status = .accepted                            // model default: .draft
        e.combineTotals = false                         // model default: true
        e.customerFirstName = "Marcus"
        e.customerLastName = "Reed"
        e.customerBusinessName = "Reed Construction"
        e.customerEmail = "marcus@example.com"
        e.customerPhone = "8505550103"
        e.customerAddress = Address(street1: "44 Job St", street2: "Bldg B",
                                    city: "Quincy", state: "FL", postalCode: "32351")
        e.serviceAddress = Address(street1: "88 Site Ln", street2: nil,
                                   city: "Havana", state: "FL", postalCode: "32333")
        e.taxRatePercent = 7.5
        e.discountType = .percentage                    // model default: .none
        e.discountValue = 10
        e.depositType = .fixed                          // model default: .none
        e.depositValue = 500
        e.customerNotes = "Owner supplies tile."
        e.terms = "50% deposit."
        e.customer = customer                           // parent AND a payload key
    }

    private func fill(_ g: EstimateGroup) {
        g.syncID = UUID(uuidString: "A9000000-0000-0000-0000-000000000001")!
        g.updatedAt = GLTestValue.date(1_700_000_009)
        g.name = "Demolition"
        g.note = "Haul-off included."
        g.sortIndex = 3
        g.estimate = estimate
    }

    private func fill(_ i: EstimateLineItem) {
        i.syncID = UUID(uuidString: "AA000000-0000-0000-0000-000000000001")!
        i.updatedAt = GLTestValue.date(1_700_000_010)
        i.name = "Porcelain 12x24"
        i.details = "Matte, rectified."
        i.quantity = 12.5                               // model default: 1
        i.unit = .linearFoot                            // model default: .squareFoot
        i.unitPrice = 8.75
        i.kind = .material                              // model default: .labor
        i.isTaxable = true                              // model default: false
        i.sortIndex = 2
        i.discountType = .fixed                         // model default: .none
        i.discountValue = 25
        i.group = estimateGroup
    }

    private func fill(_ v: Invoice) {
        v.syncID = UUID(uuidString: "AB000000-0000-0000-0000-000000000001")!
        v.updatedAt = GLTestValue.date(1_700_000_011)
        v.number = "INV-0042"
        v.jobTitle = "Master bath retile"
        v.createdAt = GLTestValue.date(1_695_000_011)
        v.dueDate = GLTestValue.date(1_697_000_011)
        v.paymentTerms = .net15                         // model default: .net30
        v.status = .sent                                // model default: .draft
        v.customerFirstName = "Marcus"
        v.customerLastName = "Reed"
        v.customerBusinessName = "Reed Construction"
        v.customerEmail = "marcus@example.com"
        v.customerPhone = "8505550103"
        v.customerAddress = Address(street1: "44 Job St", street2: "Bldg B",
                                    city: "Quincy", state: "FL", postalCode: "32351")
        v.serviceAddress = Address(street1: "88 Site Ln", street2: nil,
                                   city: "Havana", state: "FL", postalCode: "32333")
        v.sourceEstimateNumber = "EST-0042"
        v.taxRatePercent = 7.5
        v.discountType = .fixed                         // model default: .none
        v.discountValue = 125
        v.customerNotes = "Balance on completion."
        v.terms = "Net 15."
        v.amountDueNow = 900.25
        v.amountDueDetail = "Deposit"
        v.stripeAppInvoiceId = "app_inv_77"
        v.includePayLink = true                         // model default: false
        v.includeZelle = true                           // model default: false
        v.stripePaymentLinkId = "plink_77"
        v.stripePaymentLinkURL = "https://pay.example.com/plink_77"
        v.stripePaymentLinkAccountId = "acct_fixture123"   // KNOWN UNMAPPED — see the quarantine
        v.stripePaymentLinkAmountCents = 90_025
        v.stripePayLinkStatus = .paid                   // stored raw default: "" → .none
        v.stripePayLinkMintCount = 3
        v.stripePaymentLinkMintedAt = GLTestValue.date(1_696_000_011)
        v.changeOrderNumberSeed = 4
        v.job = job                                     // nullify ref → rides in the payload
        v.customer = customer                           // cascade parent → rides as parent_id
    }

    private func fill(_ g: InvoiceGroup) {
        g.syncID = UUID(uuidString: "AC000000-0000-0000-0000-000000000001")!
        g.updatedAt = GLTestValue.date(1_700_000_012)
        g.name = "Change order work"
        g.note = "Pushed from CO-0007."
        g.sortIndex = 5
        g.changeOrder = changeOrder                     // nullify-style ref in the payload
        g.invoice = invoice                             // cascade parent → rides as parent_id
    }

    private func fill(_ i: InvoiceLineItem) {
        i.syncID = UUID(uuidString: "AD000000-0000-0000-0000-000000000001")!
        i.updatedAt = GLTestValue.date(1_700_000_013)
        i.name = "Waterproofing"
        i.details = "Two coats."
        i.quantity = 88.5                               // model default: 1
        i.unit = .squareYard                            // model default: .squareFoot
        i.unitPrice = 4.25
        i.kind = .material                              // model default: .labor
        i.isTaxable = true                              // model default: false
        i.sortIndex = 6
        i.fromChangeOrder = true                        // model default: false
        i.discountType = .percentage                    // model default: .none
        i.discountValue = 5
        i.group = invoiceGroup
    }

    private func fill(_ p: InvoicePayment) {
        p.syncID = UUID(uuidString: "AE000000-0000-0000-0000-000000000001")!
        p.updatedAt = GLTestValue.date(1_700_000_014)
        p.amount = 750.50
        p.date = GLTestValue.date(1_699_500_014)
        p.method = .venmo                               // model default: .other
        p.note = "Deposit received."
        p.processorName = "Legacy Processor"
        p.processorFeePercentSnapshot = 2.9
        p.processorFlatFeeSnapshot = 0.30
        p.stripePaymentLinkId = "plink_77"
        p.invoice = invoice
    }

    private func fill(_ c: ChangeOrder) {
        c.syncID = UUID(uuidString: "AF000000-0000-0000-0000-000000000001")!
        c.updatedAt = GLTestValue.date(1_700_000_015)
        c.number = "CO-0007"
        c.title = "Add niche"
        c.createdAt = GLTestValue.date(1_696_500_015)
        c.note = "Owner approved on site."
        c.status = .approved                            // stored raw default: .pending
        c.taxRatePercent = 7.5
        c.appliedToInvoice = true                       // model default: false
        c.invoice = invoice                             // parent AND a payload key
        c.invoiceGroup = invoiceGroup
    }

    private func fill(_ i: ChangeOrderLineItem) {
        i.syncID = UUID(uuidString: "B0000000-0000-0000-0000-000000000001")!
        i.updatedAt = GLTestValue.date(1_700_000_016)
        i.name = "Niche framing"
        i.details = "Blocking + board."
        i.quantity = 3.5                                // model default: 1
        i.unit = .hour                                  // model default: .job
        i.unitPrice = 65
        i.isTaxable = true                              // model default: false
        i.sortIndex = 1
        i.changeOrder = changeOrder
    }

    private func fill(_ p: PaymentProcessor) {
        p.syncID = UUID(uuidString: "B1000000-0000-0000-0000-000000000001")!
        p.updatedAt = GLTestValue.date(1_700_000_017)
        p.name = "Square"
        p.feePercent = 2.6
        p.flatFee = 0.10
        p.createdAt = GLTestValue.date(1_660_000_017)
        p.businessProfile = businessProfile
    }

    private func fill(_ p: Project) {
        p.syncID = UUID(uuidString: "B2000000-0000-0000-0000-000000000001")!
        p.updatedAt = GLTestValue.date(1_700_000_018)
        p.name = "Riverside remodel"
        p.createdAt = GLTestValue.date(1_670_000_018)
        p.masterAgreementData = GLTestValue.blob("master-agreement")
        p.masterAgreementName = "master-agreement.pdf"
        p.customer = customer
    }

    private func fill(_ j: ScheduledJob) {
        j.syncID = UUID(uuidString: "B3000000-0000-0000-0000-000000000001")!
        j.updatedAt = GLTestValue.date(1_700_000_019)
        j.title = "Shower pan"
        j.customerName = "Marcus Reed"                  // deliberate snapshot
        j.startDate = GLTestValue.date(1_699_100_019)
        j.durationDays = 7                              // model default: 1
        j.notes = "Bring the wet saw."
        j.createdAt = GLTestValue.date(1_680_000_019)
        j.status = .inProgress                          // stored raw default: .scheduled
        j.completedAt = GLTestValue.date(1_699_900_019)
        j.serviceAddress = Address(street1: "88 Site Ln", street2: "Rear",
                                   city: "Havana", state: "FL", postalCode: "32333")
        j.agreedPrice = 4_200.50
        j.isAllDay = false                              // model default: true
        j.startTime = GLTestValue.date(1_699_130_019)
        j.durationMinutes = 150
        j.recurrenceFrequency = .biweekly               // stored raw default: "" (one-off)
        j.recurrenceWeekdayMask = 42
        j.recurrenceEndDate = GLTestValue.date(1_705_000_019)
        j.recurrenceCount = 6
        j.customer = customer
        j.estimate = estimate
        j.invoice = invoice
        j.project = project
    }

    private func fill(_ a: JobAttachment) {
        a.syncID = UUID(uuidString: "B4000000-0000-0000-0000-000000000001")!
        a.updatedAt = GLTestValue.date(1_700_000_020)
        a.data = GLTestValue.blob("job-attachment")
        a.name = "before.pdf"
        a.caption = "Before demo"
        a.createdAt = GLTestValue.date(1_699_200_020)
        a.kind = .document                              // stored raw default: .photo
        a.job = job
    }

    private func fill(_ r: Receipt) {
        r.syncID = UUID(uuidString: "B5000000-0000-0000-0000-000000000001")!
        r.updatedAt = GLTestValue.date(1_700_000_021)
        r.vendor = "Floor & Decor"
        r.date = GLTestValue.date(1_699_300_021)
        r.total = 187.43
        r.category = "Materials"
        r.notes = "Thinset + trowels."
        r.recognizedText = "FLOOR AND DECOR  187.43"
        r.createdAt = GLTestValue.date(1_699_310_021)
        r.scanData = GLTestValue.blob("receipt-scan")
        r.job = job                                     // nullify ref → rides in the payload
        r.customer = customer                           // cascade parent → rides as parent_id
    }

    private func fill(_ s: Subcontractor) {
        s.syncID = UUID(uuidString: "B6000000-0000-0000-0000-000000000001")!
        s.updatedAt = GLTestValue.date(1_700_000_022)
        s.firstName = "Lee"
        s.lastName = "Ortiz"
        s.businessName = "Ortiz Tile Setting"
        s.email = "lee@example.com"
        s.phone = "8505550122"
        s.hourlyRate = 62.5
        s.address = Address(street1: "3 Trade Ct", street2: nil,
                            city: "Miami", state: "FL", postalCode: "32304")
        s.isActive = false                              // model default: true
        s.notes = "Prefers morning starts."
        s.createdAt = GLTestValue.date(1_665_000_022)
        s.profileImageData = GLTestValue.blob("sub-photo")
        s.tinKey = "sub-tin-key-9f2"                    // write-once Keychain join key
        s.w9TINType = .ssn                              // stored raw default: nil
        s.w9Data = GLTestValue.blob("sub-w9")
        s.coiData = GLTestValue.blob("sub-coi")
        s.w9Name = "ortiz-w9.pdf"
    }

    private func fill(_ p: SubPayment) {
        p.syncID = UUID(uuidString: "B7000000-0000-0000-0000-000000000001")!
        p.updatedAt = GLTestValue.date(1_700_000_023)
        p.amount = 950.25
        p.hours = 15.5
        p.date = GLTestValue.date(1_699_400_023)
        p.paidDate = GLTestValue.date(1_699_450_023)
        p.method = .cashApp                             // model default: .check
        p.detail = "Week 2 setting."
        p.customer = customer                           // nullify ref → rides in the payload
        p.subcontractor = subcontractor                 // cascade parent → rides as parent_id
    }

    private func fill(_ i: PriceSheetItem) {
        i.syncID = UUID(uuidString: "B8000000-0000-0000-0000-000000000001")!
        i.updatedAt = GLTestValue.date(1_700_000_024)
        i.createdAt = GLTestValue.date(1_699_500_024)
        i.name = "Tile install"
        i.details = "Thinset, 12x24 porcelain."
        i.defaultQuantity = 250.5                       // model default: 1
        i.unit = .linearFoot                            // stored raw default: .squareFoot
        i.unitPrice = 12.75
        i.kind = .material                              // stored raw default: .labor
        i.isTaxable = true                              // model default: false
        i.category = "Tile Work"
        i.discountType = .percentage                    // stored raw default: .none
        i.discountValue = 7.5
        i.sortIndex = 3
    }

    private func fill(_ a: BankAccount) {
        a.syncID = UUID(uuidString: "B8000000-0000-0000-0000-000000000002")!
        a.updatedAt = GLTestValue.date(1_700_000_025)
        a.plaidAccountId = "plaid_acc_123"
        a.itemId = "item_123"
        a.institutionName = "Chase"
        a.name = "Business Complete Checking"
        a.mask = "4821"
        a.subtypeRaw = "checking"
        a.currentBalanceCents = 154200
        a.isoCurrencyCode = "USD"
        a.needsReauth = false
    }

    private func fill(_ t: BankTransaction) {
        t.syncID = UUID(uuidString: "B8000000-0000-0000-0000-000000000003")!
        t.updatedAt = GLTestValue.date(1_700_000_026)
        t.plaidTransactionId = "plaid_txn_123"
        t.plaidAccountId = "plaid_acc_123"
        t.name = "Home Depot Store 102"
        t.merchantName = "Home Depot"
        t.amountCents = 8450
        t.isoCurrencyCode = "USD"
        t.date = "2026-10-24"
        t.pending = false
        t.isBusinessOverride = true
        t.matchedRuleSyncID = UUID(uuidString: "B8000000-0000-0000-0000-000000000004")!
        t.isTrackedSubscription = false
    }

    private func fill(_ r: TransactionCategoryRule) {
        r.syncID = UUID(uuidString: "B8000000-0000-0000-0000-000000000004")!
        r.updatedAt = GLTestValue.date(1_700_000_027)
        r.createdAt = GLTestValue.date(1_699_500_027)
        r.normalizedMerchantPattern = "home depot"
        r.displayMerchantName = "Home Depot"
        r.isBusiness = true
    }

    private func fill(_ s: RecurringSubscription) {
        s.syncID = UUID(uuidString: "B8000000-0000-0000-0000-000000000005")!
        s.updatedAt = GLTestValue.date(1_700_000_028)
        s.plaidStreamId = "stream_123"
        s.plaidAccountId = "plaid_acc_123"
        s.merchantName = "Adobe Creative Cloud"
        s.amountCents = 5499
        s.isoCurrencyCode = "USD"
        s.cadenceRaw = "monthly"
        s.lastDate = "2026-10-01"
        s.nextExpectedDate = "2026-11-01"
        s.isActive = true
        s.isBusinessOverride = true
    }
}

private enum GLSyncFixtureError: Error, CustomStringConvertible {
    case noFixture(String)
    case noRegistryEntry(String)
    var description: String {
        switch self {
        case .noFixture(let name):
            return "GLSyncFixtures has no `fill` for \(name) — a sync type was added without a round-trip fixture, so nothing tests its mapper."
        case .noRegistryEntry(let key):
            return "GLSyncRegistry has no entry for '\(key)'."
        }
    }
}

/// One container + context + reference graph. Every test that touches a store builds its own,
/// so no test can be affected by what another one left behind.
@MainActor
private func glTestWorld() throws -> (ModelContext, GLSyncFixtures) {
    // TestStore retains every container for the life of the process — a released container
    // SIGTRAPs a later test through a surviving SwiftData observer (ModelContextTests.swift).
    let context = ModelContext(try TestStore.makeContainer())
    return (context, try GLSyncFixtures(context))
}

// MARK: - Round trip, all 24 types

@MainActor
struct GLSyncMapperRoundTripTests {

    /// `payload(apply(payload)) == payload`, field by field, on VALUES.
    ///
    /// The ONE documented exception is a blob field: `glSyncPayload()` emits `{sha256, name}`
    /// computed from the bytes, and `glSyncApply` deliberately never writes bytes — the
    /// engine fetches attachments separately, and no model has a column to park an incoming
    /// sha256 in (each mapper says so where it skips). So a fresh instance has no bytes and
    /// emits null for those keys, and that gap is asserted below rather than papered over.
    @Test(arguments: GLSyncRegistry.allTypes)
    func roundTripsEveryMappedField(_ type: String) throws {
        let (context, fixtures) = try glTestWorld()
        let entry = try #require(GLSyncRegistry.entry(for: type), "no registry entry for '\(type)'")

        let rich = try fixtures.makeRich(entry)
        let before = rich.glSyncPayload()
        #expect(!before.isEmpty, "\(type): glSyncPayload() produced nothing")

        let fresh = entry.createEmpty(context)
        fresh.glSyncApply(before, in: context)
        let after = fresh.glSyncPayload()

        let blobFields = Set(entry.blobFields)
        let problems = glTestMismatches(before, after, ignoring: blobFields)
        #expect(problems.isEmpty,
                "\(type) did not survive payload → apply → payload: \(problems.joined(separator: " | "))")

        for field in blobFields.sorted() {
            #expect(before[field] is GLSyncPayload,
                    "\(type).\(field): a record WITH bytes must emit a {sha256, name} reference")
            #expect(after[field] is NSNull,
                    """
                    \(type).\(field): glSyncApply is documented NOT to restore blob bytes \
                    (the engine fetches them from /attachments, and there is no hash column \
                    to stash the reference in). A non-null value here means that changed, and \
                    this expectation needs rewriting rather than silencing.
                    """)
        }
    }

    /// The four InvoiceMappers types leave `syncID` out of the patch on purpose: it rides as
    /// the op's `id` (gl-business-api README §3). That makes the ENGINE responsible for
    /// stamping identity on a pulled row, so the contract is pinned here — if a mapper starts
    /// sending `syncID` this fails, and if the engine stops stamping it, a pulled record has
    /// no identity at all.
    @Test(arguments: ["invoice", "invoice_group", "invoice_line_item", "invoice_payment"])
    func identityRidesInTheEnvelopeForTheInvoiceFamily(_ type: String) throws {
        let (context, fixtures) = try glTestWorld()
        let entry = try #require(GLSyncRegistry.entry(for: type))

        let rich = try fixtures.makeRich(entry)
        let payload = rich.glSyncPayload()
        #expect(payload["syncID"] == nil,
                "\(type) must not send syncID in the patch — it is the op's `id`")

        let fresh = entry.createEmpty(context)
        fresh.glSyncApply(payload, in: context)
        #expect(fresh.glSyncID == nil,
                "\(type): applying a patch cannot invent an identity; the engine assigns it")
    }

    /// The other 24 DO carry `syncID`, and a pulled row must land with the server's id rather
    /// than keep a locally minted one.
    @Test func theOtherTwentyFourCarryTheirIdentityInThePatch() throws {
        let (context, fixtures) = try glTestWorld()
        let envelopeOnly: Set<String> = ["invoice", "invoice_group", "invoice_line_item",
                                         "invoice_payment"]
        var checked = 0
        for type in GLSyncRegistry.allTypes where !envelopeOnly.contains(type) {
            let entry = try #require(GLSyncRegistry.entry(for: type))
            let rich = try fixtures.makeRich(entry)
            let expected = try #require(rich.glSyncID)

            let fresh = entry.createEmpty(context)
            fresh.glSyncApply(rich.glSyncPayload(), in: context)
            #expect(fresh.glSyncID == expected, "\(type) lost its identity on apply")
            checked += 1
        }
        #expect(checked == 24, "expected 24 types to carry syncID in the patch, saw \(checked)")
    }
}

// MARK: - Wire shape
//
// The round trip proves the mappers agree with THEMSELVES. These pin the actual VALUES and
// shapes the server contract is written against, so a mapper cannot drift in a
// self-consistent way — encoding a date as seconds on both sides, say — and still pass.

@MainActor
struct GLSyncPayloadShapeTests {

    /// `Address` rides as a JSON OBJECT, never flattened columns (GLSYNC-SPEC §6).
    @Test func addressRidesAsANestedObjectAndNeverAsFlattenedColumns() throws {
        let (_, fixtures) = try glTestWorld()
        let entry = try #require(GLSyncRegistry.entry(for: "customer"))
        let payload = try fixtures.makeRich(entry).glSyncPayload()

        let address = try #require(payload["address"] as? GLSyncPayload,
                                   "address must be a nested object")
        #expect(address["street1"] as? String == "44 Job St")
        #expect(address["street2"] as? String == "Bldg B")
        #expect(address["city"] as? String == "Quincy")
        #expect(address["state"] as? String == "FL")
        #expect(address["postalCode"] as? String == "32351")
        #expect(address.count == 5,
                "the address object gained or lost a field: \(address.keys.sorted())")

        for flattened in ["street1", "street2", "city", "state", "postalCode",
                          "address_street1", "addressCity"] {
            #expect(payload[flattened] == nil,
                    "address must not be flattened — found top-level '\(flattened)'")
        }
    }

    /// An address whose optional `street2` is nil rides as null and comes back nil; an
    /// EMPTY street2 stays empty. The two must not swap.
    ///
    /// Exercised on Customer since 2026-08-29: UserProfile's home address moved to flat
    /// string columns (the optional-composite history trap, UserProfile.swift), and flat
    /// storage NORMALIZES an empty street2 to nil — the distinction only still exists on
    /// the non-optional composites, so that is where the contract is pinned.
    @Test func nestedAddressOptionalDoesNotSwapWithAnEmptyString() throws {
        let (context, _) = try glTestWorld()

        let source = Customer()
        source.address = Address(street1: "1 A St", street2: nil, city: "C", state: "FL",
                                 postalCode: "32301")
        context.insert(source)
        let object = try #require(source.glSyncPayload()["address"] as? GLSyncPayload)
        #expect(object["street2"] is NSNull, "a nil street2 must ride as null, not as \"\"")

        let landedNil = Customer()
        context.insert(landedNil)
        landedNil.glSyncApply(source.glSyncPayload(), in: context)
        #expect(landedNil.address.street2 == nil, "a null street2 came back as an empty string")

        let empty = Customer()
        empty.address = Address(street1: "1 A St", street2: "", city: "C", state: "FL",
                                postalCode: "32301")
        context.insert(empty)
        let landedEmpty = Customer()
        context.insert(landedEmpty)
        landedEmpty.glSyncApply(empty.glSyncPayload(), in: context)
        // Flat storage (2026-09-02) NORMALIZES empty to nil at the facade — the
        // distinction the old assertion pinned no longer exists anywhere.
        #expect(landedEmpty.address.street2 == nil, "empty street2 should normalize to nil under flats")
    }

    /// The person's home address never rides user_profile any more (law 48: it lives in the
    /// Gold Life ID), in either direction. Before 2026-10-05 an empty one rode as null.
    @Test func userProfileCarriesNoHomeAddress() throws {
        let (context, _) = try glTestWorld()
        let source = UserProfile()
        source.useMyNameInEmails = true
        context.insert(source)
        #expect(source.glSyncPayload()["address"] == nil, "the home address still rides user_profile")

        let landed = UserProfile()
        context.insert(landed)
        landed.glSyncApply(["address": ["street1": "9 Old Rd", "city": "Nowhere", "state": "FL",
                                        "postalCode": "1"],
                            "useMyNameInEmails": true], in: context)
        #expect(landed.useMyNameInEmails)
        #expect(landed.glSyncPayload()["address"] == nil, "a pulled address was written onto the phone")
    }

    /// Optional-vs-empty-string must not swap on the plain string optionals either.
    @Test func optionalStringsDoNotSwapWithEmptyStrings() throws {
        let (context, _) = try glTestWorld()

        let nilCase = Customer()
        nilCase.businessName = nil
        context.insert(nilCase)
        #expect(nilCase.glSyncPayload()["businessName"] is NSNull)

        let landedNil = Customer()
        landedNil.businessName = "stale"
        context.insert(landedNil)
        landedNil.glSyncApply(nilCase.glSyncPayload(), in: context)
        #expect(landedNil.businessName == nil, "an explicit null did not clear businessName")

        let emptyCase = Customer()
        emptyCase.businessName = ""
        context.insert(emptyCase)
        #expect(emptyCase.glSyncPayload()["businessName"] as? String == "",
                "an empty businessName rode as null — that loses the difference")

        let landedEmpty = Customer()
        landedEmpty.businessName = "stale"
        context.insert(landedEmpty)
        landedEmpty.glSyncApply(emptyCase.glSyncPayload(), in: context)
        #expect(landedEmpty.businessName == "", "an empty string was swapped to nil")
    }

    /// Dates ride as unix MILLISECONDS (integer) — not seconds, not an ISO string.
    @Test func datesRideAsUnixMilliseconds() throws {
        let (context, _) = try glTestWorld()
        let receipt = Receipt()
        receipt.date = GLTestValue.date(1_699_300_021)
        receipt.createdAt = GLTestValue.date(1_699_310_021)
        context.insert(receipt)
        let payload = receipt.glSyncPayload()

        #expect(payload["date"] as? Int == 1_699_300_021_000,
                "date is not unix millis: \(glTestDescribe(payload["date"] ?? NSNull()))")
        #expect(payload["createdAt"] as? Int == 1_699_310_021_000)
        #expect(payload["date"] as? String == nil, "a date rode as a string")

        let landed = Receipt()
        context.insert(landed)
        landed.glSyncApply(payload, in: context)
        #expect(landed.date == GLTestValue.date(1_699_300_021))
        #expect(landed.createdAt == GLTestValue.date(1_699_310_021))
    }

    /// Sub-millisecond precision is TRUNCATED by the encoding. Deliberate, and asserted so
    /// nobody rediscovers it while chasing a one-millisecond diff.
    @Test func subMillisecondPrecisionTruncatesRatherThanRounds() throws {
        let (context, _) = try glTestWorld()
        let receipt = Receipt()
        receipt.date = Date(timeIntervalSince1970: 1_700_000_000.0015)
        context.insert(receipt)

        let payload = receipt.glSyncPayload()
        #expect(payload["date"] as? Int == 1_700_000_000_001,
                "expected truncation to whole milliseconds")

        let landed = Receipt()
        context.insert(landed)
        landed.glSyncApply(payload, in: context)
        #expect(landed.date < receipt.date, "truncation must lose time, never gain it")
        #expect(abs(landed.date.timeIntervalSince(receipt.date)) < 0.001)
    }

    /// A nil date rides as null, and an ABSENT key does not drag a non-optional date to 1970.
    @Test func anAbsentKeyDoesNotDragANonOptionalDateTo1970() throws {
        let (context, _) = try glTestWorld()
        let job = ScheduledJob()
        job.completedAt = nil
        context.insert(job)
        #expect(job.glSyncPayload()["completedAt"] is NSNull)

        let landed = ScheduledJob()
        landed.startDate = GLTestValue.date(1_699_100_019)
        context.insert(landed)
        landed.glSyncApply(["title": "Patched"], in: context)
        #expect(landed.title == "Patched")
        #expect(landed.startDate == GLTestValue.date(1_699_100_019),
                "an absent key rewrote a non-optional date")
    }

    /// Enums ride as their RAW strings, under the property name the manifest keys on.
    @Test func enumsRideAsRawStrings() throws {
        let (_, fixtures) = try glTestWorld()

        let invoice = try fixtures.makeRich("invoice")
        let invoicePayload = invoice.glSyncPayload()
        #expect(invoicePayload["status"] as? String == "sent")
        #expect(invoicePayload["paymentTerms"] as? String == "net15")
        #expect(invoicePayload["discountType"] as? String == "fixed")
        #expect(invoicePayload["stripePayLinkStatusRaw"] as? String == "paid")

        // `statusRaw`, not `status`: it is the stored property name AND the key the
        // manifest's status_transitions table is written against.
        let order = try fixtures.makeRich("change_order")
        let orderPayload = order.glSyncPayload()
        #expect(orderPayload["statusRaw"] as? String == "approved")
        #expect(orderPayload["status"] == nil, "change_order must key its status on statusRaw")

        let scheduled = try fixtures.makeRich("scheduled_job")
        let jobPayload = scheduled.glSyncPayload()
        #expect(jobPayload["statusRaw"] as? String == "inProgress")
        #expect(jobPayload["recurrenceFrequencyRaw"] as? String == "biweekly")

        let attachment = try fixtures.makeRich("job_attachment")
        #expect(attachment.glSyncPayload()["kindRaw"] as? String == "document")

        let sub = try fixtures.makeRich("subcontractor")
        #expect(sub.glSyncPayload()["w9TINTypeRaw"] as? String == "ssn")

        let profile = try fixtures.makeRich("business_profile")
        let profilePayload = profile.glSyncPayload()
        #expect(profilePayload["w9TaxClassificationRaw"] as? String == "llc")
        #expect(profilePayload["w9TINTypeRaw"] as? String == "ein")
        #expect(profilePayload["payLinkInclusionRaw"] as? String == "customSelect")
    }

    /// Blob fields ride as `{sha256, name}`. The sha256 is checked against the published
    /// SHA-256 of "abc", an EXTERNAL oracle — so this cannot pass by computing the hash the
    /// same wrong way the mapper does.
    @Test func aBlobReferenceCarriesTheRealSHA256AndNothingElse() throws {
        let (context, _) = try glTestWorld()
        let document = CustomerDocument()
        document.data = Data("abc".utf8)
        document.name = "abc.pdf"
        context.insert(document)

        let reference = try #require(document.glSyncPayload()["data"] as? GLSyncPayload,
                                     "a blob field must be a {sha256, name} object")
        #expect(reference["sha256"] as? String
                == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
                "sha256 is not the SHA-256 of the bytes")
        #expect(reference["name"] as? String == "abc.pdf")
        #expect(reference.count == 2,
                "a blob reference must carry exactly {sha256, name}: \(reference.keys.sorted())")
    }

    /// Every blob field of every type, proved by SERIALIZING the payload and looking for the
    /// bytes. A reference object that also smuggled base64 bytes passes a shape check and
    /// fails this one.
    @Test(arguments: GLSyncRegistry.allTypes)
    func noPayloadEverSerializesTheAttachmentBytes(_ type: String) throws {
        let (_, fixtures) = try glTestWorld()
        let entry = try #require(GLSyncRegistry.entry(for: type))
        let payload = try fixtures.makeRich(entry).glSyncPayload()

        #expect(JSONSerialization.isValidJSONObject(payload),
                "\(type): payload is not JSON-serializable — something non-JSON rode along")
        let data = try JSONSerialization.data(withJSONObject: payload)
        let text = try #require(String(data: data, encoding: .utf8))
        #expect(!text.contains(GLTestValue.blobMarker),
                "\(type): attachment bytes reached the payload")
        #expect(!text.contains(Data(GLTestValue.blobMarker.utf8).base64EncodedString()),
                "\(type): attachment bytes reached the payload, base64-encoded")

        for field in entry.blobFields {
            let reference = try #require(payload[field] as? GLSyncPayload,
                                         "\(type).\(field) must be a blob reference")
            #expect(Set(reference.keys) == ["sha256", "name"],
                    "\(type).\(field) reference shape: \(reference.keys.sorted())")
            let sha = try #require(reference["sha256"] as? String)
            #expect(sha.count == 64 && sha.allSatisfy { $0.isHexDigit && !$0.isUppercase },
                    "\(type).\(field) sha256 is not 64 lowercase hex characters: \(sha)")
        }
    }

    /// `BusinessProfile.workScheduleData` is the ONE inline exception (GLSYNC-SPEC §6):
    /// structured JSON in the payload, never an attachment.
    @Test func workScheduleRidesInlineAsStructuredJSONNotAsABlobReference() throws {
        let (context, fixtures) = try glTestWorld()
        let entry = try #require(GLSyncRegistry.entry(for: "business_profile"))
        let payload = try fixtures.makeRich(entry).glSyncPayload()

        let schedule = try #require(payload["workScheduleData"] as? GLSyncPayload,
                                    "workScheduleData must be inline structured JSON")
        #expect(schedule["sha256"] == nil, "workScheduleData must NOT be a blob reference")
        #expect(!entry.blobFields.contains("workScheduleData"),
                "workScheduleData must not be registered as an attachment field")

        let week = try #require(schedule["weekdayHours"] as? [Any])
        #expect(week.count == 7)
        let sunday = try #require(week.first as? GLSyncPayload)
        #expect(sunday["startMinutes"] as? Int == 555, "the real hours were replaced by defaults")
        #expect(sunday["endMinutes"] as? Int == 1125)
        #expect(sunday["isWorkday"] as? Bool == false)
        let vacations = try #require(schedule["vacations"] as? [Any])
        #expect(vacations.count == 1, "nested arrays inside the inline blob were lost")

        // …and it comes back as a decodable WorkSchedule, not merely as bytes.
        let landed = BusinessProfile()
        context.insert(landed)
        landed.glSyncApply(payload, in: context)
        let stored = try #require(landed.workScheduleData)
        let decoded = try JSONDecoder().decode(WorkSchedule.self, from: stored)
        #expect(decoded.weekdayHours.count == 7)
        #expect(decoded.weekdayHours[0].startMinutes == 555)
        #expect(decoded.weekdayHours[0].endMinutes == 1125)
        #expect(decoded.holidays.first?.id == "independence-day")
        #expect(decoded.holidays.first?.oneTimeYear == 2027)
        #expect(decoded.vacations.first?.start == GLTestValue.date(1_760_000_000))
    }

    /// A `workScheduleData` blob that no longer parses as the current shape rides as null —
    /// never as the derived default, which would silently overwrite a real schedule elsewhere.
    @Test func anUnparseableWorkScheduleRidesAsNullNotAsTheDefaultSchedule() throws {
        let (context, _) = try glTestWorld()
        let profile = BusinessProfile()
        profile.workScheduleData = Data("not json".utf8)
        context.insert(profile)
        #expect(profile.glSyncPayload()["workScheduleData"] is NSNull,
                "an unparseable schedule must ride as null, not as WorkSchedule.standard")
    }

    /// `BusinessProfile.w9TIN` is the never-sends field (GLSYNC-SPEC §6). The Worker strips it
    /// too, but the client must not rely on that: a plaintext SSN/EIN never leaves here.
    @Test func theW9TINNeverReachesThePayload() throws {
        let (_, fixtures) = try glTestWorld()
        let entry = try #require(GLSyncRegistry.entry(for: "business_profile"))
        let payload = try fixtures.makeRich(entry).glSyncPayload()

        #expect(payload["w9TIN"] == nil,
                "w9TIN is in the payload — a plaintext TIN left the device")
        let text = try #require(String(data: JSONSerialization.data(withJSONObject: payload),
                                       encoding: .utf8))
        #expect(!text.contains("12-3456789"),
                "the TIN value appeared somewhere in the serialized payload")
    }

    /// Derived money is never sent (GLSYNC-SPEC §6, gl-business-api README §5): the Worker
    /// recomputes it, and a stale total landing there flips invoices Paid/Unpaid.
    @Test(arguments: ["invoice", "invoice_group", "invoice_line_item", "estimate",
                      "estimate_group", "estimate_line_item", "change_order",
                      "change_order_line_item"])
    func derivedMoneyIsNeverSent(_ type: String) throws {
        let (_, fixtures) = try glTestWorld()
        let entry = try #require(GLSyncRegistry.entry(for: type))
        let payload = try fixtures.makeRich(entry).glSyncPayload()

        for key in ["subtotal", "discountAmount", "taxAmount", "total", "amountPaid",
                    "balanceDue", "isPaid", "revisedTotal", "displayStatus", "lineTotal",
                    "grossLineTotal", "lineDiscount", "signedLineTotal", "depositAmount",
                    "isExpired"] {
            #expect(payload[key] == nil,
                    "\(type) sent derived value '\(key)' — the server recomputes it")
        }
    }

    /// To-many relationships are never emitted: they are the inverse of a child's own link,
    /// and the CHILD row carries the edge. Emitting both lets one edge be decided twice.
    @Test(arguments: GLSyncRegistry.allTypes)
    func toManyRelationshipsAreNeverEmitted(_ type: String) throws {
        let (_, fixtures) = try glTestWorld()
        let entry = try #require(GLSyncRegistry.entry(for: type))
        let payload = try fixtures.makeRich(entry).glSyncPayload()

        let entity = try #require(GLSyncSchemaFacts.entity(for: type))
        for (name, relationship) in entity.relationshipsByName
        where !relationship.isToOneRelationship {
            #expect(payload[name] == nil,
                    "\(type) emitted the to-many '\(name)' — the child owns that edge")
        }
    }
}

// MARK: - Enum degradation
//
// "Unknown incoming values degrade to the DEFAULT case, never crash and never reject the
// record" (GLSYNC-SPEC §6, generalizing the shipped PaymentMethod → .other rule). Every case
// below seeds the target with a value that is NOT the degrade target first, so a passing
// assertion proves the degrade actually RAN rather than proving nothing changed. Each payload
// also carries one ordinary field, asserted afterwards, to prove the record was not rejected.

@MainActor
struct GLSyncEnumDegradationTests {

    @Test func unknownInvoiceEnumsDegradeAndTheRecordStillLands() throws {
        let (context, _) = try glTestWorld()
        let invoice = Invoice()
        invoice.paymentTerms = .dueOnReceipt
        invoice.status = .sent
        invoice.discountType = .percentage
        invoice.stripePayLinkStatus = .paid
        context.insert(invoice)

        invoice.glSyncApply([
            "number": "INV-9999",
            "paymentTerms": "net90_from_a_newer_build",
            "status": "voided_from_a_newer_build",
            "discountType": "tiered_from_a_newer_build",
            "stripePayLinkStatusRaw": "refunded_from_a_newer_build",
        ], in: context)

        #expect(invoice.paymentTerms == .net30)
        #expect(invoice.status == .draft)
        #expect(invoice.discountType == AdjustmentType.none)
        #expect(invoice.stripePayLinkStatus == StripePayLinkStatus.none)
        #expect(invoice.number == "INV-9999",
                "an unknown enum rejected the whole record instead of degrading one field")
    }

    /// The two line-item families disagree on their `unit` default on purpose — an estimate
    /// line defaults to square feet, a change-order line to "job". A degrade that used one
    /// default for both would silently reprice change orders.
    @Test func lineItemUnitsDegradeToTheirOwnDefaults() throws {
        let (context, _) = try glTestWorld()

        let estimateLine = EstimateLineItem()
        estimateLine.unit = .hour
        estimateLine.kind = .material
        estimateLine.discountType = .fixed
        context.insert(estimateLine)
        estimateLine.glSyncApply(["name": "Kept", "unit": "furlong",
                                  "kind": "permit", "discountType": "tiered"], in: context)
        #expect(estimateLine.unit == .squareFoot)
        #expect(estimateLine.kind == .labor)
        #expect(estimateLine.discountType == AdjustmentType.none)
        #expect(estimateLine.name == "Kept")

        let invoiceLine = InvoiceLineItem()
        invoiceLine.unit = .hour
        context.insert(invoiceLine)
        invoiceLine.glSyncApply(["unit": "furlong"], in: context)
        #expect(invoiceLine.unit == .squareFoot)

        let changeOrderLine = ChangeOrderLineItem()
        changeOrderLine.unit = .hour
        context.insert(changeOrderLine)
        changeOrderLine.glSyncApply(["unit": "furlong"], in: context)
        #expect(changeOrderLine.unit == .job,
                "a change-order line must degrade to .job, not the estimate line's .squareFoot")
    }

    /// The Price Sheet stores its enums as raw columns (`unitRaw`, `kindRaw`, `discountTypeRaw`),
    /// and those column names are its wire keys. An unknown value from a newer build lands as the
    /// default case, never as a raw string the item would keep.
    @Test func priceSheetEnumsDegradeToTheirDefaults() throws {
        let (context, _) = try glTestWorld()
        let item = PriceSheetItem(unit: .hour, kind: .material, discountType: .fixed)
        context.insert(item)
        item.glSyncApply(["name": "Kept", "unitRaw": "furlong", "kindRaw": "permit",
                          "discountTypeRaw": "tiered"], in: context)
        #expect(item.unitRaw == UnitOfMeasure.squareFoot.rawValue)
        #expect(item.kindRaw == LineItemKind.labor.rawValue)
        #expect(item.discountTypeRaw == AdjustmentType.none.rawValue)
        #expect(item.name == "Kept")

        // An absent key is not part of the change: the local value stands.
        item.unit = .day
        item.glSyncApply(["unitPrice": 9.5], in: context)
        #expect(item.unit == .day && item.unitPrice == 9.5)
    }

    @Test func unknownPaymentMethodsDegradeToOtherEverywhereMoneyIsRecorded() throws {
        let (context, _) = try glTestWorld()

        let payment = InvoicePayment()
        payment.method = .check
        context.insert(payment)
        payment.glSyncApply(["method": "crypto_from_a_newer_build", "note": "Kept"], in: context)
        #expect(payment.method == .other)
        #expect(payment.note == "Kept")

        // Paycheck's MODEL default is .check but the degrade target is .other: the shipped
        // rule is "an unrecognized method reads as Other", not "reads as the model default".
        let paycheck = Paycheck()
        paycheck.method = .zelle
        context.insert(paycheck)
        paycheck.glSyncApply(["method": "crypto_from_a_newer_build"], in: context)
        #expect(paycheck.method == .other)

        let subPayment = SubPayment()
        subPayment.method = .zelle
        context.insert(subPayment)
        subPayment.glSyncApply(["method": "crypto_from_a_newer_build"], in: context)
        #expect(subPayment.method == .other)
    }

    @Test func unknownEstimateAndChangeOrderStatusesDegrade() throws {
        let (context, _) = try glTestWorld()

        let estimate = Estimate()
        estimate.status = .accepted
        estimate.discountType = .fixed
        estimate.depositType = .percentage
        context.insert(estimate)
        estimate.glSyncApply(["status": "expired_from_a_newer_build", "discountType": "tiered",
                              "depositType": "tiered", "number": "EST-9999"], in: context)
        #expect(estimate.status == .draft)
        #expect(estimate.discountType == AdjustmentType.none)
        #expect(estimate.depositType == AdjustmentType.none)
        #expect(estimate.number == "EST-9999")

        let order = ChangeOrder()
        order.status = .approved
        context.insert(order)
        order.glSyncApply(["statusRaw": "withdrawn_from_a_newer_build", "title": "Kept"],
                          in: context)
        #expect(order.status == .pending)
        #expect(order.title == "Kept")
    }

    @Test func unknownJobStatusAndRecurrenceDegrade() throws {
        let (context, _) = try glTestWorld()
        let job = ScheduledJob()
        job.status = .completed
        job.recurrenceFrequency = .weekly
        context.insert(job)

        job.glSyncApply(["statusRaw": "cancelled_from_a_newer_build",
                         "recurrenceFrequencyRaw": "quarterly_from_a_newer_build",
                         "title": "Kept"], in: context)
        #expect(job.status == .scheduled)
        #expect(job.recurrenceFrequency == nil, "an unknown frequency must read as one-off")
        #expect(job.recurrenceFrequencyRaw == "",
                "a raw value no shipped build can render was persisted")
        #expect(job.title == "Kept")
    }

    @Test func unknownEmployeePayEnumsAndAttachmentKindDegrade() throws {
        let (context, _) = try glTestWorld()

        let employee = Employee()
        employee.payType = .salary
        employee.payFrequency = .monthly
        context.insert(employee)
        employee.glSyncApply(["payType": "commission_from_a_newer_build",
                              "payFrequency": "quarterly_from_a_newer_build",
                              "lastName": "Kept"], in: context)
        #expect(employee.payType == .hourly)
        #expect(employee.payFrequency == .weekly)
        #expect(employee.lastName == "Kept")

        let attachment = JobAttachment()
        attachment.kind = .document
        context.insert(attachment)
        attachment.glSyncApply(["kindRaw": "video_from_a_newer_build", "caption": "Kept"],
                               in: context)
        #expect(attachment.kind == .photo)
        #expect(attachment.caption == "Kept")
    }

    @Test func unknownW9EnumsDegradeToNotSetRatherThanPersistingAnUnrenderableValue() throws {
        let (context, _) = try glTestWorld()

        let profile = BusinessProfile()
        profile.w9TaxClassification = .llc
        profile.w9TINType = .ein
        context.insert(profile)
        profile.glSyncApply(["w9TaxClassificationRaw": "reit_from_a_newer_build",
                             "w9TINTypeRaw": "itin_from_a_newer_build",
                             "w9Name": "Kept"], in: context)
        #expect(profile.w9TaxClassification == nil)
        #expect(profile.w9TaxClassificationRaw == "")
        #expect(profile.w9TINType == nil)
        #expect(profile.w9TINTypeRaw == "")
        #expect(profile.w9Name == "Kept")

        let sub = Subcontractor()
        sub.w9TINType = .ein
        context.insert(sub)
        sub.glSyncApply(["w9TINTypeRaw": "itin_from_a_newer_build", "w9Name": "Kept"],
                        in: context)
        #expect(sub.w9TINType == nil)
        #expect(sub.w9Name == "Kept")
    }

    @Test func unknownPayLinkInclusionDegradesToAll() throws {
        let (context, _) = try glTestWorld()
        let profile = BusinessProfile()
        profile.payLinkInclusion = PayLinkInclusion.none
        context.insert(profile)
        profile.glSyncApply(["payLinkInclusionRaw": "weekends_only_from_a_newer_build"],
                            in: context)
        #expect(profile.payLinkInclusion == .all)
    }
}

// MARK: - Documented gaps
//
// Behaviours the mappers deliberately DO NOT have, plus two live defects. Each is pinned so
// it is a decision on the record rather than a surprise, and so the assertion flips the day
// somebody changes it.

@MainActor
struct GLSyncDocumentedGapTests {

    /// Nine of the 24 types carry blob fields and NONE of them can stash an incoming sha256:
    /// there is no hash column on any model. So `glSyncApply` restores the LABEL and leaves
    /// the bytes to the engine's `/attachments` fetch. Add a hash column and this fails,
    /// which is the prompt to start using it.
    @Test func noMapperStashesAnIncomingBlobHash() throws {
        let (context, _) = try glTestWorld()
        let source = CustomerDocument()
        source.data = Data("abc".utf8)
        source.name = "abc.pdf"
        context.insert(source)

        let landed = CustomerDocument()
        context.insert(landed)
        landed.glSyncApply(source.glSyncPayload(), in: context)

        #expect(landed.name == "abc.pdf", "the attachment LABEL must be restored")
        #expect(landed.data == nil,
                "glSyncApply must never write blob bytes — the engine fetches them")
        #expect(landed.glSyncPayload()["data"] is NSNull,
                "with no bytes and nowhere to keep the hash, the reference is null")
    }

    /// REGRESSION: the account a pay link was minted under must survive a sync.
    ///
    /// It did not, until 2026-08-23. `InvoiceDetailScreen` refuses to reuse a pay link unless
    /// `stripePaymentLinkAccountId` matches the currently connected account, so a device
    /// restored from the backend read "", judged every existing link a stranger's, and
    /// re-minted on the next send. Found by the property guard on its first run.
    @Test func invoiceStripeAccountStampSurvivesASync() throws {
        let (context, _) = try glTestWorld()
        let invoice = Invoice()
        invoice.stripePaymentLinkAccountId = "acct_live_original"
        invoice.stripePaymentLinkId = "plink_77"
        context.insert(invoice)

        let payload = invoice.glSyncPayload()
        #expect(payload["stripePaymentLinkAccountId"] as? String == "acct_live_original",
                "the minting account must be on the wire")

        let landed = Invoice()
        context.insert(landed)
        landed.glSyncApply(payload, in: context)
        #expect(landed.stripePaymentLinkId == "plink_77")
        #expect(landed.stripePaymentLinkAccountId == "acct_live_original",
                "a restored device must know which account minted the link, or it re-mints")
    }

    /// REGRESSION: an EMPTY blob must never produce a reference.
    ///
    /// `glSyncBlobHash` is copied into each mapper file and only the PeopleMappers copy
    /// guarded `!data.isEmpty`, so a zero-byte attachment emitted a {sha256} on Customer /
    /// BusinessProfile / Project / CustomerDocument / Receipt / JobAttachment / UserProfile —
    /// while `GLSyncRegistry.blobBytes` filters empty blobs out of the upload either way. The
    /// payload therefore named bytes that were never stored. Unified 2026-08-23; this pins all
    /// three copies so they cannot drift apart again.
    @Test func emptyBlobsNeverProduceAReferenceInAnyMapperFile() throws {
        let (context, _) = try glTestWorld()

        let customer = Customer()          // ContactMappers
        customer.coiData = Data()
        context.insert(customer)
        #expect(customer.glSyncPayload()["coiData"] is NSNull,
                "ContactMappers must not hash an empty blob")

        let profile = BusinessProfile()    // BusinessMappers
        profile.logoData = Data()
        context.insert(profile)
        #expect(profile.glSyncPayload()["logoData"] is NSNull,
                "BusinessMappers must not hash an empty blob")

        let employee = Employee()          // PeopleMappers (already correct)
        employee.profileImageData = Data()
        context.insert(employee)
        #expect(employee.glSyncPayload()["profileImageData"] is NSNull,
                "PeopleMappers guards `!data.isEmpty`")

        // And the reason it matters: the engine uploads neither, so a reference would dangle.
        let entry = try #require(GLSyncRegistry.entry(for: "customer"))
        #expect(entry.blobBytes(customer)["coiData"] == nil,
                "an empty blob is filtered out of the upload, so a reference would have no bytes")
    }

    /// `Subcontractor.tinKey` is write-once (manifest `write_once`): it is the device-Keychain
    /// join key, and overwriting a live one orphans the stored TIN with no plaintext anywhere.
    @Test func subcontractorTinKeyIsWriteOnceOnTheWayIn() throws {
        let (context, _) = try glTestWorld()

        let fresh = Subcontractor()
        context.insert(fresh)
        fresh.glSyncApply(["tinKey": "incoming-key"], in: context)
        #expect(fresh.tinKey == "incoming-key", "an EMPTY tinKey must accept the incoming value")

        let established = Subcontractor()
        established.tinKey = "local-key-do-not-touch"
        context.insert(established)
        established.glSyncApply(["tinKey": "incoming-key", "lastName": "Applied"], in: context)
        #expect(established.tinKey == "local-key-do-not-touch",
                "an established tinKey was overwritten — every stored TIN is now orphaned")
        #expect(established.lastName == "Applied",
                "the write-once guard must not block the rest of the patch")
    }

    /// Identity is never CLEARED by a patch: a null id would orphan the record from its server
    /// row (the Estimate mapper spells this out; its siblings use the same shape).
    @Test func anExplicitNullSyncIDDoesNotOrphanTheRecord() throws {
        let (context, _) = try glTestWorld()
        let estimate = Estimate()
        let id = UUID()
        estimate.syncID = id
        context.insert(estimate)

        estimate.glSyncApply(["syncID": NSNull(), "number": "EST-1234"], in: context)
        #expect(estimate.syncID == id, "a null syncID cleared the record's identity")
        #expect(estimate.number == "EST-1234")
    }

    /// A reference to a record this device has not pulled yet resolves to NIL, never to a
    /// fabricated stub — a stub would be a phantom customer in the customer list.
    @Test func anUnresolvableReferenceLeavesTheLinkNilAndMintsNothing() throws {
        let (context, _) = try glTestWorld()
        let job = ScheduledJob()
        context.insert(job)
        let customersBefore = try context.fetchCount(FetchDescriptor<Customer>())
        let invoicesBefore = try context.fetchCount(FetchDescriptor<Invoice>())

        job.glSyncApply(["customer": UUID().uuidString.lowercased(),
                         "invoice": UUID().uuidString.lowercased(),
                         "title": "Applied anyway"], in: context)

        #expect(job.customer == nil)
        #expect(job.invoice == nil)
        #expect(job.title == "Applied anyway", "an unresolved link must not reject the record")
        let customersAfter = try context.fetchCount(FetchDescriptor<Customer>())
        let invoicesAfter = try context.fetchCount(FetchDescriptor<Invoice>())
        #expect(customersAfter == customersBefore, "a dangling reference minted a phantom Customer")
        #expect(invoicesAfter == invoicesBefore, "a dangling reference minted a phantom Invoice")
    }

    /// Unknown payload keys are ignored: payloads are additive, so a record written by a newer
    /// build must never brick an older one.
    @Test func unknownPayloadKeysAreIgnored() throws {
        let (context, _) = try glTestWorld()
        let customer = Customer()
        context.insert(customer)
        customer.glSyncApply(["firstName": "Ada", "aFieldFromTheFuture": "whatever",
                              "anotherOne": 12], in: context)
        #expect(customer.firstName == "Ada")
    }
}

// MARK: - Stored-property facts
//
// The one place this file reads the SwiftData schema, so the guard and the to-many check
// cannot disagree about what a stored property is.

@MainActor
private enum GLSyncSchemaFacts {

    static let schema = Schema(versionedSchema: GLCurrentSchema.self)

    static func entity(for manifestKey: String) -> Schema.Entity? {
        guard let name = GLSyncRegistry.entry(for: manifestKey)?.entityName else { return nil }
        return schema.entitiesByName[name]
    }

    /// Every property SwiftData PERSISTS for this type, split the way the mappers split them.
    /// Transients are excluded: they are not stored, so they are not the server's business.
    static func storedProperties(for manifestKey: String)
        -> (attributes: Set<String>, toOne: Set<String>, toMany: Set<String>)? {
        guard let entity = entity(for: manifestKey) else { return nil }
        let attributes = Set(entity.attributesByName.filter { !$0.value.isTransient }.keys)
        var toOne: Set<String> = []
        var toMany: Set<String> = []
        for (name, relationship) in entity.relationshipsByName where !relationship.isTransient {
            if relationship.isToOneRelationship { toOne.insert(name) } else { toMany.insert(name) }
        }
        return (attributes, toOne, toMany)
    }
}

// MARK: - The property guard

@MainActor
struct GLSyncPropertyGuardTests {

    /// Every mapper file's audit list, merged. These ARE the payload keys each mapper claims
    /// to emit; `auditListMatchesWhatTheMapperActuallyEmits` proves the claim.
    static let audit: [String: [String]] = {
        var merged: [String: [String]] = [:]
        for table in [GLSyncMapperAudit.businessProperties, GLSyncMapperAudit.contactProperties,
                      GLSyncMapperAudit.estimateProperties, GLSyncMapperAudit.invoiceProperties,
                      GLSyncMapperAudit.peopleProperties, GLSyncMapperAudit.priceSheetProperties,
                      GLSyncMapperAudit.moneyProperties] {
            merged.merge(table) { existing, _ in existing }
        }
        return merged
    }()

    /// Stored properties that are NOT payload keys, and WHY. Every entry is a contract
    /// statement someone made on purpose; there are exactly three reasons and no others.
    ///
    ///  1. the CASCADE parent link — it rides in the op ENVELOPE as `parent_id`
    ///     (gl-business-api README §3), so a mapper that also emitted it would give one edge
    ///     two sources of truth. The five types whose mapper sends the parent ANYWAY
    ///     (estimate, estimate_group, estimate_line_item, change_order,
    ///     change_order_line_item) are absent here, because for them it IS a payload key.
    ///     Both shapes are legal; this table records which is which.
    ///  2. `syncID` — it rides as the op's `id`. The four invoice-family mappers leave it out
    ///     for that reason; the other 20 send it too, which is harmless and lets a pulled row
    ///     re-establish its own identity.
    ///  3. never-sent — `BusinessProfile.w9TIN` (GLSYNC-SPEC §6). The Worker strips it, but a
    ///     plaintext SSN/EIN must not leave the device in the first place.
    ///  4. rides COMBINED — each model's `address*` flat columns fold into one "address"
    ///     object on the wire (via a façade), so the wire shape never changed. The flat
    ///     columns exist because writing an OPTIONAL composite poisons persistent history —
    ///     fetchHistory fatals materializing the row (the build-48 launch crash, 2026-08-29).
    ///  6. identity — `UserProfile`'s legacy name, contact, address, photo and signature
    ///     columns. They live in the Gold Life ID alone (law 48 / 48a; audit 2026-10-03 F19),
    ///     stay in the schema only until a store migration drops them, and never sync.
    ///
    /// To-many relationships need no entry: they are excluded by RULE below, because a
    /// to-many is the inverse of a child's own reference and the CHILD row carries the edge.
    static let notOnTheWire: [String: Set<String>] = [
        "business_profile":  ["w9TIN",                      // 3
                              "addressStreet1", "addressStreet2", "addressCity",
                              "addressState", "addressPostalCode",   // 4
                              "legacyAddress"],             // 5
        "user_profile":      [],
        "customer":          ["addressStreet1", "addressStreet2", "addressCity",
                              "addressState", "addressPostalCode",   // 4
                              "serviceAddressStreet1", "serviceAddressStreet2", "serviceAddressCity",
                              "serviceAddressState", "serviceAddressPostalCode", "sameAsBillingAddress",
                              "legacyAddress"],             // 5
        "subcontractor":     ["addressStreet1", "addressStreet2", "addressCity",
                              "addressState", "addressPostalCode",   // 4
                              "legacyAddress"],             // 5
        "estimate":          ["customerAddressStreet1", "customerAddressStreet2", "customerAddressCity",
                              "customerAddressState", "customerAddressPostalCode",
                              "serviceAddressStreet1", "serviceAddressStreet2", "serviceAddressCity",
                              "serviceAddressState", "serviceAddressPostalCode",  // 4
                              "legacyCustomerAddress", "legacyServiceAddress"],   // 5
        "scheduled_job":     ["serviceAddressStreet1", "serviceAddressStreet2", "serviceAddressCity",
                              "serviceAddressState", "serviceAddressPostalCode",  // 4
                              "legacyServiceAddress", "contract"],      // 5
        "customer_document": ["customer"],                  // 1
        "invoice":           ["syncID", "customer", "contract",         // 2, 1
                              "autoRemindersEnabled", "isMarkedPastDue", "lastReminderSentAt",
                              "reminderFrequencyRaw", "reminderStartTriggerRaw",
                              "customerAddressStreet1", "customerAddressStreet2", "customerAddressCity",
                              "customerAddressState", "customerAddressPostalCode",
                              "serviceAddressStreet1", "serviceAddressStreet2", "serviceAddressCity",
                              "serviceAddressState", "serviceAddressPostalCode",  // 4
                              "legacyCustomerAddress", "legacyServiceAddress"],   // 5
        "invoice_group":     ["syncID", "invoice"],         // 2, 1
        "invoice_line_item": ["syncID", "group"],           // 2, 1
        "invoice_payment":   ["syncID", "invoice"],         // 2, 1
        "time_entry":        ["employee"],                  // 1
        "paycheck":          ["employee"],                  // 1
        "payment_processor": ["businessProfile"],           // 1
        "project":           ["customer"],                  // 1
        "job_attachment":    ["job", "invoice", "contract"],            // 1, 3
        "receipt":           ["customer", "contract"],                  // 1
        "sub_payment":       ["subcontractor"],             // 1
        "change_order":      ["contract"],
        "bank_transaction":  ["account", "bankAccountSyncID"],          // 1
        "recurring_subscription": ["account", "bankAccountSyncID"],     // 1
    ]

    /// Wire keys with NO stored property behind them: since the 2026-09-02 CRUD fix,
    /// every Address rides the wire as ONE object built by a facade from flat columns
    /// (the stored composite is dormant). Closed list — a new facade must be added
    /// here consciously, alongside its flats in `notOnTheWire` (reason 4).
    private static let facadeWireKeys: [String: Set<String>] = [
        "business_profile": ["address"],
        "customer":         ["address"],
        "subcontractor":    ["address"],
        "estimate":         ["customerAddress", "serviceAddress"],
        "invoice":          ["customerAddress", "serviceAddress"],
        "scheduled_job":    ["serviceAddress"],
    ]

    /// DEFECT QUARANTINE — stored properties that SHOULD be on the wire and are not.
    /// Not a waiver list: a countdown. Adding an entry is admitting a field does not sync;
    /// fixing the mapper makes the guard fail until the entry is removed, so a fix cannot
    /// land half-done. See `invoiceStripeAccountStampSurvivesASync` for the one that used
    /// to be here.
    /// Empty, and the goal is that it stays that way. `invoice.stripePaymentLinkAccountId`
    /// lived here for exactly as long as it took to fix the mapper (2026-08-23).
    static let unmappedDefects: [String: Set<String>] = [:]

    /// THE GUARD. Reconciles each mapper's declared payload keys against the type's actual
    /// stored properties. Fails when a stored property is added to a @Model and not mapped
    /// (GLSchema.swift rule 5 — property + mapper line + manifest entry, same commit).
    @Test(arguments: GLSyncRegistry.allTypes)
    func auditListAccountsForEveryStoredProperty(_ type: String) throws {
        let facts = try #require(GLSyncSchemaFacts.storedProperties(for: type),
                                 "no SwiftData entity for '\(type)'")
        let declared = try #require(Self.audit[type], "no audit list for '\(type)'")
        #expect(Set(declared).count == declared.count,
                "\(type): duplicate key in the audit list — \(declared)")

        let expected = facts.attributes
            .union(facts.toOne)
            .union(Self.facadeWireKeys[type] ?? [])
            .subtracting(Self.notOnTheWire[type] ?? [])
            .subtracting(Self.unmappedDefects[type] ?? [])
        let actual = Set(declared)

        let unmapped = expected.subtracting(actual).sorted()
        let extra = actual.subtracting(expected).sorted()
        #expect(unmapped.isEmpty && extra.isEmpty,
                """
                \(type): unmapped=\(unmapped) extra=\(extra). A stored property is not on the \
                wire, or an audit key no longer names one. Fix = add the field to the mapper \
                AND its audit list AND gl-business-api/sync-manifest.json (GLSchema.swift \
                rule 5); or, if it is deliberately never sent, add it to `notOnTheWire` with \
                its reason.
                """)
    }

    /// …and the audit list is worth nothing unless it matches what the mapper really emits.
    @Test(arguments: GLSyncRegistry.allTypes)
    func auditListMatchesWhatTheMapperActuallyEmits(_ type: String) throws {
        let (_, fixtures) = try glTestWorld()
        let entry = try #require(GLSyncRegistry.entry(for: type))
        let emitted = Set(try fixtures.makeRich(entry).glSyncPayload().keys)
        let declared = Set(try #require(Self.audit[type]))

        #expect(emitted == declared,
                """
                \(type): the audit list and glSyncPayload() disagree — \
                emitted-but-undeclared=\(emitted.subtracting(declared).sorted()) \
                declared-but-not-emitted=\(declared.subtracting(emitted).sorted())
                """)
    }

    /// The audit tables together cover all 28 types exactly once — a key defined in two
    /// mapper files would have one copy silently win the merge.
    @Test func theAuditTablesCoverAllTypesWithoutOverlap() {
        let tables = [GLSyncMapperAudit.businessProperties, GLSyncMapperAudit.contactProperties,
                      GLSyncMapperAudit.estimateProperties, GLSyncMapperAudit.invoiceProperties,
                      GLSyncMapperAudit.peopleProperties, GLSyncMapperAudit.priceSheetProperties,
                      GLSyncMapperAudit.moneyProperties]
        let total = tables.reduce(0) { $0 + $1.count }
        #expect(total == 28, "the audit tables declare \(total) types, expected 28")
        #expect(Self.audit.count == 28,
                "the merged audit has \(Self.audit.count) types — two tables share a key")
        let difference = Set(Self.audit.keys).symmetricDifference(Set(GLSyncRegistry.allTypes))
        #expect(difference.isEmpty, "audit keys and registry keys disagree: \(difference.sorted())")
    }

    /// Why the guard reads the schema and not `Mirror`: the @Model macro turns every declared
    /// property into a computed accessor over its backing data, so reflection cannot see one
    /// of them by name. A canary, not a preference — if it ever fails, SwiftData changed and
    /// the guard's source is worth reconsidering.
    @Test func mirrorIsNotAValidSourceOfStoredProperties() throws {
        let labels = Set(Mirror(reflecting: Customer()).children.compactMap(\.label))
        #expect(!labels.contains("firstName"),
                "Mirror now reports declared @Model properties — revisit the guard's source")
        #expect(!labels.contains("coiName"))

        let facts = try #require(GLSyncSchemaFacts.storedProperties(for: "customer"))
        #expect(facts.attributes.contains("firstName"), "the schema route lost a known attribute")
        #expect(facts.attributes.contains("coiName"))
        #expect(facts.toMany.contains("estimates"), "the schema route lost a known to-many")
    }

    /// Since 2026-09-02 every Address composite is DORMANT storage (write-forbidden;
    /// the build-62 SIGTRAP) behind flat columns + a facade — the WIRE still carries
    /// one "address" object, but the schema deliberately holds the renamed legacy
    /// composite AND the five flats. This pins that exact shape so neither half can
    /// silently vanish (the composite must survive for old stores to keep opening).
    @Test func addressIsASingleCompositeAttributeInTheSchema() throws {
        for (type, legacy) in [("customer", "legacyAddress"), ("subcontractor", "legacyAddress"),
                               ("business_profile", "legacyAddress")] {
            let facts = try #require(GLSyncSchemaFacts.storedProperties(for: type))
            #expect(facts.attributes.contains(legacy), "\(type) lost its dormant legacy composite")
            for part in ["Street1", "Street2", "City", "State", "PostalCode"] {
                #expect(facts.attributes.contains("address\(part)"),
                        "\(type): missing flat column address\(part)")
            }
            // The bare sub-column names must NOT exist — flats are prefixed.
            for bare in ["street1", "city", "postalCode"] {
                #expect(!facts.attributes.contains(bare),
                        "\(type): unprefixed '\(bare)' column appeared")
            }
        }
    }

    /// Cross-check on the exclusion table itself: every cascade-parent entry really is the
    /// parent the registry declares, so an entry cannot be used to hide an ordinary unmapped
    /// field by calling it a parent link. The reason-4 flats (flat address columns that ride
    /// COMBINED as their "address"/"customerAddress"/"serviceAddress" objects — every model
    /// since the 2026-09-02 CRUD fix) and the reason-5 dormant legacy composites (write-
    /// forbidden storage kept only so old stores open) are enumerated by NAME here — closed
    /// lists, so neither exemption can quietly grow.
    private static let ridesCombined: Set<String> = [
        "addressStreet1", "addressStreet2", "addressCity", "addressState", "addressPostalCode",
        "customerAddressStreet1", "customerAddressStreet2", "customerAddressCity",
        "customerAddressState", "customerAddressPostalCode",
        "serviceAddressStreet1", "serviceAddressStreet2", "serviceAddressCity",
        "serviceAddressState", "serviceAddressPostalCode",
    ]

    private static let dormantLegacy: Set<String> = [
        "legacyAddress", "legacyCustomerAddress", "legacyServiceAddress",
    ]

    private static let neverSent: Set<String> = [
        "w9TIN", "invoice", "contract", "sameAsBillingAddress",
        "autoRemindersEnabled", "isMarkedPastDue", "lastReminderSentAt",
        "reminderFrequencyRaw", "reminderStartTriggerRaw", "bankAccountSyncID",
    ]

    @Test func everyCascadeParentExclusionIsTheRegistrysDeclaredParent() throws {
        for (type, excluded) in Self.notOnTheWire {
            let entry = try #require(GLSyncRegistry.entry(for: type))
            let facts = try #require(GLSyncSchemaFacts.storedProperties(for: type))
            for name in excluded where name != "syncID" && !Self.neverSent.contains(name)
                && !Self.ridesCombined.contains(name)
                && !Self.dormantLegacy.contains(name) {
                let parentType = try #require(
                    entry.parentType,
                    "\(type) excludes '\(name)' as a parent link, but the registry says it has no cascade parent")
                #expect(facts.toOne.contains(name),
                        "\(type).\(name) is excluded as a parent link but is not a to-one")
                let destination = GLSyncSchemaFacts.entity(for: type)?
                    .relationshipsByName[name]?.destination
                let parentEntity = GLSyncRegistry.entry(for: parentType)?.entityName
                #expect(destination == parentEntity,
                        "\(type).\(name) points at \(destination ?? "?"), but the manifest parent is \(parentEntity ?? "?")")
            }
        }
    }
}

// MARK: - Manifest keys

@MainActor
struct GLSyncManifestKeyTests {

    /// The 24 keys of gl-business-api/sync-manifest.json, pinned as a literal (the 24th,
    /// `price_sheet_item`, joined on 2026-10-03 — QA finding F3).
    ///
    /// Pinned rather than read from the bundle because the test bundle has no copy: the
    /// manifest lives in a SIBLING repo, and adding it as a bundle resource means editing
    /// project.pbxproj. `pinnedKeysMatchTheManifestFileOnDisk` below still reads the real
    /// file when the checkout is reachable, so this literal cannot rot unnoticed on a
    /// developer machine.
    static let manifestKeys: Set<String> = [
        "business_profile", "user_profile", "customer", "customer_document", "employee",
        "time_entry", "paycheck", "estimate", "estimate_group", "estimate_line_item",
        "invoice", "invoice_group", "invoice_line_item", "invoice_payment", "change_order",
        "change_order_line_item", "payment_processor", "project", "scheduled_job",
        "job_attachment", "receipt", "subcontractor", "sub_payment", "price_sheet_item",
        "bank_account", "bank_transaction", "transaction_category_rule", "recurring_subscription",
    ]

    /// All 28 mappers, so `glSyncType` is read off the mapper itself rather than off a list
    /// that could agree with the registry while both are wrong.
    static let mappers: [any GLSyncMappable.Type] = [
        BusinessProfile.self, UserProfile.self, Customer.self, CustomerDocument.self,
        Employee.self, TimeEntry.self, Paycheck.self, Estimate.self, EstimateGroup.self,
        EstimateLineItem.self, Invoice.self, InvoiceGroup.self, InvoiceLineItem.self,
        InvoicePayment.self, ChangeOrder.self, ChangeOrderLineItem.self, PaymentProcessor.self,
        Project.self, ScheduledJob.self, JobAttachment.self, Receipt.self, Subcontractor.self,
        SubPayment.self, PriceSheetItem.self,
        BankAccount.self, BankTransaction.self, TransactionCategoryRule.self, RecurringSubscription.self,
    ]

    @Test func everyMapperTypeStringIsAManifestKey() {
        #expect(Self.manifestKeys.count == 28)
        #expect(Self.mappers.count == 28)

        var seen: Set<String> = []
        for mapper in Self.mappers {
            let key = mapper.glSyncType
            #expect(Self.manifestKeys.contains(key),
                    "'\(key)' is not a key in gl-business-api/sync-manifest.json")
            let isNew = seen.insert(key).inserted
            #expect(isNew, "two mappers both claim the key '\(key)'")
        }
        #expect(seen == Self.manifestKeys,
                "manifest keys with no mapper: \(Self.manifestKeys.subtracting(seen).sorted())")

        let difference = Set(GLSyncRegistry.allTypes).symmetricDifference(Self.manifestKeys)
        #expect(difference.isEmpty,
                "GLSyncRegistry.allTypes and the manifest disagree: \(difference.sorted())")
    }

    /// The `types` object of the REAL manifest, read from the sibling checkout — or nil where
    /// that checkout is not reachable (a sandbox, another machine), which every caller treats as
    /// "cannot check here" rather than as a failure. The pinned literals in this file are the
    /// pin either way; reading the file only stops them drifting where it CAN be checked.
    static func manifestTypesOnDisk() throws -> [String: Any]? {
        let manifest = GLSource.repoRoot                   // …/SmallBusinessApp
            .deletingLastPathComponent()                   // …/Github
            .appendingPathComponent("gl-business-api/sync-manifest.json")

        guard let data = try? Data(contentsOf: manifest) else { return nil }
        let decoded = try JSONSerialization.jsonObject(with: data)
        let root = try #require(decoded as? [String: Any])
        return try #require(root["types"] as? [String: Any],
                            "sync-manifest.json has no `types` object")
    }

    /// Cross-check the pinned literal against the real manifest when the sibling checkout is
    /// reachable.
    @Test func pinnedKeysMatchTheManifestFileOnDisk() throws {
        guard let types = try Self.manifestTypesOnDisk() else { return }
        let difference = Set(types.keys).symmetricDifference(Self.manifestKeys)
        #expect(difference.isEmpty,
                "the pinned key list has drifted from gl-business-api/sync-manifest.json: \(difference.sorted())")

        // …and the blob_fields the registry drives uploads from must match the manifest's.
        // One named exception: user_profile's photo and signature files left the app in 3.3.0
        // (law 48: they live in the Gold Life ID), while the manifest keeps listing them for
        // older builds that still upload them (the Worker strips the references).
        let retiredInApp: [String: Set<String>] = ["user_profile": ["photoData", "signatureData"]]
        for (key, raw) in types {
            let rules = try #require(raw as? [String: Any])
            let manifestBlobs = Set((rules["blob_fields"] as? [String]) ?? [])
                .subtracting(retiredInApp[key] ?? [])
            let registryBlobs = Set(GLSyncRegistry.entry(for: key)?.blobFields ?? [])
            #expect(manifestBlobs == registryBlobs,
                    "\(key): blob_fields disagree — manifest \(manifestBlobs.sorted()) vs registry \(registryBlobs.sorted())")
        }
    }

    // MARK: - The paid-invoice money lock, as the manifest ships it
    //
    // The app reads these rules in BOTH directions, so a silent manifest edit either way puts it
    // back into the divergence PaidInvoiceLock.swift exists to prevent:
    //   • it BLOCKS (invoice edit/delete, change-order delete, customer delete) exactly where the
    //     Worker would refuse the write;
    //   • and it deliberately KEEPS writing `amountDueNow` on a settled invoice
    //     (`Invoice.drawDownAmountDueRequest`), which only works because that one field is
    //     `paid_lock_exempt` — a milestone REQUEST is not a record of money collected.

    /// The types whose rows the lock covers (gl-business-api sync-manifest.json `paid_lock`).
    static let paidLockTypes: Set<String> = ["invoice", "invoice_group", "invoice_line_item"]

    /// The invoice's protected money fields, and the ONE the paid state does not freeze.
    static let invoiceProtectedFields: Set<String> = [
        "taxRatePercent", "discountType", "discountValue", "amountDueNow",
        "stripePaymentLinkAmountCents",
    ]
    static let invoicePaidLockExempt: Set<String> = ["amountDueNow"]

    @Test func paidLockRulesMatchTheManifestFileOnDisk() throws {
        guard let types = try Self.manifestTypesOnDisk() else { return }

        var locked: Set<String> = []
        for (key, raw) in types {
            let rules = try #require(raw as? [String: Any])
            if (rules["paid_lock"] as? Bool) == true { locked.insert(key) }
            // An exemption on a type outside the lock's scope would be dead data pretending to
            // be a rule — the Worker's own manifest validator refuses it, and so does this.
            if rules["paid_lock_exempt"] != nil {
                #expect(Self.paidLockTypes.contains(key), "\(key) exempts fields from a lock it is not in")
            }
        }
        #expect(locked == Self.paidLockTypes,
                "the paid_lock scope drifted: \(locked.sorted())")

        let invoice = try #require(types["invoice"] as? [String: Any])
        let protectedFields = Set((invoice["protected"] as? [String]) ?? [])
        let exempt = Set((invoice["paid_lock_exempt"] as? [String]) ?? [])
        #expect(protectedFields == Self.invoiceProtectedFields,
                "invoice protected fields drifted: \(protectedFields.sorted())")
        #expect(exempt == Self.invoicePaidLockExempt,
                "invoice paid_lock_exempt drifted: \(exempt.sorted())")
        // Exempt only narrows the PAID lock. An exempt field that stopped being protected would
        // start auto-merging concurrent money edits instead of parking them for a human.
        #expect(exempt.isSubset(of: protectedFields),
                "an exempt field must still be protected: \(exempt.subtracting(protectedFields).sorted())")
        // The fields that CAN take money off a customer must never join the exempt list:
        // stripePaymentLinkAmountCents is what a live pay link charges.
        #expect(!exempt.contains("stripePaymentLinkAmountCents"),
                "the pay-link amount is money a customer can still be charged — never exempt")
    }

    /// The blob-field lists, pinned independently of the file, so the check above is not the
    /// only thing between a mistyped field name and an attachment that never uploads.
    @Test func blobFieldsArePinnedPerType() throws {
        let expected: [String: Set<String>] = [
            "business_profile": ["logoData", "logoDataDark", "proofOfInsuranceData",
                                 "wcInsuranceData", "wcExemptionData", "licenseDocumentData",
                                 "ownerReferenceCOIData", "zelleQRCodeData"],
            "customer": ["profileImageData", "coiData", "wcCoiData"],
            "customer_document": ["data"],
            "employee": ["profileImageData"],
            "subcontractor": ["profileImageData", "w9Data", "coiData"],
            "project": ["masterAgreementData"],
            "job_attachment": ["data"],
            "receipt": ["scanData"],
        ]
        for type in GLSyncRegistry.allTypes {
            let entry = try #require(GLSyncRegistry.entry(for: type))
            #expect(Set(entry.blobFields) == (expected[type] ?? []),
                    "\(type) blob fields: \(entry.blobFields.sorted())")
        }

        // Only the subcontractor W-9 is tax-class PII — the Worker refuses an unencrypted
        // upload for it, so a wrong answer here is a compliance failure, not a cosmetic one.
        #expect(GLSyncRegistry.piiClass(type: "subcontractor", field: "w9Data") == .tax)
        #expect(GLSyncRegistry.piiClass(type: "subcontractor", field: "profileImageData") == .normal)
        #expect(GLSyncRegistry.piiClass(type: "business_profile", field: "logoData") == .normal)
    }
}
