//
//  ReadOnlyGateTests.swift — the lapsed-subscription read-only rule.
//
//  THE RULING (Adrian, 2026-08-25). A LAPSED subscription is 100% read-only: nothing created,
//  nothing edited, no status changed, no payment recorded, no 1099/W-9/PDF generated, no export.
//  Account deletion is the single exception, because Apple Guideline 5.1.1(v) requires it whatever
//  the billing state. NEVER SUBSCRIBED is a different state and is untouched — the FreeTier caps
//  still apply and those people still create and edit up to them.
//
//  These tests are written against the SAFETY rules as much as the feature, because getting those
//  wrong locks a PAYING customer out of their own business records, which is far worse than a
//  lapsed user writing one extra row:
//    - status not yet KNOWN  -> full access (the cold-launch lockout)
//    - grace / billing retry -> SUBSCRIBED, never read-only (the declined-card lockout)
//    - offline               -> not a lapse (the history is read only after the live status
//                               answers; a live status that can't answer leaves full access)
//    - never subscribed      -> the free caps, never read-only
//
//  `SubscriptionManager.shared` is a singleton, so every test here sets all four flags explicitly
//  and resets them at the end. The host-process UserDefaults lesson (project_test_defaults_pollution)
//  applies to shared entitlement state too: pin it, never inherit it.
//

import Foundation
import GoldLifeUI
import SwiftData
import StoreKit
import SwiftUI
import Testing
@testable import GLSmallBusiness

@MainActor
private enum Entitlement {
    /// Unit tests run in the HOST APP's process, and `isLapsed` short-circuits
    /// on sample mode — a leftover `mb.demoMode` from a hand-driven simulator
    /// session mounts SampleDataHost at test-host boot and silently un-lapses
    /// every fixture (the 2026-08-30 run: 9 reds, zero real bugs). Pin the
    /// flag OFF at every state change; never inherit process state.
    private static func pinRealAppState() {
        UserDemoMode.shared.isDemoActive = false
    }

    /// Never subscribed: status resolved, no entitlement, no history. The free tier.
    static func neverSubscribed(_ s: SubscriptionManager) {
        pinRealAppState()
        s.statusKnown = true; s.historyKnown = true
        s.isSubscribed = false; s.hasEverSubscribed = false
    }
    /// Subscribed now (this is also what grace period and billing retry resolve to — see
    /// `SubscriptionManager.entitledStates`).
    static func subscribed(_ s: SubscriptionManager) {
        pinRealAppState()
        s.statusKnown = true; s.historyKnown = true
        s.isSubscribed = true; s.hasEverSubscribed = true
    }
    /// LAPSED: subscribed before, not now. The history arrives the way the shipping read
    /// publishes it — an expired Pro transaction through `GLPurchaseHistory.summarize` and
    /// `applyPurchaseHistory` — never by setting the flag by hand (audit 2026-10-03 F15: the
    /// hand-set flag hid that nothing in the app wrote it any more).
    static func lapsed(_ s: SubscriptionManager) {
        pinRealAppState()
        s.statusKnown = true
        s.isSubscribed = false; s.hasEverSubscribed = false; s.historyKnown = false
        let expiredPro = GLPastTransaction(productID: SubscriptionManager.monthlyID,
                                           purchaseDate: .now.addingTimeInterval(-60 * 86_400),
                                           expirationDate: .now.addingTimeInterval(-30 * 86_400),
                                           isUpgraded: false, jws: "expired-pro-month")
        s.applyPurchaseHistory(GLPurchaseHistory.summarize(
            [expiredPro], entitlingProductIDs: Set(s.entitlingProductIDs.keys)))
    }
    /// Cold launch: StoreKit has not answered yet.
    static func unknown(_ s: SubscriptionManager) {
        pinRealAppState()
        s.statusKnown = false; s.historyKnown = false
        s.isSubscribed = false; s.hasEverSubscribed = false
    }
    /// Back to the process default, so nothing leaks into another test.
    static func reset(_ s: SubscriptionManager) { unknown(s) }
}

// MARK: - The three states

@MainActor
struct LapsedStateTests {

    @Test func lapsedIsSubscribedBeforeAndNotNow() {
        let subs = SubscriptionManager.shared
        defer { Entitlement.reset(subs) }

        Entitlement.neverSubscribed(subs)
        #expect(!subs.isLapsed, "Never subscribed is the FREE TIER, not the read-only app.")

        Entitlement.subscribed(subs)
        #expect(!subs.isLapsed)

        Entitlement.lapsed(subs)
        #expect(subs.isLapsed)
    }

