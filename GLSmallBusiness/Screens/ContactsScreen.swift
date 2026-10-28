//
//  ContactsScreen.swift
//  GLSmallBusiness
//
//  The Contacts tab (Adrian, 2026-08-21): Customers, Employees, and Subcontractors
//  merged behind one segmented control. The three screens are NOT rebuilt — they stay
//  whole underneath, each keeping its own single-driver NavigationStack, toolbar
//  variants (employees' year picker, subs' Face-ID-gated 1099 export), and search.
//  "Contacts" here always means people in YOUR business; the phone's address book is
//  called "Phone Contacts" everywhere in copy so the two never blur.
//

import SwiftUI
import SwiftData
import UIKit
import GoldLifeUI

/// Which kind of person the Contacts tab is showing.
enum ContactsKind: String, CaseIterable, Identifiable {
    case customers, employees, subcontractors
    var id: Self { self }
    /// What the segment shows — and what VoiceOver reads. "Subcontractors" truncates
    /// to "Subcontra…" in the iPad list column, so the segment wears the trade's own
    /// short word. (No separate full-word accessibility label: SwiftUI applies custom
    /// labels to segmented Picker content inconsistently across launches.)
    var segmentTitle: String {
        switch self {
        case .customers: mbLoc("Customers")
        case .employees: mbLoc("Employees")
        case .subcontractors: mbLoc("Subs")
        }
    }
}

/// App-wide navigation state shared by both shells (iPhone tabs, iPad split) and any
/// deep link: ONE writable home for "which people list is showing", so the segmented
/// control, the -demoScreen screenshot mapping, and future menu shortcuts all drive
/// the same state instead of each shell keeping a private copy.
@Observable
final class AppRouter {
    var contactsKind: ContactsKind = .customers
    var selectedTab: ScreenTab = .contacts
    var ipadSection: String = "contacts"

    /// Screens render in previews and the unit-test host without a RootView above them
    /// to inject the router. A shared fallback keeps every render site working — and
    /// because it is ONE shared instance, the picker and the panes still agree.
    static let fallback = AppRouter()

    /// Routes root-level screen targets directly to their native tab / iPad sidebar column
    /// (and segment) instead of pushing a duplicate root screen onto the Assistant's stack.
    @MainActor
    func navigateToRootScreen(_ name: String) -> Bool {
        switch name {
        case "customer":
            contactsKind = .customers
            selectedTab = .contacts
            ipadSection = "contacts"
            return true
        case "employee", "time_entry", "paycheck":
            contactsKind = .employees
            selectedTab = .contacts
            ipadSection = "contacts"
            return true
        case "subcontractor", "sub_payment":
            contactsKind = .subcontractors
            selectedTab = .contacts
            ipadSection = "contacts"
            return true
        case "contract", "contracts":
            selectedTab = .contracts
            ipadSection = "contracts"
            return true
        case "calendar", "job", "jobs":
            selectedTab = .calendar
            ipadSection = "calendar"
            return true
        case "money", "banks", "subscriptions", "bank_account", "bank_transaction":
            selectedTab = .money
            ipadSection = "money"
            return true
        case "assistant", "ai":
            selectedTab = .assistant
            ipadSection = "assistant"
            return true
        default:
            return false
        }
    }

    #if DEBUG
    /// The screenshot deep link, injectable so unit tests can assert the mapping
    /// without forging process arguments. Production callers use the () initializer.
    init(demoScreen: String?) {
        switch demoScreen {
        case "employees": contactsKind = .employees
        case "subcontractors": contactsKind = .subcontractors
        default: break
        }
    }
    convenience init() { self.init(demoScreen: DemoMode.screen) }
    #else
    init() {}
    #endif
}

/// The Contacts tab root. All three screens stay MOUNTED (ZStack, not switch) so a
/// segment flip never tears down a NavigationStack — the known dual-driver/teardown
/// bugs in this codebase all start with navigation state being destroyed mid-flight.
/// Cost is unchanged from the three-tab days: TabView kept every visited tab alive too.
struct ContactsScreen: View {
    @Environment(AppRouter.self) private var envRouter: AppRouter?
    private var router: AppRouter { envRouter ?? .fallback }

    var body: some View {
        ZStack {
            pane(CustomersScreen(), shownFor: .customers)
            pane(EmployeesScreen(isTabRoot: true), shownFor: .employees)
            pane(SubcontractorsScreen(isTabRoot: true), shownFor: .subcontractors)
        }
        .animation(nil, value: router.contactsKind)
        .onChange(of: router.contactsKind) { _, _ in
            // A flip must take the keyboard with it. The panes stay mounted, so
            // nothing detaches the outgoing pane's search field — it kept first
            // responder and keystrokes filtered the INVISIBLE list (QA-reproduced:
            // "zzz" typed over Employees blanked the hidden Customers list). The
            // old TabView resigned it by detaching the tab; this restores that.
            UIApplication.shared.sendAction(
                #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        }
    }

    @ViewBuilder
    private func pane(_ screen: some View, shownFor kind: ContactsKind) -> some View {
        let shown = router.contactsKind == kind
        screen
            .opacity(shown ? 1 : 0)
            .allowsHitTesting(shown)
            .accessibilityHidden(!shown)
            // The active pane must also be TOPMOST: an invisible pane layered above
            // it blocks accessibility hit-testing (XCUITest computed hit point
            // {-1,-1}) even though allowsHitTesting(false) passes real touches.
            .zIndex(shown ? 1 : 0)
    }
}

/// The type switcher each people list renders as its FIRST ROW, directly under the
/// script title. In-list (not a pinned safeAreaInset) on purpose: pinned content
/// reads as "scrolled under the bar" and collapses the large title — the brand's
/// script header vanished. `host` is the kind of the screen the picker sits in.
/// Pickers remain statically mounted in each list so switching segments does not
/// trigger SwiftUI list row insertion/deletion animations mid-slide; the inactive
/// panes are hidden via accessibilityHidden, allowsHitTesting(false), and zIndex.
struct ContactsSegmentPicker: View {
    @Environment(AppRouter.self) private var envRouter: AppRouter?
    private var router: AppRouter { envRouter ?? .fallback }
    let host: ContactsKind

    var body: some View {
        @Bindable var router = router
        if router.contactsKind == host {
            Picker("Contact type", selection: $router.contactsKind) {
                ForEach(ContactsKind.allCases) { kind in
                    Text(kind.segmentTitle).tag(kind)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, GLTheme.gutter)
            .padding(.bottom, 10)
            .accessibilityLabel("Contact type")
        } else {
            // Constant-height placeholder: keeps the List row height identical across all 3 panes
            // so switching segments does NOT trigger SwiftUI list row collapse/expand animations
            // (the "weird animation" Adrian reported), while ensuring exactly ONE Picker exists in
            // the accessibility tree so XCUITest and VoiceOver never see non-hittable duplicates.
            Color.clear
                .frame(height: 32)
                .padding(.horizontal, GLTheme.gutter)
                .padding(.bottom, 10)
        }
    }
}

/// Row packaging for dropping the picker into a plain-styled List.
extension ContactsSegmentPicker {
    var asListRow: some View {
        self
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets())
    }
}

#Preview {
    ContactsScreen()
        .environment(AppRouter())
        .modelContainer(for: Customer.self, inMemory: true)
}
