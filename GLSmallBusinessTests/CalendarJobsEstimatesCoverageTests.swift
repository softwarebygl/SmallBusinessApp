//
//  CalendarJobsEstimatesCoverageTests.swift
//  GLSmallBusinessTests
//
//  Coverage push for the Calendar / Jobs / Estimates / Change-Order surfaces.
//
//  Two halves:
//   1. STATE VARIANTS — the branches plain "render it once" tests never reach. Every screen in this
//      area forks on data (empty vs booked, today vs future vs past, all-day vs timed, one-off vs
//      recurring, priced vs not, applied vs not, converted vs not, deleted vs live) and on the
//      environment (light vs dark, large Dynamic Type, iPad column width). Each is hosted through
//      GLTestHost (Harness/) so SwiftUI actually evaluates the body, on stores and fixtures from
//      TestStore / DemoWorld / TS — the same substrate as every other rendering suite.
//   2. EDGE CASES on the pure math those screens read: month boundaries, DST transitions, leap days,
//      end-of-month recurrence clamping, the openings / clear-date rules, change-order apply /
//      remove / decline, and the money edges on a job, an estimate and a change order. (The
//      EstimateTotals clamps live with the rest of the money math; numbering in
//      DocumentNumberingTests.) Date math runs on the harness calendar (`TS.calendar`:
//      America/New_York, firstWeekday = Sunday) so a DST or month-boundary assertion means the same
//      thing on every machine.
//
//  A handful of tests document CURRENT behavior that is arguably wrong; each is marked DEFECT with
//  what it does today, so a future fix breaks the test on purpose instead of silently.
//

import Testing
import SwiftUI
import SwiftData
import UIKit
@testable import GLSmallBusiness

@MainActor
@Suite(.serialized)
struct CalendarJobsEstimatesCoverageTests {

    // MARK: - Pinned calendar + schedules (deterministic date math)

    /// The harness calendar (Gregorian, America/New_York, weeks start Sunday) — pinned so DST +
    /// month-boundary assertions mean the same thing regardless of the machine's locale. Dates are
    /// built with `TS.day`, and every engine call is handed this calendar explicitly.
    private let cal = TS.calendar

    /// Mon–Fri 8–5, holidays OFF — so a date assertion never depends on the holiday catalog.
    private var plainSchedule: WorkSchedule {
        var s = WorkSchedule.standard
        s.holidays = []
        return s
    }

    /// Every day a workday (8–5), used for the DST working-hours checks on a Sunday.
    private var sevenDaySchedule: WorkSchedule {
        var s = plainSchedule
        for i in 0..<7 { s.weekdayHours[i].isWorkday = true }
        return s
    }

    /// Nothing is a workday — the degenerate schedule an owner can build in the editor.
    private var noWorkdaySchedule: WorkSchedule {
        var s = plainSchedule
        for i in 0..<7 { s.weekdayHours[i].isWorkday = false }
        return s
    }

    // MARK: ─────────────────────────────────────────────────────────────────────────────────────
    // MARK: 1. CALENDAR SCREEN — state variants
    // MARK: ─────────────────────────────────────────────────────────────────────────────────────

    /// An empty calendar: no banner opening, "No jobs scheduled yet", an unmarked month grid.
    /// Both schemes, because the grid's day cells pick foreground colors per scheme.
    @Test func rendersCalendarWithNoScheduledJobs() throws {
        let container = try TestStore.makeContainer()
        GLTestHost.renderBothSchemes(CalendarScreen(), container: container)
        // The iPad content column passes showsMenuButton: false — a different body branch
        // (no NavigationStack of its own, no All Jobs row, a plain background).
        GLTestHost.render(CalendarScreen(showsMenuButton: false), container: container, size: GLTestHost.pad)
    }

    /// A job today, one in the future, one in the past. The agenda filters on
    /// `endDay >= today`, so the past job must NOT appear while the other two do — and the grid
    /// marks all three days occupied.
    @Test func rendersCalendarWithTodayFutureAndPastJobs() throws {
        let container = try TestStore.makeContainer()
        let customer = TS.customer(in: container.mainContext)
        let today = Calendar.current.startOfDay(for: .now)
        TS.job("Today — grout", start: today, customer: customer, in: container.mainContext)
        TS.job("Future — backsplash",
               start: today.addingTimeInterval(21 * 86_400), days: 4, customer: customer,
               in: container.mainContext)
        TS.job("Past — demo",
               start: today.addingTimeInterval(-30 * 86_400), days: 2,
               customer: customer, status: .completed, in: container.mainContext)
        GLTestHost.renderBothSchemes(CalendarScreen(), container: container)
    }

    /// Two all-day jobs on the SAME day — the double-booked state the overlap confirmation exists
    /// to warn about. The grid marks the day once; the agenda lists both.
    @Test func rendersCalendarWithOverlappingJobs() throws {
        let container = try TestStore.makeContainer()
        let customer = TS.customer(in: container.mainContext)
        let start = Calendar.current.startOfDay(for: .now).addingTimeInterval(7 * 86_400)
        TS.job("Kitchen tile", start: start, days: 3, customer: customer, in: container.mainContext)
        TS.job("Bathroom regrout", start: start, days: 2, customer: customer, in: container.mainContext)
        TS.job("Walk-through", start: start, hour: 13, minutes: 60, customer: customer, in: container.mainContext)
        GLTestHost.render(CalendarScreen(), container: container)
    }

    /// An open-ended recurring series flips the "Next clear date" row to
    /// "Ongoing — recurring work" and suppresses the date. A distinct banner branch.
    @Test func rendersCalendarWithOpenEndedRecurringSeries() throws {
        let container = try TestStore.makeContainer()
        let customer = TS.customer(in: container.mainContext)
        let start = Calendar.current.startOfDay(for: .now).addingTimeInterval(2 * 86_400)
        let weekly = TS.job("Recurring cleaning", start: start,
                            hour: 13, minutes: 120, customer: customer, in: container.mainContext)
        weekly.recurrenceFrequency = .weekly
        #expect(weekly.isOpenEndedRecurrence)
        GLTestHost.renderBothSchemes(CalendarScreen(), container: container)
    }

    /// A bounded series (ends after N visits) is NOT open-ended, so the banner shows a real
    /// clear date computed from the last materialized occurrence.
    @Test func rendersCalendarWithBoundedRecurringSeries() throws {
        let container = try TestStore.makeContainer()
        let customer = TS.customer(in: container.mainContext)
        let start = Calendar.current.startOfDay(for: .now).addingTimeInterval(3 * 86_400)
        let weekly = TS.job("Weekly maintenance", start: start, customer: customer, in: container.mainContext)
        weekly.recurrenceFrequency = .weekly
        weekly.recurrenceCount = 6
        #expect(!weekly.isOpenEndedRecurrence)
        GLTestHost.render(CalendarScreen(), container: container)
    }

    /// The agenda caps at 12 upcoming jobs — seed 20 so the prefix actually truncates.
    @Test func rendersCalendarAgendaCappedAtTwelveUpcoming() throws {
        let container = try TestStore.makeContainer()
        let customer = TS.customer(in: container.mainContext)
        let base = Calendar.current.startOfDay(for: .now)
        for offset in 1...20 {
            TS.job("Job \(offset)",
                   start: base.addingTimeInterval(Double(offset) * 2 * 86_400), customer: customer,
                   in: container.mainContext)
        }
        GLTestHost.render(CalendarScreen(), container: container)
    }

    /// Accessibility sizing: the banner, the 7-column month grid, and the agenda rows all reflow.
    /// This is where a fixed-height cell or a truncating HStack shows up.
    @Test func rendersCalendarAtAccessibilityTypeSize() throws {
        let container = try TestStore.demoWorld().container
        GLTestHost.render(CalendarScreen(), container: container, scheme: .dark, typeSize: .accessibility3)
        GLTestHost.render(CalendarScreen(), container: container, scheme: .light, typeSize: .accessibility5)
    }

    /// The seeded calendar (a booked run, a completed job, a timed weekly series) in both schemes.
    @Test func rendersSeededCalendarInBothSchemes() throws {
        let container = try TestStore.demoWorld().container
        GLTestHost.renderBothSchemes(CalendarScreen(), container: container)
        GLTestHost.render(CalendarScreen(showsMenuButton: false), container: container, size: GLTestHost.pad)
    }

    // MARK: - Gaps list

    /// No jobs → no bounded openings → the ContentUnavailableView branch.
    @Test func rendersGapsListEmptyState() throws {
        let container = try TestStore.makeContainer()
        GLTestHost.renderBothSchemes(GapsList(jobs: [], schedule: .standard), container: container)
    }

    /// A booked job ahead closes a run of free workdays → a `.fullDays` opening row
    /// ("Fits N workdays" + the plus.circle.fill icon).
    @Test func rendersGapsListWithFullDayOpenings() throws {
        let container = try TestStore.makeContainer()
        let customer = TS.customer(in: container.mainContext)
        let base = Calendar.current.startOfDay(for: .now)
        let a = TS.job("Near job", start: base.addingTimeInterval(10 * 86_400),
                       days: 2, customer: customer, in: container.mainContext)
        let b = TS.job("Far job", start: base.addingTimeInterval(30 * 86_400),
                       days: 3, customer: customer, in: container.mainContext)
        GLTestHost.render(GapsList(jobs: [a, b], schedule: .standard), container: container)
    }

    /// Timed jobs leave intra-day windows → the `.window` opening row
    /// ("N hr free" + the clock.badge.checkmark icon), a different label AND icon branch.
    @Test func rendersGapsListWithIntradayWindows() throws {
        let container = try TestStore.makeContainer()
        let customer = TS.customer(in: container.mainContext)
        let base = Calendar.current.startOfDay(for: .now).addingTimeInterval(3 * 86_400)
        let morning = TS.job("Morning clean", start: base, hour: 9, minutes: 90,
                             customer: customer, in: container.mainContext)
        let afternoon = TS.job("Afternoon clean", start: base, hour: 14, minutes: 60,
                               customer: customer, in: container.mainContext)
        let closer = TS.job("Closer", start: base.addingTimeInterval(9 * 86_400),
                            days: 1, customer: customer, in: container.mainContext)
        GLTestHost.render(GapsList(jobs: [morning, afternoon, closer], schedule: .standard), container: container)
        GLTestHost.render(GapsList(jobs: [morning, afternoon, closer], schedule: .standard), container: container,
                          typeSize: .accessibility3)
    }

    // MARK: - Schedule source picker

    /// Nothing accepted and no invoices → "Nothing to schedule yet".
    @Test func rendersSourcePickerEmptyState() throws {
        let container = try TestStore.makeContainer()
        GLTestHost.renderBothSchemes(ScheduleSourcePicker { _ in }, container: container)
    }

    /// Only ACCEPTED, not-yet-scheduled estimates show. A draft, a declined, and an already
    /// scheduled accepted estimate must all be filtered out — so seeding one of each proves the
    /// section header renders for exactly the one that qualifies.
    @Test func rendersSourcePickerFiltersEstimatesByStatusAndScheduling() throws {
        let container = try TestStore.makeContainer()
        let customer = TS.customer(in: container.mainContext)
        let ctx = container.mainContext

        let accepted = Estimate(number: "EST-0001", jobTitle: "Accepted work",
                                status: .accepted, customer: customer)
        let draft = Estimate(number: "EST-0002", jobTitle: "Draft work",
                             status: .draft, customer: customer)
        let declined = Estimate(number: "EST-0003", jobTitle: "Declined work",
                                status: .declined, customer: customer)
        let alreadyScheduled = Estimate(number: "EST-0004", jobTitle: "Already booked",
                                        status: .accepted, customer: customer)
        [accepted, draft, declined, alreadyScheduled].forEach(ctx.insert)
        let booking = ScheduledJob(title: "Already booked", startDate: .now)
        booking.estimate = alreadyScheduled
        ctx.insert(booking)

        #expect(accepted.scheduledJobs?.isEmpty ?? true)
        #expect(!(alreadyScheduled.scheduledJobs?.isEmpty ?? true))
        GLTestHost.render(ScheduleSourcePicker { _ in }, container: container)
    }

    /// An estimate/invoice with a BLANK job title falls back to its number in the row; the demo
    /// store gives the populated both-sections case.
    @Test func rendersSourcePickerWithBlankTitlesAndBothSections() throws {
        let container = try TestStore.makeContainer()
        let customer = TS.customer(in: container.mainContext)
        let ctx = container.mainContext
        let untitled = Estimate(number: "EST-0009", jobTitle: "", status: .accepted, customer: customer)
        let untitledInvoice = Invoice(number: "INV-0009", jobTitle: "", customer: customer)
        [untitled].forEach(ctx.insert)
        ctx.insert(untitledInvoice)
        GLTestHost.render(ScheduleSourcePicker { _ in }, container: container)

        let demo = try TestStore.demoWorld().container
        GLTestHost.render(ScheduleSourcePicker { _ in }, container: demo)
    }

