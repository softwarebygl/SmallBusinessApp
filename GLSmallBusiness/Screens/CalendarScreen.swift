//
//  CalendarScreen.swift
//  GLSmallBusiness
//
//  Created by Gold Life LLC on 6/21/26.
//
//  The Calendar tab: a "Next available date" banner + "View gaps", a month grid with booked days
//  marked, an agenda of upcoming jobs, and an "All Jobs" link. The + adds a job from scratch
//  (JobFormScreen) or from an accepted estimate / invoice (ScheduleSourcePicker → ScheduleJobSheet).
//  iPhone wraps its own NavigationStack; the iPad split passes `showsMenuButton: false` and lives
//  inside the content column's nav bar.
//

import SwiftUI
import SwiftData

struct CalendarScreen: View {
    var showsMenuButton: Bool = true

    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(SchedulingPrefs.workdaysMaskKey) private var workdaysMask = SchedulingPrefs.defaultWorkdaysMask
    @Query(sort: \ScheduledJob.startDate) private var jobs: [ScheduledJob]
    @Query private var profiles: [BusinessProfile]

    @State private var showingMenu = false
    @State private var pickingSource = false
    @State private var pendingSource: SourceBox?
    @State private var showingNewJob = false

    private var gold: Color { GLColor.gold.render(in: colorScheme) }
    /// Workdays still come from the existing @AppStorage mask; holidays / vacation / overrides come from
    /// the stored work schedule (defaults to common-holidays-on until the editor lands in Slice C).
    private var schedule: WorkSchedule {
        (profiles.first?.workSchedule ?? .standard).applyingWeekdayMask(workdaysMask)
    }
    /// Row 1 — the soonest bounded opening between booked jobs (nil when nothing is booked ahead).
    private var firstGap: ScheduleGap? { SchedulingEngine.gaps(jobs, schedule: schedule).first }
    /// Row 2 — the first open workday after your last booked job (the open-ended runway).
    private var clearDate: Date { SchedulingEngine.nextClearDate(jobs, schedule: schedule) }
    private var upcoming: [ScheduledJob] {
        let today = Calendar.current.startOfDay(for: .now)
        return jobs.filter { $0.endDay(schedule: schedule) >= today }
    }

    var body: some View {
        if showsMenuButton {
            NavigationStack { content }
        } else {
            content
        }
    }