    /// The cold-launch lockout. `statusKnown` starts false and StoreKit resolves async; treating
    /// "not answered yet" as lapsed would flash a read-only app at a paying customer on EVERY
    /// launch. Unknown means FULL ACCESS, in both directions.
    @Test func unknownStatusIsNeverLapsed() {
        let subs = SubscriptionManager.shared
        defer { Entitlement.reset(subs) }

        Entitlement.unknown(subs)
        #expect(!subs.isLapsed)

        // The nastier half: history says they once subscribed, but the live status has not landed.
        // That is exactly the returning subscriber mid-cold-launch, and they must not be walled.
        subs.hasEverSubscribed = true
        subs.historyKnown = true
        subs.statusKnown = false
        #expect(!subs.isLapsed, "A returning subscriber must not be walled before StoreKit answers.")

        // And the mirror: the status landed, the history read has not. Also full access.
        subs.statusKnown = true
        subs.historyKnown = false
        #expect(!subs.isLapsed)
    }

    /// Apple's GRACE PERIOD and BILLING RETRY are billing states, not cancellations — the customer
    /// is still a customer and Apple is still trying to collect. AppGate maps them into
    /// `isSubscribed` through this list; pinning the list here is what stops a future edit from
    /// quietly dropping a declined card into the read-only app.
    @Test func graceAndBillingRetryCountAsSubscribed() {
        #expect(SubscriptionManager.entitledStates.contains(.subscribed))
        #expect(SubscriptionManager.entitledStates.contains(.inGracePeriod))
        #expect(SubscriptionManager.entitledStates.contains(.inBillingRetryPeriod))
        #expect(!SubscriptionManager.entitledStates.contains(.expired))
        #expect(!SubscriptionManager.entitledStates.contains(.revoked))

        let subs = SubscriptionManager.shared
        defer { Entitlement.reset(subs) }
        // What AppGate's `.success` branch does with a grace-period status.
        subs.statusKnown = true; subs.historyKnown = true; subs.hasEverSubscribed = true
        subs.isSubscribed = SubscriptionManager.entitledStates.contains(.inGracePeriod)
        #expect(!subs.isLapsed, "A card that hiccupped mid-renewal must never be dropped into read-only.")
    }
}

// MARK: - Creation: the free tier survives, the lapse does not

@MainActor
struct AccessGateLapseTests {

    private func addCustomers(_ n: Int, to ctx: ModelContext) throws {
        for _ in 0..<n { ctx.insert(Customer(firstName: "T", lastName: "C")) }
        try ctx.save()
    }

    /// The free tier, unchanged: someone who never subscribed creates right up to the cap and is
    /// then sent to the paywall — not to the read-only refusal, which would be the wrong sentence.
    @Test func neverSubscribedStillCreatesUpToTheCaps() throws {
        let container = try TestStore.makeContainer()
        let ctx = container.mainContext
        let subs = SubscriptionManager.shared
        defer { Entitlement.reset(subs) }
        Entitlement.neverSubscribed(subs)

        try addCustomers(FreeTier.customers - 1, to: ctx)
        #expect(AccessGate.decide(Customer.self, cap: FreeTier.customers, in: ctx, subscription: subs) == .allowed,
                "One under the cap is still a create.")

        try addCustomers(1, to: ctx)
        #expect(AccessGate.decide(Customer.self, cap: FreeTier.customers, in: ctx, subscription: subs) == .atCap,
                "At the cap a free user gets the PAYWALL, never the lapsed refusal.")
    }

    /// The bug the ruling exists to close: a lapsed subscriber with three customers was UNDER the
    /// cap, so the old cap-only gate let them keep creating.
    @Test func lapsedIsRefusedEvenFarUnderTheCap() throws {
        let container = try TestStore.makeContainer()
        let ctx = container.mainContext
        let subs = SubscriptionManager.shared
        defer { Entitlement.reset(subs) }

        try addCustomers(3, to: ctx)   // 3 of 10 — comfortably under the free cap

        Entitlement.neverSubscribed(subs)
        #expect(AccessGate.decide(Customer.self, cap: FreeTier.customers, in: ctx, subscription: subs) == .allowed)

        Entitlement.lapsed(subs)
        #expect(AccessGate.decide(Customer.self, cap: FreeTier.customers, in: ctx, subscription: subs) == .readOnly)
        #expect(AccessGate.decide(Customer.self, cap: FreeTier.customers, in: ctx, subscription: subs) != .allowed)
    }

    @Test func unknownStatusStillCreatesOverTheCap() throws {
        let container = try TestStore.makeContainer()
        let ctx = container.mainContext
        let subs = SubscriptionManager.shared
        defer { Entitlement.reset(subs) }

        try addCustomers(FreeTier.customers + 5, to: ctx)
        Entitlement.unknown(subs)
        #expect(AccessGate.decide(Customer.self, cap: FreeTier.customers, in: ctx, subscription: subs) == .allowed)
    }

    @Test func subscribedIsAlwaysAllowed() throws {
        let container = try TestStore.makeContainer()
        let ctx = container.mainContext
        let subs = SubscriptionManager.shared
        defer { Entitlement.reset(subs) }

        try addCustomers(FreeTier.customers + 5, to: ctx)
        Entitlement.subscribed(subs)
        #expect(AccessGate.decide(Customer.self, cap: FreeTier.customers, in: ctx, subscription: subs) == .allowed)
    }
}

// MARK: - Every write class

