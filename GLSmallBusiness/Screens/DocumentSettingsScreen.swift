//
//  DocumentSettingsScreen.swift
//  GLSmallBusiness
//
//  Settings → Document Messages: the wording used when documents go out — the
//  per-document subject/intro/closing templates, the warranty terms attached to
//  completion packages, and the receipt review-request switch. Transplanted
//  verbatim from MyCompanyFormScreen (owner restructure, 2026-08-22: one stop
//  source of truth for ALL settings is the Settings screen). Same Save-form
//  semantics as the business form it came from — nothing writes until Save.
//

import SwiftUI
import GoldLifeUI
import SwiftData

/// Settings pushes this host; the inner form needs the profile at init for its
/// State seeds, so the host resolves (or first-creates) the single profile.
struct DocumentSettingsScreen: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var profiles: [BusinessProfile]
    @State private var ensuredProfile = false
    /// The read-only stand-in for the singleton this screen renders from. Held (never inserted)
    /// only when a LAPSED app declined to bootstrap one — see the `.task` below.
    @State private var readOnlyPlaceholder: BusinessProfile?

    var body: some View {
        Group {
            if let profile = profiles.first ?? readOnlyPlaceholder {
                DocumentSettingsForm(profile: profile)
            } else {
                Color.clear
            }
        }
        // Titled on the host so the bar is named before the profile exists (law 57); the form
        // carries no title of its own, so it is applied once.
        .navigationTitle(GLScript.padded(mbLoc("Document Messages")))
        .toolbarTitleDisplayMode(.large)
        .task {
            // Create the single profile once, and only if there genuinely isn't one —
            // guarding against a transient empty state during sync inserting a dup.
            guard !ensuredProfile, profiles.isEmpty else { return }
            ensuredProfile = true
            // An EMPTY singleton so there is something to render; every field on it is written
            // through `save()`, which IS gated. But the insert itself is a write and it syncs, so
            // a lapsed app renders from a transient profile that is never inserted instead — the
            // screen still shows, nothing is stored, nothing goes to the server. Silent by design
            // (nobody tapped anything; the lapsed banner carries the explanation), which is exactly
            // why it goes through the gate rather than around it: the log line is not optional.
            guard ReadOnlyGate.allowsUnattended(.saveDocumentSettings) else {
                readOnlyPlaceholder = BusinessProfile()
                return
            }
            modelContext.insert(BusinessProfile())
        }
    }
}

