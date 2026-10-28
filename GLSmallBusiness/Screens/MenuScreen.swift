//
//  MenuScreen.swift
//  GLSmallBusiness
//
//  Created by Gold Life LLC on 5/28/26.
//

import SwiftUI
import GoldLifeUI
import GoldLifeAI
import GoldLifeMoney
import SwiftData
import PhotosUI
import MessageUI
#if DEBUG
import GoldLifeCloud
#endif

// MARK: - Menu (app hub, presented from the Customers Menu button)

struct MenuScreen: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(GoldLifeAuth.self) private var auth
    @State private var mailUnavailable = false
    /// Read for the Gold Life ID card's member words (2026-10-03 audit F74).
    @State private var subscription = SubscriptionManager.shared

    private var isGoldLifeMember: Bool {
        Self.isGoldLifeMember(isSubscribed: subscription.isSubscribed,
                              serverEntitled: subscription.serverEntitled,
                              statusKnown: subscription.statusKnown)
    }
    /// The gate's "Explore with sample data" session (audit 2026-10-03 F36).
    @ObservedObject private var demo = UserDemoMode.shared
    #if DEBUG
    /// Only the sign-out warning's UI-test seam reads it (`MBSignOutWarningHarness`).
    @Environment(\.modelContext) private var modelContext
    #endif

    /// The DEBUG UI-test seam is on (never in Release).
    private static var isSignOutWarningHarness: Bool {
        #if DEBUG
        MBSignOutWarningHarness.isRequested
        #else
        false
        #endif
    }

    /// The developer's address (the Software venture alias; never a personal address).
    static let developerEmail = "support@softwarebygl.com"

    /// Where "Message the Developer" goes: the shared mail route (law 84 / PARITY "Contact
    /// links"), so it opens the person's chosen mail app (Mail or Gmail, Apple Mail when Gmail
    /// isn't installed) like every other email in the app, never a link built here (audit
    /// 2026-10-03 F45). Nil only if the address could not be mailed at all.
    static func developerMailDestination(mail: GLMailApp,
                                         canOpen: (URL) -> Bool) -> GLContactDestination? {
        GLContactRoute.destination(for: .email(address: developerEmail),
                                   maps: .appleMaps, messages: .messages, mail: mail, canOpen: canOpen)
    }

    /// Opens the developer email in the chosen mail app, then Apple Mail; when neither opens (no
    /// mail app on this device), the alert shows the address instead of a dead tap.
    private func messageTheDeveloper() {
        guard let destination = Self.developerMailDestination(mail: GLContactAppSettings.shared.mailApp,
                                                              canOpen: glCanOpenURL) else {
            mailUnavailable = true
            return
        }
        openURL(destination.primary) { accepted in
            guard !accepted else { return }
            guard let fallback = destination.fallback else { mailUnavailable = true; return }
            openURL(fallback) { opened in
                if !opened { mailUnavailable = true }
            }
        }
    }

    /// Whether the Gold Life ID card is a member's: a subscriber, a comp or owner account
    /// (`serverEntitled`), or a status not known yet. The last term is the rule build 88 dropped
    /// with the old card: a cold launch before StoreKit answers, or no signal, must never strip a
    /// paying owner's card.
    static func isGoldLifeMember(isSubscribed: Bool, serverEntitled: Bool, statusKnown: Bool) -> Bool {
        isSubscribed || serverEntitled || !statusKnown
    }

    /// Exploring sample data with no account behind it: the Menu's last button is "Exit Sample
    /// Mode" instead of a greyed-out "Sign out" (audit 2026-10-03 F36).
    /// A real session always wins (law 43).
    static func isSampleSession(demoActive: Bool, isSignedIn: Bool) -> Bool {
        demoActive && !isSignedIn
    }

    /// Whether the Sign out / Exit Sample Mode button is greyed out. Exit is always available in
    /// the sample; Sign out waits while sign-in is busy and needs an account to sign out of.
    static func isSignOutDisabled(isSampleSession: Bool, isBusy: Bool, isSignedIn: Bool,
                                  isHarness: Bool) -> Bool {
        guard !isSampleSession else { return false }
        return (isBusy || !isSignedIn) && !isHarness
    }

    private var isSampleSession: Bool {
        Self.isSampleSession(demoActive: demo.isDemoActive, isSignedIn: auth.isSignedIn)
    }

    var body: some View {
        GLMenuScreen(
            isSampleMode: isSampleSession,
            isSignOutDisabled: Self.isSignOutDisabled(isSampleSession: isSampleSession,
                                                      isBusy: auth.isBusy,
                                                      isSignedIn: auth.isSignedIn,
                                                      isHarness: Self.isSignOutWarningHarness),
            // Signing out wipes this iPhone's copy (law 13), so the alert names the changes not
            // backed up yet. Counted each time the alert opens, after folding the newest edits
            // into the outbox (audit 2026-10-03 F12): a count taken when the Menu appeared missed
            // an edit just saved in Settings or My Business Details.
            signOutMessageProvider: { await MBSessionPurge.currentSignOutMessage() },
            onSignOut: {
                // Decided when tapped, not when the Menu drew: the sample discards itself and
                // the gate opens again; nothing is signed out because nobody is signed in.
                if Self.isSampleSession(demoActive: UserDemoMode.shared.isDemoActive,
                                        isSignedIn: auth.isSignedIn) {
                    UserDemoMode.shared.exitDemo()
                    return
                }
                guard !Self.isSignOutWarningHarness else { return }
                Task { await auth.signOut() }
            },
            personalDestination: {
                // Sample data shows the fleet's sample person on the card too, matching the
                // Signature row (MBIdentity).
                // "Thank you", the letter and GOLD LIFE MEMBER are for members only (PARITY.md,
                // owner ruling 2026-08-23); a free or lapsed account gets the monogram card.
                GoldLifeIDScreen(isSampleMode: MBIdentity.shared.isSampleData,
                                 isMember: isGoldLifeMember,
                                 onExitSampleMode: {
                    dismiss()
                    UserDemoMode.shared.exitDemo()
                },
                                 appRows: {
                    MBSignatureRow()
                })
            },
            customSections: {
                Section("Business") {
                    NavigationLink {
                        MyCompanyDetailScreen()
                    } label: {
                        GLMenuRow("My Business Details", systemImage: "building.2")
                    }
                    NavigationLink {
                        BusinessProfileHost(placeholderTitle: mbLoc("Documents")) { profile in
                            AllDocumentsScreen(profile: profile)
                        }
                    } label: {
                        GLMenuRow("Documents", systemImage: "doc.on.doc")
                    }
                }

                Section("Reports") {
                    NavigationLink {
                        StatsScreen()
                    } label: {
                        GLMenuRow("Income & Expenses", systemImage: "chart.line.uptrend.xyaxis")
                    }
                }

                Section("Payments") {
                    MoneyMenuRow(isSampleMode: DemoMode.isActive || UserDemoMode.shared.isDemoActive)
                        .accessibilityIdentifier("menu.connectedBanksAndMoney")
                        .mbMoneyHostEnvironment()
                    NavigationLink {
                        StripeConnectScreen()
                    } label: {
                        GLMenuRow("Connect Stripe", systemImage: "building.columns")
                    }
                    NavigationLink {
                        ZelleConnectScreen()
                    } label: {
                        GLMenuRow("Connect Zelle", systemImage: "qrcode")
                    }
                }

                if MBFeatureFlags.assistantEnabled {
                    GLAIMenuSection()
                }
            },
            supportRows: {
                NavigationLink {
                    WhatsNewScreen()
                } label: {
                    GLMenuRow("What’s New", systemImage: "sparkles")
                }
                NavigationLink {
                    HowToScreen()
                } label: {
                    GLMenuRow("How To", systemImage: "questionmark.circle")
                }
                Button {
                    messageTheDeveloper()
                } label: {
                    GLMenuRow("Message the Developer", systemImage: "envelope",
                              subtitle: "Ideas, feedback, or a bug \u{2014} it comes straight to me.")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            },
            appRows: {
                NavigationLink {
                    SubscriptionScreen()
                } label: {
                    GLMenuRow("Subscription", systemImage: "checkmark.seal")
                }
                NavigationLink {
                    SettingsScreen()
                } label: {
                    GLMenuRow("Settings", systemImage: "gearshape")
                }
                NavigationLink {
                    AboutScreen()
                } label: {
                    GLMenuRow("About", systemImage: "info.circle")
                }
            },
            // The standing notices (sample data, offline, lapsed) under the bar: one slot, the
            // same on every screen (QA 2026-10-03 F34).
            bannerInset: { MBSystemBannerInset() }
        )
        #if DEBUG
        .task {
            guard MBSignOutWarningHarness.isRequested else { return }
            MBSignOutWarningHarness.prepare(modelContext.container)
        }
        #endif
        .alert("No email app set up", isPresented: $mailUnavailable) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Email me any time at support@softwarebygl.com \u{2014} I read every message.")
        }
    }
}

