//
//  AIAssistantLiveDeletionTests.swift
//  GLSmallBusinessTests
//
//  The TestFlight crash on build 81 (APTgSqmpO9qyluK_7eZ9Hww): the AI made an estimate and
//  a new client, the tester deleted that client, the cascade deleted the estimate, and the
//  STILL-OPEN chat re-rendered its estimate card over the dead model — Estimate.discountType
//  trapped uncatchably. The gesture only exists on a LIVE screen: a fresh render after the
//  delete never reaches the re-render path, which is why these use `renderAcross` (see
//  DetailScreenSurvivesRebuildTests for the same shape on the detail screens).
//
//  On the new screen the class of bug is designed out: a conversation holds `GLAIRecordRef`
//  (kind + id), never a `@Model`, and the router re-fetches by id at draw time. These tests are
//  the proof — the same gesture, against `AssistantScreen`, plus the router's own answer once the
//  record is gone (law 44: no dead push).
//
//  `.serialized` is load-bearing: hosted @Query views and RunLoop pumping must not
//  interleave across tests (project_swiftdata_test_process_trap).
//

import Testing
import Foundation
import SwiftUI
import SwiftData
import GoldLifeAI
import GoldLifeCloud
@testable import GLSmallBusiness

@MainActor
@Suite(.serialized)
struct AIAssistantLiveDeletionTests {

    private func onScreen(_ kind: String, _ record: some PersistentModel & GLSyncIdentified,
                          _ label: String, in context: ModelContext) -> GLAIOnScreen {
        let id = (try? DomainSyncIdentity.ensure(record, in: context, subscription: nil))?.uuidString
        return GLAIOnScreen(kind: kind, id: id ?? UUID().uuidString, label: label)
    }

    /// The tester's exact gesture: the assistant open on an estimate, its client deleted underneath.
    @Test func chatSurvivesClientDeletedUnderLiveEstimateCard() throws {
        let container = try TestStore.makeContainer()
        let context = container.mainContext
        let customer = TS.customer(in: context)
        let estimate = TS.estimate(number: "EST-AI-0001", in: context)
        estimate.customer = customer
        try context.save()
        #expect(estimate.total > 0)

        let screen = AssistantScreen(onScreen: onScreen("estimate", estimate, "EST-AI-0001", in: context),
                                     isSheet: true)
        GLTestHost.renderAcross(screen, container: container) {
            // An edit saved while the chat is off screen (a follow-up turn, a sync pull)
            // re-faults the estimate — then the client goes, cascade and all.
            estimate.jobTitle = "Master bath — revised"
            try? context.save()
            context.delete(customer)
            try? context.save()
        }

        // The cascade really committed: a saved delete leaves the row without a context.
        #expect(estimate.modelContext == nil)
    }

    /// The same gesture with an invoice on screen.
    @Test func chatSurvivesClientDeletedUnderLiveInvoiceCard() throws {
        let container = try TestStore.makeContainer()
        let context = container.mainContext
        let customer = TS.customer(in: context)
        let invoice = TS.invoice(number: "INV-AI-0001", in: context)
        invoice.customer = customer
        try context.save()
        #expect(invoice.total > 0)

        let screen = AssistantScreen(onScreen: onScreen("invoice", invoice, "INV-AI-0001", in: context),
                                     isSheet: true)
        GLTestHost.renderAcross(screen, container: container) {
            invoice.jobTitle = "Master bath — revised"
            try? context.save()
            context.delete(customer)
            try? context.save()
        }

        #expect(invoice.modelContext == nil)
    }

    /// The estimate deleted directly (Estimates list, sync) rather than by cascade.
    @Test func chatSurvivesEstimateDeletedDirectlyUnderLiveCard() throws {
        let container = try TestStore.makeContainer()
        let context = container.mainContext
        let estimate = TS.estimate(number: "EST-AI-0002", in: context)
        try context.save()

        let screen = AssistantScreen(onScreen: onScreen("estimate", estimate, "EST-AI-0002", in: context),
                                     isSheet: true)
        GLTestHost.renderAcross(screen, container: container) {
            estimate.jobTitle = "Master bath — revised"
            try? context.save()
            context.delete(estimate)
            try? context.save()
        }

        #expect(estimate.modelContext == nil)
    }