    // MARK: - Schedule job sheet

    /// Both sources, plus the blank-title / no-customer fallbacks the LabeledContent rows use.
    @Test func rendersScheduleJobSheetFromEverySource() throws {
        let world = try TestStore.demoWorld()
        let container = world.container
        let estimate = try #require(world.estimates.first)
        let invoice = try #require(world.invoices.first)
        GLTestHost.render(ScheduleJobSheet(source: .estimate(estimate)), container: container, scheme: .dark)
        GLTestHost.render(ScheduleJobSheet(source: .invoice(invoice)), container: container, scheme: .light)

        // A bare estimate — empty title AND empty customer snapshot: the "Job" fallback plus the
        // suppressed Customer row.
        let bare = Estimate(number: "EST-9999")
        container.mainContext.insert(bare)
        #expect(ScheduleJobSource.estimate(bare).title.isEmpty)
        #expect(ScheduleJobSource.estimate(bare).customerName == "Customer")
        GLTestHost.render(ScheduleJobSheet(source: .estimate(bare)), container: container)
    }

    /// The sheet with an existing booking on the same dates — the state that trips the
    /// "book one job at a time" overlap confirmation on save.
    @Test func rendersScheduleJobSheetOverAnExistingBooking() throws {
        let world = try TestStore.demoWorld()
        let container = world.container
        let invoice = try #require(world.invoices.first)
        let today = Calendar.current.startOfDay(for: .now)
        TS.job("Blocking job", start: today, days: 10, in: container.mainContext)
        GLTestHost.render(ScheduleJobSheet(source: .invoice(invoice)), container: container, typeSize: .accessibility3)
    }

    // MARK: ─────────────────────────────────────────────────────────────────────────────────────
    // MARK: 2. JOB FORM — every entry point + prefill branch
    // MARK: ─────────────────────────────────────────────────────────────────────────────────────

    /// The three inits: fixed customer (address auto-filled), from scratch (customer picker), edit.
    @Test func rendersJobFormEntryPoints() throws {
        let world = try TestStore.demoWorld()
        let container = world.container
        let customer = world.primary
        GLTestHost.renderBothSchemes(JobFormScreen(customer: customer), container: container)
        GLTestHost.render(JobFormScreen(), container: container)

        let jobs = try container.mainContext.fetch(
            FetchDescriptor<ScheduledJob>(sortBy: [SortDescriptor(\.startDate)]))
        for job in jobs { GLTestHost.render(JobFormScreen(editing: job), container: container) }
    }

    /// Gap prefills: a multi-day run (stays all-day) vs an intra-day window (flips to a TIMED job,
    /// which swaps the Stepper for the start-time picker + minute stepper).
    @Test func rendersJobFormWithGapPrefills() throws {
        let container = try TestStore.demoWorld().container
        let start = Calendar.current.startOfDay(for: .now).addingTimeInterval(5 * 86_400)
        GLTestHost.render(JobFormScreen(prefillStart: start, prefillDays: 3), container: container)
        GLTestHost.render(JobFormScreen(prefillStart: start,
                           prefillWindow: DateInterval(start: start.addingTimeInterval(9 * 3600),
                                                       duration: 3 * 3600)), container: container)
    }

    /// Degenerate prefills the gap list can genuinely hand over: a ZERO-length window (clamped to
    /// the 30-minute floor) and runs longer than the Stepper's own 1...60 / 30...600 ranges.
    /// Rendering these proves the form doesn't trap on an out-of-range Stepper value.
    @Test func rendersJobFormWithOutOfRangePrefills() throws {
        let container = try TestStore.demoWorld().container
        let start = Calendar.current.startOfDay(for: .now).addingTimeInterval(9 * 3600)
        GLTestHost.render(JobFormScreen(prefillStart: start,
                           prefillWindow: DateInterval(start: start, duration: 0)), container: container)
        GLTestHost.render(JobFormScreen(prefillStart: start,
                           prefillWindow: DateInterval(start: start, duration: 20 * 3600)), container: container)
        GLTestHost.render(JobFormScreen(prefillStart: start, prefillDays: 120), container: container)
        GLTestHost.render(JobFormScreen(prefillStart: start, prefillDays: 0), container: container)   // clamped up to 1
    }

    /// Every recurrence editor branch: none, weekly with weekday chips, monthly (chips hidden),
    /// ends-on-date, ends-after-N — plus the priced branch that reveals the currency field.
    @Test func rendersJobFormRecurrenceAndPriceBranches() throws {
        let container = try TestStore.makeContainer()
        let customer = TS.customer(in: container.mainContext)

        let weeklyOnDate = TS.job("Weekly", start: .now, customer: customer, in: container.mainContext)
        weeklyOnDate.recurrenceFrequency = .weekly
        weeklyOnDate.recurrenceWeekdayMask = (1 << 1) | (1 << 3) | (1 << 5)
        weeklyOnDate.recurrenceEndDate = Date.now.addingTimeInterval(90 * 86_400)
        GLTestHost.render(JobFormScreen(editing: weeklyOnDate), container: container)

        let biweeklyAfterN = TS.job("Biweekly", start: .now, customer: customer, in: container.mainContext)
        biweeklyAfterN.recurrenceFrequency = .biweekly
        biweeklyAfterN.recurrenceCount = 8
        GLTestHost.render(JobFormScreen(editing: biweeklyAfterN), container: container)

        let monthly = TS.job("Monthly", start: .now, customer: customer, in: container.mainContext)
        monthly.recurrenceFrequency = .monthly          // weekday chips are suppressed for monthly
        GLTestHost.render(JobFormScreen(editing: monthly), container: container)

        let priced = TS.job("Priced", start: .now, customer: customer, price: 1_250.75, in: container.mainContext)
        GLTestHost.render(JobFormScreen(editing: priced), container: container, scheme: .light)

        let timed = TS.job("Timed", start: .now, hour: 8, minutes: 210,
                           customer: customer, in: container.mainContext)
        GLTestHost.render(JobFormScreen(editing: timed), container: container, typeSize: .accessibility3)
    }

    // MARK: ─────────────────────────────────────────────────────────────────────────────────────
    // MARK: 3. JOB DETAIL — billing / attachments / source / deleted
    // MARK: ─────────────────────────────────────────────────────────────────────────────────────

    /// A job with NO customer: the billing card disables "New invoice" and shows the
    /// "Link a customer to bill this job." hint — a branch a seeded job never hits.
    @Test func rendersJobDetailWithoutACustomer() throws {
        let container = try TestStore.makeContainer()
        let job = TS.job("Verbal favor", start: .now, price: 300, in: container.mainContext)
        #expect(job.customer == nil)
        GLTestHost.renderBothSchemes(JobDetailScreen(job: job), container: container)
    }

    /// A COMPLETED job billed and collected in full → the "Paid in full" seal AND the
    /// "Completion package" action. The gate is `isFullyBilledAndCollected`.
    @Test func rendersJobDetailCompletedAndPaidInFull() throws {
        let container = try TestStore.makeContainer()
        let customer = TS.customer(in: container.mainContext)
        let ctx = container.mainContext
        let job = TS.job("Backsplash", start: Date.now.addingTimeInterval(-12 * 86_400),
                         days: 2, customer: customer, price: 1_000, status: .completed, in: ctx)
        job.completedAt = .now.addingTimeInterval(-10 * 86_400)

        let invoice = Invoice(number: "INV-0001", jobTitle: "Backsplash", status: .sent, customer: customer)
        ctx.insert(invoice)
        let group = InvoiceGroup(name: "Work", sortIndex: 0); group.invoice = invoice; ctx.insert(group)
        let line = InvoiceLineItem(name: "Backsplash", quantity: 1, unit: .job, unitPrice: 1_000,
                                   kind: .labor, isTaxable: false, sortIndex: 0)
        line.group = group; ctx.insert(line)
        let payment = InvoicePayment(amount: 1_000, date: .now, method: .check)
        payment.invoice = invoice; ctx.insert(payment)
        invoice.job = job

        #expect(close(job.contractedValue, 1_000))
        #expect(close(job.invoicedTotal, 1_000))
        #expect(job.isFullyBilledAndCollected)
        GLTestHost.renderBothSchemes(JobDetailScreen(job: job), container: container)
    }

    /// A completed job still UNDER-invoiced → the "Invoice the remaining $X…" hint instead of the
    /// package button; and a fully invoiced but UNPAID one → the "Record the outstanding $X…" hint.
    /// Two different strings from the same `else` branch.
    @Test func rendersJobDetailCompletedButNotYetCollectable() throws {
        let container = try TestStore.makeContainer()
        let customer = TS.customer(in: container.mainContext)
        let ctx = container.mainContext

        let underInvoiced = TS.job("Under-invoiced", start: .now,
                                   customer: customer, price: 2_000, status: .completed, in: ctx)
        underInvoiced.completedAt = .now
        #expect(underInvoiced.remainingToInvoice > 0.005)
        GLTestHost.render(JobDetailScreen(job: underInvoiced), container: container)

        let unpaid = TS.job("Invoiced, unpaid", start: .now,
                            customer: customer, price: 500, status: .completed, in: ctx)
        unpaid.completedAt = .now
        let invoice = Invoice(number: "INV-0002", jobTitle: "Invoiced, unpaid",
                              status: .sent, customer: customer)
        ctx.insert(invoice)
        let group = InvoiceGroup(name: "Work", sortIndex: 0); group.invoice = invoice; ctx.insert(group)
        let line = InvoiceLineItem(name: "Work", quantity: 1, unit: .job, unitPrice: 500,
                                   kind: .labor, isTaxable: false, sortIndex: 0)
        line.group = group; ctx.insert(line)
        invoice.job = unpaid
        #expect(close(unpaid.remainingToInvoice, 0))
        #expect(unpaid.balanceDue > 0.005)
        GLTestHost.render(JobDetailScreen(job: unpaid), container: container)
    }

    /// A RECURRING completed job never offers the completion package (the `!job.isRecurring` guard),
    /// and its header gains the "Repeats" row.
    @Test func rendersJobDetailForCompletedRecurringJob() throws {
        let container = try TestStore.makeContainer()
        let customer = TS.customer(in: container.mainContext)
        let job = TS.job("Standing maintenance", start: .now,
                         customer: customer, price: 200, status: .completed, in: container.mainContext)
        job.completedAt = .now
        job.recurrenceFrequency = .monthly
        job.recurrenceCount = 12
        #expect(job.isRecurring)
        #expect(!job.recurrenceSummary.isEmpty)
        GLTestHost.render(JobDetailScreen(job: job), container: container)
    }

    /// Attachments: photos grid, documents list, receipts list, a service address, notes, and a
    /// project — every optional card on the screen present at once, then each viewer screen.
    @Test func rendersJobDetailWithEveryAttachmentCard() throws {
        let container = try TestStore.makeContainer()
        let customer = TS.customer(in: container.mainContext)
        let ctx = container.mainContext
        let job = TS.job("Loaded job", start: .now, days: 2,
                         customer: customer, price: 1_200, in: ctx)
        job.serviceAddress = Address(street1: "88 Lakeshore Dr", city: "Miami",
                                     state: "FL", postalCode: "32312")
        job.notes = "Gate code 4417. Park on the street."

        let project = Project(name: "Reed kitchen remodel", customer: customer)
        ctx.insert(project)
        job.project = project

        let photo = JobAttachment(kind: .photo, name: "Finished", data: Data([0xFF, 0xD8, 0xFF]), job: job)
        let doc = JobAttachment(kind: .document, name: "City Permit.pdf",
                                data: Data([0x25, 0x50, 0x44, 0x46]), job: job)
        [photo, doc].forEach(ctx.insert)
        let receipt = Receipt(vendor: "Henderson Hardware", total: 127.43, customer: customer, job: job)
        ctx.insert(receipt)

        #expect(job.photos.count == 1)
        #expect(job.documents.count == 1)
        #expect(job.sortedReceipts.count == 1)
        GLTestHost.renderBothSchemes(JobDetailScreen(job: job), container: container)
        GLTestHost.render(JobDetailScreen(job: job), container: container, typeSize: .accessibility3)
        GLTestHost.render(JobPhotoViewer(attachment: photo), container: container)
        GLTestHost.render(JobDocumentDetailScreen(attachment: doc), container: container)
        GLTestHost.render(JobReceiptsScreen(job: job), container: container)
    }

    /// An attachment whose bytes are missing renders the "No image" fallback rather than trapping —
    /// the state a failed CloudKit asset download leaves behind.
    @Test func rendersJobPhotoViewerWithMissingData() throws {
        let container = try TestStore.makeContainer()
        let customer = TS.customer(in: container.mainContext)
        let job = TS.job("Loaded job", start: .now, customer: customer, in: container.mainContext)
        let empty = JobAttachment(kind: .photo, name: "", data: nil, job: job)
        container.mainContext.insert(empty)
        #expect(empty.data == nil)
        GLTestHost.render(JobPhotoViewer(attachment: empty), container: container)
        GLTestHost.render(JobDocumentDetailScreen(attachment: empty), container: container)
    }

