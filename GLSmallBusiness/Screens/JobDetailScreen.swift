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

    private var stillExists: Bool {
        allJobs.contains { $0.persistentModelID == job.persistentModelID }
    }

    private var gold: Color { GLColor.gold.render(in: colorScheme) }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                headerCard
                if !job.serviceAddress.isEmpty { serviceAddressCard }
                if job.agreedPrice != nil { priceCard }
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

    private var priceCard: some View {
        GLCard {
            infoRow("Agreed price", (job.agreedPrice ?? 0).formatted(.currency(code: currencyCode)))
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
