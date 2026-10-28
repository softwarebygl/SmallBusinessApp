//
//  CalendarScreen.swift
//  GLSmallBusiness
//
//  Created by Gold Life LLC on 6/21/26.
//
//  The Calendar: a "Next available date" banner + "See openings", a month grid with booked days
//  marked, and an agenda of upcoming jobs. The + adds a job from scratch (JobFormScreen) or from
//  an accepted estimate / invoice (ScheduleSourcePicker → ScheduleJobSheet). Since the Jobs-tab
//  rework (2026-08-21) this screen is PUSHED from the Jobs root on iPhone (toolbar calendar
//  button) and fills the iPad split's DETAIL pane by default — it is no longer a tab root.
//

import SwiftUI
import GoldLifeUI
import SwiftData

struct CalendarScreen: View {
    var showsMenuButton: Bool = true
    /// Whether this screen wraps its own NavigationStack. nil follows showsMenuButton
    /// (the legacy coupling, kept so old call sites and tests behave unchanged).
    var ownsStack: Bool? = nil
    /// PrimaryBackground (brand monogram) vs the plain column background. nil follows
    /// showsMenuButton, same legacy coupling.
    var primaryBackground: Bool? = nil
    private var resolvedOwnsStack: Bool { ownsStack ?? showsMenuButton }
    private var resolvedPrimaryBackground: Bool { primaryBackground ?? showsMenuButton }

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.modelContext) private var modelContext
    @Environment(SubscriptionManager.self) private var subscription
    @AppStorage(SchedulingPrefs.workdaysMaskKey) private var workdaysMask = SchedulingPrefs.defaultWorkdaysMask
    @Query(sort: \ScheduledJob.startDate) private var jobs: [ScheduledJob]
    @Query private var profiles: [BusinessProfile]

    @State private var showingMenu = false
    @State private var pickingSource = false
    @State private var pendingSource: SourceBox?
    @State private var showingNewJob = false
    @State private var showingPaywall = false
    /// Set when a lapsed subscription refuses a write — the alert names it (ReadOnlyGate.swift).
    @State private var readOnlyRefusal: MBWriteOperation?
    @State private var bannerPrefill: GapPrefill?
    // Day-details half sheet (owner feature, 2026-08-21): tap any day for its jobs,
    // or a one-tap "Book this day" on a free one. Actions are applied in the sheet's
    // onDismiss so the push never races the dismissal animation.
    @State private var daySelection: DaySelection?
    @State private var pendingDayJob: ScheduledJob?
    @State private var pendingBookDay: Date?
    @State private var dayJob: ScheduledJob?
    /// The expanded jobs, kept until the jobs change (QA F90: every read used to re-expand).
    @State private var expansionCache = ScheduleExpansionCache()

    private var gold: Color { GLTheme.accentFill }
    /// Workdays still come from the existing @AppStorage mask; holidays / vacation / overrides come from
    /// the stored work schedule (defaults to common-holidays-on until the editor lands in Slice C).
    private var schedule: WorkSchedule {
        effectiveWorkSchedule(profiles.first, legacyMask: workdaysMask)
    }
    // The calendar's answers come from ScheduleQueries (the same functions the assistant reads);
    // SchedulingEngine stays the engine underneath.
    /// Horizon over which recurring jobs are materialized into occurrences for the grid / agenda /
    /// availability (a month back, a year forward).
    private var horizon: DateInterval { ScheduleQueries.horizon() }
    /// What the calendar actually shows — recurring series expanded into concrete occurrences.
    /// Expanded once per change to the jobs, not once per read.
    private var expandedJobs: [ScheduledJob] { expansionCache.expanded(jobs, in: horizon) }
    private var hasOpenEndedRecurrence: Bool { ScheduleQueries.hasOpenEndedRecurrence(jobs) }
    /// Every day each job occupies → the jobs on it (drives the grid's initials tags
    /// and the day-details sheet). Schedule-aware, same day math as the gold fills.
    private var jobsByDay: [Date: [ScheduledJob]] { ScheduleQueries.jobsByDay(expandedJobs, schedule: schedule) }

    /// Row 1 — the soonest bounded opening between booked jobs (nil when nothing is booked ahead).
    private var firstOpening: Opening? { ScheduleQueries.openings(expandedJobs, schedule: schedule).first }
    /// Row 2 — the first open workday after your last booked job (the open-ended runway).
    private var clearDate: Date { ScheduleQueries.clearDate(expandedJobs, schedule: schedule) }
    private var upcoming: [ScheduledJob] { ScheduleQueries.upcoming(expandedJobs, schedule: schedule) }

    var body: some View {
        if resolvedOwnsStack {
            NavigationStack { content.glMinimalBackButtons() }
        } else {
            content
        }
    }

    /// Start a job from scratch, or show the paywall if a free user is at the job cap.
    private func newJobFromScratch() {
        if attemptJob() { showingNewJob = true }
    }

    /// Schedule a job from an estimate / invoice, or show the paywall if a free user is at the job cap.
    private func newJobFromSource() {
        if AccessGate.attemptCreate(ScheduledJob.self, cap: FreeTier.jobs, in: modelContext,
                                    subscription: subscription, operation: .scheduleJob,
                                    paywall: $showingPaywall, refusal: $readOnlyRefusal) {
            pickingSource = true
        }
    }

    /// One call, one outcome: at the free cap it opens the paywall, lapsed it refuses out loud.
    /// The old `if canAddJob() { … } else { showingPaywall = true }` shape would have shown a
    /// lapsed subscriber BOTH.
    private func attemptJob() -> Bool {
        AccessGate.attemptCreate(ScheduledJob.self, cap: FreeTier.jobs, in: modelContext,
                                 subscription: subscription, operation: .saveJob,
                                 paywall: $showingPaywall, refusal: $readOnlyRefusal)
    }

    @ViewBuilder
    private var content: some View {
        let byDay = jobsByDay
        ScrollView {
            VStack(spacing: 18) {
                banner
                MonthGrid(jobsByDay: byDay, gold: gold) { day in
                    daySelection = DaySelection(date: day, jobs: byDay[day] ?? [])
                }
                agenda
            }
            .padding(.horizontal, GLLayout.rowCardInset)
            .padding(.vertical)
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
        }
        .contentMargins(.top, GLScript.titleClearance(for: GLScript.padded(mbLoc("Calendar"))), for: .scrollContent)   // breathing room below the large title's descenders
        .mbSystemBanners(capsContent: false)
        .readOnlyRefusalAlert($readOnlyRefusal)
        .containerBackground(for: .navigation) {
            resolvedPrimaryBackground ? AnyView(PrimaryBackground())
                                      : AnyView(GLTheme.background.ignoresSafeArea())
        }
        .navigationTitle(GLScript.padded(mbLoc("Calendar")))
        .toolbar {
            if showsMenuButton {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showingMenu = true } label: { MenuButtonLabel() }.accessibilityLabel("Menu")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { newJobFromScratch() } label: { Label("New job", systemImage: "hammer") }
                    Button { newJobFromSource() } label: {
                        Label("From an estimate or invoice", systemImage: "doc.text")
                    }
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Add a job")
            }
            // Work schedule reached ONLY from Settings before this. Every question it
            // answers — which days do I work, when am I next free, I'm off Friday —
            // gets asked while looking at the calendar, not while in Settings.
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink {
                    WorkScheduleScreen()
                } label: {
                    Image(systemName: "calendar.badge.clock")
                }
                .accessibilityLabel("Work schedule")
            }
        }
        .sheet(isPresented: $showingMenu) { MenuScreen().glAppearance(colorScheme) }
        .paywallSheet(isPresented: $showingPaywall)
        .navigationDestination(isPresented: $showingNewJob) { JobFormScreen() }
        .navigationDestination(item: $bannerPrefill) { prefill in
            JobFormScreen(prefillStart: prefill.start, prefillDays: prefill.days, prefillWindow: prefill.window)
        }
        .navigationDestination(item: $dayJob) { job in
            JobDetailScreen(job: job)
        }
        .sheet(item: $daySelection, onDismiss: {
            if let job = pendingDayJob {
                pendingDayJob = nil
                dayJob = job
            } else if let day = pendingBookDay {
                pendingBookDay = nil
                if attemptJob() { bannerPrefill = GapPrefill(start: day) }
            }
        }) { selection in
            DayDetailsSheet(selection: selection,
                            mask: workdaysMask,
                            // A repeating job's row is an occurrence copy: open the stored series.
                            onOpenJob: {
                                pendingDayJob = ScheduleQueries.storedJob(for: $0, among: jobs)
                                daySelection = nil
                            },
                            onBook: { pendingBookDay = selection.date; daySelection = nil })
                .glAppearance(colorScheme)
        }
        .sheet(isPresented: $pickingSource) {
            ScheduleSourcePicker { source in
                pickingSource = false
                pendingSource = SourceBox(source: source)
            }
            .glAppearance(colorScheme)
        }
        .navigationDestination(item: $pendingSource) { box in
            ScheduleJobSheet(source: box.source)
        }
    }

    // MARK: - Banner

    private var banner: some View {
        let firstOpening = firstOpening
        let clearDate = clearDate
        return MBTitledCard {
            VStack(alignment: .leading, spacing: 14) {
                if let opening = firstOpening {
                    // Gated like the toolbar +: over the free job cap, show the paywall instead of the form.
                    Button {
                        if attemptJob() { bannerPrefill = GapPrefill(opening: opening) }
                    } label: {
                        bannerRow(eyebrow: "NEXT AVAILABLE DATE",
                                  value: opening.start.formatted(.dateTime.weekday(.wide).month().day()
                                    .locale(MBLocalization.currentLocale)),
                                  detail: opening.capacityText)
                    }
                    .buttonStyle(.plain)
                    Divider()
                }
                HStack(spacing: 10) {
                    Button {
                        if attemptJob() { bannerPrefill = GapPrefill(start: clearDate) }
                    } label: {
                        bannerRow(eyebrow: "NEXT CLEAR DATE",
                                  value: hasOpenEndedRecurrence
                                    ? mbLoc("Ongoing — recurring work")
                                    : clearDate.formatted(.dateTime.weekday(.wide).month().day()
                                        .locale(MBLocalization.currentLocale)),
                                  detail: hasOpenEndedRecurrence
                                    ? mbLoc("You have a recurring series with no end date")
                                    : (firstOpening == nil ? nil : mbLoc("Open-ended — nothing booked after")),
                                  showsAddIcon: false)
                    }
                    .buttonStyle(.plain)
                    NavigationLink {
                        GapsList(jobs: expandedJobs, schedule: schedule)
                    } label: {
                        Text("See openings")
                            .font(.subheadline.weight(.semibold)).foregroundStyle(GLTheme.accentText)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func bannerRow(eyebrow: LocalizedStringKey, value: String, detail: String?, showsAddIcon: Bool = true) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(eyebrow)
                    .font(.caption2.weight(.semibold)).tracking(0.5).foregroundStyle(GLTheme.textSecondary)
                Text(value)
                    .font(.title3.weight(.semibold)).foregroundStyle(GLTheme.accentText)
                if let detail {
                    Text(detail).font(.caption).foregroundStyle(GLTheme.textSecondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if showsAddIcon {
                // Signals the row pushes a new job pre-filled to this date.
                Image(systemName: "plus.circle")
                    .font(.title3).foregroundStyle(gold)
            }
        }
        .contentShape(.rect)
    }

    // MARK: - Agenda

    private var agenda: some View {
        let upcoming = upcoming
        let lastID = upcoming.last?.id
        return MBTitledCard(title: "Upcoming") {
            if upcoming.isEmpty {
                Text("No jobs scheduled yet. Tap + to add one.")
                    .font(.subheadline).foregroundStyle(GLTheme.textSecondary)
            } else {
                ForEach(upcoming) { job in
                    jobRow(job)
                    if job.id != lastID { Divider() }
                }
            }
        }
    }

    private func jobRow(_ job: ScheduledJob) -> some View {
        let style = Date.FormatStyle(date: .abbreviated, time: .omitted).locale(MBLocalization.currentLocale)
        let start = job.startDate
        let end = job.endDay(schedule: schedule)
        let range = !job.isAllDay && !job.timeText.isEmpty
            ? "\(start.formatted(style)) · \(job.timeText)"
            : (Calendar.current.isDate(start, inSameDayAs: end)
               ? start.formatted(style)
               : "\(start.formatted(style)) – \(end.formatted(style))")
        return VStack(alignment: .leading, spacing: 2) {
            Text(job.displayTitle).font(.subheadline.weight(.medium))
            HStack {
                if !job.displayCustomerName.isEmpty {
                    Text(job.displayCustomerName).font(.caption).foregroundStyle(GLTheme.textSecondary)
                }
                Spacer()
                Text(range).font(.caption).foregroundStyle(GLTheme.textSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Identifiable + Hashable wrapper so the source can drive a `.navigationDestination(item:)`.
// File-internal → shared: the Jobs tab root (AllJobsScreen) hosts the same booking flow.
struct SourceBox: Identifiable, Hashable {
    let id = UUID()
    let source: ScheduleJobSource

    static func == (l: Self, r: Self) -> Bool { l.id == r.id }
    func hash(into h: inout Hasher) { h.combine(id) }
}

// MARK: - Month grid

private struct MonthGrid: View {
    @Environment(\.colorScheme) private var colorScheme
    let jobsByDay: [Date: [ScheduledJob]]
    let gold: Color
    let onDayTap: (Date) -> Void
    @State private var month: Date = Calendar.current.startOfDay(for: .now)

    private let calendar = Calendar.current
    private var monthStart: Date {
        calendar.date(from: calendar.dateComponents([.year, .month], from: month)) ?? month
    }

    var body: some View {
        MBTitledCard {
            header
            weekdayHeader
            grid
        }
    }

    private var header: some View {
        HStack {
            Button { shift(-1) } label: {
                Image(systemName: "chevron.left")
                    .frame(minWidth: 44, minHeight: 44)   // ≥44pt tap target; the glyph stays the same
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Previous month")
            Spacer()
            Text(monthStart.formatted(.dateTime.month(.wide).year().locale(MBLocalization.currentLocale)))
                .font(.headline)
                .foregroundStyle(GLTheme.accentText)
            Spacer()
            Button { shift(1) } label: {
                Image(systemName: "chevron.right")
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Next month")
        }
        .foregroundStyle(gold)
    }

    private var weekdayHeader: some View {
        let symbols = orderedShortWeekdaySymbols()
        return HStack(spacing: 0) {
            ForEach(Array(symbols.enumerated()), id: \.offset) { _, s in
                Text(s).font(.caption2.weight(.semibold)).foregroundStyle(GLTheme.textSecondary)
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
        let key = calendar.startOfDay(for: day)
        let dayJobs = jobsByDay[key] ?? []
        let isOccupied = !dayJobs.isEmpty
        let isToday = calendar.isDateInToday(day)
        let isWorkday = SchedulingPrefs.isWorkday(day, mask: occupiedMaskHint)
        return Button { onDayTap(key) } label: {
            VStack(spacing: 1) {
                Text("\(calendar.component(.day, from: day))")
                    .font(.subheadline)
                    .frame(maxWidth: .infinity, minHeight: 34)
                    .background(Circle().fill(isOccupied ? gold : Color.clear).frame(width: 32, height: 32))
                    .foregroundStyle(isOccupied ? GLTheme.onAccent : (isWorkday ? GLTheme.textPrimary : GLTheme.textSecondary))
                    .overlay {
                        if isToday && !isOccupied {
                            Circle().stroke(gold, lineWidth: 1.5).frame(width: 32, height: 32)
                        }
                    }
                // Who's on this day, at a glance (owner pick): the first job's customer
                // initials — "DC" for Danielle Carter — plus "+N" when double-booked.
                // A fixed-height slot on EVERY cell keeps the week rows aligned.
                Text(initialsTag(dayJobs) ?? " ")
                    .font(.system(size: 8.5, weight: .semibold))
                    .foregroundStyle(isOccupied ? GLTheme.accentText : Color.clear)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .frame(height: 10)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // The gold fill + initials are the visual signals; VoiceOver gets the full story.
        .accessibilityLabel(isToday
            ? Text("\(day.formatted(.dateTime.weekday(.wide).month(.wide).day().locale(MBLocalization.currentLocale))), Today")
            : Text(day.formatted(.dateTime.weekday(.wide).month(.wide).day().locale(MBLocalization.currentLocale))))
        .accessibilityValue(isOccupied
            ? "Booked: \(dayJobs.map { $0.displayCustomerName.isEmpty ? $0.displayTitle : $0.displayCustomerName }.joined(separator: ", "))"
            : "Available")
        .accessibilityHint("Shows this day’s details")
    }

    /// "DC" from "Danielle Carter" (or "Carter, Danielle" — list order flips to
    /// first-last), the job title's initial when there's no customer, "+N" appended
    /// when more than one job shares the day.
    private func initialsTag(_ dayJobs: [ScheduledJob]) -> String? {
        guard let first = dayJobs.first else { return nil }
        let source = first.displayCustomerName.isEmpty ? first.displayTitle : first.displayCustomerName
        let ordered: [Substring]
        if source.contains(",") {
            ordered = source.split(separator: ",").reversed().flatMap { $0.split(separator: " ") }
        } else {
            ordered = source.split(separator: " ")
        }
        let letters = ordered.compactMap { $0.first(where: \.isLetter).map(String.init) }
        let initials = letters.prefix(2).joined().uppercased()
        let base = initials.isEmpty ? "•" : initials
        return dayJobs.count > 1 ? "\(base) +\(dayJobs.count - 1)" : base
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
        // Symbols in the app's chosen language; the locale copy leaves the day math untouched.
        var localized = calendar
        localized.locale = MBLocalization.currentLocale
        return CalendarGrid.orderedShortWeekdaySymbols(calendar: localized)
    }
}

// MARK: - Gaps list

/// The "See openings" list — pushed (not a sheet) from the Calendar banner. Each open stretch is tappable
/// and pre-fills a new from-scratch job to that date range. Schedule-aware (skips holidays/vacation).
struct GapsList: View /* internal for render-coverage tests */ {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.modelContext) private var modelContext
    @Environment(SubscriptionManager.self) private var subscription
    let jobs: [ScheduledJob]
    let schedule: WorkSchedule
    @State private var prefill: GapPrefill?
    @State private var showingPaywall = false
    /// Set when a lapsed subscription refuses a write — the alert names it (ReadOnlyGate.swift).
    @State private var readOnlyRefusal: MBWriteOperation?

    private var openings: [Opening] { ScheduleQueries.openings(jobs, schedule: schedule) }

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                if openings.isEmpty {
                    ContentUnavailableView("No gaps in the next 90 days",
                                           systemImage: "calendar",
                                           description: Text("Openings before your booked jobs will show up here."))
                        .padding(.top, 40)
                } else {
                    Text("Tap an opening to schedule a job in it.")
                        .font(.footnote).foregroundStyle(GLTheme.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    ForEach(openings) { opening in
                        Button {
                            // Same free-tier job cap as the toolbar +: over the cap, paywall instead of the form.
                            if AccessGate.attemptCreate(ScheduledJob.self, cap: FreeTier.jobs,
                                                        in: modelContext, subscription: subscription,
                                                        operation: .scheduleJob,
                                                        paywall: $showingPaywall,
                                                        refusal: $readOnlyRefusal) {
                                prefill = GapPrefill(opening: opening)
                            }
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(rangeText(opening)).font(.subheadline.weight(.medium))
                                    Text(opening.window != nil ? opening.capacityText : opening.openWorkdaysText)
                                        .font(.caption).foregroundStyle(GLTheme.textSecondary)
                                }
                                Spacer()
                                Image(systemName: opening.window != nil ? "clock.badge.checkmark" : "plus.circle.fill")
                                    .foregroundStyle(GLTheme.accentFill)
                            }
                            .padding(GLLayout.rowContentPadding)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .glCardBackground()
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal, GLLayout.rowCardInset)
            .padding(.vertical)
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
        }
        .mbSystemBanners(capsContent: false)
        .readOnlyRefusalAlert($readOnlyRefusal)
        .containerBackground(for: .navigation) { PrimaryBackground() }
        .navigationTitle(GLScript.padded(mbLoc("Openings")))
        .toolbarTitleDisplayMode(.large)
        .contentMargins(.top, GLScript.titleClearance(for: GLScript.padded(mbLoc("Openings"))), for: .scrollContent)
        .paywallSheet(isPresented: $showingPaywall)
        .navigationDestination(item: $prefill) { prefill in
            JobFormScreen(prefillStart: prefill.start, prefillDays: prefill.days, prefillWindow: prefill.window)
        }
    }

    private func rangeText(_ opening: Opening) -> String {
        if let window = opening.window {
            let day = window.start.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()
                .locale(MBLocalization.currentLocale))
            let timeStyle = Date.FormatStyle(date: .omitted, time: .shortened).locale(MBLocalization.currentLocale)
            let from = window.start.formatted(timeStyle)
            let to = window.end.formatted(timeStyle)
            return "\(day) · \(from) – \(to)"
        }
        let style = Date.FormatStyle(date: .abbreviated, time: .omitted).locale(MBLocalization.currentLocale)
        if Calendar.current.isDate(opening.start, inSameDayAs: opening.end) {
            return opening.start.formatted(style)
        }
        return "\(opening.start.formatted(style)) – \(opening.end.formatted(style))"
    }
}

private struct GapPrefill: Identifiable, Hashable {
    let id = UUID()
    let start: Date
    let days: Int
    let window: DateInterval?

    init(opening: Opening) {
        start = opening.start
        days = opening.workdays
        window = opening.window
    }

    /// A bare start date (the "next clear date" row) — one open-ended day, no time window.
    init(start: Date) {
        self.start = start
        days = 1
        window = nil
    }
}

// MARK: - Day details half sheet

/// The tapped day, driving the half sheet. Identified by the day itself.
private struct DaySelection: Identifiable {
    var id: Date { date }
    let date: Date
    let jobs: [ScheduledJob]
}

/// One day at a glance (owner feature, 2026-08-21): the jobs booked on it — each
/// row jumps to the job — or, on a free day, a single gold "Book this day" that
/// opens the job form pre-filled to that date. Sized to CONTENT (the measured-
/// height recipe from the Gold Life ID card): Dynamic Type grows the sheet
/// instead of clipping it; .large stays available as the overflow.
private struct DayDetailsSheet: View {
    let selection: DaySelection
    let mask: Int
    let onOpenJob: (ScheduledJob) -> Void
    let onBook: () -> Void

    @State private var contentHeight: CGFloat = 0
    private var gold: Color { GLTheme.accentFill }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // The title, empty text and button take the row-card gutter; JobRow below
                // carries its own (law 55: the token, never a hard-coded inset — QA F54).
                Text(selection.date.formatted(.dateTime.weekday(.wide).month(.wide).day()
                    .locale(MBLocalization.currentLocale)))
                    .font(.title3.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                    .padding(.horizontal, GLLayout.rowCardInset)

                if selection.jobs.isEmpty {
                    Text("Nothing booked")
                        .foregroundStyle(GLTheme.textSecondary)
                        .padding(.horizontal, GLLayout.rowCardInset)
                    Button {
                        onBook()
                    } label: {
                        Text("Book this day")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(gold)
                    .padding(.horizontal, GLLayout.rowCardInset)
                } else {
                    // JobRow already carries the card look and its own chevron —
                    // plain stacked rows, no second wrapper.
                    VStack(spacing: 10) {
                        ForEach(selection.jobs, id: \.persistentModelID) { job in
                            Button { onOpenJob(job) } label: {
                                JobRow(job: job, mask: mask, showsCustomer: true)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(.top, 26)
            .padding(.bottom, 20)
        }
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.height
        } action: { height in
            contentHeight = height
        }
        .presentationDetents(contentHeight > 0 ? [.height(contentHeight), .large]
                                               : [.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationBackground(GLTheme.background)
    }
}

// MARK: - Source picker (accepted estimates + invoices, not already scheduled)

struct ScheduleSourcePicker: View /* internal for render-coverage tests */ {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @Query(sort: \Estimate.createdAt, order: .reverse) private var estimates: [Estimate]
    @Query(sort: \Invoice.createdAt, order: .reverse) private var invoices: [Invoice]
    let onPick: (ScheduleJobSource) -> Void

    private var schedulableEstimates: [Estimate] {
        estimates.filter { $0.status == .accepted && $0.liveRows($0.scheduledJobs).isEmpty }
    }
    private var schedulableInvoices: [Invoice] {
        invoices.filter { $0.liveRows($0.scheduledJobs).isEmpty }
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
            // Same pre-D6 defect the Menu had: a bare List keeps UIKit's ~20pt
            // inset-grouped margin. The shared skin brings the 8pt gutter.
            .glFormBackground()
            .navigationTitle(GLScript.padded(mbLoc("Schedule From")))
            .toolbarTitleDisplayMode(.large)
            .contentMargins(.top, GLScript.titleClearance(for: GLScript.padded(mbLoc("Schedule From"))), for: .scrollContent)
            .toolbar { ToolbarItem(placement: .topBarLeading) { Button(role: .close) { dismiss() } } }
        }
    }

    private func row(title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.isEmpty ? mbLoc("Job") : title)
            if !subtitle.isEmpty { Text(subtitle).font(.caption).foregroundStyle(GLTheme.textSecondary) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

#Preview {
    CalendarScreen()
        .modelContainer(for: ScheduledJob.self, inMemory: true)
}
