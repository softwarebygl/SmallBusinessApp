//
//  MBHandoffTools.swift
//  GLSmallBusiness — AI
//
//  The six tools that hand the person a screen instead of writing something: `open`, `send`,
//  `pick_media`, `share_document`, `save_to_contacts` and `contact_developer`.
//
//  Each one only CHECKS (the target exists, it is live, the arguments name something real) and
//  then returns `.handoff`. `MBAIHandoffPresenter` — mounted on a view that stays on screen for
//  the whole request — presents the compose sheet, the share sheet, the picker or the push, and
//  the loop waits for the REAL outcome (contract A5): a `.sent` row only for an actual send.
//
//  The model never sees a document's contents: a share or a send hands over a file the person
//  looks at, and the result says sent / shared / cancelled / failed and nothing else.
//

import Foundation
import SwiftData
import GoldLifeAI

// MARK: - Handoff vocabulary

/// The `kind` on every `GLAIHandoff` this app raises — the app's own vocabulary, read only by
/// `MBAIHandoffPresenter` (the package knows nothing about it).
enum MBHandoffKind: String {
    case open, send
    case pickMedia = "pick_media"
    case shareDocument = "share_document"
    case saveToContacts = "save_to_contacts"
    case contactDeveloper = "contact_developer"
}

/// Everything `open` can show: a record kind, or one of the app's own screens.
enum MBOpenTarget: String, CaseIterable {
    case customer, estimate, contract, invoice
    case changeOrder = "change_order"
    case job, receipt
    case priceItem = "price_item"
    case employee, subcontractor, project, payment
    case timeEntry = "time_entry"
    case paycheck
    case subPayment = "sub_payment"
    case attachment, document
    case business
    case workSchedule = "work_schedule"
    case settings
    case documentMessages = "document_messages"
    case priceSheet = "price_sheet"
    case stats
    case complianceDocs = "compliance_docs"
    case stripeSetup = "stripe_setup"
    case zelleSetup = "zelle_setup"
    case contracts = "contracts"
    case howTo = "how_to"
    case whatsNew = "whats_new"
    case about, calendar
    case privacyPolicy = "privacy_policy"
    case termsOfUse = "terms_of_use"
    case subscription
    case goldLifeID = "gold_life_id"
    case deviceInfo = "device_info"
    case money = "money"
    case subscriptions = "subscriptions"
    case connectedBanks = "connected_banks"

    /// The record kind this target names, when it names one.
    var recordKind: MBRecordKind? { MBRecordKind(rawValue: rawValue) }
}

// MARK: - open

@MainActor
struct MBOpenTool: GLAITool {
    let entry: GLAIManifest.Tool
    let env: MBToolEnvironment

    var name: String { entry.name }
    var summary: String { entry.summary }
    var parameters: GLAISchema { entry.parameters }
    var area: GLAIToolArea { entry.area }

    func run(_ call: GLAIToolCall, context: GLAIToolContext) async -> GLAIToolOutcome {
        guard context.isStillCurrent, let store = env.context() else { return MBToolFailure.unavailable }
        let args = MBArguments(json: call.arguments)
        guard let raw = args.string("target"), let target = MBOpenTarget(rawValue: raw) else {
            return MBToolFailure.invalid("target must be one of the listed record kinds or screens.")
        }
        var payload: GLAIJSON = ["target": .string(target.rawValue)]
        var record: GLAIRecordRef?

        if let kind = target.recordKind, let id = args.string("id") {
            // Law 44: never hand over a push to something that isn't there.
            guard MBOpenRouting.exists(kind, id: id, in: store) else { return MBToolFailure.notFound(kind) }
            payload = payload.setting("id", to: .string(id))
            record = GLAIRecordRef(kind: kind.rawValue, id: id)
        } else if target.recordKind != nil, args.has("id") {
            return MBToolFailure.invalid("id must be the record's id, or left out to show the list.")
        }
        return .handoff(GLAIHandoff(kind: MBHandoffKind.open.rawValue, record: record, payload: payload))
    }
}

