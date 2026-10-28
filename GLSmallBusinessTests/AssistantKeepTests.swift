//
//  AssistantKeepTests.swift
//  GLSmallBusinessTests
//
//  The old assistant's KEEP tests (inventory 6-current-ai.md §5), re-pointed at what the new
//  assistant calls. The old AIAssistantExecutionService, AIAssistantClient and
//  AIAssistantScreen are gone; the rules these tests guard are not:
//  - Paid invoices can't be edited or deleted, and a customer with a paid invoice can't be
//    deleted (law 58 pillar 4 — a release blocker). The assistant's tools write through the
//    domain services, so the services are what's tested, with records addressed by id.
//  - Deletes go through `deleteSynced` (DeletionService) and address records by id — never
//    by name, never a "the only job there is" fallback.
//  - Nothing leaves the phone without consent: the transport refuses before a token is
//    fetched or a payload is built.
//  - A cascade delete really removes the child rows (the build-81 crash's precondition).
//
//  The KEEP tests that need the new chat screen (the build-81 live-deletion renders, the
//  consent sheet's callback) are held in AIAssistantLiveDeletionTests.swift and at the end of
//  this file until stage 4 of the same run brings that screen in.
//

import Foundation
import GoldLifeAI
import GoldLifeCloud
import SwiftData
import Testing
@testable import GLSmallBusiness

@MainActor
@Suite(.serialized)
struct AssistantKeepTests {

    // MARK: Consent belongs to the person, not the device

    /// The app treats "session user ≠ cached prefs owner" as a reachable state — that is what
    /// `reconcilePrefOwner()` exists for. AI consent is one device-global key, so it has to be on
    /// that list too: otherwise the arriving person's books go to Gemini on a yes they never gave
    /// (contract §4, law 26).
    @Test func anAccountChangeClearsAIConsentEvenWithoutASignOut() {
        let defaults = UserDefaults.standard
        let ownerKey = "mb.account.prefs.owner"
        let previousOwner = defaults.string(forKey: ownerKey)
        let consent = MBAssistantSession.shared.consent
        let previousConsent = consent.storedVersion
        defer {
            if let previousOwner { defaults.set(previousOwner, forKey: ownerKey) }
            else { defaults.removeObject(forKey: ownerKey) }
            if previousConsent > 0 { defaults.set(previousConsent, forKey: consent.key) }
            else { consent.reset() }
        }

        // Person A said yes; the caches are theirs.
        defaults.set("stytch-user-A", forKey: ownerKey)
        consent.grant()
        #expect(consent.isGranted)

        // The session is now someone else's (no Stytch session in a test = a different owner).
        GoldLifeAuth.reconcilePrefOwner()
        #expect(!consent.isGranted, "person B must see the disclosure before anything is shared")

        // Same owner again: nothing is cleared, so a plain restore keeps the yes.
        consent.grant()
        GoldLifeAuth.reconcilePrefOwner()
        #expect(consent.isGranted)
    }

    // MARK: Cascade (was deletedCustomerCascadesAndEstimateReportsIsDeleted)

    @Test func deletedCustomerCascadesAndEstimateReportsIsDeleted() throws {
        let ctx = try DomainFixtures.context()
        let customer = Customer(firstName: "Test", lastName: "Client")
        ctx.insert(customer)
        let estimate = Estimate(jobTitle: "Tile Work", customer: customer)
        customer.estimates = [estimate]
        ctx.insert(estimate)
        ctx.saveChanges()
        #expect(estimate.modelContext != nil)

        ctx.delete(customer)
        ctx.saveChanges()

        let allEstimates = (try? ctx.fetch(FetchDescriptor<Estimate>())) ?? []
        #expect(estimate.modelContext == nil || estimate.isDeleted)
        #expect(!allEstimates.contains { $0.persistentModelID == estimate.persistentModelID })
    }

    // MARK: Paid lock (was paidInvoiceMutationRefusalAndChangeOrderOffer)

