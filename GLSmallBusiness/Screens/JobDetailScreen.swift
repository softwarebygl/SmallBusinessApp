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

struct JobDetailScreen: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @AppStorage(SchedulingPrefs.workdaysMaskKey) private var workdaysMask = SchedulingPrefs.defaultWorkdaysMask
    @Query private var allJobs: [ScheduledJob]
    let job: ScheduledJob

    @State private var showingEdit = false
    @State private var showingDelete = false
    @State private var showingNewInvoice = false
    @State private var selectedInvoice: Invoice?
    @State private var showingAddToProject = false

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
                    Button { showingEdit = true } label: { Label("Edit job", systemImage: "pencil") }
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
        .sheet(isPresented: $showingEdit) {
            JobFormScreen(editing: job).glAppearance(colorScheme)
        }
        .sheet(isPresented: $showingNewInvoice) {
            if let customer = job.customer {
                InvoiceFormScreen(customer: customer, job: job).glAppearance(colorScheme)
            }
        }
        .sheet(isPresented: $showingAddToProject) {
            AddToProjectSheet(job: job).glAppearance(colorScheme)
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
                Button { showingNewInvoice = true } label: {
                    Label("New invoice", systemImage: "plus")
                }
                .disabled(job.customer == nil)
                if job.customer == nil {
                    Text("Link a customer to bill this job.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

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