@MainActor
struct ReadOnlyGateOperationTests {

    /// Walks `MBWriteOperation.allCases` rather than a hand-written list, so a write surface added
    /// tomorrow is covered the moment its case exists. Every one of them is refused while lapsed,
    /// and every one of them is allowed in each of the other three states.
    @Test func everyWriteClassIsRefusedWhileLapsedAndAllowedOtherwise() {
        let subs = SubscriptionManager.shared
        defer { Entitlement.reset(subs) }
        #expect(!MBWriteOperation.allCases.isEmpty)

        Entitlement.lapsed(subs)
        for operation in MBWriteOperation.allCases {
            var refused: MBWriteOperation?
            #expect(ReadOnlyGate.allows(operation, subs, into: Binding(get: { refused },
                                                                       set: { refused = $0 })) == false,
                    "\(operation.rawValue) was allowed while lapsed.")
            // The refusal is never silent: the person is told which operation stopped.
            #expect(refused == operation,
                    "\(operation.rawValue) refused without telling the person — a disabled control with no explanation is a defect.")
        }

        for state in [Entitlement.neverSubscribed, Entitlement.subscribed, Entitlement.unknown] {
            state(subs)
            for operation in MBWriteOperation.allCases {
                var refused: MBWriteOperation?
                #expect(ReadOnlyGate.allows(operation, subs, into: Binding(get: { refused },
                                                                           set: { refused = $0 })) == true,
                        "\(operation.rawValue) was refused outside a lapse.")
                #expect(refused == nil, "\(operation.rawValue) raised an alert with no refusal.")
            }
        }
    }

    /// The UNATTENDED surface answers identically — same denominator, same four states. It differs
    /// from `allows` in one way only: no alert, because nobody tapped anything. If it ever answered
    /// `true` while lapsed, a `.task` poll or a first-render bootstrap would write on a dead
    /// account, which is the exact bug this surface was added to stop.
    @Test func everyWriteClassIsAlsoRefusedUnattendedWhileLapsed() {
        let subs = SubscriptionManager.shared
        defer { Entitlement.reset(subs) }

        Entitlement.lapsed(subs)
        for operation in MBWriteOperation.allCases {
            #expect(ReadOnlyGate.allowsUnattended(operation, subs) == false,
                    "\(operation.rawValue) was allowed unattended while lapsed.")
        }

        for state in [Entitlement.neverSubscribed, Entitlement.subscribed, Entitlement.unknown] {
            state(subs)
            for operation in MBWriteOperation.allCases {
                #expect(ReadOnlyGate.allowsUnattended(operation, subs) == true,
                        "\(operation.rawValue) was refused unattended outside a lapse.")
            }
        }
    }

    /// Every operation owes the person a sentence. A blank one would render "… needs an active
    /// subscription" with nothing in front of it.
    @Test func everyOperationHasPlainEnglishForThePerson() {
        for operation in MBWriteOperation.allCases {
            let phrase = operation.phrase
            #expect(!phrase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                    "\(operation.rawValue) has no phrase for the alert.")
            // The phrase is the SUBJECT of the alert sentence, so it never carries its own
            // punctuation — "Saving this customer. needs an active subscription." would ship.
            #expect(!phrase.hasSuffix("."), "\(operation.rawValue)'s phrase ends in a period.")
        }
    }

    /// The developer's half. Log names are stable identifiers, so they must be unique — two
    /// operations sharing one name makes the log line ambiguous exactly when it is being read.
    @Test func everyOperationHasAUniqueStableLogName() {
        let names = MBWriteOperation.allCases.map(\.rawValue)
        #expect(Set(names).count == names.count, "Two write operations share a log name.")
        for name in names {
            #expect(!name.isEmpty)
            #expect(name.allSatisfy { $0.isLetter || $0.isNumber },
                    "\(name) is not a plain identifier — the log line parses it as one token.")
        }
    }

    @Test func isReadOnlyMatchesTheSubscriptionState() {
        let subs = SubscriptionManager.shared
        defer { Entitlement.reset(subs) }
        Entitlement.lapsed(subs)
        #expect(ReadOnlyGate.isReadOnly(subs))
        Entitlement.neverSubscribed(subs)
        #expect(!ReadOnlyGate.isReadOnly(subs))
        Entitlement.unknown(subs)
        #expect(!ReadOnlyGate.isReadOnly(subs))
    }
}

// MARK: - Reading still works

@MainActor
struct LapsedCanStillReadTests {

