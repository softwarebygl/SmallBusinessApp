//
//  MBSettingsUndoTests.swift
//  GLSmallBusinessTests — AI
//
//  Audit 2026-10-03 C71 (F32): an Undo for the business details, the work schedule or the app
//  settings never writes old values over something the person changed by hand afterwards. The
//  entry reports "changed since", the way the customer, estimate and invoice entries already do.
//  (The assistant ships switched off; this is dormant work that matters the day it flips.)
//

import Foundation
import SwiftData
import Testing
import GoldLifeAI
@testable import GLSmallBusiness

@Suite(.serialized)
@MainActor
struct MBSettingsUndoTests {

    private func handEditBusinessPhone(_ world: MBWriteWorld, to phone: String) throws {
        try DomainState.subscribed.run {
            let profile = try #require(MBRecordLookup.businessProfile(in: world.context))
            var draft = BusinessDetailsDraft(profile)
            draft.phone = phone
            _ = try BusinessProfileService.updateDetails(draft, in: world.context)
        }
    }

    @Test func aBusinessUndoSkipsWhenTheFormChangedItAfterward() async throws {
        let world = try MBWriteWorld()
        let done = await MBWriteHarness.run(world.box, "update_business",
                                            ["website_url": "https://goldtile.example"])
        _ = MBWriteHarness.output(done)
        let entry = try #require(MBWriteHarness.undo(done))
        #expect(!entry.changedSince(), "nothing has moved yet")

        try handEditBusinessPhone(world, to: "(850) 555-0199")
        #expect(entry.changedSince(), "a hand edit after the tool ran must stop the Undo")

        let reverted = await MBWriteHarness.undoLatest(done)
        #expect(reverted == nil, "the skipped Undo must not run")
        let profile = try #require(MBRecordLookup.businessProfile(in: world.context))
        #expect(profile.websiteURL == "https://goldtile.example")
        #expect(BusinessDetailsDraft(profile).phone == "(850) 555-0199", "the hand edit stands")
    }

    @Test func twoBusinessWritesUndoInTurnWhenNothingElseMoved() async throws {
        let world = try MBWriteWorld()
        let first = await MBWriteHarness.run(world.box, "update_business",
                                             ["website_url": "https://one.example"])
        _ = MBWriteHarness.output(first)
        let second = await MBWriteHarness.run(world.box, "update_business",
                                              ["website_url": "https://two.example"])
        _ = MBWriteHarness.output(second)

        guard case .reverted = await MBWriteHarness.undoLatest(second) else {
            Issue.record("the latest Undo should run")
            return
        }
        guard case .reverted = await MBWriteHarness.undoLatest(first) else {
            Issue.record("the earlier Undo should still run after the later one went back")
            return
        }
        #expect(MBRecordLookup.businessProfile(in: world.context)?.websiteURL == "")
    }

    @Test func aWorkScheduleUndoSkipsWhenTheScreenChangedItAfterward() async throws {
        let world = try MBWriteWorld()
        let done = await MBWriteHarness.run(world.box, "update_work_schedule", [
            "add_time_off": [["start": "2026-12-24", "end": "2026-12-26"]],
        ])
        _ = MBWriteHarness.output(done)
        let entry = try #require(MBWriteHarness.undo(done))
        #expect(!entry.changedSince())

        try DomainState.subscribed.run {
            var schedule = WorkScheduleService.current(in: world.context)
            schedule.weekdayHours[6].isWorkday.toggle()
            try WorkScheduleService.save(schedule, in: world.context)
        }
        #expect(entry.changedSince(), "a hand edit after the tool ran must stop the Undo")
        #expect(await MBWriteHarness.undoLatest(done) == nil)
        #expect(WorkScheduleService.current(in: world.context).vacations.count == 1, "the new time off stays")
    }

    @Test func anAppSettingsUndoSkipsWhenAWrittenSettingWasChangedByHand() async throws {
        let world = try MBWriteWorld()
        let done = await MBWriteHarness.run(world.box, "update_app_settings",
                                            ["logo_on_documents": false])
        _ = MBWriteHarness.output(done)
        let entry = try #require(MBWriteHarness.undo(done))
        #expect(!entry.changedSince())

        // The person turns the same switch back on in Settings.
        try DomainState.subscribed.run {
            try BusinessProfileService.setDisplay(.logoOnDocuments, true, in: world.context)
        }
        #expect(entry.changedSince(), "the written setting moved by hand, so Undo must not overwrite it")
        #expect(await MBWriteHarness.undoLatest(done) == nil)
    }

    @Test func anAppSettingsUndoStillRunsWhenOnlyAnotherSettingWasTouched() async throws {
        let world = try MBWriteWorld()
        let done = await MBWriteHarness.run(world.box, "update_app_settings",
                                            ["book_one_job_at_a_time": false])
        _ = MBWriteHarness.output(done)
        try DomainState.subscribed.run {
            try BusinessProfileService.setDisplay(.logoOnDocuments, false, in: world.context)
        }
        let entry = try #require(MBWriteHarness.undo(done))
        #expect(!entry.changedSince(), "a switch this call never wrote does not block its Undo")
    }
}
