//
//  InvoiceDetailScreen.swift
//  GLSmallBusiness
//
//  Created by Gold Life LLC on 5/28/26.
//

import SwiftUI
import PhotosUI
import GoldLifeUI
import GoldLifeAI
import SwiftData
import MessageUI

struct InvoiceStatusBadge: View {
    let invoice: Invoice

    private var color: Color {
        if invoice.isPaid { return GLTheme.statusGood }
        if invoice.isOverdue { return GLTheme.statusAttention }
        if invoice.isPartiallyPaid { return GLTheme.statusAttention }
        switch invoice.status {
        case .draft: return GLTheme.textSecondary
        case .sent: return GLTheme.accentFill
        }
    }

    var body: some View {
        Text(invoice.displayStatus)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Capsule().fill(color.opacity(0.18)))
            .foregroundStyle(color)
    }
}

struct InvoiceDetailScreen: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(SubscriptionManager.self) private var subscription
    @Environment(\.scenePhase) private var scenePhase
    @Query private var businessProfiles: [BusinessProfile]
    /// This invoice as the store lists it: one row, or none once it is deleted. A fetch of the
    /// one record (QA F153), still a live @Query so a saved delete redraws the screen.
    @Query private var storedInvoice: [Invoice]
    let invoice: Invoice

    /// The sparkles button (law 58, dual entry points). Off for a record the assistant itself
    /// pushed, so the assistant can never open inside the assistant.
    var showsAssistantButton = true

    init(invoice: Invoice, showsAssistantButton: Bool = true) {
        self.invoice = invoice
        self.showsAssistantButton = showsAssistantButton
        let id = invoice.persistentModelID
        _storedInvoice = Query(filter: #Predicate<Invoice> { $0.persistentModelID == id })
    }

    /// What the model is told is on screen when the sparkles sheet opens.
    private var assistantRecord: GLAIOnScreen? {
        GLAIOnScreen(.invoice, invoice, label: invoice.number.isEmpty ? mbLoc("Invoice") : invoice.number, in: modelContext)
    }

    /// False once this invoice is deleted out from under the view (e.g. its customer was deleted on
    /// another device, cascading the delete here).
    private var stillExists: Bool {
        !invoice.isSavedDelete && !invoice.isDeleted && !storedInvoice.isEmpty
    }

    @State private var showingEdit = false
    /// The paid-invoice lock explanation (PaidInvoiceLock.swift), shown instead of opening the
    /// edit form on a settled invoice.
    @State private var showingPaidLock = false
    /// An approved change order whose "Add to invoice" would settle — and so lock — this invoice,
    /// which already has payments on it; the alert asks first (PaidLockSaveGuard, QA F85). The
    /// order is kept apart from the alert's flag, so dismissing the alert never clears it before
    /// the confirmed add reads it.
    @State private var showingLockingApply = false
    @State private var pendingLockingApply: ChangeOrder?
    @State private var showingPaywall = false
    /// Set when a lapsed subscription refuses a write — the alert names it (ReadOnlyGate.swift).
    @State private var readOnlyRefusal: MBWriteOperation?
    @State private var showingMarkPaidInFull = false
    @State private var showingRecordPayment = false
    @State private var showingSetAmountDue = false
    @State private var sendAction: SendAction?
    /// What the open compose sheet shows, built when the person tapped Email or Text (never while
    /// the screen draws), and discarded with its files when the sheet closes.
    @State private var composeContent: ComposeContent?
    /// The device couldn't compose when the person tapped (ComposeCapability.check).
    @State private var composeUnavailable: ComposeCapability.Channel?
    /// The PDF couldn't be made when the person tapped send.
    @State private var pdfFailed = false
    @State private var pdfURL: URL?
    @State private var showingPreview = false
    @State private var sendFailureMessage: String?
    @State private var showingProfilePrompt = false
    @State private var receiptPayment: InvoicePayment?
    @State private var showingNewChangeOrder = false
    @State private var selectedChangeOrder: ChangeOrder?
    @State private var showingSchedule = false
    @State private var mintingLink = false
    // Unlinked-device send notice (#14): shown once per visit when the business is connected to Stripe
    // but this device has no install token, so invoices send without a Pay button here.
    @State private var showingDeviceUnlinkedNotice = false
    @State private var pendingUnlinkedAction: SendAction?
    @State private var deviceUnlinkedNoticeShown = false
    // Pay-link-unavailable send notice: the business IS connected and this invoice wants a Pay button,
    // but the account can't charge / the link couldn't be minted. Same once-per-visit, never-blocking
    // shape as the unlinked-device notice — silence here had owners emailing invoices believing
    // customers could pay by card.
    @State private var showingPayLinkUnavailableNotice = false
    @State private var pendingPayLinkAction: SendAction?
    @State private var payLinkUnavailableNoticeShown = false
    /// Which reason the notice gives: the account can't take cards, or Stripe couldn't make the link
    /// right now (no signal, a server error) — never the first when it was the second (audit F81).
    @State private var payLinkNoticeIsFailure = false
    /// Over the $50,000 a pay link can charge (audit F81): asked on every send, Send or Cancel.
    @State private var overLimitAction: SendAction?
    /// The pay-status poll came back "this install isn't authorized". A paid link would never be
    /// noticed here, so the invoice would sit Overdue after the customer paid — say so inline.
    @State private var payStatusUnreachable = false
    @State private var stripePaidPrompt: StripePaidPrompt?
    @State private var stripeRecordPrefill: RecordPrefill?
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var previewPhoto: JobAttachment?
    @State private var photoLoadFailed = false
    /// Why a picked file wasn't added (unreadable, or over the backup's 25 MB) — the shared alert.
    @State private var importFailure: FileImportFailure?
    @State private var showingDocImporter = false
    /// A refusal InvoiceService threw that the screen did not predict (DomainErrorAlert.swift).
    @State private var domainError: DomainError?

    private enum SendAction: Int, Identifiable {
        case email, text
        var id: Int { rawValue }
    }

    /// A Stripe-reported "this invoice was paid" prompt awaiting the user's confirmation.
    private struct StripePaidPrompt: Identifiable { let id = UUID(); let amountCents: Int }
    /// Prefill values for opening the Record-payment sheet from the Stripe paid prompt.
    private struct RecordPrefill: Identifiable, Equatable { let id = UUID(); let amount: Double; let linkId: String }

    private var gold: Color { GLTheme.accentFill }

    /// A business name plus at least one way to be reached — the bar for putting this document in
    /// front of a customer. `BusinessProfile.isComplete` owns the rule; this is just the read.
    private var profileIsComplete: Bool { businessProfiles.first?.isComplete == true }

    private var effectiveCustomerPhone: String {
        if !invoice.customerPhone.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return invoice.customerPhone
        }
        return invoice.customer?.phoneNumber ?? ""
    }

    private var effectiveServiceAddress: Address {
        if !invoice.serviceAddress.isEmpty {
            return invoice.serviceAddress
        }
        return invoice.customer?.serviceAddress ?? Address()
    }

    var body: some View {
        // BRANCH, not overlay (CRUD audit 2026-09-02): an overlay still evaluates the body
        // against the deleted record — property reads on a dead @Model trap uncatchably.
        if stillExists { aliveBody } else { DeletedRecordView(title: mbLoc("Invoice"), noun: "this invoice") { dismiss() } }
    }

    @ViewBuilder private var aliveBody: some View {
        ScrollView {
            VStack(spacing: 20) {
                if payStatusUnreachable { payStatusUnreachableCard }
                heroCard
                quickActionBar
                if invoice.autoRemindersEnabled && !invoice.isPaid {
                    remindersCard
                }
                serviceAddressCard
                groupsView
                totalsCard
                paymentsCard
                changeOrdersCard
                photosCard
                documentsCard
                if !invoice.customerNotes.isEmpty || !invoice.terms.isEmpty {
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
        .alert("Sending without a Pay button", isPresented: $showingDeviceUnlinkedNotice) {
            Button("OK") {
                openComposer(pendingUnlinkedAction)
                pendingUnlinkedAction = nil
            }
        } message: {
            Text("This device isn’t linked to Stripe yet, so this invoice won’t include a Pay button. Reconnect in Menu → Connect Stripe.")
        }
        .alert("Sending without a Pay button", isPresented: $showingPayLinkUnavailableNotice) {
            Button("OK") {
                openComposer(pendingPayLinkAction)
                pendingPayLinkAction = nil
            }
        } message: {
            if payLinkNoticeIsFailure {
                Text("Stripe couldn’t make a payment link right now, so this invoice won’t include a Pay button. To add one, try sending again in a few minutes.")
            } else {
                Text("Your Stripe account can’t take card payments right now, so this invoice won’t include a Pay button. Open Menu → Connect Stripe to set it up again.")
            }
        }
        .alert("Card payment limit", isPresented: Binding(get: { overLimitAction != nil },
                                                          set: { if !$0 { overLimitAction = nil } }),
               presenting: overLimitAction) { action in
            Button("Send") {
                overLimitAction = nil
                openComposer(action)
            }
            Button("Cancel", role: .cancel) { overLimitAction = nil }
        } message: { _ in
            Text("Card payments are limited to $50,000 per invoice. Send without a Pay button?")
        }
        .overlay {
            if mintingLink {
                ZStack {
                    Color.black.opacity(0.18).ignoresSafeArea()
                    ProgressView("Preparing payment link…")
                        .padding(20)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
            }
        }
        .navigationTitle(GLScript.padded(invoice.number.isEmpty ? mbLoc("Invoice") : invoice.number))
        .toolbarTitleDisplayMode(.large)
        .contentMargins(.top, GLScript.titleClearance(for: GLScript.padded(invoice.number.isEmpty ? mbLoc("Invoice") : invoice.number)), for: .scrollContent)
        .toolbar {
            // A pure check: the id is minted in the button's action, never in this builder.
            if showsAssistantButton, invoice.canBeNamedToAssistant {
                ToolbarItem(placement: .topBarTrailing) {
                    MBAssistantButton { assistantRecord }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Section {
                        Button {
                            if invoice.isMoneyLocked { showingPaidLock = true } else { showingEdit = true }
                        } label: { Label("Edit", systemImage: "pencil") }
                        if !invoice.isPaid {
                            Button { showingMarkPaidInFull = true } label: { Label("Mark paid in full", systemImage: "checkmark.circle") }
                            Button { togglePastDue() } label: {
                                Label(invoice.isMarkedPastDue ? "Clear past due" : "Mark past due", systemImage: "clock.badge.exclamationmark")
                            }
                        }
                        Button { scheduleJob() } label: { Label("Schedule", systemImage: "calendar.badge.plus") }
                        Button { showingRecordPayment = true } label: { Label("Record payment", systemImage: "dollarsign.circle") }
                        Button { showingSetAmountDue = true } label: { Label("Ask for a deposit", systemImage: "banknote") }
                    }
                    Section {
                        Button { showingNewChangeOrder = true } label: { Label("New change order", systemImage: "plus.rectangle.on.rectangle") }
                        if !invoice.sortedChangeOrders.isEmpty {
                            Menu {
                                ForEach(invoice.sortedChangeOrders) { changeOrder in
                                    Button { selectedChangeOrder = changeOrder } label: {
                                        Text(changeOrder.title.isEmpty ? changeOrder.number : "\(changeOrder.number) · \(changeOrder.title)")
                                    }
                                }
                            } label: { Label("Open change order", systemImage: "rectangle.on.rectangle") }
                        }
                    }
                    if !invoice.sortedPayments.isEmpty {
                        Menu {
                            ForEach(invoice.sortedPayments) { payment in
                                Button { receiptPayment = payment } label: {
                                    Text("\(payment.amount.formatted(.appMoney)) · \(payment.date.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted).locale(MBLocalization.currentLocale)))")
                                }
                            }
                        } label: { Label("Send a receipt", systemImage: "doc.text") }
                    }
                    if businessProfiles.first?.stripeIsConnected == true {
                        Section {
                            Toggle(isOn: includePayLinkBinding) {
                                Label("Include Pay button", systemImage: "link")
                            }
                        }
                    }
                    if businessProfiles.first?.zelleIsConfigured == true {
                        Section {
                            Toggle(isOn: includeZelleBinding) {
                                Label("Include Zelle details", systemImage: "qrcode")
                            }
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .accessibilityLabel("More")
            }
        }
        .onAppear { if pdfURL == nil { regeneratePDF() } }
        .task { await pollPayStatus() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await pollPayStatus() } }
        }
        .onChange(of: showingEdit) { _, isShowing in
            if !isShowing { regeneratePDF() }
        }
        .onChange(of: showingRecordPayment) { _, isShowing in
            if !isShowing { regeneratePDF() }
        }
        .onChange(of: showingSetAmountDue) { _, isShowing in
            if !isShowing { regeneratePDF() }
        }
        .navigationDestination(isPresented: $showingSchedule) {
            ScheduleJobSheet(source: .invoice(invoice))
        }
        .paywallSheet(isPresented: $showingPaywall)
        .readOnlyRefusalAlert($readOnlyRefusal)
        .domainErrorAlert($domainError)
        .navigationDestination(isPresented: $showingEdit) {
            InvoiceFormScreen(editing: invoice)
        }
        .sheet(isPresented: $showingRecordPayment) {
            RecordPaymentSheet(invoice: invoice).glAppearance(colorScheme)
        }
        .sheet(item: $stripeRecordPrefill) { prefill in
            RecordPaymentSheet(invoice: invoice, prefillAmount: prefill.amount, prefillMethod: .stripe,
                               prefillStripeLinkId: prefill.linkId)
                .glAppearance(colorScheme)
        }
        .onChange(of: stripeRecordPrefill) { _, value in
            if value == nil { regeneratePDF() }
        }
        .sheet(isPresented: $showingSetAmountDue) {
            SetAmountDueSheet(invoice: invoice).glAppearance(colorScheme)
        }
        .sheet(item: $sendAction, onDismiss: {
            SendPreparer.discard(composeContent)
            composeContent = nil
        }) { action in
            sendSheet(for: action).glAppearance(colorScheme)
        }
        .composeUnavailableAlert($composeUnavailable)
        .pdfFailureAlert($pdfFailed)
        .sheet(isPresented: $showingPreview) {
            if let pdfURL {
                DocumentPreviewSheet(url: pdfURL,
                                     title: invoice.number.isEmpty ? "Invoice" : "Invoice \(invoice.number)",
                                     subject: InvoiceMessage.subject(invoice: invoice, business: businessProfiles.first),
                                     message: InvoiceMessage.plainBody(invoice: invoice, business: businessProfiles.first))
                    .glAppearance(colorScheme)
            }
        }
        .sheet(item: $receiptPayment) { payment in
            PaymentReceiptSheet(invoice: invoice, payment: payment).glAppearance(colorScheme)
        }
        .sheet(isPresented: $showingMarkPaidInFull) {
            MarkPaidInFullSheet(invoice: invoice) {
                regeneratePDF()
            }
            .glAppearance(colorScheme)
        }
        .onChange(of: showingMarkPaidInFull) { _, isShowing in
            if !isShowing { regeneratePDF() }
        }
        .navigationDestination(isPresented: $showingNewChangeOrder) {
            ChangeOrderFormScreen(invoice: invoice)
        }
        .navigationDestination(item: $selectedChangeOrder) { changeOrder in
            ChangeOrderDetailSheet(changeOrder: changeOrder)
        }
        .onChange(of: selectedChangeOrder) { _, order in
            if order == nil { regeneratePDF() }
        }
        .onChange(of: showingNewChangeOrder) { _, isShowing in if !isShowing { regeneratePDF() } }
        .paidInvoiceLockAlert(isPresented: $showingPaidLock)
        .paidLockSaveAlert(isPresented: $showingLockingApply, action: "Add to invoice") {
            if let order = pendingLockingApply { addToInvoice(order, confirmedLock: true) }
            pendingLockingApply = nil
        }
        .alert("Complete your business profile", isPresented: $showingProfilePrompt) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("Add your business name and a phone or email in Menu → My Business Details so they appear on your invoice.")
        }
        .alert("Couldn’t send", isPresented: Binding(get: { sendFailureMessage != nil },
                                                     set: { if !$0 { sendFailureMessage = nil } })) {
            Button("OK", role: .cancel) { sendFailureMessage = nil }
        } message: {
            Text(sendFailureMessage ?? "")
        }
        .alert("Payment received", isPresented: Binding(get: { stripePaidPrompt != nil },
                                                        set: { if !$0 { stripePaidPrompt = nil } }),
               presenting: stripePaidPrompt) { prompt in
            Button("Record payment") {
                stripeRecordPrefill = RecordPrefill(amount: Double(prompt.amountCents) / 100,
                                                    linkId: invoice.stripePaymentLinkId)
                stripePaidPrompt = nil
            }
            Button("Not now", role: .cancel) { stripePaidPrompt = nil }
        } message: { prompt in
            Text("Stripe reports this invoice was paid (\((Double(prompt.amountCents) / 100).formatted(.appMoney))). Record it on the invoice?")
        }
        .fileImporter(isPresented: $showingDocImporter, allowedContentTypes: [.pdf, .image]) { result in
            guard case .success(let url) = result else { return }
            guard ReadOnlyGate.allows(.addJobAttachment, into: $readOnlyRefusal) else { return }
            // Size-checked first, then read off the main thread (F124).
            Task {
                switch await FileImport.read(url) {
                case .success(let data):
                    do {
                        try DocumentService.attachDocument(data, name: url.lastPathComponent, to: .invoice(invoice),
                                                           in: modelContext)
                    } catch {
                        DomainError.present(error, readOnly: $readOnlyRefusal, domainError: $domainError)
                    }
                case .failure(let failure):
                    importFailure = failure
                }
            }
        }
        .task(id: photoItems) { await addPickedPhotos() }
        .onDisappear { photoItems = [] }
        .photoLoadFailureAlert($photoLoadFailed)
        .fileImportFailureAlert($importFailure)
        .fullScreenCover(item: $previewPhoto) { photo in
            JobPhotoViewer(attachment: photo)
        }
    }

    /// The Mail / Messages compose sheet, pre-filled by SendPreparer (the same content the
    /// assistant's send hands over): branded bodies with the current pay link, the PDF, and the
    /// invoice's photos and documents. The content was built at the tap (`openComposer`).
    @ViewBuilder
    private func sendSheet(for action: SendAction) -> some View {
        let business = businessProfiles.first
        if let content = composeContent {
            composer(for: action, content: content, business: business)
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
                attachmentURL: content.pdfURL,
                additionalAttachments: content.mailAttachments
            ) { outcome in sendAction = nil; noteSend(outcome) }
        case .text:
            MessageComposeView(
                recipients: content.textRecipients,
                body: content.plainBody,
                attachmentURLs: content.messageAttachmentURLs
            ) { outcome in sendAction = nil; noteSend(outcome) }
        }
    }

    /// Builds the compose content (and writes the invoice's photos and documents into this send's
    /// own folder) right before the sheet opens — after any pay-link mint, so the body carries it.
    @MainActor
    private func openComposer(_ action: SendAction?) {
        guard let action else { return }
        SendPreparer.discard(composeContent)
        composeContent = SendPreparer.invoice(invoice, business: businessProfiles.first, pdfURL: pdfURL)
        sendAction = action
    }

    /// The Share button's files, written at the tap into this share's own folder.
    private func preparedShare() -> PreparedShare? {
        let files = SendPreparer.invoiceFiles(invoice, pdfURL: pdfURL)
        return PreparedShare(urls: files.urls, folder: files.folder)
    }

    private func addPickedPhotos() async {
        guard !photoItems.isEmpty else { return }
        guard ReadOnlyGate.allows(.addJobAttachment, into: $readOnlyRefusal) else {
            photoItems = []
            return
        }
        let items = Array(photoItems.prefix(50))
        var imported: [Data] = []
        for item in items {
            if Task.isCancelled { break }
            guard let data = try? await item.loadTransferable(type: Data.self) else {
                if Task.isCancelled { break }
                photoLoadFailed = true
                continue
            }
            // 1024 px, off the main actor (law 62), like JobDetailScreen.
            let jpeg = await ImageDownsampler.intakeJPEG(from: data)
            if Task.isCancelled { break }
            if let jpeg {
                imported.append(jpeg)
            } else {
                photoLoadFailed = true
            }
        }
        // Keep whatever imported before a cancellation (JobDetailScreen's rule). DocumentService
        // attaches and saves them in one write.
        if !imported.isEmpty {
            do {
                try DocumentService.attachPhotos(imported, to: .invoice(invoice), in: modelContext)
            } catch {
                DomainError.present(error, readOnly: $readOnlyRefusal, domainError: $domainError)
            }
        }
        guard !Task.isCancelled else { return }
        photoItems = []
    }

    private func delete(_ attachment: JobAttachment) {
        guard ReadOnlyGate.allows(.deleteJobAttachment, into: $readOnlyRefusal) else { return }
        do {
            try DeletionService.delete([.attachment(attachment)], origin: .screen, in: modelContext)
        } catch {
            DomainError.present(error, readOnly: $readOnlyRefusal, domainError: $domainError)
        }
    }

    private func importJobPhotos(_ job: ScheduledJob) {
        guard ReadOnlyGate.allows(.addJobAttachment, into: $readOnlyRefusal) else { return }
        do {
            try InvoiceService.importJobAttachments(JobAttachmentSelection(photos: true), from: job,
                                                    into: invoice, in: modelContext)
        } catch {
            DomainError.present(error, readOnly: $readOnlyRefusal, domainError: $domainError)
        }
    }

    /// Tell the user only when a send actually failed; sent/cancelled needs no interruption.
    private func noteSend(_ outcome: SendOutcome) {
        if outcome == .failed {
            // Resolved through mbLoc rather than left a bare literal: this lands in a String @State
            // that `Text(String)` renders VERBATIM, so an unlocalized literal stays English in Spanish.
            sendFailureMessage = mbLoc("We couldn’t send your invoice. Check your internet connection and try again.")
        }
    }

    /// Re-renders the PDF; false when it couldn't be made (the stale URL is cleared, never sent).
    @discardableResult
    private func regeneratePDF() -> Bool {
        // Always render so the document is previewable/shareable even before the business profile is
        // filled in — don't dead-end a new user. (See EstimateDetailScreen for the rationale.)
        pdfURL = InvoicePDF.render(invoice, business: businessProfiles.first)
        return pdfURL != nil
    }

    /// The Pay-button toggle writes to the invoice, so a lapsed app refuses the SET and leaves the
    /// toggle where it was. A `Binding` has no other place to say no, which is exactly why the
    /// refusal alert is bound to screen state rather than raised at the tap site.
    private var includePayLinkBinding: Binding<Bool> {
        Binding(get: { invoice.includePayLink },
                set: { newValue in
                    guard ReadOnlyGate.allows(.togglePayLink, into: $readOnlyRefusal) else { return }
                    do {
                        try InvoiceService.setIncludePayLink(invoice, newValue, in: modelContext)
                    } catch {
                        DomainError.present(error, readOnly: $readOnlyRefusal, domainError: $domainError)
                    }
                })
    }

    private var includeZelleBinding: Binding<Bool> {
        Binding(get: { invoice.includeZelle },
                set: { newValue in
                    guard ReadOnlyGate.allows(.togglePayLink, into: $readOnlyRefusal) else { return }
                    do {
                        try InvoiceService.setIncludeZelle(invoice, newValue, in: modelContext)
                        regeneratePDF()
                    } catch {
                        DomainError.present(error, readOnly: $readOnlyRefusal, domainError: $domainError)
                    }
                })
    }

    /// The pay link to embed in THIS send, or nil (SendPreparer.currentPayLinkURL — never mints).
    private func currentPayLinkURL() -> String? {
        SendPreparer.currentPayLinkURL(for: invoice, business: businessProfiles.first)
    }

    /// Tell the owner ONCE per visit that this send goes out without a Pay button, then send anyway.
    /// Same shape as the unlinked-device notice: honest about the degrade, never blocking.
    @MainActor
    private func noticePayLinkUnavailable(_ action: SendAction, failure: Bool = false) {
        if payLinkUnavailableNoticeShown {
            openComposer(action)
        } else {
            payLinkUnavailableNoticeShown = true
            payLinkNoticeIsFailure = failure
            pendingPayLinkAction = action
            showingPayLinkUnavailableNotice = true
        }
    }

    /// Prepare a send: rebuild the PDF, then (if this invoice should carry a pay link) mint/refresh the
    /// link before presenting the composer. Fails OPEN — any problem just sends the invoice without a Pay
    /// button rather than blocking the user. The rules are SendPreparer's (shared with the assistant);
    /// this screen owns only the spinner and the once-per-visit notices.
    @MainActor
    private func prepareSend(_ action: SendAction) {
        // Belt and braces: the menu rows above already refuse, but minting a Stripe pay link is a
        // real-world side effect (a chargeable link created in the owner's Stripe account), so the
        // function that does it carries its own guard.
        guard ReadOnlyGate.allows(.mintPayLink, into: $readOnlyRefusal) else { return }
        // A PDF that couldn't be made is never sent (or replaced by the last one): say so instead.
        guard regeneratePDF() else {
            pdfFailed = true
            return
        }
        switch SendPreparer.payLinkPlan(for: invoice, business: businessProfiles.first) {
        case .decided(let outcome):
            present(outcome, for: action)
        case .mint(let accountId):
            mintingLink = true
            Task { @MainActor in
                defer { mintingLink = false }
                do {
                    let outcome = try await SendPreparer.mintPayLink(for: invoice, accountId: accountId,
                                                                     in: modelContext)
                    // Re-validate after the await: deleted mid-mint — don't open the composer.
                    guard stillExists else { return }
                    present(outcome, for: action)
                } catch {
                    DomainError.present(error, readOnly: $readOnlyRefusal, domainError: $domainError)
                }
            }
        }
    }

    /// Opens the composer, or first the once-per-visit notice the outcome calls for.
    @MainActor
    private func present(_ outcome: PayLinkOutcome, for action: SendAction) {
        switch outcome {
        case .ready:
            openComposer(action)
        case .unavailable:
            noticePayLinkUnavailable(action)
        case .linkFailed:
            noticePayLinkUnavailable(action, failure: true)
        case .overLimit:
            overLimitAction = action
        case .alreadyPaid(let amountCents):
            // The customer already paid this invoice's link and no payment records it: nothing was
            // minted, and nothing is sent. The poll's own "Payment received" prompt asks to record it;
            // the next send then asks only for what is still owed (audit F14).
            stripePaidPrompt = StripePaidPrompt(amountCents: amountCents)
        case .deviceUnlinked:
            // Connected business, but THIS device holds no install token (fresh device, iCloud Keychain
            // off): tell the user once per visit that the Pay button will be missing and how to fix it,
            // then send without the link as usual.
            if deviceUnlinkedNoticeShown {
                openComposer(action)
            } else {
                deviceUnlinkedNoticeShown = true
                pendingUnlinkedAction = action
                showingDeviceUnlinkedNotice = true
            }
        case .vanished:
            return
        }
    }

    /// True once a recorded payment carries this invoice's current pay-link id — the reconciliation guard
    /// (`SendPreparer.payLinkIsRecorded`, shared with the send's paid check).
    private var stripeLinkAlreadyRecorded: Bool { SendPreparer.payLinkIsRecorded(invoice) }

    /// Poll the backend for this invoice's pay status; while the paid link isn't yet reconciled into an
    /// `InvoicePayment`, prompt to record it. Re-checks `stillExists` after the await (the invoice can be
    /// cascade-deleted from another device mid-poll).
    private func pollPayStatus() async {
        // Skipped without an alert while lapsed — nobody asked for this: it runs from `.task` and
        // on every foreground. It writes `stripePayLinkStatus` and can raise the "record it?"
        // prompt, and both are things a read-only app must not do on someone's behalf. The refusal
        // the person WILL see is the one on Record payment, if they go looking for it.
        //
        // Routed through the gate rather than `isReadOnly` so it is not SILENT to the developer
        // either: this used to return with neither an alert nor a log, which made "the invoice
        // never went Paid" unanswerable from a support log. `allowsUnattended` writes the line.
        guard ReadOnlyGate.allowsUnattended(.recordPayment, subscription) else { return }
        guard StripeConfig.isConfigured, stillExists,
              !invoice.stripeAppInvoiceId.isEmpty,
              !invoice.stripePaymentLinkId.isEmpty,
              !invoice.isPaid,
              !stripeLinkAlreadyRecorded else { return }
        let result: StripePayLinkStatusResponse
        do {
            result = try await StripeBackendClient.shared.payLinkStatus(appInvoiceId: invoice.stripeAppInvoiceId)
            payStatusUnreachable = false
        } catch let error as StripeBackendError where error.isBindingLost {
            // Not "not paid yet" — the backend won't answer for this install at all. Collapsing the two
            // into one silent nil is how a paid invoice sat Overdue forever with nothing shown.
            payStatusUnreachable = true
            return
        } catch {
            return          // couldn't reach it; the next open / foreground re-checks
        }
        guard result.isPaid else { return }
        guard stillExists, !stripeLinkAlreadyRecorded else { return }   // re-validate after the await
        invoice.stripePayLinkStatus = .paid                              // display hint only; not the reconcile gate
        if invoice.balanceDue > 0.005 {
            let cents = result.amountPaidCents ?? invoice.stripePaymentLinkAmountCents
            stripePaidPrompt = StripePaidPrompt(amountCents: cents)
        }
    }

    private func scheduleJob() {
        // Scheduling creates a new job, so it honors the same free-tier cap as a blank one.
        if AccessGate.attemptCreate(ScheduledJob.self, cap: FreeTier.jobs, in: modelContext,
                                    subscription: subscription, operation: .scheduleJob,
                                    paywall: $showingPaywall, refusal: $readOnlyRefusal) {
            showingSchedule = true
        }
    }

    /// Inline, never blocking: the app can't read this invoice's card-payment status any more, so a
    /// payment made through the Pay button won't show up here on its own.
    private var payStatusUnreachableCard: some View {
        card {
            Label {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Can’t check card payments")
                        .font(.subheadline.weight(.semibold))
                    Text("This device isn’t linked to your Stripe account, so a card payment on this invoice won’t show up here. Open Menu → Connect Stripe and reconnect, or record the payment yourself.")
                        .font(.footnote)
                        .foregroundStyle(GLTheme.textSecondary)
                }
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(GLTheme.accent)
            }
        }
    }

    
    
    private var heroCard: some View {
        card {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top) {
                    Text(invoice.balanceDue.formatted(.appMoney))
                        .font(.glAmountRow)
                        .foregroundStyle(GLTheme.textPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                    Spacer()
                    InvoiceStatusBadge(invoice: invoice)
                }
                
                VStack(alignment: .leading, spacing: 4) {
                    Text(invoice.jobTitle.isEmpty ? mbLoc("Untitled invoice") : invoice.jobTitle)
                        .font(.title3.weight(.semibold))
                    if let source = invoice.sourceEstimateNumber, !source.isEmpty {
                        Text("\(invoice.number) · From \(source)")
                            .font(.subheadline)
                            .foregroundStyle(GLTheme.textSecondary)
                    } else {
                        Text(invoice.number)
                            .font(.subheadline)
                            .foregroundStyle(GLTheme.textSecondary)
                    }
                    
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Billed to")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(GLTheme.textSecondary)
                        Text(invoice.customerDisplayName)
                            .font(.headline)
                        if let business = invoice.customerBusinessName, !business.isEmpty {
                            Text(business).foregroundStyle(GLTheme.textSecondary)
                        }
                        if !invoice.customerEmail.isEmpty || !effectiveCustomerPhone.isEmpty {
                            HStack(spacing: 8) {
                                if !invoice.customerEmail.isEmpty {
                                    // Law 84: tappable, opens the person's chosen app.
                                    GLContactLink(.email, invoice.customerEmail)
                                        .font(.caption)
                                        .foregroundStyle(GLTheme.textSecondary)
                                }
                                if !invoice.customerEmail.isEmpty && !effectiveCustomerPhone.isEmpty {
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
                
                labeledRow(mbLoc("Created"), invoice.createdAt.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted).locale(MBLocalization.currentLocale)))
                labeledRow(mbLoc("Terms"), invoice.paymentTerms.label)
                labeledRow(mbLoc("Due"), invoice.dueDate.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted).locale(MBLocalization.currentLocale)))
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
                    prepareSend(.email)
                }
                .disabled(invoice.recipientEmail.isEmpty || !ComposeCapability.canSend(.mail))

                GLDocumentActionButton("Text", systemImage: "message") {
                    guard ReadOnlyGate.allows(.sendDocument, into: $readOnlyRefusal),
                          ComposeCapability.check(.text, into: $composeUnavailable) else { return }
                    prepareSend(.text)
                }
                .disabled(invoice.recipientPhone.isEmpty || !ComposeCapability.canSend(.text))

                if pdfURL != nil {
                    // The files (PDF, photos, documents) are written at the tap, never while this
                    // bar draws, and removed when the share sheet closes.
                    MBPreparedShareButton(
                        subject: InvoiceMessage.subject(invoice: invoice, business: businessProfiles.first),
                        message: InvoiceMessage.plainBody(invoice: invoice, business: businessProfiles.first, payLinkURL: currentPayLinkURL()),
                        refused: $readOnlyRefusal,
                        prepare: preparedShare
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

    private var remindersCard: some View {
        card {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("Automated Reminders", systemImage: "bell.badge.fill")
                        .font(.headline)
                        .foregroundStyle(GLTheme.accent)
                    Spacer()
                    Text("Active")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(GLTheme.statusGood)
                }
                Text("Client receives friendly automated payment reminders from noreply@softwarebygl.com based on the due date (\(invoice.reminderFrequency.label.lowercased())).")
                    .font(.footnote)
                    .foregroundStyle(GLTheme.textSecondary)
                if let lastSent = invoice.lastReminderSentAt {
                    Text("Last reminder sent: \(lastSent.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(MBLocalization.currentLocale)))")
                        .font(.caption)
                        .foregroundStyle(GLTheme.textSecondary)
                }
            }
        }
    }

    private func togglePastDue() {
        guard ReadOnlyGate.allows(.saveInvoice, into: $readOnlyRefusal) else { return }
        do {
            try InvoiceService.setMarkedPastDue(invoice, isPastDue: !invoice.isMarkedPastDue, in: modelContext)
        } catch {
            DomainError.present(error, readOnly: $readOnlyRefusal, domainError: $domainError)
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
        // `!isDeleted` guards (2026-09-01, the save crash): the edit form's save()
        // deletes + recreates every group/item, and the covered detail gets one
        // more render pass over the dead rows — reading a deleted @Model traps
        // uncatchably inside SwiftData. Skip dead models for that one pass.
        ForEach(invoice.sortedGroups) { group in
            if group.modelContext != nil, !group.isDeleted { groupCard(group) }
        }
    }

    @ViewBuilder
    private func groupCard(_ group: InvoiceGroup) -> some View {
            card {
                Text(group.name.isEmpty ? mbLoc("Line Items") : group.name)
                    .font(.headline)
                if !group.note.isEmpty {
                    Text(group.note).font(.subheadline).foregroundStyle(GLTheme.textSecondary)
                }
                let items = group.sortedLineItems
                ForEach(items) { item in
                    lineItemRow(item)
                    if item.id != items.last?.id {
                        Divider()
                    }
                }
                if !group.name.isEmpty || invoice.sortedGroups.count > 1 {
                    Divider()
                    HStack {
                        Text("Subtotal").foregroundStyle(GLTheme.textSecondary)
                        Spacer()
                        Text(groupSubtotal(group).formatted(.appMoney)).fontWeight(.medium)
                    }
                    .font(.subheadline)
                }
            }
    }

    @ViewBuilder
    private func lineItemRow(_ item: InvoiceLineItem) -> some View {
        if item.modelContext != nil, !item.isDeleted { lineItemRowBody(item) }
    }

    private func lineItemRowBody(_ item: InvoiceLineItem) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(item.name)
                Spacer()
                Text(displayLineTotal(item).formatted(.appMoney))
            }
            .font(.body.weight(.medium))
            if !item.details.isEmpty {
                Text(item.details).font(.footnote).foregroundStyle(GLTheme.textSecondary)
            }
            HStack(spacing: 6) {
                Text("\(item.quantity.formatted()) \(item.unit.abbreviation) × \(item.unitPrice.formatted(.appMoney))")
                Text("·")
                Text(item.kind.label)
                if !item.isTaxable { Text("· non-taxable") }
                if item.lineDiscount > 0 { Text("· −\(item.lineDiscount.formatted(.appMoney)) off") }
            }
            .font(.caption)
            .foregroundStyle(GLTheme.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Change-order lines keep their sign so a credit shows negative — matching `Invoice.totals`,
    /// which bills them via `signedLineTotal`, and the PDF's identical helper. Original work stays
    /// floored at 0 (an over-discounted line can't go negative). Without this, a credit would show
    /// $0.00 and the visible lines wouldn't reconcile with the totals card. Internal for tests.
    func displayLineTotal(_ item: InvoiceLineItem) -> Double {
        DomainMoney.roundedToCents(item.exactShownTotal)
    }

    /// Group subtotal using the same signed math as the rows above it (`InvoiceGroup.shownSubtotal`).
    /// Internal for tests.
    func groupSubtotal(_ group: InvoiceGroup) -> Double { group.shownSubtotal }

    private var totalsCard: some View {
        card {
            totalRow(mbLoc("Subtotal"), invoice.subtotal)
            if invoice.discountAmount > 0 { totalRow(mbLoc("Discount"), -invoice.discountAmount) }
            if invoice.taxAmount > 0 {
                // Plain "Tax" when a change order bills at the rate it was signed at (QA F82).
                totalRow(invoice.shownTaxRatePercent.map { mbLoc("Tax") + " (\($0.formatted())%)" } ?? mbLoc("Tax"),
                         invoice.taxAmount)
            }
            Divider()
            totalRow(mbLoc("Total"), invoice.total, bold: true)
            if invoice.amountPaid > 0 {
                totalRow(mbLoc("Paid"), -invoice.amountPaid)
            }
            // Paid more than the total (QA F85): what is owed back, so Paid − Credit due == Total.
            if invoice.creditDue > 0 {
                totalRow(mbLoc("Credit due"), invoice.creditDue)
            }
            HStack {
                Text("Balance").foregroundStyle(GLTheme.textSecondary)
                Spacer()
                Text(invoice.balanceDue.formatted(.appMoney))
                    .foregroundStyle(invoice.isPaid ? GLTheme.statusGood : GLTheme.textPrimary)
            }
            .font(.subheadline)
            if invoice.hasAmountDueRequest {
                Divider()
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Amount due now").fontWeight(.bold)
                        if !invoice.amountDueDetail.isEmpty {
                            Text(invoice.amountDueDetail)
                                .font(.caption)
                                .foregroundStyle(GLTheme.textSecondary)
                        }
                    }
                    Spacer()
                    Text(invoice.currentAmountDue.formatted(.appMoney))
                        .fontWeight(.bold)
                        .foregroundStyle(GLTheme.accentText)
                }
            }
        }
    }

    private var paymentsCard: some View {
        card {
            let payments = invoice.sortedPayments
            HStack {
                Text("Payments").font(.headline)
                Spacer()
                // The action lived only in the toolbar "…" before. A contractor who
                // just got handed a cheque looks at the payments list, not at an
                // overflow menu — so the button belongs where the question is asked.
                // The overflow item stays; two doors to the same sheet is correct here.
                if invoice.balanceDue > 0 {
                    HStack(spacing: 8) {
                        Button {
                            showingMarkPaidInFull = true
                        } label: {
                            Label("Mark paid in full", systemImage: "checkmark.circle")
                                .font(.glCaption.weight(.semibold))
                                .frame(minHeight: 44)   // law 16: the caption stays small, the tap is 44 pt
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.borderless)

                        Button {
                            showingRecordPayment = true
                        } label: {
                            Label("Record payment", systemImage: "dollarsign.circle")
                                .font(.glCaption.weight(.semibold))
                                .frame(minHeight: 44)   // law 16: the caption stays small, the tap is 44 pt
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.borderless)
                    }
                } else if invoice.isPaid && !payments.isEmpty {
                    Button {
                        receiptPayment = payments.first
                    } label: {
                        Label("View Payment Receipt", systemImage: "doc.text")
                            .font(.glCaption.weight(.semibold))
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                }
            }
            if payments.isEmpty {
                Text("No payments recorded yet.")
                    .font(.subheadline)
                    .foregroundStyle(GLTheme.textSecondary)
            } else {
                ForEach(payments) { payment in
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(payment.method.label)
                            HStack(spacing: 6) {
                                Text(payment.date.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted).locale(MBLocalization.currentLocale)))
                                if !payment.note.isEmpty {
                                    Text("· \(payment.note)").lineLimit(1)
                                }
                            }
                            .font(.caption)
                            .foregroundStyle(GLTheme.textSecondary)
                        }
                        Spacer()
                        Text(payment.amount.formatted(.appMoney))
                            .fontWeight(.medium)
                    }
                    .font(.subheadline)
                    if payment.id != payments.last?.id {
                        Divider()
                    }
                }
            }

            // The running payment history across the whole job (this invoice's sibling billing invoices),
            // so the full picture is visible here — not just on the job screen. Read-only; these payments
            // belong to their own invoices and are not re-counted on this one.
            if let job = invoice.job {
                let otherPayments = job.liveRows(job.billingInvoices)
                    .filter { $0.persistentModelID != invoice.persistentModelID }
                    .flatMap { $0.sortedPayments }
                    .sorted { $0.date < $1.date }
                if !otherPayments.isEmpty {
                    Divider().padding(.vertical, 4)
                    HStack {
                        Text("Earlier on this job").font(.subheadline.weight(.semibold))
                        Spacer()
                        Text(DomainMoney.roundedSum(otherPayments.map(\.amount)).formatted(.appMoney))
                            .font(.subheadline.weight(.semibold))
                    }
                    ForEach(otherPayments) { payment in
                        HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(payment.method.label)
                                Text(payment.date.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted).locale(MBLocalization.currentLocale)))
                                    .font(.caption)
                            }
                            Spacer()
                            Text(payment.amount.formatted(.appMoney))
                        }
                        .font(.subheadline)
                        .foregroundStyle(GLTheme.textSecondary)
                    }
                }
            }
        }
    }

    private var changeOrdersCard: some View {
        card {
            let orders = invoice.sortedChangeOrders
            HStack {
                Text("Change Orders").font(.headline)
                Spacer()
                Button {
                    showingNewChangeOrder = true
                } label: {
                    Label("Change order", systemImage: "plus.circle")
                        .font(.glCaption.weight(.semibold))
                        .frame(minHeight: 44)   // law 16: the caption stays small, the tap is 44 pt
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
            }
            if orders.isEmpty {
                Text("None yet. Tap above when the job’s scope changes.")
                    .font(.subheadline)
                    .foregroundStyle(GLTheme.textSecondary)
            } else {
                let hasUnapplied = orders.contains { $0.status == .approved && !$0.appliedToInvoice }
                if hasUnapplied {
                    Text("Approved change orders aren’t billed until you add them here.")
                        .font(.subheadline)
                        .foregroundStyle(GLTheme.textSecondary)
                }
                ForEach(orders) { changeOrder in
                    // The row is now a BUTTON. It listed the change orders and opened
                    // none of them — the only way in was the toolbar "…" ▸ Open change
                    // order ▸ pick one, so the signed document a customer is asking
                    // about was three levels down an overflow menu while its own title
                    // sat right here. The state and the destination both already existed.
                    Button {
                        selectedChangeOrder = changeOrder
                    } label: {
                        HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(changeOrder.title.isEmpty ? changeOrder.number : changeOrder.title)
                                    .fontWeight(.medium)
                                    .lineLimit(1)
                                HStack(spacing: 6) {
                                    Text(changeOrder.number)
                                    Text("· \(changeOrder.status.label)")
                                    if changeOrder.appliedToInvoice { Text("· added") }
                                }
                                .font(.caption)
                                .foregroundStyle(GLTheme.textSecondary)
                            }
                            Spacer()
                            Text((changeOrder.total >= 0 ? "+" : "") + changeOrder.total.formatted(.appMoney))
                                .fontWeight(.medium)
                            Image(systemName: "chevron.right")
                                .font(.glCaption.weight(.semibold))
                                .foregroundStyle(GLTheme.textTertiary)
                                .accessibilityHidden(true)
                        }
                        .frame(minHeight: 44)   // law 16: a full tap target
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .font(.subheadline)
                    if changeOrder.status == .approved && !changeOrder.appliedToInvoice {
                        Button {
                            addToInvoice(changeOrder)
                        } label: {
                            Label("Add to invoice", systemImage: "plus.circle")
                                .font(.subheadline)
                                .frame(minHeight: 44)   // law 16
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.borderless)
                        .tint(gold)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if changeOrder.id != orders.last?.id {
                        Divider()
                    }
                }
            }
        }
    }

    private var photosCard: some View {
        MBTitledCard(title: "Photos") {
            VStack(alignment: .leading, spacing: 12) {
                Text("Pictures of completed work and site conditions.")
                    .font(.caption).foregroundStyle(GLTheme.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if !invoice.photos.isEmpty {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 84), spacing: 8)], spacing: 8) {
                        ForEach(invoice.photos) { photo in
                            Button { previewPhoto = photo } label: {
                                ScanThumbnail(data: photo.data, size: 84)
                                    .frame(width: 84, height: 84)
                                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(.black.opacity(0.1)))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(Text("Photo"))   // the thumbnail itself is silent
                            .contextMenu {
                                Button(role: .destructive) { delete(photo) } label: {
                                    Label("Delete photo", systemImage: "trash")
                                }
                            }
                        }
                    }
                }
                HStack {
                    PhotosPicker(selection: $photoItems, maxSelectionCount: 0, matching: .images) {
                        Label(invoice.photos.isEmpty ? "Add photos" : "Add more photos", systemImage: "photo.badge.plus")
                            .font(.subheadline.weight(.semibold)).foregroundStyle(GLTheme.accentText)
                            .frame(minHeight: 44)   // law 16
                            .contentShape(Rectangle())
                    }
                    if let job = invoice.job, !job.photos.isEmpty {
                        Spacer()
                        Button {
                            importJobPhotos(job)
                        } label: {
                            Label("Import from job", systemImage: "arrow.down.doc")
                                .font(.subheadline.weight(.medium)).foregroundStyle(GLTheme.accentText)
                                .frame(minHeight: 44)
                                .contentShape(Rectangle())
                        }
                    }
                }
            }
        }
    }

    private var documentsCard: some View {
        MBTitledCard(title: "Documents") {
            VStack(alignment: .leading, spacing: 10) {
                if invoice.documents.isEmpty {
                    Text("Permits, receipts, and other files attached to this invoice.")
                        .font(.caption).foregroundStyle(GLTheme.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    ForEach(invoice.documents) { doc in
                        NavigationLink { JobDocumentDetailScreen(attachment: doc) } label: { documentRow(doc) }
                            .buttonStyle(.plain)
                    }
                }
                Divider()
                Button { showingDocImporter = true } label: {
                    Label("Add document", systemImage: "plus")
                        .frame(minHeight: 44)   // law 16
                        .contentShape(Rectangle())
                }
            }
        }
    }

    private func documentRow(_ doc: JobAttachment) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "doc.text").font(.title3).foregroundStyle(gold)
                .accessibilityHidden(true)
            Text(doc.name.isEmpty ? mbLoc("Document") : doc.name)
                .font(.subheadline).lineLimit(1).truncationMode(.middle)
            Spacer()
            Image(systemName: "chevron.right").font(.glCaption.weight(.semibold)).foregroundStyle(GLTheme.textTertiary)
                .accessibilityHidden(true)
        }
        .frame(minHeight: 44)   // law 16: a full tap target
        .contentShape(Rectangle())
    }

    private var notesCard: some View {
        card {
            if !invoice.customerNotes.isEmpty {
                Text("Notes").font(.headline)
                Text(invoice.customerNotes).foregroundStyle(GLTheme.textSecondary)
            }
            if !invoice.terms.isEmpty {
                Text("Terms").font(.headline).padding(.top, invoice.customerNotes.isEmpty ? 0 : 6)
                Text(invoice.terms).font(.footnote).foregroundStyle(GLTheme.textSecondary)
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

    /// Billing an approved change order writes line items onto the invoice and changes what the
    /// customer owes — the same write the change-order screen's own "Add to invoice" makes, so it
    /// carries the same gate, the same operation name and the same lock preview
    /// (ChangeOrderDetailSheet.addToInvoice): a credit that leaves the payments covering the
    /// invoice settles and locks it, so that asks first (QA F85).
    private func addToInvoice(_ changeOrder: ChangeOrder, confirmedLock: Bool = false) {
        guard ReadOnlyGate.allows(.changeChangeOrderStatus, into: $readOnlyRefusal) else { return }
        if !confirmedLock,
           PaidLockSaveGuard.fires(MoneyLockPreview.wouldLock(applying: changeOrder), amountPaid: invoice.amountPaid) {
            pendingLockingApply = changeOrder
            showingLockingApply = true
            return
        }
        do {
            try ChangeOrderService.applyToInvoice(changeOrder, in: modelContext)
        } catch {
            DomainError.present(error, readOnly: $readOnlyRefusal, domainError: $domainError)
        }
        regeneratePDF()
    }

    private func totalRow(_ label: String, _ amount: Double, bold: Bool = false) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(amount.formatted(.appMoney))
        }
        .fontWeight(bold ? .bold : .regular)
    }

    private var formattedAddress: String {
        let a = invoice.customerAddress
        let cityLine = [a.city, a.state].filter { !$0.isEmpty }.joined(separator: ", ")
        let cityZip = [cityLine, a.postalCode].filter { !$0.isEmpty }.joined(separator: " ")
        return [a.street1, a.street2 ?? "", cityZip]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }
}

