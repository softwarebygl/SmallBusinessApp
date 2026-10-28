//
//  MBTeamToolTests.swift
//  GLSmallBusinessTests — AI
//
//  The `team` area: employees, their hours and paychecks, subcontractors and their ledger. Money
//  going out is always confirmed and keeps no Undo (contract §5), and no tool here can read or
//  write a tax field.
//

import Foundation
import SwiftData
import Testing
import GoldLifeAI
@testable import GLSmallBusiness

@Suite(.serialized)
@MainActor
struct MBTeamToolTests {

    // MARK: save_employee

    @Test func anEmployeeIsAddedChangedAndUndone() async throws {
        let world = try MBWriteWorld()
        let created = await MBWriteHarness.run(world.box, "save_employee", [
            "first_name": "Luis", "last_name": "Ortega", "pay_type": "hourly",
            "hourly_rate": .number(28), "hire_date": "2026-03-02",
        ])
        let output = MBWriteHarness.output(created)
        #expect(output["employee"]?["pay_type"]?.stringValue == "hourly")
        #expect(MBWriteHarness.titles(created) == ["Added employee"])
        let id = MBWriteHarness.id(output, "employee")

        let raised = await MBWriteHarness.run(world.box, "save_employee",
                                              ["id": .string(id), "hourly_rate": .number(32)])
        _ = MBWriteHarness.output(raised)
        let employee = try #require(MBRecordLookup.record(.employee, id: id, as: Employee.self,
                                                          in: world.context))
        #expect(employee.hourlyRate == 32)
        #expect(employee.firstName == "Luis")   // only the sent field changed

        let reverted = await MBWriteHarness.undoLatest(raised)
        guard case .reverted = reverted else {
            Issue.record("expected the rate to go back")
            return
        }
        #expect(employee.hourlyRate == 28)
    }

    @Test func anEmployeeNeedsAName() async throws {
        let world = try MBWriteWorld()
        let refused = await MBWriteHarness.run(world.box, "save_employee", ["hourly_rate": .number(20)])
        #expect(MBWriteHarness.failureReason(refused) == DomainError.personNameRequired.code)
    }

    // MARK: log_time

    @Test func hoursAreLoggedEditedAndUndone() async throws {
        let world = try MBWriteWorld()
        let employee = TS.employee(first: "Luis", hourlyRate: 30, in: world.context)
        world.context.saveChanges()

        let logged = await MBWriteHarness.run(world.box, "log_time", [
            "employee_id": .string(world.id(employee)), "mode": "hours",
            "hours": .number(6), "date": "2026-09-20", "customer_id": .string(world.customerID),
        ])
        let output = MBWriteHarness.output(logged)
        #expect(output["time_entry"]?["hours"]?.doubleValue == 6)
        #expect(output["time_entry"]?["amount"]?.doubleValue == 180)
        #expect(MBWriteHarness.titles(logged) == ["Logged hours"])
        let entryID = MBWriteHarness.id(output, "time_entry")

        let fixed = await MBWriteHarness.run(world.box, "log_time",
                                             ["id": .string(entryID), "hours": .number(8)])
        _ = MBWriteHarness.output(fixed)
        let entry = try #require(MBRecordLookup.record(.timeEntry, id: entryID, as: TimeEntry.self,
                                                       in: world.context))
        #expect(entry.hours == 8)
        let reverted = await MBWriteHarness.undoLatest(fixed)
        guard case .reverted = reverted else {
            Issue.record("expected the hours to go back")
            return
        }
        #expect(entry.hours == 6)
    }

    @Test func aBonusIsAFlatAmountAndUndoingANewEntryDeletesIt() async throws {
        let world = try MBWriteWorld()
        let employee = TS.employee(hourlyRate: 30, in: world.context)
        world.context.saveChanges()

        let bonus = await MBWriteHarness.run(world.box, "log_time", [
            "employee_id": .string(world.id(employee)), "mode": "bonus",
            "amount": .number(150), "date": "2026-09-20", "note": "Finished early",
        ])
        let output = MBWriteHarness.output(bonus)
        #expect(output["time_entry"]?["bonus"]?.boolValue == true)
        #expect(MBWriteHarness.titles(bonus) == ["Logged bonus"])

        let entryID = MBWriteHarness.id(output, "time_entry")
        let reverted = await MBWriteHarness.undoLatest(bonus)
        guard case .reverted = reverted else {
            Issue.record("expected the bonus to be deleted")
            return
        }
        #expect(MBRecordLookup.record(.timeEntry, id: entryID, as: TimeEntry.self, in: world.context) == nil)
    }

    @Test func hoursWithNoRateAreRefusedAndANewEntryNeedsAnEmployee() async throws {
        let world = try MBWriteWorld()
        let noEmployee = await MBWriteHarness.run(world.box, "log_time", ["mode": "hours", "hours": .number(4)])
        #expect(MBWriteHarness.failureReason(noEmployee) == "invalid_arguments")

        let employee = TS.employee(payType: .salary, hourlyRate: 0, in: world.context)
        world.context.saveChanges()
        let noRate = await MBWriteHarness.run(world.box, "log_time", [
            "employee_id": .string(world.id(employee)), "mode": "hours", "hours": .number(4),
        ])
        #expect(MBWriteHarness.failureReason(noRate) == DomainError.hoursAndRateRequired.code)
    }

    // MARK: pay_employee / edit_paycheck

    @Test func payingAnEmployeeAsksFirstAndKeepsNoUndo() async throws {
        let world = try MBWriteWorld()
        let employee = TS.employee(first: "Luis", hourlyRate: 30, in: world.context)
        TS.logHours(employee, 10, date: MBToolHarness.now, in: world.context)
        world.context.saveChanges()
        #expect(employee.accruedGross == 300)

        // No amount: everything owed.
        let asked = await MBWriteHarness.run(world.box, "pay_employee",
                                             ["employee_id": .string(world.id(employee))])
        #expect(MBWriteHarness.line(asked).contains("Luis"))
        let done = await MBWriteHarness.confirm(asked)
        let output = MBWriteHarness.output(done)
        #expect(output["paycheck"]?["gross"]?.doubleValue == 300)
        #expect(MBWriteHarness.undo(done) == nil)
        #expect(MBWriteHarness.titles(done) == ["Recorded paycheck"])
        #expect(employee.accruedGross == 0)
    }

    @Test func aRetriedPayStepNeverPaysTwice() async throws {
        let world = try MBWriteWorld()
        let employee = TS.employee(hourlyRate: 30, in: world.context)
        TS.logHours(employee, 4, date: MBToolHarness.now, in: world.context)
        world.context.saveChanges()

        let first = await MBWriteHarness.run(world.box, "pay_employee",
                                             ["employee_id": .string(world.id(employee))],
                                             turn: "t1", callID: "c1")
        _ = MBWriteHarness.output(await MBWriteHarness.confirm(first))
        let again = await MBWriteHarness.run(world.box, "pay_employee",
                                             ["employee_id": .string(world.id(employee))],
                                             turn: "t1", callID: "c1")
        let output = MBWriteHarness.output(again)
        #expect(output["already_recorded"]?.boolValue == true)
        #expect(MBRecordLookup.all(Paycheck.self, in: world.context).count == 1)
    }

    @Test func aPaycheckIsCorrectedBehindAConfirmation() async throws {
        let world = try MBWriteWorld()
        let employee = TS.employee(first: "Luis", in: world.context)
        let check = TS.paycheck(employee, gross: 500, periodStart: MBToolHarness.now,
                                periodEnd: MBToolHarness.now, payDate: MBToolHarness.now,
                                in: world.context)
        world.context.saveChanges()

        let asked = await MBWriteHarness.run(world.box, "edit_paycheck", [
            "id": .string(world.id(check)), "gross_amount": .number(520), "method": "zelle",
        ])
        #expect(MBWriteHarness.line(asked).contains("Luis"))
        let done = await MBWriteHarness.confirm(asked)
        _ = MBWriteHarness.output(done)
        #expect(check.grossAmount == 520)
        #expect(check.method == .zelle)
        #expect(MBWriteHarness.undo(done) == nil)
    }

    // MARK: save_subcontractor

    @Test func aSubcontractorIsAddedWithNoTaxFields() async throws {
        let world = try MBWriteWorld()
        let created = await MBWriteHarness.run(world.box, "save_subcontractor", [
            "first_name": "Marco", "business_name": "Marco Tile", "hourly_rate": .number(45),
            "address": ["street1": "12 Oak St", "city": "Miami", "state": "FL"],
        ])
        let output = MBWriteHarness.output(created)
        let id = MBWriteHarness.id(output, "subcontractor")
        let sub = try #require(MBRecordLookup.record(.subcontractor, id: id, as: Subcontractor.self,
                                                     in: world.context))
        #expect(sub.hourlyRate == 45)
        #expect(sub.addressCity == "Miami")
        // Nothing tax-shaped crossed the boundary.
        #expect(output.serializedString.range(of: "tin", options: .caseInsensitive) == nil)

        let reverted = await MBWriteHarness.undoLatest(created)
        guard case .reverted = reverted else {
            Issue.record("expected the subcontractor to be deleted")
            return
        }
        #expect(MBRecordLookup.record(.subcontractor, id: id, as: Subcontractor.self, in: world.context) == nil)
    }

    // MARK: log_sub_work

    @Test func unpaidSubWorkIsLoggedWithAnUndo() async throws {
        let world = try MBWriteWorld()
        let sub = TS.subcontractor(first: "Marco", in: world.context)
        sub.hourlyRate = 40
        world.context.saveChanges()

        let logged = await MBWriteHarness.run(world.box, "log_sub_work", [
            "subcontractor_id": .string(world.id(sub)), "mode": "hours", "hours": .number(5),
            "date": "2026-09-20", "detail": "Shower pan",
        ])
        let output = MBWriteHarness.output(logged)
        #expect(output["sub_payment"]?["amount"]?.doubleValue == 200)
        #expect(output["sub_payment"]?["paid"]?.boolValue == false)
        #expect(MBWriteHarness.titles(logged) == ["Logged subcontractor work"])

        let entryID = MBWriteHarness.id(output, "sub_payment")
        let reverted = await MBWriteHarness.undoLatest(logged)
        guard case .reverted = reverted else {
            Issue.record("expected the entry to be deleted")
            return
        }
        #expect(MBRecordLookup.record(.subPayment, id: entryID, as: SubPayment.self, in: world.context) == nil)
    }

    @Test func subWorkRecordedAsPaidAsksFirstAndKeepsNoUndo() async throws {
        let world = try MBWriteWorld()
        let sub = TS.subcontractor(first: "Marco", in: world.context)
        world.context.saveChanges()

        let asked = await MBWriteHarness.run(world.box, "log_sub_work", [
            "subcontractor_id": .string(world.id(sub)), "mode": "dollars", "amount": .number(300),
            "paid": true, "method": "cash", "date": "2026-09-21",
        ])
        #expect(MBWriteHarness.line(asked).contains("Marco"))
        let done = await MBWriteHarness.confirm(asked)
        let output = MBWriteHarness.output(done)
        #expect(output["sub_payment"]?["paid"]?.boolValue == true)
        #expect(MBWriteHarness.undo(done) == nil)
    }

    /// Money out carries the same idempotency key as the other three money tools (contract §4):
    /// the same turn + call can never record a second paid entry.
    @Test func paidSubWorkIsRecordedOnceForAGivenStep() async throws {
        let world = try MBWriteWorld()
        let sub = TS.subcontractor(first: "Dave", in: world.context)
        sub.hourlyRate = 65
        world.context.saveChanges()

        let asked = await MBWriteHarness.run(world.box, "log_sub_work", [
            "subcontractor_id": .string(world.id(sub)), "mode": "dollars", "amount": .number(390),
            "paid": true, "date": "2026-09-21",
        ], turn: "t1", callID: "c1")
        _ = MBWriteHarness.output(await MBWriteHarness.confirm(asked))
        #expect(sub.liveRows(sub.payments).count == 1)

        // The step runs again (a re-dispatch, or the confirmation performed twice).
        let again = await MBWriteHarness.run(world.box, "log_sub_work", [
            "subcontractor_id": .string(world.id(sub)), "mode": "dollars", "amount": .number(390),
            "paid": true, "date": "2026-09-21",
        ], turn: "t1", callID: "c1")
        #expect(MBWriteHarness.output(again)["already_recorded"]?.boolValue == true)
        #expect(sub.liveRows(sub.payments).count == 1, "Dave is not paid twice")

        // An UNPAID log is a plain edit: freely repeatable under the same key.
        let unpaid = await MBWriteHarness.run(world.box, "log_sub_work", [
            "subcontractor_id": .string(world.id(sub)), "mode": "hours", "hours": .number(2),
            "date": "2026-09-22",
        ], turn: "t1", callID: "c1")
        #expect(MBWriteHarness.output(unpaid)["already_recorded"] == nil)
        #expect(sub.liveRows(sub.payments).count == 2)
    }

    // MARK: pay_subcontractor

    @Test func payingASubcontractorSettlesTheOldestOwedFirst() async throws {
        let world = try MBWriteWorld()
        let sub = TS.subcontractor(first: "Marco", in: world.context)
        TS.oweSub(sub, 200, date: TS.day(2026, 9, 10), in: world.context)
        TS.oweSub(sub, 300, date: TS.day(2026, 9, 15), in: world.context)
        world.context.saveChanges()
        #expect(sub.outstanding == 500)

        let asked = await MBWriteHarness.run(world.box, "pay_subcontractor", [
            "subcontractor_id": .string(world.id(sub)), "amount": .number(200), "method": "check",
        ])
        let done = await MBWriteHarness.confirm(asked)
        let output = MBWriteHarness.output(done)
        #expect(output["entries_paid"]?.arrayValue?.count == 1)
        #expect(sub.outstanding == 300)
        #expect(MBWriteHarness.undo(done) == nil)
        #expect(MBWriteHarness.titles(done) == ["Paid subcontractor"])
    }

    @Test func payingNothingIsRefusedBeforeAnyoneIsAsked() async throws {
        let world = try MBWriteWorld()
        let sub = TS.subcontractor(in: world.context)
        world.context.saveChanges()
        let refused = await MBWriteHarness.run(world.box, "pay_subcontractor",
                                               ["subcontractor_id": .string(world.id(sub))])
        #expect(MBWriteHarness.failureReason(refused) == DomainError.amountRequired.code)
    }
}
