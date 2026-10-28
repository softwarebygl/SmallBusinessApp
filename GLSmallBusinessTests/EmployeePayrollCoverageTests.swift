//
//  EmployeePayrollCoverageTests.swift
//  GLSmallBusinessTests
//
//  Coverage push for the Employees / payroll area: EmployeeDetailScreen (the single biggest
//  uncovered file), its five pushed sub-screens (Log Hours, Log Bonus, Record Paycheck, All Hours,
//  All Paychecks), EmployeeFormScreen, EmployeeDetailsScreen, EmployeesScreen, and the pay math
//  those screens read (accrued gross, owed status, next payday, YTD, the year-end wage export).
//
//  Two kinds of test live here:
//    1. STATE VARIANTS — each screen hosted through GLTestHost in the branch a plain "does it
//       render" pass never reaches: empty vs populated, hourly vs salary, active vs inactive,
//       photo vs none, past due vs upcoming, over-40 vs not, deleted-out-from-under, light + dark,
//       and accessibility text sizes. Fixtures come from the TS builders with `in: context` so the
//       screens' @Query sees them; the demo dataset comes from TestStore.demoWorld().
//    2. EDGE / ERROR CASES on the pure logic — zero, negative, boundary thresholds, clamped short
//       months, leap years, DST weeks, unicode, and empty inputs.
//
//  The BASE cases of the same math (display names, the four payday frequencies, the model
//  defaults, the PayrollSummary nil paths) live in EmployeeTests; the `matchesSearch` predicates
//  live in RecordSearchTests. Nothing is asserted in two places.
//
//  Parallel-safety note: EmployeePayExport writes fixed filenames into the temp directory
//  ("GL-Employee-Wages-<year>.csv"). EmployeePayExportTests already owns 2025/2026, so every export
//  test here uses a year of its own and never deletes another suite's file.
//

import Testing
import SwiftUI
import SwiftData
import UIKit
@testable import GLSmallBusiness

@Suite(.serialized)
@MainActor
struct EmployeePayrollCoverageTests {

    // MARK: - Clock-relative dates
    //
    // `owedStatus`, `isOverFortyThisWeek` and the screens' past-due cues read the DEVICE clock and
    // calendar, so these two are deliberately `Calendar.current` and relative to `.now` — a fixed
    // `TS.day` cannot stand in for "three days from today". Fixed dates everywhere else use TS.day.

    private func daysFromNow(_ days: Int) -> Date {
        Calendar.current.date(byAdding: .day, value: days, to: .now) ?? .now
    }

    private var thisWeek: DateInterval {
        Calendar.current.dateInterval(of: .weekOfYear, for: .now)
            ?? DateInterval(start: .now, duration: 7 * 86_400)
    }

