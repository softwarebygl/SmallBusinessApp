//
//  MBAssistantDestination.swift
//  GLSmallBusiness — AI
//
//  Where the assistant can send someone: `open`'s targets and the records an activity row links
//  to. One small router, so a tap on a card row and an `open` call land in exactly the same place.
//
//  Law 44 — no dead pushes: a destination is only made for something that is really there, and the
//  view resolves the record again at draw time (a record deleted while the person was reading the
//  conversation shows the app's own "this is gone" screen instead of trapping on a dead model).
//
//  Records without a screen of their own open the screen that HOLDS them: a payment opens its
//  invoice, hours and paychecks open the employee, a subcontractor entry opens the subcontractor,
//  a photo or document opens its job or invoice, a package document opens its customer.
//

import SwiftUI
import SwiftData
import GoldLifeAI
import GoldLifeUI
import GoldLifeMoney

/// One place the assistant can send someone. Hashable so it rides a `NavigationPath`.
enum MBAssistantDestination: Hashable, Identifiable {
    /// A record, by kind and `syncID`.
    case record(kind: String, id: String)
    /// One of the app's own screens.
    case screen(String)

    var id: String {
        switch self {
        case .record(let kind, let id): return "\(kind):\(id)"
        case .screen(let name): return "screen:\(name)"
        }
    }

    // MARK: Building

    /// The destination an `open` handoff names, or nil when it names nothing this app can show.
    @MainActor
    init?(handoff: GLAIHandoff, in store: ModelContext) {
        let args = MBArguments(json: handoff.payload)
        guard let raw = args.string("target"), let target = MBOpenTarget(rawValue: raw) else { return nil }
        if let kind = target.recordKind, let id = args.string("id") {
            guard let resolved = Self.resolve(kind: kind, id: id, in: store) else { return nil }
            self = resolved
            return
        }
        self = .screen(target.rawValue)
    }

    /// The destination an activity row's record opens.
    @MainActor
    init?(record: GLAIRecordRef, in store: ModelContext) {
        guard let kind = MBRecordKind(rawValue: record.kind),
              let resolved = Self.resolve(kind: kind, id: record.id, in: store) else { return nil }
        self = resolved
    }

    /// Records with no screen of their own resolve to the screen that holds them.
    @MainActor
    private static func resolve(kind: MBRecordKind, id: String, in store: ModelContext) -> MBAssistantDestination? {
        switch kind {
        case .customer, .estimate, .contract, .invoice, .changeOrder, .job, .receipt, .employee,
             .subcontractor, .project:
            guard MBOpenRouting.exists(kind, id: id, in: store) else { return nil }
            return .record(kind: kind.rawValue, id: id)
        case .priceItem:
            guard MBOpenRouting.exists(kind, id: id, in: store) else { return nil }
            return .screen(MBOpenTarget.priceSheet.rawValue)
        case .payment:
            guard let payment = MBRecordLookup.record(.payment, id: id, as: InvoicePayment.self, in: store),
                  let invoice = payment.invoice, let invoiceID = invoice.syncID else { return nil }
            return .record(kind: MBRecordKind.invoice.rawValue, id: invoiceID.uuidString)
        case .timeEntry:
            guard let entry = MBRecordLookup.record(.timeEntry, id: id, as: TimeEntry.self, in: store),
                  let owner = entry.employee, let ownerID = owner.syncID else { return nil }
            return .record(kind: MBRecordKind.employee.rawValue, id: ownerID.uuidString)
        case .paycheck:
            guard let check = MBRecordLookup.record(.paycheck, id: id, as: Paycheck.self, in: store),
                  let owner = check.employee, let ownerID = owner.syncID else { return nil }
            return .record(kind: MBRecordKind.employee.rawValue, id: ownerID.uuidString)
        case .subPayment:
            guard let entry = MBRecordLookup.record(.subPayment, id: id, as: SubPayment.self, in: store),
                  let owner = entry.subcontractor, let ownerID = owner.syncID else { return nil }
            return .record(kind: MBRecordKind.subcontractor.rawValue, id: ownerID.uuidString)
        case .attachment:
            guard let attachment = MBRecordLookup.record(.attachment, id: id, as: JobAttachment.self, in: store)
            else { return nil }
            if let job = attachment.job, let jobID = job.syncID {
                return .record(kind: MBRecordKind.job.rawValue, id: jobID.uuidString)
            }
            if let invoice = attachment.invoice, let invoiceID = invoice.syncID {
                return .record(kind: MBRecordKind.invoice.rawValue, id: invoiceID.uuidString)
            }
            return nil
        case .document:
            guard let document = MBRecordLookup.record(.document, id: id, as: CustomerDocument.self, in: store),
                  let customer = document.customer, let customerID = customer.syncID else { return nil }
            return .record(kind: MBRecordKind.customer.rawValue, id: customerID.uuidString)
        case .business:
            return .screen(MBOpenTarget.business.rawValue)
        case .workSchedule:
            return .screen(MBOpenTarget.workSchedule.rawValue)
        case .appSettings:
            return .screen(MBOpenTarget.settings.rawValue)
        case .goldLifeID:
            return .screen(MBOpenTarget.goldLifeID.rawValue)
        case .deviceInfo:
            return .screen(MBOpenTarget.deviceInfo.rawValue)
        }
    }

