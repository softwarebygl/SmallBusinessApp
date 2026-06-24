//
//  JobsListScreen.swift
//  GLSmallBusiness
//
//  The list of a customer's jobs (the first-class Job feature). Mirrors InvoicesListScreen: rows are
//  computed from the customer's `scheduledJobs` inverse, tap opens the detail, "+" opens the form.
//

import SwiftUI
import SwiftData

struct JobsListScreen: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.modelContext) private var modelContext
    @AppStorage(SchedulingPrefs.workdaysMaskKey) private var workdaysMask = SchedulingPrefs.defaultWorkdaysMask
    let customer: Customer

    @State private var showingNew = false
    @State private var selectedJob: ScheduledJob?

    private var jobs: [ScheduledJob] {
        (customer.scheduledJobs ?? []).sorted { $0.startDate > $1.startDate }
    }

    var body: some View {
        List {
            if jobs.isEmpty {
                ContentUnavailableView {
                    Label("No Jobs", systemImage: "hammer")
                } description: {
                    Text("Tap + to schedule a job for \(customer.listDisplayName).")
                }
                .listRowBackground(Color.clear)
            } else {
                ForEach(jobs) { job in
                    Button { selectedJob = job } label: {
                        JobRow(job: job, mask: workdaysMask)
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets())
                }
                .onDelete(perform: delete)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .containerBackground(for: .navigation) { PrimaryBackground() }
        .navigationTitle("Jobs")
        .navigationDestination(item: $selectedJob) { job in
            JobDetailScreen(job: job)
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showingNew = true } label: { Image(systemName: "plus") }
                    .accessibilityLabel("New Job")
            }
        }
        .sheet(isPresented: $showingNew) {
            JobFormScreen(customer: customer).glAppearance(colorScheme)
        }
    }

    private func delete(at offsets: IndexSet) {
        for index in offsets { modelContext.delete(jobs[index]) }
        modelContext.saveChanges()
    }
}

// MARK: - Shared row + status badge (reused by AllJobsScreen)

struct JobRow: View {
    let job: ScheduledJob
    let mask: Int
    /// All-Jobs shows the customer name on the row; the per-customer list doesn't need to repeat it.
    var showsCustomer: Bool = false

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(job.displayTitle).font(.subheadline.weight(.medium))
                if showsCustomer, !job.customerName.isEmpty {
                    Text(job.customerName).font(.caption).foregroundStyle(.secondary)
                }
                Text(dateRange).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            JobStatusBadge(status: job.status)
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, GLLayout.rowContentPadding)
        .padding(.vertical, GLLayout.rowContentVerticalPadding)
        .frame(maxWidth: .infinity)
        .glCardBackground()
        .padding(.horizontal, GLLayout.rowCardInset)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private var dateRange: String {
        let start = job.startDate
        let end = job.endDay(mask: mask)
        return Calendar.current.isDate(start, inSameDayAs: end)
            ? start.formatted(date: .abbreviated, time: .omitted)
            : "\(start.formatted(date: .abbreviated, time: .omitted)) – \(end.formatted(date: .abbreviated, time: .omitted))"
    }
}

struct JobStatusBadge: View {
    let status: JobStatus

    private var color: Color {
        switch status {
        case .scheduled: .blue
        case .inProgress: .orange
        case .completed: .green
        }
    }

    var body: some View {
        Text(status.label)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Capsule().fill(color.opacity(0.18)))
            .foregroundStyle(color)
    }
}
