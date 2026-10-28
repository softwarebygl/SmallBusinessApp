//
//  MBWriteSupport.swift
//  GLSmallBusiness — AI
//
//  What every write tool shares (contract §5, AI/README.md):
//    • the person's half of what happened — `MBWriteStrings`, the activity-row titles, Undo row
//      names and drop reasons, all resolved at draw time (laws 1–2);
//    • the model's half of a refusal — `MBToolFailure.domain`, which turns a `DomainError` from a
//      service into `{ ok: false, reason: <its stable code> }` plus the way forward;
//    • reading arguments the model sent (`MBArguments` numbers / money / flags / arrays): an AMOUNT
//      (a payment, a total, a bonus, an amount due, an agreed price, a deposit in dollars) must be
//      whole cents — one with a fraction of a cent is refused with `invalid_arguments` before the
//      tool runs (`MBWholeCentsGate`, `MBArguments.centFractionRefusal`), as the forms refuse a third
//      decimal; a price, rate or percentage is kept as sent, exactly as the forms keep what was
//      typed (law 60);
//    • Undo bookkeeping — `MBWriteLedger` (what this conversation wrote, and what it expects the
//      record to look like now) and `MBFingerprint` (a record and its rows' `updatedAt` stamps,
//      so "changed since" means the SAME thing for an edit made here and one made on the form).
//
//  No write lives here. Every tool calls a service in `Services/Domain/` — the same code the
//  buttons call (law 58) — and this file only shapes what goes in and what comes back.
//

import Foundation
import OSLog
import SwiftData
import GoldLifeAI

// MARK: - Person-facing text

/// Every sentence a write tool shows a person. English here is also the catalog key; the Spanish
/// lives in `GLSmallBusiness/Localizable.xcstrings` (law 2).
@MainActor
enum MBWriteStrings {
    static func res(_ value: String.LocalizationValue) -> LocalizedStringResource { LocalizedStringResource(value) }

    // Activity rows — what changed.
    static var customerAdded: LocalizedStringResource { res("Added customer") }
    static var customerUpdated: LocalizedStringResource { res("Updated customer") }
    static var estimateCreated: LocalizedStringResource { res("Created estimate") }
    static var estimateUpdated: LocalizedStringResource { res("Updated estimate") }
    static var contractCreated: LocalizedStringResource { res("Created contract") }
    static var contractUpdated: LocalizedStringResource { res("Updated contract") }
    static var invoiceCreated: LocalizedStringResource { res("Created invoice") }
    static var invoiceUpdated: LocalizedStringResource { res("Updated invoice") }
    static var jobBooked: LocalizedStringResource { res("Booked job") }
    static var jobUpdated: LocalizedStringResource { res("Updated job") }
    static var estimateStatusChanged: LocalizedStringResource { res("Changed estimate status") }
    static var contractStatusChanged: LocalizedStringResource { res("Changed contract status") }
    static var invoiceStatusChanged: LocalizedStringResource { res("Changed invoice status") }
    static var changeOrderStatusChanged: LocalizedStringResource { res("Changed change order status") }
    static var jobStatusChanged: LocalizedStringResource { res("Changed job status") }
    static var paymentRecorded: LocalizedStringResource { res("Recorded payment") }
    static var jobFilesAdded: LocalizedStringResource { res("Added job files to invoice") }
    static var changeOrderCreated: LocalizedStringResource { res("Created change order") }
    static var changeOrderUpdated: LocalizedStringResource { res("Updated change order") }
    static var changeOrderApplied: LocalizedStringResource { res("Added change order to invoice") }
    static var receiptAdded: LocalizedStringResource { res("Added receipt") }
    static var receiptUpdated: LocalizedStringResource { res("Updated receipt") }
    static var priceItemAdded: LocalizedStringResource { res("Added price sheet item") }
    static var priceItemUpdated: LocalizedStringResource { res("Updated price sheet item") }
    static var employeeAdded: LocalizedStringResource { res("Added employee") }
    static var employeeUpdated: LocalizedStringResource { res("Updated employee") }
    static var hoursLogged: LocalizedStringResource { res("Logged hours") }
    static var hoursUpdated: LocalizedStringResource { res("Updated hours") }
    static var bonusLogged: LocalizedStringResource { res("Logged bonus") }
    static var paycheckRecorded: LocalizedStringResource { res("Recorded paycheck") }
    static var paycheckUpdated: LocalizedStringResource { res("Updated paycheck") }
    static var subcontractorAdded: LocalizedStringResource { res("Added subcontractor") }
    static var subcontractorUpdated: LocalizedStringResource { res("Updated subcontractor") }
    static var subWorkLogged: LocalizedStringResource { res("Logged subcontractor work") }
    static var subWorkUpdated: LocalizedStringResource { res("Updated subcontractor entry") }
    static var subPaid: LocalizedStringResource { res("Paid subcontractor") }
    static var businessUpdated: LocalizedStringResource { res("Updated business details") }
    static var workScheduleUpdated: LocalizedStringResource { res("Updated work hours") }
    static var appSettingsUpdated: LocalizedStringResource { res("Updated app settings") }
    static var projectCreated: LocalizedStringResource { res("Created project") }
    static var projectUpdated: LocalizedStringResource { res("Updated project") }
    static var documentUpdated: LocalizedStringResource { res("Updated document") }
    static var documentRemoved: LocalizedStringResource { res("Removed document") }
    static var transactionClassified: LocalizedStringResource { res("Classified transaction") }
    static var merchantRuleSaved: LocalizedStringResource { res("Saved merchant rule") }
    static var merchantRuleRemoved: LocalizedStringResource { res("Removed merchant rule") }
    static var subscriptionUpdated: LocalizedStringResource { res("Updated subscription") }

