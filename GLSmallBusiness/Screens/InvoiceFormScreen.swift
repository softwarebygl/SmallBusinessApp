//
//  InvoiceFormScreen.swift
//  GLSmallBusiness
//
//  Created by Gold Life LLC on 5/28/26.
//

import SwiftUI
import GoldLifeUI
import SwiftData

// The line and group drafts are InvoiceLineDraft / InvoiceGroupDraft (Services/Domain/
// DocumentDrafts.swift), shared with InvoiceService and the assistant's tools.
private typealias InvoiceLineItemDraft = InvoiceLineDraft

/// Snapshot of everything the form edits, for unsaved-changes detection.
private struct InvoiceSnapshot: Equatable {
    var jobTitle: String
    var status: InvoiceStatus
    var paymentTerms: PaymentTerms
    var dueDate: Date
    var taxRatePercent: Double
    var discountType: AdjustmentType
    var discountValue: Double
    var customerNotes: String
    var terms: String
    var serviceStreet: String
    var serviceStreet2: String
    var serviceCity: String
    var serviceState: String
    var servicePostal: String
    var amountDueNow: Double
    var amountDueDetail: String
    var groups: [InvoiceGroupDraft]
    var includePayLink: Bool
    var includeZelle: Bool
    var autoRemindersEnabled: Bool
    var reminderStartTriggerRaw: String
    var reminderFrequencyRaw: String
}