// MARK: - Record payment

struct RecordPaymentSheet: View /* internal for render-coverage tests */ {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    let invoice: Invoice
    /// Non-empty only when opened from the Stripe paid-prompt — stamped onto the recorded payment so the
    /// poll knows this link is reconciled.
    private let prefillStripeLinkId: String

    @State private var amount: Double
    @State private var date = Date.now
    @State private var method: PaymentMethod
    @State private var note = ""
    /// Set when a lapsed subscription refuses a write — the alert names it (ReadOnlyGate.swift).
    @State private var readOnlyRefusal: MBWriteOperation?
    /// A refusal InvoiceService threw that the sheet did not predict (DomainErrorAlert.swift).
    @State private var domainError: DomainError?

    init(invoice: Invoice, prefillAmount: Double? = nil, prefillMethod: PaymentMethod = .check,
         prefillStripeLinkId: String = "") {
        self.invoice = invoice
        self.prefillStripeLinkId = prefillStripeLinkId
        // Prefill what the customer was actually asked to pay now (the milestone/deposit if set),
        // not the full remaining balance — so a quick Save on a deposit invoice doesn't record the
        // whole job as paid. The Stripe paid-prompt passes the exact amount it collected + method .stripe.
        _amount = State(initialValue: prefillAmount ?? invoice.currentAmountDue)
        _method = State(initialValue: prefillMethod)
    }