    // MARK: Presentation

    /// The two legal pages are the app's own sheets (they carry their own navigation), so they are
    /// presented rather than pushed. Everything else pushes onto the assistant's stack.
    var isSheet: Bool {
        if case .screen(let name) = self {
            return name == MBOpenTarget.privacyPolicy.rawValue || name == MBOpenTarget.termsOfUse.rawValue
        }
        return false
    }

    var symbol: String {
        switch self {
        case .record(let kind, _):
            guard let recordKind = MBRecordKind(rawValue: kind) else { return "doc" }
            switch recordKind {
            case .customer: return MBWriteSymbol.customer
            case .estimate: return MBWriteSymbol.estimate
            case .contract: return MBWriteSymbol.contract
            case .invoice, .payment: return MBWriteSymbol.invoice
            case .changeOrder: return MBWriteSymbol.changeOrder
            case .job: return MBWriteSymbol.job
            case .receipt: return MBWriteSymbol.receipt
            case .employee, .timeEntry, .paycheck: return MBWriteSymbol.employee
            case .subcontractor, .subPayment: return MBWriteSymbol.subcontractor
            case .project: return MBWriteSymbol.project
            case .priceItem: return MBWriteSymbol.priceItem
            case .attachment, .document: return MBWriteSymbol.document
            case .business, .workSchedule, .appSettings, .goldLifeID, .deviceInfo: return MBWriteSymbol.settings
            }
        case .screen:
            return "arrow.up.forward.app"
        }
    }

    /// What the "Opened" row says it opened.
    @MainActor
    var label: String {
        switch self {
        case .record(let kind, _):
            guard let recordKind = MBRecordKind(rawValue: kind) else { return mbLoc("Record") }
            switch recordKind {
            case .customer: return mbLoc("Customer")
            case .estimate: return mbLoc("Estimate")
            case .contract: return mbLoc("Contract")
            case .invoice: return mbLoc("Invoice")
            case .changeOrder: return mbLoc("Change Order")
            case .job: return mbLoc("Job")
            case .receipt: return mbLoc("Receipt")
            case .employee: return mbLoc("Employee")
            case .subcontractor: return mbLoc("Subcontractor")
            case .project: return mbLoc("Project")
            case .priceItem: return mbLoc("Price Sheet")
            case .payment: return mbLoc("Invoice")
            case .timeEntry, .paycheck: return mbLoc("Employee")
            case .subPayment: return mbLoc("Subcontractor")
            case .attachment, .document: return mbLoc("Document")
            case .business: return mbLoc("My Business Details")
            case .workSchedule: return mbLoc("Work Hours")
            case .appSettings: return mbLoc("Settings")
            case .goldLifeID: return mbLoc("Gold Life ID")
            case .deviceInfo: return mbLoc("Device Info")
            }
        case .screen(let name):
            return MBAssistantDestination.screenLabel(name)
        }
    }

