//
//  UnrenderedScreensCoverageTests.swift
//
//  Render coverage for the screens ViewRenderingTests never reached. Six of them
//  were at or near ZERO percent — Stripe Connect (0.3%), About (1.2%),
//  the paywall (1.6%), the Gold Life ID views (2.3%) and prompt (11.4%),
//  What's New (12.1%) — meaning nothing verified they even build a body without
//  trapping. That is exactly where a crash hides: SettingsScreen's missing
//  environment object took the whole test process down for weeks and nothing
//  caught it, because the screen that crashed was rendered but the ones here
//  were not rendered at all.
//
//  Hosted through GLTestHost (a UIWindow, forced layout, the run loop drained so
//  `.task`/`.onAppear` fire). Asserting "renders without trapping" is the point —
//  these screens have no return value to check. The contractor-package screens
//  are rendered state by state in ContractorPackageCoverageTests, not here.
//

import Testing
import SwiftUI
import GoldLifeID
import GoldLifeUI
import SwiftData
import StoreKit
import UIKit
import GoldLifeAI
@testable import GLSmallBusiness

@Suite(.serialized)
@MainActor
struct UnrenderedScreensCoverageTests {

    // MARK: - Monetization surfaces (paywall, Stripe) — 0–2% covered before this

    @Test func rendersPaywallInBothSchemes() throws {
        let world = try TestStore.demoWorld()
        GLTestHost.renderBothSchemes(PaywallSheet(), container: world.container)
        GLTestHost.render(PaywallSheet(context: .upgrade), container: world.container)

        // PaywallSheet view extension
        GLTestHost.render(Text("Host").paywallSheet(isPresented: .constant(true)), container: world.container)

        // Error log reasons mapping
        #expect(PaywallSheet.restoreLogReason(for: StoreKitError.userCancelled) == "user_cancelled")
        #expect(PaywallSheet.restoreLogReason(for: StoreKitError.networkError(URLError(.notConnectedToInternet))) == "network")
        #expect(PaywallSheet.restoreLogReason(for: StoreKitError.notAvailableInStorefront) == "not_in_storefront")
        #expect(PaywallSheet.restoreLogReason(for: NSError(domain: "test", code: 1)) == "other")

        // Headlines and sublines in non-lapsed state
        #expect(PaywallSheet.headline(context: .atCap, isLapsed: false) == mbLoc("You’ve reached the free limit"))
        #expect(PaywallSheet.headline(context: .upgrade, isLapsed: false) == mbLoc("Subscribe to My Business"))
        #expect(!PaywallSheet.subline(isLapsed: false).isEmpty)

        // Empty store states (nothing to sell & unreachable)
        SubscriptionManager.shared.loadState = .loaded
        GLTestHost.render(PaywallSheet(), container: world.container)

        SubscriptionManager.shared.loadState = .failed
        GLTestHost.render(PaywallSheet(), container: world.container)

        // Lapsed state
        SubscriptionManager.shared.statusKnown = true
        SubscriptionManager.shared.historyKnown = true
        SubscriptionManager.shared.hasEverSubscribed = true
        SubscriptionManager.shared.isSubscribed = false
        #expect(PaywallSheet.headline(context: .atCap, isLapsed: true) == mbLoc("Your subscription ended"))
        #expect(PaywallSheet.subline(isLapsed: true).contains("Reactivate"))
        GLTestHost.render(PaywallSheet(), container: world.container)
        GLTestHost.render(PaywallSheet(context: .upgrade), container: world.container)

        // Reset
        SubscriptionManager.shared.hasEverSubscribed = false
        SubscriptionManager.shared.loadState = .loading
    }

    @Test func rendersStripeConnectScreen() throws {
        let world = try TestStore.demoWorld()
        UserDemoMode.shared.isDemoActive = false
        world.profile.stripeConnectedAccountId = ""
        world.profile.stripeChargesEnabled = false
        GLTestHost.renderBothSchemes(StripeConnectScreen(), container: world.container)

        // Sample data active branch
        UserDemoMode.shared.isDemoActive = true
        GLTestHost.render(StripeConnectScreen(), container: world.container)
        UserDemoMode.shared.isDemoActive = false
    }