struct InvoiceFormScreen: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @Query private var businessProfiles: [BusinessProfile]
    @Query(sort: \PriceSheetItem.name) private var priceSheetItems: [PriceSheetItem]

    // Type-ahead suggestion counts, fetched and counted once when the form opens (only the names,
    // never a live query over every group and line item; QA F153). History doesn't change while
    // the form is open.
    @State private var groupNameCountsCache: [String: Int] = [:]
    @State private var lineNameCountsCache: [String: Int] = [:]

    @FocusState private var focusedField: SuggestionField?

    private enum SuggestionField: Hashable {
        case groupName(UUID)
        case lineName(UUID)
    }

    private let editingInvoice: Invoice?
    private let customer: Customer?
    private let createdAt: Date
    /// When creating an invoice for a specific job (progress billing), the invoice is linked to it on save.
    private let linkedJob: ScheduledJob?

    @State private var jobTitle: String
    @State private var status: InvoiceStatus
    @State private var paymentTerms: PaymentTerms
    @State private var dueDate: Date
    @State private var taxRatePercent: Double
    @State private var discountType: AdjustmentType
    @State private var discountValue: Double
    @State private var customerNotes: String
    @State private var terms: String
    @State private var serviceStreet: String
    @State private var serviceStreet2: String
    @State private var serviceCity: String
    @State private var serviceState: String
    @State private var servicePostal: String
    @State private var amountDueNow: Double
    @State private var amountDueDetail: String
    @State private var groups: [InvoiceGroupDraft]
    @State private var initialSnapshot: InvoiceSnapshot?
    @State private var showingRecordPayment = false
    /// The paid-invoice lock explanation (PaidInvoiceLock.swift). InvoiceDetailScreen already
    /// refuses to open this form on a settled invoice; this covers the narrow race where the
    /// invoice becomes paid (a payment recorded here, or on another device) while the form is
    /// open, so a rebuild can never reach the wire behind the lock's back.
    @State private var showingPaidLock = false
    /// The pre-save confirmation for a discount that has wiped this invoice out
    /// (ZeroingDiscountGuard.swift) — the last point at which the paid-and-locked trap is cheap.
    @State private var showingZeroingDiscount = false
    /// The pre-save confirmation for an edit that would settle — and so lock — an invoice with
    /// payments on it (PaidLockSaveGuard, QA F85).
    @State private var showingPaidLockSave = false
    /// Resettable double-tap guard, in place of `SaveOnceButton`. Cancel in the zeroing-discount
    /// alert keeps this form open on purpose, so Save has to stay tappable afterwards — a button
    /// that latches dead would leave the person staring at the typo they were just asked about.
    @State private var isSaving = false
    /// Set when a lapsed subscription refuses a write — the alert names it (ReadOnlyGate.swift).
    @State private var readOnlyRefusal: MBWriteOperation?
    /// Per-invoice Stripe Pay-button choice. New invoices seed this from the business default in `.onAppear`.
    @State private var includePayLink: Bool
    @State private var didSeedPayLink = false
    /// Per-invoice Zelle choice. New invoices seed this from the business default in `.onAppear`.
    @State private var includeZelle: Bool
    @State private var didSeedZelle = false
    @State private var autoRemindersEnabled: Bool
    @State private var reminderStartTriggerRaw: String
    @State private var reminderFrequencyRaw: String
    @State private var includeJobPhotos = false
    @State private var includeJobDocuments = false
    @State private var includeJobExpenses = false
    /// A refusal InvoiceService threw that the form did not predict (DomainErrorAlert.swift).
    @State private var domainError: DomainError?
    /// A job from an OPTIONS estimate: its first invoice asks which option(s) the customer chose
    /// (the same picker Convert to Invoice uses) before carrying any work.
    @State private var showingOptionPicker = false
    @State private var chosenOptionIDs: Set<PersistentIdentifier> = []
    @State private var didAskForOption = false

    init(customer: Customer) {
        self.customer = customer
        self.editingInvoice = nil
        self.linkedJob = nil
        let now = Date.now
        self.createdAt = now
        _jobTitle = State(initialValue: "")
        _status = State(initialValue: .draft)
        _paymentTerms = State(initialValue: .net30)
        _dueDate = State(initialValue: PaymentTerms.net30.dueDate(from: now) ?? now)
        _taxRatePercent = State(initialValue: 0)
        _discountType = State(initialValue: .none)
        _discountValue = State(initialValue: 0)
        _customerNotes = State(initialValue: "")
        _terms = State(initialValue: "")
        let sAddr = customer.serviceAddress
        _serviceStreet = State(initialValue: sAddr.street1)
        _serviceStreet2 = State(initialValue: sAddr.street2 ?? "")
        _serviceCity = State(initialValue: sAddr.city)
        _serviceState = State(initialValue: sAddr.state)
        _servicePostal = State(initialValue: sAddr.postalCode)
        _amountDueNow = State(initialValue: 0)
        _amountDueDetail = State(initialValue: "")
        _groups = State(initialValue: [InvoiceGroupDraft()])
        _includePayLink = State(initialValue: false)   // seeded from the business default in .onAppear
        _includeZelle = State(initialValue: false)     // seeded from the business default in .onAppear
        _autoRemindersEnabled = State(initialValue: UserDefaults.standard.bool(forKey: "gl.invoice.defaultAutoRemindersEnabled"))
        _reminderStartTriggerRaw = State(initialValue: UserDefaults.standard.string(forKey: "gl.invoice.defaultReminderStartTrigger") ?? ReminderStartTrigger.oneWeekBeforeDue.rawValue)
        _reminderFrequencyRaw = State(initialValue: UserDefaults.standard.string(forKey: "gl.invoice.defaultReminderFrequency") ?? ReminderFrequency.weekly.rawValue)
    }

    /// Create a new invoice that BILLS a specific job (progress billing) — prefills the title + service
    /// address from the job and links `invoice.job` on save.
    init(customer: Customer, job: ScheduledJob) {
        self.customer = customer
        self.editingInvoice = nil
        self.linkedJob = job
        let now = Date.now
        self.createdAt = now
        // Pre-fill the work from the document that created the job, so it isn't re-entered (first invoice
        // only — see InvoiceService.jobBillingDraft). An options estimate carries no option until the
        // picker (shown on appear) says which one the customer chose.
        let carry = InvoiceService.jobBillingDraft(for: job)
        _jobTitle = State(initialValue: carry.jobTitle)
        _status = State(initialValue: .draft)
        _paymentTerms = State(initialValue: .net30)
        _dueDate = State(initialValue: PaymentTerms.net30.dueDate(from: now) ?? now)
        _taxRatePercent = State(initialValue: carry.taxRatePercent)
        _discountType = State(initialValue: carry.discountType)
        _discountValue = State(initialValue: carry.discountValue)
        _customerNotes = State(initialValue: carry.customerNotes)
        _terms = State(initialValue: carry.terms)
        _serviceStreet = State(initialValue: carry.serviceAddress.street1)
        _serviceStreet2 = State(initialValue: carry.serviceAddress.street2 ?? "")
        _serviceCity = State(initialValue: carry.serviceAddress.city)
        _serviceState = State(initialValue: carry.serviceAddress.state)
        _servicePostal = State(initialValue: carry.serviceAddress.postalCode)
        _amountDueNow = State(initialValue: carry.amountDueNow)      // a classic estimate's deposit
        _amountDueDetail = State(initialValue: carry.amountDueDetail)
        _groups = State(initialValue: carry.groups)
        _includePayLink = State(initialValue: false)   // seeded from the business default in .onAppear
        _includeZelle = State(initialValue: false)     // seeded from the business default in .onAppear
        _autoRemindersEnabled = State(initialValue: UserDefaults.standard.bool(forKey: "gl.invoice.defaultAutoRemindersEnabled"))
        _reminderStartTriggerRaw = State(initialValue: UserDefaults.standard.string(forKey: "gl.invoice.defaultReminderStartTrigger") ?? ReminderStartTrigger.oneWeekBeforeDue.rawValue)
        _reminderFrequencyRaw = State(initialValue: UserDefaults.standard.string(forKey: "gl.invoice.defaultReminderFrequency") ?? ReminderFrequency.weekly.rawValue)
    }

    init(editing invoice: Invoice) {
        self.customer = invoice.customer
        self.editingInvoice = invoice
        self.linkedJob = nil
        self.createdAt = invoice.createdAt
        _jobTitle = State(initialValue: invoice.jobTitle)
        _status = State(initialValue: invoice.status)
        _paymentTerms = State(initialValue: invoice.paymentTerms)
        _dueDate = State(initialValue: invoice.dueDate)
        _taxRatePercent = State(initialValue: invoice.taxRatePercent)
        _discountType = State(initialValue: invoice.discountType)
        _discountValue = State(initialValue: invoice.discountValue)
        _customerNotes = State(initialValue: invoice.customerNotes)
        _terms = State(initialValue: invoice.terms)
        _serviceStreet = State(initialValue: invoice.serviceAddress.street1)
        _serviceStreet2 = State(initialValue: invoice.serviceAddress.street2 ?? "")
        _serviceCity = State(initialValue: invoice.serviceAddress.city)
        _serviceState = State(initialValue: invoice.serviceAddress.state)
        _servicePostal = State(initialValue: invoice.serviceAddress.postalCode)
        _amountDueNow = State(initialValue: invoice.amountDueNow)
        _amountDueDetail = State(initialValue: invoice.amountDueDetail)
        let drafts = invoice.sortedGroups.map { InvoiceGroupDraft(from: $0) }
        _groups = State(initialValue: drafts.isEmpty ? [InvoiceGroupDraft()] : drafts)
        _includePayLink = State(initialValue: invoice.includePayLink)
        _includeZelle = State(initialValue: invoice.includeZelle)
        _autoRemindersEnabled = State(initialValue: invoice.autoRemindersEnabled)
        _reminderStartTriggerRaw = State(initialValue: invoice.reminderStartTriggerRaw)
        _reminderFrequencyRaw = State(initialValue: invoice.reminderFrequencyRaw)
    }

    /// Mirrors `Invoice.totals`: the overall discount applies only to ORIGINAL work; change-order line
    /// items are billed at full price and full tax on top, so the preview matches the saved invoice (and
    /// the signed change order) exactly.
    private var totals: EstimateTotals {
        InvoiceMath.totals(groups: groups, taxRatePercent: taxRatePercent,
                           discountType: discountType, discountValue: discountValue)
    }

    private var canSave: Bool {
        !jobTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The invoice we're editing was deleted out from under us (e.g. its customer was deleted on
    /// another device). `save()` bails on it.
    private var editingInvoiceVanished: Bool {
        guard let editingInvoice else { return false }
        return !modelContext.stillStores(editingInvoice)
    }

    /// This invoice's money is settled, so `save()` refuses and explains instead.
    private var editingInvoiceIsMoneyLocked: Bool { editingInvoice?.isMoneyLocked ?? false }

    /// Either reason `save()` will refuse before it writes anything. Read by `attemptSave()` so a
    /// refused save is never asked to confirm something it isn't going to do.
    private var saveIsBlocked: Bool { editingInvoiceVanished || editingInvoiceIsMoneyLocked }

    private var currentSnapshot: InvoiceSnapshot {
        InvoiceSnapshot(jobTitle: jobTitle, status: status, paymentTerms: paymentTerms, dueDate: dueDate,
                        taxRatePercent: taxRatePercent, discountType: discountType, discountValue: discountValue,
                        customerNotes: customerNotes, terms: terms, serviceStreet: serviceStreet,
                        serviceStreet2: serviceStreet2,
                        serviceCity: serviceCity, serviceState: serviceState, servicePostal: servicePostal,
                        amountDueNow: amountDueNow, amountDueDetail: amountDueDetail, groups: groups,
                        includePayLink: includePayLink, includeZelle: includeZelle, autoRemindersEnabled: autoRemindersEnabled,
                        reminderStartTriggerRaw: reminderStartTriggerRaw, reminderFrequencyRaw: reminderFrequencyRaw)
    }
    private var isDirty: Bool { initialSnapshot.map { $0 != currentSnapshot } ?? false }

    var body: some View {
        Form {
            Section("Invoice") {
                TextField("Job title", text: $jobTitle)
                Picker("Status", selection: $status) {
                    ForEach(InvoiceStatus.allCases) { Text($0.label).tag($0) }
                }
                Picker("Terms", selection: $paymentTerms) {
                    ForEach(PaymentTerms.allCases) { Text($0.label).tag($0) }
                }
                .onChange(of: paymentTerms) { _, newTerms in
                    if let computed = newTerms.dueDate(from: createdAt) {
                        dueDate = computed
                    }
                }
                if paymentTerms == .custom {
                    DatePicker("Due date", selection: $dueDate, displayedComponents: .date)
                } else {
                    LabeledContent("Due date", value: dueDate.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted).locale(MBLocalization.currentLocale)))
                }
            }

            Section {
                GLAddressField("Street", street: $serviceStreet, city: $serviceCity, state: $serviceState, zip: $servicePostal)
                    .textContentType(.streetAddressLine1)
                TextField("Apt / Suite (optional)", text: $serviceStreet2)
                    .textContentType(.streetAddressLine2)
                TextField("City", text: $serviceCity)
                    .textContentType(.addressCity)
                TextField("State", text: $serviceState)
                    .textContentType(.addressState)
                    .textInputAutocapitalization(.characters)
                TextField("ZIP", text: $servicePostal)
                    .textContentType(.postalCode)
                    #if !os(macOS)
                    .keyboardType(.numberPad)
                    #endif
            } header: {
                InfoLabel("Service Address", info: "The specific job site or lot this invoice is for. Optional — leave blank if it's at the customer's own address.", topic: "Service Address")
            }

            ForEach($groups) { $group in
                groupSection($group)
            }

            Section {
                Button {
                    groups.append(InvoiceGroupDraft())
                } label: {
                    Label("Add group", systemImage: "plus.square.on.square")
                }
            }

            Section("Tax") {
                LabeledContent("Tax rate (%)") {
                    AutoClearNumberField(placeholder: "0", value: $taxRatePercent, style: .number, clearsAt: 0,
                                         maxValue: 100)   // a tax rate over 100% is a typo; the service refuses it
                        .multilineTextAlignment(.trailing)
                }
                Text("Applied only to line items marked taxable.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            adjustmentSection(title: mbLoc("Discount"), type: $discountType, value: $discountValue)

            Section {
                LabeledContent("Amount due now") {
                    AutoClearNumberField(placeholder: "0", value: $amountDueNow, style: .currency, clearsAt: 0,
                                         wholeCents: true)
                        .multilineTextAlignment(.trailing)
                }
                TextField("What it's for (e.g. Deposit to start)", text: $amountDueDetail)
            } header: {
                InfoLabel("Deposit or milestone", info: "Bill a deposit or a milestone now instead of the whole job. Leave it at $0 to request the full balance.", topic: "Deposit or milestone")
            }

            Section("Notes") {
                TextField("Notes for the customer", text: $customerNotes, axis: .vertical)
                    .lineLimit(2...6)
                TextField("Terms & conditions", text: $terms, axis: .vertical)
                    .lineLimit(2...6)
            }

            // The row is ALWAYS here now. It used to be hidden until Stripe was
            // already connected, so the invoice screen — the one place a contractor
            // is thinking about getting paid — never mentioned that card payment
            // existed. A feature you only see after you've found it teaches nobody.
            Section {
                if businessProfiles.first?.stripeIsConnected == true {
                    Toggle(isOn: $includePayLink) {
                        Label("Include Pay button", systemImage: "link")
                    }
                } else {
                    NavigationLink {
                        StripeConnectScreen()
                    } label: {
                        Label("Let customers pay by card", systemImage: "creditcard")
                    }
                }
            } footer: {
                Text(businessProfiles.first?.stripeIsConnected == true
                     ? mbLoc("Add a “Pay this invoice” button so your customer can pay by card. Starts from your Get Paid default; you can change it here or later.")
                     : mbLoc("Set up card payments once, and every invoice can carry a “Pay this invoice” button."))
            }

            Section {
                if businessProfiles.first?.zelleIsConfigured == true {
                    Toggle(isOn: $includeZelle) {
                        Label("Include Zelle details", systemImage: "qrcode")
                    }
                } else {
                    NavigationLink {
                        ZelleConnectScreen()
                    } label: {
                        Label("Let customers pay with Zelle", systemImage: "qrcode")
                    }
                }
            } footer: {
                Text(businessProfiles.first?.zelleIsConfigured == true
                     ? mbLoc("Include your Zelle tag, contact info and QR code so customers can pay directly.")
                     : mbLoc("Set up your Zelle details once, and your invoices can include your payment info and QR code."))
            }

            Section {
                Toggle("Send automated reminders", isOn: $autoRemindersEnabled)
                if autoRemindersEnabled {
                    Picker("First reminder", selection: $reminderStartTriggerRaw) {
                        ForEach(ReminderStartTrigger.allCases) { trigger in
                            Text(trigger.label).tag(trigger.rawValue)
                        }
                    }
                    Picker("Frequency", selection: $reminderFrequencyRaw) {
                        ForEach(ReminderFrequency.allCases) { freq in
                            Text(freq.label).tag(freq.rawValue)
                        }
                    }
                }
            } header: {
                InfoLabel("Automated Payment Reminders", info: "Automatically emails friendly payment reminders to clients from noreply@softwarebygl.com based on invoice due dates.", topic: "Automated Payment Reminders")
            } footer: {
                if autoRemindersEnabled {
                    Text("Sent automatically from noreply@softwarebygl.com until the balance is paid.")
                }
            }

            if linkedJob != nil {
                Section {
                    Toggle(isOn: $includeJobPhotos) {
                        Label("Include job photos", systemImage: "photo.on.rectangle")
                    }
                    Toggle(isOn: $includeJobDocuments) {
                        Label("Include job documents", systemImage: "doc.on.doc")
                    }
                    Toggle(isOn: $includeJobExpenses) {
                        Label("Include job expenses", systemImage: "receipt")
                    }
                } header: {
                    Text("Job Attachments")
                } footer: {
                    Text(mbLoc("Attach copies of photos, documents, or expense receipts from this job to the invoice. Kept off by default for privacy."))
                }
            }

            summarySection
        }
        .glFormBackground()
        .readOnlyRefusalAlert($readOnlyRefusal)
        .domainErrorAlert($domainError)
        .task { loadNameSuggestions() }
        .navigationTitle(GLScript.padded(editingInvoice == nil ? mbLoc("New Invoice") : mbLoc("Edit Invoice")))
        .toolbarTitleDisplayMode(.large)
        .contentMargins(.top, GLScript.titleClearance(for: GLScript.padded(editingInvoice == nil ? mbLoc("New Invoice") : mbLoc("Edit Invoice"))), for: .scrollContent)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { attemptSave() }.disabled(!canSave || isSaving)
            }
            if editingInvoice != nil {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showingRecordPayment = true } label: {
                        Label("Record payment", systemImage: "dollarsign.circle")
                    }
                    .accessibilityLabel("Record payment")
                }
            }
        }
        .sheet(isPresented: $showingRecordPayment) {
            if let editingInvoice {
                RecordPaymentSheet(invoice: editingInvoice).glAppearance(colorScheme)
            }
        }
        .onAppear {
            // Seed a new invoice's Pay-button choice from the business default BEFORE snapshotting, so an
            // untouched new invoice isn't flagged as having unsaved changes.
            if editingInvoice == nil, !didSeedPayLink {
                includePayLink = businessProfiles.first?.payLinkDefaultOn ?? true
                didSeedPayLink = true
            }
            if editingInvoice == nil, !didSeedZelle {
                includeZelle = (businessProfiles.first?.zelleIsConfigured == true) ? (businessProfiles.first?.zelleDefaultOn ?? false) : false
                didSeedZelle = true
            }
            if initialSnapshot == nil { initialSnapshot = currentSnapshot }
            if let linkedJob, !didAskForOption, InvoiceService.jobBillingNeedsOptionChoice(for: linkedJob) {
                didAskForOption = true
                showingOptionPicker = true
            }
        }
        .sheet(isPresented: $showingOptionPicker) {
            if let estimate = linkedJob?.estimate {
                EstimateOptionPickerSheet(estimate: estimate, chosenIDs: $chosenOptionIDs, confirmTitle: "Done",
                                          onCancel: { showingOptionPicker = false },
                                          onConfirm: applyChosenOptions)
                    .glAppearance(colorScheme)
            }
        }
        .paidInvoiceLockAlert(isPresented: $showingPaidLock)
        .zeroingDiscountInvoiceAlert(isPresented: $showingZeroingDiscount, onSave: save)
        .paidLockSaveAlert(isPresented: $showingPaidLockSave, action: "Save", onConfirm: save)
        .discardChangesGuard(isDirty: isDirty)
    }

    /// Fills the work from the option(s) the customer chose — only those, with no estimate discount
    /// or deposit (InvoiceService.jobBillingDraft). That is where this invoice starts, so it is not
    /// counted as an unsaved change.
    private func applyChosenOptions() {
        showingOptionPicker = false
        guard let linkedJob else { return }
        let carry = InvoiceService.jobBillingDraft(for: linkedJob, chosenGroupIDs: chosenOptionIDs)
        groups = carry.groups
        initialSnapshot = currentSnapshot
    }

    private func groupSection(_ group: Binding<InvoiceGroupDraft>) -> some View {
        Section {
            if group.wrappedValue.changeOrder != nil {
                // The name IS the change order’s number and title, and that order rebuilds this
                // whole group from scratch on every edit (ChangeOrder.resyncInvoiceItems), so it is
                // shown here, never edited. Editing it also had teeth: clearing it dropped the group
                // out of `save()`’s keep filter below, which deletes the billed items — on this
                // phone and on the wire — while the order still reads as added to the invoice.
                Text(group.wrappedValue.name.isEmpty ? mbLoc("Group") : group.wrappedValue.name)
                    .font(.headline)
            } else {
                nameField(
                    group.name,
                    placeholder: "Group name (e.g. Master Shower)",
                    field: .groupName(group.wrappedValue.id),
                    counts: groupNameCountsCache
                )
            }
            TextField("Note (e.g. 5×3×8)", text: group.note)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            ForEach(group.lines) { $line in
                lineEditor($line) {
                    group.lines.wrappedValue.removeAll { $0.id == line.id }
                }
                // A change-order line is owned by its order — the row is read-only, but the swipe
                // was not, and the in-place save really deletes an unclaimed row (here and on the
                // wire) while the order stays marked applied, so the invoice would bill less than
                // the signed change order. Disabling delete on the ROW keeps its offset out of the
                // `.onDelete` below; those items come off by editing the order itself.
                .deleteDisabled(line.fromChangeOrder)
            }
            .onDelete { group.lines.wrappedValue.remove(atOffsets: $0) }

            // Ordinary scope only. A change-order group’s membership belongs to the order, and a
            // line typed in here is destroyed the next time that order is edited (resyncInvoiceItems
            // rebuilds the group) — the same rule the group footer below already states.
            if group.wrappedValue.changeOrder == nil {
                HStack {
                    Button {
                        group.lines.wrappedValue.append(InvoiceLineItemDraft())
                    } label: {
                        Label("Add line item", systemImage: "plus.circle.fill")
                    }

                    if !priceSheetItems.isEmpty {
                        Spacer()
                        Menu {
                            ForEach(priceSheetItems) { item in
                                Button(item.name) {
                                    group.lines.wrappedValue.append(InvoiceLineItemDraft(priceSheetItem: item))
                                }
                            }
                        } label: {
                            Label("From Price Sheet", systemImage: "tag")
                        }
                    }
                }
            }

            HStack {
                Spacer()
                Text("Group subtotal: \(group.wrappedValue.subtotal.formatted(.appMoney))")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if group.wrappedValue.changeOrder != nil {
                // Removing a change-order group here would leave the order marked applied with nothing
                // billed — it comes off by declining or deleting the change order itself.
                Text("From a change order — remove it by declining or deleting that order.")
                    .font(.caption).foregroundStyle(.secondary)
            } else if groups.count > 1 {
                Button(role: .destructive) {
                    groups.removeAll { $0.id == group.wrappedValue.id }
                } label: {
                    Label("Remove group", systemImage: "trash")
                }
            }
        } header: {
            Text(group.wrappedValue.name.isEmpty ? mbLoc("Group") : group.wrappedValue.name)
        }
    }

    @ViewBuilder
    private func lineEditor(_ line: Binding<InvoiceLineItemDraft>, onRemove: @escaping () -> Void) -> some View {
        if line.wrappedValue.fromChangeOrder {
            changeOrderLineRow(line.wrappedValue)
        } else {
            editableLine(line, onRemove: onRemove)
        }
    }

    /// Read-only row for a line pushed from a change order: those items are owned by the order and
    /// re-synced from it whenever it changes, so invoice-side edits would be clobbered (and a credit's
    /// negative price can't round-trip a money field). Edit or remove them on the change order itself.
    private func changeOrderLineRow(_ line: InvoiceLineItemDraft) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(line.name.isEmpty ? mbLoc("Change-order item") : line.name)
            if !line.details.isEmpty {
                Text(line.details).font(.subheadline).foregroundStyle(.secondary)
            }
            HStack {
                Text("\(line.quantity.formatted(.number)) \(line.unit.abbreviation) × \(line.unitPrice.formatted(.appMoney))")
                    .font(.footnote).foregroundStyle(.secondary)
                Spacer()
                Text(line.signedLineTotal.formatted(.appMoney))
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Text("From a change order — edit or remove it there.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    private func editableLine(_ line: Binding<InvoiceLineItemDraft>, onRemove: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            nameField(
                line.name,
                placeholder: "Item name",
                field: .lineName(line.wrappedValue.id),
                counts: lineNameCountsCache
            )
            TextField("Description (optional)", text: line.details)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            HStack {
                AutoClearNumberField(placeholder: "Qty", value: line.quantity, style: .number, clearsAt: 1)
                    .frame(maxWidth: 70)
                Picker("Unit", selection: line.unit) {
                    ForEach(UnitOfMeasure.allCases) { Text($0.abbreviation).tag($0) }
                }
                .labelsHidden()
                Spacer()
                Text("×").foregroundStyle(.secondary)
                AutoClearNumberField(placeholder: "Price", value: line.unitPrice, style: .currency, clearsAt: 0)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 110)
            }

            Picker("Type", selection: line.kind) {
                ForEach(LineItemKind.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .onChange(of: line.kind.wrappedValue) { _, newKind in
                line.isTaxable.wrappedValue = newKind.defaultTaxable
            }

            Toggle("Taxable", isOn: line.isTaxable)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Picker("Discount", selection: line.discountType) {
                        Text("No discount").tag(AdjustmentType.none)
                        Text("% off").tag(AdjustmentType.percentage)
                        Text("$ off").tag(AdjustmentType.fixed)
                    }
                    .pickerStyle(.menu)
                    .accessibilityIdentifier("lineDiscountPicker")
                    Spacer()
                    if line.discountType.wrappedValue != .none {
                        // A PERCENT off caps at 100 — 100% already takes the line to zero, so
                        // 150 buys nothing but a wrong-looking number on a document the customer
                        // reads. A DOLLAR amount has no ceiling: $150 off is an ordinary figure.
                        AutoClearNumberField(placeholder: "0", value: line.discountValue, style: .number, clearsAt: 0,
                                             maxValue: line.discountType.wrappedValue == .percentage ? 100 : nil)
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: 90)
                    }
                }
                if line.discountType.wrappedValue == .percentage {
                    Text("Percentages stop at 100% — that’s the whole amount.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            HStack {
                Button(role: .destructive, action: onRemove) {
                    Label("Remove", systemImage: "trash")
                        .font(.footnote)
                }
                .buttonStyle(.borderless)
                Spacer()
                if line.wrappedValue.lineDiscount > 0 {
                    Text("−\(line.wrappedValue.lineDiscount.formatted(.appMoney))")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Text("Line total: \(line.wrappedValue.lineTotal.formatted(.appMoney))")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Name fields with type-ahead suggestions

    /// The names this business has used on invoices AND estimates, fetched once.
    private func loadNameSuggestions() {
        groupNameCountsCache = LineItemNameSuggestions.counts(
            LineItemNameSuggestions.storedNames(\InvoiceGroup.name, in: modelContext)
                + LineItemNameSuggestions.storedNames(\EstimateGroup.name, in: modelContext))
        lineNameCountsCache = LineItemNameSuggestions.counts(
            LineItemNameSuggestions.storedNames(\InvoiceLineItem.name, in: modelContext)
                + LineItemNameSuggestions.storedNames(\EstimateLineItem.name, in: modelContext))
    }

    @ViewBuilder
    private func nameField(_ text: Binding<String>, placeholder: LocalizedStringKey, field: SuggestionField, counts: [String: Int]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            TextField(placeholder, text: text)
                .font(.headline)
                .focused($focusedField, equals: field)

            if focusedField == field {
                ForEach(LineItemNameSuggestions.matching(text.wrappedValue, counts: counts), id: \.self) { name in
                    Button {
                        text.wrappedValue = name
                        focusedField = nil
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "arrow.up.left.circle")
                                .foregroundStyle(GLTheme.accentFill)
                            Text(name)
                                .foregroundStyle(.primary)
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .font(.subheadline)
                    .padding(.top, 10)
                }
            }
        }
    }

    /// One document-level adjustment (Discount here and on the invoice; Deposit on estimates).
    ///
    /// A PERCENT caps at 100 at the keyboard. `EstimateTotals` already clamps a 150% discount to
    /// the whole subtotal, so 150 and 100 bill the identical total — but someone who meant 15%
    /// and typed 150 never learned that, and the number they read back was wrong. The cap makes
    /// the clamp visible while it can still be fixed; the money math is untouched (it agrees
    /// bit-for-bit with the server's money.ts and is pinned by shared conformance vectors).
    /// The Deposit field is capped by the same line, deliberately: a deposit is already clamped
    /// to 0...total, so >100% asks for more than the whole job and bills exactly the whole job.
    /// A FIXED amount is never capped — it is dollars, and $150 off is an ordinary figure.
    private func adjustmentSection(title: String, type: Binding<AdjustmentType>, value: Binding<Double>) -> some View {
        Section {
            Picker(title, selection: type) {
                ForEach(AdjustmentType.allCases) { Text($0.label).tag($0) }
            }
            if type.wrappedValue != .none {
                LabeledContent(type.wrappedValue == .percentage ? "\(title) (%)" : "\(title) amount") {
                    AutoClearNumberField(placeholder: "0", value: value, style: .number, clearsAt: 0,
                                         maxValue: type.wrappedValue == .percentage ? 100 : nil)
                        .multilineTextAlignment(.trailing)
                }
            }
        } header: {
            // `title` arrives already localized (mbLoc at the call site), so Text(String) — which
            // does not re-localize — is the correct initializer, same as the old Section(title).
            Text(title)
        } footer: {
            if type.wrappedValue == .percentage {
                Text("Percentages stop at 100% — that’s the whole amount.")
            }
        }
    }

    private var summarySection: some View {
        Section("Summary") {
            summaryRow(mbLoc("Subtotal"), totals.subtotal)
            if totals.discount > 0 { summaryRow(mbLoc("Discount"), -totals.discount) }
            if totals.tax > 0 { summaryRow(mbLoc("Tax"), totals.tax) }
            summaryRow(mbLoc("Total"), totals.total, bold: true)
        }
    }

    private func summaryRow(_ label: String, _ amount: Double, bold: Bool = false) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(amount.formatted(.appMoney))
        }
        .fontWeight(bold ? .bold : .regular)
    }

    /// Save, unless the totals show a discount has wiped the invoice out — then ask first.
    ///
    /// The confirmation is skipped when `save()` is going to refuse anyway (a vanished or already
    /// paid invoice), for two reasons. It would be asking about a save that isn't happening; and
    /// the refusal raises its own alert, so chaining them puts a second alert up while the first is
    /// still dismissing, which iOS can swallow — leaving the person with no explanation at all.
    /// The already-paid case is exactly the stuck $0 invoice this guard exists to prevent, so it is
    /// the likeliest collision, not a theoretical one.
    ///
    /// Then the lock preview (QA F85): an edit that leaves the payments already recorded covering
    /// the new total settles the invoice, and a settled invoice locks — so it asks first, and the
    /// saved invoice shows any credit due. The zeroing-discount alert already says the same.
    private func attemptSave() {
        if saveIsBlocked {
            save()
            return
        }
        if ZeroingDiscountGuard.fires(totals: totals, discountType: discountType) {
            showingZeroingDiscount = true
            return
        }
        if PaidLockSaveGuard.fires(MoneyLockPreview.wouldLock(editingInvoice, applying: makeDraft()),
                                   amountPaid: editingInvoice?.amountPaid ?? 0) {
            showingPaidLockSave = true
            return
        }
        save()
    }

    /// The form as an `InvoiceDraft` — what `save()` hands InvoiceService, and what the lock
    /// preview measures.
    private func makeDraft() -> InvoiceDraft {
        var draft = InvoiceDraft()
        draft.jobTitle = jobTitle
        draft.status = status
        draft.paymentTerms = paymentTerms
        draft.dueDate = dueDate
        draft.taxRatePercent = taxRatePercent
        draft.discountType = discountType
        draft.discountValue = discountValue
        draft.customerNotes = customerNotes
        draft.terms = terms
        draft.serviceAddress = Address(street1: serviceStreet,
                                       street2: serviceStreet2.isEmpty ? nil : serviceStreet2,
                                       city: serviceCity,
                                       state: serviceState, postalCode: servicePostal)
        draft.amountDueNow = amountDueNow
        draft.amountDueDetail = amountDueDetail
        draft.includePayLink = includePayLink
        draft.includeZelle = includeZelle
        draft.autoRemindersEnabled = autoRemindersEnabled
        draft.reminderStartTriggerRaw = reminderStartTriggerRaw
        draft.reminderFrequencyRaw = reminderFrequencyRaw
        draft.groups = groups
        return draft
    }

    private func save() {
        // If the invoice we're editing was deleted out from under us (e.g. its customer was deleted on
        // another device), don't write line items onto a tombstoned object — bail instead of orphaning
        // the edits.
        if editingInvoiceVanished {
            dismiss()
            return
        }
        // On a paid invoice the server refuses every edit and delete inside it (paid_locked), so a
        // save would land on this phone and never on the server — the silent-divergence bug class
        // PaidInvoiceLock.swift exists to prevent. Explain and keep the edits on screen.
        if editingInvoiceIsMoneyLocked {
            showingPaidLock = true
            return
        }
        // A fast double-tap (toolbar Save, or Save in the zeroing-discount alert) can fire again
        // during the dismiss animation and insert a second invoice. Latched here rather than in
        // `SaveOnceButton` so the two refusals above stay retryable — same shape as
        // ScheduleJobSheet.save().
        guard !isSaving else { return }
        // Lapsed = 100% read-only. Refused BEFORE the latch and before any property is touched:
        // SwiftData autosaves, so a half-applied save would persist even though the form said no,
        // and a latched Save would stay dead behind the alert that invites a retry.
        guard ReadOnlyGate.allows(.saveInvoice, into: $readOnlyRefusal) else { return }
        isSaving = true
        // InvoiceService validates, numbers, copies the chosen job files, reconciles the rows in
        // place and saves — the same path the assistant uses (DocumentDrafts.swift).
        let draft = makeDraft()
        do {
            if let editingInvoice {
                try InvoiceService.update(editingInvoice, with: draft, origin: .screen, in: modelContext)
            } else if let customer {
                try InvoiceService.create(
                    draft, for: customer, job: linkedJob,
                    attachments: JobAttachmentSelection(photos: includeJobPhotos, documents: includeJobDocuments,
                                                        expenses: includeJobExpenses),
                    origin: .screen, in: modelContext)
            } else {
                throw DomainError.recordNotFound
            }
        } catch DomainError.paidLocked {
            // Paid between the check above and here (a payment synced in): the same explanation.
            isSaving = false
            showingPaidLock = true
            return
        } catch {
            isSaving = false
            DomainError.present(error, readOnly: $readOnlyRefusal, domainError: $domainError)
            return
        }
        dismiss()
    }
}

