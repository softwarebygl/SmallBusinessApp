//
//  MBWriteTestSupport.swift
//  GLSmallBusinessTests — AI
//
//  Runs a write tool the way the conversation loop does: one call, then — when the tool asks —
//  the person's answer to the alert (Continue or Cancel), then the Undo the card offers.
//

import Foundation
import SwiftData
import Testing
import GoldLifeAI
@testable import GLSmallBusiness

@MainActor
enum MBWriteHarness {

    /// One tool call. `callID` and `turn` make up the idempotency key money tools use.
    static func run(_ box: MBToolbox, _ name: String, _ arguments: GLAIJSON,
                    turn: String = "turn", callID: String = "call",
                    state: DomainState = .subscribed) async -> GLAIToolOutcome {
        guard let tool = box.online.executor(named: name) else {
            Issue.record("\(name) is not bound")
            return .failure(GLAIFailure(reason: "unbound", message: "", personReason: GLAIStrings.notAvailableHere))
        }
        let context = GLAIToolContext(turnId: turn, step: 0, onScreen: nil, accountEpoch: 1, currentEpoch: { 1 })
        return await state.runAsync {
            await tool.run(GLAIToolCall(id: callID, name: name, arguments: arguments, turnId: turn),
                           context: context)
        }
    }

    /// The person taps the alert's action: the confirmed outcome.
    static func confirm(_ outcome: GLAIToolOutcome, state: DomainState = .subscribed,
                        sourceLocation: SourceLocation = #_sourceLocation) async -> GLAIToolOutcome {
        guard case .needsConfirmation(let confirmation) = outcome else {
            Issue.record("expected a confirmation", sourceLocation: sourceLocation)
            return outcome
        }
        return await state.runAsync { await confirmation.perform() }
    }

    static func confirmation(_ outcome: GLAIToolOutcome,
                             sourceLocation: SourceLocation = #_sourceLocation) -> GLAIConfirmation? {
        guard case .needsConfirmation(let confirmation) = outcome else {
            Issue.record("expected a confirmation", sourceLocation: sourceLocation)
            return nil
        }
        return confirmation
    }

    /// The alert's line, in English (what the person reads).
    static func line(_ outcome: GLAIToolOutcome) -> String {
        guard let confirmation = confirmation(outcome) else { return "" }
        return GLAIStrings.english(confirmation.line)
    }

    static func output(_ outcome: GLAIToolOutcome, sourceLocation: SourceLocation = #_sourceLocation) -> GLAIJSON {
        switch outcome {
        case .result(let output, _, _): return output
        case .failure(let failure):
            Issue.record("expected a result, got \(failure.reason): \(failure.message)", sourceLocation: sourceLocation)
        case .needsConfirmation:
            Issue.record("expected a result, got a confirmation", sourceLocation: sourceLocation)
        case .handoff:
            Issue.record("expected a result, got a hand-off", sourceLocation: sourceLocation)
        }
        return .null
    }

    static func activity(_ outcome: GLAIToolOutcome) -> [GLAIActivity] {
        if case .result(_, let activity, _) = outcome { return activity }
        if case .failure(let failure) = outcome, failure.showsToPerson { return [failure.activity] }
        return []
    }

    static func undo(_ outcome: GLAIToolOutcome) -> GLAIUndo? {
        if case .result(_, _, let undo) = outcome { return undo }
        return nil
    }

    static func failureReason(_ outcome: GLAIToolOutcome) -> String? {
        if case .failure(let failure) = outcome { return failure.reason }
        return nil
    }

    static func failureMessage(_ outcome: GLAIToolOutcome) -> String {
        if case .failure(let failure) = outcome { return failure.message }
        return ""
    }

    /// Runs the Undo the card offers, the way `undoLatest` does (dropped and changed-since first).
    static func undoLatest(_ outcome: GLAIToolOutcome, state: DomainState = .subscribed,
                           sourceLocation: SourceLocation = #_sourceLocation) async -> GLAIUndoRevert? {
        guard let entry = undo(outcome) else {
            Issue.record("expected an Undo entry", sourceLocation: sourceLocation)
            return nil
        }
        if entry.dropReason() != nil { return nil }
        if entry.changedSince() { return nil }
        return await state.runAsync { await entry.revert() }
    }

    /// English titles of the activity rows — what the card says, checked without a screen.
    static func titles(_ outcome: GLAIToolOutcome) -> [String] {
        activity(outcome).map { GLAIStrings.english($0.title) }
    }

    static func id(_ output: GLAIJSON, _ key: String) -> String {
        output[key]?["id"]?.stringValue ?? ""
    }
}

/// A small world for the write tools: one customer, and the pieces a test asks for.
@MainActor
struct MBWriteWorld {
    let context: ModelContext
    let box: MBToolbox
    let customer: Customer

    init() throws {
        context = try DomainFixtures.context()
        let profile = BusinessProfile()
        profile.businessName = "Gold Tile Co"
        profile.email = "office@goldtile.example"
        context.insert(profile)
        customer = TS.customer(in: context)
        context.saveChanges()
        box = try MBToolHarness.toolbox(context)
    }

    var customerID: String { MBIDs.id(customer, MBToolHarness.environment(context)) }

    func id<T: PersistentModel & GLSyncIdentified>(_ record: T) -> String {
        MBIDs.id(record, MBToolHarness.environment(context))
    }

    func id(_ item: PriceSheetItem) -> String { MBIDs.id(item, MBToolHarness.environment(context)) }

    func estimates() -> [Estimate] { MBRecordLookup.all(Estimate.self, in: context) }
    func invoices() -> [Invoice] { MBRecordLookup.all(Invoice.self, in: context) }
    func jobs() -> [ScheduledJob] { MBRecordLookup.all(ScheduledJob.self, in: context) }
    func customers() -> [Customer] { MBRecordLookup.all(Customer.self, in: context) }
}
