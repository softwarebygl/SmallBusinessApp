//
//  MBAssistantSession.swift
//  GLSmallBusiness — AI
//
//  ONE `GLAIConversationController` per signed-in session (GoldLifeAI README, step 4), plus the
//  toolbox it dispatches through and the handoff presenter the screen mounts. Held here, not in a
//  view, because the conversation outlives the chat screen: an `open` handoff navigates away and
//  must come back to the same conversation.
//
//  The fence (contract §4): `cancelAndWait()` runs BEFORE the store unmounts — sign-out, session
//  expiry, account deletion, entering or leaving sample data, and a store rebuild. It stops the
//  loop, waits for it, clears the conversation, Undo and any pending confirmation, and bumps the
//  account epoch so a tool still holding a context sees `isStillCurrent == false`. Consent is
//  reset on the same paths.
//

import Foundation
import SwiftData
import OSLog
import GoldLifeAI
import GoldLifeCloud
import GoldLifeID
import GoldLifeUI

@MainActor
@Observable
final class MBAssistantSession {
    static let shared = MBAssistantSession()

    /// The live conversation, or nil until a store is attached.
    private(set) var controller: GLAIConversationController?
    /// Why the assistant couldn't be built (a missing manifest). Shown as the screen's error.
    private(set) var setupFailed = false
    /// This month's usage for the thin percent bar (law 80, owner ruling 2026-09-29: keep the
    /// server's rule). Nil until fetched; cleared with the session.
    private(set) var usage: GLAIUsage?
    @ObservationIgnored private var transport: GLAIServerTransport?
    @ObservationIgnored private var directTransport: GLAIDirectProviderTransport?

    @ObservationIgnored let consent = GLAIConsent.myBusiness()
    @ObservationIgnored private(set) var presenter: MBAIHandoffPresenter
    @ObservationIgnored private var environment: MBToolEnvironment
    @ObservationIgnored private(set) var attachedStore: ModelContext?
    @ObservationIgnored private var toolbox: MBToolbox?
    @ObservationIgnored private let logger = Logger(subsystem: "com.evolvedbygl.GLSmallBusiness", category: "Assistant")

    /// What the model is told is on screen right now (the sparkles sheet's record).
    @ObservationIgnored var onScreen: GLAIOnScreen?

    private init() {
        let env = MBToolEnvironment(context: { MBAssistantSession.shared.attachedStore })
        environment = env
        presenter = MBAIHandoffPresenter(environment: env)
    }

    /// The store a toolbox belongs to, PINNED. The lookup is live so a tool sees an unmount, but
    /// it must never resolve to the NEXT account's store: sample-mode entry and exit call
    /// `detachNow()` and attach the replacement without ever awaiting the old loop, so a
    /// confirmation raised against the real books could otherwise run against the sample
    /// container (law 42). Identity, not just "is something mounted".
    private static func pinnedLookup(_ store: ModelContext?) -> () -> ModelContext? {
        { [weak store] in
            guard let store, MBAssistantSession.shared.attachedStore === store else { return nil }
            return store
        }
    }

    // MARK: Mounting

    /// Attaches the assistant to the store the app is showing. A different store (sign-in, account
    /// switch, sample mode, a rebuild) tears the old conversation down first.
    func attach(_ store: ModelContext) async {
        if attachedStore === store, controller != nil { return }
        await cancelAndWait()
        attachedStore = store
        build()
    }

    private func build() {
        setupFailed = false
        let env = MBToolEnvironment(context: Self.pinnedLookup(attachedStore))
        environment = env
        presenter.environment = env
        let box: MBToolbox
        do {
            box = try MBToolbox(environment: env)
        } catch {
            logger.error("assistant toolbox failed: \(String(describing: error), privacy: .public)")
            setupFailed = true
            return
        }
        toolbox = box
        let serverTransport = GLAIServerTransport(
            consent: consent,
            isSampleMode: { UserDemoMode.shared.isDemoActive },
            bearerToken: { forceRefresh in
                switch try await MBAssistantSession.tokens.token(forcingRefresh: forceRefresh) {
                case .token(let token, _): return token
                case .signedOut: return ""
                }
            },
            entitlementJWS: { await MBAIEntitlement.shared.currentAIJWS() })
        self.transport = serverTransport
        let direct = GLAIDirectProviderTransport(
            manifest: box.online.manifest,
            consent: consent,
            isSampleMode: { UserDemoMode.shared.isDemoActive },
            systemPromptProvider: { [weak self] _ in
                self?.buildDomainSystemPrompt() ?? ""
            },
            connectionStore: .shared,
            chatService: .shared,
            spendTracker: .shared,
            reliability: .shared
        )
        self.directTransport = direct
        let configuration = GLAIConversationController.Configuration(
            appName: Self.appName,
            context: { MBAssistantSession.shared.hostContext() },
            isOnline: { NetworkMonitor.shared.isConnected },
            isSampleMode: { UserDemoMode.shared.isDemoActive },
            areasForScreen: { Self.areas(for: $0) },
            consent: consent,
            subscriptionState: { .entitled })
        let answerer = Self.onDevice(box)
        storedOnDevice = answerer
        controller = GLAIConversationController(toolbox: box.online, transport: direct,
                                                configuration: configuration,
                                                onDevice: answerer)
        env.ledger.clear()
    }

    @ObservationIgnored private static let tokens = GLSyncTokenProvider()

    static let appName = "My Business"