    // Activity rows — hand-offs.
    static var openedScreen: LocalizedStringResource { res("Opened") }
    static var openedContactCard: LocalizedStringResource { res("Opened a new contact card") }
    static var sentEstimate: LocalizedStringResource { res("Sent estimate") }
    static var sentInvoice: LocalizedStringResource { res("Sent invoice") }
    static var sentChangeOrder: LocalizedStringResource { res("Sent change order") }
    static var sentReceipt: LocalizedStringResource { res("Sent payment receipt") }
    static var sentPackage: LocalizedStringResource { res("Sent package") }
    static var sentReviewRequest: LocalizedStringResource { res("Sent review request") }
    static var sentToDeveloper: LocalizedStringResource { res("Sent a message to the developer") }
    static var sharedDocument: LocalizedStringResource { res("Shared document") }
    static var photoAdded: LocalizedStringResource { res("Added photo") }
    static var fileAdded: LocalizedStringResource { res("Added document") }
    static var scanAdded: LocalizedStringResource { res("Added scan") }
    static var logoAdded: LocalizedStringResource { res("Updated logo") }

    // Activity rows — Undo put it back.
    static var customerRestored: LocalizedStringResource { res("Restored customer") }
    static var estimateRestored: LocalizedStringResource { res("Restored estimate") }
    static var contractRestored: LocalizedStringResource { res("Restored contract") }
    static var invoiceRestored: LocalizedStringResource { res("Restored invoice") }
    static var jobRestored: LocalizedStringResource { res("Restored job") }
    static var changeOrderRestored: LocalizedStringResource { res("Restored change order") }
    static var receiptRestored: LocalizedStringResource { res("Restored receipt") }
    static var priceItemRestored: LocalizedStringResource { res("Restored price sheet item") }
    static var employeeRestored: LocalizedStringResource { res("Restored employee") }
    static var hoursRestored: LocalizedStringResource { res("Restored hours") }
    static var subcontractorRestored: LocalizedStringResource { res("Restored subcontractor") }
    static var subWorkRestored: LocalizedStringResource { res("Restored subcontractor entry") }
    static var projectRestored: LocalizedStringResource { res("Restored project") }
    static var businessRestored: LocalizedStringResource { res("Restored business details") }
    static var workScheduleRestored: LocalizedStringResource { res("Restored work hours") }
    static var appSettingsRestored: LocalizedStringResource { res("Restored app settings") }
    static var transactionRestored: LocalizedStringResource { res("Restored transaction") }
    static var merchantRuleRestored: LocalizedStringResource { res("Restored merchant rule") }
    static var subscriptionRestored: LocalizedStringResource { res("Restored subscription") }

