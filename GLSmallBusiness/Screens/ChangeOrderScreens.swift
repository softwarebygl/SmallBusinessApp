//
//  ChangeOrderScreens.swift
//  GLSmallBusiness
//
//  Create / edit a change order, and a detail sheet to preview, send, approve, and (once approved)
//  push it onto the invoice as a new line-item group.
//

import SwiftUI
import GoldLifeUI
import GoldLifeAI
import SwiftData
import MessageUI

// MARK: - Form

struct ChangeOrderFormScreen: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let invoice: Invoice?
    let contract: Contract?
    var editing: ChangeOrder?

    @State private var title: String
    @State private var note: String
    @State private var status: ChangeOrderStatus
    @State private var items: [DraftItem]
    @State private var initialDigest: String?
    @State private var resyncFailed = false
    /// Set when a lapsed subscription refuses a write — the alert names it (ReadOnlyGate.swift).
    @State private var readOnlyRefusal: MBWriteOperation?
    /// A refusal ChangeOrderService threw that the form did not predict (DomainErrorAlert.swift).
    @State private var domainError: DomainError?
    /// The invoice was paid while this form was open (a payment synced in): the app's paid-lock
    /// explanation, as the Invoice form shows it.
    @State private var showingPaidLock = false
    /// Saving this applied order's edit would settle — and so lock — its invoice, which already
    /// has payments on it (PaidLockSaveGuard, QA F85).
    @State private var showingPaidLockSave = false

    /// One item as the form edits it: a price magnitude plus Charge/Credit (ChangeOrderDraft.swift,
    /// shared with ChangeOrderService and the assistant's tools).
    typealias DraftItem = ChangeOrderLineDraft

    init(invoice: Invoice? = nil, contract: Contract? = nil, editing: ChangeOrder? = nil) {
        let effInvoice = invoice ?? editing?.invoice
        let effContract = contract ?? editing?.contract ?? effInvoice?.contract
        self.invoice = effInvoice
        self.contract = effContract
        self.editing = editing
        _title = State(initialValue: editing?.title ?? "")
        _note = State(initialValue: editing?.note ?? "")
        let defaultStatus = editing?.status ?? (effContract != nil ? .approved : .pending)
        _status = State(initialValue: defaultStatus)
        if let editing, !editing.sortedLineItems.isEmpty {
            _items = State(initialValue: editing.sortedLineItems.map { DraftItem(from: $0) })
        } else {
            _items = State(initialValue: [DraftItem()])
        }
    }

    init(invoice: Invoice, editing: ChangeOrder? = nil) {
        self.init(invoice: invoice, contract: nil, editing: editing)
    }

    init(contract: Contract, editing: ChangeOrder? = nil) {
        self.init(invoice: nil, contract: contract, editing: editing)
    }

    init(editing: ChangeOrder) {
        self.init(invoice: nil, contract: nil, editing: editing)
    }

    private var digest: String {
        "\(title)|\(note)|\(status.rawValue)|" + items.map {
            "\($0.name)|\($0.quantity)|\($0.unit.rawValue)|\($0.unitPrice)|\($0.isCredit)|\($0.isTaxable)"
        }.joined(separator: ";")
    }
    private var isDirty: Bool { initialDigest.map { $0 != digest } ?? false }

    /// What this form writes to was deleted out from under us: the change order itself, or the
    /// invoice/contract that owns it. Checked on save (matching EstimateFormScreen and InvoiceFormScreen).
    private var targetVanished: Bool {
        if let invoice, invoice.isSavedDelete || invoice.isDeleted || !modelContext.stillStores(invoice) { return true }
        if let contract, contract.isSavedDelete || contract.isDeleted || !modelContext.stillStores(contract) { return true }
        guard let editing else { return false }
        return editing.isSavedDelete || editing.isDeleted || !modelContext.stillStores(editing)
    }

    private var defaultTaxRate: Double {
        invoice?.taxRatePercent ?? (contract?.taxRatePercent ?? 0)
    }

    /// What the order will charge once saved, at the rate the save stores (QA F82: an approved
    /// order keeps its signed rate; a pending one takes the rate only when its money
    /// changes). A vanished order is never read.
    private var changeTotal: Double {
        let kept = items.filter { !DocumentDraftRules.trim($0.name).isEmpty }
        let rate: Double
        if let editing, !editing.isSavedDelete, !editing.isDeleted, modelContext.stillStores(editing) {
            rate = ChangeOrderService.taxRateAfterSave(editing, keeping: kept, invoiceRate: defaultTaxRate)
        } else {
            rate = defaultTaxRate
        }
        return ChangeOrderMath.totals(lines: items.map { ($0.exactLineTotal, $0.isTaxable) },
                                      taxRatePercent: rate).total
    }
    private func money(_ v: Double) -> String { v.formatted(.money) }
    private func signed(_ v: Double) -> String { (v >= 0 ? "+" : "") + money(v) }

    var body: some View {
        Form {
            Section {
                TextField("Summary (e.g. Add second coat of sealer)", text: $title)
            } header: {
                InfoLabel("Change Order", info: "Set an item to Credit to subtract for removed work.", topic: "Change Order")
            }

            Section {
                Picker("Status", selection: $status) {
                    Text(mbLoc("Approved")).tag(ChangeOrderStatus.approved)
                    Text(mbLoc("Pending")).tag(ChangeOrderStatus.pending)
                }
                .pickerStyle(.segmented)
            } header: {
                Text(mbLoc("Approval Status"))
            } footer: {
                if status == .approved {
                    Text(contract != nil ? mbLoc("Approved change orders immediately update the contract total.") : mbLoc("Approved change orders can be added to the invoice."))
                } else {
                    Text(mbLoc("Pending change orders wait for client approval and do not update totals yet."))
                }
            }

            Section("Items") {
                ForEach($items) { $item in
                    itemEditor($item)
                }
                .onDelete { items.remove(atOffsets: $0) }
                Button {
                    items.append(DraftItem())
                } label: {
                    Label("Add line item", systemImage: "plus.circle.fill")
                }
            }

            Section {
                TextField("Notes (optional)", text: $note, axis: .vertical)
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("This change")
                        Spacer()
                        Text(signed(changeTotal)).fontWeight(.semibold)
                    }
                    .font(.subheadline)
                    .foregroundStyle(GLTheme.textPrimary)
                    if editing?.appliedToInvoice == true {
                        Text("This change order is on the invoice — changes update the invoice’s items too.")
                            .font(.footnote)
                    }
                }
            }
        }
        .glFormBackground()
        .readOnlyRefusalAlert($readOnlyRefusal)
        .domainErrorAlert($domainError)
        .paidInvoiceLockAlert(isPresented: $showingPaidLock)
        .paidLockSaveAlert(isPresented: $showingPaidLockSave, action: "Save") { commit(confirmedLock: true) }
        .onAppear { if initialDigest == nil { initialDigest = digest } }
        .discardChangesGuard(isDirty: isDirty)
        .navigationTitle(GLScript.padded(editing == nil ? mbLoc("New Change Order") : mbLoc("Edit Change Order")))
        .toolbarTitleDisplayMode(.large)
        .contentMargins(.top, GLScript.titleClearance(for: GLScript.padded(editing == nil ? mbLoc("New Change Order") : mbLoc("Edit Change Order"))), for: .scrollContent)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                SaveOnceButton(disabled: !canSave, action: save)
            }
        }
        .alert("Invoice not updated", isPresented: $resyncFailed) {
            Button("OK", role: .cancel) { dismiss() }
        } message: {
            Text("Your edits were saved, but this change order’s items on the invoice couldn’t be matched. Update the invoice’s line items by hand.")
        }
    }

    private var canSave: Bool {
        items.contains { !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    @ViewBuilder
    private func itemEditor(_ item: Binding<DraftItem>) -> some View {
        VStack(spacing: 10) {
            TextField("Description", text: item.name)
            HStack {
                AutoClearNumberField(placeholder: "1", value: item.quantity, style: .number, clearsAt: 0)
                    .frame(width: 56)
                Picker("Unit", selection: item.unit) {
                    ForEach(UnitOfMeasure.allCases) { Text($0.abbreviation).tag($0) }
                }
                .labelsHidden()
                Spacer()
                if item.wrappedValue.isCredit {
                    Text("−").foregroundStyle(GLTheme.statusCritical)
                }
                AutoClearNumberField(placeholder: "0", value: item.unitPrice, style: .currency, clearsAt: 0)
                    .multilineTextAlignment(.trailing)
            }
            // Segmented at normal sizes; a menu at accessibility sizes, where the segments
            // truncate their labels. The two styles are different types, so the branch is
            // at the view level, not a ternary (MMGoldLifeSignInSheet recipe).
            Group {
                if dynamicTypeSize.isAccessibilitySize {
                    Picker("Type", selection: item.isCredit) {
                        Text("Charge").tag(false)
                        Text("Credit").tag(true)
                    }
                    .pickerStyle(.menu)
                } else {
                    Picker("Type", selection: item.isCredit) {
                        Text("Charge").tag(false)
                        Text("Credit").tag(true)
                    }
                    .pickerStyle(.segmented)
                }
            }
            // A name for VoiceOver ("Type: Charge"); a segmented control draws no label anyway.
            .labelsHidden()
            Toggle("Taxable", isOn: item.isTaxable)
                .font(.subheadline)
        }
        .padding(.vertical, 4)
    }

    /// Returns whether the save committed — false re-arms `SaveOnceButton` so a refused tap can be
    /// retried after the person reactivates.
    ///
    /// Line items are saved IN PLACE (RowReconciler.swift): a draft that came from a live row
    /// updates that row, a row added in the form is inserted, a row removed in the form is
    /// deleted. An untouched row produces no change at all — no history row, no sync op — and
    /// every kept row keeps its syncID, so another device's references to it stay valid. A new
    /// order runs the same body against an empty row list; there is no new/edit fork.
    @discardableResult
    private func save() -> Bool { commit(confirmedLock: false) }

    /// `save()`, after the lock preview has been asked (QA F85) — `confirmedLock` once the person
    /// said yes. An edit to an order already on the invoice moves the invoice's total; when the
    /// payments on it would then cover the total, the invoice settles and locks, so it asks first.
    @discardableResult
    private func commit(confirmedLock: Bool) -> Bool {
        // The change order — or the invoice whose cascade owns it — was deleted out from under us
        // while this form was on screen. Bail before touching anything: writing rows onto a
        // tombstoned object silently orphans the edits, and `setIfChanged` READS the property
        // first, which traps uncatchably inside SwiftData (LiveRows.swift). The parent pops this
        // screen when its own record dies, but that pop is a SwiftUI update — a Save tap already
        // in flight beats it. `true` latches SaveOnceButton: there is nothing here to retry.
        if targetVanished {
            dismiss()
            return true
        }
        guard ReadOnlyGate.allows(.saveChangeOrder, into: $readOnlyRefusal) else { return false }
        // ChangeOrderService numbers it, stores credits as negative prices, snapshots the tax rate,
        // reconciles the rows in place, re-pushes an applied order and saves — the same path the
        // assistant uses.
        let draft = ChangeOrderDraft(title: title, note: note, items: items, status: status)
        if !confirmedLock, let editing, let paid = editing.invoice?.amountPaid,
           PaidLockSaveGuard.fires(MoneyLockPreview.wouldLock(editing, applying: draft), amountPaid: paid) {
            showingPaidLockSave = true
            return false
        }
        do {
            if let editing {
                // An applied order's items also live on the invoice — false means they couldn't be
                // matched there. The change order DID save; only the invoice re-push failed.
                if !(try ChangeOrderService.update(editing, with: draft, in: modelContext)) {
                    resyncFailed = true
                    return true
                }
            } else if let contract {
                try ChangeOrderService.create(draft, on: contract, in: modelContext)
            } else if let invoice {
                try ChangeOrderService.create(draft, on: invoice, in: modelContext)
            }
        } catch DomainError.paidLocked {
            showingPaidLock = true
            return false
        } catch {
            DomainError.present(error, readOnly: $readOnlyRefusal, domainError: $domainError)
            return false
        }
        dismiss()
        return true
    }
}

// MARK: - Detail

struct ChangeOrderDetailSheet: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Query private var businessProfiles: [BusinessProfile]
    /// This change order as the store lists it: one row, or none once it is deleted. A fetch of
    /// the one record (QA F153), still a live @Query so a saved delete redraws the sheet.
    @Query private var storedChangeOrder: [ChangeOrder]
    @Bindable var changeOrder: ChangeOrder

    /// The sparkles button (law 58, dual entry points). Off for a record the assistant itself
    /// pushed, so the assistant can never open inside the assistant.
    var showsAssistantButton = true

    init(changeOrder: ChangeOrder, showsAssistantButton: Bool = true) {
        self.changeOrder = changeOrder
        self.showsAssistantButton = showsAssistantButton
        let id = changeOrder.persistentModelID
        _storedChangeOrder = Query(filter: #Predicate<ChangeOrder> { $0.persistentModelID == id })
    }

    /// What the model is told is on screen when the sparkles sheet opens.
    private var assistantRecord: GLAIOnScreen? {
        GLAIOnScreen(.changeOrder, changeOrder, label: changeOrder.number, in: modelContext)
    }

    /// False once this change order is deleted out from under the view (e.g. it — or its invoice,
    /// which cascades — was deleted on another device and synced over).
    private var stillExists: Bool {
        !changeOrder.isSavedDelete && !changeOrder.isDeleted && !storedChangeOrder.isEmpty
    }

    @State private var pdfURL: URL?
    @State private var pdfData: Data?
    /// The PDF couldn't be made when the person tapped send.
    @State private var pdfFailed = false
    /// The device couldn't compose when the person tapped (ComposeCapability.check).
    @State private var composeUnavailable: ComposeCapability.Channel?
    @State private var sendAction: SendAction?
    @State private var sendFailureMessage: String?
    @State private var showingProfilePrompt = false
    @State private var showingEdit = false
    @State private var confirmDelete = false
    @State private var statusRemovalFailed = false
    @State private var deleteNeedsManualRemoval = false
    /// True for exactly the one `onChange` pass that a refused status change causes by putting the
    /// picker back — see the guard in the handler.
    @State private var restoringStatus = false
    /// Set when a lapsed subscription refuses a write — the alert names it (ReadOnlyGate.swift).
    @State private var readOnlyRefusal: MBWriteOperation?
    /// The paid-invoice lock explanation (PaidInvoiceLock.swift). Every gesture below that
    /// would pull this order's billed items back off the invoice is a DELETE of an invoice
    /// group, which the server refuses once that invoice is paid.
    @State private var showingPaidLock = false
    @State private var showingPreview = false
    /// Adding this order's items would settle — and so lock — its invoice, which already has
    /// payments on it (a credit that covers the balance; PaidLockSaveGuard, QA F85).
    @State private var showingPaidLockApply = false
    /// A refusal ChangeOrderService threw that the sheet did not predict (DomainErrorAlert.swift).
    @State private var domainError: DomainError?
    
    private var statusColor: Color {
        switch changeOrder.status {
        case .pending: return GLTheme.textSecondary
        case .approved: return GLTheme.statusGood
        case .declined: return GLTheme.statusCritical
        }
    }
    
    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        MBTitledCard { content() }
    }

    private func labeledRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(GLTheme.textSecondary)
            Spacer()
            Text(value)
        }
        .font(.subheadline)
    }


    private enum SendAction: Int, Identifiable { case email, text; var id: Int { rawValue } }
    private var gold: Color { GLTheme.accentFill }
    private var business: BusinessProfile? { businessProfiles.first }
    private var invoice: Invoice? { changeOrder.invoice }
    private var contract: Contract? { changeOrder.contract }
    private var hasRecipient: Bool { invoice != nil || contract != nil }
    private var recipientEmail: String { changeOrder.recipientEmail }
    private var recipientPhone: String { changeOrder.recipientPhone }

    /// A business name plus at least one way to be reached — the bar for putting this document in
    /// front of a customer. `BusinessProfile.isComplete` owns the rule; this is just the read.
    private var profileIsComplete: Bool { business?.isComplete == true }
    private var canApply: Bool { changeOrder.status == .approved && !changeOrder.appliedToInvoice && changeOrder.invoice != nil }

    var body: some View {
        // BRANCH, not overlay (CRUD audit 2026-09-02): an overlay still evaluates the body
        // against the deleted record — property reads on a dead @Model trap uncatchably.
        if stillExists { aliveBody } else { DeletedRecordView(title: mbLoc("Change Order"), noun: "the change order") { dismiss() } }
    }

    @ViewBuilder private var aliveBody: some View {
        ScrollView {
            VStack(spacing: 20) {
                heroCard
                quickActionBar
                
                MBTitledCard(title: "Status") {
                    Group {
                        if dynamicTypeSize.isAccessibilitySize {
                            Picker("Status", selection: $changeOrder.status) {
                                ForEach(ChangeOrderStatus.allCases) { Text($0.label).tag($0) }
                            }
                            .pickerStyle(.menu)
                        } else {
                            Picker("Status", selection: $changeOrder.status) {
                                ForEach(ChangeOrderStatus.allCases) { Text($0.label).tag($0) }
                            }
                            .pickerStyle(.segmented)
                        }
                    }
                    .labelsHidden()
                    if changeOrder.appliedToInvoice {
                        Text("Moving off Approved takes this change order’s items back off the invoice.")
                            .font(.caption).foregroundStyle(GLTheme.textSecondary)
                    }
                    if statusRemovalFailed {
                        Text("These items couldn’t be matched on the invoice — remove them from the invoice’s line items by hand.")
                            .font(.caption).foregroundStyle(GLTheme.accentText)
                    }
                }

                if changeOrder.appliedToInvoice {
                    Label("Added to invoice", systemImage: "checkmark.circle.fill")
                        .font(.subheadline).foregroundStyle(GLTheme.statusGood)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(GLLayout.rowContentPadding).glCardBackground()
                } else if canApply {
                    DocActionRow(title: "Add items to invoice",
                                 subtitle: "Append this change to the invoice’s line items.",
                                 systemImage: "plus.rectangle.on.rectangle") { addToInvoice() }
                }

                DocActionRow(title: "Edit change order",
                             subtitle: "Update the summary, items, or notes.",
                             systemImage: "square.and.pencil") {
                    if changeOrder.isBilledToLockedInvoice { showingPaidLock = true } else { showingEdit = true }
                }

                Button(role: .destructive) {
                    if changeOrder.isBilledToLockedInvoice { showingPaidLock = true } else { confirmDelete = true }
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "trash").font(.title3).frame(width: 28).foregroundStyle(GLTheme.statusCritical)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Delete change order").font(.subheadline.weight(.semibold)).foregroundStyle(GLTheme.statusCritical)
                            Text("Remove this change order.").font(.caption).foregroundStyle(GLTheme.textSecondary)
                        }
                        Spacer(minLength: 8)
                    }
                    .padding(GLLayout.rowContentPadding).frame(maxWidth: .infinity, alignment: .leading).glCardBackground()
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, GLLayout.rowCardInset)
            .padding(.vertical)
            // One column with the banners above (QA 2026-10-03 F50): capped at 640 pt, the gutter inside it.
            .glReadableWidth()
        }
        .safeAreaInset(edge: .bottom) {
            previewButton
        }
        .background { GLTheme.background.ignoresSafeArea() }
        .navigationTitle(GLScript.padded(changeOrder.number.isEmpty ? mbLoc("Change Order") : changeOrder.number))
        .toolbarTitleDisplayMode(.large)
        .contentMargins(.top, GLScript.titleClearance(for: GLScript.padded(changeOrder.number.isEmpty ? mbLoc("Change Order") : changeOrder.number)), for: .scrollContent)
        .mbSystemBanners()
        .toolbar {
            // A pure check: the id is minted in the button's action, never in this builder.
            if showsAssistantButton, changeOrder.canBeNamedToAssistant {
                ToolbarItem(placement: .topBarTrailing) {
                    MBAssistantButton { assistantRecord }
                }
            }
        }
        .onAppear { regenerate() }
        .onChange(of: changeOrder.statusRaw) { oldValue, newValue in
            statusRemovalFailed = false
            if changeOrder.isBilledToLockedInvoice, ChangeOrderStatus(rawValue: newValue) != .approved {
                changeOrder.statusRaw = oldValue
                showingPaidLock = true
                return
            }
            guard !restoringStatus else { restoringStatus = false; return }
            guard ReadOnlyGate.allows(.changeChangeOrderStatus, into: $readOnlyRefusal) else {
                restoringStatus = true
                changeOrder.statusRaw = oldValue
                return
            }
            // The picker already wrote the status; ChangeOrderService takes an un-approved order's
            // items back off the invoice and saves — the same code its setStatus runs. Its own
            // checks repeat the ones above, so a refusal here means the record died mid-change.
            do {
                if !(try ChangeOrderService.settleStatusChange(changeOrder, in: modelContext)) {
                    statusRemovalFailed = true
                }
            } catch {
                if changeOrder.modelContext != nil, !changeOrder.isDeleted {
                    restoringStatus = true
                    changeOrder.statusRaw = oldValue
                }
                DomainError.present(error, readOnly: $readOnlyRefusal, domainError: $domainError)
            }
            regenerate()
        }
        .onChange(of: showingEdit) { _, isShowing in if !isShowing { regenerate() } }
        .navigationDestination(isPresented: $showingEdit) {
            ChangeOrderFormScreen(editing: changeOrder)
        }
        .sheet(item: $sendAction) { action in sendSheet(action).glAppearance(colorScheme) }
        .composeUnavailableAlert($composeUnavailable)
        .pdfFailureAlert($pdfFailed)
        .sheet(isPresented: $showingPreview) {
            if let pdfURL {
                DocumentPreviewSheet(url: pdfURL,
                                     title: changeOrder.number.isEmpty ? "Change Order" : "Change Order \(changeOrder.number)",
                                     subject: ChangeOrderMessage.subject(changeOrder, business: business),
                                     message: ChangeOrderMessage.plainBody(changeOrder, business: business))
                    .glAppearance(colorScheme)
            }
        }
        .alert("Complete your business profile", isPresented: $showingProfilePrompt) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("Add your business name and a phone or email in Menu → My Business Details so they appear on your documents.")
        }
        .alert("Couldn’t send", isPresented: Binding(get: { sendFailureMessage != nil },
                                                     set: { if !$0 { sendFailureMessage = nil } })) {
            Button("OK", role: .cancel) { sendFailureMessage = nil }
        } message: {
            Text(sendFailureMessage ?? "")
        }
        .paidLockSaveAlert(isPresented: $showingPaidLockApply, action: "Add to invoice") {
            addToInvoice(confirmedLock: true)
        }
        .paidInvoiceLockAlert(isPresented: $showingPaidLock)
        .readOnlyRefusalAlert($readOnlyRefusal)
        .domainErrorAlert($domainError)
        .alert("Delete this change order?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) { performDelete() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(deleteMessage)
        }
        .alert("Remove items by hand", isPresented: $deleteNeedsManualRemoval) {
            Button("OK", role: .cancel) {
                guard ReadOnlyGate.allows(.deleteChangeOrder, into: $readOnlyRefusal) else { return }
                deleteChangeOrder(evenIfItemsUnmatched: true)
            }
        } message: {
            Text("This change order’s items couldn’t be matched on the invoice, so they’ll stay on it. Remove them from the invoice’s line items by hand.")
        }
    }
    
    private var heroCard: some View {
        card {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top) {
                    Text(changeOrder.total.formatted(.money))
                        .font(.glAmountRow)
                        .foregroundStyle(GLTheme.textPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                    Spacer()
                    Text(changeOrder.status.label)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(statusColor.opacity(0.18)))
                        .foregroundStyle(statusColor)
                }
                
                VStack(alignment: .leading, spacing: 4) {
                    Text(changeOrder.title.isEmpty ? mbLoc("Untitled change order") : changeOrder.title)
                        .font(.title3.weight(.semibold))
                    Text(changeOrder.number)
                        .font(.subheadline)
                        .foregroundStyle(GLTheme.textSecondary)
                    
                    VStack(alignment: .leading, spacing: 2) {
                        Text(changeOrder.invoice != nil ? "Billed to" : "Client")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(GLTheme.textSecondary)
                        Text(changeOrder.customerDisplayName)
                            .font(.headline)
                        if let business = changeOrder.customerBusinessName, !business.isEmpty {
                            Text(business).foregroundStyle(GLTheme.textSecondary)
                        }
                    }
                }
                
                Divider()
                
                if let invoice = changeOrder.invoice, !invoice.number.isEmpty {
                    labeledRow(mbLoc("Invoice"), invoice.number)
                } else if let contract = changeOrder.contract, !contract.number.isEmpty {
                    labeledRow(mbLoc("Contract"), contract.number)
                }
                labeledRow(mbLoc("Created"), changeOrder.createdAt.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted).locale(MBLocalization.currentLocale)))
            }
        }
    }

    @ViewBuilder
    private var quickActionBar: some View {
        if profileIsComplete {
            HStack(spacing: 12) {
                GLDocumentActionButton("Email", systemImage: "envelope") {
                    guard hasRecipient, ReadOnlyGate.allows(.sendDocument, into: $readOnlyRefusal),
                          ComposeCapability.check(.mail, into: $composeUnavailable) else { return }
                    send(.email)
                }
                // No customer to send to.
                .disabled(recipientEmail.isEmpty || !ComposeCapability.canSend(.mail))

                GLDocumentActionButton("Text", systemImage: "message") {
                    guard hasRecipient, ReadOnlyGate.allows(.sendDocument, into: $readOnlyRefusal),
                          ComposeCapability.check(.text, into: $composeUnavailable) else { return }
                    send(.text)
                }
                .disabled(recipientPhone.isEmpty || !ComposeCapability.canSend(.text))

                if let pdfURL {
                    MBShareLink(
                        item: pdfURL,
                        subject: Text(ChangeOrderMessage.subject(changeOrder, business: business)),
                        message: Text(ChangeOrderMessage.plainBody(changeOrder, business: business)),
                        refused: $readOnlyRefusal
                    ) {
                        GLDocumentActionLabel("Share", systemImage: "square.and.arrow.up")
                    }
                    .foregroundStyle(GLTheme.accentText)
                } else {
                    GLDocumentActionButton("Retry", systemImage: "arrow.clockwise") {
                        regenerate()
                    }
                }
            }
        } else {
            Button { showingProfilePrompt = true } label: {
                HStack {
                    Image(systemName: "exclamationmark.circle")
                    Text("Set up business profile to send")
                        .font(.subheadline.weight(.semibold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .background(GLTheme.surfaceRaised.clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous)))
                .foregroundStyle(GLTheme.statusAttention)
            }
        }
    }

    private var previewButton: some View {
        GLStickyPreviewFooter("Preview PDF", systemImage: "eye") {
            if pdfURL == nil { regenerate() }
            if pdfURL != nil { showingPreview = true }
        }
    }



    /// LocalizedStringKey (not a String ternary) so both variants go through the string catalog —
    /// mirrors AllChangeOrdersScreen's deleteMessage.
    private var deleteMessage: LocalizedStringKey {
        changeOrder.appliedToInvoice
            ? "Its items come off the invoice too. This can’t be undone."
            : "This can’t be undone."
    }

    private func performDelete() {
        guard ReadOnlyGate.allows(.deleteChangeOrder, into: $readOnlyRefusal) else { return }
        deleteChangeOrder(evenIfItemsUnmatched: false)
    }

    /// DeletionService pulls the billed items off the invoice first — the cascade covers linked
    /// groups, but a pre-link legacy apply needs that explicit pass — then deletes and saves. A
    /// failed match (when not overridden) falls through to the "Remove items by hand" alert, which
    /// still deletes on OK.
    private func deleteChangeOrder(evenIfItemsUnmatched: Bool) {
        do {
            switch try DeletionService.delete([.changeOrder(changeOrder)], evenIfItemsUnmatched: evenIfItemsUnmatched,
                                              origin: .screen, in: modelContext) {
            case .deleted: dismiss()
            case .itemsUnmatched: deleteNeedsManualRemoval = true
            }
        } catch DomainError.paidLocked {
            showingPaidLock = true
        } catch {
            DomainError.present(error, readOnly: $readOnlyRefusal, domainError: $domainError)
        }
    }

    /// Re-renders the PDF; false when it couldn't be made. A failure clears the last PDF, so a
    /// stale one is never previewed or sent as if it were current.
    @discardableResult
    private func regenerate() -> Bool {
        guard let url = ChangeOrderPDF.render(changeOrder, business: business),
              let data = try? Data(contentsOf: url) else {
            pdfURL = nil
            pdfData = nil
            return false
        }
        pdfURL = url
        pdfData = data
        return true
    }

    /// Opens the composer with a freshly made PDF, or says the PDF couldn't be made.
    private func send(_ action: SendAction) {
        guard regenerate() else {
            pdfFailed = true
            return
        }
        sendAction = action
    }

    /// Adds the items, after the lock preview (QA F85): a credit that leaves the payments covering
    /// the invoice settles it, and a settled invoice locks, so that asks first.
    private func addToInvoice(confirmedLock: Bool = false) {
        guard ReadOnlyGate.allows(.changeChangeOrderStatus, into: $readOnlyRefusal) else { return }
        if !confirmedLock, let paid = changeOrder.invoice?.amountPaid,
           PaidLockSaveGuard.fires(MoneyLockPreview.wouldLock(applying: changeOrder), amountPaid: paid) {
            showingPaidLockApply = true
            return
        }
        do {
            try ChangeOrderService.applyToInvoice(changeOrder, in: modelContext)
        } catch {
            DomainError.present(error, readOnly: $readOnlyRefusal, domainError: $domainError)
        }
    }

    @ViewBuilder
    private func sendSheet(_ action: SendAction) -> some View {
        if hasRecipient {
            // Recipients, subject, bodies and files come from SendPreparer — the same content the
            // assistant's send hands the compose sheet.
            let content = SendPreparer.changeOrder(changeOrder, business: business, pdfURL: pdfURL)
            switch action {
            case .email:
                MailComposeView(
                    recipients: content.emailRecipients,
                    subject: content.subject,
                    body: content.htmlBody,
                    isHTML: true,
                    preferredSendingEmail: business?.email,
                    attachmentURL: content.pdfURL
                ) { outcome in sendAction = nil; noteSend(outcome) }
            case .text:
                MessageComposeView(
                    recipients: content.textRecipients,
                    body: content.plainBody,
                    attachmentURLs: content.messageAttachmentURLs
                ) { outcome in sendAction = nil; noteSend(outcome) }
            }
        }
    }

    private func noteSend(_ outcome: SendOutcome) {
        if outcome == .failed {
            // Resolved through mbLoc rather than left a bare literal: this lands in a String @State
            // that `Text(String)` renders VERBATIM, so an unlocalized literal stays English in Spanish.
            sendFailureMessage = mbLoc("We couldn’t send your change order. Check your internet connection and try again.")
        }
    }
}