    /// The whole promise: "all they can do is read the tombstone." Records created while
    /// subscribed are still all there, still fetchable, still complete, after the lapse.
    @Test func everyRecordStaysReadableAfterTheLapse() throws {
        let container = try TestStore.makeContainer()
        let ctx = container.mainContext
        let subs = SubscriptionManager.shared
        defer { Entitlement.reset(subs) }

        Entitlement.subscribed(subs)
        for i in 0..<12 { ctx.insert(Customer(firstName: "Customer", lastName: "\(i)")) }
        let invoice = Invoice(number: "INV-0001", jobTitle: "Bathroom tile")
        ctx.insert(invoice)
        try ctx.save()

        Entitlement.lapsed(subs)

        let customers = try ctx.fetch(FetchDescriptor<Customer>())
        #expect(customers.count == 12, "The records must survive the lapse untouched.")
        let invoices = try ctx.fetch(FetchDescriptor<Invoice>())
        #expect(invoices.first?.number == "INV-0001")
        #expect(invoices.first?.jobTitle == "Bathroom tile")
        // And creating another is refused, which is the other half of the same sentence.
        #expect(AccessGate.decide(Customer.self, cap: FreeTier.customers, in: ctx, subscription: subs) != .allowed)
    }
}

// MARK: - Account deletion is never gated (Apple 5.1.1(v))

/// Gating account deletion behind a subscription gets the app REJECTED (Apple 5.1.1(v)), so no
/// gate may sit anywhere on the path: the Menu's Gold Life ID door, the package's deletion screen,
/// or the eraser My Business hands it (`MBHostDataErase`, audit 2026-10-03 F1).
///
/// These read CODE ONLY (`GLSource.code`, comments stripped). Until 2026-10-03 they read raw text,
/// and after build 88 every one of them passed on comment lines kept in GoldLifeIDViews.swift for
/// the tests' sake, while the code they named no longer existed (F11). Each scan also proves it
/// found the real code (a call only that code makes), so a renamed or moved type fails loudly
/// instead of scanning nothing.
struct AccountDeletionIsNeverGatedTests {

    private static let gates = ["ReadOnlyGate", "isLapsed", "MBWriteOperation", "AccessGate",
                                "isSubscribed", "SubscriptionManager", "serverEntitled"]

    /// The eraser behind My Business's row: no gate in it, and it is the code that erases the
    /// backup (gl-business-api DELETE /account).
    @Test func theEraseCarriesNoSubscriptionGate() throws {
        let app = try #require(GLSource.code("GLSmallBusinessApp.swift"))
        let start = try #require(app.range(of: "enum MBHostDataErase"), "MBHostDataErase left GLSmallBusinessApp.swift — re-point this scan")
        let body = try #require(GLSource.balanced("{", "}", from: start.upperBound, in: app)).inner
        #expect(body.contains("deleteAccountData()"), "the scan must read the eraser itself")
        for forbidden in Self.gates {
            #expect(!body.contains(forbidden), "MBHostDataErase references \(forbidden): deletion is never billing-gated (Apple 5.1.1(v))")
        }
    }

    /// The package's deletion screen My Business pushes (law 48a) carries no gate either.
    @Test func thePackagesDeletionScreenCarriesNoGate() throws {
        let packageRoot = GLSource.repoRoot.deletingLastPathComponent().appendingPathComponent("GoldLifeID/Sources/GoldLifeID")
        let screen = try #require(GLSource.code("GoldLifeIDDeletionScreen.swift", under: packageRoot),
                                  "GoldLifeID's deletion screen was not found beside this repo")
        #expect(screen.contains("GLAccountDeletionSections("), "the scan must read the screen itself")
        for forbidden in Self.gates {
            #expect(!screen.contains(forbidden), "GoldLifeIDDeletionScreen references \(forbidden): deletion is never billing-gated (Apple 5.1.1(v))")
        }
    }

    /// The door: Menu → Gold Life ID opens the package screen with nothing in front of it.
    @Test func theDoorToDeletionIsNotGated() throws {
        let menu = try #require(GLSource.code("Screens/MenuScreen.swift"))
        let start = try #require(menu.range(of: "personalDestination:"), "the Menu's Gold Life ID door moved — re-point this scan")
        let door = try #require(GLSource.balanced("{", "}", from: start.upperBound, in: menu)).inner
        #expect(door.contains("GoldLifeIDScreen("), "the scan must read the door itself")
        for forbidden in Self.gates {
            #expect(!door.contains(forbidden), "the Gold Life ID door references \(forbidden): deletion is never billing-gated (Apple 5.1.1(v))")
        }
    }
}

// MARK: - Reading the source the way the compiler reads it

//  The source-scanning tests below used to split on the literal `"\nstruct "`, and that made one of
//  them UNABLE TO FAIL. A top-level `private struct` (or `@MainActor struct`, or `final class`)
//  does not start with `struct`, so its lines folded into the PRECEDING type's block — and the
//  preceding type's `.readOnlyRefusalAlert` then satisfied the assertion for both. Proven by
//  mutation on 2026-08-26: adding a `private struct` that holds refusal state and mounts no alert
//  left the test green.
//
//  So the scan counts braces instead of splitting on a prefix. This is the smallest amount of Swift
//  parsing that makes the answer trustworthy; it is deliberately not a parser.

/// One declared type and the lines it spans: `start` is its declaration line, `end` the first line
/// after its closing brace.
private struct TypeSpan {
    let name: String
    let start: Int
    let end: Int
}

