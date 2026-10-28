//
//  JobDetailScreen.swift
//  GLSmallBusiness
//
//  Detail for a first-class Job: schedule, customer, optional price, the source doc it links back to,
//  and notes. The toolbar edits the job, changes its status (marking complete stamps the completion
//  date), or deletes it. Mirrors InvoiceDetailScreen's layout conventions.
//

import SwiftUI
import GoldLifeUI
import GoldLifeAI
import SwiftData
import PhotosUI
import UIKit
import UniformTypeIdentifiers

struct JobDetailScreen: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(SubscriptionManager.self) private var subscription
    @AppStorage(SchedulingPrefs.workdaysMaskKey) private var workdaysMask = SchedulingPrefs.defaultWorkdaysMask
    /// This job as the store lists it: one row, or none once it is deleted. A fetch of the one
    /// record (QA F153), still a live @Query so a saved delete redraws the screen.
    @Query private var storedJob: [ScheduledJob]
    @Query private var profiles: [BusinessProfile]
    let job: ScheduledJob

    /// The sparkles button (law 58, dual entry points). Off for a record the assistant itself
    /// pushed, so the assistant can never open inside the assistant.
    var showsAssistantButton = true

    init(job: ScheduledJob, showsAssistantButton: Bool = true) {
        self.job = job
        self.showsAssistantButton = showsAssistantButton
        let id = job.persistentModelID
        _storedJob = Query(filter: #Predicate<ScheduledJob> { $0.persistentModelID == id })
    }

    /// What the model is told is on screen when the sparkles sheet opens.
    private var assistantRecord: GLAIOnScreen? {
        GLAIOnScreen(.job, job, label: job.displayTitle, in: modelContext)
    }

    @State private var showingEdit = false
    @State private var showingDelete = false
    @State private var showingNewInvoice = false
    @State private var showingPaywall = false
    @State private var selectedInvoice: Invoice?
    @State private var showingAddToProject = false
    @State private var completionURL: URL?
    @State private var completionFailed = false
    @State private var showingCompletionPreview = false
    @State private var showingDocImporter = false
    /// Why a picked file wasn't added (unreadable, or over the backup's 25 MB) — the shared alert.
    @State private var importFailure: FileImportFailure?
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var photoLoadFailed = false
    @State private var previewPhoto: JobAttachment?
    @State private var selectedReceipt: Receipt?
    /// Set when a lapsed subscription refuses a write — the alert names it (ReadOnlyGate.swift).
    @State private var readOnlyRefusal: MBWriteOperation?
    /// A refusal JobService threw that the screen did not predict (DomainErrorAlert.swift).
    @State private var domainError: DomainError?

    private var stillExists: Bool {
        !job.isSavedDelete && !job.isDeleted && !storedJob.isEmpty
    }

    private var gold: Color { GLTheme.accentFill }

    var body: some View {
        // BRANCH, not overlay (CRUD audit 2026-09-02): an overlay still evaluates the body
        // against the deleted record — property reads on a dead @Model trap uncatchably.
        if stillExists { aliveBody } else { DeletedRecordView(title: mbLoc("Job"), noun: "this job") { dismiss() } }
    }

    @ViewBuilder private var aliveBody: some View {
        ScrollView {
            VStack(spacing: 20) {
                headerCard
                if !job.serviceAddress.isEmpty { serviceAddressCard }
                if showsBilling { billingCard }
                if let project = job.project { projectCard(project) }
                if job.hasSource { sourceCard }
                if !job.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { notesCard }
                photosCard
                documentsCard
                receiptsCard
            }
            .padding(.horizontal, GLLayout.rowCardInset)
            .padding(.vertical)
            // One column with the banners above (QA 2026-10-03 F50): capped at 640 pt, the gutter inside it.
            .glReadableWidth()
        }
        .mbSystemBanners()
        .readOnlyRefusalAlert($readOnlyRefusal)
        .domainErrorAlert($domainError)
        .containerBackground(for: .navigation) {
            PrimaryBackground()
        }
        .navigationTitle(GLScript.padded(job.displayTitle))
        .toolbarTitleDisplayMode(.large)
        .contentMargins(.top, GLScript.titleClearance(for: GLScript.padded(job.displayTitle)), for: .scrollContent)
        .toolbar {
            // A pure check: the id is minted in the button's action, never in this builder.
            if showsAssistantButton, job.canBeNamedToAssistant {
                ToolbarItem(placement: .topBarTrailing) {
                    MBAssistantButton { assistantRecord }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { showingEdit = true } label: { Label("Edit", systemImage: "pencil") }
                    Menu {
                        ForEach(JobStatus.allCases) { option in
                            Button { setStatus(option) } label: {
                                Label(option.label,
                                      systemImage: job.status == option ? "checkmark" : statusIcon(option))
                            }
                        }
                    } label: { Label("Status", systemImage: "flag") }
                    Button { showingAddToProject = true } label: {
                        Label(job.project == nil ? "Add to project" : "Change project",
                              systemImage: "folder.badge.plus")
                    }
                    Section {
                        Button(role: .destructive) { showingDelete = true } label: {
                            Label("Delete job", systemImage: "trash")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .accessibilityLabel("More")
            }
        }
        .navigationDestination(isPresented: $showingEdit) {
            JobFormScreen(editing: job)
        }
        .navigationDestination(isPresented: $showingNewInvoice) {
            if let customer = job.customer {
                InvoiceFormScreen(customer: customer, job: job)
            }
        }
        .paywallSheet(isPresented: $showingPaywall)
        .sheet(isPresented: $showingAddToProject) {
            AddToProjectSheet(job: job).glAppearance(colorScheme)
        }
        .alert("Couldn\u{2019}t create the completion package", isPresented: $completionFailed) {
            Button("Try Again") { makeCompletionPackage() }
            Button("OK", role: .cancel) { }
        } message: {
            Text("This usually means your device is low on storage. Free up some space and try again.")
        }
        .sheet(isPresented: $showingCompletionPreview) {
            if let url = completionURL {
                DocumentPreviewSheet(url: url, title: "Completion Package",
                                     subject: completionSubject, message: completionMessage)
                    .glAppearance(colorScheme)
            }
        }
        .navigationDestination(item: $selectedInvoice) { invoice in
            InvoiceDetailScreen(invoice: invoice)
        }
        .alert("Delete this job?", isPresented: $showingDelete) {
            Button("Delete job", role: .destructive) {
                guard ReadOnlyGate.allows(.deleteJob, into: $readOnlyRefusal) else { return }
                guard perform({ try DeletionService.delete([.job(job)], origin: .screen, in: modelContext) }) else { return }
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        }
        .navigationDestination(item: $selectedReceipt) { receipt in
            ReceiptDetailScreen(receipt: receipt)
        }
        .fileImporter(isPresented: $showingDocImporter, allowedContentTypes: [.pdf, .image]) { result in
            guard case .success(let url) = result else { return }
            guard ReadOnlyGate.allows(.addJobAttachment, into: $readOnlyRefusal) else { return }
            // Size-checked first, then read off the main thread (F124).
            Task {
                switch await FileImport.read(url) {
                case .success(let data):
                    perform { try DocumentService.attachDocument(data, name: url.lastPathComponent, to: .job(job), in: modelContext) }
                case .failure(let failure):
                    importFailure = failure
                }
            }
        }
        .task(id: photoItems) { await addPickedPhotos() }
        // Leaving the screen cancels the import mid-batch; clear the picks so returning doesn't
        // re-run the same batch and re-insert the photos that were already saved before the cancel.
        // (A re-pick's cancellation keeps its own new selection — this only fires on disappear.)
        .onDisappear { photoItems = [] }
        .photoLoadFailureAlert($photoLoadFailed)
        .fileImportFailureAlert($importFailure)
        .fullScreenCover(item: $previewPhoto) { photo in
            JobPhotoViewer(attachment: photo)
        }
    }

    // MARK: - Cards

    private var headerCard: some View {
        MBTitledCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    Text(job.displayTitle).font(.title3.weight(.semibold))
                    Spacer()
                    JobStatusBadge(status: job.status)
                }
                if !job.displayCustomerName.isEmpty { infoRow("Customer", job.displayCustomerName) }
                if job.isAllDay {
                    infoRow("Dates", dateRange)
                    infoRow("Length", ScheduledJob.workdaysText(job.durationDays))
                } else {
                    infoRow("Date", job.startDate.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted).locale(MBLocalization.currentLocale)))
                    if !job.timeText.isEmpty { infoRow("Time", job.timeText) }
                }
                if job.isRecurring { infoRow("Repeats", job.recurrenceSummary) }
                if let completed = job.completedAt {
                    infoRow("Completed", completed.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted).locale(MBLocalization.currentLocale)))
                }
            }
        }
    }

    private var serviceAddressCard: some View {
        MBTitledCard(title: "Service address") {
            if job.serviceAddress.isEmpty {
                Text("—")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                GLContactLink(.address, job.serviceAddress.singleLine, display: job.serviceAddress.formattedMultiline)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var showsBilling: Bool {
        job.customer != nil || job.agreedPrice != nil || !job.liveRows(job.billingInvoices).isEmpty
    }

    private var billingInvoices: [Invoice] {
        job.liveRows(job.billingInvoices).sorted { $0.createdAt < $1.createdAt }
    }

    private var billingCard: some View {
        MBTitledCard(title: "Billing") {
            VStack(alignment: .leading, spacing: 10) {
                moneyRow("Contracted", job.contractedValue)
                if job.invoicedTotal > 0.005 { moneyRow("Invoiced", job.invoicedTotal) }
                if job.amountPaid > 0.005 { moneyRow("Collected", job.amountPaid) }
                if job.remainingToInvoice > 0.005 { moneyRow("Left to invoice", job.remainingToInvoice) }
                if job.balanceDue > 0.005 { moneyRow("Balance due", job.balanceDue) }
                if job.isFullyBilledAndCollected && job.contractedValue > 0.005 {
                    Label("Paid in full", systemImage: "checkmark.seal.fill")
                        .font(.subheadline.weight(.semibold)).foregroundStyle(GLTheme.statusGood)
                }

                if !billingInvoices.isEmpty {
                    Divider()
                    ForEach(billingInvoices) { invoice in
                        Button { selectedInvoice = invoice } label: { invoiceRow(invoice) }
                            .buttonStyle(.plain)
                    }
                }

                Divider()
                Button { newInvoice() } label: {
                    Label("New invoice", systemImage: "plus")
                }
                .disabled(job.customer == nil)
                if job.customer == nil {
                    Text("Link a customer to bill this job.")
                        .font(.caption).foregroundStyle(GLTheme.textSecondary)
                }

                if job.status == .completed && !job.isRecurring {
                    Divider()
                    if job.isFullyBilledAndCollected {
                        Button { makeCompletionPackage() } label: {
                            Label("Completion package", systemImage: "checkmark.seal")
                        }
                    } else {
                        Text(job.remainingToInvoice > 0.005
                             ? "Invoice the remaining \(money(job.remainingToInvoice)) to issue the completion package."
                             : "Record the outstanding \(money(job.balanceDue)) to issue the completion package.")
                            .font(.caption).foregroundStyle(GLTheme.textSecondary)
                    }
                }
            }
        }
    }

    private func money(_ value: Double) -> String { value.formatted(.money(code: currencyCode)) }

    /// Open the new-invoice form for this job, or the paywall if a free user is at the invoice cap.
    private func newInvoice() {
        if AccessGate.attemptCreate(Invoice.self, cap: FreeTier.invoices, in: modelContext,
                                    subscription: subscription, operation: .saveInvoice,
                                    paywall: $showingPaywall, refusal: $readOnlyRefusal) {
            showingNewInvoice = true
        }
    }

    private func makeCompletionPackage() {
        // Generating a document is the app DOING something on their behalf, which a read-only app
        // does not do — the ruling names 1099/W-9/PDF generation explicitly.
        guard ReadOnlyGate.allows(.generateCompletionPackage, into: $readOnlyRefusal) else { return }
        completionURL = CompletionPackagePDF.render(job: job, business: profiles.first)
        // A nil URL used to mean the button did nothing at all — tapped, and the app
        // just sat there with no sheet and no explanation. Say what happened and give
        // the owner the retry, the same way the estimate and invoice screens do.
        if completionURL != nil { showingCompletionPreview = true } else { completionFailed = true }
    }

    private var completionSubject: String { CompletionPackageMessage.subject(job: job, business: profiles.first) }
    private var completionMessage: String { CompletionPackageMessage.body(job: job, business: profiles.first) }

    private func moneyRow(_ label: LocalizedStringKey, _ amount: Double) -> some View {
        HStack {
            Text(label).foregroundStyle(GLTheme.textSecondary)
            Spacer()
            Text(amount.formatted(.money(code: currencyCode)))
        }
    }

    private func invoiceRow(_ invoice: Invoice) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(invoice.number.isEmpty ? mbLoc("Invoice") : invoice.number)
                    .font(.subheadline)
                Text(invoice.createdAt.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted).locale(MBLocalization.currentLocale)))
                    .font(.caption).foregroundStyle(GLTheme.textSecondary)
            }
            Spacer()
            Text(invoice.total.formatted(.money(code: currencyCode))).font(.subheadline)
            InvoiceStatusBadge(invoice: invoice)
            Image(systemName: "chevron.right").font(.glCaption.weight(.semibold)).foregroundStyle(GLTheme.textTertiary)
                .accessibilityHidden(true)
        }
        .frame(minHeight: 44)   // law 16: a full tap target
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var sourceCard: some View {
        MBTitledCard(title: "Source") {
            if let estimate = job.estimate {
                NavigationLink { EstimateDetailScreen(estimate: estimate) } label: {
                    sourceLabel("View source estimate", systemImage: "doc.text")
                }
                .buttonStyle(.plain)
            } else if let invoice = job.invoice {
                NavigationLink { InvoiceDetailScreen(invoice: invoice) } label: {
                    sourceLabel("View source invoice", systemImage: "banknote")
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func projectCard(_ project: Project) -> some View {
        MBTitledCard(title: "Project") {
            NavigationLink { ProjectDetailScreen(project: project) } label: {
                HStack(spacing: 12) {
                    Image(systemName: "folder").frame(width: 24).foregroundStyle(gold)
                        .accessibilityHidden(true)
                    Text(project.displayName)
                    Spacer()
                    Image(systemName: "chevron.right").font(.glCaption.weight(.semibold)).foregroundStyle(GLTheme.textTertiary)
                        .accessibilityHidden(true)
                }
                .frame(minHeight: 44)   // law 16
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private var notesCard: some View {
        MBTitledCard(title: "Notes") {
            Text(job.notes).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Photos, documents, receipts

    /// Proof-of-finalized-work photos: a thumbnail grid (tap to view full, long-press to delete) plus
    /// a multi-select picker. Photos aren't cropped — proof shots keep their full frame.
    private var photosCard: some View {
        MBTitledCard(title: "Photos") {
            VStack(alignment: .leading, spacing: 12) {
                Text("Pictures of the finished work.")
                    .font(.caption).foregroundStyle(GLTheme.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if !job.photos.isEmpty {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 84), spacing: 8)], spacing: 8) {
                        ForEach(job.photos) { photo in
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
                PhotosPicker(selection: $photoItems, maxSelectionCount: 0, matching: .images) {
                    Label(job.photos.isEmpty ? "Add photos" : "Add more photos", systemImage: "photo.badge.plus")
                        .font(.subheadline.weight(.semibold)).foregroundStyle(GLTheme.accentText)
                        .frame(minHeight: 44)   // law 16
                        .contentShape(Rectangle())
                }
            }
        }
    }

    /// Additional documents (PDF or image) — the same upload + view flow as the insurance documents.
    private var documentsCard: some View {
        MBTitledCard(title: "Documents") {
            VStack(alignment: .leading, spacing: 10) {
                if job.documents.isEmpty {
                    Text("Permits, supplier slips, and other files for this job.")
                        .font(.caption).foregroundStyle(GLTheme.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    ForEach(job.documents) { doc in
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

    /// Receipts attached to this job (also visible under the customer). The add/scan flow is the
    /// shared `ReceiptListView`, scoped to this job so new scans pre-attach.
    private var receiptsCard: some View {
        MBTitledCard(title: "Expenses") {
            VStack(alignment: .leading, spacing: 10) {
                if job.sortedReceipts.isEmpty {
                    Text("Attach material, equipment, and fuel receipts for this job.")
                        .font(.caption).foregroundStyle(GLTheme.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    ForEach(job.sortedReceipts) { receipt in
                        Button { selectedReceipt = receipt } label: { receiptRow(receipt) }
                            .buttonStyle(.plain)
                    }
                }
                Divider()
                NavigationLink { JobReceiptsScreen(job: job) } label: {
                    Label(job.sortedReceipts.isEmpty ? "Add receipt" : "Add or manage receipts", systemImage: "plus")
                        .frame(minHeight: 44)   // law 16
                        .contentShape(Rectangle())
                }
            }
        }
    }

    private func receiptRow(_ receipt: Receipt) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(receipt.vendor.isEmpty ? mbLoc("Expense") : receipt.vendor).font(.subheadline)
                Text(receipt.date.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted).locale(MBLocalization.currentLocale)))
                    .font(.caption).foregroundStyle(GLTheme.textSecondary)
            }
            Spacer()
            Text(receipt.total.formatted(.money(code: currencyCode))).font(.subheadline)
            Image(systemName: "chevron.right").font(.glCaption.weight(.semibold)).foregroundStyle(GLTheme.textTertiary)
                .accessibilityHidden(true)
        }
        .frame(minHeight: 44)   // law 16: a full tap target
        .contentShape(Rectangle())
    }

    /// Normalize each picked image to a compressed JPEG (CloudKit-friendly) and attach it to the job.
    /// Re-picking while a batch is importing cancels this task via `.task(id: photoItems)` — a
    /// cancelled batch must bail quietly: no "couldn't load" alert, and it must NOT clear `photoItems`
    /// (that would restart the `.task` and cancel the replacement batch mid-import).
    private func addPickedPhotos() async {
        guard !photoItems.isEmpty else { return }
        // Refused before the first image is decoded, not after: a lapsed app should not spend the
        // battery downsampling 50 photos it is not going to keep.
        guard ReadOnlyGate.allows(.addJobAttachment, into: $readOnlyRefusal) else {
            photoItems = []
            return
        }
        let items = Array(photoItems.prefix(50))   // sane batch guard
        var imported: [Data] = []
        for item in items {
            if Task.isCancelled { break }
            guard let data = try? await item.loadTransferable(type: Data.self) else {
                // Cancellation surfaces here as a thrown CancellationError — not a load failure.
                if Task.isCancelled { break }
                photoLoadFailed = true
                continue
            }
            // Shrunk to 1024 px and encoded OFF the main actor (Photo Intake Memory Defense, law
            // 62), so a batch of 12MP photos doesn't hitch the UI or store multi-MB blobs.
            let jpeg = await ImageDownsampler.intakeJPEG(from: data)
            if Task.isCancelled { break }
            if let jpeg {
                imported.append(jpeg)
            } else {
                photoLoadFailed = true
            }
        }
        // Keep whatever imported before a cancellation.
        if !imported.isEmpty { perform { try DocumentService.attachPhotos(imported, to: .job(job), in: modelContext) } }
        guard !Task.isCancelled else { return }   // the replacement batch owns `photoItems` now
        photoItems = []
    }

    private func delete(_ attachment: JobAttachment) {
        guard ReadOnlyGate.allows(.deleteJobAttachment, into: $readOnlyRefusal) else { return }
        perform { try DeletionService.delete([.attachment(attachment)], origin: .screen, in: modelContext) }
    }

    /// Runs a JobService write after the screen's own gate; a refusal it did not predict (the job
    /// deleted under it, say) is shown instead of dropped. True when the write went through.
    @discardableResult
    private func perform(_ write: () throws -> Void) -> Bool {
        do {
            try write()
            return true
        } catch {
            DomainError.present(error, readOnly: $readOnlyRefusal, domainError: $domainError)
            return false
        }
    }

    // MARK: - Helpers

    private func sourceLabel(_ title: LocalizedStringKey, systemImage: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage).frame(width: 24).foregroundStyle(gold)
                .accessibilityHidden(true)
            Text(title)
            Spacer()
            Image(systemName: "chevron.right").font(.glCaption.weight(.semibold)).foregroundStyle(GLTheme.textTertiary)
                .accessibilityHidden(true)
        }
        .frame(minHeight: 44)   // law 16: a full tap target
        .contentShape(Rectangle())
    }

    private func infoRow(_ label: LocalizedStringKey, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(GLTheme.textSecondary)
            Spacer()
            Text(value.isEmpty ? "—" : value).multilineTextAlignment(.trailing).copyable(value)
        }
    }

    private func statusIcon(_ status: JobStatus) -> String {
        switch status {
        case .scheduled: "calendar"
        case .inProgress: "hammer"
        case .completed: "checkmark.seal"
        }
    }

    private func setStatus(_ status: JobStatus) {
        // "No status changes" is named in the ruling — a status IS a write, even though the screen
        // makes it look like a view option.
        guard ReadOnlyGate.allows(.changeJobStatus, into: $readOnlyRefusal) else { return }
        // Completing stamps completedAt once (the warranty clock); any other status clears it.
        perform { try JobService.setStatus(status, for: job, in: modelContext) }
    }

    private var currencyCode: String { "USD" }   // US-only at launch — match every other money surface

    private var dateRange: String {
        let start = job.startDate
        // Schedule-aware (holidays / vacations skipped) so the detail matches the calendar/agenda end date.
        let end = job.endDay(schedule: effectiveWorkSchedule(profiles.first, legacyMask: workdaysMask))
        return Calendar.current.isDate(start, inSameDayAs: end)
            ? start.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted).locale(MBLocalization.currentLocale))
            : "\(start.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted).locale(MBLocalization.currentLocale))) – \(end.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted).locale(MBLocalization.currentLocale)))"
    }
}

/// Full-screen viewer for a proof-of-work photo (or any image/PDF attachment).
struct JobPhotoViewer: View {
    @Environment(\.dismiss) private var dismiss
    let attachment: JobAttachment

    var body: some View {
        NavigationStack {
            Group {
                if let data = attachment.data {
                    CertificatePreview(data: data)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ContentUnavailableView("No image", systemImage: "photo")
                }
            }
            .background { GLTheme.resolved(GLTheme.background, in: .light).ignoresSafeArea() }
            .navigationTitle(GLScript.padded(attachment.name.isEmpty ? mbLoc("Photo") : attachment.name))
            .toolbarTitleDisplayMode(.large)
            .contentMargins(.top, GLScript.titleClearance(for: GLScript.padded(attachment.name.isEmpty ? mbLoc("Photo") : attachment.name)), for: .scrollContent)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button(role: .close) { dismiss() } }
            }
        }
    }
}

/// View / replace / remove one job DOCUMENT — the shared insurance-document flow, backed by a
/// `JobAttachment`. Removing it deletes the attachment record (not just its bytes).
struct JobDocumentDetailScreen: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var profiles: [BusinessProfile]
    let attachment: JobAttachment

    var body: some View {
        DocumentDetailScreen(slot: DocumentSlot(
            title: attachment.name.isEmpty ? mbLoc("Document") : attachment.name,
            data: attachment.data,
            name: attachment.name,
            fallbackFileName: "Document.pdf",
            businessName: profiles.first?.businessName ?? "",
            removeTitle: "Remove document",
            removeSubtitle: "Delete this document from the job.",
            store: { data, name in
                // DocumentDetailScreen has already gated (and refused out loud); `try?` here only
                // drops a write DocumentService finds impossible (the attachment went away).
                try? DocumentService.set(.attachment(attachment), data: data, name: name, in: modelContext)
            }
        ))
    }
}

/// This job's receipts, using the shared receipts list + scan/add flow scoped to the job.
struct JobReceiptsScreen: View {
    let job: ScheduledJob

    var body: some View {
        ReceiptListView(receipts: job.sortedReceipts,
                        defaultCustomer: job.customer,
                        defaultJob: job,
                        title: "Job Receipts")
    }
}
