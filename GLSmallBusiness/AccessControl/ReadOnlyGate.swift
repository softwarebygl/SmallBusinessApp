//
//  ReadOnlyGate.swift
//  GLSmallBusiness
//
//  Created by Gold Life LLC.
//
//  THE RULING (Adrian, 2026-08-25). A LAPSED subscription — subscribed before, inactive now — is
//  100% READ-ONLY. The app does NOTHING on their behalf: no creating, no editing, no status
//  changes, no recording a payment that lands after the lapse, no 1099/W-9/PDF, no export. They
//  read their records; that is all. His words: "the app is in a sense dead and all they can do is
//  read the tombstone. Tombstones can't 'do' anything."
//
//  Two states are deliberately NOT this:
//  - NEVER SUBSCRIBED keeps the FreeTier caps and creates and edits up to them. "Free to start" is
//    the App Store listing; breaking it here would make the listing false.
//  - ACCOUNT DELETION survives, whatever the billing state, because Apple Guideline 5.1.1(v)
//    requires in-app account deletion. Gating it gets the app rejected. Nothing in this file is
//    ever applied to that flow — see the deletion sections in
//    the GoldLifeID package (`GLAccountDeletionSections`).
//
//  WHY A GATE AND NOT A DISABLED BUTTON. A control that greys out with no explanation is a defect:
//  the person taps, nothing happens, and they conclude the app is broken rather than lapsed. So
//  every refusal here does TWO things, always both, never one (owner rule, same day):
//    1. a plain-English alert for the PERSON, saying what happened and what to do next, EN + ES;
//    2. an `OSLog` line for the DEVELOPER, naming the operation and the decision.
//  The log names the OPERATION, never a value: no Tax IDs, no money, no customer details.
//
//  TWO SURFACES, ONE LOG. Not every write starts with a tap. A `.task` poll, a foreground status
//  refresh and a first-render singleton bootstrap are all writes the app was about to make on its
//  own, and those go through `allowsUnattended`, which writes the developer line and raises NO
//  alert. That is the rule applied, not bent: rule (1) exists so a person who taps something is
//  never left in front of a screen that did nothing, and here nobody tapped — an alert would arrive
//  unprompted, name an operation they never started, and offer nothing to do. What they can act on
//  is on screen already and permanently: the MBSystemBanners slot rides every screen. Rule (2)
//  has no such exception and never will: a refusal with no log is what made "the invoice never went
//  Paid" unanswerable from `log show`, and closing that is why this split exists at all.
//

import Foundation
import GoldLifeMoney
import GoldLifeUI
import OSLog
import SwiftData
import SwiftUI

extension Logger {
    /// Entitlement / access-control decisions. Its own channel so a support question ("why did
    /// nothing happen when I tapped Save?") is one `log show --predicate` away.
    static let access = Logger(subsystem: Bundle.main.bundleIdentifier ?? "GLSmallBusiness",
                               category: "access")
}

// MARK: - The denominator

/// Every write the app can be asked to perform, named. A closed list on purpose: adding a write
/// surface without adding a case here is a compile-time nudge, and the list itself is the answer to
/// "did we get all of them?" — `MBWriteOperation.allCases` is what `ReadOnlyGateTests` walks.
///
/// The raw value is the DEVELOPER's name for the operation and goes into the log line verbatim, so
/// it is stable, lowerCamelCase, and never localized. `phrase` is the PERSON's half and is resolved
/// at render time (never cached as a String), so an in-app language switch re-renders it — the same
/// rule the account-deletion flow states.
enum MBWriteOperation: String, CaseIterable, Sendable {

    // Contacts
    case saveCustomer, deleteCustomer
    case saveEmployee, deleteEmployee
    case saveSubcontractor, deleteSubcontractor

    // Estimates
    case saveEstimate, deleteEstimate, convertEstimateToInvoice

    // Contracts
    case saveContract, deleteContract

    // Invoices and money
    case saveInvoice, deleteInvoice
    case setAmountDue
    case recordPayment, deletePayment
    case togglePayLink, mintPayLink

    // Change orders
    case saveChangeOrder, deleteChangeOrder, changeChangeOrderStatus

    // Jobs, projects, scheduling
    case saveJob, deleteJob, changeJobStatus, scheduleJob
    case addJobAttachment, deleteJobAttachment, assignJobToProject
    case saveProject, deleteProject