    /// Internal for tests. InvoiceService's rule, so the sheet and the save can't disagree.
    var exceedsBalance: Bool { InvoiceService.paymentExceedsBalance(invoice, amount: amount) }

    /// Manual entries hard-block an over-balance save (a typo shouldn't overpay an invoice). The
    /// Stripe paid-prompt path must NOT: a link always collects its full minted amount, so when a
    /// hand-recorded payment (or an applied credit) shrank the balance below the link amount first,
    /// the money was still really collected — blocking it would make the books permanently
    /// understate the Stripe payout. Internal for tests.
    /// Less than a cent as it will show is nothing to record (the save refuses it too — law 60).
    var saveBlocked: Bool {
        DomainMoney.roundedToCents(amount) <= 0 || (exceedsBalance && prefillStripeLinkId.isEmpty)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Amount") {
                        AutoClearNumberField(placeholder: "0", value: $amount, style: .currency, clearsAt: 0, wholeCents: true)
                            .multilineTextAlignment(.trailing)
                    }
                    DatePicker("Date", selection: $date, displayedComponents: .date)
                    Picker("Method", selection: $method) {
                        ForEach(PaymentMethod.allCases) { Text($0.label).tag($0) }
                    }
                    TextField("Note (optional)", text: $note)
                } header: {
                    Text("Payment")
                } footer: {
                    if exceedsBalance {
                        if prefillStripeLinkId.isEmpty {
                            Text("That’s more than the \(invoice.balanceDue.formatted(.appMoney)) balance due. Enter the balance due or less.")
                                .foregroundStyle(GLTheme.statusCritical)
                        } else {
                            Text("That’s more than the \(invoice.balanceDue.formatted(.appMoney)) balance due, but Stripe already collected it. Saving keeps the full amount on record so your books match the Stripe payout.")
                        }
                    }
                }
            }
            .glFormBackground()
            .readOnlyRefusalAlert($readOnlyRefusal)
            .domainErrorAlert($domainError)
            .navigationTitle(GLScript.padded(mbLoc("Record Payment")))
            .toolbarTitleDisplayMode(.large)
            .contentMargins(.top, GLScript.titleClearance(for: GLScript.padded(mbLoc("Record Payment"))), for: .scrollContent)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(role: .close) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    SaveOnceButton(disabled: saveBlocked, action: save)
                }
            }
        }
    }

    /// Returns whether the save committed — false re-arms `SaveOnceButton` so a refused tap can be
    /// retried after the person reactivates.
    @discardableResult
    func save() -> Bool {
        // "No recording a payment that arrives after the lapse" (owner ruling, 2026-08-25). This is
        // the surface that ruling names most directly, including the Stripe-prompt path that lands
        // here prefilled — a payment the customer really made, which the app still may not record.
        guard ReadOnlyGate.allows(.recordPayment, into: $readOnlyRefusal) else { return false }
        // InvoiceService records it with the over-balance rule above, stamps a matching card payment
        // with the outstanding Stripe link, draws down the amount-due request and saves — the same
        // path the assistant uses.
        do {
            try InvoiceService.recordPayment(on: invoice, amount: amount, date: date, method: method,
                                             note: note, stripeLinkId: prefillStripeLinkId, origin: .screen,
                                             in: modelContext)
        } catch {
            DomainError.present(error, readOnly: $readOnlyRefusal, domainError: $domainError)
            return false
        }
        dismiss()
        return true
    }
}