    /// Removing a line from a paid invoice is refused and the line stays. (Offering a change
    /// order instead is the model's reply — covered by the server's live eval.)
    @Test func paidInvoiceMutationIsRefused() throws {
        let ctx = try DomainFixtures.context()
        let customer = Customer(firstName: "Carol", lastName: "Miller")
        ctx.insert(customer)
        let invoice = Invoice(jobTitle: "Patio Paving", customer: customer)
        invoice.number = "INV-3001"
        let group = InvoiceGroup(name: "Paving", sortIndex: 0)
        group.invoice = invoice
        let line = InvoiceLineItem(name: "Pavers", quantity: 100, unit: .squareFoot, unitPrice: 15)
        line.group = group
        group.lineItems = [line] // LIVEROWS-OK: test fixture setup
        invoice.groups = [group] // LIVEROWS-OK: test fixture setup
        let payment = InvoicePayment(amount: 1500, date: .now, method: .check)
        payment.invoice = invoice
        invoice.payments = [payment] // LIVEROWS-OK: test fixture setup
        ctx.insert(invoice)
        ctx.insert(payment)
        ctx.saveChanges()
        #expect(invoice.isMoneyLocked)

        var edit = InvoiceDraft(invoice)
        edit.groups[0].lines.removeAll()
        let refusal = DomainState.subscribed.run {
            domainError { try InvoiceService.update(invoice, with: edit, in: ctx) }
        }
        #expect(refusal == .paidLocked)
        #expect(invoice.sortedGroups.first?.sortedLineItems.count == 1)
        #expect(invoice.sortedGroups.first?.sortedLineItems.first?.name == "Pavers")
    }

    // MARK: Paid lock on deletes (was paidInvoiceAndCustomerDeleteRefusal)

    @Test func paidInvoiceAndCustomerDeleteRefusal() throws {
        let ctx = try DomainFixtures.context()
        let customer = Customer(firstName: "Dan", lastName: "White")
        ctx.insert(customer)
        let invoice = Invoice(jobTitle: "Roof Repair", customer: customer)
        invoice.number = "INV-4001"
        let group = InvoiceGroup(name: "Roofing", sortIndex: 0)
        group.invoice = invoice
        let line = InvoiceLineItem(name: "Shingles", quantity: 20, unit: .each, unitPrice: 35)
        line.group = group
        group.lineItems = [line] // LIVEROWS-OK: test fixture setup
        invoice.groups = [group] // LIVEROWS-OK: test fixture setup
        let payment = InvoicePayment(amount: 700, date: .now, method: .cash)
        payment.invoice = invoice
        invoice.payments = [payment] // LIVEROWS-OK: test fixture setup
        customer.invoices = [invoice] // LIVEROWS-OK: test fixture setup
        ctx.insert(invoice)
        ctx.insert(payment)
        ctx.saveChanges()
        #expect(invoice.isMoneyLocked)
        #expect(customer.hasPaidInvoice)

        let invoiceID = try #require(invoice.syncID)
        let customerID = try #require(customer.syncID)
        try DomainState.subscribed.run {
            // 1. The paid invoice, by id.
            let paid = try DeletionService.target(kind: .invoice, id: invoiceID, in: ctx)
            #expect(domainError { _ = try DeletionService.plan([paid], in: ctx) } == .paidLocked)
            #expect(domainError { try DeletionService.delete([paid], in: ctx) } == .paidLocked)
            // 2. The customer who has it, by id.
            let payer = try DeletionService.target(kind: .customer, id: customerID, in: ctx)
            #expect(domainError { try DeletionService.delete([payer], in: ctx) } == .paidLocked)
        }
        #expect(!invoice.isDeleted && invoice.modelContext != nil)
        #expect(!customer.isDeleted && customer.modelContext != nil)
        #expect(try ctx.fetchCount(FetchDescriptor<Invoice>()) == 1)
        #expect(try ctx.fetchCount(FetchDescriptor<Customer>()) == 1)
    }

    // MARK: Unlocked deletes by id (was unlockedDocumentAndRecordDeletionViaDeleteSynced)

