//
//  EstimateDetailScreen.swift
//  GLSmallBusiness
//
//  Created by Gold Life LLC on 5/28/26.
//

import OSLog
import SwiftUI
import GoldLifeUI
import GoldLifeAI
import SwiftData
import MessageUI

struct EstimateStatusBadge: View {
    let estimate: Estimate

    private var color: Color {
        if estimate.isExpired { return GLTheme.statusAttention }
        switch estimate.status {
        case .draft: return GLTheme.textSecondary
        case .sent: return GLTheme.accentFill
        case .accepted: return GLTheme.statusGood
        case .declined: return GLTheme.statusCritical
        }
    }

    var body: some View {
        Text(estimate.displayStatus)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Capsule().fill(color.opacity(0.18)))
            .foregroundStyle(color)
    }
}

struct EstimateDetailScreen: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(SubscriptionManager.self) private var subscription
    @Query private var businessProfiles: [BusinessProfile]
    /// This estimate as the store lists it: one row, or none once it is deleted. A fetch of the
    /// one record (QA F153), still a live @Query so a saved delete redraws the screen.
    @Query private var storedEstimate: [Estimate]
    let estimate: Estimate

    /// The sparkles button (law 58, dual entry points). Off for a record the assistant itself
    /// pushed, so the assistant can never open inside the assistant.
    var showsAssistantButton = true

    init(estimate: Estimate, showsAssistantButton: Bool = true) {
        self.estimate = estimate
        self.showsAssistantButton = showsAssistantButton
        let id = estimate.persistentModelID
        _storedEstimate = Query(filter: #Predicate<Estimate> { $0.persistentModelID == id })
    }

    /// What the model is told is on screen when the sparkles sheet opens.
    private var assistantRecord: GLAIOnScreen? {
        GLAIOnScreen(.estimate, estimate, label: estimate.number.isEmpty ? mbLoc("Estimate") : estimate.number, in: modelContext)
    }

    /// False once this estimate is deleted out from under the view (e.g. its customer was deleted on
    /// another device, cascading the delete here).
    private var stillExists: Bool {
        !estimate.isSavedDelete && !estimate.isDeleted && !storedEstimate.isEmpty
    }

    @State private var showingEdit = false
    @State private var showingPaywall = false
    /// Set when a lapsed subscription refuses a write — the alert names it (ReadOnlyGate.swift).
    @State private var readOnlyRefusal: MBWriteOperation?
    @State private var sendAction: SendAction?
    /// What the open compose sheet shows, built at the tap (never while the screen draws).
    @State private var composeContent: ComposeContent?
    /// The device couldn't compose when the person tapped (ComposeCapability.check).
    @State private var composeUnavailable: ComposeCapability.Channel?
    /// The PDF couldn't be made when the person tapped send.
    @State private var pdfFailed = false
    @State private var pdfURL: URL?
    @State private var showingPreview = false
    @State private var sendFailureMessage: String?
    @State private var showingProfilePrompt = false
    @State private var convertedInvoice: Invoice?
    @State private var convertedContract: Contract?
    @State private var showingSchedule = false
    @State private var pendingReconvertNumber: String?   // set when re-converting an already-converted estimate
    /// OPTIONS estimate (combineTotals off): which groups the customer chose,
    /// gathered by the picker sheet before conversion.
    @State private var showingOptionPicker = false
    @State private var isConvertingToContract = false
    @State private var chosenOptionIDs: Set<PersistentIdentifier> = []
    /// A refusal EstimateService threw that the screen did not predict (DomainErrorAlert.swift).
    @State private var domainError: DomainError?

    enum SendAction: Int, Identifiable {
        case email, text
        var id: Int { rawValue }
    }

    private var gold: Color { GLTheme.accentFill }

    /// A business name plus at least one way to be reached — the bar for putting this document in
    /// front of a customer. `BusinessProfile.isComplete` owns the rule; this is just the read.
    private var profileIsComplete: Bool { businessProfiles.first?.isComplete == true }

    private var effectiveCustomerPhone: String {
        if !estimate.customerPhone.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return estimate.customerPhone
        }
        return estimate.customer?.phoneNumber ?? ""
    }

    private var effectiveServiceAddress: Address {
        if !estimate.serviceAddress.isEmpty {
            return estimate.serviceAddress
        }
        return estimate.customer?.serviceAddress ?? Address()
    }

    var body: some View {
        // BRANCH, not overlay (CRUD audit 2026-09-02): an overlay still evaluates the body
        // against the deleted record — property reads on a dead @Model trap uncatchably.
        if stillExists { aliveBody } else { DeletedRecordView(title: mbLoc("Estimate"), noun: "this estimate") { dismiss() } }
    }

    @ViewBuilder private var aliveBody: some View {
        ScrollView {
            VStack(spacing: 20) {
                heroCard
                quickActionBar
                serviceAddressCard
                groupsView
                totalsCard
                if !estimate.customerNotes.isEmpty || !estimate.terms.isEmpty {
                    notesCard
                }
            }
            .padding(.horizontal, GLLayout.rowCardInset)
            .padding(.vertical)
            // One column with the banners above (QA 2026-10-03 F50): capped at 640 pt, the gutter inside it.
            .glReadableWidth()
        }
        .safeAreaInset(edge: .bottom) {
            previewButton
        }
        .mbSystemBanners()
        .containerBackground(for: .navigation) {
            PrimaryBackground()
        }
        .navigationTitle(GLScript.padded(estimate.number.isEmpty ? mbLoc("Estimate") : estimate.number))
        .toolbarTitleDisplayMode(.large)
        // Whole points (QA 2026-10-03 L15): a fractional clearance (18.696 pt for "EST-0001",
        // 30.664 for "More Info") leaves the scroll view a fraction of a pixel below its top at
        // load, so UIKit opens the screen with the large title already collapsed.
        .contentMargins(.top, GLScript.titleClearance(for: GLScript.padded(estimate.number.isEmpty ? mbLoc("Estimate") : estimate.number)).rounded(.up), for: .scrollContent)
        .navigationDestination(item: $convertedInvoice) { invoice in
            InvoiceDetailScreen(invoice: invoice)
        }
        .navigationDestination(item: $convertedContract) { contract in
            ContractDetailScreen(contract: contract)
        }
        .paywallSheet(isPresented: $showingPaywall)
        .readOnlyRefusalAlert($readOnlyRefusal)
        .domainErrorAlert($domainError)
        .toolbar {
            // A pure check: the id is minted in the button's action, never in this builder.
            if showsAssistantButton, estimate.canBeNamedToAssistant {
                ToolbarItem(placement: .topBarTrailing) {
                    MBAssistantButton { assistantRecord }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Section {
                        Button { showingEdit = true } label: { Label("Edit", systemImage: "pencil") }
                        Button { convertToContract() } label: { Label(mbLoc("Convert to Contract"), systemImage: "doc.text.fill") }
                        if estimate.status == .accepted {
                            Button { scheduleJob() } label: { Label("Schedule", systemImage: "calendar.badge.plus") }
                        }
                        Button { convertToInvoice() } label: { Label("Convert to Invoice", systemImage: "arrow.right.doc.on.clipboard") }
                    }
                    Section("Status") {
                        Button { setStatus(.accepted) } label: {
                            Label("Mark as Accepted", systemImage: "checkmark.circle")
                        }
                        Button { setStatus(.sent) } label: {
                            Label("Mark as Sent", systemImage: "paperplane")
                        }
                        Button { setStatus(.declined) } label: {
                            Label("Mark as Declined", systemImage: "xmark.circle")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .accessibilityLabel("More")
            }
        }
        .onAppear { if pdfURL == nil { regeneratePDF() } }
        .onChange(of: showingEdit) { _, isShowing in
            if !isShowing { regeneratePDF() }
        }
        .navigationDestination(isPresented: $showingEdit) {
            EstimateFormScreen(editing: estimate)
        }
        .navigationDestination(isPresented: $showingSchedule) {
            ScheduleJobSheet(source: .estimate(estimate))
        }
        .sheet(item: $sendAction, onDismiss: { composeContent = nil }) { action in
            sendSheet(for: action).glAppearance(colorScheme)
        }
        .composeUnavailableAlert($composeUnavailable)
        .pdfFailureAlert($pdfFailed)
        .sheet(isPresented: $showingOptionPicker) {
            optionPickerSheet.glAppearance(colorScheme)
        }
        .sheet(isPresented: $showingPreview) {
            if let pdfURL {
                DocumentPreviewSheet(url: pdfURL,
                                     title: estimate.number.isEmpty ? "Estimate" : "Estimate \(estimate.number)",
                                     subject: EstimateMessage.subject(estimate: estimate, business: businessProfiles.first),
                                     message: EstimateMessage.plainBody(estimate: estimate, business: businessProfiles.first))
                    .glAppearance(colorScheme)
            }
        }
        .alert("Complete your business profile", isPresented: $showingProfilePrompt) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("Add your business name and a phone or email in Menu → My Business Details so they appear on your estimate.")
        }
        .alert("Couldn’t send", isPresented: Binding(get: { sendFailureMessage != nil },
                                                     set: { if !$0 { sendFailureMessage = nil } })) {
            Button("OK", role: .cancel) { sendFailureMessage = nil }
        } message: {
            Text(sendFailureMessage ?? "")
        }
        .alert("Already converted to invoice \(pendingReconvertNumber ?? "")",
               isPresented: Binding(get: { pendingReconvertNumber != nil },
                                    set: { if !$0 { pendingReconvertNumber = nil } })) {
            Button("Create Another Invoice") { beginConvert(); pendingReconvertNumber = nil }
            Button("Cancel", role: .cancel) { pendingReconvertNumber = nil }
        } message: {
            Text(estimate.isOptionsMode
                 ? mbLoc("This estimate already has an invoice. Converting again is fine if the customer chose another option — otherwise it bills the job twice.")
                 : mbLoc("This estimate was already turned into an invoice. Creating another will bill this job twice."))
        }
    }

    /// After the Mail/Messages sheet closes, tell the user only when it actually failed — a sent or
    /// cancelled message needs no interruption.
    func noteSend(_ outcome: SendOutcome) {
        if outcome == .failed {
            // Resolved through mbLoc rather than left a bare literal: this lands in a String @State
            // that `Text(String)` renders VERBATIM, so an unlocalized literal stays English in Spanish.
            sendFailureMessage = mbLoc("We couldn’t send your estimate. Check your internet connection and try again.")
        }
    }

    
    
    private var heroCard: some View {
        card {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top) {
                    if estimate.isOptionsMode {
                        Text("Options")
                            .font(.glAmountRow)
                            .foregroundStyle(GLTheme.textPrimary)
                    } else {
                        Text(estimate.total.formatted(.money))
                            .font(.glAmountRow)
                            .foregroundStyle(GLTheme.textPrimary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 4) {
                        Menu {
                            Section("Change Status") {
                                ForEach(EstimateStatus.allCases) { s in
                                    Button {
                                        setStatus(s)
                                    } label: {
                                        HStack {
                                            Text(s.label)
                                            if estimate.status == s {
                                                Image(systemName: "checkmark")
                                            }
                                        }
                                    }
                                }
                            }
                        } label: {
                            HStack(spacing: 4) {
                                EstimateStatusBadge(estimate: estimate)
                                Image(systemName: "chevron.up.chevron.down")
                                    .font(.caption2)
                                    .foregroundStyle(GLTheme.textTertiary)
                            }
                        }
                        Text(statusSubtitle)
                            .font(.caption2)
                            .foregroundStyle(GLTheme.textSecondary)
                            .multilineTextAlignment(.trailing)
                    }
                }
                
                VStack(alignment: .leading, spacing: 4) {
                    Text(estimate.jobTitle.isEmpty ? mbLoc("Untitled estimate") : estimate.jobTitle)
                        .font(.title3.weight(.semibold))
                    Text(estimate.number)
                        .font(.subheadline)
                        .foregroundStyle(GLTheme.textSecondary)
                    
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Prepared for")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(GLTheme.textSecondary)
                        Text(estimate.customerDisplayName)
                            .font(.headline)
                        if let business = estimate.customerBusinessName, !business.isEmpty {
                            Text(business).foregroundStyle(GLTheme.textSecondary)
                        }
                        if !estimate.customerEmail.isEmpty || !effectiveCustomerPhone.isEmpty {
                            HStack(spacing: 8) {
                                if !estimate.customerEmail.isEmpty {
                                    // Law 84: tappable, opens the person's chosen app.
                                    GLContactLink(.email, estimate.customerEmail)
                                        .font(.caption)
                                        .foregroundStyle(GLTheme.textSecondary)
                                }
                                if !estimate.customerEmail.isEmpty && !effectiveCustomerPhone.isEmpty {
                                    Text("·")
                                        .font(.caption)
                                        .foregroundStyle(GLTheme.textSecondary)
                                }
                                if !effectiveCustomerPhone.isEmpty {
                                    // Law 84: tappable, opens the person's chosen app.
                                    GLContactLink(.phone, effectiveCustomerPhone)
                                        .font(.caption)
                                        .foregroundStyle(GLTheme.textSecondary)
                                }
                            }
                        }
                    }
                }
                
                Divider()
                
                labeledRow(mbLoc("Created"), estimate.createdAt.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted).locale(MBLocalization.currentLocale)))
                labeledRow(mbLoc("Valid until"), estimate.validUntil.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted).locale(MBLocalization.currentLocale)))
            }
        }
    }

    @ViewBuilder
    private var quickActionBar: some View {
        if profileIsComplete {
            HStack(spacing: 12) {
                GLDocumentActionButton("Email", systemImage: "envelope") {
                    guard ReadOnlyGate.allows(.sendDocument, into: $readOnlyRefusal),
                          ComposeCapability.check(.mail, into: $composeUnavailable) else { return }
                    openComposer(.email)
                }
                .disabled(estimate.recipientEmail.isEmpty || !ComposeCapability.canSend(.mail))

                GLDocumentActionButton("Text", systemImage: "message") {
                    guard ReadOnlyGate.allows(.sendDocument, into: $readOnlyRefusal),
                          ComposeCapability.check(.text, into: $composeUnavailable) else { return }
                    openComposer(.text)
                }
                .disabled(estimate.recipientPhone.isEmpty || !ComposeCapability.canSend(.text))

                if let pdfURL {
                    MBShareLink(
                        item: pdfURL,
                        subject: Text(EstimateMessage.subject(estimate: estimate, business: businessProfiles.first)),
                        message: Text(EstimateMessage.plainBody(estimate: estimate, business: businessProfiles.first)),
                        refused: $readOnlyRefusal
                    ) {
                        GLDocumentActionLabel("Share", systemImage: "square.and.arrow.up")
                    }
                    .foregroundStyle(GLTheme.accentText)
                } else {
                    GLDocumentActionButton("Retry", systemImage: "arrow.clockwise") {
                        regeneratePDF()
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
            if pdfURL == nil { regeneratePDF() }
            if pdfURL != nil { showingPreview = true }
        }
    }


    private var serviceAddressCard: some View {
        card {
            Text("Service Address")
                .font(.headline)
            let addr = effectiveServiceAddress
            if addr.isEmpty {
                Text("—")
                    .foregroundStyle(GLTheme.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                // Law 84: opens in the person's maps app (the same card as the job's).
                GLContactLink(.address, addr.singleLine, display: addr.formattedMultiline)
                    .foregroundStyle(GLTheme.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    private var groupsView: some View {
        // `!isDeleted` guards (2026-09-01, the wife's save crash): the edit form's
        // save() DELETES every group/item and recreates them, and SwiftUI gives the
        // covered detail screen one more update pass over the dead rows — reading
        // any property of a deleted @Model traps uncatchably inside SwiftData
        // (same mechanism as the build-43 sign-out crash). Skip dead models; the
        // next pass renders the recreated ones.
        ForEach(estimate.sortedGroups) { group in
            if group.modelContext != nil, !group.isDeleted { groupCard(group) }
        }
    }

    @ViewBuilder
    private func groupCard(_ group: EstimateGroup) -> some View {
            card {
                Text(group.name.isEmpty ? mbLoc("Line Items") : group.name)
                    .font(.headline)
                if !group.note.isEmpty {
                    Text(group.note).font(.subheadline).foregroundStyle(GLTheme.textSecondary)
                }
                ForEach(group.sortedLineItems) { item in
                    lineItemRow(item)
                    if item.id != group.sortedLineItems.last?.id {
                        Divider()
                    }
                }
                if !group.name.isEmpty || estimate.sortedGroups.count > 1 {
                    Divider()
                    if estimate.isOptionsMode {
                        // A standalone option prices itself — subtotal, its own
                        // tax, and ITS total, because there is no grand total.
                        let option = group.optionTotals(taxRatePercent: estimate.taxRatePercent)
                        HStack {
                            Text("Subtotal").foregroundStyle(GLTheme.textSecondary)
                            Spacer()
                            Text(option.subtotal.formatted(.money))
                        }
                        .font(.subheadline)
                        if option.tax > 0 {
                            HStack {
                                Text(mbLoc("Tax") + " (\(estimate.taxRatePercent.formatted())%)")
                                    .foregroundStyle(GLTheme.textSecondary)
                                Spacer()
                                Text(option.tax.formatted(.money))
                            }
                            .font(.subheadline)
                        }
                        HStack {
                            Text("Option total").foregroundStyle(GLTheme.textSecondary)
                            Spacer()
                            Text(option.total.formatted(.money)).fontWeight(.semibold)
                        }
                        .font(.subheadline)
                    } else {
                        HStack {
                            Text("Subtotal").foregroundStyle(GLTheme.textSecondary)
                            Spacer()
                            Text(group.subtotal.formatted(.money)).fontWeight(.medium)
                        }
                        .font(.subheadline)
                    }
                }
            }
    }

    @ViewBuilder
    private func lineItemRow(_ item: EstimateLineItem) -> some View {
        if item.modelContext != nil, !item.isDeleted { lineItemRowBody(item) }
    }

    private func lineItemRowBody(_ item: EstimateLineItem) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(item.name)
                Spacer()
                Text(item.lineTotal.formatted(.money))
            }
            .font(.body.weight(.medium))
            if !item.details.isEmpty {
                Text(item.details).font(.footnote).foregroundStyle(GLTheme.textSecondary)
            }
            HStack(spacing: 6) {
                Text("\(item.quantity.formatted()) \(item.unit.abbreviation) × \(item.unitPrice.formatted(.money))")
                Text("·")
                Text(item.kind.label)
                if !item.isTaxable { Text("· non-taxable") }
                if item.lineDiscount > 0 { Text("· −\(item.lineDiscount.formatted(.money)) off") }
            }
            .font(.caption)
            .foregroundStyle(GLTheme.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var totalsCard: some View {
        card {
            if estimate.isOptionsMode {
                Text("Priced as options").font(.headline)
                ForEach(estimate.sortedGroups) { group in
                    if group.modelContext != nil, !group.isDeleted {
                        totalRow(group.name.isEmpty ? mbLoc("Option") : group.name,
                                 group.optionTotals(taxRatePercent: estimate.taxRatePercent).total)
                    }
                }
                Text("Each option stands on its own — there is no combined total.")
                    .font(.footnote)
                    .foregroundStyle(GLTheme.textSecondary)
            } else {
                combinedTotals
            }
        }
    }

    @ViewBuilder
    private var combinedTotals: some View {
            totalRow(mbLoc("Subtotal"), estimate.subtotal)
            if estimate.discountAmount > 0 { totalRow(mbLoc("Discount"), -estimate.discountAmount) }
            if estimate.taxAmount > 0 { totalRow(mbLoc("Tax") + " (\(estimate.taxRatePercent.formatted())%)", estimate.taxAmount) }
            Divider()
            totalRow(mbLoc("Total"), estimate.total, bold: true)
            if estimate.depositAmount > 0 {
                totalRow(mbLoc("Required Deposit"), estimate.depositAmount)
            }
    }

    private var notesCard: some View {
        card {
            if !estimate.customerNotes.isEmpty {
                Text("Notes").font(.headline)
                Text(estimate.customerNotes).foregroundStyle(GLTheme.textSecondary)
            }
            if !estimate.terms.isEmpty {
                Text("Terms").font(.headline).padding(.top, estimate.customerNotes.isEmpty ? 0 : 6)
                Text(estimate.terms).font(.footnote).foregroundStyle(GLTheme.textSecondary)
            }
        }
    }

    // MARK: - Helpers

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

    private func totalRow(_ label: String, _ amount: Double, bold: Bool = false) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(amount.formatted(.appMoney))
                .monospacedDigit()
        }
        .fontWeight(bold ? .bold : .regular)
    }

    /// Re-renders the PDF and builds the compose content at the tap — SendPreparer fills it, the
    /// same content the assistant's send hands over. A PDF that couldn't be made is never sent.
    private func openComposer(_ action: SendAction) {
        guard regeneratePDF() else {
            pdfFailed = true
            return
        }
        composeContent = SendPreparer.estimate(estimate, business: businessProfiles.first, pdfURL: pdfURL)
        sendAction = action
    }

    /// The Mail / Messages compose sheet, pre-filled with branded content and attachments.
    @ViewBuilder
    func sendSheet(for action: SendAction) -> some View {
        if let content = composeContent {
            composer(for: action, content: content, business: businessProfiles.first)
        }
    }

    @ViewBuilder
    private func composer(for action: SendAction, content: ComposeContent, business: BusinessProfile?) -> some View {
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
            // Logo first (renders as an inline image), then the estimate PDF.
            MessageComposeView(
                recipients: content.textRecipients,
                body: content.plainBody,
                attachmentURLs: content.messageAttachmentURLs
            ) { outcome in sendAction = nil; noteSend(outcome) }
        }
    }

    var statusSubtitle: String {
        switch estimate.status {
        case .draft: return mbLoc("Draft · Not yet sent")
        case .sent: return mbLoc("Sent · Awaiting response")
        case .accepted: return mbLoc("Approved manually by you")
        case .declined: return mbLoc("Declined by customer")
        }
    }

    private func setStatus(_ newStatus: EstimateStatus) {
        guard ReadOnlyGate.allows(.saveEstimate, into: $readOnlyRefusal) else { return }
        do {
            try EstimateService.setStatus(estimate, newStatus, in: modelContext)
        } catch {
            DomainError.present(error, readOnly: $readOnlyRefusal, domainError: $domainError)
        }
    }

    /// Re-renders the PDF; false when it couldn't be made (the stale URL is cleared, never sent).
    @discardableResult
    private func regeneratePDF() -> Bool {
        // Always render so a brand-new user can at least Preview/Share what they built — don't dead-end
        // them behind a complete business profile. A missing profile just renders a blank letterhead,
        // which the preview makes obvious so they know to fill it in.
        pdfURL = EstimatePDF.render(estimate, business: businessProfiles.first)
        return pdfURL != nil
    }

    private func scheduleJob() {
        // Scheduling creates a new job, so it honors the same free-tier cap as a blank one.
        if AccessGate.attemptCreate(ScheduledJob.self, cap: FreeTier.jobs, in: modelContext,
                                    subscription: subscription, operation: .scheduleJob,
                                    paywall: $showingPaywall, refusal: $readOnlyRefusal) {
            showingSchedule = true
        }
    }

    private func convertToContract() {
        guard ReadOnlyGate.allows(.saveJob, into: $readOnlyRefusal) else { return }
        guard AccessGate.attemptCreate(Contract.self, cap: FreeTier.jobs, in: modelContext,
                                       subscription: subscription, operation: .saveJob,
                                       paywall: $showingPaywall, refusal: $readOnlyRefusal) else { return }
        if estimate.isOptionsMode {
            isConvertingToContract = true
            chosenOptionIDs = []
            showingOptionPicker = true
        } else {
            performConvertToContract(chosenIDs: nil)
        }
    }

    private func performConvertToContract(chosenIDs: Set<PersistentIdentifier>?) {
        guard ReadOnlyGate.allows(.saveJob, into: $readOnlyRefusal) else { return }
        let existingContracts = (try? modelContext.fetch(FetchDescriptor<Contract>())) ?? []
        let number = Contract.nextNumber(after: existingContracts)
        let contract = Contract(
            number: number,
            title: estimate.jobTitle.isEmpty ? estimate.customerDisplayName : estimate.jobTitle,
            customerName: estimate.customerDisplayName,
            customerEmail: estimate.customerEmail,
            customerPhone: estimate.customerPhone,
            startDate: .now,
            durationDays: 1,
            isAllDay: true,
            notes: estimate.customerNotes,
            terms: estimate.terms,
            serviceAddress: estimate.serviceAddress,
            status: .draft,
            customer: estimate.customer,
            estimate: estimate
        )
        modelContext.insert(contract)

        let groupsToConvert = estimate.sortedGroups.filter { group in
            if let chosenIDs {
                return chosenIDs.contains(group.persistentModelID)
            }
            return true
        }

        for (gIndex, group) in groupsToConvert.enumerated() {
            let contractGroup = ContractGroup(name: group.name, note: group.note, sortIndex: gIndex)
            contractGroup.contract = contract
            modelContext.insert(contractGroup)
            for (lIndex, item) in group.sortedLineItems.enumerated() {
                let line = ContractLineItem(
                    name: item.name,
                    details: item.details,
                    quantity: item.quantity,
                    unit: item.unit,
                    unitPrice: item.unitPrice,
                    kind: item.kind,
                    isTaxable: item.isTaxable,
                    sortIndex: lIndex
                )
                line.group = contractGroup
                modelContext.insert(line)
            }
        }

        if estimate.status != .accepted {
            estimate.status = .accepted
        }

        let job = ScheduledJob(customer: estimate.customer)
        job.title = contract.title
        job.contract = contract
        job.estimate = estimate
        job.customerName = contract.customerName
        job.startDate = contract.startDate
        job.durationDays = contract.durationDays
        job.isAllDay = contract.isAllDay
        job.serviceAddress = contract.serviceAddress
        contract.scheduledJob = job
        modelContext.insert(job)

        modelContext.saveChanges()
        convertedContract = contract
    }

    private func convertToInvoice() {
        // Converting creates a new invoice, so it honors the same free-tier cap as a blank one.
        guard AccessGate.attemptCreate(Invoice.self, cap: FreeTier.invoices, in: modelContext,
                                       subscription: subscription, operation: .convertEstimateToInvoice,
                                       paywall: $showingPaywall, refusal: $readOnlyRefusal) else { return }
        // If this estimate was already converted, confirm before minting a second invoice for one job
        // (otherwise a revisit + tap silently double-counts revenue).
        if let existing = EstimateService.existingInvoice(convertedFrom: estimate, in: modelContext) {
            pendingReconvertNumber = existing.number
            return
        }
        beginConvert()
    }

    /// Which option(s) the customer chose, asked before converting (EstimateOptionPickerSheet).
    var optionPickerSheet: some View {
        EstimateOptionPickerSheet(estimate: estimate, chosenIDs: $chosenOptionIDs, confirmTitle: "Convert",
                                  onCancel: {
                                      showingOptionPicker = false
                                      isConvertingToContract = false
                                  }) {
            let chosen = estimate.sortedGroups.filter {
                chosenOptionIDs.contains($0.persistentModelID)
            }
            showingOptionPicker = false
            // A sync from another device can delete the selected
            // group(s) while the sheet is open; an empty selection
            // must not mint a $0 invoice. Alert AND log (house rule).
            guard !chosen.isEmpty else {
                Logger.data.error("options convert refused: selected groups vanished (synced delete) — nothing minted")
                sendFailureMessage = mbLoc("Those options are no longer on this estimate. Pull down to refresh, then try again.")
                isConvertingToContract = false
                return
            }
            if isConvertingToContract {
                isConvertingToContract = false
                performConvertToContract(chosenIDs: Set(chosen.map(\.persistentModelID)))
            } else {
                performConvert(chosenIDs: Set(chosen.map(\.persistentModelID)))
            }
        }
    }

    /// OPTIONS estimate: ask which option(s) the customer chose before minting
    /// the invoice — multiple selections are allowed. Classic estimate converts
    /// directly.
    private func beginConvert() {
        isConvertingToContract = false
        if estimate.isOptionsMode {
            chosenOptionIDs = []
            showingOptionPicker = true
        } else {
            performConvert(chosenIDs: nil)
        }
    }

    /// EstimateService numbers the invoice, builds it (`Invoice.make`) and saves it — the same path
    /// the assistant uses. `force`: the already-converted question was asked (or didn't apply) in
    /// `convertToInvoice()`, so the service must not answer it again.
    private func performConvert(chosenIDs: Set<PersistentIdentifier>?) {
        do {
            switch try EstimateService.convertToInvoice(estimate, chosenGroupIDs: chosenIDs, force: true,
                                                        in: modelContext) {
            case .created(let invoice), .alreadyConverted(let invoice):
                convertedInvoice = invoice
            }
        } catch {
            DomainError.present(error, readOnly: $readOnlyRefusal, domainError: $domainError)
        }
    }

    var formattedAddress: String {
        let a = estimate.customerAddress
        let cityLine = [a.city, a.state].filter { !$0.isEmpty }.joined(separator: ", ")
        let cityZip = [cityLine, a.postalCode].filter { !$0.isEmpty }.joined(separator: " ")
        return [a.street1, a.street2 ?? "", cityZip]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }
}

/// Multi-select of an OPTIONS estimate's groups — the customer may take more than one option (a
/// recurring plan plus a one-time add-on). Tapping a row only selects it; the confirm button applies
/// the choice and Cancel keeps none (law 63). Small sheet, per the alerts-not-popovers house rule.
/// One picker for both places that ask: Convert to Invoice and a job's first invoice.
struct EstimateOptionPickerSheet: View {
    let estimate: Estimate
    @Binding var chosenIDs: Set<PersistentIdentifier>
    /// "Convert" on the estimate; "Done" on the invoice form (a picker opened from an edit screen).
    let confirmTitle: LocalizedStringKey
    let onCancel: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        NavigationStack {
            List(estimate.sortedGroups) { group in
                Button {
                    if chosenIDs.contains(group.persistentModelID) {
                        chosenIDs.remove(group.persistentModelID)
                    } else {
                        chosenIDs.insert(group.persistentModelID)
                    }
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(group.name.isEmpty ? mbLoc("Option") : group.name)
                                .foregroundStyle(GLTheme.textPrimary)
                            Text(group.optionTotals(taxRatePercent: estimate.taxRatePercent).total
                                .formatted(.money))
                                .font(.subheadline)
                                .foregroundStyle(GLTheme.textSecondary)
                        }
                        Spacer()
                        Image(systemName: chosenIDs.contains(group.persistentModelID)
                              ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(GLTheme.accentFill)
                    }
                }
            }
            .glFormBackground()
            .navigationTitle(GLScript.padded(mbLoc("Chosen Options")))
            .toolbarTitleDisplayMode(.large)
            .contentMargins(.top, GLScript.titleClearance(for: GLScript.padded(mbLoc("Chosen Options"))), for: .scrollContent)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onCancel() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(confirmTitle) { onConfirm() }
                        .disabled(chosenIDs.isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
    }
}

#Preview {
    let estimate = Estimate(jobTitle: "Master bath tile install", customer: Customer(firstName: "Jane", lastName: "Doe"))
    estimate.number = "EST-0001"
    estimate.taxRatePercent = 8.25
    return NavigationStack {
        EstimateDetailScreen(estimate: estimate)
    }
    .modelContainer(for: [Customer.self, Estimate.self], inMemory: true)
}