// MARK: - Set amount due (milestone request)

struct SetAmountDueSheet: View /* internal for render-coverage tests */ {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    let invoice: Invoice

    @State private var amount: Double
    @State private var detail: String
    /// Set when a lapsed subscription refuses a write — the alert names it (ReadOnlyGate.swift).
    @State private var readOnlyRefusal: MBWriteOperation?
    /// A refusal InvoiceService threw that the sheet did not predict (DomainErrorAlert.swift).
    @State private var domainError: DomainError?

    init(invoice: Invoice) {
        self.invoice = invoice
        _amount = State(initialValue: invoice.amountDueNow)
        _detail = State(initialValue: invoice.amountDueDetail)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Amount due now") {
                        AutoClearNumberField(placeholder: "0", value: $amount, style: .currency, clearsAt: 0, wholeCents: true)
                            .multilineTextAlignment(.trailing)
                    }
                    TextField("What it’s for (e.g. 30% progress payment)", text: $detail)
                } footer: {
                    Text("What you’re asking the customer to pay now. Leave at $0 to request the full balance of \(invoice.balanceDue.formatted(.appMoney)).")
                }
            }
            .glFormBackground()
            .readOnlyRefusalAlert($readOnlyRefusal)
            .domainErrorAlert($domainError)
            .navigationTitle(GLScript.padded(mbLoc("Amount Due")))
            .toolbarTitleDisplayMode(.large)
            .contentMargins(.top, GLScript.titleClearance(for: GLScript.padded(mbLoc("Amount Due"))), for: .scrollContent)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(role: .close) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                }
            }
        }
    }

    func save() {
        guard ReadOnlyGate.allows(.setAmountDue, into: $readOnlyRefusal) else { return }
        do {
            try InvoiceService.setAmountDue(invoice, amount: amount, detail: detail, in: modelContext)
        } catch {
            DomainError.present(error, readOnly: $readOnlyRefusal, domainError: $domainError)
            return
        }
        dismiss()
    }
}