    @Test func unlockedRecordsDeleteByIDThroughDeleteSynced() throws {
        let ctx = try DomainFixtures.context()
        let customer = Customer(firstName: "Eve", lastName: "Adams")
        ctx.insert(customer)
        let estimate = Estimate(jobTitle: "Drywall Patch", customer: customer)
        estimate.number = "EST-9001"
        estimate.status = .draft
        ctx.insert(estimate)
        let job = ScheduledJob(title: "Drywall Installation", customerName: customer.fullName, customer: customer)
        ctx.insert(job)
        ctx.saveChanges()
        let estimateID = try #require(estimate.syncID)
        let jobID = try #require(job.syncID)
        let customerID = try #require(customer.syncID)

        try DomainState.subscribed.run {
            let estimateTarget = try DeletionService.target(kind: .estimate, id: estimateID, in: ctx)
            #expect(try DeletionService.delete([estimateTarget], in: ctx)
                    == .deleted(.init(deleted: 1, itemsLeftOnInvoice: false, tripsOtherDevicesBreaker: false)))
            #expect(estimate.isDeleted || estimate.modelContext == nil)

            let jobTarget = try DeletionService.target(kind: .job, id: jobID, in: ctx)
            try DeletionService.delete([jobTarget], in: ctx)
            #expect(job.isDeleted || job.modelContext == nil)

            let customerTarget = try DeletionService.target(kind: .customer, id: customerID, in: ctx)
            try DeletionService.delete([customerTarget], in: ctx)
            #expect(customer.isDeleted || customer.modelContext == nil)
        }
        #expect(!ctx.hasChanges, "each delete saved with its queued sync op")
        #expect(try ctx.fetchCount(FetchDescriptor<Estimate>()) == 0)
        #expect(try ctx.fetchCount(FetchDescriptor<ScheduledJob>()) == 0)
        #expect(try ctx.fetchCount(FetchDescriptor<Customer>()) == 0)
    }

    // MARK: Job delete by id (was scheduledJobDeletionByNameAndActiveContext, part 3)

    /// Deletes exactly the job named by id — the old name match could delete a DIFFERENT job
    /// (substring both ways, then "the only job there is").
    @Test func jobDeletesByIDAndNeverAnother() throws {
        let ctx = try DomainFixtures.context()
        let customer = Customer(firstName: "Job", lastName: "Client")
        ctx.insert(customer)
        let job = ScheduledJob(title: "Master Bath Tiling", startDate: .now, durationDays: 3, customer: customer)
        let other = ScheduledJob(title: "Master Bath", startDate: .now, durationDays: 1, customer: customer)
        ctx.insert(job)
        ctx.insert(other)
        ctx.saveChanges()
        let jobID = try #require(job.syncID)

        try DomainState.subscribed.run {
            try DeletionService.delete([try DeletionService.target(kind: .job, id: jobID, in: ctx)], in: ctx)
            // An id that names nothing is not found — never a fallback to whatever job is left.
            #expect(domainError { _ = try DeletionService.target(kind: .job, id: UUID(), in: ctx) } == .recordNotFound)
        }
        let allJobs = try ctx.fetch(FetchDescriptor<ScheduledJob>())
        #expect(!allJobs.contains { $0.persistentModelID == job.persistentModelID })
        #expect(allJobs.map(\.title) == ["Master Bath"])
    }

    // MARK: Consent before payload (was assistantClientConsentRequirementEnforced)

    /// Records every request instead of sending it. No network, no shared defaults.
    private actor RecordingDispatcher: GLAICloudDispatching {
        private(set) var requests: [GLCloudRequest] = []
        func dispatch(_ request: GLCloudRequest) async throws -> GLCloudResponse {
            requests.append(request)
            return GLCloudResponse(statusCode: 503, data: Data(#"{"error":"ai_paused"}"#.utf8))
        }
    }

    private func turnRequest() -> GLAITurnRequest {
        GLAITurnRequest(
            toolset: "mb-1", turnId: UUID().uuidString, step: 0,
            context: GLAITurnContext(now: "2026-09-22T09:00:00-04:00", timeZone: "America/New_York",
                                     language: "en", appVersion: "test", onScreen: nil,
                                     businessName: nil, areas: []),
            transcript: [.user("Create an estimate for Bob")])
    }

    @Test func noConsentMeansNothingIsBuiltOrSent() async throws {
        let suite = "AssistantKeepTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        // My Business's consent: key mb.ai.consent.version, version 4.
        let consent = GLAIConsent.myBusiness(defaults: defaults)
        let dispatcher = RecordingDispatcher()
        var tokenAsks = 0
        let transport = GLAIServerTransport(
            dispatcher: dispatcher, consent: consent, isSampleMode: { false },
            bearerToken: { _ in tokenAsks += 1; return "token" },
            entitlementJWS: { "signed.jws.value" })

        // 1. No consent: refused before a token is fetched or a request exists.
        await #expect(throws: GLAIError.consentRequired) { _ = try await transport.send(turnRequest()) }
        #expect(tokenAsks == 0)
        #expect(await dispatcher.requests.isEmpty)

        // The pre-toolbox Bool never counts as consent.
        defaults.set(true, forKey: GLAIConsent.legacyKey)
        await #expect(throws: GLAIError.consentRequired) { _ = try await transport.send(turnRequest()) }
        #expect(await dispatcher.requests.isEmpty)

        // 2. Consent given: the request goes out through GLCloudTransport's seam, carrying the
        //    consent version and the Pro + AI proof.
        consent.grant()
        await #expect(throws: GLAIError.self) { _ = try await transport.send(turnRequest()) }
        let sent = await dispatcher.requests
        #expect(sent.count == 1)
        #expect(sent.first?.path == "ai/turn" && sent.first?.method == "POST")
        #expect(sent.first?.headers[GLAIServerTransport.consentHeader] == "4")
        #expect(sent.first?.headers[GLAIServerTransport.entitlementHeader] == "signed.jws.value")
        #expect(sent.first?.headers["Authorization"] == "Bearer token")

        // 3. Sample data never leaves the phone, consent or not (law 42).
        let sample = GLAIServerTransport(
            dispatcher: dispatcher, consent: consent, isSampleMode: { true },
            bearerToken: { _ in "token" }, entitlementJWS: { nil })
        await #expect(throws: GLAIError.sampleMode) { _ = try await sample.send(turnRequest()) }
        #expect(await dispatcher.requests.count == 1)
    }
}

// MARK: - The chat screen's own KEEP tests (stage 4)
//
// The build-81 crash's shape, on the NEW screen: a record the conversation named is deleted
// underneath it. GoldLifeAI's messages hold a `GLAIRecordRef` (kind + id), never a `@Model`, so
// there is nothing to trap on — this proves it, rather than assuming it.

@MainActor
@Suite(.serialized)
struct AssistantScreenKeepTests {

    /// Was `deletedCustomerDoesNotCrashAssistantScreen`.
    @Test func aDeletedCustomerDoesNotCrashTheAssistantScreen() throws {
        let container = try TestStore.makeContainer()
        let ctx = container.mainContext

        let customer = Customer(firstName: "Test", lastName: "Client")
        ctx.insert(customer)
        let estimate = Estimate(jobTitle: "Tile Work", customer: customer)
        customer.estimates = [estimate]
        ctx.insert(estimate)
        ctx.saveChanges()

        let onScreen = GLAIOnScreen(kind: "estimate",
                                    id: estimate.syncID?.uuidString ?? UUID().uuidString,
                                    label: "EST-0001")
        GLTestHost.render(AssistantScreen(onScreen: onScreen, isSheet: true), container: container)

        ctx.delete(customer)
        ctx.saveChanges()

        let allEstimates = (try? ctx.fetch(FetchDescriptor<Estimate>())) ?? []
        #expect(!allEstimates.contains { $0.persistentModelID == estimate.persistentModelID })

        // Rendering again with the conversation still naming the deleted record MUST NOT crash.
        GLTestHost.render(AssistantScreen(onScreen: onScreen, isSheet: true), container: container)
    }

    /// Was the assistant half of `rendersAIAssistantAndPriceSheetScreens`: the populated screen
    /// and the consent sheet, in both colour schemes.
    @Test func theAssistantAndItsConsentSheetRenderInBothSchemes() throws {
        let world = try TestStore.demoWorld()
        GLTestHost.renderBothSchemes(AssistantScreen(), container: world.container)
        GLTestHost.renderBothSchemes(
            GLAIConsentSheet(content: MBAssistantStrings.consentContent) { },
            container: world.container)
    }

    /// Every gate the screen can stand in front of draws (contract §4 gate order).
    @Test func everyGateResolvesTheWayTheContractOrdersThem() {
        #expect(GLAIGate.resolve(isSampleMode: true, isSignedIn: true, subscription: .entitled,
                                 isOnline: true, onDeviceAvailable: false) == .sampleMode)
        #expect(GLAIGate.resolve(isSampleMode: false, isSignedIn: false, subscription: .entitled,
                                 isOnline: true, onDeviceAvailable: false) == .signedOut)
        #expect(GLAIGate.resolve(isSampleMode: false, isSignedIn: true, subscription: .notEntitled,
                                 isOnline: true, onDeviceAvailable: false) == .premium)
        #expect(GLAIGate.resolve(isSampleMode: false, isSignedIn: true, subscription: .paymentIssue,
                                 isOnline: true, onDeviceAvailable: false) == .paymentIssue)
        #expect(GLAIGate.resolve(isSampleMode: false, isSignedIn: true, subscription: .unconfirmed,
                                 isOnline: true, onDeviceAvailable: false) == .couldNotConfirm)
        #expect(GLAIGate.resolve(isSampleMode: false, isSignedIn: true, subscription: .entitled,
                                 isOnline: false, onDeviceAvailable: false) == .open(.needsConnection))
        #expect(GLAIGate.resolve(isSampleMode: false, isSignedIn: true, subscription: .entitled,
                                 isOnline: false, onDeviceAvailable: true) == .open(.onDevice))
    }

    /// The area an `onScreen` record pre-loads (contract §5).
    @Test func whatIsOnScreenPreLoadsItsArea() {
        func areas(_ kind: String) -> [String] {
            MBAssistantSession.areas(for: GLAIOnScreen(kind: kind, id: "1", label: "x"))
        }
        #expect(areas("invoice") == ["money"])
        #expect(areas("change_order") == ["money"])
        #expect(areas("employee") == ["team"])
        #expect(areas("receipt") == ["expenses"])
        #expect(areas("job") == ["expenses"])
        #expect(areas("price_item") == ["catalog"])
        #expect(areas("project") == ["settings"])
        #expect(areas("customer").isEmpty)
    }
}