    // Receipts and documents
    case saveReceipt, deleteReceipt
    case saveDocument, deleteDocument

    // Payroll
    case logHours, deleteHours
    case recordPaycheck, deletePaycheck
    case recordSubcontractorPayment, deleteSubcontractorPayment

    // Business setup
    case saveBusinessProfile, saveDocumentSettings, saveWorkSchedule
    case saveSignature, savePersonalInfo, saveAppSettings
    case setUpPayments
    case savePriceSheetItem, deletePriceSheetItem
    case useAIAssistant

    // Things the app GENERATES — a verb, so it stops too
    case generateDocument, generate1099, generateW9
    case generateContractorPackage, generateCompletionPackage, generatePaymentReceipt
    case sendDocument

    // Things the app EXPORTS — "that is a verb, the app is doing something" (owner, 2026-08-25)
    case exportWages, exportSubcontractorPay, exportStats

    // Connected banks & money (GoldLifeMoney)
    case connectBank, disconnectBank, refreshBanks
    case classifyTransaction, applyBulkRule, updateAccountDefault
    case saveRule, deleteRule
    case toggleSubscriptionTracking, updateSubscription

    /// What the person was trying to do, as the subject of a sentence. A gerund in English and an
    /// infinitive in Spanish, so the surrounding sentence needs no gender or number agreement in
    /// either language and one template serves all of them.
    var phrase: String {
        switch self {
        case .saveCustomer:                 return mbLoc("Saving this customer")
        case .deleteCustomer:               return mbLoc("Deleting this customer")
        case .saveEmployee:                 return mbLoc("Saving this employee")
        case .deleteEmployee:               return mbLoc("Deleting this employee")
        case .saveSubcontractor:            return mbLoc("Saving this subcontractor")
        case .deleteSubcontractor:          return mbLoc("Deleting this subcontractor")

        case .saveEstimate:                 return mbLoc("Saving this estimate")
        case .deleteEstimate:               return mbLoc("Deleting this estimate")
        case .convertEstimateToInvoice:     return mbLoc("Turning this estimate into an invoice")
        case .saveContract:                 return mbLoc("Saving this contract")
        case .deleteContract:               return mbLoc("Deleting this contract")

        case .saveInvoice:                  return mbLoc("Saving this invoice")
        case .deleteInvoice:                return mbLoc("Deleting this invoice")
        case .setAmountDue:                 return mbLoc("Changing the amount due")
        case .recordPayment:                return mbLoc("Recording a payment")
        case .deletePayment:                return mbLoc("Deleting this payment")
        case .togglePayLink:                return mbLoc("Changing the Pay button")
        case .mintPayLink:                  return mbLoc("Creating a card payment link")

        case .saveChangeOrder:              return mbLoc("Saving this change order")
        case .deleteChangeOrder:            return mbLoc("Deleting this change order")
        case .changeChangeOrderStatus:      return mbLoc("Changing this change order")

        case .saveJob:                      return mbLoc("Saving this job")
        case .deleteJob:                    return mbLoc("Deleting this job")
        case .changeJobStatus:              return mbLoc("Changing this job")
        case .scheduleJob:                  return mbLoc("Scheduling a job")
        case .addJobAttachment:             return mbLoc("Adding to this job")
        case .deleteJobAttachment:          return mbLoc("Removing this attachment")
        case .assignJobToProject:           return mbLoc("Changing this job’s project")
        case .saveProject:                  return mbLoc("Saving this project")
        case .deleteProject:                return mbLoc("Deleting this project")

        case .saveReceipt:                  return mbLoc("Saving this receipt")
        case .deleteReceipt:                return mbLoc("Deleting this receipt")
        case .saveDocument:                 return mbLoc("Adding this document")
        case .deleteDocument:               return mbLoc("Deleting this document")

        case .logHours:                     return mbLoc("Logging hours")
        case .deleteHours:                  return mbLoc("Deleting these hours")
        case .recordPaycheck:               return mbLoc("Recording a paycheck")
        case .deletePaycheck:               return mbLoc("Deleting this paycheck")
        case .recordSubcontractorPayment:   return mbLoc("Recording a payment")
        case .deleteSubcontractorPayment:   return mbLoc("Deleting this payment")

        case .saveBusinessProfile:          return mbLoc("Saving your business details")
        case .saveDocumentSettings:         return mbLoc("Saving your document settings")
        case .saveWorkSchedule:             return mbLoc("Saving your work schedule")
        case .saveSignature:                return mbLoc("Saving your signature")
        case .savePersonalInfo:             return mbLoc("Saving your details")
        case .saveAppSettings:              return mbLoc("Changing this setting")
        case .setUpPayments:                return mbLoc("Setting up card payments")
        case .savePriceSheetItem:           return mbLoc("Saving this price sheet item")
        case .deletePriceSheetItem:         return mbLoc("Deleting this price sheet item")
        case .useAIAssistant:               return mbLoc("Using the Assistant")

        case .generateDocument:             return mbLoc("Creating this document")
        case .generate1099:                 return mbLoc("Creating a 1099-NEC")
        case .generateW9:                   return mbLoc("Creating a W-9")
        case .generateContractorPackage:    return mbLoc("Creating a contractor package")
        case .generateCompletionPackage:    return mbLoc("Creating a completion package")
        case .generatePaymentReceipt:       return mbLoc("Creating a payment receipt")
        case .sendDocument:                 return mbLoc("Sending this document")

        case .exportWages:                  return mbLoc("Exporting wages")
        case .exportSubcontractorPay:       return mbLoc("Exporting subcontractor pay")
        case .exportStats:                  return mbLoc("Exporting your statistics")

        case .connectBank:                  return mbLoc("Connecting a bank account")
        case .disconnectBank:               return mbLoc("Disconnecting this bank account")
        case .refreshBanks:                 return mbLoc("Refreshing bank transactions")
        case .classifyTransaction:          return mbLoc("Changing this transaction")
        case .applyBulkRule:                return mbLoc("Saving this merchant rule")
        case .updateAccountDefault:         return mbLoc("Changing this account setting")
        case .saveRule:                     return mbLoc("Saving this merchant rule")
        case .deleteRule:                   return mbLoc("Deleting this merchant rule")
        case .toggleSubscriptionTracking:   return mbLoc("Changing subscription tracking")
        case .updateSubscription:           return mbLoc("Changing this subscription")
        }
    }
}