    // Activity rows — deleted, one per kind (the card names the kind, the detail names the record).
    static func deleted(_ kind: DeletionService.Kind, attachment: JobAttachment? = nil) -> LocalizedStringResource {
        switch kind {
        case .customer: return res("Deleted customer")
        case .estimate: return res("Deleted estimate")
        case .contract: return res("Deleted contract")
        case .invoice: return res("Deleted invoice")
        case .changeOrder: return res("Deleted change order")
        case .job: return res("Deleted job")
        case .receipt: return res("Deleted receipt")
        case .priceItem: return res("Deleted price sheet item")
        case .employee: return res("Deleted employee")
        case .subcontractor: return res("Deleted subcontractor")
        case .project: return res("Deleted project")
        case .timeEntry: return res("Deleted hours")
        case .paycheck: return res("Deleted paycheck")
        case .subPayment: return res("Deleted subcontractor entry")
        case .attachment: return attachment?.kind == .photo ? res("Deleted photo") : res("Deleted document")
        case .document: return res("Deleted document")
        case .payment: return res("Deleted document")   // unreachable: payments are never deleted
        }
    }

    // Undo rows — what the Undo list names.
    static func undoTitle(customer name: String) -> LocalizedStringResource { res("Customer \(name)") }
    static func undoTitle(estimate number: String) -> LocalizedStringResource { res("Estimate \(number)") }
    static func undoTitle(contract number: String) -> LocalizedStringResource { res("Contract \(number)") }
    static func undoTitle(invoice number: String) -> LocalizedStringResource { res("Invoice \(number)") }
    static func undoTitle(job title: String) -> LocalizedStringResource { res("Job \(title)") }
    static func undoTitle(changeOrder number: String) -> LocalizedStringResource { res("Change order \(number)") }
    static func undoTitle(receipt vendor: String) -> LocalizedStringResource { res("Receipt \(vendor)") }
    static func undoTitle(priceItem name: String) -> LocalizedStringResource { res("Price sheet item \(name)") }
    static func undoTitle(employee name: String) -> LocalizedStringResource { res("Employee \(name)") }
    static func undoTitle(subcontractor name: String) -> LocalizedStringResource { res("Subcontractor \(name)") }
    static func undoTitle(project name: String) -> LocalizedStringResource { res("Project \(name)") }
    static func undoTitle(hours label: String) -> LocalizedStringResource { res("Hours \(label)") }
    static func undoTitle(entry label: String) -> LocalizedStringResource { res("Subcontractor entry \(label)") }
    static var undoTitleBusiness: LocalizedStringResource { res("Business details") }
    static var undoTitleWorkSchedule: LocalizedStringResource { res("Work hours") }
    static var undoTitleAppSettings: LocalizedStringResource { res("App settings") }
    static func undoTitle(transaction merchant: String) -> LocalizedStringResource { res("Transaction \(merchant)") }
    static func undoTitle(merchantRule merchant: String) -> LocalizedStringResource { res("Rule \(merchant)") }
    static func undoTitle(subscription merchant: String) -> LocalizedStringResource { res("Subscription \(merchant)") }

    // Undo — why an entry was dropped or couldn't run.
    static var undoDroppedPaymentRecorded: LocalizedStringResource {
        res("A payment was recorded on it, so it stays as it is.")
    }
    static var undoDroppedPaid: LocalizedStringResource { res("It’s paid now, so it stays as it is.") }
    static var undoKeptHasRecords: LocalizedStringResource { res("It has other records now, so it was kept.") }
    static var undoWouldPayInvoice: LocalizedStringResource {
        res("Undoing this would mark the invoice paid, so it was left as is.")
    }

    // Confirmations.
    static func confirmDelete(_ records: String) -> LocalizedStringResource { res("Delete \(records)") }
    static func confirmDelete(_ records: String, _ effects: String) -> LocalizedStringResource {
        res("Delete \(records). \(effects)")
    }
    static func confirmPayment(amount: String, invoice: String) -> LocalizedStringResource {
        res("Record a payment of \(amount) on \(invoice)")
    }
    static func confirmWouldLock(_ invoice: String) -> LocalizedStringResource {
        res("This marks \(invoice) paid, so it can’t be changed afterward.")
    }
    static func confirmPaidInvoiceEdit(_ invoice: String) -> LocalizedStringResource {
        res("Change paid invoice \(invoice)?")
    }
    static func confirmPayPerson(amount: String, person: String) -> LocalizedStringResource {
        res("Pay \(person) \(amount)")
    }
    static func confirmEditPaycheck(person: String, amount: String) -> LocalizedStringResource {
        res("Change \(person)’s paycheck to \(amount)")
    }
    static func confirmBusinessChanges(_ changes: String) -> LocalizedStringResource {
        res("Change your business details?\n\(changes)")
    }
    static func confirmRemoveDocument(_ document: String) -> LocalizedStringResource {
        res("Remove \(document)")
    }
    static var confirmContinue: LocalizedStringResource { res("Continue") }