// The consent KEEP test lives on `AssistantKeepTests` so it can reuse that suite's recording
// dispatcher and turn request (both private to this file).
extension AssistantKeepTests {
    /// Was `consentSheetCallbackExecution`: Allow runs the action the host held — which, in the
    /// new screen, is `grantConsentAndResume()`. What that action really does is recorded here:
    /// consent goes into the store the TRANSPORT checks, so the held request can go out.
    @Test func allowingSharingIsWhatUnblocksTheTransport() async throws {
        let defaults = try #require(UserDefaults(suiteName: "mb.ai.consent.test.\(UUID().uuidString)"))
        defer { defaults.removePersistentDomain(forName: defaults.description) }
        let consent = GLAIConsent.myBusiness(defaults: defaults)
        #expect(!consent.isGranted)

        let dispatcher = RecordingDispatcher()
        let transport = GLAIServerTransport(dispatcher: dispatcher, consent: consent,
                                            isSampleMode: { false },
                                            bearerToken: { _ in "token" }, entitlementJWS: { nil })
        await #expect(throws: GLAIError.consentRequired) { _ = try await transport.send(turnRequest()) }
        #expect(await dispatcher.requests.isEmpty)

        // This is exactly what the sheet's Allow button runs.
        consent.grant()
        #expect(consent.isGranted)
        _ = try? await transport.send(turnRequest())
        #expect(await dispatcher.requests.count == 1)
    }