    /// The Stripe screen with a CONNECTED, charge-ready account — the finished
    /// state, which is a different branch from the onboarding one above.
    @Test func rendersStripeConnectWhenAlreadyConnected() throws {
        let world = try TestStore.demoWorld()
        UserDemoMode.shared.isDemoActive = false
        world.profile.stripeConnectedAccountId = "acct_test"
        world.profile.stripeChargesEnabled = true
        world.profile.payLinkDefaultOn = true
        GLTestHost.render(StripeConnectScreen(), container: world.container)

        // With pay button toggle off
        world.profile.payLinkDefaultOn = false
        GLTestHost.render(StripeConnectScreen(), container: world.container)

        // Pending review (connected but charges not yet enabled)
        world.profile.stripeChargesEnabled = false
        GLTestHost.render(StripeConnectScreen(), container: world.container)
    }

    // MARK: - Identity surfaces (Gold Life ID) — LIVE, composed from the kit
    // (2026-08-30: the flag-era prompt/settings-section/buttons are retired;
    // the fleet sheet and the pushed deletion screen are the real surfaces).

    @Test func rendersGoldLifeIDSurfaces() throws {
        let world = try TestStore.demoWorld()
        let auth = GoldLifeAuth()
        GLTestHost.renderBothSchemes(GoldLifeIDScreen(), container: world.container)
        GLTestHost.renderBothSchemes(SignInScreen(auth: auth), container: world.container)
        GLTestHost.renderBothSchemes(GateView(), container: world.container)
        GLTestHost.render(GoldLifeEmailSignInSheet(auth: auth), container: world.container)
        GLTestHost.renderBothSchemes(GoldLifeIDDeletionScreen(), container: world.container)
    }

    // MARK: - Informational screens

    @Test func rendersAboutAndWhatsNew() throws {
        let world = try TestStore.demoWorld()
        GLTestHost.renderBothSchemes(AboutScreen(), container: world.container)
        GLTestHost.render(WhatsNewScreen(), container: world.container)
    }

    // MARK: - Gold Life ID error states
    // (The -glIDEnabled flag era ended 2026-08-30: the surfaces have shipped
    // unconditionally since the hard-gate retrofit, and the flag enum left
    // with the retired prompt file. These pin the ERROR branches instead.)

    /// Busy and error-posted branches of the live sheet render without touching
    /// the network or the Keychain (`load()` returns early signed out; nothing
    /// destructive runs without a tap).
    @Test func goldLifeIDSheetRendersItsBusyAndErrorBranches() throws {
        let container = try TestStore.makeContainer()
        let auth = GoldLifeAuth()
        #expect(!auth.isSignedIn)

        auth.isBusy = true
        GLTestHost.render(GoldLifeEmailSignInSheet(auth: auth), container: container)

        auth.isBusy = false
        auth.errorMessage = GoldLifeAuth.signInFailureMessage(URLError(.timedOut))
        GLTestHost.render(GoldLifeEmailSignInSheet(auth: auth), container: container)
    }

    /// The sign-in surfaces are NOT behind the flag — they are reachable views that
    /// Signed out is the only state a test can reach without a live Stytch
    /// session, and it is also the state a first-time user sees.
    @Test func goldLifeIDSignInSurfacesRenderSignedOut() throws {
        let container = try TestStore.makeContainer()
        let auth = GoldLifeAuth()
        #expect(!auth.isSignedIn, "a fresh auth is signed out, so no network is touched")
        GLTestHost.render(GoldLifeEmailSignInSheet(auth: auth), container: container)
    }

    /// The sign-in error copy still resolves — the sheet body renders with an
    /// error posted on the engine (the kit sheet owns the per-face error rows).
    @Test func goldLifeSignInSheetShowsItsErrorState() throws {
        let container = try TestStore.makeContainer()
        let auth = GoldLifeAuth()
        auth.errorMessage = GoldLifeAuth.signInFailureMessage(URLError(.notConnectedToInternet))
        #expect(auth.errorMessage?.contains("not connected to the internet") == true)
        GLTestHost.render(GoldLifeEmailSignInSheet(auth: auth), container: container)
    }

    // MARK: - Assistant & Price Sheet catalog