    // Refusals a hand-off gives, in the person's own language.
    static var handoffNotAvailable: LocalizedStringResource { res("The app couldn’t open that just now.") }
    static var mailUnavailable: LocalizedStringResource { res("There’s no email account set up on this iPhone.") }
    static var messagesUnavailable: LocalizedStringResource { res("This iPhone can’t send text messages.") }
    static var noRecipient: LocalizedStringResource { res("There’s no email or phone number on file for them.") }
    static var profileIncomplete: LocalizedStringResource {
        res("Add your business name and a phone or email first.")
    }
    static var documentFailed: LocalizedStringResource { res("That document couldn’t be made.") }
    static var faceIDRefused: LocalizedStringResource { res("Face ID didn’t pass, so that stayed closed.") }
    static var documentOnlyOnScreen: LocalizedStringResource { res("That one is only done on its own screen.") }
    static var documentNotOnFile: LocalizedStringResource { res("There’s nothing on file for that yet.") }
    static var packageNeedsCOI: LocalizedStringResource {
        res("Add this customer’s certificate of insurance first.")
    }
    static var w9Incomplete: LocalizedStringResource { res("Your W-9 details aren’t filled in yet.") }
    static var signatureNotSaved: LocalizedStringResource { res("You haven’t saved a signature yet.") }
    static var scannerUnavailable: LocalizedStringResource { res("This device can’t scan.") }
    static var logoNeedsPhoto: LocalizedStringResource { res("Pick the logo as a photo or a file so you can crop it.") }
    static var projectNeedsJob: LocalizedStringResource { res("A project needs a job to start it.") }
    static var confirmDeleteAction: LocalizedStringResource { res("Delete") }
    static var confirmRecordPaymentAction: LocalizedStringResource { res("Record payment") }

    /// "Invoice INV-0003" / "Factura INV-0003" — a record named inside a confirmation sentence,
    /// resolved in the app's chosen language when the alert is built.
    static func phrase(_ kind: DeletionService.Kind, _ label: String, attachment: JobAttachment? = nil) -> String {
        switch kind {
        case .customer: return mbLoc("Customer \(label)")
        case .estimate: return mbLoc("Estimate \(label)")
        case .contract: return mbLoc("Contract \(label)")
        case .invoice: return mbLoc("Invoice \(label)")
        case .changeOrder: return mbLoc("Change order \(label)")
        case .job: return mbLoc("Job \(label)")
        case .receipt: return mbLoc("Receipt \(label)")
        case .priceItem: return mbLoc("Price sheet item \(label)")
        case .employee: return mbLoc("Employee \(label)")
        case .subcontractor: return mbLoc("Subcontractor \(label)")
        case .project: return mbLoc("Project \(label)")
        case .timeEntry: return mbLoc("Hours \(label)")
        case .paycheck: return mbLoc("Paycheck \(label)")
        case .subPayment: return mbLoc("Subcontractor entry \(label)")
        case .attachment:
            return attachment?.kind == .photo ? mbLoc("Photo \(label)") : mbLoc("Document \(label)")
        case .document, .payment: return mbLoc("Document \(label)")
        }
    }
}

/// The SF Symbols the activity card reuses — the app's own, never a new one.
@MainActor
enum MBWriteSymbol {
    static let customer = "person.crop.circle"
    static let estimate = "doc.text"
    static let contract = "doc.text.fill"
    static let invoice = "banknote"
    static let changeOrder = "plus.rectangle.on.rectangle"
    static let job = "hammer"
    static let receipt = "doc.viewfinder"
    static let priceItem = "list.bullet.rectangle"
    static let employee = "person.text.rectangle"
    static let subcontractor = "person.2"
    static let project = "folder"
    static let payment = "dollarsign.circle"
    static let hours = "clock"
    static let paycheck = "banknote"
    static let photo = "photo"
    static let document = "doc"
    static let status = "flag"
    static let deleted = "trash"
    static let business = "building.2"
    static let settings = "gearshape"
    static let sent = "paperplane"

