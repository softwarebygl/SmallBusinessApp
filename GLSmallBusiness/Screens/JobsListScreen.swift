//
//  JobsListScreen.swift
//  GLSmallBusiness
//
//  The list of a customer's jobs (the first-class Job feature). Mirrors InvoicesListScreen: rows are
//  computed from the customer's `scheduledJobs` inverse, tap opens the detail, "+" opens the form.
//

import SwiftUI
import SwiftData
import GoldLifeUI

struct JobsListScreen: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(SubscriptionManager.self) private var subscription
    @AppStorage(SchedulingPrefs.workdaysMaskKey) private var workdaysMask = SchedulingPrefs.defaultWorkdaysMask
    let customer: Customer

    @State private var showingNew = false
    @State private var pendingDelete: [ScheduledJob]?
    /// Set when a lapsed subscription refuses a write — the alert names it (ReadOnlyGate.swift).
    @State private var readOnlyRefusal: MBWriteOperation?
    /// A refusal JobService threw that the screen did not predict (DomainErrorAlert.swift).
    @State private var domainError: DomainError?
    @State private var showingPaywall = false
    @State private var selectedJob: ScheduledJob?

    private var jobs: [ScheduledJob] {
        customer.liveRows(customer.scheduledJobs).sorted { $0.startDate > $1.startDate }
    }

    var body: some View {
        // F24: draws "This customer was removed" once the customer is deleted while open.
        LiveRecordGate(customer, title: "Jobs") { aliveBody }
    }

    @ViewBuilder private var aliveBody: some View {
        List {
            if jobs.isEmpty {
                ContentUnavailableView {
                    Label("No jobs", systemImage: "hammer")
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
                    .confirmFirstDeleteSwipe { pendingDelete = [job] }
                }
            }
        }
        .swipeDeleteConfirmation($pendingDelete, title: "Delete this job?") {
            delete($0)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .mbSystemBanners()
        .readOnlyRefusalAlert($readOnlyRefusal)
        .domainErrorAlert($domainError)
        .containerBackground(for: .navigation) { PrimaryBackground() }
        .navigationTitle(GLScript.padded(mbLoc("Jobs")))
        .toolbarTitleDisplayMode(.large)   // law 57: large even when pushed from an inline parent
        .contentMargins(.top, GLScript.titleClearance(for: GLScript.padded(mbLoc("Jobs"))), for: .scrollContent)   // per-string descender clearance
        .navigationDestination(item: $selectedJob) { job in
            JobDetailScreen(job: job)
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { newJob() } label: { Image(systemName: "plus") }
                    .accessibilityLabel("New Job")
            }
        }
        .navigationDestination(isPresented: $showingNew) {
            JobFormScreen(customer: customer)
        }
        .paywallSheet(isPresented: $showingPaywall)
    }

    /// Open the new-job form, or the paywall if a free user is at the job cap.
    private func newJob() {
        if AccessGate.attemptCreate(ScheduledJob.self, cap: FreeTier.jobs, in: modelContext,
                                    subscription: subscription, operation: .saveJob,
                                    paywall: $showingPaywall, refusal: $readOnlyRefusal) {
            showingNew = true
        }
    }

    private func delete(_ items: [ScheduledJob]) {
        // Deleting a record is a write, so a lapsed app refuses it like any other.
        guard ReadOnlyGate.allows(.deleteJob, into: $readOnlyRefusal) else { return }
        // Rows a sync removed while the confirmation was up are skipped, as before; DeletionService
        // refuses a dead row rather than writing it.
        do {
            try DeletionService.delete(items.filter { $0.modelContext != nil && !$0.isDeleted }.map(DeletionService.Target.job),
                                       origin: .screen, in: modelContext)
        } catch {
            DomainError.present(error, readOnly: $readOnlyRefusal, domainError: $domainError)
        }
    }
}

// MARK: - Shared row + status badge (reused by AllJobsScreen)

struct JobRow: View {
    let job: ScheduledJob
    /// Legacy workdays fallback for `effectiveWorkSchedule` — the end date below is schedule-aware
    /// (holidays / vacations / overrides) so rows match the calendar and agenda, not raw-mask math.
    let mask: Int
    /// All-Jobs shows the customer name on the row; the per-customer list doesn't need to repeat it.
    var showsCustomer: Bool = false
    @Query private var profiles: [BusinessProfile]

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(job.displayTitle).font(.subheadline.weight(.medium))
                if showsCustomer, !job.displayCustomerName.isEmpty {
                    Text(job.displayCustomerName).font(.caption).foregroundStyle(GLTheme.textSecondary)
                }
                Text(dateRange).font(.caption).foregroundStyle(GLTheme.textSecondary)
            }
            Spacer(minLength: 8)
            JobStatusBadge(status: job.status)
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(GLTheme.textTertiary)
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
        let style = Date.FormatStyle(date: .abbreviated, time: .omitted).locale(MBLocalization.currentLocale)
        if !job.isAllDay, !job.timeText.isEmpty {
            return "\(job.startDate.formatted(style)) · \(job.timeText)"
        }
        let start = job.startDate
        let end = job.endDay(schedule: effectiveWorkSchedule(profiles.first, legacyMask: mask))
        return Calendar.current.isDate(start, inSameDayAs: end)
            ? start.formatted(style)
            : "\(start.formatted(style)) – \(end.formatted(style))"
    }
}

struct JobStatusBadge: View {
    let status: JobStatus

    private var color: Color {
        switch status {
        case .scheduled: GLTheme.accentFill
        case .inProgress: GLTheme.statusAttention
        case .completed: GLTheme.statusGood
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