/// Brace depth at the START of each line, with `//` comments, `/* */` comments and string literals
/// removed first — otherwise a brace inside any of the three moves the depth and every span after
/// it is wrong.
private func braceDepths(_ lines: [String]) -> [Int] {
    var depths: [Int] = []
    var depth = 0
    var inBlockComment = false
    for line in lines {
        depths.append(depth)
        var code = ""
        var inString = false
        var index = line.startIndex
        while index < line.endIndex {
            let character = line[index]
            let after = line.index(after: index)
            let next: Character? = after < line.endIndex ? line[after] : nil
            if inBlockComment {
                if character == "*", next == "/" { inBlockComment = false; index = line.index(after: after) }
                else { index = after }
                continue
            }
            if inString {
                // A backslash escapes the next character, so `"\""` does not end the literal.
                if character == "\\" { index = after < line.endIndex ? line.index(after: after) : after; continue }
                if character == "\"" { inString = false }
                index = after
                continue
            }
            if character == "\"" { inString = true; index = after; continue }
            if character == "/", next == "/" { break }                 // rest of the line is a comment
            if character == "/", next == "*" { inBlockComment = true; index = line.index(after: after); continue }
            code.append(character)
            index = after
        }
        depth += code.filter { $0 == "{" }.count - code.filter { $0 == "}" }.count
    }
    return depths
}

/// The type declared on this line, if any — at ANY nesting depth, and whatever attributes and
/// modifiers precede it (`@MainActor private final class Foo`). Nil for everything else, including
/// a declaration that only appears inside a comment.
private func declaredTypeName(on line: String) -> String? {
    let code = line.components(separatedBy: "//").first ?? line
    var words = code.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
    let modifiers: Set<String> = ["public", "internal", "private", "fileprivate", "final",
                                  "indirect", "open", "package", "static"]
    while let first = words.first, first.hasPrefix("@") || modifiers.contains(first) {
        words.removeFirst()
    }
    guard let keyword = words.first, ["struct", "class", "enum", "actor"].contains(keyword),
          words.count > 1 else { return nil }
    // Trim whatever follows the name on the same line: `: View {`, `<T> {`, `{`.
    let name = words[1].prefix { $0.isLetter || $0.isNumber || $0 == "_" }
    return name.isEmpty ? nil : String(name)
}

/// Every type declared in the file, nested ones included.
private func typeSpans(_ lines: [String], _ depths: [Int]) -> [TypeSpan] {
    var spans: [TypeSpan] = []
    for (index, line) in lines.enumerated() {
        guard let name = declaredTypeName(on: line) else { continue }
        let depth = depths[index]
        var end = lines.count
        for candidate in (index + 1)..<lines.count where depths[candidate] <= depth {
            end = candidate
            break
        }
        spans.append(TypeSpan(name: name, start: index, end: end))
    }
    return spans
}

/// The INNERMOST type containing a line — the one that actually owns the declaration, so a screen
/// nested inside another file's screen is judged on its own body and not on its host's.
private func owner(of line: Int, in spans: [TypeSpan]) -> TypeSpan? {
    spans.filter { $0.start < line && line < $0.end }.max { $0.start < $1.start }
}

// MARK: - The person always gets words, and so does the log

@MainActor
struct RefusalIsNeverSilentTests {