// MARK: - The gate

/// The one place that answers "may this write happen?", and the one place that says no.
///
/// Deliberately NOT folded into `AccessGate`: that gate is CAP-based and answers a question about a
/// RECORD TYPE ("is there room for another Customer?"). This one is about the ACCOUNT and covers
/// verbs creation has nothing to say about — editing, deleting, generating, exporting.
/// `AccessGate.decide` asks `isLapsed` first, so the two can never disagree about creation.
@MainActor
enum ReadOnlyGate {

    /// THE condition, asked in exactly one place. `isReadOnly`, `allows` and `allowsUnattended` all
    /// defer to this and read nothing else, because the alternative was shipped and was a defect:
    /// the sample-mode exemption landed on the DISPLAY helper alone while both gates that actually
    /// refuse kept their own copy of the check, so an offline person exploring sample data was
    /// refused every write with "Read-only while offline" — and `isReadOnly` being false meant the
    /// banner that would have explained it was suppressed. Nothing to do, and nothing said.
    ///
    /// Returns WHY the write is refused, or nil when it may proceed.
    private static func refusalCause(_ subscription: SubscriptionManager) -> RefusalCause? {
        // Sample mode is never read-only (law 15): the dataset is fictional
        // and in-memory, so no network is needed to write to it — refusing
        // with "until you reconnect" would be a claim about a world the screen
        // is not showing. (Its billing exemption already lives in `isLapsed`,
        // so this line only has to cover the offline half.)
        if UserDemoMode.shared.isDemoActive { return nil }
        if subscription.isLapsed { return .lapsed }
        if !NetworkMonitor.shared.isConnected { return .offline }
        return nil
    }

    /// Is the app read-only right now? Read this for DISPLAY (choosing copy, hiding a control that
    /// would be pure noise) — never as the only guard, because a control that silently does nothing
    /// is the defect this file exists to prevent.
    static func isReadOnly(_ subscription: SubscriptionManager? = nil) -> Bool {
        refusalCause(subscription ?? .shared) != nil
    }

