//
//  ContractDetailScreen.swift
//  GLSmallBusiness
//
//  Created by Gold Life LLC on 10/7/26.
//
//  The Core Hub for Contract Management: contract signing, change orders,
//  invoicing, and schedule dates (with Calendar accessible from toolbar).
//

import SwiftUI
import SwiftData
import PhotosUI
import UniformTypeIdentifiers
import GoldLifeUI
import GoldLifeAI

struct ContractDetailScreen: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(\.colorScheme) private var colorScheme
    @Environment(SubscriptionManager.self) private var subscription
    @Query private var storedContract: [Contract]
    @Query private var businessProfiles: [BusinessProfile]

    let contract: Contract
    var showsAssistantButton = true

    @State private var showingEdit = false
    @State private var showingSignSheet = false
    @State private var showingInvoiceSheet = false
    @State private var showingNewChangeOrder = false
    @State private var showingCalendar = false
    @State private var showingDeleteConfirmation = false
    @State private var selectedInvoice: Invoice?
    @State private var selectedChangeOrder: ChangeOrder?
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var showingDocImporter = false
    @State private var showingAddToProject = false
    @State private var previewAttachment: JobAttachment?
    @State private var sendAction: SendAction?
    @State private var composeContent: ComposeContent?
    @State private var composeUnavailable: ComposeCapability.Channel?
    @State private var pdfFailed = false
    @State private var pdfURL: URL?
    @State private var showingPreview = false
    @State private var sendFailureMessage: String?
    @State private var showingProfilePrompt = false
    @State private var readOnlyRefusal: MBWriteOperation?
    @State private var domainError: DomainError?

    private var profileIsComplete: Bool { businessProfiles.first?.isComplete == true }

    private var effectiveCustomerPhone: String {
        if !contract.recipientPhone.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return contract.recipientPhone
        }
        return contract.customer?.phoneNumber ?? ""
    }

    private var effectiveServiceAddress: Address {
        if !contract.serviceAddress.isEmpty {
            return contract.serviceAddress
        }
        if let est = contract.estimate, !est.serviceAddress.isEmpty {
            return est.serviceAddress
        }
        if let jobEst = contract.scheduledJob?.estimate, !jobEst.serviceAddress.isEmpty {
            return jobEst.serviceAddress
        }
        if let jobInv = contract.scheduledJob?.invoice, !jobInv.serviceAddress.isEmpty {
            return jobInv.serviceAddress
        }
        if let job = contract.scheduledJob, !job.serviceAddress.isEmpty {
            return job.serviceAddress
        }
        return contract.customer?.serviceAddress ?? Address()
    }

    enum SendAction: Int, Identifiable { case email, text; var id: Int { rawValue } }

    init(contract: Contract, showsAssistantButton: Bool = true) {
        self.contract = contract
        self.showsAssistantButton = showsAssistantButton
        let id = contract.persistentModelID
        _storedContract = Query(filter: #Predicate<Contract> { $0.persistentModelID == id })
    }

    private var assistantRecord: GLAIOnScreen? {
        GLAIOnScreen(.contract, contract, label: contract.number.isEmpty ? mbLoc("Contract") : contract.number, in: modelContext)
    }

    private var stillExists: Bool {
        !contract.isDeleted && !storedContract.isEmpty
    }

    var body: some View {
        if stillExists {
            aliveBody
        } else {
            DeletedRecordView(title: mbLoc("Contract"), noun: "this contract") { dismiss() }
        }
    }

    @ViewBuilder
    private var aliveBody: some View {
        ScrollView {
            VStack(spacing: 16) {
                headerCard
                quickActionBar
                contactAndAddressCard
                signingCard
                invoicingCard
                changeOrdersCard
                scheduleCard
                if !contract.notes.isEmpty || !contract.terms.isEmpty {
                    notesAndTermsCard
                }
                attachmentsCard
            }
            .padding(.horizontal, GLLayout.rowCardInset)
            .padding(.vertical)
            .glReadableWidth()
        }
        .safeAreaInset(edge: .bottom) {
            previewButton
        }
        .mbSystemBanners()
        .glFormBackground()
        .readOnlyRefusalAlert($readOnlyRefusal)
        .domainErrorAlert($domainError)
        .navigationTitle(GLScript.padded(contract.number.isEmpty ? mbLoc("Contract") : contract.number))
        .toolbarTitleDisplayMode(.large)
        .contentMargins(.top, GLScript.titleClearance(for: GLScript.padded(contract.number.isEmpty ? mbLoc("Contract") : contract.number)), for: .scrollContent)
        .toolbar {
            if showsAssistantButton, contract.canBeNamedToAssistant {
                ToolbarItem(placement: .topBarTrailing) {
                    MBAssistantButton { assistantRecord }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showingCalendar = true
                } label: {
                    Label(mbLoc("Calendar"), systemImage: "calendar")
                }
                .accessibilityLabel("Calendar")
            }

            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Section {
                        Button {
                            showingEdit = true
                        } label: {
                            Label(mbLoc("Edit"), systemImage: "pencil")
                        }

                        Button {
                            showingInvoiceSheet = true
                        } label: {
                            Label(mbLoc("Invoice from Contract"), systemImage: "banknote")
                        }

                        if !contract.hasPhysicalSignature {
                            Button {
                                showingSignSheet = true
                            } label: {
                                Label(mbLoc("Sign Contract"), systemImage: "signature")
                            }
                        }

                        if let job = contract.scheduledJob {
                            Button {
                                showingAddToProject = true
                            } label: {
                                if job.project == nil {
                                    Label(mbLoc("Add to project"), systemImage: "folder.badge.plus")
                                } else {
                                    Label(mbLoc("Change project"), systemImage: "folder.badge.plus")
                                }
                            }
                        }
                    }

                    Section(mbLoc("Status")) {
                        ForEach(ContractStatus.allCases) { st in
                            Button {
                                setStatus(st)
                            } label: {
                                HStack {
                                    Text(st.label)
                                    if contract.status == st {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        }
                    }

                    Section {
                        Button(role: .destructive) {
                            showingDeleteConfirmation = true
                        } label: {
                            Label(mbLoc("Delete Contract"), systemImage: "trash")
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
        .onChange(of: showingSignSheet) { _, isShowing in
            if !isShowing { regeneratePDF() }
        }
        .sheet(item: $sendAction, onDismiss: { composeContent = nil }) { action in
            sendSheet(for: action).glAppearance(colorScheme)
        }
        .composeUnavailableAlert($composeUnavailable)
        .pdfFailureAlert($pdfFailed)
        .sheet(isPresented: $showingPreview) {
            if let pdfURL {
                DocumentPreviewSheet(
                    url: pdfURL,
                    title: contract.number.isEmpty ? "Contract" : "Contract \(contract.number)",
                    subject: ContractMessage.subject(contract: contract, business: businessProfiles.first),
                    message: ContractMessage.plainBody(contract: contract, business: businessProfiles.first)
                )
                .glAppearance(colorScheme)
            }
        }
        .alert(mbLoc("Complete your business profile"), isPresented: $showingProfilePrompt) {
            Button(mbLoc("OK"), role: .cancel) { }
        } message: {
            Text(mbLoc("Add your business name and a phone or email in Menu → My Business Details so they appear on your contract."))
        }
        .alert(mbLoc("Couldn’t send"), isPresented: Binding(get: { sendFailureMessage != nil },
                                                     set: { if !$0 { sendFailureMessage = nil } })) {
            Button(mbLoc("OK"), role: .cancel) { sendFailureMessage = nil }
        } message: {
            Text(sendFailureMessage ?? "")
        }
        .sheet(isPresented: $showingSignSheet) {
            ContractSignSheet(contract: contract)
                .glAppearance(colorScheme)
        }
        .sheet(isPresented: $showingInvoiceSheet) {
            InvoiceFromContractSheet(contract: contract) { newInvoice in
                selectedInvoice = newInvoice
            }
            .glAppearance(colorScheme)
        }
        .sheet(isPresented: $showingAddToProject) {
            if let job = contract.scheduledJob {
                AddToProjectSheet(job: job).glAppearance(colorScheme)
            }
        }
        .navigationDestination(isPresented: $showingEdit) {
            ContractFormScreen(editing: contract)
        }
        .navigationDestination(isPresented: $showingCalendar) {
            CalendarScreen(showsMenuButton: false, ownsStack: false, primaryBackground: true)
        }
        .navigationDestination(item: $selectedInvoice) { inv in
            InvoiceDetailScreen(invoice: inv)
        }
        .navigationDestination(item: $selectedChangeOrder) { co in
            ChangeOrderDetailSheet(changeOrder: co)
        }
        .navigationDestination(isPresented: $showingNewChangeOrder) {
            newChangeOrderView
        }
        .deleteConfirmation($showingDeleteConfirmation, title: "Delete this contract?") {
            deleteContract()
        }
    }

    // MARK: - Cards

    private var headerCard: some View {
        card {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(contract.displayTitle)
                            .font(.title2.weight(.bold))
                            .foregroundStyle(GLTheme.textPrimary)
                        Text(contract.displayCustomerName)
                            .font(.subheadline)
                            .foregroundStyle(GLTheme.textSecondary)
                    }
                    Spacer()
                    ContractStatusBadge(status: contract.status)
                }

                Divider()

                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(mbLoc("Contract Value"))
                            .font(.caption)
                            .foregroundStyle(GLTheme.textSecondary)
                        Text(contract.contractedValue.formatted(.appMoney))
                            .font(.headline.weight(.bold))
                            .foregroundStyle(GLTheme.textPrimary)
                        if !contract.approvedChangeOrders.isEmpty {
                            Text(String(format: mbLoc("%d change order(s) included"), contract.approvedChangeOrders.count))
                                .font(.caption2)
                                .foregroundStyle(GLTheme.accentText)
                        }
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(mbLoc("Invoiced"))
                            .font(.caption)
                            .foregroundStyle(GLTheme.textSecondary)
                        Text(contract.invoicedTotal.formatted(.appMoney))
                            .font(.headline.weight(.semibold))
                            .foregroundStyle(GLTheme.accentText)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(mbLoc("Remaining"))
                            .font(.caption)
                            .foregroundStyle(GLTheme.textSecondary)
                        Text(contract.remainingToInvoice.formatted(.appMoney))
                            .font(.headline.weight(.bold))
                            .foregroundStyle(GLTheme.statusGood)
                    }
                }

                // Progress Bar
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(GLTheme.surfaceRaised)
                            .frame(height: 8)
                        let progress = contract.contractedValue > 0
                            ? min(1.0, max(0.0, contract.invoicedTotal / contract.contractedValue))
                            : 0.0
                        Capsule()
                            .fill(progress >= 1.0 ? GLTheme.statusGood : GLTheme.accentFill)
                            .frame(width: geo.size.width * progress, height: 8)
                    }
                }
                .frame(height: 8)
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
                .disabled(contract.recipientEmail.isEmpty || !ComposeCapability.canSend(.mail))

                GLDocumentActionButton("Text", systemImage: "message") {
                    guard ReadOnlyGate.allows(.sendDocument, into: $readOnlyRefusal),
                          ComposeCapability.check(.text, into: $composeUnavailable) else { return }
                    openComposer(.text)
                }
                .disabled(effectiveCustomerPhone.isEmpty || !ComposeCapability.canSend(.text))

                if let pdfURL {
                    MBShareLink(
                        item: pdfURL,
                        subject: Text(ContractMessage.subject(contract: contract, business: businessProfiles.first)),
                        message: Text(ContractMessage.plainBody(contract: contract, business: businessProfiles.first)),
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

                GLDocumentActionButton("Invoice", systemImage: "banknote") {
                    showingInvoiceSheet = true
                }
            }
        } else {
            Button { showingProfilePrompt = true } label: {
                HStack {
                    Image(systemName: "exclamationmark.circle")
                    Text(mbLoc("Set up business profile to send"))
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

    private var contactAndAddressCard: some View {
        card {
            VStack(alignment: .leading, spacing: 12) {
                Text(mbLoc("Contact & Site Details"))
                    .font(.headline)

                HStack(spacing: 8) {
                    Image(systemName: "phone.fill")
                        .foregroundStyle(GLTheme.accentFill)
                        .frame(width: 20)
                    let phone = effectiveCustomerPhone
                    if phone.isEmpty {
                        Text("—").foregroundStyle(GLTheme.textSecondary)
                    } else {
                        GLContactLink(.phone, phone)
                    }
                }

                if !contract.recipientEmail.isEmpty {
                    HStack(spacing: 8) {
                        Image(systemName: "envelope.fill")
                            .foregroundStyle(GLTheme.accentFill)
                            .frame(width: 20)
                        GLContactLink(.email, contract.recipientEmail)
                    }
                }

                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "mappin.and.ellipse")
                        .foregroundStyle(GLTheme.accentFill)
                        .frame(width: 20)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(mbLoc("Service Address"))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(GLTheme.textSecondary)
                        let addr = effectiveServiceAddress
                        if addr.isEmpty {
                            Text("—").foregroundStyle(GLTheme.textSecondary)
                        } else {
                            GLContactLink(.address, addr.singleLine, display: addr.formattedMultiline)
                        }
                    }
                }
            }
        }
    }

    private var signingCard: some View {
        card {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(mbLoc("Contract Signing"))
                        .font(.headline)
                    Spacer()
                    if contract.hasPhysicalSignature {
                        Label(mbLoc("Signed"), systemImage: "checkmark.seal.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(GLTheme.statusGood)
                    } else if contract.isSigned {
                        Label(mbLoc("Marked Signed (No Signature)"), systemImage: "checkmark.circle")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(GLTheme.statusAttention)
                    } else {
                        Label(mbLoc("Pending Signature"), systemImage: "clock")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(GLTheme.statusAttention)
                    }
                }

                if contract.hasPhysicalSignature {
                    VStack(alignment: .leading, spacing: 6) {
                        if !contract.signerName.isEmpty {
                            Text("\(mbLoc("Authorized Signer:")) \(contract.signerName)")
                                .font(.subheadline.weight(.medium))
                        }
                        if let signedAt = contract.signedAt {
                            Text("\(mbLoc("Date Signed:")) \(signedAt.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption)
                                .foregroundStyle(GLTheme.textSecondary)
                        }
                        if let sigData = contract.signatureData, let uiImage = UIImage(data: sigData) {
                            Image(uiImage: uiImage)
                                .resizable()
                                .scaledToFit()
                                .frame(height: 70)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(GLLayout.rowCardInset)
                                .background(Color.white)
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(GLTheme.textSecondary.opacity(0.3)))
                        }
                        Button {
                            showingSignSheet = true
                        } label: {
                            Text(mbLoc("Re-sign Contract"))
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(GLTheme.accentText)
                                .frame(minHeight: 44)
                                .contentShape(Rectangle())
                        }
                        .padding(.top, 4)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        if contract.isSigned {
                            Text(mbLoc("Contract status was marked signed, but physical client signature has not been captured yet."))
                                .font(.subheadline)
                                .foregroundStyle(GLTheme.textSecondary)
                        } else {
                            Text(mbLoc("Capture client signature to authorize this contract."))
                                .font(.subheadline)
                                .foregroundStyle(GLTheme.textSecondary)
                        }

                        HStack(spacing: 12) {
                            Button {
                                showingSignSheet = true
                            } label: {
                                HStack {
                                    Spacer()
                                    Image(systemName: "signature")
                                    Text(mbLoc("Sign on Device"))
                                        .fontWeight(.semibold)
                                    Spacer()
                                }
                                .padding(.vertical, 10)
                                .background(GLTheme.accentFill)
                                .foregroundStyle(.white)
                                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            }
                            .buttonStyle(.plain)

                            if !contract.recipientEmail.isEmpty || !effectiveCustomerPhone.isEmpty {
                                Button {
                                    if !contract.recipientEmail.isEmpty && ComposeCapability.canSend(.mail) {
                                        openComposer(.email)
                                    } else if !effectiveCustomerPhone.isEmpty && ComposeCapability.canSend(.text) {
                                        openComposer(.text)
                                    } else {
                                        if pdfURL == nil { regeneratePDF() }
                                        showingPreview = true
                                    }
                                } label: {
                                    HStack {
                                        Spacer()
                                        Image(systemName: "paperplane")
                                        Text(mbLoc("Send to Client"))
                                            .fontWeight(.semibold)
                                        Spacer()
                                    }
                                    .padding(.vertical, 10)
                                    .background(GLTheme.surfaceRaised)
                                    .foregroundStyle(GLTheme.textPrimary)
                                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
        }
    }

    private var invoicingCard: some View {
        card {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(mbLoc("Invoicing & Draws"))
                        .font(.headline)
                    Spacer()
                    Button {
                        showingInvoiceSheet = true
                    } label: {
                        Label(mbLoc("Invoice"), systemImage: "plus")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(GLTheme.accentText)
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                    }
                }

                if contract.activeBillingInvoices.isEmpty {
                    Text(mbLoc("No invoices generated from this contract yet. Tap Invoice to create a deposit, progress draw, or final bill."))
                        .font(.subheadline)
                        .foregroundStyle(GLTheme.textSecondary)
                } else {
                    ForEach(contract.activeBillingInvoices) { inv in
                        Button {
                            selectedInvoice = inv
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(inv.number)
                                        .font(.subheadline.weight(.medium))
                                        .foregroundStyle(GLTheme.textPrimary)
                                    Text(inv.dueDate.formatted(date: .abbreviated, time: .omitted))
                                        .font(.caption2)
                                        .foregroundStyle(GLTheme.textSecondary)
                                }
                                Spacer()
                                VStack(alignment: .trailing, spacing: 2) {
                                    Text(inv.total.formatted(.appMoney))
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(GLTheme.textPrimary)
                                    Text(inv.displayStatus)
                                        .font(.caption2.weight(.medium))
                                        .foregroundStyle(inv.isPaid ? GLTheme.statusGood : GLTheme.statusAttention)
                                }
                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundStyle(GLTheme.textTertiary)
                                    .accessibilityHidden(true)
                            }
                            .padding(.vertical, 4)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var changeOrdersCard: some View {
        card {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(mbLoc("Change Orders"))
                        .font(.headline)
                    Spacer()
                    Button {
                        showingNewChangeOrder = true
                    } label: {
                        Label(mbLoc("New"), systemImage: "plus")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(GLTheme.accentText)
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                    }
                }

                if contract.sortedChangeOrders.isEmpty {
                    Text(mbLoc("No change orders. Add change orders when project scope, materials, or pricing change."))
                        .font(.subheadline)
                        .foregroundStyle(GLTheme.textSecondary)
                } else {
                    ForEach(contract.sortedChangeOrders) { co in
                        VStack(spacing: 8) {
                            HStack {
                                Button {
                                    selectedChangeOrder = co
                                } label: {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(co.title.isEmpty ? co.number : "\(co.number) · \(co.title)")
                                            .font(.subheadline.weight(.medium))
                                            .foregroundStyle(GLTheme.textPrimary)
                                        Text(co.status.label)
                                            .font(.caption2.weight(.medium))
                                            .foregroundStyle(co.status == .approved ? GLTheme.statusGood : GLTheme.statusAttention)
                                    }
                                }
                                .buttonStyle(.plain)

                                Spacer()

                                if co.status == .pending {
                                    Button {
                                        guard ReadOnlyGate.allows(.saveJob, into: $readOnlyRefusal) else { return }
                                        co.status = .approved
                                        modelContext.saveChanges()
                                        regeneratePDF()
                                    } label: {
                                        Text(mbLoc("Approve"))
                                            .font(.caption.weight(.bold))
                                            .padding(.horizontal, GLTheme.gutter)
                                            .padding(.vertical, 5)
                                            .background(GLTheme.statusGood)
                                            .foregroundStyle(.white)
                                            .clipShape(Capsule())
                                    }
                                    .buttonStyle(.plain)
                                }

                                Button {
                                    selectedChangeOrder = co
                                } label: {
                                    HStack(spacing: 4) {
                                        Text((co.total >= 0 ? "+" : "") + co.total.formatted(.appMoney))
                                            .font(.subheadline.weight(.semibold))
                                            .foregroundStyle(co.total >= 0 ? GLTheme.textPrimary : GLTheme.statusCritical)
                                        Image(systemName: "chevron.right")
                                            .font(.caption)
                                            .foregroundStyle(GLTheme.textTertiary)
                                            .accessibilityHidden(true)
                                    }
                                }
                                .buttonStyle(.plain)
                            }

                            if co.id != contract.sortedChangeOrders.last?.id {
                                Divider()
                            }
                        }
                        .padding(.vertical, 2)
                    }

                    if contract.sortedChangeOrders.contains(where: { $0.status == .pending }) {
                        Text(mbLoc("Pending change orders are not added to the contract total until approved."))
                            .font(.caption2)
                            .foregroundStyle(GLTheme.textSecondary)
                            .padding(.top, 4)
                    }
                }
            }
        }
    }

    private var scheduleCard: some View {
        card {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(mbLoc("Schedule & Dates"))
                        .font(.headline)
                    Spacer()
                    Button {
                        showingCalendar = true
                    } label: {
                        Label(mbLoc("View in Calendar"), systemImage: "calendar")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(GLTheme.accentText)
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                    }
                }

                HStack {
                    Image(systemName: "calendar")
                        .foregroundStyle(GLTheme.accentFill)
                    Text(dateRangeText)
                        .font(.subheadline)
                    Spacer()
                }

                if !contract.isAllDay, let time = contract.startTime {
                    HStack {
                        Image(systemName: "clock")
                            .foregroundStyle(GLTheme.accentFill)
                        Text(time.formatted(date: .omitted, time: .shortened))
                            .font(.subheadline)
                        if let dur = contract.durationMinutes {
                            Text("(\(dur / 60)h \(dur % 60)m)")
                                .font(.caption)
                                .foregroundStyle(GLTheme.textSecondary)
                        }
                    }
                }
            }
        }
    }

    private var notesAndTermsCard: some View {
        card {
            VStack(alignment: .leading, spacing: 10) {
                Text(mbLoc("Terms & Notes"))
                    .font(.headline)
                if !contract.notes.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(mbLoc("Notes"))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(GLTheme.textSecondary)
                        Text(contract.notes)
                            .font(.subheadline)
                    }
                }
                if !contract.terms.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(mbLoc("Terms"))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(GLTheme.textSecondary)
                        Text(contract.terms)
                            .font(.subheadline)
                    }
                }
            }
        }
    }

    private var attachmentsCard: some View {
        card {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(mbLoc("Photos & Documents"))
                        .font(.headline)
                    Spacer()
                    PhotosPicker(selection: $photoItems, matching: .images) {
                        Image(systemName: "camera")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(GLTheme.accentText)
                            .frame(minWidth: 44, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                }

                let attachments = contract.sortedAttachments
                if attachments.isEmpty {
                    Text(mbLoc("No photos or documents attached yet."))
                        .font(.subheadline)
                        .foregroundStyle(GLTheme.textSecondary)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 80, maximum: 120))], spacing: 8) {
                        ForEach(attachments) { att in
                            if att.kind == .photo, let data = att.data, let img = UIImage(data: data) {
                                Image(uiImage: img)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: 80, height: 80)
                                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            } else {
                                VStack {
                                    Image(systemName: "doc.fill")
                                        .font(.title2)
                                        .foregroundStyle(GLTheme.accentFill)
                                    Text(att.name)
                                        .font(.caption2)
                                        .lineLimit(1)
                                }
                                .frame(width: 80, height: 80)
                                .background(GLTheme.surfaceRaised)
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            }
                        }
                    }
                }
            }
        }
        .task(id: photoItems) {
            guard !photoItems.isEmpty else { return }
            guard ReadOnlyGate.allows(.addJobAttachment, into: $readOnlyRefusal) else {
                photoItems = []
                return
            }
            for item in photoItems {
                if let data = try? await item.loadTransferable(type: Data.self) {
                    let att = JobAttachment()
                    att.data = data
                    att.name = "Photo \(Date.now.formatted(date: .abbreviated, time: .shortened))"
                    att.kind = .photo
                    att.contract = contract
                    modelContext.insert(att)
                }
            }
            photoItems = []
            modelContext.saveChanges()
        }
    }

    private var dateRangeText: String {
        let style = Date.FormatStyle(date: .abbreviated, time: .omitted).locale(MBLocalization.currentLocale)
        let end = Calendar.current.date(byAdding: .day, value: max(0, contract.durationDays - 1), to: contract.startDate) ?? contract.startDate
        return Calendar.current.isDate(contract.startDate, inSameDayAs: end)
            ? contract.startDate.formatted(style)
            : "\(contract.startDate.formatted(style)) – \(end.formatted(style))"
    }

    // MARK: - Actions

    private func setStatus(_ newStatus: ContractStatus) {
        guard ReadOnlyGate.allows(.saveJob, into: $readOnlyRefusal) else { return }
        contract.status = newStatus
        if newStatus == .completed {
            contract.completedAt = .now
        }
        if let job = contract.scheduledJob {
            switch newStatus {
            case .draft, .signed: job.status = .scheduled
            case .inProgress: job.status = .inProgress
            case .completed: job.status = .completed
            }
        }
        modelContext.saveChanges()
    }

    private func deleteContract() {
        guard ReadOnlyGate.allows(.deleteJob, into: $readOnlyRefusal) else { return }
        if let job = contract.scheduledJob {
            modelContext.deleteSynced(job)
        }
        modelContext.delete(contract) // GLSYNC-LINT-OK: local model until manifest v2
        modelContext.saveChanges()
        dismiss()
    }

    private func openComposer(_ action: SendAction) {
        guard regeneratePDF() else {
            pdfFailed = true
            return
        }
        composeContent = SendPreparer.contract(contract, business: businessProfiles.first, pdfURL: pdfURL)
        sendAction = action
    }

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
            MessageComposeView(
                recipients: content.textRecipients,
                body: content.plainBody,
                attachmentURLs: content.messageAttachmentURLs
            ) { outcome in sendAction = nil; noteSend(outcome) }
        }
    }

    func noteSend(_ outcome: SendOutcome) {
        if outcome == .failed {
            sendFailureMessage = mbLoc("We couldn’t send your contract. Check your internet connection and try again.")
        }
    }

    @discardableResult
    private func regeneratePDF() -> Bool {
        pdfURL = ContractPDF.render(contract, business: businessProfiles.first)
        return pdfURL != nil
    }

    @ViewBuilder
    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10, content: content)
            .padding(GLLayout.rowContentPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glCardBackground()
    }

    @ViewBuilder
    private var newChangeOrderView: some View {
        ChangeOrderFormScreen(contract: contract)
    }
}