    /// Every screen that can refuse also MOUNTS the alert. The binding itself is compiler-required
    /// (`ReadOnlyGate.allows(_:_:into:)` takes a non-optional `Binding`), so what is left to check
    /// is the other half: a screen holding `readOnlyRefusal` state but never rendering
    /// `.readOnlyRefusalAlert($readOnlyRefusal)` would set a value nothing displays — a refusal in
    /// silence, which is the "tapped Save, nothing happened" defect the ruling forbids.
    ///
    /// Judged per TYPE, not per file — several of these files hold four or five screens, and the
    /// sheet that refuses is rarely the one at the top — and per type as the BRACES define it, not
    /// as a `"\nstruct "` split guesses at it. See the note above `TypeSpan` for what that split
    /// was quietly hiding.
    @Test func everyScreenThatRefusesAlsoShowsTheAlert() {
        let sources = GLSource.files(excluding: ["AccessControl/ReadOnlyGate.swift"])
        #expect(!sources.isEmpty)

        var checked = 0
        var silent: [String] = []
        for file in sources {
            let name = (file.path as NSString).lastPathComponent
            guard file.text.contains("readOnlyRefusal") else { continue }
            let lines = file.text.components(separatedBy: "\n")
            let spans = typeSpans(lines, braceDepths(lines))

            // Which types mount the alert, by declaration line (unique within a file).
            var mounts: Set<Int> = []
            for (index, line) in lines.enumerated()
            where line.contains("readOnlyRefusalAlert($readOnlyRefusal)") {
                if let host = owner(of: index, in: spans) { mounts.insert(host.start) }
            }
            for (index, line) in lines.enumerated()
            where line.contains("@State private var readOnlyRefusal") {
                checked += 1
                guard let host = owner(of: index, in: spans) else {
                    silent.append("\(name):\(index + 1) — refusal state outside any type")
                    continue
                }
                if !mounts.contains(host.start) {
                    silent.append("\(name) :: \(host.name) (line \(index + 1))")
                }
            }
        }
        #expect(silent.isEmpty,
                "These hold refusal state but never mount the alert — their refusals would be silent: \(silent.joined(separator: ", "))")
        // 59 at the time of writing. A floor, not a target: it catches the walk itself breaking
        // (a moved folder, a renamed state var) rather than pinning a screen count.
        #expect(checked > 40, "Only \(checked) screens were scanned; the walk found too few to be trusted.")
    }

    /// The log line names the OPERATION and never a value. Tax IDs, money and customer details are
    /// exactly what a support log must not carry.
    ///
    /// Checks EVERY refusal line, not just the first one it finds: the gate writes one per surface
    /// (`alert`, `unattended`), and a second line free to grow an interpolation nobody looks at is
    /// the same hole in a different place.
    @Test func theLogLineCarriesNoUserData() throws {
        let text = try #require(GLSource.file("AccessControl/ReadOnlyGate.swift"))
        #expect(text.contains("operation=\\(operation.rawValue, privacy: .public)"),
                "The refusal log must name the operation.")
        #expect(text.contains("decision=lapsed_subscription_read_only"),
                "The refusal log must name the decision.")

        // Every logged refusal line in the file — the `Logger.access.error` calls, not the prose
        // above them, so a doc comment quoting the format can't stand in for a real one.
        let logged = text.components(separatedBy: "\n")
            .filter { $0.contains("read-only refusal:") && !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
        #expect(logged.count >= 2,
                "Both gate surfaces must log: found \(logged.count) refusal log lines.")
        for line in logged {
            let interpolations = line.components(separatedBy: "\\(").count - 1
            #expect(interpolations == 1,
                    "A refusal log line carries \(interpolations) interpolations — exactly one is allowed, and it is the enum's own raw value: \(line.trimmingCharacters(in: .whitespaces))")
            #expect(line.contains("\\(operation.rawValue, privacy: .public)"),
                    "A refusal log line interpolates something other than the operation: \(line.trimmingCharacters(in: .whitespaces))")
            // Two decisions exist now (the offline refusal grew its own lines,
            // same privacy contract) — every line must name ONE of them.
            #expect(line.contains("decision=lapsed_subscription_read_only")
                        || line.contains("decision=offline_read_only"),
                    "A refusal log line does not name a known decision: \(line.trimmingCharacters(in: .whitespaces))")
        }
    }
}

// MARK: - No write goes around the gate

/// The class of defect the operation walk above CANNOT see: a write that never reaches
/// `ReadOnlyGate` at all. `everyWriteClassIsRefusedWhileLapsedAndAllowedOtherwise` proves the gate
/// says no to all 55 operations; it says nothing about a button that never asks it. Three such
/// buttons shipped (an adversarial run, 2026-08-26): "Add to invoice" on an approved change order,
/// the certificate file importer on a customer, and two first-render singleton bootstraps.
///
/// So this walks the SOURCE for the two shapes those bugs had. It is a net, not a proof: a write
/// spelled in some third way is still on the reviewer. What it does guarantee is that these two
/// shapes cannot come back silently.
@MainActor
struct EveryWriteIsGatedTests {

    /// The screens and the access-control surface — where a person's taps land. `Models/` and
    /// `Sync/` are deliberately outside: their writes are helpers (`ChangeOrder.addItemsToInvoice`)
    /// and server-truth bookkeeping, and it is the CALLERS scanned here that owe the refusal.
    /// `DemoMode` seeds the screenshot dataset and never runs for a real person. Files DIRECTLY
    /// in the three folders, as the original walk read them (no subfolders exist there today).
    private func sources() -> [(name: String, lines: [String], depths: [Int])] {
        let folders = ["Screens/", "AccessControl/", "UIComponents/"]
        return GLSource.files(excluding: ["AccessControl/DemoMode.swift", "AccessControl/ReadOnlyGate.swift"])
            .filter { file in
                folders.contains { folder in
                    file.path.hasPrefix(folder) && !file.path.dropFirst(folder.count).contains("/")
                }
            }
            .map { file in
                let lines = file.text.components(separatedBy: "\n")
                return (name: (file.path as NSString).lastPathComponent, lines: lines, depths: braceDepths(lines))
            }
    }

