//
//  MBHandoffToolTests.swift
//  GLSmallBusinessTests — AI
//
//  The six tools that hand the person a screen, a composer, a share sheet or a picker: what they
//  check BEFORE anything is shown (law 44 — never a dead push; law 45 — never a send under a
//  half-built business), what they hand over, and how a real outcome comes back (contract A5:
//  `.sent` only for an actual send).
//

import Foundation
import SwiftData
import Testing
import GoldLifeAI
@testable import GLSmallBusiness

@Suite(.serialized)
@MainActor
struct MBHandoffToolTests {

    /// The hand-off a tool raised, or an Issue.
    static func handoff(_ outcome: GLAIToolOutcome,
                        sourceLocation: SourceLocation = #_sourceLocation) -> GLAIHandoff? {
        guard case .handoff(let handoff) = outcome else {
            Issue.record("expected a hand-off, got \(outcome)", sourceLocation: sourceLocation)
            return nil
        }
        return handoff
    }

    // MARK: open

    @Test func openHandsOverARecordOrAScreenAndRefusesAnIdThatIsGone() async throws {
        let world = try MBWriteWorld()
        let invoice = TS.invoice(number: "INV-0100", lines: [(500, false)], in: world.context)
        world.context.saveChanges()

        let record = await MBWriteHarness.run(world.box, "open",
                                              ["target": "invoice", "id": .string(world.id(invoice))])
        let handoff = try #require(Self.handoff(record))
        #expect(handoff.kind == "open")
        #expect(handoff.record?.kind == "invoice")

        let screen = await MBWriteHarness.run(world.box, "open", ["target": "price_sheet"])
        #expect(Self.handoff(screen)?.payload["target"]?.stringValue == "price_sheet")

        // Law 44: an id that names nothing is refused, not pushed at.
        let gone = await MBWriteHarness.run(world.box, "open",
                                            ["target": "invoice", "id": .string(UUID().uuidString)])
        #expect(MBWriteHarness.failureReason(gone) == "not_found")

        let unknown = await MBWriteHarness.run(world.box, "open", ["target": "nowhere"])
        #expect(MBWriteHarness.failureReason(unknown) == "invalid_arguments")
    }

    /// "Show my customers / subs / all jobs" — `open` with a record kind and no id — opened a
    /// blank "gone" screen (found 2026-09-29): the destination view only knew the named screens.
    /// Every target now resolves to a real screen with a real title, never the "Screen" fallback.
    @Test func openWithoutAnIdOpensThatKindsList() async throws {
        let world = try MBWriteWorld()
        for kind in ["customer", "subcontractor", "employee", "job", "estimate", "invoice", "project"] {
            let outcome = await MBWriteHarness.run(world.box, "open", ["target": .string(kind)])
            let handoff = try #require(Self.handoff(outcome))
            #expect(handoff.record == nil)
            let destination = MBAssistantDestination(handoff: handoff, in: world.context)
            #expect(destination == .screen(kind))
        }
        let fallback = MBAssistantDestination.screenLabel("nowhere")
        for target in MBOpenTarget.allCases {
            #expect(MBAssistantDestination.screenLabel(target.rawValue) != fallback, "\(target.rawValue)")
        }
        #expect(MBAssistantDestination.screenLabel("customer") == mbLoc("Customers"))
        #expect(MBAssistantDestination.screenLabel("subcontractor") == mbLoc("Subcontractors"))
        #expect(MBAssistantDestination.screenLabel("job") == mbLoc("All Jobs"))
    }

    /// A record with no screen of its own opens the screen that holds it.
    @Test func aPaymentOpensItsInvoiceAndHoursOpenTheEmployee() async throws {
        let world = try MBWriteWorld()
        let invoice = TS.invoice(number: "INV-0101", lines: [(500, false)], in: world.context)
        let payment = TS.pay(invoice, 100, in: world.context)
        let employee = TS.employee(in: world.context)
        let entry = TS.logHours(employee, 3, date: MBToolHarness.now, in: world.context)
        world.context.saveChanges()

        let fromPayment = MBAssistantDestination(
            record: GLAIRecordRef(kind: "payment", id: world.id(payment)), in: world.context)
        #expect(fromPayment == .record(kind: "invoice", id: world.id(invoice)))

        let fromHours = MBAssistantDestination(
            record: GLAIRecordRef(kind: "time_entry", id: world.id(entry)), in: world.context)
        #expect(fromHours == .record(kind: "employee", id: world.id(employee)))

        // The two legal pages are sheets, not pushes (they carry their own navigation).
        #expect(MBAssistantDestination.screen("privacy_policy").isSheet)
        #expect(!MBAssistantDestination.screen("settings").isSheet)
    }