    /// Source cards: a job created FROM an estimate vs FROM an invoice — two different NavigationLink
    /// labels from the same `sourceCard`.
    @Test func rendersJobDetailSourceCardsForEstimateAndInvoice() throws {
        let world = try TestStore.demoWorld()
        let container = world.container
        let estimate = try #require(world.estimates.first)
        let invoice = try #require(world.invoices.first)
        let customer = world.primary

        let fromEstimate = TS.job("From estimate", start: .now, customer: customer, in: container.mainContext)
        fromEstimate.estimate = estimate
        let fromInvoice = TS.job("From invoice", start: .now, customer: customer, in: container.mainContext)
        fromInvoice.invoice = invoice

        #expect(fromEstimate.hasSource)
        #expect(fromInvoice.hasSource)
        GLTestHost.render(JobDetailScreen(job: fromEstimate), container: container)
        GLTestHost.render(JobDetailScreen(job: fromInvoice), container: container)
    }

    /// A TIMED job shows "Date" + "Time" rows instead of "Dates" + "Length".
    @Test func rendersJobDetailForTimedJob() throws {
        let container = try TestStore.makeContainer()
        let customer = TS.customer(in: container.mainContext)
        let job = TS.job("2-hour cleaning", start: .now, hour: 13, minutes: 120,
                         customer: customer, in: container.mainContext)
        #expect(!job.timeText.isEmpty)
        GLTestHost.render(JobDetailScreen(job: job), container: container)
    }

    /// A job that is NOT in the store (deleted out from under the screen, e.g. a synced cascade)
    /// draws the DeletedRecordView overlay. Every detail screen in this area shares that guard.
    @Test func rendersJobDetailForDeletedJob() throws {
        let container = try TestStore.makeContainer()
        let orphan = ScheduledJob(title: "Deleted job", startDate: .now)   // never inserted
        GLTestHost.renderBothSchemes(JobDetailScreen(job: orphan), container: container)
    }

    /// Every seeded job through the detail screen, in both schemes — the scheduled / completed /
    /// timed / recurring / project-grouped mix at once.
    @Test func rendersEverySeededJobDetail() throws {
        let world = try TestStore.demoWorld()
        let container = world.container
        let jobs = try container.mainContext.fetch(
            FetchDescriptor<ScheduledJob>(sortBy: [SortDescriptor(\.startDate)]))
        #expect(jobs.count >= 5)
        for job in jobs {
            GLTestHost.render(JobDetailScreen(job: job), container: container, scheme: .dark)
        }
        GLTestHost.render(AllJobsScreen(), container: container)
        GLTestHost.render(JobsListScreen(customer: world.primary), container: container)
    }

    // MARK: ─────────────────────────────────────────────────────────────────────────────────────
    // MARK: 4. ESTIMATE DETAIL / FORM — status, conversion, money branches
    // MARK: ─────────────────────────────────────────────────────────────────────────────────────

    /// One estimate per status, plus an EXPIRED one — five distinct badge colors and labels.
    @Test func rendersEstimateDetailForEveryStatus() throws {
        let container = try TestStore.makeContainer()
        let customer = TS.customer(in: container.mainContext)
        let ctx = container.mainContext

        for (index, status) in EstimateStatus.allCases.enumerated() {
            let estimate = Estimate(number: String(format: "EST-%04d", index + 1),
                                    jobTitle: "\(status.label) job", status: status, customer: customer)
            estimate.taxRatePercent = 7.5
            ctx.insert(estimate)
            let group = EstimateGroup(name: "Work", sortIndex: 0); group.estimate = estimate; ctx.insert(group)
            let line = EstimateLineItem(name: "Tile install", quantity: 120, unit: .squareFoot,
                                        unitPrice: 6.5, kind: .labor, isTaxable: false, sortIndex: 0)
            line.group = group; ctx.insert(line)
            GLTestHost.render(EstimateDetailScreen(estimate: estimate), container: container)
        }

        // Expired: SENT but past its valid-until day.
        let expired = Estimate(number: "EST-0099", jobTitle: "Stale quote", status: .sent, customer: customer)
        expired.validUntil = .now.addingTimeInterval(-10 * 86_400)
        ctx.insert(expired)
        #expect(expired.isExpired)
        #expect(expired.displayStatus != expired.status.label)
        GLTestHost.render(EstimateDetailScreen(estimate: expired), container: container)
        GLTestHost.render(EstimateStatusBadge(estimate: expired), container: container)
    }

    /// A DECLINED estimate: never expires (even past its date), never offers "Schedule", and keeps
    /// the red badge. The two guards in `isExpired` and the toolbar's `status == .accepted` check.
    @Test func rendersDeclinedEstimateDetail() throws {
        let container = try TestStore.makeContainer()
        let customer = TS.customer(in: container.mainContext)
        let declined = Estimate(number: "EST-0007", jobTitle: "Turned down",
                                status: .declined, customer: customer)
        declined.validUntil = .now.addingTimeInterval(-365 * 86_400)
        container.mainContext.insert(declined)
        #expect(!declined.isExpired)
        #expect(declined.displayStatus == EstimateStatus.declined.label)
        GLTestHost.renderBothSchemes(EstimateDetailScreen(estimate: declined), container: container)
    }

    /// Converted vs not: an estimate with a matching `sourceEstimateNumber` invoice in the store is
    /// the state that makes "Convert to Invoice" ask before minting a second one.
    @Test func rendersEstimateDetailConvertedAndNotConverted() throws {
        let container = try TestStore.makeContainer()
        let customer = TS.customer(in: container.mainContext)
        let ctx = container.mainContext

        let notConverted = Estimate(number: "EST-0001", jobTitle: "Fresh quote",
                                    status: .accepted, customer: customer)
        let converted = Estimate(number: "EST-0002", jobTitle: "Already billed",
                                 status: .accepted, customer: customer)
        [notConverted, converted].forEach(ctx.insert)
        let group = EstimateGroup(name: "Work", sortIndex: 0); group.estimate = converted; ctx.insert(group)
        let line = EstimateLineItem(name: "Labor", quantity: 1, unit: .job, unitPrice: 900,
                                    kind: .labor, isTaxable: false, sortIndex: 0)
        line.group = group; ctx.insert(line)

        let invoice = Invoice.make(from: converted, number: "INV-0001", in: ctx)
        ctx.saveChanges()

        let all = try ctx.fetch(FetchDescriptor<Invoice>(sortBy: [SortDescriptor(\.number)]))
        #expect(invoice.sourceEstimateNumber == "EST-0002")
        #expect(all.contains { $0.sourceEstimateNumber == converted.number })
        #expect(!all.contains { $0.sourceEstimateNumber == notConverted.number })

        GLTestHost.render(EstimateDetailScreen(estimate: converted), container: container)
        GLTestHost.render(EstimateDetailScreen(estimate: notConverted), container: container)
    }

    /// The reconvert guard's precondition: `Invoice.make` copies an EMPTY estimate number verbatim,
    /// so without the `!estimate.number.isEmpty` check every un-numbered estimate would look
    /// "already converted" the moment any other un-numbered one was billed.
    @Test func emptyEstimateNumberWouldFalsePositiveWithoutTheGuard() throws {
        let container = try TestStore.makeContainer()
        let ctx = container.mainContext
        let billed = Estimate(number: "", jobTitle: "Un-numbered A")
        let other = Estimate(number: "", jobTitle: "Un-numbered B")
        [billed, other].forEach(ctx.insert)
        let invoice = Invoice.make(from: billed, number: "INV-0001", in: ctx)
        ctx.saveChanges()

        #expect(invoice.sourceEstimateNumber == "")
        // The naive match hits — which is exactly why the screen guards on a non-empty number first.
        let all = try ctx.fetch(FetchDescriptor<Invoice>(sortBy: [SortDescriptor(\.number)]))
        #expect(all.contains { $0.sourceEstimateNumber == other.number })
        #expect(other.number.isEmpty)
    }

    /// The money branches on the detail: whole-document discount, tax, deposit, per-line discount,
    /// multiple groups (which turns on the per-group subtotal row), notes + terms, service address.
    @Test func rendersEstimateDetailWithEveryMoneyAndContentBranch() throws {
        let container = try TestStore.makeContainer()
        let customer = TS.customer(in: container.mainContext)
        let ctx = container.mainContext
        let estimate = Estimate(number: "EST-0010", jobTitle: "Full-fat estimate",
                                status: .sent, customer: customer)
        estimate.taxRatePercent = 7.5
        estimate.discountType = .percentage; estimate.discountValue = 10
        estimate.depositType = .percentage; estimate.depositValue = 30
        estimate.customerNotes = "Colors confirmed on site."
        estimate.terms = "Balance due on completion."
        estimate.serviceAddress = Address(street1: "88 Lakeshore Dr", city: "Miami",
                                          state: "FL", postalCode: "32312")
        ctx.insert(estimate)

        let g1 = EstimateGroup(name: "Tile & Flooring", note: "5×3×8", sortIndex: 0)
        g1.estimate = estimate; ctx.insert(g1)
        let g2 = EstimateGroup(name: "Prep & Demo", sortIndex: 1)
        g2.estimate = estimate; ctx.insert(g2)

        let discounted = EstimateLineItem(name: "Porcelain tile 12×24", details: "Matte, rectified",
                                          quantity: 130, unit: .squareFoot, unitPrice: 4.25,
                                          kind: .material, isTaxable: true, sortIndex: 0,
                                          discountType: .percentage, discountValue: 15)
        discounted.group = g1; ctx.insert(discounted)
        let plain = EstimateLineItem(name: "Tile installation", quantity: 120, unit: .squareFoot,
                                     unitPrice: 6.5, kind: .labor, isTaxable: false, sortIndex: 1)
        plain.group = g1; ctx.insert(plain)
        let demo = EstimateLineItem(name: "Demo & haul-away", quantity: 1, unit: .job, unitPrice: 450,
                                    kind: .labor, isTaxable: false, sortIndex: 0)
        demo.group = g2; ctx.insert(demo)

        #expect(discounted.lineDiscount > 0)
        #expect(estimate.discountAmount > 0)
        #expect(estimate.taxAmount > 0)
        #expect(estimate.depositAmount > 0)
        GLTestHost.renderBothSchemes(EstimateDetailScreen(estimate: estimate), container: container)
        GLTestHost.render(EstimateDetailScreen(estimate: estimate), container: container, typeSize: .accessibility3)
    }

    /// An estimate with NO groups and no customer snapshot: every optional card collapses, the
    /// title falls back to "Untitled estimate", and the customer falls back to "Customer".
    @Test func rendersEmptyEstimateDetail() throws {
        let container = try TestStore.makeContainer()
        let bare = Estimate(number: "")
        container.mainContext.insert(bare)
        #expect(bare.sortedGroups.isEmpty)
        #expect(bare.customerDisplayName == "Customer")
        #expect(close(bare.total, 0))
        GLTestHost.render(EstimateDetailScreen(estimate: bare), container: container)
    }

    /// A deleted estimate draws the DeletedRecordView overlay.
    @Test func rendersEstimateDetailForDeletedEstimate() throws {
        let container = try TestStore.makeContainer()
        let orphan = Estimate(number: "EST-0404", jobTitle: "Gone")   // never inserted
        GLTestHost.render(EstimateDetailScreen(estimate: orphan), container: container)
    }

    /// The form: new-for-customer, editing a populated estimate, editing a group-less one (which
    /// seeds a blank draft group), and each adjustment shape (percentage vs fixed).
    @Test func rendersEstimateFormBranches() throws {
        let world = try TestStore.demoWorld()
        let container = world.container
        let customer = world.primary
        let ctx = container.mainContext

        GLTestHost.renderBothSchemes(EstimateFormScreen(customer: customer), container: container)

        for estimate in try ctx.fetch(FetchDescriptor<Estimate>(sortBy: [SortDescriptor(\.number)])) {
            GLTestHost.render(EstimateFormScreen(editing: estimate), container: container)
        }

        let groupless = Estimate(number: "EST-0500", jobTitle: "No lines yet", customer: customer)
        ctx.insert(groupless)
        GLTestHost.render(EstimateFormScreen(editing: groupless), container: container)

        let fixedAdjustments = Estimate(number: "EST-0501", jobTitle: "Fixed adjustments",
                                        customer: customer)
        fixedAdjustments.discountType = .fixed; fixedAdjustments.discountValue = 250
        fixedAdjustments.depositType = .fixed; fixedAdjustments.depositValue = 500
        ctx.insert(fixedAdjustments)
        let group = EstimateGroup(name: "Work", sortIndex: 0)
        group.estimate = fixedAdjustments; ctx.insert(group)
        let line = EstimateLineItem(name: "Labor", quantity: 8, unit: .hour, unitPrice: 95,
                                    kind: .labor, isTaxable: false, sortIndex: 0,
                                    discountType: .fixed, discountValue: 40)
        line.group = group; ctx.insert(line)
        GLTestHost.render(EstimateFormScreen(editing: fixedAdjustments), container: container)
        GLTestHost.render(EstimateFormScreen(editing: fixedAdjustments), container: container, typeSize: .accessibility3)
    }