    /// A real JPEG so `ProfileAvatar` takes its image branch (and the "Remove Photo" button shows).
    private func sampleJPEG() -> Data {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 48, height: 48))
        let image = renderer.image { ctx in
            UIColor.systemTeal.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 48, height: 48))
        }
        return image.jpegData(compressionQuality: 0.8) ?? Data()
    }

    // ======================================================================
    // MARK: - EmployeeDetailScreen state variants
    // ======================================================================

    /// Nothing logged, nothing paid: "No hours logged yet." + "No paychecks recorded yet." + a $0 DUE.
    @Test func detailRendersEmptyHourlyEmployee() throws {
        let store = try TestStore.makeContainer()
        let employee = TS.employee(first: "Blank", last: "Slate", hourlyRate: 0, in: store.mainContext)
        #expect(close(employee.accruedGross, 0))
        #expect(employee.owedStatus == .none)
        GLTestHost.renderBothSchemes(EmployeeDetailScreen(employee: employee), container: store)
    }

    /// A salaried employee with no bonuses takes the "No bonuses yet." copy and the standing
    /// per-period DUE amount (never zero, by design).
    @Test func detailRendersEmptySalariedEmployee() throws {
        let store = try TestStore.makeContainer()
        let employee = TS.employee(first: "Sal", last: "Aried", payType: .salary, hourlyRate: 0,
                                   annualSalary: 62_400, payFrequency: .monthly, in: store.mainContext)
        #expect(close(employee.accruedGross, 5_200))
        GLTestHost.renderBothSchemes(EmployeeDetailScreen(employee: employee), container: store)
    }

    /// More than five entries and more than five paychecks → both "View All" affordances.
    @Test func detailRendersViewAllBranchesWhenOverFiveRecords() throws {
        let store = try TestStore.makeContainer()
        let ctx = store.mainContext
        let employee = TS.employee(first: "Busy", last: "Worker", hourlyRate: 22,
                                   anchorPayday: daysFromNow(2), in: ctx)
        for day in 1...12 {
            TS.logHours(employee, Double(day % 8) + 1, date: daysFromNow(-day), in: ctx)
        }
        for week in 1...7 {
            TS.paycheck(employee, gross: Double(week) * 100, hours: 30,
                        periodStart: daysFromNow(-7 * week - 6),
                        periodEnd: daysFromNow(-7 * week),
                        payDate: daysFromNow(-7 * week), in: ctx)
        }
        #expect(employee.sortedTimeEntries.count == 12)
        #expect(employee.sortedPaychecks.count == 7)
        GLTestHost.renderBothSchemes(EmployeeDetailScreen(employee: employee), container: store)
    }

    /// Over 40 hours in the current week → the orange overtime callout renders.
    @Test func detailRendersOvertimeFlag() throws {
        let store = try TestStore.makeContainer()
        let employee = TS.employee(first: "Over", last: "Time", hourlyRate: 30, in: store.mainContext)
        let inWeek = thisWeek.start.addingTimeInterval(3_600)
        for offset in 0..<5 {
            TS.logHours(employee, 9, date: inWeek.addingTimeInterval(Double(offset) * 86_400),
                        in: store.mainContext)
        }
        #expect(employee.isOverFortyThisWeek)
        GLTestHost.renderBothSchemes(EmployeeDetailScreen(employee: employee), container: store)
    }

    /// A payday that came and went with hours still unpaid → red DUE + the "Past due" text cue.
    @Test func detailRendersPastDueState() throws {
        let store = try TestStore.makeContainer()
        let employee = TS.employee(first: "Late", last: "Pay", hourlyRate: 25, payFrequency: .weekly,
                                   anchorPayday: daysFromNow(-60), in: store.mainContext)
        TS.logHours(employee, 8, date: daysFromNow(-45), in: store.mainContext)
        #expect(employee.owedStatus == .pastDue)
        GLTestHost.renderBothSchemes(EmployeeDetailScreen(employee: employee), container: store)
    }

    /// An inactive (terminated) employee → the "Inactive" capsule in the header.
    @Test func detailRendersInactiveEmployeeCapsule() throws {
        let store = try TestStore.makeContainer()
        let employee = TS.employee(first: "Gone", last: "Fishing", isActive: false, in: store.mainContext)
        TS.paycheck(employee, gross: 900, hours: 36, periodStart: daysFromNow(-40),
                    periodEnd: daysFromNow(-34), payDate: daysFromNow(-33), in: store.mainContext)
        GLTestHost.renderBothSchemes(EmployeeDetailScreen(employee: employee), container: store)
    }

    /// With a profile photo → the avatar's image branch AND the destructive "Remove Photo" button.
    @Test func detailRendersWithAndWithoutProfilePhoto() throws {
        let store = try TestStore.makeContainer()
        let withPhoto = TS.employee(first: "Pic", last: "Tured", in: store.mainContext)
        withPhoto.profileImageData = sampleJPEG()
        let withoutPhoto = TS.employee(first: "No", last: "Photo", in: store.mainContext)
        #expect(withPhoto.profileImageData != nil)
        #expect(withoutPhoto.profileImageData == nil)
        GLTestHost.renderBothSchemes(EmployeeDetailScreen(employee: withPhoto), container: store)
        GLTestHost.render(EmployeeDetailScreen(employee: withoutPhoto), container: store, scheme: .light)
    }

    /// The record is gone from the store the screen is querying (deleted on another device) →
    /// the DeletedRecordView overlay covers the stale numbers.
    @Test func detailRendersDeletedRecordOverlay() throws {
        let owning = try TestStore.makeContainer()
        let elsewhere = try TestStore.makeContainer()   // an empty store: the employee isn't in THIS one
        let employee = TS.employee(first: "Ghost", last: "Record", in: owning.mainContext)
        TS.logHours(employee, 6, in: owning.mainContext)
        GLTestHost.renderBothSchemes(EmployeeDetailScreen(employee: employee), container: elsewhere)
    }

    /// Accessibility text sizes — the payroll card's HStacks are where a large type layout breaks.
    @Test func detailRendersAtAccessibilityTextSizes() throws {
        let store = try TestStore.makeContainer()
        let employee = TS.employee(first: "Big", last: "Type", hourlyRate: 31.75,
                                   anchorPayday: daysFromNow(-30), in: store.mainContext)
        TS.logHours(employee, 7.25, date: daysFromNow(-21), in: store.mainContext).note = "Framing"
        TS.paycheck(employee, gross: 1_234.56, hours: 40, periodStart: daysFromNow(-14),
                    periodEnd: daysFromNow(-8), payDate: daysFromNow(-7), in: store.mainContext)
        GLTestHost.render(EmployeeDetailScreen(employee: employee), container: store,
                          scheme: .light, typeSize: .accessibility1)
        GLTestHost.render(EmployeeDetailScreen(employee: employee), container: store,
                          scheme: .dark, typeSize: .accessibility5)
    }

    /// A salaried employee whose unpaid bonuses stack on top of the standing period amount —
    /// the bonus row formatting (currency, not hours) in the payroll card.
    @Test func detailRendersSalariedBonusRows() throws {
        let store = try TestStore.makeContainer()
        let employee = TS.employee(first: "Bonus", last: "Getter", payType: .salary, hourlyRate: 0,
                                   annualSalary: 78_000, payFrequency: .biweekly, in: store.mainContext)
        let wellDone = TS.logHours(employee, 0, date: daysFromNow(-3), in: store.mainContext)
        wellDone.amount = 500
        wellDone.note = "Job well done"
        let referral = TS.logHours(employee, 0, date: daysFromNow(-10), in: store.mainContext)
        referral.amount = 250
        referral.note = "Referral"
        #expect(close(employee.unpaidBonuses, 750))
        #expect(close(employee.accruedGross, 3_000 + 750))   // $78,000 biweekly = $3,000 a period, plus the bonuses
        GLTestHost.renderBothSchemes(EmployeeDetailScreen(employee: employee), container: store)
    }

    /// Entries tagged with a customer render the secondary job line under the date.
    @Test func detailRendersCustomerTaggedEntries() throws {
        let store = try TestStore.makeContainer()
        let ctx = store.mainContext
        let customer = TS.customer(in: ctx)
        let employee = TS.employee(first: "Tag", last: "Ged", hourlyRate: 26, in: ctx)
        TS.logHours(employee, 8, date: daysFromNow(-1), customer: customer, in: ctx).note = "Tile"
        TS.logHours(employee, 0, date: daysFromNow(-2), customer: customer, in: ctx).amount = 120
        GLTestHost.render(EmployeeDetailScreen(employee: employee), container: store, scheme: .light)
    }

    /// Every demo employee (hourly weekly, hourly biweekly with a recorded check, salaried monthly),
    /// in both schemes.
    @Test func detailRendersEveryDemoEmployee() throws {
        let world = try TestStore.demoWorld()
        #expect(world.employees.count >= 3)
        for employee in world.employees {
            GLTestHost.renderBothSchemes(EmployeeDetailScreen(employee: employee), container: world.container)
        }
    }

    // ======================================================================
    // MARK: - EmployeeDetailsScreen ("More Info")
    // ======================================================================

    @Test func moreInfoRendersEveryFieldCombination() throws {
        let store = try TestStore.makeContainer()
        let ctx = store.mainContext
        let hourlyWithNotes = TS.employee(first: "Hour", last: "Ly", email: "hour.ly@example.com",
                                          phone: "(850) 555-0100", hourlyRate: 27.5, in: ctx)
        hourlyWithNotes.notes = "Prefers early starts."
        let salariedNoNotes = TS.employee(first: "Sal", last: "Ary", email: "sal.ary@example.com",
                                          phone: "(850) 555-0101", payType: .salary, hourlyRate: 0,
                                          annualSalary: 55_000, payFrequency: .semimonthly, in: ctx)
        let blank = TS.employee(first: "", last: "", email: "", phone: "", hourlyRate: 0,
                                isActive: false, in: ctx)
        #expect(blank.listDisplayName == "No name")
        GLTestHost.renderBothSchemes(EmployeeDetailsScreen(employee: hourlyWithNotes), container: store)
        GLTestHost.render(EmployeeDetailsScreen(employee: salariedNoNotes), container: store, scheme: .light)
        GLTestHost.render(EmployeeDetailsScreen(employee: blank), container: store,
                          scheme: .light, typeSize: .accessibility3)
    }

    // ======================================================================
    // MARK: - EmployeeFormScreen
    // ======================================================================

    @Test func formRendersNewEditAndSaveCallbackVariants() throws {
        let store = try TestStore.makeContainer()
        let hourly = TS.employee(first: "Edit", last: "Me", hourlyRate: 33, in: store.mainContext)
        let salaried = TS.employee(first: "Sal", last: "Edit", payType: .salary, hourlyRate: 0,
                                   annualSalary: 91_000, payFrequency: .monthly, isActive: false,
                                   in: store.mainContext)
        salaried.notes = "Left in June."

        GLTestHost.render(EmployeeFormScreen(), container: store, scheme: .light)          // new: Import-from-Contacts section
        GLTestHost.render(EmployeeFormScreen { _ in }, container: store, scheme: .light)   // new + onSave (the iPad add flow)
        GLTestHost.renderBothSchemes(EmployeeFormScreen(editing: hourly), container: store) // edit: hourly-rate field
        GLTestHost.render(EmployeeFormScreen(editing: salaried), container: store, scheme: .light)   // edit: annual-salary field
        GLTestHost.render(EmployeeFormScreen(editing: salaried), container: store,
                          scheme: .light, typeSize: .accessibility2)
    }

    // ======================================================================
    // MARK: - EmployeesScreen (list)
    // ======================================================================

    @Test func employeesListRendersEmptyPopulatedAndInactiveOnly() throws {
        let empty = try TestStore.makeContainer()
        GLTestHost.renderBothSchemes(EmployeesScreen(isTabRoot: true), container: empty)

        let populated = try TestStore.makeContainer()
        let ctx = populated.mainContext
        _ = TS.employee(first: "Aaron", last: "Adams", hourlyRate: 20, anchorPayday: daysFromNow(3), in: ctx)
        let pastDue = TS.employee(first: "Bea", last: "Baker", hourlyRate: 30,
                                  anchorPayday: daysFromNow(-60), in: ctx)
        TS.logHours(pastDue, 10, date: daysFromNow(-45), in: ctx)
        _ = TS.employee(first: "Cal", last: "Carter", payType: .salary, hourlyRate: 0,
                        annualSalary: 48_000, payFrequency: .semimonthly, in: ctx)
        GLTestHost.renderBothSchemes(EmployeesScreen(isTabRoot: true), container: populated)
        GLTestHost.render(EmployeesScreen(isTabRoot: true), container: populated, scheme: .light, typeSize: .accessibility2)
        // Pushed branch (Menu > Documents > Employee Wages): no stack of its own — the host's
        // NavigationStack stands in for the parent's.
        GLTestHost.renderBothSchemes(EmployeesScreen(), container: populated)

        // Inactive-only roster: `hasExportableYear` is false with no active staff and no wages,
        // so the toolbar takes its plain "+" branch instead of the Year-End Report menu.
        let inactiveOnly = try TestStore.makeContainer()
        _ = TS.employee(first: "Dee", last: "Dawson", isActive: false, in: inactiveOnly.mainContext)
        GLTestHost.render(EmployeesScreen(isTabRoot: true), container: inactiveOnly, scheme: .light)
    }

    /// An inactive employee WITH wages in a prior year still makes the year-end report available —
    /// they need a W-2. Exercises the other side of `hasExportableYear`.
    @Test func employeesListRendersExportMenuForPriorYearWages() throws {
        let store = try TestStore.makeContainer()
        // "Last year" as the toolbar itself computes it — the device calendar, on purpose.
        let year = Calendar.current.component(.year, from: .now) - 1
        let paidThenLeft = TS.employee(first: "Prior", last: "Year", isActive: false, in: store.mainContext)
        TS.paycheck(paidThenLeft, gross: 4_200, hours: 160, periodStart: TS.day(year, 3, 1),
                    periodEnd: TS.day(year, 3, 15), payDate: TS.day(year, 3, 16), in: store.mainContext)
        #expect(paidThenLeft.ytdGross(year: year) > 0.005)
        GLTestHost.renderBothSchemes(EmployeesScreen(isTabRoot: true), container: store)
    }

    // ======================================================================
    // MARK: - AllHoursSheet / AllPaychecksSheet
    // ======================================================================

    @Test func allHoursSheetRendersEmptyHourlyAndSalaryVariants() throws {
        let store = try TestStore.makeContainer()
        let ctx = store.mainContext
        let emptyHourly = TS.employee(first: "None", last: "Logged", in: ctx)
        let emptySalary = TS.employee(first: "None", last: "Bonused", payType: .salary, hourlyRate: 0,
                                      annualSalary: 60_000, in: ctx)
        let populated = TS.employee(first: "Lots", last: "Logged", hourlyRate: 21, in: ctx)
        let customer = TS.customer(first: "Nina", last: "Vance", in: ctx)
        for day in 1...9 {
            TS.logHours(populated, Double(day), date: daysFromNow(-day),
                        customer: day.isMultiple(of: 2) ? customer : nil, in: ctx).note = "Day \(day)"
        }
        let salaryWithBonuses = TS.employee(first: "Bo", last: "Nus", payType: .salary, hourlyRate: 0,
                                            annualSalary: 70_000, in: ctx)
        TS.logHours(salaryWithBonuses, 0, date: daysFromNow(-5), in: ctx).amount = 400

        GLTestHost.render(AllHoursSheet(employee: emptyHourly), container: store, scheme: .light)   // "No hours in this range"
        GLTestHost.render(AllHoursSheet(employee: emptySalary), container: store, scheme: .light)   // "No bonuses in this range"
        GLTestHost.renderBothSchemes(AllHoursSheet(employee: populated), container: store)          // rows + hours footer
        GLTestHost.render(AllHoursSheet(employee: salaryWithBonuses), container: store, scheme: .light)   // rows + currency footer
        GLTestHost.render(AllHoursSheet(employee: populated), container: store,
                          scheme: .light, typeSize: .accessibility1)
    }

    @Test func allPaychecksSheetRendersEmptyAndPopulated() throws {
        let store = try TestStore.makeContainer()
        let ctx = store.mainContext
        let none = TS.employee(first: "Never", last: "Paid", in: ctx)
        let paid = TS.employee(first: "Often", last: "Paid", hourlyRate: 24, in: ctx)
        for week in 1...6 {
            TS.paycheck(paid, gross: 24 * 38, hours: 38,
                        periodStart: daysFromNow(-7 * week - 6),
                        periodEnd: daysFromNow(-7 * week),
                        payDate: daysFromNow(-7 * week),
                        method: week.isMultiple(of: 2) ? .cash : .check, in: ctx)
                .note = week == 1 ? "Includes $100.00 bonus." : ""
        }
        // Exactly one paycheck exercises the singular "1 paycheck" footer branch.
        let single = TS.employee(first: "One", last: "Check", in: ctx)
        TS.paycheck(single, gross: 500, periodStart: daysFromNow(-10),
                    periodEnd: daysFromNow(-4), payDate: daysFromNow(-3), in: ctx)

        GLTestHost.render(AllPaychecksSheet(employee: none), container: store, scheme: .light)
        GLTestHost.renderBothSchemes(AllPaychecksSheet(employee: paid), container: store)
        GLTestHost.render(AllPaychecksSheet(employee: single), container: store, scheme: .light)
        GLTestHost.render(AllPaychecksSheet(employee: paid), container: store,
                          scheme: .light, typeSize: .accessibility1)
    }

    // ======================================================================
    // MARK: - LogHoursSheet / LogBonusSheet
    // ======================================================================

    @Test func logHoursSheetRendersEveryEntryModeItCanOpenIn() throws {
        let store = try TestStore.makeContainer()
        let ctx = store.mainContext
        let customer = TS.customer(first: "Owen", last: "Beck", in: ctx)
        let employee = TS.employee(first: "Log", last: "Hours", hourlyRate: 25, in: ctx)

        // New entry → Hours mode, rate pre-filled from the saved rate (no "reset" row).
        GLTestHost.renderBothSchemes(LogHoursSheet(employee: employee, existing: nil), container: store)

        // Editing an hours entry whose snapshot differs from the saved rate → the
        // "Reset to saved rate" row appears.
        let overridden = TS.logHours(employee, 6, date: daysFromNow(-2), rate: 40,
                                     customer: customer, in: ctx)
        overridden.note = "Overtime rate"
        GLTestHost.render(LogHoursSheet(employee: employee, existing: overridden), container: store, scheme: .light)

        // Editing a flat-amount entry → the sheet opens in Dollars mode.
        let dollars = TS.logHours(employee, 0, date: daysFromNow(-4), in: ctx)
        dollars.amount = 275
        GLTestHost.renderBothSchemes(LogHoursSheet(employee: employee, existing: dollars), container: store)

        // A zero-rate employee: Save is disabled in Hours mode (a $0 snapshot would be re-priced
        // by a later raise) — the disabled-toolbar branch.
        let zeroRate = TS.employee(first: "Zero", last: "Rate", hourlyRate: 0, in: ctx)
        GLTestHost.render(LogHoursSheet(employee: zeroRate, existing: nil), container: store, scheme: .light)

        GLTestHost.render(LogHoursSheet(employee: employee, existing: overridden), container: store,
                          scheme: .light, typeSize: .accessibility1)
    }

    @Test func logBonusSheetRendersNewAndEditing() throws {
        let store = try TestStore.makeContainer()
        let employee = TS.employee(first: "Bo", last: "Nus", payType: .salary, hourlyRate: 0,
                                   annualSalary: 84_000, payFrequency: .semimonthly, in: store.mainContext)
        let bonus = TS.logHours(employee, 0, date: daysFromNow(-6), in: store.mainContext)
        bonus.amount = 1_000
        bonus.note = "Q2 bonus"
        GLTestHost.renderBothSchemes(LogBonusSheet(employee: employee, existing: nil), container: store)   // Save disabled at $0
        GLTestHost.renderBothSchemes(LogBonusSheet(employee: employee, existing: bonus), container: store) // + Delete section
        GLTestHost.render(LogBonusSheet(employee: employee, existing: bonus), container: store,
                          scheme: .light, typeSize: .accessibility2)
    }

    // ======================================================================
    // MARK: - RecordPaycheckSheet
    // ======================================================================

    @Test func recordPaycheckSheetRendersOwedFooterVariants() throws {
        let store = try TestStore.makeContainer()
        let ctx = store.mainContext

        // Owed > 0: the sheet pre-fills the full amount → "Full amount entered" / "Pays everything owed."
        let owing = TS.employee(first: "Owed", last: "Money", hourlyRate: 30, in: ctx)
        TS.logHours(owing, 12, date: daysFromNow(-2), in: ctx)
        #expect(close(owing.accruedGross, 360))
        GLTestHost.renderBothSchemes(RecordPaycheckSheet(employee: owing, existing: nil), container: store)

        // Nothing owed: "Nothing is owed right now…" and a disabled Pay-in-full button.
        let settled = TS.employee(first: "All", last: "Square", hourlyRate: 0, in: ctx)
        #expect(close(settled.accruedGross, 0))
        GLTestHost.renderBothSchemes(RecordPaycheckSheet(employee: settled, existing: nil), container: store)

        // Editing a recorded paycheck → the correction-only branch plus the Delete section.
        let check = TS.paycheck(owing, gross: 360, hours: 12, periodStart: daysFromNow(-8),
                                periodEnd: daysFromNow(-2), payDate: daysFromNow(-1), method: .zelle, in: ctx)
        check.note = "Weekly"
        GLTestHost.renderBothSchemes(RecordPaycheckSheet(employee: owing, existing: check), container: store)

        GLTestHost.render(RecordPaycheckSheet(employee: owing, existing: nil), container: store,
                          scheme: .light, typeSize: .accessibility1)
    }

    /// A salaried employee already paid inside the current period → the gold "already recorded
    /// this period" warning. Never blocked, just stated.
    @Test func recordPaycheckSheetWarnsWhenSalaryAlreadyPaidThisPeriod() throws {
        let store = try TestStore.makeContainer()
        let employee = TS.employee(first: "Double", last: "Pay", payType: .salary, hourlyRate: 0,
                                   annualSalary: 52_000, payFrequency: .weekly,
                                   anchorPayday: daysFromNow(3), in: store.mainContext)
        let periodStart = employee.currentPeriodStart()
        TS.paycheck(employee, gross: 1_000, periodStart: periodStart, periodEnd: .now, payDate: .now,
                    in: store.mainContext)
        #expect(employee.sortedPaychecks.first.map { $0.payDate >= periodStart } == true)
        GLTestHost.renderBothSchemes(RecordPaycheckSheet(employee: employee, existing: nil), container: store)
    }

    /// The method defaults to how the LAST check went out — exercises that init lookup with a
    /// non-default method on the newest paycheck.
    @Test func recordPaycheckSheetInheritsLastMethod() throws {
        let store = try TestStore.makeContainer()
        let employee = TS.employee(first: "Meth", last: "Od", hourlyRate: 20, in: store.mainContext)
        TS.paycheck(employee, gross: 200, periodStart: daysFromNow(-20), periodEnd: daysFromNow(-14),
                    payDate: daysFromNow(-14), method: .check, in: store.mainContext)
        TS.paycheck(employee, gross: 300, periodStart: daysFromNow(-13), periodEnd: daysFromNow(-7),
                    payDate: daysFromNow(-7), method: .cash, in: store.mainContext)
        #expect(employee.sortedPaychecks.first?.method == .cash)
        GLTestHost.render(RecordPaycheckSheet(employee: employee, existing: nil), container: store, scheme: .light)
    }

    // ======================================================================
    // MARK: - owedStatus
    // ======================================================================

    @Test func owedStatusIsNoneWhenNothingAccrued() {
        let employee = TS.employee(payType: .hourly, hourlyRate: 25)
        #expect(employee.owedStatus == .none)
    }

    @Test func owedStatusIsUpcomingForHoursBeforeTheNextPayday() {
        let employee = TS.employee(payType: .hourly, hourlyRate: 25,
                                   payFrequency: .weekly, anchorPayday: daysFromNow(3))
        TS.logHours(employee, 8, date: .now)
        #expect(employee.owedStatus == .upcoming)
    }

    /// Payday itself is still "upcoming" — red only starts the day AFTER a missed payday.
    @Test func owedStatusIsUpcomingOnPaydayItself() {
        let employee = TS.employee(payType: .hourly, hourlyRate: 25,
                                   payFrequency: .weekly, anchorPayday: .now)
        TS.logHours(employee, 8, date: .now)
        #expect(employee.nextPayday(onOrAfter: .now) == Calendar.current.startOfDay(for: .now))
        #expect(employee.owedStatus == .upcoming)
    }

    @Test func owedStatusIsPastDueOnceAPaydayPassedUnpaid() {
        let employee = TS.employee(payType: .hourly, hourlyRate: 25,
                                   payFrequency: .weekly, anchorPayday: daysFromNow(-70))
        TS.logHours(employee, 8, date: daysFromNow(-50))
        #expect(employee.owedStatus == .pastDue)
    }

    /// A covered entry can't drag the status past due — it isn't owed any more.
    @Test func owedStatusIgnoresEntriesAlreadyCoveredByAPaycheck() {
        let employee = TS.employee(payType: .hourly, hourlyRate: 25,
                                   payFrequency: .weekly, anchorPayday: daysFromNow(-70))
        let old = TS.logHours(employee, 8, date: daysFromNow(-50))
        let check = TS.paycheck(employee, gross: 200, hours: 8, periodStart: daysFromNow(-56),
                                periodEnd: daysFromNow(-50), payDate: daysFromNow(-49))
        old.paycheck = check
        TS.logHours(employee, 4, date: .now)                 // fresh, not yet due
        #expect(employee.owedStatus == .upcoming)
    }

    /// A salaried worker's standing period amount is ALWAYS the upcoming check — even with stale
    /// hours entries lying around, it never reads as past due.
    @Test func owedStatusSalaryStandingAmountIsNeverPastDue() {
        let employee = TS.employee(payType: .salary, annualSalary: 52_000,
                                   payFrequency: .weekly, anchorPayday: daysFromNow(-70))
        TS.logHours(employee, 40, date: daysFromNow(-60))    // hours don't count for salary
        #expect(close(employee.accruedGross, 1_000))
        #expect(employee.owedStatus == .upcoming)
    }

    /// …but an old unpaid BONUS does make a salaried worker past due, because a bonus is a real
    /// unpaid obligation with a date.
    @Test func owedStatusSalaryGoesPastDueOnAnOldUnpaidBonus() {
        let employee = TS.employee(payType: .salary, annualSalary: 52_000,
                                   payFrequency: .weekly, anchorPayday: daysFromNow(-70))
        let bonus = TS.logHours(employee, 0, date: daysFromNow(-50))
        bonus.amount = 750
        #expect(close(employee.unpaidBonuses, 750))
        #expect(employee.owedStatus == .pastDue)
    }

    /// Sub-penny accruals round to nothing rather than lighting the row up.
    @Test func owedStatusThresholdIsHalfACent() {
        let below = TS.employee(payType: .hourly, hourlyRate: 1)
        TS.logHours(below, 0.004)
        #expect(close(below.accruedGross, 0.004))
        #expect(below.owedStatus == .none)

        let above = TS.employee(payType: .hourly, hourlyRate: 1,
                                payFrequency: .weekly, anchorPayday: daysFromNow(3))
        TS.logHours(above, 0.02)
        #expect(above.owedStatus == .upcoming)
    }

    /// Negative net accrual (a correction entry bigger than the hours logged) reads as nothing
    /// owed rather than as a negative "Owed: -$50" row.
    @Test func owedStatusIsNoneWhenNetAccrualIsNegative() {
        let employee = TS.employee(payType: .hourly, hourlyRate: 20)
        TS.logHours(employee, 2)             // +40
        TS.logHours(employee, -5)            // -100
        #expect(close(employee.accruedGross, -60))
        #expect(employee.owedStatus == .none)
    }

    // ======================================================================
    // MARK: - TimeEntry.grossValue / cost edge cases
    // ======================================================================

    /// A pre-snapshot (or demo-seeded) entry with no rate falls back to the employee's CURRENT rate.
    @Test func grossValueFallsBackToCurrentRateWithoutASnapshot() {
        let employee = TS.employee(payType: .hourly, hourlyRate: 30)
        let entry = TS.logHours(employee, 5, rate: 0)
        #expect(close(entry.rateSnapshot, 0))
        #expect(close(entry.grossValue, 150))     // 5 × the employee's live 30
        #expect(close(entry.cost, 0))             // …but labor COST still honors the (missing) snapshot
    }

    /// An orphaned entry with neither a snapshot nor an employee is worth nothing — no crash.
    @Test func grossValueOfAnOrphanEntryIsZero() {
        let orphan = TimeEntry(date: .now, hours: 8)
        #expect(orphan.employee == nil)
        #expect(close(orphan.grossValue, 0))
    }

    /// A flat amount wins over hours × rate, and the cutoff is exactly half a cent.
    @Test func grossValuePrefersFlatAmountAboveTheHalfCentCutoff() {
        let employee = TS.employee(payType: .hourly, hourlyRate: 10)

        let justAbove = TS.logHours(employee, 8)
        justAbove.amount = 0.006
        #expect(close(justAbove.grossValue, 0.006))     // flat amount wins

        let atCutoff = TS.logHours(employee, 8)
        atCutoff.amount = 0.005
        #expect(close(atCutoff.grossValue, 80))         // NOT > 0.005 → hours × rate

        let negativeAmount = TS.logHours(employee, 8)
        negativeAmount.amount = -50
        #expect(close(negativeAmount.grossValue, 80))   // a negative amount is ignored, not applied
    }

    /// Cost is hours × the SNAPSHOT — a later raise never re-prices it — and it survives
    /// negative corrections and very large values.
    @Test func costHandlesNegativeAndVeryLargeValues() {
        let employee = TS.employee(payType: .hourly, hourlyRate: 25)
        let correction = TS.logHours(employee, -4)
        #expect(close(correction.cost, -100))
        employee.hourlyRate = 40                         // a raise after the fact…
        #expect(close(correction.cost, -100))            // …leaves the snapshot alone

        let huge = TS.logHours(employee, 1_000_000, rate: 1_000)
        #expect(close(huge.cost, 1_000_000_000, eps: 1))
        #expect(huge.cost.isFinite)
    }

    @Test func unpaidBonusesCountsOnlyFlatAmounts() {
        let employee = TS.employee(payType: .salary, annualSalary: 52_000, payFrequency: .weekly)
        TS.logHours(employee, 40)                       // hours: ignored
        let bonus = TS.logHours(employee, 0); bonus.amount = 300
        let paidBonus = TS.logHours(employee, 0); paidBonus.amount = 900
        let check = TS.paycheck(employee, gross: 900, periodStart: TS.day(2026, 1, 1),
                                periodEnd: TS.day(2026, 1, 7), payDate: TS.day(2026, 1, 8))
        paidBonus.paycheck = check
        #expect(close(employee.unpaidBonuses, 300))     // the paid one drops out
        #expect(close(employee.accruedGross, 1_000 + 300))
    }

    /// Hourly accrual, unlike salary, DOES include flat dollar entries.
    @Test func hourlyAccrualMixesHoursAndFlatAmounts() {
        let employee = TS.employee(payType: .hourly, hourlyRate: 20)
        TS.logHours(employee, 10)                       // 200
        let flat = TS.logHours(employee, 0); flat.amount = 75
        #expect(close(employee.unpaidGross, 275))
        #expect(close(employee.accruedGross, 275))
        #expect(close(employee.unpaidHours, 10))        // the flat entry carries no hours
    }

    @Test func zeroRateHourlyEmployeeAccruesNothing() {
        let employee = TS.employee(payType: .hourly, hourlyRate: 0)
        TS.logHours(employee, 40, rate: 0)
        #expect(close(employee.unpaidHours, 40))        // hours were still worked…
        #expect(close(employee.accruedGross, 0))        // …but they're worth nothing at a $0 rate
        #expect(employee.owedStatus == .none)
    }

    // ======================================================================
    // MARK: - PayFrequency / PayType metadata
    // ======================================================================

    /// The case counts, the raw-value round trip, and the rejection of unknown raws. (The labels,
    /// `id`, and the literal `periodsPerYear` constants are EnumTests' rows.)
    @Test func payFrequencyAndPayTypeMetadataIsComplete() {
        #expect(PayFrequency.allCases.count == 4)
        #expect(PayType.allCases.count == 2)
        for frequency in PayFrequency.allCases {
            #expect(PayFrequency(rawValue: frequency.rawValue) == frequency)
        }
        for type in PayType.allCases {
            #expect(PayType(rawValue: type.rawValue) == type)
        }
        #expect(PayFrequency(rawValue: "fortnightly") == nil)
        #expect(PayType(rawValue: "commission") == nil)
    }

    // ======================================================================
    // MARK: - nextPayday edge cases (leap years, DST, distant anchors)
    // ======================================================================

    /// An anchor a decade in the past still lands on a correctly-aligned payday — the jump math,
    /// not the while-loop, does the work.
    @Test func nextPaydayFromADecadeOldAnchorStaysAligned() {
        let anchor = TS.day(2016, 1, 1)                 // a Friday
        let employee = TS.employee(payFrequency: .weekly, anchorPayday: anchor)
        let payday = employee.nextPayday(onOrAfter: TS.day(2026, 6, 17))
        #expect(payday >= TS.day(2026, 6, 17))
        let days = Calendar.current.dateComponents([.day], from: anchor, to: payday).day ?? -1
        #expect(days % 7 == 0)
        #expect(payday < TS.day(2026, 6, 24))           // the FIRST such payday, not a later one
    }

    /// An anchor set far in the FUTURE walks backwards to the correct occurrence.
    @Test func nextPaydayFromAFutureAnchorWalksBackwards() {
        let anchor = TS.day(2030, 1, 4)
        let employee = TS.employee(payFrequency: .biweekly, anchorPayday: anchor)
        let payday = employee.nextPayday(onOrAfter: TS.day(2026, 6, 17))
        #expect(payday >= TS.day(2026, 6, 17))
        #expect(payday < TS.day(2026, 7, 1))
        let days = Calendar.current.dateComponents([.day], from: payday, to: anchor).day ?? -1
        #expect(days % 14 == 0)
    }

    @Test func semimonthlyHandlesLeapFebruary() {
        let employee = TS.employee(payFrequency: .semimonthly, anchorPayday: TS.day(2028, 1, 1))
        #expect(employee.nextPayday(onOrAfter: TS.day(2028, 2, 16)) == TS.day(2028, 2, 29))  // leap year
        #expect(employee.nextPayday(onOrAfter: TS.day(2027, 2, 16)) == TS.day(2027, 2, 28))  // not a leap year
        #expect(employee.nextPayday(onOrAfter: TS.day(2026, 12, 16)) == TS.day(2026, 12, 31))
    }

    /// Semimonthly ignores the anchor entirely — it's always the 15th and month-end.
    @Test func semimonthlyIgnoresTheAnchorDate() {
        let a = TS.employee(payFrequency: .semimonthly, anchorPayday: TS.day(2026, 6, 3))
        let b = TS.employee(payFrequency: .semimonthly, anchorPayday: TS.day(2020, 11, 27))
        #expect(a.nextPayday(onOrAfter: TS.day(2026, 6, 2)) == b.nextPayday(onOrAfter: TS.day(2026, 6, 2)))
        #expect(a.nextPayday(onOrAfter: TS.day(2026, 6, 2)) == TS.day(2026, 6, 15))
    }

    /// The clamp is per month: a short month pulls the payday in, and the next long month has it
    /// back on the 31st — the clamp never sticks.
    @Test func monthlyAnchorOnTheThirtyFirstClampsEveryShortMonth() {
        let employee = TS.employee(payFrequency: .monthly, anchorPayday: TS.day(2026, 1, 31))
        #expect(employee.nextPayday(onOrAfter: TS.day(2026, 2, 1)) == TS.day(2026, 2, 28))   // Feb 2026 has 28 days
        #expect(employee.nextPayday(onOrAfter: TS.day(2026, 3, 1)) == TS.day(2026, 3, 31))   // …and March has its 31st back
        #expect(employee.nextPayday(onOrAfter: TS.day(2026, 4, 1)) == TS.day(2026, 4, 30))
        #expect(employee.nextPayday(onOrAfter: TS.day(2026, 6, 1)) == TS.day(2026, 6, 30))
        #expect(employee.nextPayday(onOrAfter: TS.day(2028, 2, 1)) == TS.day(2028, 2, 29))   // leap
    }

    /// An anchor ON Feb 29 clamps to the 28th in non-leap years and never skips a month.
    @Test func monthlyAnchorOnLeapDayClampsInNonLeapYears() {
        let employee = TS.employee(payFrequency: .monthly, anchorPayday: TS.day(2028, 2, 29))
        #expect(employee.nextPayday(onOrAfter: TS.day(2027, 2, 1)) == TS.day(2027, 2, 28))
        #expect(employee.nextPayday(onOrAfter: TS.day(2027, 3, 1)) == TS.day(2027, 3, 29))
    }

    /// A weekly schedule crossing the US spring-forward transition keeps whole-day spacing
    /// (start-of-day math, not +604 800 s).
    @Test func weeklyPaydaysSurviveTheDSTTransition() {
        let employee = TS.employee(payFrequency: .weekly, anchorPayday: TS.day(2026, 3, 6))
        let afterSpringForward = employee.nextPayday(onOrAfter: TS.day(2026, 3, 9))
        #expect(afterSpringForward == TS.day(2026, 3, 13))
        #expect(Calendar.current.component(.hour, from: afterSpringForward) == 0)
    }

    /// The rolled-forward payday is always start-of-day, whatever time the anchor carried.
    @Test func nextPaydayNormalizesToStartOfDay() {
        let noonAnchor = Calendar.current.date(bySettingHour: 14, minute: 37, second: 12,
                                               of: TS.day(2026, 6, 5)) ?? TS.day(2026, 6, 5)
        let employee = TS.employee(payFrequency: .weekly, anchorPayday: noonAnchor)
        let payday = employee.nextPayday(onOrAfter: TS.day(2026, 6, 20))
        #expect(payday == Calendar.current.startOfDay(for: payday))
    }

    // ======================================================================
    // MARK: - currentPeriodStart
    // ======================================================================

    @Test func currentPeriodStartCoversEveryFrequencyOnPaydayItself() {
        // Asked ON a payday, the period being closed is the one ENDING today.
        let weekly = TS.employee(payFrequency: .weekly, anchorPayday: TS.day(2026, 6, 5))
        #expect(weekly.currentPeriodStart(onOrBefore: TS.day(2026, 6, 5)) == TS.day(2026, 5, 30))

        let biweekly = TS.employee(payFrequency: .biweekly, anchorPayday: TS.day(2026, 6, 5))
        #expect(biweekly.currentPeriodStart(onOrBefore: TS.day(2026, 6, 5)) == TS.day(2026, 5, 23))

        let semimonthly = TS.employee(payFrequency: .semimonthly, anchorPayday: TS.day(2026, 1, 1))
        #expect(semimonthly.currentPeriodStart(onOrBefore: TS.day(2026, 6, 15)) == TS.day(2026, 6, 1))
        #expect(semimonthly.currentPeriodStart(onOrBefore: TS.day(2026, 6, 30)) == TS.day(2026, 6, 16))
    }

    /// DEFECT (documented, not asserted as correct): with a monthly anchor on the 31st, the
    /// previous payday CLAMPS to a short month (Jan 31 → Feb 28), but `currentPeriodStart`
    /// subtracts one calendar month from the NEXT payday instead of re-deriving the previous one.
    /// For a Feb 28 next-payday it returns Jan 29 — three days before the real Feb 1 period start —
    /// so a paycheck dated Jan 29 or 30 is wrongly flagged "already recorded this period".
    @Test func monthlyPeriodStartIsWrongForClampedShortMonths() {
        let employee = TS.employee(payFrequency: .monthly, anchorPayday: TS.day(2026, 1, 31))
        let next = employee.nextPayday(onOrAfter: TS.day(2026, 2, 20))
        #expect(next == TS.day(2026, 2, 28))                       // clamped payday — correct

        let periodStart = employee.currentPeriodStart(onOrBefore: TS.day(2026, 2, 20))
        #expect(periodStart == TS.day(2026, 1, 29))                // current behavior
        #expect(periodStart < TS.day(2026, 2, 1))                  // …which precedes the real start
    }

    /// A well-behaved monthly anchor (mid-month) has no such drift.
    @Test func monthlyPeriodStartIsCorrectForAStableAnchorDay() {
        let employee = TS.employee(payFrequency: .monthly, anchorPayday: TS.day(2026, 6, 15))
        #expect(employee.currentPeriodStart(onOrBefore: TS.day(2026, 6, 20)) == TS.day(2026, 6, 16))
        #expect(employee.currentPeriodStart(onOrBefore: TS.day(2026, 6, 15)) == TS.day(2026, 5, 16))
    }

    // ======================================================================
    // MARK: - YTD + weekly-hours edges
    // ======================================================================

    @Test func ytdTotalsAreZeroForAYearWithNoActivity() {
        let employee = TS.employee()
        TS.paycheck(employee, gross: 1_000, periodStart: TS.day(2026, 1, 1),
                    periodEnd: TS.day(2026, 1, 7), payDate: TS.day(2026, 1, 8))
        TS.logHours(employee, 8, date: TS.day(2026, 1, 8))
        #expect(close(employee.ytdGross(year: 2024), 0))
        #expect(close(employee.ytdHours(year: 2024), 0))
        #expect(close(employee.ytdGross(year: 2099), 0))
    }

    /// Year boundaries are inclusive at both ends — Jan 1 and Dec 31 belong to that year — for
    /// paychecks (by pay date) and hours (by entry date) alike, and neither figure leaks across
    /// the boundary into a neighbouring year.
    @Test func ytdIncludesTheFirstAndLastDayOfTheYear() {
        let employee = TS.employee()
        TS.paycheck(employee, gross: 100, periodStart: TS.day(2026, 1, 1),
                    periodEnd: TS.day(2026, 1, 1), payDate: TS.day(2026, 1, 1))
        TS.paycheck(employee, gross: 200, periodStart: TS.day(2026, 12, 31),
                    periodEnd: TS.day(2026, 12, 31), payDate: TS.day(2026, 12, 31))
        TS.paycheck(employee, gross: 400, periodStart: TS.day(2027, 1, 1),
                    periodEnd: TS.day(2027, 1, 1), payDate: TS.day(2027, 1, 1))
        #expect(close(employee.ytdGross(year: 2026), 300))
        #expect(close(employee.ytdGross(year: 2027), 400))

        TS.logHours(employee, 8, date: TS.day(2025, 12, 31))
        TS.logHours(employee, 6, date: TS.day(2026, 1, 1))
        TS.logHours(employee, 4, date: TS.day(2026, 12, 31))
        TS.logHours(employee, 2, date: TS.day(2027, 1, 1))
        #expect(close(employee.ytdHours(year: 2025), 8))
        #expect(close(employee.ytdHours(year: 2026), 10))
        #expect(close(employee.ytdHours(year: 2027), 2))
    }

    /// A negative correction paycheck reduces the YTD figure rather than being ignored.
    @Test func ytdGrossAbsorbsNegativeCorrections() {
        let employee = TS.employee()
        TS.paycheck(employee, gross: 1_000, periodStart: TS.day(2026, 2, 1),
                    periodEnd: TS.day(2026, 2, 7), payDate: TS.day(2026, 2, 8))
        TS.paycheck(employee, gross: -250, periodStart: TS.day(2026, 2, 8),
                    periodEnd: TS.day(2026, 2, 14), payDate: TS.day(2026, 2, 15))
        #expect(close(employee.ytdGross(year: 2026), 750))
    }

    /// The 40-hour flag is strictly greater-than: exactly 40 is not "over".
    @Test func overtimeFlagBoundaryIsStrictlyAboveForty() {
        let start = thisWeek.start.addingTimeInterval(3_600)

        let exactly = TS.employee()
        TS.logHours(exactly, 40, date: start)
        #expect(close(exactly.hoursInWeek(), 40))
        #expect(!exactly.isOverFortyThisWeek)

        let justOver = TS.employee()
        TS.logHours(justOver, 40.01, date: start)
        #expect(justOver.isOverFortyThisWeek)
    }

    /// DEFECT (documented, low severity): `hoursInWeek` uses `DateInterval.contains`, which is
    /// CLOSED at both ends — so an entry timestamped at exactly the week boundary instant counts
    /// in BOTH the week that ends there and the week that starts there. The instant before and the
    /// week's own start behave correctly. In practice entries are day-dated, so this is only
    /// reachable by an exactly-midnight clock-in.
    @Test func hoursInWeekBoundaryInstantIsCountedInBothWeeks() {
        let week = thisWeek
        let employee = TS.employee()
        TS.logHours(employee, 5, date: week.start)                                  // in — first instant
        TS.logHours(employee, 5, date: week.end.addingTimeInterval(-1))             // in — last second
        TS.logHours(employee, 5, date: week.start.addingTimeInterval(-1))           // out — previous week
        #expect(close(employee.hoursInWeek(), 10))

        // …and the boundary instant itself lands in this week AND the next one.
        let boundary = TS.employee()
        TS.logHours(boundary, 5, date: week.end)
        #expect(close(boundary.hoursInWeek(), 5))                                   // counted here
        #expect(close(boundary.hoursInWeek(of: week.end.addingTimeInterval(60)), 5))// and again next week
    }

    @Test func hoursInWeekNetsOutNegativeCorrections() {
        let start = thisWeek.start.addingTimeInterval(3_600)
        let employee = TS.employee()
        TS.logHours(employee, 45, date: start)
        TS.logHours(employee, -6, date: start.addingTimeInterval(86_400))
        #expect(close(employee.hoursInWeek(), 39))
        #expect(!employee.isOverFortyThisWeek)
    }

    // ======================================================================
    // MARK: - PayrollSummary roll-up edges
    // ======================================================================

    /// Employees on different frequencies whose paydays converge on one date are summed together.
    @Test func payrollSummaryMergesDifferentFrequenciesLandingOnTheSameDay() {
        let reference = TS.day(2026, 6, 1)
        let weekly = TS.employee(first: "W", payType: .salary, annualSalary: 52_000,
                                 payFrequency: .weekly, anchorPayday: TS.day(2026, 6, 5))
        let biweekly = TS.employee(first: "B", payType: .salary, annualSalary: 13_000,
                                   payFrequency: .biweekly, anchorPayday: TS.day(2026, 6, 5))
        let summary = PayrollSummary.nextPayday(for: [weekly, biweekly], on: reference)
        #expect(summary?.date == TS.day(2026, 6, 5))
        #expect(summary?.count == 2)
        #expect(summary != nil && close(summary!.total, 1_000 + 500))
    }

    /// Asked ON a payday, that payday is the answer (not the following one).
    @Test func payrollSummaryReturnsTodayWhenTodayIsPayday() {
        let payday = TS.day(2026, 6, 5)
        let employee = TS.employee(payType: .salary, annualSalary: 52_000,
                                   payFrequency: .weekly, anchorPayday: payday)
        let summary = PayrollSummary.nextPayday(for: [employee], on: payday)
        #expect(summary?.date == payday)
    }

    /// An employee who accrues nothing still counts toward the headcount — the header says how many
    /// people are being paid, and a $0 total is a legitimate answer.
    @Test func payrollSummaryCountsEmployeesWithNothingAccrued() {
        let reference = TS.day(2026, 6, 1)
        let idle = TS.employee(payType: .hourly, hourlyRate: 25,
                               payFrequency: .weekly, anchorPayday: TS.day(2026, 6, 5))
        let summary = PayrollSummary.nextPayday(for: [idle], on: reference)
        #expect(summary?.count == 1)
        #expect(summary != nil && close(summary!.total, 0))
    }

    /// A single inactive employee among actives is excluded from BOTH the date search and the total.
    @Test func payrollSummarySkipsInactiveEvenWhenTheirPaydayIsSooner() {
        let reference = TS.day(2026, 6, 1)
        let inactiveSooner = TS.employee(first: "Soon", payType: .salary, annualSalary: 52_000,
                                         payFrequency: .weekly, anchorPayday: TS.day(2026, 6, 2),
                                         isActive: false)
        let activeLater = TS.employee(first: "Later", payType: .salary, annualSalary: 24_000,
                                      payFrequency: .monthly, anchorPayday: TS.day(2026, 6, 20))
        let summary = PayrollSummary.nextPayday(for: [inactiveSooner, activeLater], on: reference)
        #expect(summary?.date == TS.day(2026, 6, 20))
        #expect(summary?.count == 1)
        #expect(summary != nil && close(summary!.total, 2_000))
    }

    // ======================================================================
    // MARK: - The "View All" sheets' totals + range filtering (pure mirror)
    // ======================================================================

    /// The hours footer sums `hours`, the bonus footer sums `grossValue` — verified through the same
    /// DateRangeFilter the sheets use, including the inclusive custom end day.
    @Test func viewAllTotalsRespectTheSelectedRange() {
        let employee = TS.employee(payType: .hourly, hourlyRate: 20)
        TS.logHours(employee, 8, date: TS.day(2026, 6, 1))
        TS.logHours(employee, 4, date: TS.day(2026, 6, 15))
        TS.logHours(employee, 6, date: TS.day(2025, 12, 30))

        let all = DateRangeFilter.all.apply(to: employee.sortedTimeEntries, date: \.date)
        #expect(close(all.reduce(0) { $0 + $1.hours }, 18))

        let thisYear = DateRangeFilter.year(2026).apply(to: employee.sortedTimeEntries, date: \.date)
        #expect(close(thisYear.reduce(0) { $0 + $1.hours }, 12))
        #expect(close(thisYear.reduce(0) { $0 + $1.grossValue }, 240))

        // Custom range: the END day is inclusive.
        let inclusive = DateRangeFilter.custom(from: TS.day(2026, 6, 1), to: TS.day(2026, 6, 15))
            .apply(to: employee.sortedTimeEntries, date: \.date)
        #expect(inclusive.count == 2)

        // Backwards endpoints are treated as the same range, not as "nothing here".
        let reversed = DateRangeFilter.custom(from: TS.day(2026, 6, 15), to: TS.day(2026, 6, 1))
            .apply(to: employee.sortedTimeEntries, date: \.date)
        #expect(reversed.count == 2)

        // A range with no entries → the sheet's empty-state branch.
        let none = DateRangeFilter.custom(from: TS.day(2024, 1, 1), to: TS.day(2024, 1, 31))
            .apply(to: employee.sortedTimeEntries, date: \.date)
        #expect(none.isEmpty)
    }

    @Test func viewAllPaycheckTotalsRespectTheSelectedRange() {
        let employee = TS.employee()
        TS.paycheck(employee, gross: 500, periodStart: TS.day(2026, 1, 1),
                    periodEnd: TS.day(2026, 1, 7), payDate: TS.day(2026, 1, 8))
        TS.paycheck(employee, gross: 700, periodStart: TS.day(2025, 12, 1),
                    periodEnd: TS.day(2025, 12, 7), payDate: TS.day(2025, 12, 8))
        let thisYear = DateRangeFilter.year(2026).apply(to: employee.sortedPaychecks, date: \.payDate)
        #expect(thisYear.count == 1)
        #expect(close(thisYear.reduce(0) { $0 + $1.grossAmount }, 500))
    }

    // ======================================================================
    // MARK: - Year-end wage export edge cases (unique years — see the file header)
    // ======================================================================

    private func readFile(_ url: URL) -> String { (try? String(contentsOf: url, encoding: .utf8)) ?? "" }
    private func wagesCSV(_ files: [URL]) -> String {
        files.first { $0.lastPathComponent.contains("Wages") }.map(readFile) ?? ""
    }
    private func ledgerCSV(_ files: [URL]) -> String {
        files.first { $0.lastPathComponent.contains("Paychecks") }.map(readFile) ?? ""
    }

    /// No employees at all still produces two well-formed, header-only CSVs — never a nil share.
    @Test func exportWithNoEmployeesStillWritesBothHeaders() {
        let files = EmployeePayExport.files(employees: [], year: 2017, business: nil)
        #expect(files.count == 2)
        let wages = wagesCSV(files)
        let ledger = ledgerCSV(files)
        #expect(wages.contains("Employee,Pay type,Rate,Gross paid 2017,Hours 2017,Paychecks 2017"))
        #expect(ledger.contains("Employee,Paid on,Period start,Period end,Gross,Hours,Method,Note"))
        // Header row only (the BOM rides on the first line).
        #expect(wages.split(separator: "\n").count == 1)
        #expect(ledger.split(separator: "\n").count == 1)
    }

    /// An unnamed employee falls back to "No name" instead of writing an empty leading field.
    @Test func exportFallsBackToListDisplayNameWhenTheNameIsBlank() {
        let nameless = TS.employee(first: "", last: "")
        TS.paycheck(nameless, gross: 300, periodStart: TS.day(2018, 5, 1),
                    periodEnd: TS.day(2018, 5, 7), payDate: TS.day(2018, 5, 8))
        let files = EmployeePayExport.files(employees: [nameless], year: 2018, business: nil)
        #expect(wagesCSV(files).contains("No name"))
        #expect(ledgerCSV(files).contains("No name"))
    }

    /// Notes with newlines / quotes / commas stay in ONE CSV row (RFC-4180 quoting), so the
    /// accountant's spreadsheet doesn't gain phantom rows.
    @Test func exportQuotesMultilineAndQuotedNotes() {
        let employee = TS.employee(first: "Note", last: "Heavy")
        TS.paycheck(employee, gross: 900, periodStart: TS.day(2019, 4, 1),
                    periodEnd: TS.day(2019, 4, 7), payDate: TS.day(2019, 4, 8))
            .note = "Line one\nLine \"two\", with a comma"
        let ledger = ledgerCSV(EmployeePayExport.files(employees: [employee], year: 2019, business: nil))
        #expect(ledger.contains("\"Line one\nLine \"\"two\"\", with a comma\""))
        // Header + one logical record — the embedded newline is inside quotes, not a new row.
        #expect(ledger.contains("Note Heavy"))
    }

    /// Unicode names survive the round-trip (UTF-8 with a BOM for Excel-on-Windows).
    @Test func exportPreservesUnicodeNames() {
        let employee = TS.employee(first: "José", last: "Núñez-Ólafsdóttir")
        TS.paycheck(employee, gross: 1_500, periodStart: TS.day(2020, 7, 1),
                    periodEnd: TS.day(2020, 7, 7), payDate: TS.day(2020, 7, 8))
        let files = EmployeePayExport.files(employees: [employee], year: 2020, business: nil)
        let wages = wagesCSV(files)
        #expect(wages.contains("José Núñez-Ólafsdóttir"))
        // The BOM is checked on the RAW bytes: String(contentsOf:) silently strips it on read.
        let url = files.first { $0.lastPathComponent.contains("Wages") }
        let raw = url.flatMap { try? Data(contentsOf: $0) } ?? Data()
        #expect(raw.starts(with: [0xEF, 0xBB, 0xBF]))              // UTF-8 BOM for Excel-on-Windows
    }

    /// Negative and very large figures format without crashing or going exponential.
    @Test func exportFormatsNegativeAndVeryLargeAmounts() {
        let employee = TS.employee(first: "Big", last: "Numbers", payType: .salary,
                                   annualSalary: 9_876_543.21, payFrequency: .monthly)
        TS.paycheck(employee, gross: -125.5, hours: -4, periodStart: TS.day(2021, 2, 1),
                    periodEnd: TS.day(2021, 2, 7), payDate: TS.day(2021, 2, 8))
        TS.paycheck(employee, gross: 1_000_000, hours: 0, periodStart: TS.day(2021, 3, 1),
                    periodEnd: TS.day(2021, 3, 7), payDate: TS.day(2021, 3, 8))
        let files = EmployeePayExport.files(employees: [employee], year: 2021, business: nil)
        let wages = wagesCSV(files)
        #expect(wages.contains("9876543.21/yr"))
        #expect(wages.contains("999874.50"))                       // net gross, plainly formatted
        #expect(!wages.contains("e+"))
        let ledger = ledgerCSV(files)
        #expect(ledger.contains("'-125.50"))                       // leading "-" neutralized for Excel
        #expect(ledger.contains("1000000.00"))
    }

    /// An active employee with no wages in the chosen year still gets a row (zeros) — payroll
    /// services want the whole roster, not just the paid part of it.
    @Test func exportIncludesActiveEmployeesWithNoWagesThatYear() {
        let active = TS.employee(first: "Zero", last: "Wages")
        let files = EmployeePayExport.files(employees: [active], year: 2022, business: nil)
        let wages = wagesCSV(files)
        #expect(wages.contains("Zero Wages"))
        #expect(wages.contains("0.00"))
        // …but the ledger has no rows to write for them.
        #expect(ledgerCSV(files).split(separator: "\n").count == 1)
    }

    /// The wage summary sorts by list name (Last, First), case-insensitively.
    @Test func exportSortsEmployeesByListName() {
        let files = EmployeePayExport.files(
            employees: [TS.employee(first: "Zed", last: "zulu"),
                        TS.employee(first: "Amy", last: "Able"),
                        TS.employee(first: "Moe", last: "Mid")],
            year: 2023, business: nil)
        let lines = wagesCSV(files).split(separator: "\n").map(String.init)
        let able = lines.firstIndex { $0.contains("Able") }
        let mid = lines.firstIndex { $0.contains("Mid") }
        let zulu = lines.firstIndex { $0.contains("zulu") }
        #expect(able != nil && mid != nil && zulu != nil)
        #expect(able! < mid! && mid! < zulu!)
    }

    // ======================================================================
    // MARK: - Model defaults / relationship-nil defenses specific to payroll
    // ======================================================================

    /// A brand-new @Model has nil collections, not [] — every computed that walks them must read
    /// as empty / zero rather than trap, for the salaried case (a standing amount) and the hourly
    /// default (nothing owed) alike.
    @Test func paycheckAndEntryRelationshipsSurviveNilCollections() {
        let employee = Employee(firstName: "Nil", lastName: "Safe",
                                payType: .salary, annualSalary: 52_000, payFrequency: .weekly)
        #expect(employee.timeEntries == nil && employee.paychecks == nil)
        #expect(employee.sortedTimeEntries.isEmpty && employee.sortedPaychecks.isEmpty)
        #expect(close(employee.unpaidHours, 0))
        #expect(close(employee.unpaidGross, 0))
        #expect(close(employee.unpaidBonuses, 0))
        #expect(close(employee.accruedGross, 1_000))     // the standing salary amount still computes
        #expect(employee.owedStatus == .upcoming)
        #expect(PayrollSummary.nextPayday(for: [employee]) != nil)
        #expect(close(employee.ytdGross(year: 2026), 0) && close(employee.ytdHours(year: 2026), 0))
        #expect(close(employee.hoursInWeek(of: TS.day(2026, 6, 17)), 0))
        #expect(!employee.isOverFortyThisWeek)

        let hourly = Employee()                          // the model's own defaults: hourly, $0
        #expect(hourly.timeEntries == nil && hourly.paychecks == nil)
        #expect(close(hourly.accruedGross, 0))
        #expect(hourly.owedStatus == .none)

        let check = Paycheck()
        #expect(check.coveredEntries == nil)
    }

    /// Deleting a paycheck nullifies the link, so the hours it covered become owed again.
    @Test func clearingAPaycheckLinkReturnsHoursToOwed() {
        let employee = TS.employee(payType: .hourly, hourlyRate: 30,
                                   payFrequency: .weekly, anchorPayday: daysFromNow(3))
        let entry = TS.logHours(employee, 10, date: .now)
        let check = TS.paycheck(employee, gross: 300, hours: 10, periodStart: daysFromNow(-6),
                                periodEnd: .now, payDate: .now)
        entry.paycheck = check
        #expect(close(employee.accruedGross, 0))
        #expect(employee.owedStatus == .none)

        entry.paycheck = nil                             // the nullify delete rule's effect
        #expect(close(employee.accruedGross, 300))
        #expect(employee.owedStatus == .upcoming)
    }
}