    /// Is this line's write guarded?
    ///
    /// Walks OUTWARD from the block the write sits in. The gate counts when it is named in that
    /// block or in any block around it, out to and including the enclosing `func` — the action.
    /// It stops WITHOUT counting a `some View` body: a gate on some other control elsewhere on the
    /// same screen is not a gate on this one, and treating the whole `body` as one scope is exactly
    /// what would have let the customer file importer through.
    private func isGuarded(line index: Int, in lines: [String], _ depths: [Int]) -> Bool {
        var line = index
        var level = depths[index]
        for _ in 0..<12 {
            guard level > 0 else { return false }
            var start = line
            while start >= 0 && depths[start] >= level { start -= 1 }
            guard start >= 0 else { return false }
            var end = line
            while end < lines.count && depths[end] >= level { end += 1 }
            let opener = lines[start]
            let isFunction = opener.range(of: #"\bfunc\s+\w+"#, options: .regularExpression) != nil
            if opener.contains("some View") && !isFunction { return false }   // the screen's body — too coarse
            if lines[start..<end].contains(where: { $0.contains("ReadOnlyGate") }) { return true }
            if isFunction { return false }
            level -= 1
            line = start
        }
        return false
    }

    /// Writes that are correctly ungated WHERE THEY STAND because the refusal happens at their one
    /// caller, keyed by file and the write itself. Each entry has to say where the real gate is.
    ///
    /// Re-checked below: an entry that no longer matches a flagged write FAILS the test, so this
    /// cannot quietly outlive the code it excuses.
    private static let gatedByTheirCaller: [String: String] = [
        "StripeConnectScreen.swift|modelContext.insert(created)":
            "ensureProfile(): every caller gates first — the pay-default binding, connect(), and refreshStatus().",
    ]

    /// Shape one: inserting or deleting a row.
    @Test func noScreenInsertsOrDeletesWithoutTheGate() {
        var writes = 0
        var ungated: [String] = []
        var used: Set<String> = []

        for source in sources() {
            for (index, line) in source.lines.enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.hasPrefix("//"),
                      trimmed.contains("modelContext.insert(")
                        || trimmed.contains("modelContext.delete(")
                        || trimmed.contains("modelContext.deleteSynced(") else { continue }
                writes += 1
                guard !isGuarded(line: index, in: source.lines, source.depths) else { continue }
                let key = "\(source.name)|\(trimmed)"
                if Self.gatedByTheirCaller[key] != nil {
                    used.insert(key)
                } else {
                    ungated.append("\(source.name):\(index + 1) — \(trimmed)")
                }
            }
        }

        // A vacuity floor, not a target. It was 25, then 15, then 5; the job, receipt, price sheet, business
        // profile and work schedule writes, and then every delete (DeletionService) and document
        // write (DocumentService), have moved into Services/Domain (gated there, and pinned by
        // DomainWritesAreGatedTests), so few are left in the screens for this walk to find.
        #expect(writes >= 4, "Only \(writes) writes were found; the walk is not reaching the screens.")
        #expect(ungated.isEmpty,
                "These write while lapsed — a lapsed app must do nothing on the owner's behalf: \(ungated.joined(separator: ", "))")
        let stale = Set(Self.gatedByTheirCaller.keys).subtracting(used)
        #expect(stale.isEmpty,
                "The gated-by-their-caller list has entries that match nothing any more — delete them: \(stale.sorted().joined(separator: ", "))")
    }

    /// Shape two: a file importer that stores what it imported. Every one of these ends in a write,
    /// and the customer certificate importer stored two blobs and a filename with no gate at all.
    ///
    /// A closure that hands the work straight to a function in the same file counts as gated when
    /// THAT function gates — one hop, which is how the contractor package's importer is written.
    @Test func everyFileImporterGoesThroughTheGate() {
        var importers = 0
        var ungated: [String] = []

        for source in sources() {
            let text = source.lines.joined(separator: "\n")
            for (index, line) in source.lines.enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.hasPrefix("//"), trimmed.contains(".fileImporter(") else { continue }
                importers += 1
                let level = source.depths[index] + 1
                var end = index + 1
                while end < source.lines.count && source.depths[end] >= level { end += 1 }
                let body = source.lines[index..<end].joined(separator: "\n")
                if body.contains("ReadOnlyGate") { continue }
                // One hop: `importFile(result)` is gated if `func importFile` is.
                let called = body.matches(of: /\b([a-z]\w*)\(/).map { String($0.1) }
                let delegates = called.contains { name in
                    guard let declaration = text.range(of: "func \(name)(") else { return false }
                    let after = text[declaration.lowerBound...].prefix(2_000)
                    return after.contains("ReadOnlyGate")
                }
                if !delegates {
                    ungated.append("\(source.name):\(index + 1)")
                }
            }
        }

        #expect(importers >= 6, "Only \(importers) file importers were found; the walk is not reaching the screens.")
        #expect(ungated.isEmpty,
                "These importers store an imported file with no read-only gate: \(ungated.joined(separator: ", "))")
    }
}

// MARK: - The catalog carries what the banner and the alert print

struct LapsedCopyTests {

    private var catalog: [String: Any] {
        get throws {
            let text = try #require(GLSource.file("Localizable.xcstrings"))
            let json = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
            return (json?["strings"] as? [String: Any]) ?? [:]
        }
    }

    private func spanish(_ key: String, in strings: [String: Any]) -> String? {
        guard let entry = strings[key] as? [String: Any],
              let localizations = entry["localizations"] as? [String: Any],
              let es = localizations["es"] as? [String: Any],
              let unit = es["stringUnit"] as? [String: Any] else { return nil }
        return unit["value"] as? String
    }