/// Which records `open` can really reach — asked before the handoff, so the model is refused
/// rather than the person being pushed at nothing.
@MainActor
enum MBOpenRouting {
    static func exists(_ kind: MBRecordKind, id: String, in store: ModelContext) -> Bool {
        switch kind {
        case .customer: return MBRecordLookup.record(kind, id: id, as: Customer.self, in: store) != nil
        case .estimate: return MBRecordLookup.record(kind, id: id, as: Estimate.self, in: store) != nil
        case .contract: return MBRecordLookup.record(kind, id: id, as: Contract.self, in: store) != nil
        case .invoice: return MBRecordLookup.record(kind, id: id, as: Invoice.self, in: store) != nil
        case .changeOrder: return MBRecordLookup.record(kind, id: id, as: ChangeOrder.self, in: store) != nil
        case .job: return MBRecordLookup.record(kind, id: id, as: ScheduledJob.self, in: store) != nil
        case .receipt: return MBRecordLookup.record(kind, id: id, as: Receipt.self, in: store) != nil
        case .priceItem: return MBRecordLookup.record(kind, id: id, as: PriceSheetItem.self, in: store) != nil
        case .employee: return MBRecordLookup.record(kind, id: id, as: Employee.self, in: store) != nil
        case .subcontractor: return MBRecordLookup.record(kind, id: id, as: Subcontractor.self, in: store) != nil
        case .project: return MBRecordLookup.record(kind, id: id, as: Project.self, in: store) != nil
        case .payment: return MBRecordLookup.record(kind, id: id, as: InvoicePayment.self, in: store) != nil
        case .timeEntry: return MBRecordLookup.record(kind, id: id, as: TimeEntry.self, in: store) != nil
        case .paycheck: return MBRecordLookup.record(kind, id: id, as: Paycheck.self, in: store) != nil
        case .subPayment: return MBRecordLookup.record(kind, id: id, as: SubPayment.self, in: store) != nil
        case .attachment: return MBRecordLookup.record(kind, id: id, as: JobAttachment.self, in: store) != nil
        case .document: return MBRecordLookup.record(kind, id: id, as: CustomerDocument.self, in: store) != nil
        case .business, .workSchedule, .appSettings, .goldLifeID, .deviceInfo: return true
        }
    }
}

// MARK: - send

/// What `send` can put in front of the person.
enum MBSendDocument: String, CaseIterable {
    case estimate, invoice
    case changeOrder = "change_order"
    case paymentReceipt = "payment_receipt"
    case contractorPackage = "contractor_package"
    case completionPackage = "completion_package"
    case reviewRequest = "review_request"
}

enum MBSendChannel: String, CaseIterable {
    case email, text, share
}

@MainActor
struct MBSendTool: GLAITool {
    let entry: GLAIManifest.Tool
    let env: MBToolEnvironment

    var name: String { entry.name }
    var summary: String { entry.summary }
    var parameters: GLAISchema { entry.parameters }
    var area: GLAIToolArea { entry.area }

    func run(_ call: GLAIToolCall, context: GLAIToolContext) async -> GLAIToolOutcome {
        guard context.isStillCurrent, let store = env.context() else { return MBToolFailure.unavailable }
        let args = MBArguments(json: call.arguments)
        guard let raw = args.string("document"), let document = MBSendDocument(rawValue: raw) else {
            return MBToolFailure.invalid("document must be one of the listed documents.")
        }
        guard let channelRaw = args.string("channel"), let channel = MBSendChannel(rawValue: channelRaw) else {
            return MBToolFailure.invalid("channel must be email, text or share.")
        }
        guard let id = args.string("id") else { return MBToolFailure.invalid("id is required.") }

        // The id names a different record per document (the manifest says which).
        let record: GLAIRecordRef
        switch document {
        case .estimate:
            guard MBRecordLookup.record(.estimate, id: id, as: Estimate.self, in: store) != nil else {
                return MBToolFailure.notFound(.estimate)
            }
            record = MBWrite.ref(.estimate, id)
        case .invoice:
            guard MBRecordLookup.record(.invoice, id: id, as: Invoice.self, in: store) != nil else {
                return MBToolFailure.notFound(.invoice)
            }
            record = MBWrite.ref(.invoice, id)
        case .changeOrder:
            guard MBRecordLookup.record(.changeOrder, id: id, as: ChangeOrder.self, in: store) != nil else {
                return MBToolFailure.notFound(.changeOrder)
            }
            record = MBWrite.ref(.changeOrder, id)
        case .paymentReceipt:
            guard MBRecordLookup.record(.payment, id: id, as: InvoicePayment.self, in: store) != nil else {
                return MBToolFailure.notFound(.payment)
            }
            record = MBWrite.ref(.payment, id)
        case .completionPackage:
            guard MBRecordLookup.record(.job, id: id, as: ScheduledJob.self, in: store) != nil else {
                return MBToolFailure.notFound(.job)
            }
            record = MBWrite.ref(.job, id)
        case .contractorPackage, .reviewRequest:
            guard MBRecordLookup.record(.customer, id: id, as: Customer.self, in: store) != nil else {
                return MBToolFailure.notFound(.customer)
            }
            record = MBWrite.ref(.customer, id)
        }

        var payload: GLAIJSON = [
            "document": .string(document.rawValue),
            "channel": .string(channel.rawValue),
            "id": .string(id),
        ]
        let recipients = args.strings("recipients")
        if !recipients.isEmpty { payload = payload.setting("recipients", to: .array(recipients.map { .string($0) })) }
        let parts = args.strings("package_parts")
        if !parts.isEmpty { payload = payload.setting("package_parts", to: .array(parts.map { .string($0) })) }
        return .handoff(GLAIHandoff(kind: MBHandoffKind.send.rawValue, record: record, payload: payload))
    }
}

