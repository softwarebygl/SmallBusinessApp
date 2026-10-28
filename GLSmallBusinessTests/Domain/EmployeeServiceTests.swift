//
//  EmployeeServiceTests.swift
//  GLSmallBusinessTests — Domain
//
//  The employee and payroll save path shared by the Employee form, the Log Hours / Log Bonus /
//  Pay Now sheets and the assistant. The paycheck rules are pinned case by case because they
//  moved out of a View: FIFO settlement, the partial-entry split (amount and hours), salary
//  settling bonuses only, the bonus line in the note, and the pay-period start.
//

import Foundation
import SwiftData
import Testing
@testable import GLSmallBusiness

@MainActor
@Suite(.serialized)
struct EmployeeServiceTests {

    private let day1 = TS.day(2026, 9, 1)
    private let day2 = TS.day(2026, 9, 2)
    private let day3 = TS.day(2026, 9, 3)
    private let payday = TS.day(2026, 9, 10)

    // MARK: The employee

    @Test func createTrimsSavesAndIsCapped() throws {
        let context = try DomainFixtures.context()
        let draft = EmployeeDraft(firstName: " Ana ", lastName: "Ruiz", email: " ana@x.com ",
                                  payType: .hourly, hourlyRate: 22.5, notes: " crew lead ")
        let ana = try DomainState.neverSubscribed.run { try EmployeeService.create(draft, in: context) }
        #expect(ana.firstName == "Ana" && ana.email == "ana@x.com" && ana.notes == "crew lead")
        #expect(ana.hourlyRate == 22.5)
        #expect(ana.syncID != nil && !context.hasChanges)

        _ = try DomainState.neverSubscribed.run { try EmployeeService.create(EmployeeDraft(firstName: "Bo"), in: context) }
        #expect(DomainState.neverSubscribed.run { domainError { try EmployeeService.create(EmployeeDraft(firstName: "Cy"), in: context) } }
                == .freeLimitReached(operation: "saveEmployee"))
        #expect(try context.fetchCount(FetchDescriptor<Employee>()) == FreeTier.employees)
    }

    @Test func createAndUpdateValidation() throws {
        let context = try DomainFixtures.context()
        DomainState.subscribed.run {
            #expect(domainError { try EmployeeService.create(EmployeeDraft(email: "a@b.c"), in: context) } == .personNameRequired)
            #expect(domainError { try EmployeeService.create(EmployeeDraft(firstName: "A", hourlyRate: -1), in: context) } == .negativeValue)
            #expect(domainError { try EmployeeService.create(EmployeeDraft(firstName: "A", annualSalary: .nan), in: context) } == .negativeValue)
        }
        #expect(try context.fetchCount(FetchDescriptor<Employee>()) == 0)
    }

    @Test func updateWritesOnlyChangesAndKeepsBothRates() throws {
        let context = try DomainFixtures.context()
        let employee = TS.employee(hourlyRate: 25, in: context)
        context.saveChanges()
        let stamp = try #require(employee.updatedAt)
        try DomainState.subscribed.run {
            try EmployeeService.update(employee, with: EmployeeDraft(employee), in: context)
            #expect(employee.updatedAt == stamp, "an unchanged edit is not a write")
            var edit = EmployeeDraft(employee)
            edit.payType = .salary
            edit.annualSalary = 52_000
            edit.isActive = false
            try EmployeeService.update(employee, with: edit, photo: Data([4]), in: context)
        }
        #expect(employee.payType == .salary && employee.annualSalary == 52_000)
        #expect(employee.hourlyRate == 25, "the other rate is kept, as the form always has")
        #expect(!employee.isActive && employee.profileImageData == Data([4]))
        #expect(!context.hasChanges)
        #expect(DomainState.lapsed.run { domainError { try EmployeeService.setPhoto(nil, for: employee, in: context) } }
                == .readOnly(operation: "saveEmployee", lapsed: true))
        #expect(employee.profileImageData == Data([4]))
    }

    // MARK: Hours and bonuses

    @Test func logTimeInEachMode() throws {
        let context = try DomainFixtures.context()
        let employee = TS.employee(hourlyRate: 25, in: context)
        let customer = TS.customer(in: context)
        let start = day1.addingTimeInterval(22 * 3600)   // 10 pm → 6 am, overnight
        try DomainState.subscribed.run {
            let range = try EmployeeService.logTime(.range(start: start, end: start.addingTimeInterval(8 * 3600), rate: 30),
                                                    customer: customer, note: " night pour ",
                                                    for: employee, in: context)
            #expect(range.hours == 8 && range.date == start && range.rateSnapshot == 30 && range.amount == 0)
            #expect(range.customer === customer && range.note == "night pour")
            #expect(range.syncID != nil && !context.hasChanges)

            let hours = try EmployeeService.logTime(.hours(6, on: day2, rate: 25), customer: nil, note: "",
                                                    for: employee, in: context)
            #expect(hours.hours == 6 && hours.grossValue == 150)

            // Editing to Dollars clears hours and the rate snapshot, and the customer tag.
            try EmployeeService.logTime(.dollars(80, on: day3), customer: nil, note: "flat",
                                        for: employee, editing: range, in: context)
            #expect(range.hours == 0 && range.amount == 80 && range.rateSnapshot == 0 && range.customer == nil)
            #expect(range.date == day3)
        }
        #expect(employee.sortedTimeEntries.count == 2)
        #expect(close(employee.unpaidGross, 230))
    }

    @Test func logTimeRefusals() throws {
        let context = try DomainFixtures.context()
        let employee = TS.employee(in: context)
        let other = TS.employee(first: "Other", in: context)
        let othersEntry = TS.logHours(other, 4, date: day1, in: context)
        context.saveChanges()
        DomainState.subscribed.run {
            #expect(domainError { try EmployeeService.logTime(.hours(0, on: day1, rate: 25), customer: nil, note: "", for: employee, in: context) }
                    == .hoursAndRateRequired)
            #expect(domainError { try EmployeeService.logTime(.dollars(-5, on: day1), customer: nil, note: "", for: employee, in: context) }
                    == .negativeValue)
            #expect(domainError { try EmployeeService.logTime(.hours(2, on: day1, rate: 25), customer: nil, note: "", for: employee, editing: othersEntry, in: context) }
                    == .recordNotFound, "an entry is edited only through its own employee")
            #expect(domainError { try EmployeeService.logBonus(0, on: day1, note: "", for: employee, in: context) } == .amountRequired)
        }
        #expect(DomainState.offline.run {
            domainError { try EmployeeService.logTime(.hours(2, on: day1, rate: 25), customer: nil, note: "", for: employee, in: context) }
        } == .readOnly(operation: "logHours", lapsed: false))
        #expect(employee.sortedTimeEntries.isEmpty)
        #expect(othersEntry.hours == 4)
    }

    @Test func bonusCreateEditAndDelete() throws {
        let context = try DomainFixtures.context()
        let employee = TS.employee(payType: .salary, hourlyRate: 0, annualSalary: 52_000, in: context)
        let customer = TS.customer(in: context)
        try DomainState.subscribed.run {
            let bonus = try EmployeeService.logBonus(250, on: day1, note: " holiday ", for: employee, in: context)
            #expect(bonus.amount == 250 && bonus.hours == 0 && bonus.rateSnapshot == 0 && bonus.note == "holiday")
            bonus.customer = customer
            context.saveChanges()
            try EmployeeService.logBonus(300, on: day2, note: "", for: employee, editing: bonus, in: context)
            #expect(bonus.amount == 300 && bonus.date == day2)
            #expect(bonus.customer === customer, "the bonus sheet never touches the customer tag")
            #expect(DomainState.lapsed.run { domainError { try DeletionService.delete([.timeEntry(bonus)], in: context) } }
                    == .readOnly(operation: "deleteHours", lapsed: true))
        }
        try DomainState.subscribed.run {
            let bonus = try #require(employee.sortedTimeEntries.first)
            try DeletionService.delete([.timeEntry(bonus)], in: context)
        }
        #expect(employee.sortedTimeEntries.isEmpty)
        #expect(!context.hasChanges, "the delete (and its outbox row) is saved")
    }

    // MARK: Paychecks — settlement

    @Test func payingSettlesOldestFirstAndSplitsAnHoursEntry() throws {
        let context = try DomainFixtures.context()
        let employee = TS.employee(hourlyRate: 25, hireDate: TS.day(2026, 1, 1), in: context)
        let e1 = TS.logHours(employee, 8, date: day1, in: context)            // $200
        let e2 = TS.logHours(employee, 8, date: day2, in: context)            // $200
        let e3 = TS.logHours(employee, 4, date: day3, rate: 30, in: context)  // $120
        context.saveChanges()

        let check = try DomainState.subscribed.run {
            try EmployeeService.recordPaycheck(for: employee, amount: 300, payDate: payday,
                                               method: .zelle, note: " thanks ", in: context)
        }
        #expect(check.grossAmount == 300)
        #expect(check.hoursPaid == 12, "8 settled + a 4-hour paid slice of the second day")
        #expect(check.method == .zelle && check.note == "thanks")
        #expect(check.payPeriodStart == day1 && check.payPeriodEnd == payday && check.payDate == payday)
        #expect(e1.paycheck === check)
        #expect(e2.paycheck == nil && e2.hours == 4, "the rest of the split day stays owed")
        #expect(e3.paycheck == nil)
        let slice = try #require(check.coveredEntries?.first { $0 !== e1 })
        #expect(slice.hours == 4 && slice.rateSnapshot == 25 && slice.date == day2)
        #expect(close(employee.unpaidGross, 220), "owed drops by exactly what was paid")
        #expect(check.syncID != nil && slice.syncID != nil && !context.hasChanges)
    }

    @Test func aFlatEntrySplitsByAmount() throws {
        let context = try DomainFixtures.context()
        let employee = TS.employee(hourlyRate: 25, in: context)
        let flat = TS.logHours(employee, 0, date: day1, in: context)
        flat.amount = 300
        flat.note = "materials run"
        context.saveChanges()
        let check = try DomainState.subscribed.run {
            try EmployeeService.recordPaycheck(for: employee, amount: 120, payDate: payday,
                                               method: .cash, note: "", in: context)
        }
        #expect(flat.amount == 180 && flat.paycheck == nil)
        let slice = try #require(check.coveredEntries?.first)
        #expect(slice.amount == 120 && slice.note == "materials run" && slice.date == day1)
        #expect(check.hoursPaid == 0)
    }

    @Test func overpayingRidesOnTheGrossAndBonusIsNamedInTheNote() throws {
        let context = try DomainFixtures.context()
        let employee = TS.employee(hourlyRate: 25, in: context)
        TS.logHours(employee, 8, date: day1, in: context)
        context.saveChanges()
        let check = try DomainState.subscribed.run {
            try EmployeeService.recordPaycheck(for: employee, amount: 250, bonus: 40, payDate: payday,
                                               method: .check, note: "Week 1", in: context)
        }
        let bonusText = "Includes \(40.0.formatted(.currency(code: "USD"))) bonus."
        #expect(check.grossAmount == 290)
        #expect(check.note == "Week 1\n\(bonusText)")
        #expect(employee.unpaidGross == 0)

        let bonusOnly = try DomainState.subscribed.run {
            try EmployeeService.recordPaycheck(for: employee, amount: 0, bonus: 15, payDate: payday,
                                               method: .check, note: "", in: context)
        }
        #expect(bonusOnly.grossAmount == 15 && bonusOnly.note == "Includes \(15.0.formatted(.currency(code: "USD"))) bonus.")
    }

    @Test func salarySettlesOnlyBonuses() throws {
        let context = try DomainFixtures.context()
        let employee = TS.employee(payType: .salary, hourlyRate: 0, annualSalary: 52_000, in: context)
        let stray = TS.logHours(employee, 5, date: day1, rate: 0, in: context)
        let bonus = TS.logHours(employee, 0, date: day2, in: context)
        bonus.amount = 100
        context.saveChanges()
        let check = try DomainState.subscribed.run {
            try EmployeeService.recordPaycheck(for: employee, amount: 1_100, payDate: payday,
                                               method: .transfer, note: "", in: context)
        }
        #expect(bonus.paycheck === check)
        #expect(stray.paycheck == nil, "salary never settles stray hours")
        #expect(check.grossAmount == 1_100 && check.payPeriodStart == day2)
    }

    @Test func periodStartFallsBackToLastPeriodThenHireDate() throws {
        let context = try DomainFixtures.context()
        let hired = TS.day(2026, 3, 2)
        let employee = TS.employee(payType: .salary, annualSalary: 52_000, hireDate: hired, in: context)
        context.saveChanges()
        let first = try DomainState.subscribed.run {
            try EmployeeService.recordPaycheck(for: employee, amount: 1_000, payDate: TS.day(2026, 3, 13),
                                               method: .check, note: "", in: context)
        }
        #expect(first.payPeriodStart == hired, "nothing settled, no prior period → hire date")
        let second = try DomainState.subscribed.run {
            try EmployeeService.recordPaycheck(for: employee, amount: 1_000, payDate: TS.day(2026, 3, 27),
                                               method: .check, note: "", in: context)
        }
        // The day after the last covered period (the service adds a day in Calendar.current).
        #expect(second.payPeriodStart == Calendar.current.date(byAdding: .day, value: 1, to: TS.day(2026, 3, 13)))
        // Never after the pay date.
        let early = try DomainState.subscribed.run {
            try EmployeeService.recordPaycheck(for: employee, amount: 10, payDate: TS.day(2026, 3, 1),
                                               method: .check, note: "", in: context)
        }
        #expect(early.payPeriodStart == TS.day(2026, 3, 1))
    }

    @Test func recordPaycheckRefusalsWriteNothing() throws {
        let context = try DomainFixtures.context()
        let employee = TS.employee(hourlyRate: 25, in: context)
        let entry = TS.logHours(employee, 8, date: day1, in: context)
        context.saveChanges()
        func pay(_ amount: Double, bonus: Double = 0) -> DomainError? {
            domainError {
                try EmployeeService.recordPaycheck(for: employee, amount: amount, bonus: bonus,
                                                   payDate: payday, method: .check, note: "", in: context)
            }
        }
        #expect(DomainState.lapsed.run { pay(100) } == .readOnly(operation: "recordPaycheck", lapsed: true))
        #expect(DomainState.offline.run { pay(100) } == .readOnly(operation: "recordPaycheck", lapsed: false))
        #expect(DomainState.subscribed.run { pay(0) } == .amountRequired)
        #expect(DomainState.subscribed.run { pay(-10) } == .negativeValue)
        #expect(DomainState.subscribed.run { pay(10, bonus: -1) } == .negativeValue)
        #expect(entry.paycheck == nil && entry.hours == 8)
        #expect(employee.sortedPaychecks.isEmpty)
        #expect(!context.hasChanges)
    }

    // MARK: Paychecks — edit and delete

    @Test func editChangesFieldsOnlyAndDeleteReturnsPayToOwed() throws {
        let context = try DomainFixtures.context()
        let employee = TS.employee(hourlyRate: 25, in: context)
        let entry = TS.logHours(employee, 8, date: day1, in: context)
        context.saveChanges()
        let check = try DomainState.subscribed.run {
            try EmployeeService.recordPaycheck(for: employee, amount: 200, payDate: payday,
                                               method: .check, note: "", in: context)
        }
        try DomainState.subscribed.run {
            try EmployeeService.editPaycheck(check, payDate: day3, gross: 250, method: .cash,
                                             note: " corrected ", in: context)
        }
        #expect(check.grossAmount == 250 && check.payDate == day3 && check.method == .cash && check.note == "corrected")
        #expect(entry.paycheck === check && entry.hours == 8, "an edit never re-settles")
        #expect(DomainState.subscribed.run {
            domainError { try EmployeeService.editPaycheck(check, payDate: day3, gross: 0, method: .cash, note: "", in: context) }
        } == .amountRequired)
        #expect(DomainState.lapsed.run { domainError { try DeletionService.delete([.paycheck(check)], in: context) } }
                == .readOnly(operation: "deletePaycheck", lapsed: true))

        _ = try DomainState.subscribed.run { try DeletionService.delete([.paycheck(check)], in: context) }
        #expect(employee.sortedPaychecks.isEmpty)
        #expect(entry.paycheck == nil, "the covered entry survives and is owed again")
        #expect(employee.sortedTimeEntries.count == 1 && close(employee.unpaidGross, 200))
        #expect(!context.hasChanges)
        #expect(DomainState.subscribed.run { domainError { try DeletionService.delete([.paycheck(check)], in: context) } }
                == .recordNotFound)
    }
}