    // MARK: ─────────────────────────────────────────────────────────────────────────────────────
    // MARK: 5. CHANGE ORDERS — add vs subtract, applied vs not
    // MARK: ─────────────────────────────────────────────────────────────────────────────────────

    /// A SENT invoice with one taxable $1,000 line for the fixture customer, saved in a fresh
    /// store — composed from the harness builders, nothing seeded by hand.
    private func sentInvoiceStore(taxRatePercent: Double = 0) throws -> (ModelContainer, Invoice) {
        let container = try TestStore.makeContainer()
        let ctx = container.mainContext
        let invoice = TS.invoice(status: .sent, taxRatePercent: taxRatePercent,
                                 lines: [(1_000, true)], in: ctx)
        invoice.customer = TS.customer(in: ctx)
        ctx.saveChanges()
        return (container, invoice)
    }

    /// A change order that ADDS work vs one that SUBTRACTS it (a credit). Both render on the form
    /// and the detail sheet; the credit's segmented Charge/Credit picker starts on Credit and the
    /// "−" marker shows next to its price.
    @Test func rendersChangeOrderFormForAddAndSubtract() throws {
        let (container, invoice) = try sentInvoiceStore(taxRatePercent: 7.5)
        let ctx = container.mainContext
        let addition = TS.changeOrder(invoice, number: "CO-0001", taxRatePercent: invoice.taxRatePercent,
                                      lines: [(200, true)], in: ctx)
        let credit = TS.changeOrder(invoice, number: "CO-0002", taxRatePercent: invoice.taxRatePercent,
                                    lines: [(-150, false)], in: ctx)
        ctx.saveChanges()

        #expect(addition.total > 0)
        #expect(credit.total < 0)

        GLTestHost.renderBothSchemes(ChangeOrderFormScreen(invoice: invoice), container: container)
        GLTestHost.render(ChangeOrderFormScreen(invoice: invoice, editing: addition), container: container)
        GLTestHost.render(ChangeOrderFormScreen(invoice: invoice, editing: credit), container: container)
        GLTestHost.render(ChangeOrderFormScreen(invoice: invoice, editing: credit), container: container, typeSize: .accessibility3)
    }

    /// Editing a change order that is ALREADY on the invoice adds the "changes update the invoice's
    /// items too" footer — a branch only an applied order reaches.
    @Test func rendersChangeOrderFormForAppliedOrder() throws {
        let (container, invoice) = try sentInvoiceStore()
        let ctx = container.mainContext
        let applied = TS.changeOrder(invoice, number: "CO-0001", status: .approved, lines: [(200, false)], in: ctx)
        applied.addItemsToInvoice(using: ctx)
        ctx.saveChanges()
        #expect(applied.appliedToInvoice)
        GLTestHost.render(ChangeOrderFormScreen(invoice: invoice, editing: applied), container: container)
    }

    /// Editing an order with NO line items falls back to a single blank draft row (the
    /// `sortedLineItems.isEmpty` branch of the init).
    @Test func rendersChangeOrderFormForEmptyOrder() throws {
        let (container, invoice) = try sentInvoiceStore()
        let empty = ChangeOrder(number: "CO-0009", title: "", taxRatePercent: 0)
        empty.invoice = invoice
        container.mainContext.insert(empty)
        #expect(empty.sortedLineItems.isEmpty)
        GLTestHost.render(ChangeOrderFormScreen(invoice: invoice, editing: empty), container: container)
    }

    @Test func rendersChangeOrderFormForContract() throws {
        let (container, _) = try sentInvoiceStore()
        let ctx = container.mainContext
        let contract = Contract(number: "CNT-0001", title: "Roof repair")
        ctx.insert(contract)
        ctx.saveChanges()
        GLTestHost.render(ChangeOrderFormScreen(contract: contract), container: container)
    }

    /// The detail sheet across every status × applied combination: pending (no apply row),
    /// approved-not-applied ("Add items to invoice"), approved-and-applied ("Added to invoice"),
    /// and declined.
    @Test func rendersChangeOrderDetailAcrossStatuses() throws {
        let (container, invoice) = try sentInvoiceStore(taxRatePercent: 7.5)
        let ctx = container.mainContext

        let rate = invoice.taxRatePercent
        let pending = TS.changeOrder(invoice, number: "CO-0001", taxRatePercent: rate,
                                     lines: [(200, false)], in: ctx)
        let approved = TS.changeOrder(invoice, number: "CO-0002", status: .approved, taxRatePercent: rate,
                                      lines: [(300, false)], in: ctx)
        let declined = TS.changeOrder(invoice, number: "CO-0003", status: .declined, taxRatePercent: rate,
                                      lines: [(400, false)], in: ctx)
        let appliedCredit = TS.changeOrder(invoice, number: "CO-0004", status: .approved, taxRatePercent: rate,
                                           lines: [(-125, false)], in: ctx)
        appliedCredit.addItemsToInvoice(using: ctx)
        ctx.saveChanges()

        #expect(pending.status == .pending && !pending.appliedToInvoice)
        #expect(approved.status == .approved && !approved.appliedToInvoice)
        #expect(appliedCredit.appliedToInvoice)

        GLTestHost.render(ChangeOrderDetailSheet(changeOrder: pending), container: container, scheme: .dark)
        GLTestHost.render(ChangeOrderDetailSheet(changeOrder: approved), container: container, scheme: .light)
        GLTestHost.render(ChangeOrderDetailSheet(changeOrder: declined), container: container)
        GLTestHost.render(ChangeOrderDetailSheet(changeOrder: appliedCredit), container: container)
        GLTestHost.render(AllChangeOrdersScreen(), container: container)
    }

    /// An ORPHANED change order (its invoice was deleted, nullifying the link) still renders: the
    /// Email/Text menu entries drop out and the PDF falls back to em-dashes.
    @Test func rendersChangeOrderDetailWithoutAnInvoice() throws {
        let container = try TestStore.makeContainer()
        let orphan = ChangeOrder(number: "CO-0404", title: "Orphaned change", taxRatePercent: 0)
        container.mainContext.insert(orphan)
        let item = ChangeOrderLineItem(name: "Work", quantity: 1, unit: .job, unitPrice: 50, sortIndex: 0)
        item.changeOrder = orphan
        container.mainContext.insert(item)
        container.mainContext.saveChanges()
        #expect(orphan.invoice == nil)
        GLTestHost.render(ChangeOrderDetailSheet(changeOrder: orphan), container: container)
    }

    /// A change order deleted out from under the sheet draws DeletedRecordView (and disables the
    /// share menu, which the overlay can't cover).
    @Test func rendersChangeOrderDetailForDeletedOrder() throws {
        let container = try TestStore.makeContainer()
        let orphan = ChangeOrder(number: "CO-0500", title: "Gone", taxRatePercent: 0)   // never inserted
        GLTestHost.render(ChangeOrderDetailSheet(changeOrder: orphan), container: container)
    }

    // MARK: ─────────────────────────────────────────────────────────────────────────────────────
    // MARK: 6. DATE MATH — month boundaries, DST, leap days
    // MARK: ─────────────────────────────────────────────────────────────────────────────────────