    // MARK: send

    @Test func sendChecksTheDocumentTheChannelAndTheRecord() async throws {
        let world = try MBWriteWorld()
        let estimate = TS.estimate(number: "EST-0100", lines: [(900, false)], in: world.context)
        world.context.saveChanges()

        let ready = await MBWriteHarness.run(world.box, "send", [
            "document": "estimate", "id": .string(world.id(estimate)), "channel": "email",
        ])
        let handoff = try #require(Self.handoff(ready))
        #expect(handoff.kind == "send")
        #expect(handoff.payload["channel"]?.stringValue == "email")

        let badChannel = await MBWriteHarness.run(world.box, "send", [
            "document": "estimate", "id": .string(world.id(estimate)), "channel": "carrier pigeon",
        ])
        #expect(MBWriteHarness.failureReason(badChannel) == "invalid_arguments")

        // The id names a different record per document: a customer for a review request.
        let wrongKind = await MBWriteHarness.run(world.box, "send", [
            "document": "review_request", "id": .string(world.id(estimate)), "channel": "text",
        ])
        #expect(MBWriteHarness.failureReason(wrongKind) == "not_found")
    }

    @Test func extraRecipientsRideAlong() async throws {
        let world = try MBWriteWorld()
        let invoice = TS.invoice(number: "INV-0102", lines: [(500, false)], in: world.context)
        world.context.saveChanges()
        let ready = await MBWriteHarness.run(world.box, "send", [
            "document": "invoice", "id": .string(world.id(invoice)), "channel": "share",
            "recipients": ["husband@example.com"],
        ])
        #expect(Self.handoff(ready)?.payload["recipients"]?.arrayValue?.count == 1)
    }

    /// Law 45: nothing goes to a customer under a business with no name or no way to be reached.
    @Test func aSendUnderAnIncompleteBusinessIsRefusedBeforeAnythingIsShown() async throws {
        let context = try DomainFixtures.context()
        _ = TS.customer(in: context)
        let estimate = TS.estimate(number: "EST-0101", lines: [(100, false)], in: context)
        context.saveChanges()
        let env = MBToolHarness.environment(context)
        let handoff = GLAIHandoff(kind: "send", payload: [
            "document": "estimate", "channel": "email", "id": .string(MBIDs.id(estimate, env)),
        ])
        let plan = await MBHandoffBuilder.send(handoff, env: env)
        guard case .answer(let outcome) = plan else {
            Issue.record("expected a refusal")
            return
        }
        #expect(outcome.isError)
        #expect(outcome.output["reason"]?.stringValue == "business_profile_incomplete")
    }

    // MARK: A5 outcomes

    @Test func onlyARealSendMakesASentRow() {
        let content = MBComposeContent(recipients: ["a@b.example"], subject: "s", body: "b",
                                       isHTML: true, preferredSendingEmail: nil, attachmentURL: nil,
                                       record: GLAIRecordRef(kind: "invoice", id: "1"),
                                       activityTitle: MBWriteStrings.sentInvoice,
                                       activityDetail: "INV-0001", channel: "email")
        let sent = MBSendOutcomeMapper.outcome(.sent, content: content)
        #expect(sent.output["sent"]?.boolValue == true)
        #expect(sent.activity.count == 1)
        #expect(sent.activity.first?.kind == .sent)

        let cancelled = MBSendOutcomeMapper.outcome(.cancelled, content: content)
        #expect(cancelled.output["cancelled"]?.boolValue == true)
        #expect(cancelled.activity.isEmpty)

        let failed = MBSendOutcomeMapper.outcome(.failed, content: content)
        #expect(failed.isError)
        #expect(failed.output["reason"]?.stringValue == "send_failed")
    }

    // MARK: pick_media