    @ViewBuilder
    private var content: some View {
        ScrollView {
            VStack(spacing: 18) {
                banner
                MonthGrid(occupied: SchedulingEngine.occupiedDays(jobs, schedule: schedule), gold: gold)
                agenda
                GLHubRow(title: "All Jobs", systemImage: "hammer") { AllJobsScreen() }
            }
            .padding()
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
        }
        .contentMargins(.top, 10, for: .scrollContent)   // breathing room below the large title's descenders
        .containerBackground(for: .navigation) {
            showsMenuButton ? AnyView(PrimaryBackground())
                            : AnyView(GLColor.backgroundPrimary.render(in: colorScheme).ignoresSafeArea())
        }
        .navigationTitle("Calendar")
        .toolbar {
            if showsMenuButton {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showingMenu = true } label: { MenuButtonLabel() }.accessibilityLabel("Menu")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { showingNewJob = true } label: { Label("New job", systemImage: "hammer") }
                    Button { pickingSource = true } label: {
                        Label("From an estimate or invoice", systemImage: "doc.text")
                    }
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Add a job")
            }
        }
        .sheet(isPresented: $showingMenu) { MenuScreen().glAppearance(colorScheme) }
        .sheet(isPresented: $showingNewJob) { JobFormScreen().glAppearance(colorScheme) }
        .sheet(isPresented: $pickingSource) {
            ScheduleSourcePicker { source in
                pickingSource = false
                pendingSource = SourceBox(source: source)
            }
            .glAppearance(colorScheme)
        }
        .sheet(item: $pendingSource) { box in
            ScheduleJobSheet(source: box.source).glAppearance(colorScheme)
        }
    }

    // MARK: - Banner

    private var banner: some View {
        GLCard {
            VStack(alignment: .leading, spacing: 14) {
                if let gap = firstGap {
                    bannerRow(eyebrow: "NEXT AVAILABLE DATE",
                              date: gap.start,
                              detail: "Fits \(gap.workdays) \(gap.workdays == 1 ? "workday" : "workdays")")
                    Divider()
                }
                bannerRow(eyebrow: "NEXT CLEAR DATE",
                          date: clearDate,
                          detail: firstGap == nil ? nil : "Open-ended — nothing booked after")
                NavigationLink {
                    GapsList(jobs: jobs, schedule: schedule)
                } label: {
                    Label("View gaps", systemImage: "rectangle.split.2x1")
                        .font(.subheadline.weight(.semibold)).foregroundStyle(gold)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func bannerRow(eyebrow: LocalizedStringKey, date: Date, detail: String?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(eyebrow)
                .font(.caption2.weight(.semibold)).tracking(0.5).foregroundStyle(.secondary)
            Text(date.formatted(.dateTime.weekday(.wide).month().day()))
                .font(.title3.weight(.semibold)).foregroundStyle(gold)
            if let detail {
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Agenda

    private var agenda: some View {
        GLCard(title: "Upcoming") {
            if upcoming.isEmpty {
                Text("No jobs scheduled yet. Tap + to add one.")
                    .font(.subheadline).foregroundStyle(.secondary)
            } else {
                ForEach(upcoming) { job in
                    jobRow(job)
                    if job.id != upcoming.last?.id { Divider() }
                }
            }
        }
    }

    private func jobRow(_ job: ScheduledJob) -> some View {
        let start = job.startDate
        let end = job.endDay(schedule: schedule)
        let range = Calendar.current.isDate(start, inSameDayAs: end)
            ? start.formatted(date: .abbreviated, time: .omitted)
            : "\(start.formatted(date: .abbreviated, time: .omitted)) – \(end.formatted(date: .abbreviated, time: .omitted))"
        return VStack(alignment: .leading, spacing: 2) {
            Text(job.displayTitle).font(.subheadline.weight(.medium))
            HStack {
                if !job.customerName.isEmpty {
                    Text(job.customerName).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text(range).font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Identifiable wrapper so the source can drive a `.sheet(item:)`.
private struct SourceBox: Identifiable {
    let id = UUID()
    let source: ScheduleJobSource
}

// MARK: - Month grid

private struct MonthGrid: View {
    let occupied: Set<Date>
    let gold: Color
    @State private var month: Date = Calendar.current.startOfDay(for: .now)

    private let calendar = Calendar.current
    private var monthStart: Date {
        calendar.date(from: calendar.dateComponents([.year, .month], from: month)) ?? month
    }

    var body: some View {
        GLCard {
            header
            weekdayHeader
            grid
        }
    }

    private var header: some View {
        HStack {
            Button { shift(-1) } label: { Image(systemName: "chevron.left") }.buttonStyle(.plain)
            Spacer()
            Text(monthStart.formatted(.dateTime.month(.wide).year()))
                .font(.headline)
            Spacer()
            Button { shift(1) } label: { Image(systemName: "chevron.right") }.buttonStyle(.plain)
        }
        .foregroundStyle(gold)
    }

    private var weekdayHeader: some View {
        let symbols = orderedShortWeekdaySymbols()
        return HStack(spacing: 0) {
            ForEach(Array(symbols.enumerated()), id: \.offset) { _, s in
                Text(s).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private var grid: some View {
        let days = monthCells()
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 7), spacing: 6) {
            ForEach(Array(days.enumerated()), id: \.offset) { _, day in
                if let day {
                    dayCell(day)
                } else {
                    Color.clear.frame(height: 34)
                }
            }
        }
    }

    private func dayCell(_ day: Date) -> some View {
        let isOccupied = occupied.contains(calendar.startOfDay(for: day))
        let isToday = calendar.isDateInToday(day)
        let isWorkday = SchedulingPrefs.isWorkday(day, mask: occupiedMaskHint)
        return Text("\(calendar.component(.day, from: day))")
            .font(.subheadline)
            .frame(maxWidth: .infinity, minHeight: 34)
            .background(Circle().fill(isOccupied ? gold : Color.clear).frame(width: 32, height: 32))
            .foregroundStyle(isOccupied ? .white : (isWorkday ? .primary : .secondary))
            .overlay {
                if isToday && !isOccupied {
                    Circle().stroke(gold, lineWidth: 1.5).frame(width: 32, height: 32)
                }
            }
    }

    // The grid only needs the mask to dim non-workdays; read it once from defaults.
    private var occupiedMaskHint: Int {
        let m = UserDefaults.standard.integer(forKey: SchedulingPrefs.workdaysMaskKey)
        return m == 0 ? SchedulingPrefs.defaultWorkdaysMask : m
    }

    private func shift(_ months: Int) {
        if let d = calendar.date(byAdding: .month, value: months, to: monthStart) { month = d }
    }

    /// Day cells for the displayed month: leading blanks (nil) then each day, aligned to firstWeekday.
    private func monthCells() -> [Date?] {
        CalendarGrid.monthCells(monthStart: monthStart, calendar: calendar)
    }

    private func orderedShortWeekdaySymbols() -> [String] {
        CalendarGrid.orderedShortWeekdaySymbols(calendar: calendar)
    }
}

// MARK: - Gaps list

/// The "View gaps" list — pushed (not a sheet) from the Calendar banner. Each open stretch is tappable
/// and pre-fills a new from-scratch job to that date range. Schedule-aware (skips holidays/vacation).
struct GapsList: View /* internal for render-coverage tests */ {
    @Environment(\.colorScheme) private var colorScheme
    let jobs: [ScheduledJob]
    let schedule: WorkSchedule
    @State private var prefill: GapPrefill?

    private var gaps: [ScheduleGap] { SchedulingEngine.gaps(jobs, schedule: schedule) }

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                if gaps.isEmpty {
                    ContentUnavailableView("No gaps in the next 90 days",
                                           systemImage: "calendar",
                                           description: Text("Open stretches before your booked jobs will show up here."))
                        .padding(.top, 40)
                } else {
                    Text("Tap an opening to schedule a job in it.")
                        .font(.footnote).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    ForEach(gaps) { gap in
                        Button {
                            prefill = GapPrefill(start: gap.start, days: gap.workdays)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(rangeText(gap)).font(.subheadline.weight(.medium))
                                    Text("\(gap.workdays) open \(gap.workdays == 1 ? "workday" : "workdays")")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "plus.circle.fill")
                                    .foregroundStyle(GLColor.gold.render(in: colorScheme))
                            }
                            .padding()
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .glCardBackground()
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding()
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
        }
        .containerBackground(for: .navigation) { PrimaryBackground() }
        .navigationTitle("Open Gaps")
        .toolbarTitleDisplayMode(.inline)
        .sheet(item: $prefill) { prefill in
            JobFormScreen(prefillStart: prefill.start, prefillDays: prefill.days).glAppearance(colorScheme)
        }
    }

    private func rangeText(_ gap: ScheduleGap) -> String {
        if Calendar.current.isDate(gap.start, inSameDayAs: gap.end) {
            return gap.start.formatted(date: .abbreviated, time: .omitted)
        }
        return "\(gap.start.formatted(date: .abbreviated, time: .omitted)) – \(gap.end.formatted(date: .abbreviated, time: .omitted))"
    }
}

private struct GapPrefill: Identifiable {
    let id = UUID()
    let start: Date
    let days: Int
}

// MARK: - Source picker (accepted estimates + invoices, not already scheduled)

struct ScheduleSourcePicker: View /* internal for render-coverage tests */ {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @Query(sort: \Estimate.createdAt, order: .reverse) private var estimates: [Estimate]
    @Query(sort: \Invoice.createdAt, order: .reverse) private var invoices: [Invoice]
    let onPick: (ScheduleJobSource) -> Void

    private var schedulableEstimates: [Estimate] {
        estimates.filter { $0.status == .accepted && ($0.scheduledJobs?.isEmpty ?? true) }
    }
    private var schedulableInvoices: [Invoice] {
        invoices.filter { $0.scheduledJobs?.isEmpty ?? true }
    }

    var body: some View {
        NavigationStack {
            List {
                if schedulableEstimates.isEmpty && schedulableInvoices.isEmpty {
                    ContentUnavailableView("Nothing to schedule yet", systemImage: "calendar.badge.plus",
                                           description: Text("Accept an estimate or create an invoice, then schedule it here."))
                }
                if !schedulableEstimates.isEmpty {
                    Section("Accepted estimates") {
                        ForEach(schedulableEstimates) { estimate in
                            Button { onPick(.estimate(estimate)) } label: {
                                row(title: estimate.jobTitle.isEmpty ? estimate.number : estimate.jobTitle,
                                    subtitle: ScheduleJobSource.estimate(estimate).customerName)
                            }
                        }
                    }
                }
                if !schedulableInvoices.isEmpty {
                    Section("Invoices") {
                        ForEach(schedulableInvoices) { invoice in
                            Button { onPick(.invoice(invoice)) } label: {
                                row(title: invoice.jobTitle.isEmpty ? invoice.number : invoice.jobTitle,
                                    subtitle: invoice.customerDisplayName)
                            }
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background { GLColor.backgroundPrimary.render(in: colorScheme).ignoresSafeArea() }
            .navigationTitle("Schedule From")
            .toolbarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarLeading) { Button(role: .close) { dismiss() } } }
        }
    }

    private func row(title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.isEmpty ? "Job" : title)
            if !subtitle.isEmpty { Text(subtitle).font(.caption).foregroundStyle(.secondary) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

#Preview {
    CalendarScreen()
        .modelContainer(for: ScheduledJob.self, inMemory: true)
}