    @Test func rendersAssistantAndPriceSheetScreens() throws {
        let world = try TestStore.demoWorld()
        // The assistant, every way it is opened: the tab's own screen, the iPad Assistant column
        // (which borrows the split view's navigation controller instead of stacking a second one),
        // and the sparkles sheet over a record. Its messages, gates and consent sheet are rendered
        // in AssistantKeepTests.
        GLTestHost.renderBothSchemes(AssistantScreen(), container: world.container)
        GLTestHost.render(AssistantScreen(ownsStack: false), container: world.container)
        let estimate = try #require(world.estimates.first)
        let onScreen = GLAIOnScreen(kind: "estimate",
                                    id: estimate.syncID?.uuidString ?? UUID().uuidString,
                                    label: estimate.number)
        GLTestHost.render(AssistantScreen(onScreen: onScreen, isSheet: true), container: world.container)
        GLTestHost.renderBothSchemes(PriceSheetScreen(), container: world.container)

        let item = PriceSheetItem(
            name: "Ceramic Tile Installation",
            details: "Standard floor prep, thin-set mortar, 12x24 porcelain tile.",
            defaultQuantity: 250,
            unit: .squareFoot,
            unitPrice: 14.50,
            kind: .labor,
            isTaxable: false,
            category: "Tile Work",
            discountType: .percentage,
            discountValue: 10
        )
        world.context.insert(item)
        world.context.saveChanges()

        GLTestHost.render(PriceSheetScreen(), container: world.container)
        GLTestHost.render(PriceSheetItemFormScreen(editing: nil), container: world.container)
        GLTestHost.render(PriceSheetItemFormScreen(editing: item), container: world.container)
    }

    // MARK: - Subscription management

    @Test func rendersSubscriptionScreen() throws {
        let world = try TestStore.demoWorld()
        GLTestHost.renderBothSchemes(SubscriptionScreen(), container: world.container)

        SubscriptionManager.shared.isVip = true
        GLTestHost.render(SubscriptionScreen(), container: world.container)
        SubscriptionManager.shared.isVip = false

        SubscriptionManager.shared.statusKnown = true
        SubscriptionManager.shared.isSubscribed = true
        GLTestHost.render(SubscriptionScreen(), container: world.container)

        SubscriptionManager.shared.isSubscribed = false
        SubscriptionManager.shared.historyKnown = true
        SubscriptionManager.shared.hasEverSubscribed = true
        GLTestHost.render(SubscriptionScreen(), container: world.container)
        SubscriptionManager.shared.hasEverSubscribed = false
    }

    // MARK: - Legal, How-To, and Navigation roots

    @Test func rendersLegalWebSheetsAndHowTo() throws {
        let world = try TestStore.demoWorld()
        GLTestHost.render(PrivacyPolicySheet(), container: world.container)
        GLTestHost.render(TermsOfUseSheet(), container: world.container)
        GLTestHost.render(HowToScreen(), container: world.container)
        // An address that isn't one shows the "couldn't load" state instead of trapping.
        GLTestHost.render(HowToScreen(address: "http://[::1"), container: world.container)
    }

    @Test func rendersSettingsAndPreferencesScreens() throws {
        let world = try TestStore.demoWorld()
        GLTestHost.render(LanguageScreen(), container: world.container)
        GLTestHost.render(AppearanceScreen(), container: world.container)
        // The Gold Life ID's own pickers come straight from the package (law 48a); the app's
        // empty wrappers were removed with gl_prefs (audit 2026-10-03 F20).
        GLTestHost.render(GoldLifeIDLanguageScreen(), container: world.container)
        GLTestHost.render(GoldLifeIDAppearanceScreen(), container: world.container)
    }