/// QA F85: a screen save that would settle — and so money-lock — an invoice that already has
/// payments on it asks first. Cutting an invoice to (or below) what the customer has paid, by an
/// edit or a credit change order, used to read Paid and lock without a word, and the money owed
/// back showed nowhere. The verdict is `MoneyLockPreview`'s (the assistant's own question); this
/// adds only the screens' rule: ask when money has been paid. A $0 comp with nothing paid is a
/// deliberate act and saves without a word (the zeroing-discount alert covers a typo'd discount).
/// Used by the invoice form, the change-order form and both "Add to invoice" buttons.
nonisolated enum PaidLockSaveGuard {
    static func fires(_ wouldLock: Bool, amountPaid: Double) -> Bool {
        wouldLock && amountPaid > DomainMoney.epsilon
    }
}

extension View {
    /// The confirmation `PaidLockSaveGuard` raises. Cancel is the easy way out (`.cancel`: bold,
    /// Escape, a tap outside); the action is plain, not destructive — settling an invoice on
    /// purpose is a normal thing to do.
    func paidLockSaveAlert(isPresented: Binding<Bool>, action: LocalizedStringKey,
                           onConfirm: @escaping () -> Void) -> some View {
        alert("This marks the invoice paid", isPresented: isPresented) {
            Button(action) { onConfirm() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("The payments already recorded cover the new total, so the invoice will read paid. Paid invoices can’t be edited or deleted. If the customer paid more than the new total, the invoice shows the credit due.")
        }
    }
}

#Preview {
    InvoiceFormScreen(customer: Customer(firstName: "Jane", lastName: "Doe"))
        .modelContainer(for: [Customer.self, Invoice.self], inMemory: true)
}