// MARK: - pick_media

enum MBPickKind: String, CaseIterable {
    case photo, file, scan, contact
}

/// Where a picked photo, file, scan or contact goes.
enum MBPickTarget: String, CaseIterable {
    case newReceipt = "new_receipt"
    case receipt
    case jobPhotos = "job_photos"
    case jobDocuments = "job_documents"
    case invoicePhotos = "invoice_photos"
    case invoiceDocuments = "invoice_documents"
    case customerCOI = "customer_coi"
    case customerWCCOI = "customer_wc_coi"
    case packageDocuments = "package_documents"
    case subcontractorCOI = "subcontractor_coi"
    case subcontractorW9 = "subcontractor_w9"
    case wcExemption = "wc_exemption"
    case license
    case referenceCOI = "reference_coi"
    case projectAgreement = "project_agreement"
    case businessLogo = "business_logo"
    case businessLogoDark = "business_logo_dark"
    case customerPhoto = "customer_photo"
    case employeePhoto = "employee_photo"
    case subcontractorPhoto = "subcontractor_photo"
    case newCustomer = "new_customer"
    case newEmployee = "new_employee"
    case newSubcontractor = "new_subcontractor"

    /// Targets a phone contact can fill.
    var takesContact: Bool { self == .newCustomer || self == .newEmployee || self == .newSubcontractor }

    /// The business logos: picked as a photo or a file and cropped before they are saved.
    var isLogo: Bool { self == .businessLogo || self == .businessLogoDark }

    /// The record the target hangs on — nil for the business's own slots and the `new_` targets.
    var owner: MBRecordKind? {
        switch self {
        case .receipt: return .receipt
        case .jobPhotos, .jobDocuments: return .job
        case .invoicePhotos, .invoiceDocuments: return .invoice
        case .customerCOI, .customerWCCOI, .packageDocuments, .customerPhoto: return .customer
        case .subcontractorCOI, .subcontractorW9, .subcontractorPhoto: return .subcontractor
        case .employeePhoto: return .employee
        case .projectAgreement: return .project
        case .newReceipt, .wcExemption, .license, .referenceCOI, .businessLogo, .businessLogoDark,
             .newCustomer, .newEmployee, .newSubcontractor:
            return nil
        }
    }
}

@MainActor
struct MBPickMediaTool: GLAITool {
    let entry: GLAIManifest.Tool
    let env: MBToolEnvironment

    var name: String { entry.name }
    var summary: String { entry.summary }
    var parameters: GLAISchema { entry.parameters }
    var area: GLAIToolArea { entry.area }

    func run(_ call: GLAIToolCall, context: GLAIToolContext) async -> GLAIToolOutcome {
        guard context.isStillCurrent, let store = env.context() else { return MBToolFailure.unavailable }
        let args = MBArguments(json: call.arguments)
        guard let kindRaw = args.string("kind"), let kind = MBPickKind(rawValue: kindRaw) else {
            return MBToolFailure.invalid("kind must be photo, file, scan or contact.")
        }
        guard let targetRaw = args.string("target"), let target = MBPickTarget(rawValue: targetRaw) else {
            return MBToolFailure.invalid("target must be one of the listed places.")
        }
        if kind == .contact, !target.takesContact {
            return MBToolFailure.invalid("A phone contact only fits new_customer, new_employee or new_subcontractor.")
        }
        if kind != .contact, target.takesContact {
            return MBToolFailure.invalid("new_customer, new_employee and new_subcontractor only take a contact.")
        }
        var record: GLAIRecordRef?
        if let ownerKind = target.owner {
            guard let id = args.string("id"), MBOpenRouting.exists(ownerKind, id: id, in: store) else {
                return MBToolFailure.notFound(ownerKind)
            }
            record = GLAIRecordRef(kind: ownerKind.rawValue, id: id)
        }
        var payload: GLAIJSON = ["kind": .string(kind.rawValue), "target": .string(target.rawValue)]
        if let record { payload = payload.setting("id", to: .string(record.id)) }
        return .handoff(GLAIHandoff(kind: MBHandoffKind.pickMedia.rawValue, record: record, payload: payload))
    }
}

// MARK: - share_document

enum MBShareDocument: String, CaseIterable {
    case w9
    case form1099NEC = "form_1099_nec"
    case subcontractor1099Report = "subcontractor_1099_report"
    case wageReport = "wage_report"
    case yearEndReport = "year_end_report"
    case complianceDocs = "compliance_docs"
    case customerCOI = "customer_coi"
    case customerWCCOI = "customer_wc_coi"
    case subcontractorCOI = "subcontractor_coi"
    case subcontractorW9 = "subcontractor_w9"
    case wcExemption = "wc_exemption"
    case license
    case referenceCOI = "reference_coi"
    case packageDocument = "package_document"
    case jobDocument = "job_document"
    case invoiceDocument = "invoice_document"
    case estimatePDF = "estimate_pdf"
    case invoicePDF = "invoice_pdf"
    case changeOrderPDF = "change_order_pdf"