    @Test func rendersCustomerSelectionAndRootViews() throws {
        let world = try TestStore.demoWorld()
        GLTestHost.render(PickCustomerThenScreen(title: "New Estimate") { _ in Text("Dest") }, container: world.container)
        GLTestHost.renderBothSchemes(CustomerFormScreen(), container: world.container)
        if let cust = world.customers.first {
            GLTestHost.renderBothSchemes(CustomerFormScreen(editing: cust), container: world.container)
        }
        let empty = try TestStore.makeContainer()
        GLTestHost.render(PickCustomerThenScreen(title: "New Estimate") { _ in Text("Dest") }, container: empty)

        GLTestHost.render(RootTabView(), container: world.container)
        GLTestHost.render(RootView(), container: world.container)
        GLTestHost.render(AppGate(), container: world.container)
        GLTestHost.render(IPadRootSplitView(initialSection: "calendar"), container: world.container, size: GLTestHost.pad, sizeClass: .regular)
        GLTestHost.render(IPadRootSplitView(initialSection: "assistant"), container: world.container, size: GLTestHost.pad, sizeClass: .regular)

        let routerCust = AppRouter()
        routerCust.contactsKind = .customers
        GLTestHost.render(IPadRootSplitView(initialSection: "contacts").environment(routerCust), container: world.container, size: GLTestHost.pad, sizeClass: .regular)

        let routerEmp = AppRouter()
        routerEmp.contactsKind = .employees
        GLTestHost.render(IPadRootSplitView(initialSection: "contacts").environment(routerEmp), container: world.container, size: GLTestHost.pad, sizeClass: .regular)

        let routerSub = AppRouter()
        routerSub.contactsKind = .subcontractors
        GLTestHost.render(IPadRootSplitView(initialSection: "contacts").environment(routerSub), container: world.container, size: GLTestHost.pad, sizeClass: .regular)

        // Tab-root screen variations with toolbars, search, and action menus
        GLTestHost.renderBothSchemes(AllJobsScreen(isTabRoot: true), container: world.container)
        GLTestHost.renderBothSchemes(AllEstimatesScreen(), container: world.container)
        GLTestHost.renderBothSchemes(AllInvoicesScreen(), container: world.container)
        GLTestHost.renderBothSchemes(AllChangeOrdersScreen(), container: world.container)
        GLTestHost.renderBothSchemes(AllReceiptsScreen(), container: world.container)
        GLTestHost.renderBothSchemes(CustomersScreen(), container: world.container)
        GLTestHost.renderBothSchemes(ContactsScreen(), container: world.container)
        GLTestHost.renderBothSchemes(EmployeesScreen(isTabRoot: true), container: world.container)
        GLTestHost.renderBothSchemes(SubcontractorsScreen(isTabRoot: true), container: world.container)
        GLTestHost.renderBothSchemes(ReceiptsTabScreen(), container: world.container)
        GLTestHost.render(ReceiptsTabScreen(), container: world.container, size: GLTestHost.pad, sizeClass: .regular)

        if let customer = world.customers.first {
            GLTestHost.renderBothSchemes(CustomerCOIDetailScreen(customer: customer), container: world.container)
            GLTestHost.renderBothSchemes(CustomerWCCOIDetailScreen(customer: customer), container: world.container)
        }
    }

    // MARK: - Universal Profile, Preferences & Banner Chrome Coverage

    @Test func universalProfileAndPreferencesCoverage() throws {
        // GLProfileManager (the per-app profile read and its 'gl_profile_cache') is retired:
        // GoldLifeID owns the identity record (audit 2026-10-03 F38/F93, law 48).
        // Test GLProfileContact wire fields
        let contact = GLProfileContact(
            firstName: "Jane",
            middleName: "Marie",
            lastName: "Doe",
            phone: "555-987-6543",
            addressNumber: "456",
            addressStreet: "Oak Ave",
            addressCity: "Orlando",
            addressState: "FL",
            addressZip: "32801"
        )
        let wire = contact.wireFields
        #expect(wire["first_name"] == "Jane")
        #expect(wire["middle_name"] == "Marie")
        #expect(wire["last_name"] == "Doe")
        #expect(wire["phone"] == "555-987-6543")
        #expect(wire["address_number"] == "456")
        #expect(wire["address_street"] == "Oak Ave")
        #expect(wire["address_city"] == "Orlando")
        #expect(wire["address_state"] == "FL")
        #expect(wire["address_zip"] == "32801")

        // (GLProfileMigrator, the per-app upload to the retired profile API, is gone: the legacy
        // upload is GLGoldLifeIDSync.runLegacyUpload, covered in GLGoldLifeIDSyncTests.)
        let world = try TestStore.demoWorld()

        // AppearanceStore coverage
        let appStore = AppearanceStore.shared
        for c in AppearancePref.pickerCases {
            #expect(!c.label.isEmpty)
            #expect(!c.id.isEmpty)
            appStore.set(c)
            #expect(appStore.pref == c)
            _ = appStore.colorScheme
        }
        appStore.set(.goldLife)

        // System Banners chrome rendering
        GLTestHost.render(GLOfflineBanner(), container: world.container)
        GLTestHost.render(GLSampleDataBanner(onExit: {}), container: world.container)
        GLTestHost.render(Text("Banner Harness").mbSystemBanners(), container: world.container)
    }
}