// MARK: - Payment receipt

/// Previews the payment receipt (the W-9-style flow: see it, then send) and sends it to the
/// customer by email/text or shares the PDF. Receipt wording shows the remaining balance as
/// information, never as an amount due.
struct PaymentReceiptSheet: View /* internal for render-coverage tests */ {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @Query private var businessProfiles: [BusinessProfile]
    let invoice: Invoice
    let payment: InvoicePayment

    @State private var pdfURL: URL?
    @State private var pdfData: Data?
    @State private var generationFailed = false
    @State private var sendAction: SendAction?
    @State private var sendFailureMessage: String?
    /// Set when a lapsed subscription refuses a write — the alert names it (ReadOnlyGate.swift).
    @State private var readOnlyRefusal: MBWriteOperation?
    @State private var showingProfilePrompt = false

    enum SendAction: Int, Identifiable { case email, text; var id: Int { rawValue } }
    private var gold: Color { GLTheme.accentFill }
    private var business: BusinessProfile? { businessProfiles.first }

    /// A business name plus at least one way to be reached — the bar for putting this document in
    /// front of a customer. `BusinessProfile.isComplete` owns the rule; this is just the read.
    private var profileIsComplete: Bool { business?.isComplete == true }

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                if let pdfData {
                    CertificatePreview(data: pdfData)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(.black.opacity(0.12)))
                } else if generationFailed {
                    Spacer()
                    DocumentGenerationError { regenerate() }
                    Spacer()
                } else {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
            }
            .padding(.horizontal, GLLayout.rowCardInset)
            .padding(.vertical)
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
            .background { GLTheme.background.ignoresSafeArea() }
            .navigationTitle(GLScript.padded(mbLoc("Payment Receipt")))
            .toolbarTitleDisplayMode(.large)
            .contentMargins(.top, GLScript.titleClearance(for: GLScript.padded(mbLoc("Payment Receipt"))), for: .scrollContent)
            .mbSystemBanners()
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button(role: .close) { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        // The SEND rows are gated on the PROFILE, not on the PDF. A blank letterhead
                        // renders perfectly well, so a receipt existing proves nothing about whether it
                        // is fit to put in front of a customer — and this menu sits two rows below the
                        // invoice's own gate, so leaving it open handed a brand-new owner the exact
                        // unbranded send that gate exists to stop. Share stays open either way (the
                        // deliberate don't-dead-end call): it hands the file to another app on this
                        // device, it doesn't put it on the wire. Matches EstimateDetailScreen exactly.
                        if profileIsComplete {
                            if !invoice.recipientEmail.isEmpty && ComposeCapability.canSend(.mail) {
                                Button {
                                    if ReadOnlyGate.allows(.generatePaymentReceipt, into: $readOnlyRefusal) { sendAction = .email }
                                } label: { Label("Email receipt", systemImage: "envelope") }
                            }
                            if !invoice.recipientPhone.isEmpty && ComposeCapability.canSend(.text) {
                                Button {
                                    if ReadOnlyGate.allows(.generatePaymentReceipt, into: $readOnlyRefusal) { sendAction = .text }
                                } label: { Label("Text receipt", systemImage: "message") }
                            }
                        } else {
                            // One tappable row instead of Email/Text — never a dead control, and it
                            // names the fix (the alert it opens says exactly which fields).
                            Button { showingProfilePrompt = true } label: {
                                Label("Set up business profile to send", systemImage: "exclamationmark.circle")
                            }
                        }
                        if let pdfURL {
                            MBShareLink(item: pdfURL,
                                        subject: Text(PaymentReceiptMessage.subject(invoice: invoice, business: business)),
                                        message: Text(PaymentReceiptMessage.plainBody(invoice: invoice, payment: payment, business: business)),
                                        operation: .generatePaymentReceipt,
                                        refused: $readOnlyRefusal) {
                                Label("Share receipt…", systemImage: "square.and.arrow.up")
                            }
                        }
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .tint(gold)
                }
            }
            .onAppear { regenerate() }
            .readOnlyRefusalAlert($readOnlyRefusal)
            .sheet(item: $sendAction) { action in sendSheet(action).glAppearance(colorScheme) }
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
        }
    }

    private func regenerate() {
        guard let url = PaymentReceiptPDF.render(invoice, payment: payment, business: business),
              let data = try? Data(contentsOf: url) else {
            generationFailed = true
            return
        }
        pdfURL = url
        pdfData = data
        generationFailed = false
    }

    func noteSend(_ outcome: SendOutcome) {
        if outcome == .failed {
            // Same verbatim-Text trap as the invoice's own send failure above.
            sendFailureMessage = mbLoc("We couldn’t send your receipt. Check your internet connection and try again.")
        }
    }

    @ViewBuilder
    func sendSheet(_ action: SendAction) -> some View {
        // SendPreparer fills it — the same content the assistant's send hands over.
        let content = SendPreparer.paymentReceipt(invoice, payment: payment, business: business, pdfURL: pdfURL)
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

#Preview {
    let invoice = Invoice(jobTitle: "Master bath tile install", customer: Customer(firstName: "Jane", lastName: "Doe"))
    invoice.number = "INV-0001"
    return NavigationStack {
        InvoiceDetailScreen(invoice: invoice)
    }
    .modelContainer(for: [Customer.self, Invoice.self], inMemory: true)
}
