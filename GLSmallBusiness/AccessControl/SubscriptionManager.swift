import Foundation
import GoldLifeCloud
import GoldLifeUI
import OSLog
import StoreKit

typealias SubscriptionManager = GLSubscription

extension GLSubscription {
    @MainActor
    public static let shared = GLSubscription(
        appID: "my_business",
        // The real bundle id (project PRODUCT_BUNDLE_IDENTIFIER, contract A11). GLSubscription
        // stores it and reads it nowhere today; it was "com.evolvedbygl.SmallBusinessApp".
        bundleID: "com.evolvedbygl.GLSmallBusiness",
        groupID: "22148954",
        // Only the Unlimited (Pro) plans open the app; the AI Assistant is 100% free via BYOK.
        entitlingProductIDs: [
            "mybusiness.pro.monthly": .single,
            "mybusiness.pro.yearly": .single
        ],
        isDemoActive: {
            MainActor.assumeIsolated { DemoMode.isActive || UserDemoMode.shared.isDemoActive }
        },
        fetchEntitlement: {
            try await GoldLifeAPI.shared.fetchEntitlement(app: "my_business")
        },
        // THE history read (owner ruling 2026-08-25, audit 2026-10-03 F15): it is what tells a
        // lapsed subscriber (read-only) from someone who never subscribed (the free tier) while
        // the server has no My Business standing. Dropping it once (2026-09-18) silently ended
        // every lapse; SubscriptionStandingTests pins that it is here.
        purchaseHistory: GLSubscription.storeKitPurchaseHistory,
        // The latest App Store transaction goes to gl-money-api at launch, after a purchase or
        // a restore, and on expiry (every status delivery), so the server records the standing.
        recordTransaction: { jws in await GLSubscription.recordStanding(jws: jws) }
    )

    /// `POST /entitlement/my-business {jws}` — built in one place so its shape is testable
    /// without a network. nil only if the body can't be encoded.
    nonisolated static func standingRequest(jws: String) -> GLCloudRequest? {
        guard let body = try? JSONEncoder().encode(["jws": jws]) else { return nil }
        return GoldLifeAPI.request("entitlement/my-business", method: "POST", body: body)
    }

    /// The standing in the server's reply, or nil when it named none this app knows.
    nonisolated static func standing(fromReply data: Data) -> GLStanding? {
        struct Reply: Decodable { let standing: String? }
        guard let raw = (try? JSONDecoder().decode(Reply.self, from: data))?.standing else { return nil }
        return GLStanding(rawValue: raw)
    }

    /// Sends one transaction through GLCloudTransport (law 59) and returns the server's standing.
    /// Every failure is silent and nil: a 404 from a Worker without the route, offline, a 409
    /// (the transaction belongs to another Gold Life ID), a 403. Nobody started this send, so
    /// nothing is shown; the log carries the status code only, never the JWS.
    nonisolated static func recordStanding(jws: String) async -> GLStanding? {
        guard let request = standingRequest(jws: jws) else { return nil }
        do {
            return standing(fromReply: try await GoldLifeAPI.shared.send(request))
        } catch GoldLifeAPIError.badStatus(let code) {
            await MainActor.run {
                Logger.access.info("record standing not recorded status=\(code, privacy: .public)")
            }
            return nil
        } catch {
            return nil
        }
    }

    public static let monthlyID = "mybusiness.pro.monthly"
    public static let annualID = "mybusiness.pro.yearly"
    /// Gold Life sells no AI subscription; the Assistant is 100% free via BYOK.
    nonisolated public static let aiMonthlyID = "mybusiness.ai.monthly"
    nonisolated public static let aiAnnualID = "mybusiness.ai.yearly"
    nonisolated public static let aiProductIDs: Set<String> = [aiMonthlyID, aiAnnualID]
    /// Every product that keeps the app writable — the Subscription screen prices the term the
    /// person is on from this list.
    public static let productIDs = [monthlyID, annualID]
    public static let groupID = "22148954"

    public static let entitledStates: [Product.SubscriptionInfo.RenewalState] =
        [.subscribed, .inGracePeriod, .inBillingRetryPeriod]

    public var isVip: Bool {
        get { serverEntitled }
        set { }
    }

    public func checkVipStatus() async {
        await refreshServerEntitlement()
    }

    #if DEBUG
    // QA/screenshot override, DEBUG ONLY. The read-only app is otherwise unreachable without a
    // real expired subscription, so there is no way to LOOK at it — and a banner nobody has
    // seen at AX5 on an iPhone SE is a banner nobody has verified. It can only ever turn the
    // lapse ON: it grants nothing, unlocks nothing, and cannot be used to bypass the paywall.
    // Checked BEFORE the demo bypass so `-demoMode -forceLapsed` can capture the lapsed app.
    public static var isForceLapsed: Bool {
        ProcessInfo.processInfo.arguments.contains("-forceLapsed")
    }
    #endif
}