    /// True when Apple's on-device model can answer offline in the app's language — the gate's
    /// "on-device mode" instead of "needs a connection".
    var hasOnDeviceModel: Bool {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            return (onDeviceTransport?.availability ?? .unavailable) == .available
        }
        #endif
        return false
    }

    #if canImport(FoundationModels)
    @available(iOS 26.0, *)
    private var onDeviceTransport: GLAIOnDeviceTransport? { storedOnDevice as? GLAIOnDeviceTransport }
    #endif
    @ObservationIgnored private var storedOnDevice: AnyObject?

    /// The offline, read-only answerer — only where Apple's on-device model exists.
    private static func onDevice(_ box: MBToolbox) -> (any GLAIOnDeviceAnswering)? {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            return try? GLAIOnDeviceTransport(toolbox: box.onDevice,
                                              instructions: MBAssistantStrings.onDeviceInstructions,
                                              locale: MBLocalization.currentLocale)
        }
        #endif
        return nil
    }

    /// Pre-loaded areas for what the person is looking at (contract §5).
    static func areas(for screen: GLAIOnScreen) -> [String] {
        switch MBRecordKind(rawValue: screen.kind) {
        case .invoice, .estimate, .changeOrder, .contract: return ["money"]
        case .employee, .subcontractor: return ["team"]
        case .receipt, .job: return ["expenses"]
        case .priceItem: return ["catalog"]
        case .project, .business, .workSchedule, .appSettings, .goldLifeID, .deviceInfo: return ["settings"]
        default: return []
        }
    }

    @MainActor
    private func buildDomainSystemPrompt() -> String {
        var sections: [String] = []
        sections.append(MBAppGuide.markdown(languageCode: MBLocalization.resolvedLanguageCode))

        // Non-secret Gold Life ID profile details
        let identity = MBIdentity.shared.current
        var profileLines: [String] = []
        let fullName = "\(identity.firstName) \(identity.lastName)".trimmingCharacters(in: .whitespacesAndNewlines)
        if !fullName.isEmpty {
            profileLines.append("User Name: \(fullName)")
        }
        if !identity.email.isEmpty {
            profileLines.append("User Email: \(identity.email)")
        }
        if !identity.phone.isEmpty {
            profileLines.append("User Phone: \(identity.phone)")
        }
        let streetLine = [identity.address.number, identity.address.street]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let addressParts = [streetLine, identity.address.city, identity.address.state, identity.address.zip]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if !addressParts.isEmpty {
            profileLines.append("User Mailing Address: \(addressParts.joined(separator: ", "))")
        }
        let isMember = SubscriptionManager.shared.isSubscribed || SubscriptionManager.shared.serverEntitled
        profileLines.append("Gold Life Member: \(isMember ? "Yes" : "No")")

        if let store = attachedStore, let business = MBRecordLookup.businessProfile(in: store) {
            if !business.businessName.isEmpty {
                profileLines.append("Business Name: \(business.businessName)")
            }
            if !business.phone.isEmpty {
                profileLines.append("Business Phone: \(business.phone)")
            }
            if !business.email.isEmpty {
                profileLines.append("Business Email: \(business.email)")
            }
        }

        if !profileLines.isEmpty {
            sections.append("[User & Business Context]\n" + profileLines.joined(separator: "\n"))
        }

        sections.append("""
        [Voice & Formatting]
        Speak naturally like a knowledgeable human colleague in warm, flowing sentences and short paragraphs. Never reply with bulleted lists, outlines, or bolded feature dumps unless the user explicitly asks for a list or step-by-step instructions. When asked about the app or its interface, explain it naturally in a few conversational sentences.
        """)

        return sections.joined(separator: "\n\n")
    }

    func hostContext() -> GLAIHostContext {
        let store = attachedStore
        let business = store.flatMap { MBRecordLookup.businessProfile(in: $0) }
        return GLAIHostContext(
            language: MBLocalization.resolvedLanguageCode,
            appVersion: Self.appVersion,
            businessName: business?.businessName,
            onScreen: onScreen,
            timeZone: .current,
            now: .now)
    }

    static var appVersion: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        return "\(short) (\(build))"
    }

    // MARK: The fence

    /// Stops the loop and waits for it, BEFORE the store unmounts. Safe to call when nothing is
    /// running.
    func cancelAndWait() async {
        let running = controller
        detachNow()
        await running?.cancelAndWait()
    }

    /// The synchronous half, for the two doors that can't await (entering and leaving sample
    /// data). Dropping the store FIRST is what matters: every tool asks `env.context()` at the
    /// moment it runs and `isStillCurrent` right before it writes, so once this returns nothing
    /// can reach the container that is about to unmount. The loop is then stopped right behind it.
    func detachNow() {
        presenter.cancelPending()
        attachedStore = nil
        transport = nil
        directTransport = nil
        usage = nil
        let running = controller
        controller = nil
        toolbox = nil
        storedOnDevice = nil
        environment.ledger.clear()
        guard let running else { return }
        Task { await running.cancelAndWait() }
    }

    /// Re-reads this month's usage (GET ai/usage). A failed read keeps the last answer (the bar
    /// is information; the server enforces the limit), so it never flickers away mid-chat.
    func refreshUsage() async {
        guard let transport else { return }
        let store = attachedStore
        guard let fresh = await transport.fetchUsage(), attachedStore === store, store != nil else { return }
        usage = fresh
    }

    /// Sign-out and account switch: the conversation goes, and so does consent (contract §4).
    func endSession() async {
        await cancelAndWait()
        consent.reset()
    }

    /// First launch after the rebuild: the pre-v2 yes/no flag is deleted (law 26). It never
    /// counted as consent (law 74), and deleting it grants nothing.
    static func removeLegacyConsent() {
        GLAIConsent.myBusiness().removeLegacyConsent()
    }
}