    /// THE call-site pattern:
    ///
    /// ```swift
    /// @State private var refused: MBWriteOperation?          // + .readOnlyRefusalAlert($refused)
    /// ...
    /// guard ReadOnlyGate.allows(.saveCustomer, subscription, into: $refused) else { return }
    /// ```
    ///
    /// Returns true and does nothing at all when the subscription is fine — never-subscribed
    /// included, because the free caps are `AccessGate`'s business, not this gate's. Returns false
    /// AND refuses out loud when it is lapsed.
    ///
    /// `into` is REQUIRED, and that is the point: it is the screen's own alert state, so the
    /// compiler — not a code review — is what stops a refusal from happening in silence. An
    /// app-wide fallback host was tried first and deleted: an alert has to be presented from the
    /// presentation context the person is actually looking at, and one bound at the app root
    /// presents NOTHING while a sheet is up, which is where half these refusals happen.
    @discardableResult
    static func allows(_ operation: MBWriteOperation,
                       _ subscription: SubscriptionManager? = nil,
                       into refused: Binding<MBWriteOperation?>) -> Bool {
        let subscription = subscription ?? .shared
        guard refusalCause(subscription) != nil else { return true }
        refuse(operation, into: refused, subscription: subscription)
        return false
    }

    /// The UNATTENDED call-site pattern — the same gate for a write NOBODY ASKED FOR:
    ///
    /// ```swift
    /// guard ReadOnlyGate.allowsUnattended(.recordPayment, subscription) else { return }
    /// ```
    ///
    /// A `.task` poll, a foreground status refresh, a first-render bootstrap of an empty singleton.
    /// These get the LOG and no alert, and that is a deliberate reading of the owner rule rather
    /// than an exception to it. The rule exists so a person who taps a control is never left staring
    /// at a screen that did nothing; here there was no tap, so an alert would arrive out of nowhere,
    /// name an operation they never started, and give them nothing to act on. What they CAN act on
    /// is already on screen and permanent: the MBSystemBanners slot rides every screen and says
    /// the app is read-only with a Reactivate button in it. The developer half is NOT optional —
    /// "why did the pay status stop updating?" has to be answerable from `log show`.
    ///
    /// The rule of thumb, and the reason this is a SEPARATE function rather than a flag: if a
    /// control started it, the person is owed the sentence and `allows(_:_:into:)` is the call. A
    /// silent refusal is only ever correct for work the app started by itself.
    @discardableResult
    static func allowsUnattended(_ operation: MBWriteOperation,
                                 _ subscription: SubscriptionManager? = nil) -> Bool {
        let subscription = subscription ?? .shared
        guard let cause = refusalCause(subscription) else { return true }
        log(operation, surface: .unattended, cause: cause)
        return false
    }

    /// WHY the write was refused, captured AT refusal time. The alert used to
    /// re-read connectivity when it rendered, so an offline refusal whose alert
    /// appeared after reconnect claimed "Your subscription ended" at a possibly
    /// subscribed person. One writer (refuse/allowsUnattended), one reader (the
    /// alert), always the truth of the moment the gate said no.
    enum RefusalCause { case lapsed, offline }
    private(set) static var lastRefusalCause: RefusalCause = .lapsed

    /// The cause as of RIGHT NOW — used only at the instant of refusal, and only by `refuse`, which
    /// is called when something has ALREADY decided to say no. It is not a second gate condition and
    /// must never grow into one: `refusalCause` is the only place that decides WHETHER, this only
    /// names WHY, and for every refusal routed through `allows` the two agree by construction.
    private static func currentCause(_ subscription: SubscriptionManager) -> RefusalCause {
        subscription.isLapsed ? .lapsed : .offline
    }

    /// Say no, both ways at once — the alert AND the log, never one without the other. Never call
    /// this without having actually refused something.
    static func refuse(_ operation: MBWriteOperation, into refused: Binding<MBWriteOperation?>,
                       subscription: SubscriptionManager? = nil) {
        let subscription = subscription ?? .shared
        lastRefusalCause = currentCause(subscription)
        log(operation, surface: .alert, cause: lastRefusalCause)
        // The person's half.
        refused.wrappedValue = operation
    }

    /// Maps a `GoldLifeMoney` write-gate operation string to a concrete `MBWriteOperation`.
    static func mapMoneyOperation(_ raw: String) -> MBWriteOperation {
        switch raw {
        case "connectBank": return .connectBank
        case "disconnectBank": return .disconnectBank
        case "refreshBanks": return .refreshBanks
        case "classifyTransaction": return .classifyTransaction
        case "applyBulkRule": return .applyBulkRule
        case "updateAccountDefault": return .updateAccountDefault
        case "saveRule", "addRule": return .saveRule
        case "deleteRule": return .deleteRule
        case "toggleSubscriptionTracking": return .toggleSubscriptionTracking
        case "updateSubscription": return .updateSubscription
        default: return .classifyTransaction
        }
    }