    static func symbol(for kind: DeletionService.Kind, attachment: JobAttachment? = nil) -> String {
        switch kind {
        case .customer: return customer
        case .estimate: return estimate
        case .contract: return contract
        case .invoice, .payment: return invoice
        case .changeOrder: return changeOrder
        case .job: return job
        case .receipt: return receipt
        case .priceItem: return priceItem
        case .employee: return employee
        case .subcontractor: return subcontractor
        case .project: return project
        case .timeEntry: return hours
        case .paycheck, .subPayment: return paycheck
        case .attachment: return attachment?.kind == .photo ? photo : document
        case .document: return document
        }
    }
}

// MARK: - Refusals

@MainActor
extension MBToolFailure {

    /// A service's refusal, as both halves of law 6: the model gets the stable `code` and a
    /// sentence with the way forward; the person gets a "Not done" row in their own language.
    static func domain(_ error: DomainError, _ record: GLAIRecordRef? = nil) -> GLAIToolOutcome {
        let english = GLAIStrings.english(error.personReason)
        let message = [english, hint(for: error)].compactMap { $0 }.joined(separator: " ")
        return .failure(GLAIFailure(reason: error.code, message: message,
                                    personReason: error.personReason, record: record))
    }

    /// What the model should do instead — the app's own answer to each refusal.
    static func hint(for error: DomainError) -> String? {
        switch error {
        case .paidLocked:
            return "A paid invoice can't be changed. Offer a change order instead."
        case .changeOrderLinesReadOnly:
            return "Change the change order itself instead."
        case .exceedsBalance:
            return "Offer to split the payment across the customer's open invoices, one call each."
        case .paymentsCannotBeDeleted, .hasRecordedPayments:
            return "Offer a credit change order instead."
        case .readOnly(_, let lapsed):
            return lapsed
                ? "Tell the user plainly; nothing can be changed until the subscription is active."
                : "Tell the user plainly; nothing can be changed until they're back online."
        case .freeLimitReached:
            return "Tell the user plainly that this needs a subscription."
        case .recordNotFound:
            return "Use find to get a current id."
        case .tooMuchToDelete:
            return "Suggest deleting some of the records under it first."
        default:
            return nil
        }
    }

    /// Anything a service threw that isn't a `DomainError` (a store failure). The person sees the
    /// generic sentence; the model is told plainly that nothing was saved.
    static func unexpected(_ error: any Error, _ record: GLAIRecordRef? = nil) -> GLAIToolOutcome {
        if let domain = error as? DomainError { return self.domain(domain, record) }
        Logger.domain.error("ai write failed: \(String(describing: type(of: error)), privacy: .public)")
        return .failure(GLAIFailure(reason: "not_saved",
                                    message: "That didn't save. Tell the user plainly and don't retry it by itself.",
                                    personReason: GLAIStrings.errorGeneric, record: record))
    }

    /// The person's "not current" fence: the account, store or sample mode changed under the call.
    static var storeChanged: GLAIToolOutcome { unavailable }
}

// MARK: - Steps

/// Either the value a step produced, or the outcome the tool should hand back instead (a refusal).
/// `Result` can't carry a `GLAIToolOutcome`, which isn't an `Error` — and shouldn't be: a refusal
/// is a normal answer here, not a thrown failure.
enum MBStep<Value> {
    case value(Value)
    case outcome(GLAIToolOutcome)
}

// MARK: - Arguments

extension MBArguments {
    /// Present at all (a `null` counts as present — it is how a nullable field is cleared).
    func has(_ key: String) -> Bool { json[key] != nil }

    /// Present and explicitly null (`agreed_price: null` clears the price).
    func isNull(_ key: String) -> Bool { json[key]?.isNull == true }

    func bool(_ key: String) -> Bool? { json[key]?.boolValue }

    func number(_ key: String) -> Double? {
        guard let value = json[key]?.doubleValue, value.isFinite else { return nil }
        return value
    }

    /// An AMOUNT from the model — a payment, a receipt total, a flat entry, a bonus, a paycheck, an
    /// amount due, an agreed price. Money is entered in whole cents (law 60): `MBWholeCentsGate`
    /// has already refused a call whose amount carries a fraction of a cent, so this is the value
    /// as sent, held to the cent the way its service stores it from the form too. Never for a
    /// price, rate or percentage: those are read with `number` and kept as sent, as the forms keep
    /// what was typed, so the amount made from them is rounded once — 1,000 × $0.125 is $125.00 on
    /// both doors, never $130.00.
    func money(_ key: String) -> Double? {
        guard let value = number(key) else { return nil }
        return DomainMoney.roundedToCents(value)
    }