    @MainActor
    static func screenLabel(_ name: String) -> String {
        guard let target = MBOpenTarget(rawValue: name) else { return mbLoc("Screen") }
        switch target {
        // A record kind with no id is its LIST ("Show my customers"), labeled as the list's own
        // title (the Contacts segment or the Menu › Documents row the person knows).
        case .customer: return mbLoc("Customers")
        case .estimate: return mbLoc("All Estimates")
        case .contract, .contracts: return mbLoc("Contracts")
        case .invoice, .payment: return mbLoc("All Invoices")
        case .changeOrder: return mbLoc("All Change Orders")
        case .job: return mbLoc("All Jobs")
        case .receipt: return mbLoc("All Expenses")
        case .priceItem, .priceSheet: return mbLoc("Price Sheet")
        case .employee, .timeEntry, .paycheck: return mbLoc("Employees")
        case .subcontractor, .subPayment: return mbLoc("Subcontractors")
        case .project: return mbLoc("All Projects")
        case .attachment, .document: return mbLoc("All Documents")
        case .business: return mbLoc("My Business Details")
        case .workSchedule: return mbLoc("Work Hours")
        case .settings: return mbLoc("Settings")
        case .documentMessages: return mbLoc("Document Messages")
        case .stats: return mbLoc("Statistics")
        case .complianceDocs: return mbLoc("Compliance Documents")
        case .stripeSetup: return mbLoc("Connect Stripe")
        case .zelleSetup: return mbLoc("Connect Zelle")
        case .howTo: return mbLoc("How To")
        case .whatsNew: return mbLoc("What’s New")
        case .about: return mbLoc("About")
        case .calendar: return mbLoc("Calendar")
        case .privacyPolicy: return mbLoc("Privacy Policy")
        case .termsOfUse: return mbLoc("Terms of Use")
        case .subscription: return mbLoc("Subscription")
        case .goldLifeID: return mbLoc("Gold Life ID")
        case .deviceInfo: return mbLoc("Device Info")
        case .money: return mbLoc("Money")
        case .subscriptions: return mbLoc("Subscriptions")
        case .connectedBanks: return mbLoc("Connected Banks & Money")
        }
    }
}

// MARK: - The view