#if DEBUG
/// UI-test seam for the sign-out warning (`-demoMode -uiTestSignOutWarning`, DEBUG only; audit
/// 2026-10-03 F12 proof). The demo store has no Gold Life ID and no sync engine, so this gives it
/// an engine with no session (it never reaches the network) and turns Sign Out on without signing
/// anyone out. The alert's count then runs the production path,
/// `MBSessionPurge.unsyncedChanges(engine:context:)`.
@MainActor
enum MBSignOutWarningHarness {
    static var isRequested: Bool {
        DemoMode.isActive && ProcessInfo.processInfo.arguments.contains("-uiTestSignOutWarning")
    }

    private(set) static var active: (engine: GLSyncEngine, container: ModelContainer)?

    /// Once per launch: sync ids for the seeded records, a history baseline (what the first
    /// signed-in cycle sets), and the offline engine.
    static func prepare(_ container: ModelContainer) {
        guard isRequested, active == nil else { return }
        SyncIdentityBackfill.run(ModelContext(container))
        GLSyncLocalStore(container: container).establishHistoryBaseline()
        let noSession: @Sendable () -> String? = { nil }
        let engine = GLSyncEngine(
            container: container,
            tokens: GLSyncTokenProvider(transport: .shared, storedSessionJWT: noSession, onSessionExpired: {}),
            cloud: .shared,
            documents: GLSyncDocumentCrypto(transport: .shared, storedSessionJWT: noSession, onSessionExpired: {}))
        active = (engine, container)
    }
}
#endif

// MARK: - Business profile host (the ONE owner of the singleton)