    /// Every argument that is an AMOUNT, by the name the manifest gives it on every tool that takes
    /// it (`amount`, `amount_due_now`, `agreed_price`, `bonus`, `gross_amount`, `total`). A deposit
    /// is an amount only when it is in dollars, so the estimate tools check `deposit_value`
    /// themselves (`MBEstimateDraftBuilder.depositRefusal`). `WholeCentAmountTests` fails when the
    /// manifest gains a number argument nobody has sorted into amounts or kept-as-sent values.
    static let amountKeys: Set<String> = ["amount", "amount_due_now", "agreed_price", "bonus", "gross_amount", "total"]

    /// The first AMOUNT argument sent with a fraction of a cent, refused as the model's own slip
    /// (`invalid_arguments`, never a row on the person's card) so it sends the amount again in
    /// whole cents. Nil when every amount sent is whole cents.
    func centFractionRefusal() -> GLAIToolOutcome? {
        for key in Self.amountKeys.sorted() {
            guard let value = number(key), !DomainMoney.isWholeCents(value) else { continue }
            return MBToolFailure.invalid(Self.wholeCentsMessage(key))
        }
        return nil
    }

    /// What the model reads when an amount carries a fraction of a cent.
    static func wholeCentsMessage(_ key: String) -> String {
        "\(key) is money, so it must be whole cents: at most two decimals, like 12.35. Send it again in whole cents."
    }

    func strings(_ key: String) -> [String] {
        (json[key]?.arrayValue ?? []).compactMap {
            guard let text = $0.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty
            else { return nil }
            return text
        }
    }

    func objects(_ key: String) -> [GLAIJSON] { json[key]?.arrayValue ?? [] }

    func object(_ key: String) -> GLAIJSON? {
        guard let value = json[key], value.objectValue != nil else { return nil }
        return value
    }

    /// A raw-value enum the manifest spells out. Nil when absent; a wrong spelling is the model's
    /// slip, so the caller refuses with `invalid`.
    func raw<T: RawRepresentable>(_ key: String, _ type: T.Type) -> T? where T.RawValue == String {
        guard let text = string(key) else { return nil }
        return T(rawValue: text)
    }
}

// MARK: - Shared value rules

@MainActor
enum MBWriteValue {

    /// "Only the sent parts change" — the manifest's rule for every address argument.
    static func address(_ current: Address, patch: GLAIJSON?) -> Address {
        guard let patch, let object = patch.objectValue else { return current }
        var address = current
        if let street1 = object["street1"]?.stringValue { address.street1 = street1 }
        if let street2 = object["street2"]?.stringValue { address.street2 = street2 }
        if let city = object["city"]?.stringValue { address.city = city }
        if let state = object["state"]?.stringValue { address.state = state }
        if let postal = object["postal_code"]?.stringValue { address.postalCode = postal }
        return address
    }

    /// The whole-dollar spelling the activity rows show ("$1,240.00"), in the app's locale.
    static func amount(_ value: Double) -> String {
        value.formatted(.money.locale(MBLocalization.currentLocale))
    }
}

// MARK: - Fingerprints

/// A record's "has anything changed since?" stamp: its own `updatedAt` and its rows'. `saveChanges`
/// moves `updatedAt` on every row a write touches, so this catches an edit made on the form, a
/// pull from another device, and a later tool call alike.
@MainActor
enum MBFingerprint {

    static func stamp(_ record: (any GLSyncIdentified)?) -> String {
        guard let record else { return "-" }
        return String(format: "%.6f", record.updatedAt?.timeIntervalSinceReferenceDate ?? 0)
    }

    static func of(_ customer: Customer) -> String { stamp(customer) }

    /// Price sheet items are local-only (not `GLSyncIdentified`), so they carry their own stamp —
    /// `PriceSheetService` writes `updatedAt` by hand on every save.
    static func of(_ item: PriceSheetItem) -> String {
        String(format: "%.6f", item.updatedAt?.timeIntervalSinceReferenceDate ?? 0)
    }

    static func of(_ job: ScheduledJob) -> String {
        "\(stamp(job))|\(job.project?.syncID?.uuidString ?? "-")"
    }