    /// Which half of the gate refused. `alert` was a tap and the person got a sentence; `unattended`
    /// was the app's own work and the banner is what tells them.
    private enum Surface { case alert, unattended }

    /// The developer half, and the only place in the app that writes it.
    ///
    /// Spelled out per surface×cause instead of interpolating either, so the invariant
    /// `ReadOnlyGateTests.theLogLineCarriesNoUserData` pins stays literally true and checkable:
    /// ONE interpolation per refusal line, and it is the closed enum's own raw value. Everything
    /// else is a compile-time literal, which is why `.public` is safe here and would not be for a
    /// value the person typed — no Tax ID, no amount, no customer name ever reaches this line.
    /// (The offline branches fix the recorded diagnosability lie: an offline refusal used to log
    /// `decision=lapsed_subscription_read_only`.)
    private static func log(_ operation: MBWriteOperation, surface: Surface, cause: RefusalCause) {
        switch (surface, cause) {
        case (.alert, .lapsed):
            Logger.access.error(
                "read-only refusal: operation=\(operation.rawValue, privacy: .public) decision=lapsed_subscription_read_only surface=alert")
        case (.alert, .offline):
            Logger.access.error(
                "read-only refusal: operation=\(operation.rawValue, privacy: .public) decision=offline_read_only surface=alert")
        case (.unattended, .lapsed):
            Logger.access.error(
                "read-only refusal: operation=\(operation.rawValue, privacy: .public) decision=lapsed_subscription_read_only surface=unattended")
        case (.unattended, .offline):
            Logger.access.error(
                "read-only refusal: operation=\(operation.rawValue, privacy: .public) decision=offline_read_only surface=unattended")
        }
    }
}

// MARK: - What the person sees

extension View {
    /// The refusal alert for ONE screen or sheet, bound to that screen's own state.
    ///
    /// Per-screen rather than app-wide on purpose. A single host at the app root cannot present
    /// over a sheet — SwiftUI presents from the nearest presentation context — and the Record
    /// payment, Log hours, Amount due, Signature and Menu surfaces are all sheets. Every screen
    /// that can refuse therefore owns one `@State private var readOnlyRefusal: MBWriteOperation?`
    /// and mounts this beside its other alerts.
    func readOnlyRefusalAlert(_ refused: Binding<MBWriteOperation?>) -> some View {
        modifier(ReadOnlyRefusalAlert(refused: refused))
    }
}

private struct ReadOnlyRefusalAlert: ViewModifier {
    @Binding var refused: MBWriteOperation?
    /// Local, so the paywall opens in the SAME presentation context as the alert that offered it.
    @State private var showingPaywall = false

    /// The CAPTURED cause, not a live connectivity read: the refusal's truth was
    /// fixed the moment the gate said no. (Live reads raced — an offline refusal
    /// whose alert rendered after reconnect claimed "Your subscription ended".)
    private var causeIsLapsed: Bool { ReadOnlyGate.lastRefusalCause == .lapsed }

    func body(content: Content) -> some View {
        content
            .alert(causeIsLapsed ? mbLoc("Your subscription ended") : mbLoc("Read-only while offline"),
                   isPresented: Binding(get: { refused != nil },
                                        set: { if !$0 { refused = nil } }),
                   presenting: refused) { _ in
                if causeIsLapsed {
                    Button(mbLoc("Reactivate")) {
                        refused = nil
                        showingPaywall = true
                    }
                }
                Button(mbLoc("OK"), role: .cancel) { refused = nil }
            } message: { operation in
                if causeIsLapsed {
                    Text("\(operation.phrase) needs an active subscription. Everything you already have is still here to read — nothing can be added, changed or exported until you reactivate.")
                } else {
                    Text("\(operation.phrase) requires an internet connection. Everything you already have is still here to read — nothing can be added, changed or exported until you reconnect.")
                }
            }
            .paywallSheet(isPresented: $showingPaywall)
    }
}

// The lapsed banner no longer mounts here or per screen: MBSystemBanners.swift
// is the ONE slot every standing notice shares (owner ruling 2026-08-28 —
// banners append in a single position; build 43 had sample above the chrome,
// lapsed under every title, offline on the roots). Still the shared
// GLSubscriptionBanner from GoldLifeUI with `.entered` (typed records go
// nowhere), per PARITY.md.