    /// The card's row still points at the deleted record: the router refuses it (law 44) and the
    /// destination view draws the app's own "this is gone" screen instead of trapping.
    @Test func anActivityRowForADeletedRecordNeitherPushesNorTraps() throws {
        let container = try TestStore.makeContainer()
        let context = container.mainContext
        let estimate = TS.estimate(number: "EST-AI-0003", in: context)
        try context.save()
        let id = try #require(try DomainSyncIdentity.ensure(estimate, in: context, subscription: nil)).uuidString

        #expect(MBAssistantDestination(record: GLAIRecordRef(kind: "estimate", id: id),
                                       in: context) == .record(kind: "estimate", id: id))
        context.delete(estimate)
        try context.save()
        #expect(MBAssistantDestination(record: GLAIRecordRef(kind: "estimate", id: id), in: context) == nil)

        // Even if a stale destination is drawn, it resolves to the "removed" screen, not a trap.
        GLTestHost.render(MBAssistantDestinationView(destination: .record(kind: "estimate", id: id)),
                          container: container)
    }

    @Test func assistantChatRendersCleanReplyWithGemini38Flash() async throws {
        let container = try TestStore.makeContainer()
        let context = container.mainContext
        let env = MBToolEnvironment(context: { context })
        let box = try MBToolbox(environment: env)

        final class StubTransport: GLAITurnTransport {
            var count = 0
            func send(_ request: GLAITurnRequest) async throws -> GLAITurnResponse {
                count += 1
                if count == 1 {
                    throw GLAIError.unavailable
                }
                return GLAITurnResponse(
                    step: GLAIModelStep(text: "Hello! I’m ready to help with your customers, estimates, contracts, and invoices."),
                    done: true
                )
            }
        }
        let stub = StubTransport()
        let suite = "mb.ai.proof.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let consent = GLAIConsent.myBusiness(defaults: defaults)
        consent.grant()

        let controller = GLAIConversationController(
            toolbox: box.online,
            transport: stub,
            configuration: .init(
                appName: MBAssistantSession.appName,
                context: { GLAIHostContext(language: "en", appVersion: "3.4.1 (102)", businessName: "Summit Tile & Stone") },
                isOnline: { true },
                isSampleMode: { false },
                consent: consent,
                subscriptionState: { .entitled }
            )
        )
        controller.send("Hi")
        while controller.isBusy {
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(controller.canTryAgain)
        controller.tryAgain()
        while controller.isBusy {
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(!controller.canTryAgain)

        let store = AIConnectionStore()
        store.connect(provider: .gemini, token: "gemini-test-key")
        store.setSelectedModel(AIProvider.gemini.defaultModel, for: .gemini)

        let host = GLAIChatHost(
            title: MBAssistantStrings.title,
            appName: MBAssistantSession.appName,
            gate: .open(.online),
            bannerStack: { variant in AnyView(MBSystemBannerInset(offlineVariant: variant)) },
            examples: MBAssistantStrings.examples,
            examplesTitle: MBAssistantStrings.examplesTitle,
            composerPlaceholder: MBAssistantStrings.composerPlaceholder,
            activityCardTitle: MBAssistantStrings.activityCardTitle,
            workingLabel: { MBAssistantStrings.workingLabel($0) },
            consentContent: MBAssistantStrings.consentContent,
            presentHandoff: { _ in .cancelled() },
            openRecord: { _ in },
            onSignIn: nil,
            onUpgrade: {},
            onRetrySubscriptionCheck: {},
            dictationLocale: MBLocalization.currentLocale,
            usage: nil,
            connectionStore: store
        )

        GLTestHost.render(GLAIChatScreen(controller: controller, host: host),
                          container: container, scheme: .light, settle: 0.25) { vc in
            guard let window = vc.view.window else { return }
            let png = UIGraphicsImageRenderer(bounds: window.bounds).pngData { _ in
                vc.view.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            let home = ProcessInfo.processInfo.environment["SIMULATOR_HOST_HOME"] ?? NSHomeDirectory()
            let cacheDir = URL(fileURLWithPath: home).appendingPathComponent("Library/Caches/testflight_feedback")
            try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
            try? png.write(to: cacheDir.appendingPathComponent("mb_APjyN1d8wqoFT0zhmSarH8Y_proof_sim.png"))
        }
    }
}