    static func of(_ estimate: Estimate) -> String {
        let groups = estimate.sortedGroups
        let rows = groups.flatMap { $0.sortedLineItems.map { stamp($0) } }
        return ([stamp(estimate)] + groups.map { stamp($0) } + rows).joined(separator: "|")
    }

    static func of(_ contract: Contract) -> String {
        let groups = contract.sortedGroups
        let rows = groups.flatMap { $0.sortedLineItems.map { stamp($0) } }
        let changeOrders = contract.sortedChangeOrders.map { stamp($0) }
        return ([stamp(contract), contract.statusRaw, "\(contract.agreedPrice ?? 0)"] + groups.map { stamp($0) } + rows + changeOrders)
            .joined(separator: "|")
    }

    static func of(_ invoice: Invoice) -> String {
        let groups = invoice.sortedGroups
        let rows = groups.flatMap { $0.sortedLineItems.map { stamp($0) } }
        let payments = invoice.sortedPayments.map { stamp($0) }
        let attachments = invoice.liveRows(invoice.attachments).count
        return ([stamp(invoice)] + groups.map { stamp($0) } + rows + payments + ["a\(attachments)"])
            .joined(separator: "|")
    }

    /// The business details and message templates as they read now. They are one record with no
    /// `updatedAt` worth trusting across a form save, so the stamp is the content itself.
    static func business(in store: ModelContext) -> String {
        let profile = MBRecordLookup.businessProfile(in: store)
        let details = profile.map { BusinessDetailsDraft($0) } ?? BusinessDetailsDraft()
        let messages = profile.map { DocumentMessagesDraft($0) } ?? DocumentMessagesDraft()
        return "\(details)|\(messages)"
    }

    /// The work schedule as it reads now (days, holidays, vacations, days off, overrides).
    static func workSchedule(_ schedule: WorkSchedule) -> String { "\(schedule)" }

    static func of(_ order: ChangeOrder) -> String {
        let rows = order.liveRows(order.lineItems).map { stamp($0) }
        return ([stamp(order), order.statusRaw, order.appliedToInvoice ? "1" : "0"] + rows).joined(separator: "|")
    }
}

// MARK: - The conversation's write ledger

/// What this conversation has written, kept out of the tools themselves so an Undo entry captures
/// nothing but ids (contract §4: re-fetch by id).
///
///   • `fingerprints` — what each record looked like after the last write THIS conversation made.
///     Undo skips an entry whose record has moved since (`changedSince`), and a later tool write
///     updates the expectation, so undoing a create after an edit still runs.
///   • `snapshots` — the "before" draft an Undo restores, handed out by token (a `@Model` or a
///     draft never crosses into an Undo closure).
///   • `payments` — the idempotency key (`turnId:callId`) of every payment recorded, so a step
///     that runs twice can never record the same money twice.
@MainActor
final class MBWriteLedger {
    private var fingerprints: [String: String] = [:]
    private var snapshots: [UUID: MBUndoSnapshot] = [:]
    private var payments: [String: GLAIJSON] = [:]

    init() {}

    func note(_ id: String, _ fingerprint: String) { fingerprints[id] = fingerprint }

    /// True when the record moved since this conversation last wrote it.
    func changed(_ id: String, _ current: String?) -> Bool {
        guard let expected = fingerprints[id] else { return false }
        return expected != current
    }

    func stash(_ snapshot: MBUndoSnapshot) -> UUID {
        let token = UUID()
        snapshots[token] = snapshot
        return token
    }

    func snapshot(_ token: UUID) -> MBUndoSnapshot? { snapshots[token] }

    func recordedPayment(_ key: String) -> GLAIJSON? { payments[key] }

    func notePayment(_ key: String, _ output: GLAIJSON) { payments[key] = output }

    /// Sign-out, account switch or store rebuild: nothing here means anything any more.
    func clear() {
        fingerprints.removeAll()
        snapshots.removeAll()
        payments.removeAll()
    }
}

