//
//  JobDetailScreen.swift
//  GLSmallBusiness
//
//  Detail for a first-class Job: schedule, customer, optional price, the source doc it links back to,
//  and notes. The toolbar edits the job, changes its status (marking complete stamps the completion
//  date), or deletes it. Mirrors InvoiceDetailScreen's layout conventions.
//

import SwiftUI
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
    @Query private var allJobs: [ScheduledJob]
    @Query private var profiles: [BusinessProfile]
    let job: ScheduledJob

    @State private var showingEdit = false
    @State private var showingDelete = false
    @State private var showingNewInvoice = false
    @State private var showingPaywall = false
    @State private var selectedInvoice: Invoice?
    @State private var showingAddToProject = false
    @State private var completionURL: URL?
    @State private var showingCompletionPreview = false
    @State private var showingDocImporter = false
    @State private var uploadFailed = false
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var photoLoadFailed = false
    @State private var previewPhoto: JobAttachment?
    @State private var selectedReceipt: Receipt?

    private var stillExists: Bool {
        allJobs.contains { $0.persistentModelID == job.persistentModelID }
    }

    private var gold: Color { GLColor.gold.render(in: colorScheme) }

    var body: some View {
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
            .padding()
        }
        .containerBackground(for: .navigation) {
            PrimaryBackground()
        }
        .overlay {
            if !stillExists {
                DeletedRecordView(noun: "job") { dismiss() }
            }
        }
        .navigationTitle(job.displayTitle)
        .toolbarTitleDisplayMode(.inline)
        .toolbar {
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
        .confirmationDialog("Delete this job?", isPresented: $showingDelete, titleVisibility: .visible) {
            Button("Delete job", role: .destructive) {
                modelContext.delete(job)
                modelContext.saveChanges()
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        }
        .navigationDestination(item: $selectedReceipt) { receipt in
            ReceiptDetailScreen(receipt: receipt)
        }
        .fileImporter(isPresented: $showingDocImporter, allowedContentTypes: [.pdf, .image]) { result in
            guard case .success(let url) = result else { return }
            if let data = url.readSecurityScoped() {
                modelContext.insert(JobAttachment(kind: .document, name: url.lastPathComponent, data: data, job: job))
                modelContext.saveChanges()
            } else {
                uploadFailed = true
            }
        }
        .task(id: photoItems) { await addPickedPhotos() }
        .photoLoadFailureAlert($photoLoadFailed)
        .alert("Couldn’t read that file", isPresented: $uploadFailed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("That file couldn’t be opened. Try a different file, or export it as a PDF first.")
        }
        .fullScreenCover(item: $previewPhoto) { photo in
            JobPhotoViewer(attachment: photo)
        }
    }

    // MARK: - Cards

    private var headerCard: some View {
        GLCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    Text(job.displayTitle).font(.title3.weight(.semibold))
                    Spacer()
                    JobStatusBadge(status: job.status)
                }
                if !job.customerName.isEmpty { infoRow("Customer", job.customerName) }
                if job.isAllDay {
                    infoRow("Dates", dateRange)
                    infoRow("Length", "\(job.durationDays) \(job.durationDays == 1 ? "workday" : "workdays")")
                } else {
                    infoRow("Date", job.startDate.formatted(date: .abbreviated, time: .omitted))
                    if !job.timeText.isEmpty { infoRow("Time", job.timeText) }
                }
                if job.isRecurring { infoRow("Repeats", job.recurrenceSummary) }
                if let completed = job.completedAt {
                    infoRow("Completed", completed.formatted(date: .abbreviated, time: .omitted))
                }
            }
        }
    }

    private var serviceAddressCard: some View {
        GLCard(title: "Service address") {
            Text(job.serviceAddress.formattedMultiline)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var showsBilling: Bool {
        job.customer != nil || job.agreedPrice != nil || !(job.billingInvoices ?? []).isEmpty
    }

    private var billingInvoices: [Invoice] {
        (job.billingInvoices ?? []).sorted { $0.createdAt < $1.createdAt }
    }

    private var billingCard: some View {
        GLCard(title: "Billing") {
            VStack(alignment: .leading, spacing: 10) {
                moneyRow("Contracted", job.contractedValue)
                if job.invoicedTotal > 0.005 { moneyRow("Invoiced", job.invoicedTotal) }
                if job.amountPaid > 0.005 { moneyRow("Collected", job.amountPaid) }
                if job.remainingToInvoice > 0.005 { moneyRow("Left to invoice", job.remainingToInvoice) }
                if job.balanceDue > 0.005 { moneyRow("Balance due", job.balanceDue) }
                if job.isFullyBilledAndCollected && job.contractedValue > 0.005 {
                    Label("Paid in full", systemImage: "checkmark.seal.fill")
                        .font(.subheadline.weight(.semibold)).foregroundStyle(.green)
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
                        .font(.caption).foregroundStyle(.secondary)
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
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func money(_ value: Double) -> String { value.formatted(.currency(code: currencyCode)) }

    /// Open the new-invoice form for this job, or the paywall if a free user is at the invoice cap.
    private func newInvoice() {
        if AccessGate.canCreate(Invoice.self, cap: FreeTier.invoices, in: modelContext, subscription: subscription) {
            showingNewInvoice = true
        } else {
            showingPaywall = true
        }
    }

    private func makeCompletionPackage() {
        completionURL = CompletionPackagePDF.render(job: job, business: profiles.first)
        if completionURL != nil { showingCompletionPreview = true }
    }

    private var completionSubject: String { CompletionPackageMessage.subject(job: job, business: profiles.first) }
    private var completionMessage: String { CompletionPackageMessage.body(job: job, business: profiles.first) }

    private func moneyRow(_ label: LocalizedStringKey, _ amount: Double) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(amount.formatted(.currency(code: currencyCode)))
        }
    }

    private func invoiceRow(_ invoice: Invoice) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(invoice.number.isEmpty ? String(localized: "Invoice") : invoice.number)
                    .font(.subheadline)
                Text(invoice.createdAt.formatted(date: .abbreviated, time: .omitted))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(invoice.total.formatted(.currency(code: currencyCode))).font(.subheadline)
            InvoiceStatusBadge(invoice: invoice)
            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var sourceCard: some View {
        GLCard(title: "Source") {
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
        GLCard(title: "Project") {
            NavigationLink { ProjectDetailScreen(project: project) } label: {
                HStack(spacing: 12) {
                    Image(systemName: "folder").frame(width: 24).foregroundStyle(gold)
                    Text(project.displayName)
                    Spacer()
                    Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
        }
    }

    private var notesCard: some View {
        GLCard(title: "Notes") {
            Text(job.notes).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Photos, documents, receipts

    /// Proof-of-finalized-work photos: a thumbnail grid (tap to view full, long-press to delete) plus
    /// a multi-select picker. Photos aren't cropped — proof shots keep their full frame.
    private var photosCard: some View {
        GLCard(title: "Photos") {
            VStack(alignment: .leading, spacing: 12) {
                Text("Pictures of the finished work.")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if !job.photos.isEmpty {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 84), spacing: 8)], spacing: 8) {
                        ForEach(job.photos) { photo in
                            Button { previewPhoto = photo } label: {
                                ScanThumbnail(data: photo.data, size: 84)
                                    .frame(width: 84, height: 84)
                                    .clipShape(RoundedRectangle(cornerRadius: 10))
                                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(.black.opacity(0.1)))
                            }
                            .buttonStyle(.plain)
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
                        .font(.subheadline.weight(.semibold)).foregroundStyle(gold)
                }
            }
        }
    }

    /// Additional documents (PDF or image) — the same upload + view flow as the insurance documents.
    private var documentsCard: some View {
        GLCard(title: "Documents") {
            VStack(alignment: .leading, spacing: 10) {
                if job.documents.isEmpty {
                    Text("Permits, supplier slips, and other files for this job.")
                        .font(.caption).foregroundStyle(.secondary)
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
                }
            }
        }
    }

    private func documentRow(_ doc: JobAttachment) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "doc.text").font(.title3).foregroundStyle(gold)
            Text(doc.name.isEmpty ? String(localized: "Document") : doc.name)
                .font(.subheadline).lineLimit(1).truncationMode(.middle)
            Spacer()
            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
        }
    }

    /// Receipts attached to this job (also visible under the customer). The add/scan flow is the
    /// shared `ReceiptListView`, scoped to this job so new scans pre-attach.
    private var receiptsCard: some View {
        GLCard(title: "Receipts") {
            VStack(alignment: .leading, spacing: 10) {
                if job.sortedReceipts.isEmpty {
                    Text("Attach material, equipment, and fuel receipts for this job.")
                        .font(.caption).foregroundStyle(.secondary)
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
                }
            }
        }
    }

    private func receiptRow(_ receipt: Receipt) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(receipt.vendor.isEmpty ? String(localized: "Receipt") : receipt.vendor).font(.subheadline)
                Text(receipt.date.formatted(date: .abbreviated, time: .omitted))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(receipt.total.formatted(.currency(code: currencyCode))).font(.subheadline)
            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
        }
    }

    /// Normalize each picked image to a compressed JPEG (CloudKit-friendly) and attach it to the job.
    private func addPickedPhotos() async {
        guard !photoItems.isEmpty else { return }
        for item in photoItems {
            if let data = try? await item.loadTransferable(type: Data.self),
               let jpeg = UIImage(data: data)?.jpegData(compressionQuality: 0.7) {
                modelContext.insert(JobAttachment(kind: .photo, name: "Photo", data: jpeg, job: job))
            } else {
                photoLoadFailed = true
            }
        }
        modelContext.saveChanges()
        photoItems = []
    }

    private func delete(_ attachment: JobAttachment) {
        modelContext.delete(attachment)
        modelContext.saveChanges()
    }

    // MARK: - Helpers

    private func sourceLabel(_ title: LocalizedStringKey, systemImage: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage).frame(width: 24).foregroundStyle(gold)
            Text(title)
            Spacer()
            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
        }
    }

    private func infoRow(_ label: LocalizedStringKey, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value.isEmpty ? "—" : value).multilineTextAlignment(.trailing)
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
        job.status = status
        if status == .completed {
            if job.completedAt == nil { job.completedAt = .now }
        } else {
            job.completedAt = nil
        }
        modelContext.saveChanges()
    }

    private var currencyCode: String { Locale.current.currency?.identifier ?? "USD" }

    private var dateRange: String {
        let start = job.startDate
        let end = job.endDay(mask: workdaysMask)
        return Calendar.current.isDate(start, inSameDayAs: end)
            ? start.formatted(date: .abbreviated, time: .omitted)
            : "\(start.formatted(date: .abbreviated, time: .omitted)) – \(end.formatted(date: .abbreviated, time: .omitted))"
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
            .background { GLColor.backgroundPrimary.render(in: .light).ignoresSafeArea() }
            .navigationTitle(attachment.name.isEmpty ? "Photo" : attachment.name)
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
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
            title: attachment.name.isEmpty ? String(localized: "Document") : attachment.name,
            data: attachment.data,
            name: attachment.name,
            fallbackFileName: "Document.pdf",
            businessName: profiles.first?.businessName ?? "",
            removeTitle: "Remove document",
            removeSubtitle: "Delete this document from the job.",
            store: { data, name in
                if let data {
                    attachment.data = data
                    attachment.name = name
                } else {
                    modelContext.delete(attachment)
                }
                modelContext.saveChanges()
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
