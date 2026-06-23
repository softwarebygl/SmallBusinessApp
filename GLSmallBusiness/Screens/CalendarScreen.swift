//
//  CalendarScreen.swift
//  GLSmallBusiness
//
//  Created by Gold Life LLC on 6/21/26.
//
//  The Calendar tab: a "Next available date" banner + "View gaps", a month grid with booked days
//  marked, and an agenda of upcoming jobs. Scheduling starts from an accepted estimate or an invoice
//  (the + picks the source, then ScheduleJobSheet). iPhone wraps its own NavigationStack; the iPad
//  split passes `showsMenuButton: false` and lives inside the content column's nav bar.
//

import SwiftUI
import SwiftData

struct CalendarScreen: View {
    var showsMenuButton: Bool = true

    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(SchedulingPrefs.workdaysMaskKey) private var workdaysMask = SchedulingPrefs.defaultWorkdaysMask
    @Query(sort: \ScheduledJob.startDate) private var jobs: [ScheduledJob]

    @State private var showingMenu = false
    @State private var showingGaps = false
    @State private var pickingSource = false
    @State private var pendingSource: SourceBox?

    private var gold: Color { GLColor.gold.render(in: colorScheme) }
    private var nextAvailable: Date { SchedulingEngine.nextAvailable(jobs, mask: workdaysMask) }
    private var upcoming: [ScheduledJob] {
        let today = Calendar.current.startOfDay(for: .now)
        return jobs.filter { $0.endDay(mask: workdaysMask) >= today }
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
                MonthGrid(occupied: SchedulingEngine.occupiedDays(jobs, mask: workdaysMask), gold: gold)
                agenda
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
                Button { pickingSource = true } label: { Image(systemName: "plus") }
                    .accessibilityLabel("Schedule a job")
            }
        }
        .sheet(isPresented: $showingMenu) { MenuScreen().glAppearance(colorScheme) }
        .sheet(isPresented: $showingGaps) {
            GapsList(jobs: jobs, mask: workdaysMask).glAppearance(colorScheme)
        }
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
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("NEXT AVAILABLE DATE")
                        .font(.caption2.weight(.semibold)).tracking(0.5).foregroundStyle(.secondary)
                    Text(nextAvailable.formatted(.dateTime.weekday(.wide).month().day()))
                        .font(.title3.weight(.semibold)).foregroundStyle(gold)
                }
                Spacer()
                Button { showingGaps = true } label: {
                    Label("View gaps", systemImage: "rectangle.split.2x1")
                        .font(.subheadline.weight(.semibold)).foregroundStyle(gold)
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Agenda

    private var agenda: some View {
        GLCard(title: "Upcoming") {
            if upcoming.isEmpty {
                Text("No jobs scheduled. Tap + to schedule an accepted estimate or an invoice.")
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
        let end = job.endDay(mask: workdaysMask)
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

private struct GapsList: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    let jobs: [ScheduledJob]
    let mask: Int

    private var gaps: [ScheduleGap] { SchedulingEngine.gaps(jobs, mask: mask) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    if gaps.isEmpty {
                        ContentUnavailableView("No gaps in the next 90 days",
                                               systemImage: "calendar",
                                               description: Text("Open stretches before your booked jobs will show up here."))
                            .padding(.top, 40)
                    } else {
                        ForEach(gaps) { gap in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(rangeText(gap)).font(.subheadline.weight(.medium))
                                    Text("\(gap.workdays) open \(gap.workdays == 1 ? "workday" : "workdays")")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                            .padding()
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .glCardBackground()
                        }
                    }
                }
                .padding()
                .frame(maxWidth: 640)
                .frame(maxWidth: .infinity)
            }
            .background { GLColor.backgroundPrimary.render(in: colorScheme).ignoresSafeArea() }
            .navigationTitle("Open Gaps")
            .toolbarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarLeading) { Button(role: .close) { dismiss() } } }
        }
    }

    private func rangeText(_ gap: ScheduleGap) -> String {
        if Calendar.current.isDate(gap.start, inSameDayAs: gap.end) {
            return gap.start.formatted(date: .abbreviated, time: .omitted)
        }
        return "\(gap.start.formatted(date: .abbreviated, time: .omitted)) – \(gap.end.formatted(date: .abbreviated, time: .omitted))"
    }
}

// MARK: - Source picker (accepted estimates + invoices, not already scheduled)

private struct ScheduleSourcePicker: View {
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