/// Anything that renders FROM the business-profile singleton pushes through here.
///
/// The singleton is created lazily, so on a brand-new store `profiles.first` is nil and any
/// destination that read it directly built to NOTHING — a blank screen with a back button.
/// This host owns the bootstrap instead: it inserts the empty singleton once, falls back to a
/// transient placeholder when a lapsed (or offline) app refuses that insert, and hands the
/// content a real profile either way. One owner, so the blank screen can't come back.
/// Internal (not private): the assistant's `open compliance_docs` router pushes through the SAME
/// owner, so a brand-new store bootstraps the singleton there too instead of spinning forever.
struct BusinessProfileHost<Content: View>: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var profiles: [BusinessProfile]
    @State private var ensuredProfile = false
    /// The read-only stand-in for the singleton. Held (never inserted) only when a LAPSED app
    /// declined to bootstrap one — see the `.task` below.
    @State private var readOnlyPlaceholder: BusinessProfile?
    private var network = NetworkMonitor.shared
    /// The bar title for the moment before the singleton exists. Pass it only when `content`
    /// titles itself; leave it nil when the caller titles the host from outside
    /// (MyCompanyDetailScreen), so the title is never applied twice.
    private let placeholderTitle: String?
    private let content: (BusinessProfile) -> Content

    init(placeholderTitle: String? = nil, @ViewBuilder content: @escaping (BusinessProfile) -> Content) {
        self.placeholderTitle = placeholderTitle
        self.content = content
    }

    var body: some View {
        Group {
            if let profile = profiles.first ?? readOnlyPlaceholder {
                content(profile)
            } else if let placeholderTitle {
                // Law 57: a pushed screen is never untitled, not even for the moment the
                // singleton is being bootstrapped — wear the title `content` is about to set.
                Color.clear
                    .navigationTitle(GLScript.padded(placeholderTitle))
                    .toolbarTitleDisplayMode(.large)
                    .contentMargins(.top, GLScript.titleClearance(for: GLScript.padded(placeholderTitle)), for: .scrollContent)
            } else {
                Color.clear
            }
        }
        .task {
            // Create the single profile once, and only if there genuinely isn't one — guarding
            // against a transient empty state during sync (or a repeated onAppear) inserting a dup.
            guard !ensuredProfile, profiles.isEmpty else { return }
            ensuredProfile = true
            // Bootstrap only: an empty singleton so the screen has something to show. The fields
            // are written by `MyCompanyFormScreen.save()`, which is gated on the lapse.
            //
            // It is still an INSERT, and an insert syncs — so a lapsed app does not make it. It
            // renders from a transient `BusinessProfile` instead: never inserted, so nothing is
            // written and nothing reaches the server, and the person still sees their (empty)
            // details screen rather than the blank one that refusing outright would leave. No
            // alert, because nobody tapped anything — the lapsed banner above this screen is what
            // says why it's empty. Unattended, so the log line is not optional.
            guard ReadOnlyGate.allowsUnattended(.saveBusinessProfile) else {
                // Not latched: the refusal can be OFFLINE, which clears on its own. Leaving
                // `ensuredProfile` false lets the retry below bootstrap the real singleton the
                // moment writes are allowed again, so the stand-in never becomes the thing the
                // person edits for a whole session.
                ensuredProfile = false
                readOnlyPlaceholder = BusinessProfile()
                return
            }
            modelContext.insert(BusinessProfile())
        }
        // Connectivity coming back is the common case: bootstrap for real and drop the stand-in.
        .onChange(of: network.isConnected) { _, connected in
            guard connected, !ensuredProfile, profiles.isEmpty,
                  ReadOnlyGate.allowsUnattended(.saveBusinessProfile) else { return }
            ensuredProfile = true
            readOnlyPlaceholder = nil
            modelContext.insert(BusinessProfile())
        }
    }
}

// MARK: - My Company (read-only view + Edit, mirroring the app's view -> Edit -> form pattern)

struct MyCompanyDetailScreen: View {
    @Environment(\.colorScheme) private var colorScheme
    @State private var showingEdit = false
    @State private var reviewSend: ReviewSendAction?
    @State private var reviewSendFailed = false
    /// Set when a lapsed subscription refuses a write — the alert names it (ReadOnlyGate.swift).
    @State private var readOnlyRefusal: MBWriteOperation?

    private enum ReviewSendAction: String, Identifiable {
        case text, email
        var id: String { rawValue }
    }

    private var gold: Color { GLTheme.accentFill }