    /// `GLSubscriptionBanner`'s strings resolve against `Bundle.main` — THIS app's catalog — so the
    /// package can print them only if this app carries the keys. PARITY.md names the two My
    /// Business needs (it renders `.entered`); without them the banner falls back to the English
    /// key and is untranslated in Spanish.
    @Test func theCatalogCarriesTheSharedBannerKeys() throws {
        let strings = try catalog
        let entered = "Your subscription ended, so your records are read-only. Everything is still here to read. Nothing can be added, changed or exported until you reactivate."
        #expect(strings["Reactivate"] != nil, "The banner's action word is missing from the catalog.")
        #expect(spanish("Reactivate", in: strings) == "Reactivar")
        #expect(strings[entered] != nil, "The `.entered` banner sentence is missing from the catalog.")
        #expect(spanish(entered, in: strings)?.contains("solo lectura") == true,
                "The Spanish banner sentence is missing or wrong.")
        // Register: agregar, never añadir — fleet-wide (PARITY.md).
        #expect(spanish(entered, in: strings)?.contains("añadir") != true)
    }

    /// The refusal alert, both halves of it, in both languages.
    @Test func theCatalogCarriesTheRefusalAlert() throws {
        let strings = try catalog
        let title = "Your subscription ended"
        let body = "%@ needs an active subscription. Everything you already have is still here to read — nothing can be added, changed or exported until you reactivate."
        #expect(spanish(title, in: strings) == "Tu suscripción terminó")
        #expect(strings[body] != nil, "The refusal alert's message is missing from the catalog.")
        #expect(spanish(body, in: strings)?.contains("%@") == true,
                "The Spanish message dropped the placeholder — it would print the sentence with no subject.")
    }

    /// Every operation phrase is translated. One missing `es` is one alert that reads half in
    /// English to a Spanish-speaking owner.
    @Test @MainActor func everyOperationPhraseIsTranslated() throws {
        let strings = try catalog
        // `phrase` resolves through the catalog in the CURRENTLY chosen language, and these tests
        // run in the host app's process — so the app's own language choice is pinned here rather
        // than inherited, and restored after. (The UserDefaults-pollution rule, applied to language:
        // a leftover Spanish choice would make every `phrase` come back translated and every
        // lookup below miss.)
        let localization = MBLocalization.shared
        let previous = localization.language
        defer { localization.language = previous }
        localization.language = .en

        for operation in MBWriteOperation.allCases {
            let english = operation.phrase
            #expect(strings[english] != nil,
                    "\(operation.rawValue): the phrase \"\(english)\" is not in the string catalog.")
            #expect(spanish(english, in: strings)?.isEmpty == false,
                    "\(operation.rawValue): the phrase \"\(english)\" has no Spanish.")
        }
    }
}

// MARK: - The DEBUG-only QA override is compiled out of Release

/// The positive control the owner's security bar asks for: never "take it on trust" that a debug
/// hook is gone from Release. `-forceLapsed` exists so the read-only app can be LOOKED at (it is
/// otherwise unreachable without a genuinely expired subscription), and it can only ever turn the
/// lapse ON — it grants nothing and unlocks nothing, so the worst a shipped copy could do is refuse
/// writes, not hand out the paid app. It is still fenced, and this is the fence.
struct ForceLapsedIsDebugOnlyTests {

    private var source: String {
        get throws { try #require(GLSource.file("AccessControl/SubscriptionManager.swift")) }
    }

    @Test func theOverrideExistsAndIsFencedByDEBUG() throws {
        let text = try source
        guard let range = text.range(of: "-forceLapsed") else {
            Issue.record("The -forceLapsed QA override is gone — remove this test with it.")
            return
        }
        // Everything before the flag must contain an unclosed `#if DEBUG`.
        let before = String(text[text.startIndex..<range.lowerBound])
        let opens = before.components(separatedBy: "#if DEBUG").count - 1
        let closes = before.components(separatedBy: "#endif").count - 1
        #expect(opens > closes,
                "-forceLapsed is not inside a #if DEBUG block — it would ship in Release.")
    }

    /// The positive control: this test target is a DEBUG build, so the flag IS live here. If the
    /// fence were wrong in the other direction (the flag compiled out even in DEBUG) the override
    /// would silently stop working and nobody would notice until they tried to use it.
    @MainActor
    @Test func theOverrideIsLiveInThisDebugBuild() {
        let subs = SubscriptionManager.shared
        defer { Entitlement.reset(subs) }
        Entitlement.subscribed(subs)
        // Not asserting `isLapsed` here — this process was not launched with the flag. What is
        // asserted is that the flag is READ at all in a DEBUG build, which the source check above
        // cannot tell apart from a comment.
        #expect(!ProcessInfo.processInfo.arguments.contains("-forceLapsed"),
                "The test host must not be launched with -forceLapsed, or every gate test would run against a forced lapse.")
        #expect(!subs.isLapsed)
    }
}