    @Test func pickMediaChecksTheKindTheTargetAndTheOwner() async throws {
        let world = try MBWriteWorld()
        let ready = await MBWriteHarness.run(world.box, "pick_media", [
            "kind": "photo", "target": "customer_coi", "id": .string(world.customerID),
        ])
        #expect(Self.handoff(ready)?.payload["target"]?.stringValue == "customer_coi")

        let noOwner = await MBWriteHarness.run(world.box, "pick_media",
                                               ["kind": "file", "target": "customer_coi"])
        #expect(MBWriteHarness.failureReason(noOwner) == "not_found")

        // A phone contact only fits the new_ targets, and they take nothing else.
        let wrongContact = await MBWriteHarness.run(world.box, "pick_media",
                                                    ["kind": "contact", "target": "customer_coi",
                                                     "id": .string(world.customerID)])
        #expect(MBWriteHarness.failureReason(wrongContact) == "invalid_arguments")
        let wrongPhoto = await MBWriteHarness.run(world.box, "pick_media",
                                                  ["kind": "photo", "target": "new_customer"])
        #expect(MBWriteHarness.failureReason(wrongPhoto) == "invalid_arguments")
    }

    /// A subcontractor's W-9 is tax class: no service writes one, so the hand-off refuses it.
    @Test func theSubcontractorW9CannotBePickedOrShared() async throws {
        let world = try MBWriteWorld()
        let sub = TS.subcontractor(in: world.context)
        world.context.saveChanges()
        let env = MBToolHarness.environment(world.context)

        let pick = GLAIHandoff(kind: "pick_media", payload: [
            "kind": "file", "target": "subcontractor_w9", "id": .string(MBIDs.id(sub, env)),
        ])
        guard case .answer(let picked) = await MBHandoffBuilder.pick(pick, env: env) else {
            Issue.record("expected a refusal")
            return
        }
        #expect(picked.isError)

        let share = GLAIHandoff(kind: "share_document", payload: [
            "document": "subcontractor_w9", "id": .string(MBIDs.id(sub, env)),
        ])
        guard case .answer(let shared) = await MBHandoffBuilder.share(share, env: env) else {
            Issue.record("expected a refusal")
            return
        }
        #expect(shared.isError)
    }

    /// `w9_signature` is a manifest option, so it must DO something or be refused — never fall
    /// through silently while the reply claims a signed W-9 went out.
    @Test func theW9SignaturePartIsHonouredOrRefusedNeverIgnored() async throws {
        let world = try MBWriteWorld()
        world.customer.email = "maria@example.com"
        world.customer.coiData = Data([1, 2, 3])
        world.context.saveChanges()
        let env = MBToolHarness.environment(world.context)

        // Asked for on its own, it says what it needs instead of doing nothing.
        let handoff = GLAIHandoff(kind: "send", payload: [
            "document": "contractor_package", "channel": "share",
            "id": .string(world.customerID), "package_parts": ["w9_signature"],
        ])
        guard case .answer(let outcome) = await MBHandoffBuilder.send(handoff, env: env) else {
            Issue.record("expected a refusal, not a package built without the signature")
            return
        }
        #expect(outcome.isError)
        #expect(outcome.output["reason"]?.stringValue == "invalid_arguments")
        #expect(outcome.output["message"]?.stringValue?.contains("w9") == true)
    }

    // MARK: share_document

    @Test func shareChecksTheDocumentAndFillsInTheYear() async throws {
        let world = try MBWriteWorld()
        let ready = await MBWriteHarness.run(world.box, "share_document", ["document": "wage_report"])
        let handoff = try #require(Self.handoff(ready))
        #expect(handoff.payload["year"]?.doubleValue == 2026)

        let needsOwner = await MBWriteHarness.run(world.box, "share_document",
                                                  ["document": "form_1099_nec"])
        #expect(MBWriteHarness.failureReason(needsOwner) == "not_found")

        let unknown = await MBWriteHarness.run(world.box, "share_document", ["document": "nope"])
        #expect(MBWriteHarness.failureReason(unknown) == "invalid_arguments")
    }

    @Test func aDocumentWithNothingOnFileSaysSo() async throws {
        let world = try MBWriteWorld()
        let env = MBToolHarness.environment(world.context)
        let handoff = GLAIHandoff(kind: "share_document", payload: ["document": "license"])
        guard case .answer(let outcome) = await MBHandoffBuilder.share(handoff, env: env) else {
            Issue.record("expected a refusal")
            return
        }
        #expect(outcome.output["reason"]?.stringValue == "not_on_file")
    }

    // MARK: save_to_contacts / contact_developer