/// Draws one destination, re-resolving the record from the store so a record deleted since shows
/// the app's own "this is gone" screen rather than trapping on a dead model.
struct MBAssistantDestinationView: View {
    let destination: MBAssistantDestination
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        switch destination {
        case .record(let kind, let id):
            record(kind: kind, id: id)
        case .screen(let name):
            screen(name)
        }
    }

    @ViewBuilder
    private func record(kind: String, id: String) -> some View {
        let store = modelContext
        switch MBRecordKind(rawValue: kind) {
        case .customer:
            if let found = MBRecordLookup.record(.customer, id: id, as: Customer.self, in: store) {
                CustomerDetailScreen(customer: found, showsAssistantButton: false)
            } else { gone(mbLoc("Customer"), "this customer") }
        case .estimate:
            if let found = MBRecordLookup.record(.estimate, id: id, as: Estimate.self, in: store) {
                EstimateDetailScreen(estimate: found, showsAssistantButton: false)
            } else { gone(mbLoc("Estimate"), "this estimate") }
        case .contract:
            if let found = MBRecordLookup.record(.contract, id: id, as: Contract.self, in: store) {
                ContractDetailScreen(contract: found, showsAssistantButton: false)
            } else { gone(mbLoc("Contract"), "this contract") }
        case .invoice:
            if let found = MBRecordLookup.record(.invoice, id: id, as: Invoice.self, in: store) {
                InvoiceDetailScreen(invoice: found, showsAssistantButton: false)
            } else { gone(mbLoc("Invoice"), "this invoice") }
        case .changeOrder:
            if let found = MBRecordLookup.record(.changeOrder, id: id, as: ChangeOrder.self, in: store) {
                ChangeOrderDetailSheet(changeOrder: found, showsAssistantButton: false)
            } else { gone(mbLoc("Change Order"), "the change order") }
        case .job:
            if let found = MBRecordLookup.record(.job, id: id, as: ScheduledJob.self, in: store) {
                JobDetailScreen(job: found, showsAssistantButton: false)
            } else { gone(mbLoc("Job"), "this job") }
        case .receipt:
            if let found = MBRecordLookup.record(.receipt, id: id, as: Receipt.self, in: store) {
                ReceiptDetailScreen(receipt: found, showsAssistantButton: false)
            } else { gone(mbLoc("Receipt"), "this receipt") }
        case .employee:
            if let found = MBRecordLookup.record(.employee, id: id, as: Employee.self, in: store) {
                EmployeeDetailScreen(employee: found, showsAssistantButton: false)
            } else { gone(mbLoc("Employee"), "this employee") }
        case .subcontractor:
            if let found = MBRecordLookup.record(.subcontractor, id: id, as: Subcontractor.self, in: store) {
                SubcontractorDetailScreen(subcontractor: found, showsAssistantButton: false)
            } else { gone(mbLoc("Subcontractor"), "this subcontractor") }
        case .project:
            if let found = MBRecordLookup.record(.project, id: id, as: Project.self, in: store) {
                ProjectDetailScreen(project: found, showsAssistantButton: false)
            } else { gone(mbLoc("Project"), "this project") }
        default:
            gone(mbLoc("Record"), "this record")
        }
    }

    /// Every target has a real screen (the switch is exhaustive, so a new target can't fall
    /// through to "gone"). A record kind with no id opens that kind's LIST — the same pushable
    /// list the Menu › Documents rows push (never a tab root, which would nest a second
    /// NavigationStack inside the assistant's). Records without a list of their own open the list
    /// that holds them: payments → invoices, hours and paychecks → employees, sub payments →
    /// subcontractors, photos and documents → All Documents.
    @ViewBuilder
    private func screen(_ name: String) -> some View {
        if let target = MBOpenTarget(rawValue: name) {
            switch target {
            case .customer: CustomersScreen(isTabRoot: false)
            case .estimate: AllEstimatesScreen()
            case .contract, .contracts: AllContractsScreen()
            case .invoice, .payment: AllInvoicesScreen()
            case .changeOrder: AllChangeOrdersScreen()
            case .job: AllJobsScreen()
            case .receipt: AllReceiptsScreen()
            case .priceItem, .priceSheet: PriceSheetScreen()
            case .employee, .timeEntry, .paycheck: EmployeesScreen()
            case .subcontractor, .subPayment: SubcontractorsScreen()
            case .project: AllProjectsScreen()
            case .attachment, .document: MBAllDocumentsDestination()
            case .business: MyCompanyDetailScreen()
            case .workSchedule: WorkScheduleScreen()
            case .settings: SettingsScreen()
            case .documentMessages: DocumentSettingsScreen()
            case .stats: StatsScreen()
            case .complianceDocs: MBComplianceDocsDestination()
            case .stripeSetup: StripeConnectScreen()
            case .zelleSetup: ZelleConnectScreen()
            case .howTo: HowToScreen()
            case .whatsNew: WhatsNewScreen()
            case .about: AboutScreen()
            case .calendar: CalendarScreen(showsMenuButton: false)
            case .subscription: SubscriptionScreen()
            case .goldLifeID:
                GoldLifeIDScreen(
                    isSampleMode: MBIdentity.shared.isSampleData,
                    isMember: SubscriptionManager.shared.isSubscribed || SubscriptionManager.shared.serverEntitled,
                    appRows: { MBSignatureRow() }
                )
            case .deviceInfo: SettingsScreen()
            case .money:
                MoneyScreen(initialSegment: .transactions, ownsStack: false)
                    .mbMoneyHostEnvironment()
            case .subscriptions:
                MoneyScreen(initialSegment: .subscriptions, ownsStack: false)
                    .mbMoneyHostEnvironment()
            case .connectedBanks:
                ConnectedBanksAndMoneyScreen(isSampleMode: DemoMode.isActive || UserDemoMode.shared.isDemoActive)
                    .mbMoneyHostEnvironment()
            // Presented as sheets (`isSheet`), never pushed; the host draws them itself.
            case .privacyPolicy, .termsOfUse: gone(mbLoc("Screen"), "this screen")
            }
        } else {
            gone(mbLoc("Screen"), "this screen")
        }
    }

    private func gone(_ title: String, _ noun: String.LocalizationValue) -> some View {
        DeletedRecordView(title: title, noun: noun) { dismiss() }
    }
}

/// The compliance documents manager needs the business profile singleton, and on a brand-new (or
/// lapsed) store there isn't one yet. `BusinessProfileHost` is the ONE owner of that bootstrap —
/// the same door the Menu uses — so this pushes through it instead of spinning on an empty query
/// forever (law 44), and wears a title while it waits (law 57).
struct MBComplianceDocsDestination: View {
    var body: some View {
        BusinessProfileHost(placeholderTitle: mbLoc("Compliance Documents")) { profile in
            ComplianceDocsManagerSheet(profile: profile)
        }
    }
}

/// All Documents needs the business profile singleton (its compliance rows), created on first
/// use by the same `BusinessProfileHost` door the Menu uses.
struct MBAllDocumentsDestination: View {
    var body: some View {
        BusinessProfileHost(placeholderTitle: mbLoc("All Documents")) { profile in
            AllDocumentsScreen(profile: profile)
        }
    }
}