    /// Law 74: the assistant checks GoldLifeCloud's shared versioned store at My Business's own
    /// key and version, and a yes to an older sheet asks again.
    @Test func aYesToAnOlderSheetAsksAgain() throws {
        let suite = "mb.ai.consent.test.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(MBAssistantSession.shared.consent.key == "mb.ai.consent.version")
        #expect(MBAssistantSession.shared.consent.requiredVersion == GLAIConsent.myBusinessVersion)

        let consent = GLAIConsent.myBusiness(defaults: defaults)
        defaults.set(true, forKey: GLAIConsent.legacyKey)
        #expect(!consent.isGranted)
        defaults.set(GLAIConsent.myBusinessVersion - 1, forKey: consent.key)
        #expect(!consent.isGranted, "a yes to an older sheet is not a yes to this one")
        consent.grant()
        #expect(consent.isGranted)
        #expect(defaults.object(forKey: GLAIConsent.legacyKey) == nil)
    }

}

// MARK: - Consent v4: the sheet names the BYOK AI companies connected directly from this device
extension AssistantKeepTests {

    /// The approved English wording, as the sheet's first sentence prints it.
    @Test func theDisclosureNamesGoldLifesServerInEnglish() {
        let saved = MBLocalization.shared.language
        defer { MBLocalization.shared.language = saved }
        MBLocalization.shared.language = .en

        let provider = MBAssistantStrings.consentContent.providerName
        #expect(provider == "the AI companies you connect (OpenAI, Anthropic, Google or Meta), straight from this device with your own key")
        let intro = GLAIStrings.string(GLAIStrings.consentIntro(provider: provider), locale: Locale(identifier: "en"))
        #expect(intro == "The assistant sends what you type or say, and the records it needs to answer, "
                + "to the AI companies you connect (OpenAI, Anthropic, Google or Meta), straight from this device with your own key.")
    }

    /// The approved Spanish wording, read from this app's catalog, fits the package's sentence.
    @Test func theDisclosureNamesGoldLifesServerInSpanish() {
        let saved = MBLocalization.shared.language
        defer { MBLocalization.shared.language = saved }
        MBLocalization.shared.language = .es

        let provider = MBAssistantStrings.consentContent.providerName
        #expect(provider == "las empresas de IA que conectas (OpenAI, Anthropic, Google o Meta), directo desde este dispositivo con tu propia clave")
        let intro = GLAIStrings.string(GLAIStrings.consentIntro(provider: provider), locale: Locale(identifier: "es"))
        #expect(intro == "El asistente env\u{ED}a lo que escribes o dices, y los registros que necesita para responder, "
                + "a las empresas de IA que conectas (OpenAI, Anthropic, Google o Meta), directo desde este dispositivo con tu propia clave.")
    }

    /// The catalog carries the new wording in Spanish, and the old wording is gone with it.
    @Test func theCatalogCarriesOnlyTheNewWording() throws {
        let url = GLSource.appRoot.appendingPathComponent("Localizable.xcstrings")
        let root = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let strings = try #require(root["strings"] as? [String: Any])
        let entry = try #require(strings["the AI companies you connect (OpenAI, Anthropic, Google or Meta), straight from this device with your own key"] as? [String: Any])
        let es = ((entry["localizations"] as? [String: Any])?["es"] as? [String: Any])?["stringUnit"] as? [String: Any]
        #expect(es?["value"] as? String == "las empresas de IA que conectas (OpenAI, Anthropic, Google o Meta), directo desde este dispositivo con tu propia clave")
        #expect(strings["Google\u{2019}s Gemini API, a paid service"] == nil)
        #expect(strings["Google\u{2019}s Gemini, a paid service, through Gold Life\u{2019}s server"] == nil)
    }

    /// A yes to the v2 sheet asks again; a yes to v3 doesn't; Allow now stores 3.
    @Test func aStoredV3AsksAgainAndV4DoesNot() throws {
        let suite = "mb.ai.consent.test.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(GLAIConsent.myBusinessVersion == 4)
        let consent = GLAIConsent.myBusiness(defaults: defaults)

        defaults.set(3, forKey: "mb.ai.consent.version")
        #expect(!consent.isGranted, "a yes to the v3 sheet didn't see the Beta terms")
        defaults.set(4, forKey: "mb.ai.consent.version")
        #expect(consent.isGranted)

        consent.reset()
        consent.grant()
        #expect(defaults.integer(forKey: "mb.ai.consent.version") == 4)
    }

    /// The network-layer guard refuses a stored v3 before a token is fetched or a request is
    /// built; the same person's v4 yes goes out carrying "4".
    @Test func theGuardRefusesAStoredV3() async throws {
        let suite = "mb.ai.consent.test.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let consent = GLAIConsent.myBusiness(defaults: defaults)
        let dispatcher = RecordingDispatcher()
        var tokenAsks = 0
        let transport = GLAIServerTransport(
            dispatcher: dispatcher, consent: consent, isSampleMode: { false },
            bearerToken: { _ in tokenAsks += 1; return "token" },
            entitlementJWS: { "signed.jws.value" })

        defaults.set(3, forKey: consent.key)
        await #expect(throws: GLAIError.consentRequired) { _ = try await transport.send(turnRequest()) }
        #expect(tokenAsks == 0)
        #expect(await dispatcher.requests.isEmpty)

        consent.grant()
        await #expect(throws: GLAIError.self) { _ = try await transport.send(turnRequest()) }
        let sent = await dispatcher.requests
        #expect(sent.count == 1)
        #expect(sent.first?.headers[GLAIServerTransport.consentHeader] == "4")
    }
}