private struct DocumentSettingsForm: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    let profile: BusinessProfile

    @AppStorage("gl.invoice.defaultAutoRemindersEnabled") private var defaultAutoRemindersEnabled = false
    @AppStorage("gl.invoice.defaultReminderStartTrigger") private var defaultStartTrigger = ReminderStartTrigger.oneWeekBeforeDue.rawValue
    @AppStorage("gl.invoice.defaultReminderFrequency") private var defaultFrequency = ReminderFrequency.weekly.rawValue

    @State private var includeReviewOnReceipts: Bool
    @State private var reviewsURL: String
    @State private var estimateMessageSubject: String
    @State private var messageIntro: String
    @State private var messageClosing: String
    @State private var invoiceMessageSubject: String
    @State private var invoiceMessageIntro: String
    @State private var invoiceMessageClosing: String
    @State private var receiptMessageSubject: String
    @State private var receiptMessageIntro: String
    @State private var receiptMessageClosing: String
    @State private var changeOrderMessageSubject: String
    @State private var changeOrderMessageIntro: String
    @State private var changeOrderMessageClosing: String
    @State private var packageMessageSubject: String
    @State private var packageMessageIntro: String
    @State private var packageMessageClosing: String
    @State private var completionMessageSubject: String
    @State private var completionMessageIntro: String
    @State private var completionMessageClosing: String
    @State private var warrantyText: String
    @State private var initialDigest: String?
    /// Set when a lapsed subscription refuses a write — the alert names it (ReadOnlyGate.swift).
    @State private var readOnlyRefusal: MBWriteOperation?
    /// A refusal BusinessProfileService threw that the form did not predict (DomainErrorAlert.swift).
    @State private var domainError: DomainError?

    private var digest: String {
        ([estimateMessageSubject, messageIntro, messageClosing, invoiceMessageSubject,
          invoiceMessageIntro, invoiceMessageClosing, receiptMessageSubject, receiptMessageIntro,
          receiptMessageClosing, changeOrderMessageSubject, changeOrderMessageIntro, changeOrderMessageClosing,
          packageMessageSubject, packageMessageIntro, packageMessageClosing, warrantyText,
          completionMessageSubject, completionMessageIntro, completionMessageClosing]
         + [String(includeReviewOnReceipts), reviewsURL]).joined(separator: "|")
    }
    private var isDirty: Bool { initialDigest.map { $0 != digest } ?? false }

    init(profile: BusinessProfile) {
        self.profile = profile
        _includeReviewOnReceipts = State(initialValue: profile.includeReviewLinkOnReceipts)
        _reviewsURL = State(initialValue: profile.reviewsURL)
        _estimateMessageSubject = State(initialValue: profile.estimateMessageSubject)
        _messageIntro = State(initialValue: profile.messageIntro)
        _messageClosing = State(initialValue: profile.messageClosing)
        _invoiceMessageSubject = State(initialValue: profile.invoiceMessageSubject)
        _invoiceMessageIntro = State(initialValue: profile.invoiceMessageIntro)
        _invoiceMessageClosing = State(initialValue: profile.invoiceMessageClosing)
        _receiptMessageSubject = State(initialValue: profile.receiptMessageSubject)
        _receiptMessageIntro = State(initialValue: profile.receiptMessageIntro)
        _receiptMessageClosing = State(initialValue: profile.receiptMessageClosing)
        _changeOrderMessageSubject = State(initialValue: profile.changeOrderMessageSubject)
        _changeOrderMessageIntro = State(initialValue: profile.changeOrderMessageIntro)
        _changeOrderMessageClosing = State(initialValue: profile.changeOrderMessageClosing)
        _packageMessageSubject = State(initialValue: profile.packageMessageSubject)
        _packageMessageIntro = State(initialValue: profile.packageMessageIntro)
        _packageMessageClosing = State(initialValue: profile.packageMessageClosing)
        _completionMessageSubject = State(initialValue: profile.completionMessageSubject)
        _completionMessageIntro = State(initialValue: profile.completionMessageIntro)
        _completionMessageClosing = State(initialValue: profile.completionMessageClosing)
        _warrantyText = State(initialValue: profile.warrantyText)
    }

    var body: some View {
        Form {
            // The toggle and the link it sends people to used to live on two
            // different screens, so switching it on could silently do nothing —
            // the value it depends on was somewhere the user could not see.
            Section {
                Toggle("Add review link to receipts", isOn: $includeReviewOnReceipts)
                if includeReviewOnReceipts {
                    TextField("Reviews link", text: $reviewsURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                }
            } footer: {
                Text(includeReviewOnReceipts && reviewsURL.trimmingCharacters(in: .whitespaces).isEmpty
                     ? mbLoc("Add your reviews link — without it, receipts go out with no review request.")
                     : mbLoc("Closes every payment receipt (email, text, and PDF) with a polished review request."))
            }

            Section {
                Toggle("Send automated reminders", isOn: $defaultAutoRemindersEnabled)
                if defaultAutoRemindersEnabled {
                    Picker("First reminder", selection: $defaultStartTrigger) {
                        ForEach(ReminderStartTrigger.allCases) { trigger in
                            Text(trigger.label).tag(trigger.rawValue)
                        }
                    }
                    Picker("Frequency", selection: $defaultFrequency) {
                        ForEach(ReminderFrequency.allCases) { freq in
                            Text(freq.label).tag(freq.rawValue)
                        }
                    }
                }
            } header: {
                InfoLabel("Automated Payment Reminders", info: "Automatically emails friendly payment reminders to clients from noreply@softwarebygl.com based on invoice due dates.", topic: "Automated Payment Reminders")
            } footer: {
                if defaultAutoRemindersEnabled {
                    Text("New invoices inherit these reminder defaults. You can still customize or turn them off for any individual invoice.")
                }
            }

            messageSection("Estimate message", topic: "Estimate message", document: "the estimate",
                           subject: $estimateMessageSubject, subjectHint: "Estimate # from your business",
                           intro: $messageIntro, introHint: EstimateMessage.defaultIntro,
                           closing: $messageClosing, closingHint: EstimateMessage.defaultClosing)

            messageSection("Invoice message", topic: "Invoice message", document: "the invoice",
                           subject: $invoiceMessageSubject, subjectHint: "Invoice # from your business",
                           intro: $invoiceMessageIntro, introHint: InvoiceMessage.defaultIntro,
                           closing: $invoiceMessageClosing, closingHint: InvoiceMessage.defaultClosing)

            messageSection("Receipt message", topic: "Receipt message", document: "the payment receipt",
                           subject: $receiptMessageSubject, subjectHint: "Receipt for invoice # from your business",
                           intro: $receiptMessageIntro, introHint: "Thank you for your payment. Your receipt is attached.",
                           closing: $receiptMessageClosing, closingHint: PaymentReceiptMessage.defaultClosing)

            messageSection("Change order message", topic: "Change order message", document: "the change order",
                           subject: $changeOrderMessageSubject, subjectHint: "Change order # from your business",
                           intro: $changeOrderMessageIntro, introHint: ChangeOrderMessage.defaultIntro,
                           closing: $changeOrderMessageClosing, closingHint: ChangeOrderMessage.defaultClosing)

            messageSection("Contractor package message", topic: "Contractor package message", document: "the contractor package",
                           subject: $packageMessageSubject, subjectHint: "Contractor package from your business",
                           intro: $packageMessageIntro, introHint: ContractorPackageMessage.defaultIntro,
                           closing: $packageMessageClosing, closingHint: ContractorPackageMessage.defaultClosing)
            messageSection("Completion package message", topic: "Completion package message", document: "the completion package",
                           subject: $completionMessageSubject, subjectHint: "Completion package from your business",
                           intro: $completionMessageIntro, introHint: CompletionPackageMessage.defaultIntro,
                           closing: $completionMessageClosing, closingHint: CompletionPackageMessage.defaultClosing)
            Section {
                TextField("Your warranty terms", text: $warrantyText, axis: .vertical)
                    .lineLimit(3...10)
            } header: {
                Text("Warranty")
            } footer: {
                Text("Free text — attached to each completion package. Coverage starts from the job’s completion date.")
                    .textCase(nil)
            }
        }
        .glFormBackground()
        .readOnlyRefusalAlert($readOnlyRefusal)
        .domainErrorAlert($domainError)
        .onAppear { if initialDigest == nil { initialDigest = digest } }
        .discardChangesGuard(isDirty: isDirty)
        // Title and large mode live on DocumentSettingsScreen (the host); the clearance stays here
        // so it lands on this Form's scroll content — the MyCompanyDetailScreen split.
        .contentMargins(.top, GLScript.titleClearance(for: GLScript.padded(mbLoc("Document Messages"))), for: .scrollContent)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save", action: save)
            }
        }
    }

    /// One document's editable text/email wording: an optional subject line plus the intro and
    /// closing paragraphs. Each shows its default as placeholder; blank falls back to that default.
    /// `topic` repeats `title` as a localization VALUE (a `LocalizedStringKey` can't be read
    /// back out) so each of the six ⓘ this builds gets its own VoiceOver label — otherwise the
    /// rotor on this screen lists six identical entries.
    private func messageSection(_ title: LocalizedStringKey, topic: String.LocalizationValue,
                                document: String.LocalizationValue,
                                subject: Binding<String>, subjectHint: String,
                                intro: Binding<String>, introHint: String,
                                closing: Binding<String>, closingHint: String) -> some View {
        Section {
            TextField("Subject — \(subjectHint)", text: subject, axis: .vertical)
                .lineLimit(1...2)
            TextField(introHint, text: intro, axis: .vertical)
                .lineLimit(2...6)
            TextField(closingHint, text: closing, axis: .vertical)
                .lineLimit(2...6)
        } header: {
            InfoLabel(title, info: "Subject line, then the message between the greeting and your signature, used when you send \(mbLoc(document)) by email or text. Leave any field blank to use the suggested wording shown.", topic: topic)
        }
    }

    private func save() {
        guard ReadOnlyGate.allows(.saveDocumentSettings, into: $readOnlyRefusal) else { return }
        // BusinessProfileService trims and saves — the same path the assistant uses. A transient
        // stand-in profile (the bootstrap was refused earlier) is adopted into the store.
        var draft = DocumentMessagesDraft()
        draft.includeReviewLinkOnReceipts = includeReviewOnReceipts
        draft.reviewsURL = reviewsURL
        draft.estimateSubject = estimateMessageSubject
        draft.estimateIntro = messageIntro
        draft.estimateClosing = messageClosing
        draft.invoiceSubject = invoiceMessageSubject
        draft.invoiceIntro = invoiceMessageIntro
        draft.invoiceClosing = invoiceMessageClosing
        draft.receiptSubject = receiptMessageSubject
        draft.receiptIntro = receiptMessageIntro
        draft.receiptClosing = receiptMessageClosing
        draft.changeOrderSubject = changeOrderMessageSubject
        draft.changeOrderIntro = changeOrderMessageIntro
        draft.changeOrderClosing = changeOrderMessageClosing
        draft.packageSubject = packageMessageSubject
        draft.packageIntro = packageMessageIntro
        draft.packageClosing = packageMessageClosing
        draft.completionSubject = completionMessageSubject
        draft.completionIntro = completionMessageIntro
        draft.completionClosing = completionMessageClosing
        draft.warrantyText = warrantyText
        do {
            try BusinessProfileService.updateDocumentMessages(draft, for: profile, in: modelContext)
        } catch {
            DomainError.present(error, readOnly: $readOnlyRefusal, domainError: $domainError)
            return
        }
        dismiss()
    }
}