    @Test func aContactCardIsOfferedForAPersonOnly() async throws {
        let world = try MBWriteWorld()
        let ready = await MBWriteHarness.run(world.box, "save_to_contacts",
                                             ["kind": "customer", "id": .string(world.customerID)])
        #expect(Self.handoff(ready)?.record?.kind == "customer")

        let wrongKind = await MBWriteHarness.run(world.box, "save_to_contacts",
                                                 ["kind": "invoice", "id": .string(world.customerID)])
        #expect(MBWriteHarness.failureReason(wrongKind) == "invalid_arguments")
    }

    @Test func theDeveloperEmailCarriesTheDraftMessage() async throws {
        let world = try MBWriteWorld()
        let ready = await MBWriteHarness.run(world.box, "contact_developer",
                                             ["message": "The calendar scrolls oddly on my iPhone."])
        let handoff = try #require(Self.handoff(ready))
        #expect(handoff.payload["message"]?.stringValue?.contains("calendar") == true)
        #expect(MBHandoffBuilder.developerEmail == "support@softwarebygl.com")
    }

    // MARK: The presenter

    @Test func aHandoffWithNoRouteAnswersRatherThanHanging() async throws {
        let world = try MBWriteWorld()
        let presenter = MBAIHandoffPresenter(environment: MBToolHarness.environment(world.context))
        let outcome = await presenter.present(GLAIHandoff(kind: "open", payload: ["target": "settings"]))
        #expect(outcome.isError)
        #expect(outcome.output["reason"]?.stringValue == "not_available")
    }

    @Test func anOpenHandoffRoutesAndAnswersAtOnce() async throws {
        let world = try MBWriteWorld()
        let presenter = MBAIHandoffPresenter(environment: MBToolHarness.environment(world.context))
        let routed = Routes()
        presenter.claim(UUID()) { routed.destinations.append($0) }
        let outcome = await presenter.present(GLAIHandoff(kind: "open", payload: ["target": "stats"]))
        #expect(routed.destinations == [.screen("stats")])
        #expect(outcome.output["opened"]?.boolValue == true)
        #expect(outcome.activity.first?.kind == .opened)
    }

    /// A screen that goes away takes its route with it: `open` then says it couldn't, instead of
    /// pushing into a dismissed sheet's stack and reporting `{opened:true}` (law 44).
    @Test func aReleasedScreenStopsRoutingAndOpenSaysSo() async throws {
        let world = try MBWriteWorld()
        let presenter = MBAIHandoffPresenter(environment: MBToolHarness.environment(world.context))
        let tab = Routes()
        let sheet = Routes()
        let tabToken = UUID()
        let sheetToken = UUID()
        presenter.claim(tabToken) { tab.destinations.append($0) }
        presenter.claim(sheetToken) { sheet.destinations.append($0) }
        // The sheet is on top: it routes, and it is the one host that may present.
        _ = await presenter.present(GLAIHandoff(kind: "open", payload: ["target": "stats"]))
        #expect(sheet.destinations == [.screen("stats")])
        #expect(tab.destinations.isEmpty)
        #expect(presenter.isOwner(sheetToken))
        #expect(!presenter.isOwner(tabToken))
        // Dismissed: the tab underneath takes over rather than the dead closure staying installed.
        presenter.release(sheetToken)
        #expect(presenter.isOwner(tabToken))
        _ = await presenter.present(GLAIHandoff(kind: "open", payload: ["target": "price_sheet"]))
        #expect(sheet.destinations == [.screen("stats")])
        #expect(tab.destinations == [.screen("price_sheet")])
        // Nothing on screen at all: a refusal, never a false "opened".
        presenter.release(tabToken)
        let outcome = await presenter.present(GLAIHandoff(kind: "open", payload: ["target": "stats"]))
        #expect(outcome.isError)
        #expect(outcome.output["opened"] == nil)
    }

    /// A box, so the route closures can append without capturing an inout local.
    @MainActor
    final class Routes {
        var destinations: [MBAssistantDestination] = []
    }

    @Test func aPendingHandoffIsAnsweredWhenTheAccountGoes() async throws {
        let world = try MBWriteWorld()
        let presenter = MBAIHandoffPresenter(environment: MBToolHarness.environment(world.context))
        let handoff = GLAIHandoff(kind: "save_to_contacts",
                                  payload: ["kind": "customer", "id": .string(world.customerID)])
        async let answered = presenter.present(handoff)
        // Let the presenter raise its sheet, then tear the session down under it.
        try await Task.sleep(nanoseconds: 20_000_000)
        presenter.cancelPending()
        let outcome = await answered
        #expect(outcome.output["cancelled"]?.boolValue == true)
        #expect(presenter.presentation == nil)
    }
}