    /// The record the `id` names, when one is needed.
    var owner: MBRecordKind? {
        switch self {
        case .form1099NEC, .subcontractorW9, .subcontractorCOI: return .subcontractor
        case .customerCOI, .customerWCCOI: return .customer
        case .packageDocument: return .document
        case .jobDocument, .invoiceDocument: return .attachment
        case .estimatePDF: return .estimate
        case .invoicePDF: return .invoice
        case .changeOrderPDF: return .changeOrder
        case .w9, .subcontractor1099Report, .wageReport, .yearEndReport, .complianceDocs,
             .wcExemption, .license, .referenceCOI:
            return nil
        }
    }

    /// Reports that take a tax year.
    var takesYear: Bool {
        self == .subcontractor1099Report || self == .wageReport || self == .yearEndReport || self == .form1099NEC
    }
}

@MainActor
struct MBShareDocumentTool: GLAITool {
    let entry: GLAIManifest.Tool
    let env: MBToolEnvironment

    var name: String { entry.name }
    var summary: String { entry.summary }
    var parameters: GLAISchema { entry.parameters }
    var area: GLAIToolArea { entry.area }

    func run(_ call: GLAIToolCall, context: GLAIToolContext) async -> GLAIToolOutcome {
        guard context.isStillCurrent, let store = env.context() else { return MBToolFailure.unavailable }
        let args = MBArguments(json: call.arguments)
        guard let raw = args.string("document"), let document = MBShareDocument(rawValue: raw) else {
            return MBToolFailure.invalid("document must be one of the listed documents.")
        }
        var record: GLAIRecordRef?
        if let ownerKind = document.owner {
            guard let id = args.string("id"), MBOpenRouting.exists(ownerKind, id: id, in: store) else {
                return MBToolFailure.notFound(ownerKind)
            }
            record = GLAIRecordRef(kind: ownerKind.rawValue, id: id)
        }
        var payload: GLAIJSON = ["document": .string(document.rawValue)]
        if let record { payload = payload.setting("id", to: .string(record.id)) }
        if document.takesYear {
            let year = args.int("year") ?? env.calendar.component(.year, from: env.now())
            payload = payload.setting("year", to: .number(Double(year)))
        }
        return .handoff(GLAIHandoff(kind: MBHandoffKind.shareDocument.rawValue, record: record, payload: payload))
    }
}

// MARK: - save_to_contacts

@MainActor
struct MBSaveToContactsTool: GLAITool {
    let entry: GLAIManifest.Tool
    let env: MBToolEnvironment

    var name: String { entry.name }
    var summary: String { entry.summary }
    var parameters: GLAISchema { entry.parameters }
    var area: GLAIToolArea { entry.area }

    func run(_ call: GLAIToolCall, context: GLAIToolContext) async -> GLAIToolOutcome {
        guard context.isStillCurrent, let store = env.context() else { return MBToolFailure.unavailable }
        let args = MBArguments(json: call.arguments)
        guard let kindRaw = args.string("kind"), let kind = MBRecordKind(rawValue: kindRaw),
              [.customer, .employee, .subcontractor].contains(kind) else {
            return MBToolFailure.invalid("kind must be customer, employee or subcontractor.")
        }
        guard let id = args.string("id"), MBOpenRouting.exists(kind, id: id, in: store) else {
            return MBToolFailure.notFound(kind)
        }
        return .handoff(GLAIHandoff(
            kind: MBHandoffKind.saveToContacts.rawValue,
            record: GLAIRecordRef(kind: kind.rawValue, id: id),
            payload: ["kind": .string(kind.rawValue), "id": .string(id)]))
    }
}

// MARK: - contact_developer

@MainActor
struct MBContactDeveloperTool: GLAITool {
    let entry: GLAIManifest.Tool
    let env: MBToolEnvironment

    var name: String { entry.name }
    var summary: String { entry.summary }
    var parameters: GLAISchema { entry.parameters }
    var area: GLAIToolArea { entry.area }

    func run(_ call: GLAIToolCall, context: GLAIToolContext) async -> GLAIToolOutcome {
        guard context.isStillCurrent else { return MBToolFailure.unavailable }
        let args = MBArguments(json: call.arguments)
        let message = MBValue.clip(args.json["message"]?.stringValue ?? "", limit: 2000)
        return .handoff(GLAIHandoff(kind: MBHandoffKind.contactDeveloper.rawValue,
                                    payload: ["message": .string(message)]))
    }
}