// MARK: - Sharing

/// A `ShareLink` that a lapsed app replaces with a row that explains itself.
///
/// Sharing hands a generated document to another app — the plainest case of the app doing
/// something on someone's behalf, and the ruling blocks export in exactly those words ("that is a
/// verb, the app is doing something"). A `ShareLink` has no action to guard, so the lapsed app
/// substitutes a real `Button` wearing the SAME label rather than hiding the row: a control that
/// silently vanishes teaches the person nothing, and they go looking for a bug instead of a
/// subscription.
struct MBShareLink<Label: View>: View {
    let item: URL
    var subject: Text? = nil
    var message: Text? = nil
    var operation: MBWriteOperation = .sendDocument
    @Binding var refused: MBWriteOperation?
    @ViewBuilder var label: () -> Label

    /// The singleton rather than the environment, for the reason `MBLapsedBanner` gives: these rows
    /// render in previews and render-coverage tests that inject no environment.
    @State private var subscription = SubscriptionManager.shared

    var body: some View {
        if subscription.isLapsed {
            Button { ReadOnlyGate.refuse(operation, into: $refused) } label: { label() }
        } else {
            ShareLink(item: item, subject: subject, message: message) { label() }
        }
    }
}

/// The plain-text form — the review-request message, which is a thing the app sends on the
/// owner's behalf just as much as a PDF is.
struct MBShareTextLink<Label: View>: View {
    let text: String
    var operation: MBWriteOperation = .sendDocument
    @Binding var refused: MBWriteOperation?
    @ViewBuilder var label: () -> Label

    @State private var subscription = SubscriptionManager.shared

    var body: some View {
        if subscription.isLapsed {
            Button { ReadOnlyGate.refuse(operation, into: $refused) } label: { label() }
        } else {
            ShareLink(item: text) { label() }
        }
    }
}

/// The multi-item form of `MBShareLink` — same rule, same substitution.
struct MBShareLinkItems<Label: View>: View {
    let items: [URL]
    var subject: Text? = nil
    var message: Text? = nil
    var operation: MBWriteOperation = .sendDocument
    @Binding var refused: MBWriteOperation?
    @ViewBuilder var label: () -> Label

    @State private var subscription = SubscriptionManager.shared

    var body: some View {
        if subscription.isLapsed {
            Button { ReadOnlyGate.refuse(operation, into: $refused) } label: { label() }
        } else {
            ShareLink(items: items, subject: subject, message: message) { label() }
        }
    }
}

// MARK: - GoldLifeMoney host environment

/// Canonical host modifier that wires every `GoldLifeMoney` view into `GLSmallBusiness`'s
/// standing banner slot (`MBSystemBannerInset`), live language (`MBLocalization.shared.language`),
/// and Law 6 read-only refusal alert + `Logger.access` line (`ReadOnlyGate.refuse`).
struct MBMoneyHostEnvironment: ViewModifier {
    @State private var readOnlyRefusal: MBWriteOperation?
    private let loc = MBLocalization.shared

    func body(content: Content) -> some View {
        let _ = loc.language
        content
            .environment(\.locale, loc.locale)
            .moneyBannerInset(MBSystemBannerInset())
            .environment(\.moneyWriteGate, MoneyWriteGate(
                canWrite: { !ReadOnlyGate.isReadOnly() },
                onRefusal: { rawOp in
                    let op = ReadOnlyGate.mapMoneyOperation(rawOp)
                    ReadOnlyGate.refuse(op, into: $readOnlyRefusal)
                },
                deleteModel: { ctx, model in
                    if let acc = model as? BankAccount {
                        ctx.deleteSynced(acc)
                    } else if let txn = model as? BankTransaction {
                        ctx.deleteSynced(txn)
                    } else if let sub = model as? RecurringSubscription {
                        ctx.deleteSynced(sub)
                    } else if let rule = model as? TransactionCategoryRule {
                        ctx.deleteSynced(rule)
                    } else {
                        ctx.delete(model) // GLSYNC-LINT-OK: fallback for non-synced PersistentModel
                    }
                }
            ))
            .readOnlyRefusalAlert($readOnlyRefusal)
    }
}

extension View {
    func mbMoneyHostEnvironment() -> some View {
        modifier(MBMoneyHostEnvironment())
    }
}