/// Contract editable fields as preserved for Undo snapshots.
nonisolated struct ContractDraft: Equatable, Sendable {
    var title: String = ""
    var customerID: UUID? = nil
    var customerName: String = ""
    var customerEmail: String = ""
    var customerPhone: String = ""
    var startDate: Date = .now
    var durationDays: Int = 1
    var isAllDay: Bool = true
    var startTime: Date? = nil
    var durationMinutes: Int? = nil
    var notes: String = ""
    var terms: String = ""
    var serviceAddress: Address = Address()
    var agreedPrice: Double? = nil
    var status: ContractStatus = .draft

    init() {}

    @MainActor
    init(_ contract: Contract) {
        self.title = contract.title
        self.customerID = contract.customer?.syncID
        self.customerName = contract.customerName
        self.customerEmail = contract.customerEmail
        self.customerPhone = contract.customerPhone
        self.startDate = contract.startDate
        self.durationDays = contract.durationDays
        self.isAllDay = contract.isAllDay
        self.startTime = contract.startTime
        self.durationMinutes = contract.durationMinutes
        self.notes = contract.notes
        self.terms = contract.terms
        self.serviceAddress = contract.serviceAddress
        self.agreedPrice = contract.agreedPrice
        self.status = contract.status
    }
}

/// The "before" state an Undo puts back. Held by the ledger (never captured in an Undo closure).
@MainActor
enum MBUndoSnapshot {
    case customer(CustomerDraft)
    case estimate(EstimateDraft)
    case contract(ContractDraft)
    case invoice(InvoiceDraft)
    case job(JobDraft, projectID: String?)
}

// MARK: - Records by id

/// How a write tool names and re-finds a record. Ids are `syncID`s (contract §5), and an Undo
/// closure holds nothing but the id — it re-fetches when it runs.
@MainActor
enum MBWrite {

    static func ref(_ kind: MBRecordKind, _ id: String) -> GLAIRecordRef {
        GLAIRecordRef(kind: kind.rawValue, id: id)
    }

    static func customer(_ id: String, _ env: MBToolEnvironment) -> Customer? {
        record(.customer, id, env, Customer.self)
    }

    static func estimate(_ id: String, _ env: MBToolEnvironment) -> Estimate? {
        record(.estimate, id, env, Estimate.self)
    }

    static func contract(_ id: String, _ env: MBToolEnvironment) -> Contract? {
        record(.contract, id, env, Contract.self)
    }

    static func invoice(_ id: String, _ env: MBToolEnvironment) -> Invoice? {
        record(.invoice, id, env, Invoice.self)
    }

    static func job(_ id: String, _ env: MBToolEnvironment) -> ScheduledJob? {
        record(.job, id, env, ScheduledJob.self)
    }

    static func changeOrder(_ id: String, _ env: MBToolEnvironment) -> ChangeOrder? {
        record(.changeOrder, id, env, ChangeOrder.self)
    }

    static func project(_ id: String, _ env: MBToolEnvironment) -> Project? {
        record(.project, id, env, Project.self)
    }

    private static func record<T: PersistentModel>(_ kind: MBRecordKind, _ id: String,
                                                   _ env: MBToolEnvironment, _ type: T.Type) -> T? {
        guard let store = env.context() else { return nil }
        return MBRecordLookup.record(kind, id: id, as: type, in: store)
    }

    /// A refusal met while Undo was putting something back: the person reads the reason on the card.
    static func revertFailure(_ error: any Error) -> GLAIUndoRevert {
        if let domain = error as? DomainError { return .failed(domain.personReason) }
        return .failed(GLAIStrings.errorGeneric)
    }
}

// MARK: - Undo entries

@MainActor
enum MBUndo {

    /// One reversible write. `fingerprint` re-reads the record (by id) and answers what it looks
    /// like now; `revert` re-enters the same service the form calls.
    static func entry(_ record: GLAIRecordRef, title: LocalizedStringResource, ledger: MBWriteLedger,
                      fingerprint: @escaping @MainActor @Sendable () -> String?,
                      dropReason: @escaping @MainActor @Sendable () -> LocalizedStringResource? = { nil },
                      revert: @escaping @MainActor @Sendable () async -> GLAIUndoRevert) -> GLAIUndo {
        GLAIUndo(record: record, title: title, dropReason: dropReason,
                 changedSince: { ledger.changed(record.id, fingerprint()) },
                 revert: revert)
    }

    /// The record an Undo was about is gone — the same refusal a form gets.
    static var recordGone: GLAIUndoRevert { .failed(DomainError.recordNotFound.personReason) }

    static func reverted(_ kind: GLAIActivity.Kind, _ symbol: String, _ title: LocalizedStringResource,
                         detail: String?, record: GLAIRecordRef?) -> GLAIUndoRevert {
        .reverted(GLAIActivity(kind: kind, symbol: symbol, title: title, detail: detail, record: record))
    }
}