    /// A 3-workday job starting Mon Aug 31 2026 runs into September: Aug 31, Sep 1, Sep 2.
    @Test func multiDayJobSpansAMonthBoundary() {
        let job = ScheduledJob(startDate: TS.day(2026, 8, 31), durationDays: 3)
        let days = job.occupiedDays(schedule: plainSchedule, calendar: cal)
        #expect(days.count == 3)
        #expect(cal.isDate(days[0], inSameDayAs: TS.day(2026, 8, 31)))
        #expect(cal.isDate(days[1], inSameDayAs: TS.day(2026, 9, 1)))
        #expect(cal.isDate(days[2], inSameDayAs: TS.day(2026, 9, 2)))
        #expect(cal.isDate(job.endDay(schedule: plainSchedule, calendar: cal),
                           inSameDayAs: TS.day(2026, 9, 2)))
    }

    /// A 3-workday job starting Fri Oct 30 2026 crosses the DST FALL-BACK (Sun Nov 1) and lands on
    /// Oct 30, Nov 2, Nov 3 — every entry still an exact start-of-day, no 23/25-hour drift.
    @Test func multiDayJobCrossesDSTFallBackWithoutDrift() {
        let job = ScheduledJob(startDate: TS.day(2026, 10, 30), durationDays: 3)
        let days = job.occupiedDays(schedule: plainSchedule, calendar: cal)
        #expect(days.count == 3)
        #expect(cal.isDate(days[0], inSameDayAs: TS.day(2026, 10, 30)))
        #expect(cal.isDate(days[1], inSameDayAs: TS.day(2026, 11, 2)))
        #expect(cal.isDate(days[2], inSameDayAs: TS.day(2026, 11, 3)))
        for d in days { #expect(d == cal.startOfDay(for: d)) }
    }

    /// The same across the SPRING-FORWARD (Sun Mar 8 2026): Mar 6, Mar 9, Mar 10.
    @Test func multiDayJobCrossesDSTSpringForwardWithoutDrift() {
        let job = ScheduledJob(startDate: TS.day(2026, 3, 6), durationDays: 3)
        let days = job.occupiedDays(schedule: plainSchedule, calendar: cal)
        #expect(days.count == 3)
        #expect(cal.isDate(days[0], inSameDayAs: TS.day(2026, 3, 6)))
        #expect(cal.isDate(days[1], inSameDayAs: TS.day(2026, 3, 9)))
        #expect(cal.isDate(days[2], inSameDayAs: TS.day(2026, 3, 10)))
        for d in days { #expect(d == cal.startOfDay(for: d)) }
    }

    /// Working hours are WALL-CLOCK 8–5 on both DST transition days. Building them by adding
    /// elapsed minutes to startOfDay would give 7–4 on the fall-back day and 9–6 on the
    /// spring-forward day; `bySettingHour` keeps them honest.
    @Test func workingHoursStayEightToFiveAcrossBothDSTTransitions() throws {
        for date in [TS.day(2026, 11, 1), TS.day(2026, 3, 8)] {
            let window = try #require(WorkCalendar.workingHours(date, schedule: sevenDaySchedule,
                                                                calendar: cal).first)
            #expect(cal.component(.hour, from: window.start) == 8)
            #expect(cal.component(.hour, from: window.end) == 17)
            #expect(close(window.duration, 9 * 3_600, eps: 1))
        }
    }

    /// The month grid keeps exactly one cell per day across both DST months — no day dropped, no
    /// day doubled, every cell at local midnight.
    @Test func monthGridCellsSurviveBothDSTMonths() {
        for (year, month, count) in [(2026, 3, 31), (2026, 11, 30)] {
            let monthStart = TS.day(year, month, 1)
            let cells = CalendarGrid.monthCells(monthStart: monthStart, calendar: cal)
            let real = cells.compactMap { $0 }
            #expect(real.count == count)
            #expect(real.map { cal.component(.day, from: $0) } == Array(1...count))
            for d in real { #expect(cal.component(.hour, from: d) == 0) }
        }
    }

    /// December → the year boundary: 31 cells, and the leading blanks align Dec 1 2026 (a Tuesday)
    /// under the third column of a Sunday-first week.
    @Test func monthGridHandlesTheYearBoundary() {
        let cells = CalendarGrid.monthCells(monthStart: TS.day(2026, 12, 1), calendar: cal)
        #expect(cells.compactMap { $0 }.count == 31)
        #expect(cells.prefix(while: { $0 == nil }).count == 2)   // Dec 1 2026 = Tuesday, week starts Sunday
        #expect(cells.count == 33)
    }

    /// A vacation range inside a multi-day run pushes the end date out — the schedule-aware end
    /// date every surface (agenda, detail, form footer) now shares.
    @Test func multiDayJobSkipsAVacationRange() {
        var schedule = plainSchedule
        schedule.vacations = [DateRangeRule(start: TS.day(2026, 6, 3), end: TS.day(2026, 6, 4))]
        let job = ScheduledJob(startDate: TS.day(2026, 6, 1), durationDays: 3)   // Mon June 1
        let days = job.occupiedDays(schedule: schedule, calendar: cal)
        #expect(days.count == 3)
        #expect(cal.isDate(days[0], inSameDayAs: TS.day(2026, 6, 1)))
        #expect(cal.isDate(days[1], inSameDayAs: TS.day(2026, 6, 2)))
        #expect(cal.isDate(days[2], inSameDayAs: TS.day(2026, 6, 5)))   // Wed+Thu are vacation
    }

    /// A blocked date override removes a single day from a run.
    @Test func multiDayJobSkipsABlockedDateOverride() {
        var schedule = plainSchedule
        schedule.overrides = [DateOverride(date: TS.day(2026, 6, 2), kind: .blocked)]
        let job = ScheduledJob(startDate: TS.day(2026, 6, 1), durationDays: 2)
        let days = job.occupiedDays(schedule: schedule, calendar: cal)
        #expect(cal.isDate(days[0], inSameDayAs: TS.day(2026, 6, 1)))
        #expect(cal.isDate(days[1], inSameDayAs: TS.day(2026, 6, 3)))
    }

    /// A schedule with EVERY weekday switched off is an unfinished schedule, not a business that
    /// never works — read literally it erased the calendar (jobs occupying zero days, multi-day
    /// runs collapsing onto their start, an empty agenda over records that still existed). It falls
    /// back to each day's own hours instead, so a job still occupies real days.
    @Test func jobOnAnAllOffScheduleStillOccupiesItsDays() {
        #expect(!noWorkdaySchedule.hasAnyWorkday)
        #expect(WorkCalendar.isWorkday(TS.day(2026, 6, 6), schedule: noWorkdaySchedule, calendar: cal))

        let job = ScheduledJob(startDate: TS.day(2026, 6, 1), durationDays: 5)
        let days = job.occupiedDays(schedule: noWorkdaySchedule, calendar: cal)
        #expect(days.count == 5)
        #expect(cal.isDate(days[0], inSameDayAs: TS.day(2026, 6, 1)))
        #expect(cal.isDate(job.endDay(schedule: noWorkdaySchedule, calendar: cal),
                           inSameDayAs: TS.day(2026, 6, 5)))
        #expect(!SchedulingEngine.occupiedDays([job], schedule: noWorkdaySchedule, calendar: cal).isEmpty)

        // A schedule that DOES name workdays is still honored literally — the fallback is scoped
        // to the all-off case only.
        #expect(plainSchedule.hasAnyWorkday)
        #expect(!WorkCalendar.isWorkday(TS.day(2026, 6, 6), schedule: plainSchedule, calendar: cal))   // Saturday
    }

    // MARK: - Recurrence date math

    /// A monthly series anchored on the 31st clamps into short months and then RECOVERS — it must
    /// not permanently drift to the 28th after February.
    @Test func monthlyRecurrenceClampsShortMonthsAndRecovers() {
        let job = ScheduledJob(startDate: TS.day(2026, 1, 31), durationDays: 1)
        job.recurrenceFrequency = .monthly
        let occurrences = job.occurrenceStartDates(
            in: DateInterval(start: TS.day(2026, 1, 1), end: TS.day(2026, 7, 15)), calendar: cal)
        #expect(occurrences.map { cal.component(.day, from: $0) } == [31, 28, 31, 30, 31, 30])
        #expect(occurrences.map { cal.component(.month, from: $0) } == [1, 2, 3, 4, 5, 6])
    }

    /// A monthly series anchored on LEAP DAY: Feb 29 2028 → Mar 29 → … → Feb 28 2029 (2029 is not
    /// a leap year, so the 12-month occurrence clamps).
    @Test func monthlyRecurrenceFromLeapDayClampsTheFollowingFebruary() throws {
        let job = ScheduledJob(startDate: TS.day(2028, 2, 29), durationDays: 1)
        job.recurrenceFrequency = .monthly
        job.recurrenceCount = 13
        let occurrences = job.occurrenceStartDates(
            in: DateInterval(start: TS.day(2028, 1, 1), end: TS.day(2029, 6, 1)), calendar: cal)
        #expect(occurrences.count == 13)
        let first = try #require(occurrences.first)
        let last = try #require(occurrences.last)
        #expect(cal.isDate(first, inSameDayAs: TS.day(2028, 2, 29)))
        #expect(cal.isDate(occurrences[1], inSameDayAs: TS.day(2028, 3, 29)))
        #expect(cal.isDate(last, inSameDayAs: TS.day(2029, 2, 28)))
    }

    /// A weekly series across the spring-forward week still lands on the same weekday.
    @Test func weeklyRecurrenceKeepsItsWeekdayAcrossDST() {
        let job = ScheduledJob(startDate: TS.day(2026, 3, 2), durationDays: 1)   // Monday
        job.recurrenceFrequency = .weekly
        let occurrences = job.occurrenceStartDates(
            in: DateInterval(start: TS.day(2026, 3, 1), end: TS.day(2026, 3, 31)), calendar: cal)
        #expect(occurrences.count == 5)
        for occurrence in occurrences {
            #expect(cal.component(.weekday, from: occurrence) == 2)   // Monday everywhere
            #expect(occurrence == cal.startOfDay(for: occurrence))
        }
    }

    /// A single-visit series produces exactly one occurrence — the `recurrenceCount == 1` boundary.
    @Test func recurrenceCountOfOneYieldsOneOccurrence() {
        let job = ScheduledJob(startDate: TS.day(2026, 6, 1), durationDays: 1)
        job.recurrenceFrequency = .weekly
        job.recurrenceCount = 1
        let occurrences = job.occurrenceStartDates(
            in: DateInterval(start: TS.day(2026, 5, 1), end: TS.day(2026, 12, 1)), calendar: cal)
        #expect(occurrences.count == 1)
        #expect(cal.isDate(occurrences[0], inSameDayAs: TS.day(2026, 6, 1)))
    }

    /// REGRESSION GUARD: a recurring job whose end date precedes its start is
    /// contradictory data (the form can't produce it; an edited or synced record
    /// can). It used to yield NO occurrences, so the job vanished from the calendar,
    /// the agenda and the availability math while its record still existed. It now
    /// still happens exactly once, on the day it starts.
    @Test func recurrenceEndingBeforeItStartsStillHappensOnce() {
        let job = ScheduledJob(startDate: TS.day(2026, 6, 1), durationDays: 1)
        job.recurrenceFrequency = .weekly
        job.recurrenceEndDate = TS.day(2026, 5, 1)
        let range = DateInterval(start: TS.day(2026, 1, 1), end: TS.day(2026, 12, 31))

        let occurrences = job.occurrenceStartDates(in: range, calendar: cal)
        #expect(occurrences.count == 1, "the job disappeared entirely")
        #expect(cal.isDate(occurrences[0], inSameDayAs: TS.day(2026, 6, 1)))

        let expanded = SchedulingEngine.expand([job], in: range, calendar: cal)
        #expect(expanded.count == 1)
        #expect(!SchedulingEngine.occupiedDays(expanded, schedule: plainSchedule, calendar: cal).isEmpty,
                "the job occupies no day, so it books nothing and blocks nothing")

        // An end date ON the start day behaves the same — one occurrence, not zero.
        let sameDay = ScheduledJob(startDate: TS.day(2026, 6, 1), durationDays: 1)
        sameDay.recurrenceFrequency = .weekly
        sameDay.recurrenceEndDate = TS.day(2026, 6, 1)
        #expect(sameDay.occurrenceStartDates(in: range, calendar: cal).count == 1)
    }

    /// A one-off job outside the horizon isn't materialized; inside it, it passes through unchanged.
    @Test func expandPassesOneOffJobsThroughOnlyInsideTheHorizon() {
        let job = ScheduledJob(startDate: TS.day(2026, 6, 1), durationDays: 2)
        let inside = DateInterval(start: TS.day(2026, 5, 1), end: TS.day(2026, 7, 1))
        let outside = DateInterval(start: TS.day(2027, 1, 1), end: TS.day(2027, 2, 1))
        #expect(SchedulingEngine.expand([job], in: inside, calendar: cal).count == 1)
        #expect(job.occurrenceStartDates(in: inside, calendar: cal).count == 1)   // a one-off is its own single occurrence
        // A NON-recurring job is passed through by `expand` regardless of range — occurrence
        // filtering only applies to series. Documented so a future change is deliberate.
        #expect(SchedulingEngine.expand([job], in: outside, calendar: cal).count == 1)
        #expect(job.occurrenceStartDates(in: outside, calendar: cal).isEmpty)
    }

    /// An occurrence copy is a plain one-off on its new day, keeping the timed window's wall-clock
    /// hour and dropping the recurrence (otherwise expansion would recurse).
    @Test func occurrenceCopyRebasesTheTimedWindowAndDropsRecurrence() throws {
        let job = ScheduledJob(startDate: TS.day(2026, 6, 1), durationDays: 1)
        job.isAllDay = false
        job.startTime = cal.date(bySettingHour: 13, minute: 30, second: 0, of: TS.day(2026, 6, 1))
        job.durationMinutes = 120
        job.recurrenceFrequency = .weekly

        let copy = job.occurrenceCopy(on: TS.day(2026, 6, 8), calendar: cal)
        let start = try #require(copy.startTime)
        #expect(!copy.isRecurring)
        #expect(!copy.isAllDay)
        #expect(cal.component(.hour, from: start) == 13)
        #expect(cal.component(.minute, from: start) == 30)
        #expect(cal.isDate(start, inSameDayAs: TS.day(2026, 6, 8)))
        #expect(copy.durationMinutes == 120)
    }

    // MARK: - Openings / clear date

    /// A run of free workdays closed by a booked day is a `.fullDays` opening; the trailing free
    /// run after the last job is availability, not a gap, so it is excluded.
    @Test func openingsReturnBoundedFullDayRunsOnly() throws {
        let booked = ScheduledJob(startDate: TS.day(2026, 6, 5), durationDays: 1)   // Friday
        let openings = SchedulingEngine.openings([booked], from: TS.day(2026, 6, 1), horizonDays: 7,
                                                 schedule: plainSchedule, calendar: cal)
        #expect(openings.count == 1)
        let opening = try #require(openings.first)
        #expect(opening.workdays == 4)                                  // Mon–Thu
        #expect(opening.window == nil)
        #expect(cal.isDate(opening.start, inSameDayAs: TS.day(2026, 6, 1)))
        #expect(cal.isDate(opening.end, inSameDayAs: TS.day(2026, 6, 4)))
        #expect(opening.capacityText == "Fits 4 workdays")

        // A run that crosses a weekend counts only the workdays: Jun 1–5 + 8–12 ahead of a Jun 15
        // booking — and it is still a full-days run, not a window.
        let later = ScheduledJob(startDate: TS.day(2026, 6, 15), durationDays: 1)
        let acrossWeekend = SchedulingEngine.openings([later], from: TS.day(2026, 6, 1),
                                                      schedule: plainSchedule, calendar: cal)
        #expect(acrossWeekend.first?.workdays == 10)
        #expect(acrossWeekend.first?.window == nil)
    }

    /// A timed job splits its day into two intra-day windows — the free time on each SIDE of it,
    /// in order, each labelled in hours.
    @Test func timedJobLeavesTwoLabelledIntradayWindows() throws {
        let job = ScheduledJob(startDate: TS.day(2026, 6, 2), durationDays: 1)   // Tuesday
        job.isAllDay = false
        job.startTime = cal.date(bySettingHour: 10, minute: 0, second: 0, of: TS.day(2026, 6, 2))
        job.durationMinutes = 120                                                // 10:00–12:00
        let openings = SchedulingEngine.openings([job], from: TS.day(2026, 6, 2), horizonDays: 1,
                                                 schedule: plainSchedule, calendar: cal)
        #expect(openings.count == 2)
        #expect(openings.allSatisfy { $0.window != nil })
        #expect(openings.allSatisfy { $0.workdays == 1 })
        #expect(openings.map(\.capacityText) == ["2 hr free", "5 hr free"])   // 8–10, then 12–5
        #expect(openings.compactMap(\.window).map { Int($0.duration / 60) } == [120, 300])
    }

    /// The `minMinutes` floor is INCLUSIVE: a window exactly as long as the floor is kept, one
    /// minute of floor more drops it.
    @Test func openingsHonorTheMinimumWindowBoundaryInclusively() {
        let job = ScheduledJob(startDate: TS.day(2026, 6, 2), durationDays: 1)
        job.isAllDay = false
        job.startTime = cal.date(bySettingHour: 8, minute: 0, second: 0, of: TS.day(2026, 6, 2))
        job.durationMinutes = 510   // 8:00 → 16:30, leaving exactly 30 minutes before 17:00

        let kept = SchedulingEngine.openings([job], from: TS.day(2026, 6, 2), horizonDays: 1,
                                             schedule: plainSchedule, minMinutes: 30, calendar: cal)
        #expect(kept.count == 1)
        #expect(kept.first?.capacityText == "30 min free")

        let dropped = SchedulingEngine.openings([job], from: TS.day(2026, 6, 2), horizonDays: 1,
                                                schedule: plainSchedule, minMinutes: 31, calendar: cal)
        #expect(dropped.isEmpty)
    }

    /// A day booked wall-to-wall by an all-day job yields no window at all.
    @Test func fullyBookedDayYieldsNoOpenings() {
        let job = ScheduledJob(startDate: TS.day(2026, 6, 2), durationDays: 1)
        let openings = SchedulingEngine.openings([job], from: TS.day(2026, 6, 2), horizonDays: 1,
                                                 schedule: plainSchedule, calendar: cal)
        #expect(openings.isEmpty)
    }

    /// The clear date is the first open workday AFTER the last booked day.
    @Test func nextClearDateFollowsTheLastBookedDay() {
        let job = ScheduledJob(startDate: TS.day(2026, 6, 3), durationDays: 1)   // Wednesday
        let clear = SchedulingEngine.nextClearDate([job], from: TS.day(2026, 6, 1),
                                                   schedule: plainSchedule, calendar: cal)
        #expect(cal.isDate(clear, inSameDayAs: TS.day(2026, 6, 4)))
    }

    /// With only PAST bookings (or none at all), there is no "last booked day" ahead, so the clear
    /// date collapses to the next available workday from today — walking off a weekend start.
    @Test func nextClearDateWithOnlyPastBookingsIsTheNextWorkday() {
        let past = ScheduledJob(startDate: TS.day(2026, 5, 1), durationDays: 1)
        let clear = SchedulingEngine.nextClearDate([past], from: TS.day(2026, 6, 1),
                                                   schedule: plainSchedule, calendar: cal)
        #expect(cal.isDate(clear, inSameDayAs: TS.day(2026, 6, 1)))

        // No jobs at all, asked on a Saturday → the following Monday.
        let fromSaturday = SchedulingEngine.nextClearDate([], from: TS.day(2026, 6, 6),
                                                          schedule: plainSchedule, calendar: cal)
        #expect(cal.isDate(fromSaturday, inSameDayAs: TS.day(2026, 6, 8)))
    }

    /// The clear date walks past a weekend when the last booked day is a Friday.
    @Test func nextClearDateSkipsTheWeekend() {
        let friday = ScheduledJob(startDate: TS.day(2026, 6, 5), durationDays: 1)
        let clear = SchedulingEngine.nextClearDate([friday], from: TS.day(2026, 6, 1),
                                                   schedule: plainSchedule, calendar: cal)
        #expect(cal.isDate(clear, inSameDayAs: TS.day(2026, 6, 8)))   // the following Monday
    }

    /// The engine primitives under overlap detection: the proposed job's workdays vs every existing
    /// booking's workdays, with recurring series EXPANDED first (an unexpanded series only occupies
    /// its literal start day). The screens' check itself is `JobScheduling.overlaps(.full)`, pinned
    /// in JobOverlapTests.
    @Test func overlapDetectionMatchesTheSheetsRule() {
        let existing = ScheduledJob(startDate: TS.day(2026, 6, 1), durationDays: 3)   // Mon–Wed
        let range = DateInterval(start: TS.day(2026, 5, 1), end: TS.day(2026, 8, 1))
        let booked = SchedulingEngine.occupiedDays(
            SchedulingEngine.expand([existing], in: range, calendar: cal),
            schedule: plainSchedule, calendar: cal)

        let overlapping = Set(ScheduledJob(startDate: TS.day(2026, 6, 3), durationDays: 2)
            .occupiedDays(schedule: plainSchedule, calendar: cal))
        #expect(!overlapping.isDisjoint(with: booked))

        let clear = Set(ScheduledJob(startDate: TS.day(2026, 6, 4), durationDays: 1)
            .occupiedDays(schedule: plainSchedule, calendar: cal))
        #expect(clear.isDisjoint(with: booked))

        // Recurring: the proposal lands on occurrence #2, which only expansion reveals.
        let weekly = ScheduledJob(startDate: TS.day(2026, 6, 1), durationDays: 1)
        weekly.recurrenceFrequency = .weekly
        let expandedBooked = SchedulingEngine.occupiedDays(
            SchedulingEngine.expand([weekly], in: range, calendar: cal),
            schedule: plainSchedule, calendar: cal)
        let onSecondOccurrence = Set(ScheduledJob(startDate: TS.day(2026, 6, 8), durationDays: 1)
            .occupiedDays(schedule: plainSchedule, calendar: cal))
        #expect(!onSecondOccurrence.isDisjoint(with: expandedBooked))
        let literalBooked = SchedulingEngine.occupiedDays([weekly], schedule: plainSchedule, calendar: cal)
        #expect(onSecondOccurrence.isDisjoint(with: literalBooked))
    }

    /// `subtract` edge cases the intra-day window math depends on: no blocks, a block that swallows
    /// the whole base, a block entirely BEFORE it, one in the MIDDLE, and two abutting blocks (whose
    /// zero-length seam must not become a window).
    @Test func subtractHandlesCoveringPrecedingAndAbuttingBlocks() {
        let base = DateInterval(start: TS.day(2026, 6, 2).addingTimeInterval(8 * 3_600),
                                duration: 9 * 3_600)   // 8:00 → 17:00

        #expect(SchedulingEngine.subtract(base, []) == [base])

        let covering = DateInterval(start: base.start.addingTimeInterval(-3_600),
                                    duration: base.duration + 7_200)
        #expect(SchedulingEngine.subtract(base, [covering]).isEmpty)

        let before = DateInterval(start: base.start.addingTimeInterval(-7_200), duration: 3_600)
        #expect(SchedulingEngine.subtract(base, [before]) == [base])

        // One block in the middle splits the base in two, each side exactly what is left of it.
        let middle = DateInterval(start: base.start.addingTimeInterval(2 * 3_600), duration: 2 * 3_600)
        let split = SchedulingEngine.subtract(base, [middle])
        #expect(split.count == 2)
        #expect(close(split[0].duration, 2 * 3_600, eps: 1))   // 8:00–10:00
        #expect(close(split[1].duration, 5 * 3_600, eps: 1))   // 12:00–17:00

        // 10:00–12:00 and 12:00–14:00 abut — the seam between them is zero-length, not a window.
        let first = DateInterval(start: base.start.addingTimeInterval(2 * 3_600), duration: 2 * 3_600)
        let second = DateInterval(start: base.start.addingTimeInterval(4 * 3_600), duration: 2 * 3_600)
        let free = SchedulingEngine.subtract(base, [first, second])
        #expect(free.count == 2)
        #expect(close(free[0].duration, 2 * 3_600, eps: 1))   // 8:00–10:00
        #expect(close(free[1].duration, 3 * 3_600, eps: 1))   // 14:00–17:00
    }

    /// DEFECT (documented): a block that lies entirely AFTER the base produces a "free" interval
    /// that OVERRUNS the base's end (8:00–18:00 for an 8:00–17:00 base), because `subtract` clamps
    /// the block's END to the base but not its START. Unreachable through `openings` today — it
    /// pre-intersects every block with the working window first — so this pins the helper's real
    /// contract rather than a live bug.
    @Test func subtractOverrunsWhenABlockLiesEntirelyAfterTheBase() throws {
        let base = DateInterval(start: TS.day(2026, 6, 2).addingTimeInterval(8 * 3_600),
                                duration: 9 * 3_600)   // 8:00 → 17:00
        let after = DateInterval(start: base.end.addingTimeInterval(3_600), duration: 3_600)
        let free = SchedulingEngine.subtract(base, [after])
        let only = try #require(free.first)
        #expect(free.count == 1)
        #expect(only.start == base.start)
        #expect(only.end > base.end)                                  // DEFECT: overruns the base
        #expect(close(only.duration, 10 * 3_600, eps: 1))
    }

    // MARK: ─────────────────────────────────────────────────────────────────────────────────────
    // MARK: 7. FORMATTING + FALLBACKS
    // MARK: ─────────────────────────────────────────────────────────────────────────────────────

    /// `Opening.durationLabel` across the hour/minute boundaries the banner and gaps list show.
    /// A negative duration carries its sign ONCE, on the front, and splits on the magnitude — a
    /// component-wise split silently dropped the hour (-90 read as "-30 min").
    @Test func durationLabelFormatsEveryBoundary() {
        #expect(Opening.durationLabel(minutes: 0) == "0 min")
        #expect(Opening.durationLabel(minutes: 1) == "1 min")
        #expect(Opening.durationLabel(minutes: 59) == "59 min")
        #expect(Opening.durationLabel(minutes: 60) == "1 hr")
        #expect(Opening.durationLabel(minutes: 61) == "1 hr 1 min")
        #expect(Opening.durationLabel(minutes: 90) == "1 hr 30 min")
        #expect(Opening.durationLabel(minutes: 1_440) == "24 hr")
        #expect(Opening.durationLabel(minutes: -30) == "-30 min")
        #expect(Opening.durationLabel(minutes: -60) == "-1 hr")
        #expect(Opening.durationLabel(minutes: -90) == "-1 hr 30 min")
    }

    /// The capacity text singularizes at exactly one workday and switches shape for a window.
    @Test func openingCapacityTextSingularizesAndSwitchesShape() {
        let start = TS.day(2026, 6, 1)
        let oneDay = Opening(start: start, end: start, span: .fullDays(1))
        let threeDays = Opening(start: start, end: TS.day(2026, 6, 3), span: .fullDays(3))
        let window = Opening(start: start, end: start.addingTimeInterval(5_400),
                             span: .window(DateInterval(start: start, duration: 5_400)))
        #expect(oneDay.capacityText == "Fits 1 workday")
        #expect(threeDays.capacityText == "Fits 3 workdays")
        #expect(window.capacityText == "1 hr 30 min free")
        #expect(oneDay.workdays == 1 && threeDays.workdays == 3 && window.workdays == 1)
        #expect(oneDay.window == nil && window.window != nil)
        #expect(oneDay.id == start)
    }

    /// `timeText` is empty for every shape that has no real window, and populated otherwise.
    @Test func timeTextIsEmptyWithoutARealWindow() {
        let allDay = ScheduledJob(startDate: TS.day(2026, 6, 1))
        #expect(allDay.timeText.isEmpty)

        let noStart = ScheduledJob(startDate: TS.day(2026, 6, 1))
        noStart.isAllDay = false
        noStart.durationMinutes = 60
        #expect(noStart.timeText.isEmpty)                 // startTime nil

        let zeroLength = ScheduledJob(startDate: TS.day(2026, 6, 1))
        zeroLength.isAllDay = false
        zeroLength.startTime = TS.day(2026, 6, 1)
        zeroLength.durationMinutes = 0
        #expect(zeroLength.timeText.isEmpty)

        let negative = ScheduledJob(startDate: TS.day(2026, 6, 1))
        negative.isAllDay = false
        negative.startTime = TS.day(2026, 6, 1)
        negative.durationMinutes = -30
        #expect(negative.timeText.isEmpty)

        let real = ScheduledJob(startDate: TS.day(2026, 6, 1))
        real.isAllDay = false
        real.startTime = cal.date(bySettingHour: 13, minute: 0, second: 0, of: TS.day(2026, 6, 1))
        real.durationMinutes = 120
        #expect(!real.timeText.isEmpty)
        #expect(real.timeText.contains("–"))
    }

    /// A timed job with no window blocks NOTHING — it can't collide with anything, and the day
    /// stays fully open. Worth pinning: it's the shape a half-migrated record has.
    @Test func timedJobWithoutAWindowOccupiesNoIntervals() {
        let job = ScheduledJob(startDate: TS.day(2026, 6, 2), durationDays: 1)
        job.isAllDay = false
        job.durationMinutes = 60   // no startTime
        #expect(job.occupiedIntervals(schedule: plainSchedule, calendar: cal).isEmpty)
        let openings = SchedulingEngine.openings([job], from: TS.day(2026, 6, 2), horizonDays: 1,
                                                 schedule: plainSchedule, calendar: cal)
        #expect(openings.isEmpty)   // a fully-free trailing day is availability, not a bounded gap
    }

    /// Title fallbacks: whitespace / newline-only collapse to "Job"; unicode survives intact.
    @Test func jobDisplayTitleFallsBackAndPreservesUnicode() {
        #expect(ScheduledJob(title: "").displayTitle == "Job")
        #expect(ScheduledJob(title: "   ").displayTitle == "Job")
        #expect(ScheduledJob(title: "\n\t ").displayTitle == "Job")
        #expect(ScheduledJob(title: "  Backsplash  ").displayTitle == "Backsplash")
        #expect(ScheduledJob(title: "Baño principal — azulejo 🧱").displayTitle
                == "Baño principal — azulejo 🧱")
    }

    /// The recurrence summary shapes the detail screen's "Repeats" row uses.
    @Test func recurrenceSummaryCoversEveryShape() {
        let oneOff = ScheduledJob(startDate: TS.day(2026, 6, 1))
        #expect(oneOff.recurrenceSummary.isEmpty)
        #expect(!oneOff.isRecurring)
        #expect(!oneOff.isOpenEndedRecurrence)

        let openEnded = ScheduledJob(startDate: TS.day(2026, 6, 1))
        openEnded.recurrenceFrequency = .weekly
        #expect(openEnded.isOpenEndedRecurrence)
        #expect(openEnded.recurrenceSummary == RecurrenceFrequency.weekly.label)

        let counted = ScheduledJob(startDate: TS.day(2026, 6, 1))
        counted.recurrenceFrequency = .biweekly
        counted.recurrenceCount = 8
        #expect(!counted.isOpenEndedRecurrence)
        #expect(counted.recurrenceSummary.contains("8"))
        #expect(counted.recurrenceSummary.contains("·"))

        let dated = ScheduledJob(startDate: TS.day(2026, 6, 1))
        dated.recurrenceFrequency = .monthly
        dated.recurrenceEndDate = TS.day(2026, 12, 1)
        #expect(!dated.isOpenEndedRecurrence)
        #expect(dated.recurrenceSummary.contains("·"))
        #expect(dated.recurrenceSummary.hasPrefix(RecurrenceFrequency.monthly.label))

        // A count wins over an end date in the summary (both set is only reachable via sync).
        let both = ScheduledJob(startDate: TS.day(2026, 6, 1))
        both.recurrenceFrequency = .weekly
        both.recurrenceCount = 3
        both.recurrenceEndDate = TS.day(2026, 12, 1)
        #expect(both.recurrenceSummary.contains("3"))
    }

    /// The two weekly frequencies differ only by their week interval — the value the expansion walk
    /// steps by.
    @Test func recurrenceFrequencyWeekIntervals() {
        #expect(RecurrenceFrequency.weekly.weekInterval == 1)
        #expect(RecurrenceFrequency.biweekly.weekInterval == 2)
        #expect(RecurrenceFrequency.monthly.weekInterval == 1)
        #expect(RecurrenceFrequency.allCases.count == 3)
        #expect(RecurrenceFrequency(rawValue: "yearly") == nil)
        #expect(RecurrenceFrequency.allCases.allSatisfy { !$0.label.isEmpty })
    }

    /// `ScheduleJobSource` reads through to whichever document backs it, including the blank
    /// fallbacks the sheet's rows check.
    @Test func scheduleJobSourceReadsThroughToItsDocument() {
        let customer = Customer(firstName: "Danielle", lastName: "Carter")
        let estimate = Estimate(number: "EST-0001", jobTitle: "LVP install", customer: customer)
        let invoice = Invoice(number: "INV-0001", jobTitle: "", customer: customer)
        #expect(ScheduleJobSource.estimate(estimate).title == "LVP install")
        #expect(ScheduleJobSource.estimate(estimate).customerName == "Danielle Carter")
        #expect(ScheduleJobSource.invoice(invoice).title.isEmpty)
        #expect(ScheduleJobSource.invoice(invoice).customerName == "Danielle Carter")

        let anonymous = Invoice(number: "INV-0002")
        #expect(ScheduleJobSource.invoice(anonymous).customerName == "Customer")
    }

    // MARK: ─────────────────────────────────────────────────────────────────────────────────────
    // MARK: 8. JOB BILLING + ESTIMATE / CHANGE-ORDER MONEY EDGES
    // MARK: ─────────────────────────────────────────────────────────────────────────────────────

    /// `contractedValue` falls through agreed price → estimate total → invoiced total. An explicit
    /// agreed price of $0 is a REAL answer (a comped job), not "unset" — `agreedPrice` is optional,
    /// so "no price" is already nil. Reporting the linked estimate's total for a deliberately zeroed
    /// job would hold the completion package hostage to invoicing money nobody owes.
    @Test func contractedValueFallsThroughItsChain() throws {
        let container = try TestStore.makeContainer()
        let ctx = container.mainContext

        let estimate = Estimate(number: "EST-0001", jobTitle: "Work")
        ctx.insert(estimate)
        let group = EstimateGroup(name: "Work", sortIndex: 0); group.estimate = estimate; ctx.insert(group)
        let line = EstimateLineItem(name: "Labor", quantity: 1, unit: .job, unitPrice: 800,
                                    kind: .labor, isTaxable: false, sortIndex: 0)
        line.group = group; ctx.insert(line)

        let priced = ScheduledJob(title: "Priced", agreedPrice: 1_500)
        priced.estimate = estimate
        #expect(close(priced.contractedValue, 1_500))

        let comped = ScheduledJob(title: "Comped", agreedPrice: 0)
        comped.estimate = estimate
        #expect(close(comped.contractedValue, 0))     // an explicit $0 wins over the estimate
        #expect(close(comped.remainingToInvoice, 0))
        #expect(comped.isFullyBilledAndCollected)     // so the completion package is available

        let fromEstimate = ScheduledJob(title: "Estimate-priced")
        fromEstimate.estimate = estimate
        #expect(close(fromEstimate.contractedValue, 800))   // nil price → the estimate's total

        let unpriced = ScheduledJob(title: "Unpriced")
        #expect(close(unpriced.contractedValue, 0))
        #expect(close(unpriced.remainingToInvoice, 0))
        #expect(unpriced.isFullyBilledAndCollected)   // a $0 job satisfies the gate vacuously
    }

    /// DRAFT invoices never count toward billed or collected, so a job billed only by a draft still
    /// reads as un-invoiced — the branch that keeps the completion package locked.
    @Test func draftInvoicesDoNotCountTowardJobBilling() throws {
        let container = try TestStore.makeContainer()
        let customer = TS.customer(in: container.mainContext)
        let ctx = container.mainContext
        let job = ScheduledJob(title: "Drafted", agreedPrice: 1_000, status: .completed)
        ctx.insert(job)

        let draft = Invoice(number: "INV-0001", jobTitle: "Drafted", status: .draft, customer: customer)
        ctx.insert(draft)
        let group = InvoiceGroup(name: "Work", sortIndex: 0); group.invoice = draft; ctx.insert(group)
        let line = InvoiceLineItem(name: "Work", quantity: 1, unit: .job, unitPrice: 1_000,
                                   kind: .labor, isTaxable: false, sortIndex: 0)
        line.group = group; ctx.insert(line)
        draft.job = job
        ctx.saveChanges()

        #expect(job.activeBillingInvoices.isEmpty)
        #expect(close(job.invoicedTotal, 0))
        #expect(close(job.remainingToInvoice, 1_000))
        #expect(!job.isFullyBilledAndCollected)
        GLTestHost.render(JobDetailScreen(job: job), container: container)

        // Promoting the draft to sent flips every figure.
        draft.status = .sent
        #expect(close(job.invoicedTotal, 1_000))
        #expect(close(job.remainingToInvoice, 0))
    }

    /// Over-invoicing never produces a negative "left to invoice".
    @Test func remainingToInvoiceNeverGoesNegative() throws {
        let container = try TestStore.makeContainer()
        let customer = TS.customer(in: container.mainContext)
        let ctx = container.mainContext
        let job = ScheduledJob(title: "Over-billed", agreedPrice: 500)
        ctx.insert(job)
        let invoice = Invoice(number: "INV-0001", jobTitle: "Over-billed", status: .sent, customer: customer)
        ctx.insert(invoice)
        let group = InvoiceGroup(name: "Work", sortIndex: 0); group.invoice = invoice; ctx.insert(group)
        let line = InvoiceLineItem(name: "Work", quantity: 1, unit: .job, unitPrice: 900,
                                   kind: .labor, isTaxable: false, sortIndex: 0)
        line.group = group; ctx.insert(line)
        invoice.job = job
        ctx.saveChanges()

        #expect(close(job.invoicedTotal, 900))
        #expect(close(job.remainingToInvoice, 0))
        #expect(job.balanceDue > 0.005)
        #expect(!job.isFullyBilledAndCollected)
    }

    /// The expiry boundary: an estimate is valid through the WHOLE valid-until day, and neither an
    /// accepted nor a declined estimate ever reads as expired.
    @Test func estimateExpiryBoundaryIsInclusiveOfItsLastDay() {
        let today = Estimate(number: "EST-0001", status: .sent)
        today.validUntil = .now
        #expect(!today.isExpired)
        #expect(today.displayStatus == EstimateStatus.sent.label)

        let yesterday = Estimate(number: "EST-0002", status: .sent)
        yesterday.validUntil = .now.addingTimeInterval(-86_400)
        #expect(yesterday.isExpired)

        for decided in [EstimateStatus.accepted, .declined] {
            let settled = Estimate(number: "EST-0003", status: decided)
            settled.validUntil = .now.addingTimeInterval(-365 * 86_400)
            #expect(!settled.isExpired)
            #expect(settled.displayStatus == decided.label)
        }

        let draft = Estimate(number: "EST-0004", status: .draft)
        draft.validUntil = .now.addingTimeInterval(-86_400)
        #expect(draft.isExpired)   // a stale DRAFT expires too
    }

    /// A default estimate's valid-until is 30 days out from its creation date, so a back-dated
    /// estimate is created already expired.
    @Test func backdatedEstimateIsBornExpired() {
        let old = Estimate(number: "EST-0001", createdAt: .now.addingTimeInterval(-90 * 86_400),
                           status: .sent)
        #expect(old.isExpired)
        #expect(old.displayStatus != EstimateStatus.sent.label)
    }

    /// The customer name shown on an estimate falls through name → business → "Customer", and
    /// preserves non-ASCII names verbatim.
    @Test func estimateCustomerDisplayNameFallsThroughAndKeepsUnicode() {
        let whitespaceOnly = Estimate(number: "EST-0001")
        whitespaceOnly.customerFirstName = "   "
        whitespaceOnly.customerLastName = "\n"
        whitespaceOnly.customerBusinessName = " Reed General Contracting "
        #expect(whitespaceOnly.customerDisplayName == "Reed General Contracting")

        let nothing = Estimate(number: "EST-0002")
        nothing.customerBusinessName = "   "
        #expect(nothing.customerDisplayName == "Customer")

        let unicode = Estimate(number: "EST-0003")
        unicode.customerFirstName = "José"
        unicode.customerLastName = "Núñez"
        #expect(unicode.customerDisplayName == "José Núñez")
    }

    /// Recipients prefer the customer's LIVE contact details and fall back to the frozen snapshot —
    /// the gate the estimate detail's Email/Text menu entries read.
    @Test func estimateRecipientsPreferLiveContactOverTheSnapshot() {
        let customer = Customer(firstName: "Marcus", lastName: "Reed",
                                email: "new@example.com", phoneNumber: "(850) 555-1111")
        let estimate = Estimate(number: "EST-0001", customer: customer)
        estimate.customerEmail = "old@example.com"
        estimate.customerPhone = "(850) 555-0000"
        #expect(estimate.recipientEmail == "new@example.com")
        #expect(estimate.recipientPhone == "(850) 555-1111")

        customer.email = "   "
        customer.phoneNumber = ""
        #expect(estimate.recipientEmail == "old@example.com")
        #expect(estimate.recipientPhone == "(850) 555-0000")

        let orphan = Estimate(number: "EST-0002")
        #expect(orphan.recipientEmail.isEmpty)
        #expect(orphan.recipientPhone.isEmpty)
    }

    /// A change order with no items is worth nothing — the state a half-filled form saves into.
    @Test func emptyChangeOrderIsWorthZero() {
        let co = ChangeOrder(number: "CO-0001", title: "Nothing yet", taxRatePercent: 7.5)
        #expect(co.sortedLineItems.isEmpty)
        #expect(close(co.subtotal, 0))
        #expect(close(co.taxAmount, 0))
        #expect(close(co.total, 0))
    }

    /// A TAXABLE credit refunds its tax too — the change order's total goes more negative than its
    /// subtotal, which is the correct paper trail for removed taxable work.
    @Test func taxableCreditRefundsItsTax() {
        let co = ChangeOrder(number: "CO-0001", title: "Removed stone", taxRatePercent: 10)
        let credit = ChangeOrderLineItem(name: "Removed stone", quantity: 1, unit: .job,
                                         unitPrice: -500, isTaxable: true, sortIndex: 0)
        credit.changeOrder = co
        co.lineItems = [credit]
        #expect(close(co.subtotal, -500))
        #expect(close(co.taxAmount, -50))
        #expect(close(co.total, -550))
        #expect(co.total < co.subtotal)
    }

    /// A charge and a credit that cancel out leave a zero-value change order — and zero tax, even
    /// when both lines are taxable.
    @Test func offsettingChangeOrderLinesNetToZero() {
        let co = ChangeOrder(number: "CO-0001", title: "Swap", taxRatePercent: 7.5)
        let add = ChangeOrderLineItem(name: "Added trim", quantity: 1, unit: .job,
                                      unitPrice: 300, isTaxable: true, sortIndex: 0)
        let remove = ChangeOrderLineItem(name: "Removed trim", quantity: 1, unit: .job,
                                         unitPrice: -300, isTaxable: true, sortIndex: 1)
        [add, remove].forEach { $0.changeOrder = co }
        co.lineItems = [add, remove]
        #expect(close(co.subtotal, 0))
        #expect(close(co.taxAmount, 0))
        #expect(close(co.total, 0))
    }

    /// A change order that ADDS scope raises the invoice total by exactly its own total and links
    /// the group it pushed; the credit case moves the total the other way. Pulling both back off —
    /// the credit via a DECLINE (the detail screen removes the items whenever the status leaves
    /// Approved), the addition as-is — restores the untouched invoice exactly and drops the links.
    @Test func applyingAddAndSubtractChangeOrdersMovesTheInvoiceTotal() throws {
        let (container, invoice) = try sentInvoiceStore(taxRatePercent: 10)
        let ctx = container.mainContext
        let original = invoice.total
        #expect(close(original, 1_100))   // $1,000 taxable at 10%
        #expect(invoice.sortedGroups.count == 1)

        let addition = TS.changeOrder(invoice, number: "CO-0001", status: .approved, taxRatePercent: 10,
                                      lines: [(200, true)], in: ctx)
        addition.addItemsToInvoice(using: ctx)
        ctx.saveChanges()
        #expect(addition.appliedToInvoice)
        #expect(addition.invoiceGroup != nil)                 // apply links the pushed group
        #expect(invoice.sortedGroups.count == 2)
        #expect(close(invoice.total, original + 220))
        // Once billed, the order leaves the "approved but unbilled" bucket: the revised total IS
        // the total, and the balance carries the new amount.
        #expect(close(invoice.approvedChangeOrderTotal, 0))
        #expect(close(invoice.revisedTotal, invoice.total))
        #expect(close(invoice.balanceDue, original + 220))

        let credit = TS.changeOrder(invoice, number: "CO-0002", status: .approved, taxRatePercent: 10,
                                    lines: [(-150, true)], in: ctx)
        credit.addItemsToInvoice(using: ctx)
        ctx.saveChanges()
        #expect(close(invoice.total, original + 220 - 165))
        #expect(invoice.sortedGroups.count == 3)

        credit.status = .declined                             // a declined order must not bill
        #expect(credit.removeItemsFromInvoice(using: ctx))
        #expect(addition.removeItemsFromInvoice(using: ctx))
        ctx.saveChanges()
        #expect(!addition.appliedToInvoice && !credit.appliedToInvoice)   // "Add items to invoice" can reappear on re-approve
        #expect(addition.invoiceGroup == nil && credit.invoiceGroup == nil)
        #expect(close(invoice.total, original))
        #expect(invoice.sortedGroups.count == 1)              // only the original work group remains
    }

    /// A change order that isn't APPROVED never reaches the invoice, and applying twice can't
    /// double-bill it.
    @Test func onlyApprovedChangeOrdersApplyAndOnlyOnce() throws {
        let (container, invoice) = try sentInvoiceStore()
        let ctx = container.mainContext
        let original = invoice.total

        for status in [ChangeOrderStatus.pending, .declined] {
            let co = TS.changeOrder(invoice, number: "CO-000\(status.rawValue.count)", status: status,
                                    lines: [(250, false)], in: ctx)
            co.addItemsToInvoice(using: ctx)
            ctx.saveChanges()
            #expect(!co.appliedToInvoice)
            #expect(close(invoice.total, original))
        }

        let approved = TS.changeOrder(invoice, number: "CO-0009", status: .approved, lines: [(250, false)], in: ctx)
        approved.addItemsToInvoice(using: ctx)
        approved.addItemsToInvoice(using: ctx)   // a second tap must be a no-op
        ctx.saveChanges()
        #expect(close(invoice.total, original + 250))
    }

    /// An unapplied approved order shows up in the invoice's REVISED total but not its billed
    /// balance — the "signed but not yet billed" state the detail sheet nudges about.
    @Test func approvedButUnappliedOrderCountsOnlyTowardTheRevisedTotal() throws {
        let (container, invoice) = try sentInvoiceStore()
        let approved = TS.changeOrder(invoice, number: "CO-0001", status: .approved, lines: [(200, false)],
                                      in: container.mainContext)
        container.mainContext.saveChanges()
        #expect(!approved.appliedToInvoice)
        #expect(close(invoice.total, 1_000))
        #expect(close(invoice.approvedChangeOrderTotal, 200))
        #expect(close(invoice.revisedTotal, 1_200))
        #expect(close(invoice.balanceDue, 1_000))   // not billed until it's added
        GLTestHost.render(ChangeOrderDetailSheet(changeOrder: approved), container: container)
    }

    /// Status raw values round-trip, and an unknown raw (a newer build's value synced down) falls
    /// back to the safe default rather than trapping.
    @Test func statusRawValuesRoundTripAndFallBackSafely() {
        let job = ScheduledJob(startDate: .now)
        for status in JobStatus.allCases {
            job.status = status
            #expect(job.status == status)
            #expect(!status.label.isEmpty)
        }
        job.statusRaw = "teleported"
        #expect(job.status == .scheduled)

        let co = ChangeOrder(number: "CO-0001")
        #expect(co.status == .pending)                        // the default for a new order
        for status in ChangeOrderStatus.allCases {
            co.status = status
            #expect(co.status == status)
            #expect(co.statusRaw == status.rawValue)          // the stored raw follows the enum
            #expect(!status.label.isEmpty)
        }
        co.statusRaw = "abandoned"
        #expect(co.status == .pending)

        let attachment = JobAttachment(kind: .document, name: "x", data: nil)
        attachment.kindRaw = "hologram"
        #expect(attachment.kind == .photo)
    }

    // MARK: ─────────────────────────────────────────────────────────────────────────────────────
    // MARK: 9. CALENDAR OCCURRENCES — the real record, one expansion, one name format (QA 2026-10-03)
    // MARK: ─────────────────────────────────────────────────────────────────────────────────────

    /// F59: the Calendar day sheet lists a repeating job's OCCURRENCE copies (never inserted). Tapping
    /// one used to push that copy, and JobDetailScreen (which looks the job up among the stored jobs)
    /// said "This job was removed". The tap now opens the stored series the copy came from.
    @Test func dayDetailsOpensARepeatingJobsRealRecord() throws {
        let container = try TestStore.makeContainer()
        let context = container.mainContext
        let customer = TS.customer(in: context)
        let start = Calendar.current.startOfDay(for: .now).addingTimeInterval(2 * 86_400)
        let weekly = TS.job("Weekly cleaning", start: start, customer: customer,
                            recurrence: .weekly, calendar: .current, in: context)
        let oneOff = TS.job("Backsplash", start: start.addingTimeInterval(86_400), customer: customer,
                            calendar: .current, in: context)
        context.saveChanges()
        let stored = try context.fetch(FetchDescriptor<ScheduledJob>())

        // What the day sheet holds: the expanded occurrences on a day the series lands on.
        let expanded = ScheduleQueries.expanded(stored, in: ScheduleQueries.horizon())
        let occurrences = expanded.filter { $0.title == "Weekly cleaning" }
        #expect(occurrences.count > 1)
        let occurrence = try #require(occurrences.dropFirst().first)
        #expect(!stored.contains { $0.persistentModelID == occurrence.persistentModelID },
                "the occurrence is a throwaway copy, not a stored row")

        // The tap's target: the stored series — the same lookup JobDetailScreen's stillExists runs.
        let opened = ScheduleQueries.storedJob(for: occurrence, among: stored)
        #expect(opened.persistentModelID == weekly.persistentModelID)
        #expect(stored.contains { $0.persistentModelID == opened.persistentModelID },
                "JobDetailScreen would draw 'This job was removed' for anything else")
        // A one-off job is already the stored row.
        #expect(ScheduleQueries.storedJob(for: oneOff, among: stored) === oneOff)
        // A series deleted since the sheet opened is not resurrected: the copy comes back as is,
        // and the detail screen says the job was removed (honest, never a dead-model read).
        let survivors = stored.filter { $0.persistentModelID != weekly.persistentModelID }
        #expect(ScheduleQueries.storedJob(for: occurrence, among: survivors) === occurrence)

        GLTestHost.render(JobDetailScreen(job: opened), container: container)
    }

    /// F90: the Calendar body read `expandedJobs` (a computed property) about 19 times per render —
    /// every read re-materialized every repeating series into new @Model copies. One body
    /// evaluation now expands once, and repeat reads hand back the SAME copies (stable ids, so the
    /// agenda's last-row divider check matches).
    @Test func calendarBodyExpandsRepeatingJobsOnce() throws {
        let container = try TestStore.makeContainer()
        let context = container.mainContext
        let customer = TS.customer(in: context)
        let start = Calendar.current.startOfDay(for: .now).addingTimeInterval(86_400)
        for i in 0..<8 {
            TS.job("Weekly \(i)", start: start.addingTimeInterval(Double(i) * 86_400), customer: customer,
                   recurrence: .weekly, calendar: .current, in: context)
        }
        context.saveChanges()

        let before = ScheduleQueries.expansionCount
        GLTestHost.render(CalendarScreen(), container: container)
        #expect(ScheduleQueries.expansionCount - before == 1, "one expansion per data change, not one per read")
    }

    /// The cache behind the Calendar: same jobs → same copies, no new expansion; an edit that
    /// changes what an occurrence looks like → a fresh expansion.
    @Test func expansionCacheRecomputesOnlyWhenTheJobsChange() throws {
        let context = try DomainFixtures.context()
        let customer = TS.customer(in: context)
        let weekly = TS.job("Weekly", start: TS.day(2026, 9, 14), customer: customer,
                            recurrence: .weekly, in: context)
        context.saveChanges()
        let horizon = ScheduleQueries.horizon(now: TS.day(2026, 9, 14), calendar: cal)
        let cache = ScheduleExpansionCache()

        let before = ScheduleQueries.expansionCount
        let first = cache.expanded([weekly], in: horizon, calendar: cal)
        let second = cache.expanded([weekly], in: horizon, calendar: cal)
        #expect(ScheduleQueries.expansionCount - before == 1)
        #expect(first.map(ObjectIdentifier.init) == second.map(ObjectIdentifier.init), "the same copies")
        #expect(first.last?.persistentModelID == second.last?.persistentModelID)

        weekly.title = "Weekly clean"
        let third = cache.expanded([weekly], in: horizon, calendar: cal)
        #expect(ScheduleQueries.expansionCount - before == 2, "an edit re-expands")
        #expect(third.first?.title == "Weekly clean")

        customer.lastName = "Reid"
        let fourth = cache.expanded([weekly], in: horizon, calendar: cal)
        #expect(ScheduleQueries.expansionCount - before == 3, "a customer rename re-expands")
        #expect(fourth.first?.displayCustomerName == "Reid, Marcus")
    }

    /// L7: a job scheduled from an estimate or an invoice snapshotted "Marcus Reed" while every other
    /// path wrote "Reed, Marcus", so one Jobs list mixed both. The snapshot is now the Customers
    /// list's format, and what a job SHOWS comes from its live customer when it has one.
    @Test func jobsShowTheCustomersListNameFormat() throws {
        let context = try DomainFixtures.context()
        let customer = TS.customer(in: context)
        let estimate = TS.estimate(status: .accepted, in: context)
        estimate.customer = customer
        estimate.customerFirstName = "Marcus"
        estimate.customerLastName = "Reed"
        let invoice = TS.invoice(in: context)
        invoice.customer = customer
        invoice.customerFirstName = "Marcus"
        invoice.customerLastName = "Reed"
        // A source whose customer record is gone: only its own name fields are left.
        let orphanEstimate = TS.estimate(number: "EST-0002", status: .accepted, in: context)
        orphanEstimate.customerFirstName = "Danielle"
        orphanEstimate.customerLastName = "Carter"
        context.saveChanges()

        let fromEstimate = try DomainState.subscribed.run {
            try JobService.schedule(from: .estimate(estimate), start: TS.day(2026, 9, 15), durationDays: 1,
                                    notes: "", in: context)
        }
        let fromInvoice = try DomainState.subscribed.run {
            try JobService.schedule(from: .invoice(invoice), start: TS.day(2026, 9, 16), durationDays: 1,
                                    notes: "", in: context)
        }
        let fromOrphan = try DomainState.subscribed.run {
            try JobService.schedule(from: .estimate(orphanEstimate), start: TS.day(2026, 9, 17), durationDays: 1,
                                    notes: "", in: context)
        }
        #expect(fromEstimate.customerName == "Reed, Marcus")
        #expect(fromInvoice.customerName == "Reed, Marcus")
        #expect(fromOrphan.customerName == "Carter, Danielle")

        // An older booking still holding a "First Last" snapshot shows the live customer's name.
        let legacy = TS.job("Old booking", start: TS.day(2026, 9, 18), customer: customer, in: context)
        legacy.customerName = "Marcus Reed"
        #expect(legacy.displayCustomerName == "Reed, Marcus")
        customer.firstName = "Mark"
        #expect(legacy.displayCustomerName == "Reed, Mark", "follows the live customer")
        // No customer: the snapshot, as stored.
        let walkIn = ScheduledJob(title: "Walk-in", customerName: "Doe, Jane")
        #expect(walkIn.displayCustomerName == "Doe, Jane")

        // Occurrences of a repeating job show the same name as the series.
        legacy.recurrenceFrequency = .weekly
        let copies = SchedulingEngine.expand([legacy], in: ScheduleQueries.horizon(now: TS.day(2026, 9, 14), calendar: cal),
                                             calendar: cal)
        #expect(!copies.isEmpty && copies.allSatisfy { $0.displayCustomerName == "Reed, Mark" })
    }
}
