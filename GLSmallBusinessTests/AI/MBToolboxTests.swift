//
//  MBToolboxTests.swift
//  GLSmallBusinessTests — AI
//
//  The toolbox's binding contract: the bundled manifests load, every manifest tool is either
//  bound or scheduled for a named later stage, nothing is bound that the manifest doesn't list,
//  and the offline toolbox holds only read-only executors (law 12). At stage 4 nothing may be
//  left unbound.
//

import Foundation
import SwiftData
import Testing
import GoldLifeAI
@testable import GLSmallBusiness

@Suite(.serialized)
@MainActor
struct MBToolboxTests {

    @Test func bothManifestsLoadFromTheAppBundle() throws {
        let box = try MBToolboxHarnessStore.toolbox()
        #expect(box.online.manifest.toolset == MBToolbox.toolset)
        #expect(box.onDevice.manifest.toolset == MBToolbox.toolset)
        #expect(!box.online.manifest.isOnDevice)
        #expect(box.onDevice.manifest.isOnDevice)
        #expect(box.online.manifest.tools.count == 45)
        #expect(Set(box.onDevice.manifest.tools.map(\.name)) == ["find", "get", "report", "list_bank_transactions", "list_subscriptions"])
    }

    /// Every manifest tool is bound, built into the loop, or scheduled for a named later stage —
    /// and once `buildStage` reaches 4, nothing is left unbound.
    @Test func everyManifestToolIsBoundOrScheduled() throws {
        let box = try MBToolboxHarnessStore.toolbox()
        let report = box.online.bindingReport
        #expect(report.executorsNotInManifest.isEmpty)
        #expect(report.mismatches.isEmpty, "\(report.mismatches)")

        let unbound = Set(report.manifestToolsWithoutExecutor)
        // A scheduled tool that got bound must come off the list; an unbound one must be on it.
        #expect(unbound == Set(MBToolbox.scheduled.keys),
                "unbound but not scheduled: \(unbound.subtracting(MBToolbox.scheduled.keys).sorted()); scheduled but bound: \(Set(MBToolbox.scheduled.keys).subtracting(unbound).sorted())")
        for (name, stage) in MBToolbox.scheduled {
            #expect(stage > MBToolbox.buildStage && stage <= 4, "\(name) is scheduled for stage \(stage)")
            #expect(box.online.manifest.tool(named: name) != nil, "\(name) is scheduled but not in the manifest")
        }
        if MBToolbox.buildStage >= 4 {
            #expect(report.manifestToolsWithoutExecutor.isEmpty,
                    "stage 4 leaves no manifest tool unbound: \(report.manifestToolsWithoutExecutor)")
        }
        for name in ["find", "get", "report", "help"] {
            #expect(box.online.executor(named: name) is any GLAIReadOnlyTool, "\(name) is bound and read-only")
        }
    }

    @Test func theOfflineToolboxIsCleanAndReadOnly() throws {
        let box = try MBToolboxHarnessStore.toolbox()
        #expect(box.onDevice.bindingReport.isClean, "\(box.onDevice.bindingReport)")
        for entry in box.onDevice.manifest.tools {
            #expect(box.onDevice.executor(named: entry.name) is any GLAIReadOnlyTool, "\(entry.name)")
        }
        // The offline transport's own gate (law 12) accepts this toolbox.
        #if canImport(FoundationModels)
        #expect(throws: Never.self) {
            _ = try GLAIOnDeviceTransport(toolbox: box.onDevice, instructions: "Read only.", locale: Locale(identifier: "en_US"))
        }
        #endif
    }

    @Test func aMissingManifestIsReportedNotCrashed() {
        #expect(throws: MBToolboxError.manifestMissing("tools.nope")) {
            _ = try MBToolbox.manifestURL("tools.nope", in: .main)
        }
    }

    /// No store mounted (signed out / rebuilding): every read tool refuses plainly, and runs nothing.
    @Test func noStoreMeansNotAvailable() async throws {
        let context = try DomainFixtures.context()
        var env = MBToolHarness.environment(context)
        env.context = { nil }
        let box = try MBToolbox(environment: env)
        for (name, args) in [("find", ["kind": "customer"]), ("get", ["kind": "business"]),
                             ("report", ["kind": "owed_to_me"])] as [(String, GLAIJSON)] {
            #expect(MBToolHarness.failureReason(await MBToolHarness.run(box, name, args)) == "not_available", "\(name)")
        }
    }

    /// The account fence moved (sign-out mid-request): the tool reads nothing.
    @Test func aMovedAccountFenceStopsTheRead() async throws {
        let world = try MBToolWorld()
        let box = try MBToolHarness.toolbox(world.context)
        guard let tool = box.online.executor(named: "find") else { Issue.record("find unbound"); return }
        let stale = GLAIToolContext(turnId: "t", step: 0, onScreen: nil, accountEpoch: 1, currentEpoch: { 2 })
        let outcome = await tool.run(GLAIToolCall(id: "c", name: "find", arguments: ["kind": "customer"], turnId: "t"),
                                     context: stale)
        #expect(MBToolHarness.failureReason(outcome) == "not_available")
    }
}

@MainActor
enum MBToolboxHarnessStore {
    static func toolbox() throws -> MBToolbox {
        try MBToolHarness.toolbox(DomainFixtures.context())
    }
}