    var body: some View {
        // The host owns the singleton (and the lapsed placeholder), so the Edit form and the
        // review sheet are handed the SAME profile this screen is rendering. They used to read
        // `profiles.first` on their own, which is nil for a lapsed app running on the
        // placeholder — Edit pushed a blank screen.
        BusinessProfileHost { profile in
            detail(profile)
                .navigationDestination(isPresented: $showingEdit) {
                    MyCompanyFormScreen(profile: profile)
                }
                .sheet(item: $reviewSend) { action in
                    reviewSendSheet(for: action, profile: profile).glAppearance(colorScheme)
                }
        }
        .navigationTitle(GLScript.padded(mbLoc("My Business Details")))
        .toolbarTitleDisplayMode(.large)   // large so Income & Expenses (pushed from here) renders large too
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                // Law 40: a one-option menu is banned — the action IS the button.
                Button("Edit") { showingEdit = true }
            }
        }
        .readOnlyRefusalAlert($readOnlyRefusal)
        .alert("Couldn’t send", isPresented: $reviewSendFailed) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("We couldn’t send your review request. Check your internet connection and try again.")
        }
    }

    /// The Mail / Messages compose sheet for the review request — same pattern as the invoice send
    /// flow, minus the PDF. No recipient is pre-filled; the owner picks the customer in the sheet.
    @ViewBuilder
    private func reviewSendSheet(for action: ReviewSendAction, profile: BusinessProfile) -> some View {
        switch action {
        case .email:
            MailComposeView(
                recipients: [],
                subject: ReviewRequestMessage.subject(business: profile),
                body: ReviewRequestMessage.htmlBody(business: profile),
                isHTML: true,
                attachmentURL: nil
            ) { outcome in
                reviewSend = nil
                if outcome == .failed { reviewSendFailed = true }
            }
        case .text:
            MessageComposeView(
                recipients: [],
                body: ReviewRequestMessage.plainBody(business: profile),
                attachmentURLs: [EstimateMessage.logoAttachmentURL(business: profile)].compactMap { $0 }
            ) { outcome in
                reviewSend = nil
                if outcome == .failed { reviewSendFailed = true }
            }
        }
    }

    private func detail(_ profile: BusinessProfile) -> some View {
        // A grouped FORM, not a hand-built ScrollView (owner ruling 2026-08-22,
        // Apple-flow): system sentence-case headers and one card per section via
        // the shared skin; the logo hero rides as a clear row.
        Form {
            Section {
                VStack(spacing: 16) {
                    logo(profile)
                    Text(profile.businessName.isEmpty ? mbLoc("Your business") : profile.businessName)
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(profile.businessName.isEmpty ? GLTheme.textSecondary : GLTheme.textPrimary)
                }
                // 12pt top padding clears iOS 26's section corner mask; centered
                // content is capsule-safe without a companion row (the List
                // clear-row gotchas, 2026-08-22).
                .padding(.top, 12)
                .frame(maxWidth: .infinity)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
                .listRowSeparator(.hidden)
            }

            Section("Contact") {
                infoRow("Name", profile.ownerFullName)
                contactRow("Email", .email, profile.email)
                contactRow("Phone", .phone, profile.phone)
            }

            // Foundational details INLINE — no extra click for the basics
            // (owner ask 2026-08-22; the separate "More Info" screen is gone).
            Section("Business Info") {
                infoRow("License #", profile.licenseNumber)
                infoRow("Website", profile.websiteURL)
                infoRow("Reviews link", profile.reviewsURL)
            }

            Section("Address") {
                let addr = addressText(profile)
                if addr.isEmpty {
                    Text("—")
                        .foregroundStyle(GLTheme.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    GLContactLink(.address, profile.address.singleLine, display: addr)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            Section("Tax details (W-9)") {
                infoRow("Name", profile.w9Name)
                infoRow("Classification", classificationText(profile))
                infoRow("Tax ID", maskedTIN(profile))
            }

            // ONE titled door to every document AND record (owner restructure,
            // 2026-08-22: Job Records moved off the Menu into here).
            Section("Documents & Records") {
                NavigationLink {
                    AllDocumentsScreen(profile: profile)
                } label: {
                    Label {
                        HStack {
                            Text("Documents")
                            Spacer()
                            if profile.hasComplianceDocuments {
                                Image(systemName: "checkmark.seal.fill")
                                    .font(.footnote)
                                    .foregroundStyle(gold)
                            }
                        }
                    } icon: {
                        Image(systemName: "doc.on.doc")
                            .foregroundStyle(gold)
                    }
                }
            }

            Section("Customer Reviews") {
                if profile.reviewsLink != nil {
                    Menu {
                        if MFMessageComposeViewController.canSendText() {
                            Button {
                                if ReadOnlyGate.allows(.sendDocument, into: $readOnlyRefusal) { reviewSend = .text }
                            } label: { Label("Text review link", systemImage: "message") }
                        }
                        if MFMailComposeViewController.canSendMail() {
                            Button {
                                if ReadOnlyGate.allows(.sendDocument, into: $readOnlyRefusal) { reviewSend = .email }
                            } label: { Label("Email review link", systemImage: "envelope") }
                        }
                        MBShareTextLink(text: ReviewRequestMessage.plainBody(business: profile),
                                        refused: $readOnlyRefusal) {
                            Label("Share…", systemImage: "square.and.arrow.up")
                        }
                    } label: {
                        Label {
                            Text("Ask for a Review")
                                .foregroundStyle(GLTheme.textPrimary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } icon: {
                            Image(systemName: "star.bubble")
                                .foregroundStyle(gold)
                        }
                        .contentShape(Rectangle())
                    }
                } else {
                    // No link yet — the row opens the edit form, where the Online section explains it.
                    Button {
                        showingEdit = true
                    } label: {
                        Label {
                            Text("Add a Reviews Link")
                                .foregroundStyle(GLTheme.textPrimary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } icon: {
                            Image(systemName: "star.bubble")
                                .foregroundStyle(gold)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }

            Section("Reports") {
                NavigationLink {
                    StatsScreen()
                } label: {
                    Label {
                        Text("Income & Expenses")
                    } icon: {
                        Image(systemName: "chart.bar")
                            .foregroundStyle(gold)
                    }
                }
            }
        }
        .glFormBackground()
        .contentMargins(.top, GLScript.titleClearance(for: GLScript.padded(mbLoc("My Business Details"))), for: .scrollContent)   // breathing room below the large title's descenders
    }

    private func logo(_ profile: BusinessProfile) -> some View {
        // Show the variant for the current scheme, but back it with the surface that variant was made
        // for (light logo on a light card, dark logo on a dark card) so it's always legible — a
        // light-only logo no longer vanishes in dark mode.
        let useDark = colorScheme == .dark && profile.logoDataDark != nil
        let data = useDark ? profile.logoDataDark : (profile.logoData ?? profile.logoDataDark)
        // Resolve the backing for the scheme the SHOWN VARIANT was made for, not the
        // current one — a light-only logo in dark mode still sits on the light card
        // it was designed against. (This was computed but unused — the compiler
        // warning that exposed it.)
        let backing: ColorScheme = useDark ? .dark : (profile.logoData != nil ? .light : .dark)
        return ZStack {
            if let data, let uiImage = LogoImage.decoded(data) {
                GLTheme.resolved(GLTheme.background, in: backing)
                Image(uiImage: uiImage).resizable().scaledToFill()
            } else {
                gold.opacity(0.12)
                Image(systemName: "building.2")
                    .font(.system(size: 40))
                    .foregroundStyle(gold)
            }
        }
        .frame(width: 120, height: 120)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        // No outline HERE (owner clarification 2026-08-30: the stroke he asked
        // to remove was on this VIEW screen — the logo stands alone; the EDIT
        // wells keep theirs as a tappable-well affordance).
        .frame(maxWidth: .infinity)
    }

    private func infoRow(_ label: LocalizedStringKey, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(GLTheme.textSecondary)
            Spacer()
            Text(value.isEmpty ? "—" : value).multilineTextAlignment(.trailing).copyable(value)
        }
    }

    private func contactRow(_ label: LocalizedStringKey, _ kind: GLContactLink.Kind, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(GLTheme.textSecondary)
            Spacer()
            if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("—").foregroundStyle(GLTheme.textSecondary)
            } else {
                GLContactLink(kind, value).multilineTextAlignment(.trailing)
            }
        }
    }

    // Transplanted from the retired CompanyDetailsScreen ("More Info") when its
    // sections inlined here (owner ask 2026-08-22).

    private func addressText(_ profile: BusinessProfile) -> String {
        let a = profile.address
        let cityLine = [a.city, a.state].filter { !$0.isEmpty }.joined(separator: ", ")
        let cityZip = [cityLine, a.postalCode].filter { !$0.isEmpty }.joined(separator: " ")
        return [a.street1, a.street2 ?? "", cityZip]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    private func classificationText(_ profile: BusinessProfile) -> String {
        guard let classification = profile.w9TaxClassification else { return "—" }
        switch classification {
        case .llc:
            return profile.w9LLCClassification.isEmpty
                ? classification.label
                : "\(classification.label) (\(profile.w9LLCClassification))"
        case .other:
            return profile.w9OtherClassification.isEmpty
                ? classification.label
                : "\(classification.label): \(profile.w9OtherClassification)"
        default:
            return classification.label
        }
    }

    /// Masks the taxpayer ID to its last four digits — it's an SSN/EIN, so it isn't
    /// shown in full on this read-only screen.
    private func maskedTIN(_ profile: BusinessProfile) -> String {
        let digits = profile.secureTIN.filter { $0.isASCII && $0.isNumber }
        guard let type = profile.w9TINType, !digits.isEmpty else { return "—" }
        let last4 = String(digits.suffix(4))
        return "\(type.label) ••• \(last4)"
    }
}

// MARK: - My Company edit form (pushed via navigation, Save-only, same pattern as the Customer/Estimate forms)

private struct LogoCrop: Identifiable {
    let id = UUID()
    let image: UIImage
    let isDark: Bool
}

struct MyCompanyFormScreen: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    let profile: BusinessProfile

    @State private var businessName: String
    @State private var ownerFirstName: String
    @State private var ownerLastName: String
    @State private var licenseNumber: String
    @State private var email: String
    @State private var phone: String
    @State private var websiteURL: String
    @State private var reviewsURL: String
    @State private var street1: String
    @State private var city: String
    @State private var state: String
    @State private var postalCode: String
    @State private var logoData: Data?
    @State private var logoDataDark: Data?
    @State private var logoItem: PhotosPickerItem?
    @State private var logoItemDark: PhotosPickerItem?
    @State private var logoToCrop: LogoCrop?
    @State private var w9Name: String
    @State private var w9Classification: W9TaxClassification?
    @State private var w9LLCClassification: String
    @State private var w9OtherClassification: String
    @State private var w9TINType: W9TINType?
    @State private var w9TIN: String
    @State private var w9ExemptPayeeCode: String
    @State private var w9FATCACode: String
    @State private var initialDigest: String?
    private var digest: String {
        ([businessName, ownerFirstName, ownerLastName, licenseNumber, email, phone, websiteURL, reviewsURL, street1, city, state,
          postalCode, w9Name,
          w9LLCClassification, w9OtherClassification, w9TIN, w9ExemptPayeeCode, w9FATCACode]
         + [w9Classification?.rawValue ?? "", w9TINType?.rawValue ?? "",
            String(logoData?.count ?? 0), String(logoDataDark?.count ?? 0)]).joined(separator: "|")
    }
    private var isDirty: Bool { initialDigest.map { $0 != digest } ?? false }
    @State private var tinSaveFailed = false
    @State private var photoLoadFailed = false
    @State private var tinRevealed = false   // the Tax ID stays masked until Face ID unlocks it
    /// Set when a lapsed subscription refuses a write — the alert names it (ReadOnlyGate.swift).
    @State private var readOnlyRefusal: MBWriteOperation?
    /// A refusal BusinessProfileService threw that the form did not predict (DomainErrorAlert.swift).
    @State private var domainError: DomainError?

    init(profile: BusinessProfile) {
        self.profile = profile
        _businessName = State(initialValue: profile.businessName)
        _ownerFirstName = State(initialValue: profile.ownerFirstName)
        _ownerLastName = State(initialValue: profile.ownerLastName)
        _licenseNumber = State(initialValue: profile.licenseNumber)
        _email = State(initialValue: profile.email)
        _phone = State(initialValue: profile.phone)
        _websiteURL = State(initialValue: profile.websiteURL)
        _reviewsURL = State(initialValue: profile.reviewsURL)
        _street1 = State(initialValue: profile.address.street1)
        _city = State(initialValue: profile.address.city)
        _state = State(initialValue: profile.address.state)
        _postalCode = State(initialValue: profile.address.postalCode)
        _logoData = State(initialValue: profile.logoData)
        _logoDataDark = State(initialValue: profile.logoDataDark)
        _w9Name = State(initialValue: profile.w9Name)
        _w9Classification = State(initialValue: profile.w9TaxClassification)
        _w9LLCClassification = State(initialValue: profile.w9LLCClassification)
        _w9OtherClassification = State(initialValue: profile.w9OtherClassification)
        _w9TINType = State(initialValue: profile.w9TINType)
        _w9TIN = State(initialValue: profile.secureTIN)
        _w9ExemptPayeeCode = State(initialValue: profile.w9ExemptPayeeCode)
        _w9FATCACode = State(initialValue: profile.w9FATCACode)
    }

    private var gold: Color { GLTheme.accentFill }

    private var requiredMark: some View {
        Text("*").foregroundStyle(GLTheme.statusCritical).accessibilityLabel("Required")
    }

    /// The name alone saves (found 2026-09-29); an email or a phone is what SENDING a document
    /// needs, and the send screens say so (`BusinessProfile.isComplete`).
    private var canSave: Bool {
        !businessName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        Form {
            Section {
                HStack(alignment: .top, spacing: 24) {
                    Spacer(minLength: 0)
                    logoWell(title: "Light", scheme: .light, data: $logoData, item: $logoItem)
                    logoWell(title: "Dark", scheme: .dark, data: $logoDataDark, item: $logoItemDark)
                    Spacer(minLength: 0)
                }
                .listRowBackground(Color.clear)
            } header: {
                InfoLabel("Logo", info: "Optional. Appears on your estimates and invoices, and customizes the app.", topic: "Logo")
            }

            Section("Business") {
                HStack {
                    TextField("Business name", text: $businessName)
                        .textContentType(.organizationName)
                        .textInputAutocapitalization(.words)
                    requiredMark
                }
                TextField("License number", text: $licenseNumber)
                    .idCodeStyle()
            }

            Section("Contact") {
                TextField("Owner first name", text: $ownerFirstName)
                    .textContentType(.givenName)
                    .textInputAutocapitalization(.words)
                TextField("Owner last name", text: $ownerLastName)
                    .textContentType(.familyName)
                    .textInputAutocapitalization(.words)
                HStack {
                    TextField("Email", text: $email)
                        .textContentType(.emailAddress)
                        #if !os(macOS)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        #endif
                }
                PhoneTextField(placeholder: "Phone", text: $phone)
            }

            Section {
                TextField("Website (optional)", text: $websiteURL)
                    .textContentType(.URL)
                    #if !os(macOS)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    #endif
                TextField("Reviews link (optional)", text: $reviewsURL)
                    .textContentType(.URL)
                    #if !os(macOS)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    #endif
            } header: {
                Text("Online")
            } footer: {
                Text("Paste any review URL (Google, Yelp, etc.) — you can send it to a customer anytime from My Business Details. To close every payment receipt with a review request, turn that on in Settings → Document Messages.")
            }

            Section("Address") {
                GLAddressField("Street", street: $street1, city: $city, state: $state, zip: $postalCode)
                    .textContentType(.streetAddressLine1)
                TextField("City", text: $city)
                    .textContentType(.addressCity)
                TextField("State", text: $state)
                    .textContentType(.addressState)
                    .textInputAutocapitalization(.characters)
                TextField("Postal code", text: $postalCode)
                    .textContentType(.postalCode)
                    #if !os(macOS)
                    .keyboardType(.numberPad)
                    #endif
            }

            Section {
                TextField("Name (as on tax return)", text: $w9Name)
                    .textContentType(.name)
                Picker("Tax classification", selection: $w9Classification) {
                    Text("Select…").tag(W9TaxClassification?.none)
                    ForEach(W9TaxClassification.allCases) { option in
                        Text(option.label).tag(W9TaxClassification?.some(option))
                    }
                }
                if w9Classification == .llc {
                    TextField("LLC tax classification (C, S, or P)", text: $w9LLCClassification)
                        #if !os(macOS)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        #endif
                }
                if w9Classification == .other {
                    TextField("Describe classification", text: $w9OtherClassification)
                }
                // STRICT top-to-bottom editing (owner, 2026-08-30: the old shape
                // locked the type picker until the row BELOW it was Face-ID'd,
                // forcing a skip-down-then-jump-back-up loop). Two linear states:
                //  - no stored number → type picker + field, editable in order,
                //    no Face ID (there is nothing to protect yet — the signature
                //    editor's first-time rule);
                //  - stored + masked → ONE locked row here; Face ID expands it
                //    into the same picker + field, still in order.
                if w9TIN.isEmpty || tinRevealed {
                    Picker("Taxpayer ID type", selection: $w9TINType) {
                        Text("Select…").tag(W9TINType?.none)
                        ForEach(W9TINType.allCases) { option in
                            Text(option.label).tag(W9TINType?.some(option))
                        }
                    }
                    .onChange(of: w9TINType) { _, _ in
                        // The SSN and EIN formats differ, so switching type
                        // clears the number. Only reachable revealed-or-empty,
                        // so a masked stored value can never be blanked unseen.
                        w9TIN = ""
                    }
                    LabeledContent(w9TINType?.label ?? mbLoc("Tax ID")) {
                        TINField(kind: w9TINType, text: $w9TIN)
                    }
                } else {
                    // Masked until Face ID — your SSN/EIN isn't shown to anyone
                    // holding an unlocked phone. The whole row is the button.
                    Button {
                        Task {
                            if await BiometricGate.authenticateInSession(reason: mbLoc("Your Tax ID is stored in this device's secure Keychain and stays masked until Face ID confirms it's you.")) {
                                tinRevealed = true
                            }
                        }
                    } label: {
                        HStack {
                            Text(w9TINType?.label ?? mbLoc("Tax ID"))
                                .foregroundStyle(GLTheme.textPrimary)
                            Spacer()
                            Text("•••••••••")
                                .foregroundStyle(GLTheme.textSecondary)
                            Image(systemName: "lock.fill").font(.caption2).foregroundStyle(gold)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("taxIdRevealButton")
                }
            } header: {
                InfoLabel("Tax details (for W-9)", info: "Optional. Used to generate a W-9. Your Tax ID is stored securely in your Keychain, not the synced database. Sign and date the form by hand after you print or send it.", topic: "Tax details (for W-9)")
            } footer: {
                if !tinRevealed && !w9TIN.isEmpty {
                    Text("Unlock to see or change your Tax ID and its type.")
                }
            }

            Section {
                TextField("Exempt payee code", text: $w9ExemptPayeeCode)
                    .idCodeStyle()
                TextField("FATCA exemption code", text: $w9FATCACode)
                    .idCodeStyle()
            } header: {
                InfoLabel("Exemption codes", info: "Optional W-9 exemption codes. Most small businesses leave these blank.", topic: "Exemption codes")
            }

            // Message templates + warranty moved to Settings → Document Messages
            // (owner restructure, 2026-08-22: one source of truth for all settings).
        }
        .glFormBackground()
        .onAppear { if initialDigest == nil { initialDigest = digest } }
        .discardChangesGuard(isDirty: isDirty)
        .navigationTitle(GLScript.padded(mbLoc("My Business Details")))
        .toolbarTitleDisplayMode(.large)
        .contentMargins(.top, GLScript.titleClearance(for: GLScript.padded(mbLoc("My Business Details"))), for: .scrollContent)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save", action: save).disabled(!canSave)
            }
        }
        // Each pick is shrunk to 1024 px, upright, off the main thread before the crop screen
        // holds it (Photo Intake Memory Defense, law 62). A logo's transparency is kept.
        .task(id: logoItem) {
            guard let logoItem else { return }
            guard let data = try? await logoItem.loadTransferable(type: Data.self),
                  let picked = await ImageDownsampler.intakeImage(from: data) else {
                self.logoItem = nil
                photoLoadFailed = true
                return
            }
            logoToCrop = LogoCrop(image: picked, isDark: false)
            self.logoItem = nil
        }
        .task(id: logoItemDark) {
            guard let logoItemDark else { return }
            guard let data = try? await logoItemDark.loadTransferable(type: Data.self),
                  let picked = await ImageDownsampler.intakeImage(from: data) else {
                self.logoItemDark = nil
                photoLoadFailed = true
                return
            }
            logoToCrop = LogoCrop(image: picked, isDark: true)
            self.logoItemDark = nil
        }
        .photoLoadFailureAlert($photoLoadFailed)
        .fullScreenCover(item: $logoToCrop) { crop in
            // The fleet crop screen: rounded-tile guide on the logo's own ground, a 600 px
            // square that keeps transparency; a failed crop stays open with an alert.
            GLSquarePhotoCropper(image: crop.image, guide: .roundedRect,
                                 windowBackground: GLTheme.resolved(GLTheme.background, in: crop.isDark ? .dark : .light),
                                 outputSide: ImageDownsampler.croppedSide, keepsTransparency: true) {
                logoToCrop = nil
            } onCropped: { cropped in
                let data = cropped.pngData()
                if crop.isDark { logoDataDark = data } else { logoData = data }
                logoToCrop = nil
            }
        }
        .readOnlyRefusalAlert($readOnlyRefusal)
        .domainErrorAlert($domainError)
        .alert("Couldn’t save your Tax ID", isPresented: $tinSaveFailed) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("Your other details were saved, but your Tax ID wasn’t. Make sure your device is unlocked, then tap Save again.")
        }
    }

    /// One labeled logo slot (Light or Dark), Xcode-asset style. Each previews the logo on the
    /// brand background for its appearance so the user sees how it will actually look.
    @ViewBuilder
    private func logoWell(title: LocalizedStringKey, scheme: ColorScheme, data: Binding<Data?>, item: Binding<PhotosPickerItem?>) -> some View {
        // Each slot previews on the ground its logo will actually be USED on
        // (RC find: a dark light-mode logo was invisible on the dark card):
        // the Light well is WHITE, the Dark well stays the app ground in dark mode.
        let wellBackground: Color = scheme == .light ? .white : GLTheme.resolved(GLTheme.background, in: .dark)
        let wellGold = GLTheme.accentFill
        VStack(spacing: 8) {
            PhotosPicker(selection: item, matching: .images) {
                ZStack {
                    wellBackground
                    if let value = data.wrappedValue, let uiImage = LogoImage.decoded(value) {
                        Image(uiImage: uiImage)
                            .resizable()
                            .scaledToFill()
                    } else {
                        VStack(spacing: 6) {
                            Image(systemName: "photo.badge.plus")
                                .font(.system(size: 24))
                                .foregroundStyle(wellGold)
                            Text("Add")
                                .font(.caption)
                                .foregroundStyle(wellGold.opacity(0.85))
                        }
                    }
                }
                .frame(width: 110, height: 110)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                // The EDIT wells keep their outline (owner clarification
                // 2026-08-30: the earlier "remove the stroke" was about the
                // Details VIEW; here it marks the tappable well).
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(wellGold.opacity(0.25), lineWidth: 1))
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: "camera.fill")
                        .font(.caption2)
                        .foregroundStyle(.white)
                        .padding(6)
                        .background(Circle().fill(gold))
                        .padding(5)
                }
            }
            .buttonStyle(.plain)

            Text(title)
                .font(.subheadline.weight(.medium))

            if data.wrappedValue != nil {
                Button(role: .destructive) {
                    data.wrappedValue = nil
                    item.wrappedValue = nil
                } label: {
                    Text("Remove").font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(GLTheme.statusCritical)
            } else {
                // Keeps both wells the same height whether or not a logo is set.
                Text(" ").font(.caption).hidden()
            }
        }
    }

    /// One document's editable text/email wording: an optional subject line plus the intro and
    /// closing paragraphs. Each shows its default as placeholder; blank falls back to that default.
    private func save() {
        // Refused before anything is written: a lapsed or offline app changes nothing.
        guard ReadOnlyGate.allows(.saveBusinessProfile, into: $readOnlyRefusal) else { return }
        // Everything but the Tax ID goes through BusinessProfileService (trimmed, validated, saved
        // — the path the assistant uses). `profile` can be BusinessProfileHost's transient
        // stand-in; the service adopts it into the store (or writes onto the stored profile if one
        // appeared meanwhile), since the gate now allows the write.
        var draft = BusinessDetailsDraft()
        draft.businessName = businessName
        draft.ownerFirstName = ownerFirstName
        draft.ownerLastName = ownerLastName
        draft.licenseNumber = licenseNumber
        draft.email = email
        draft.phone = phone
        draft.websiteURL = websiteURL
        draft.reviewsURL = reviewsURL
        draft.address = Address(street1: street1, city: city, state: state, postalCode: postalCode)
        draft.w9Name = w9Name
        draft.w9TaxClassification = w9Classification
        draft.w9LLCClassification = w9LLCClassification
        draft.w9OtherClassification = w9OtherClassification
        draft.w9TINType = w9TINType
        draft.w9ExemptPayeeCode = w9ExemptPayeeCode
        draft.w9FATCACode = w9FATCACode
        let saved: BusinessProfile
        do {
            saved = try BusinessProfileService.updateDetails(
                draft, logos: BusinessLogos(light: logoData, dark: logoDataDark), for: profile, in: modelContext)
        } catch {
            DomainError.present(error, readOnly: $readOnlyRefusal, domainError: $domainError)
            return
        }
        // The Tax ID lives in the Keychain and is loaded into `w9TIN` masked. Only write it back
        // when the owner actually revealed (and could edit) it — otherwise leave the stored value
        // untouched, so a routine edit of other fields can never wipe an unseen SSN/EIN. Written
        // only after the service accepted the rest (a refusal changes nothing), then saved so the
        // legacy-plaintext purge it may make persists.
        let tinSaved = tinRevealed ? saved.updateTIN(w9TIN) : true
        modelContext.saveChanges()
        // The rest of the profile is saved; only the secure Tax ID write can fail. If it did, keep
        // the form open and tell the user rather than dismissing as if everything saved.
        if tinSaved {
            dismiss()
        } else {
            tinSaveFailed = true
        }
    }
}

/// The Gold Life ID screen's Signature row. The signature is saved in the Gold Life ID
/// itself (law 48a; audit 2026-10-03 F19 / F70), so no local row is needed to save it.
struct MBSignatureRow: View {
    @State private var showingSignature = false
    @Environment(\.colorScheme) private var colorScheme
    private let identity = MBIdentity.shared

    private var hasSignature: Bool { identity.signatureData != nil }

    var body: some View {
        Section {
            Button {
                Task { await openSignature() }
            } label: {
                Label {
                    HStack {
                        Text(mbLoc("Signature"))
                            .foregroundStyle(GLTheme.textPrimary)
                        Spacer()
                        if hasSignature {
                            Image(systemName: "checkmark.seal.fill")
                                .font(.footnote)
                                .foregroundStyle(GLTheme.accentFill)
                        }
                    }
                } icon: {
                    Image(systemName: "signature")
                        .foregroundStyle(GLTheme.accentFill)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .sheet(isPresented: $showingSignature) {
            SignatureEditorSheet().glAppearance(colorScheme)
        }
    }

    private func openSignature() async {
        if hasSignature {
            guard await BiometricGate.authenticateInSession(reason: mbLoc("Unlock your saved signature.")) else { return }
        }
        showingSignature = true
    }
}

#Preview {
    MenuScreen()
        .modelContainer(for: [Customer.self, Estimate.self, BusinessProfile.self], inMemory: true)
}
