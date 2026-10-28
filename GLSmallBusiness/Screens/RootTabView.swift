//
//  RootTabView.swift
//  GLSmallBusiness
//
//  Created by Gold Life LLC on 5/28/26.
//

import SwiftUI
import GoldLifeUI
import GoldLifeMoney

/// App root (iPhone, compact width): Contacts (Customers + Employees + Subcontractors behind a
/// segmented control — Adrian's merge, 2026-08-21) and Jobs (the All Jobs list, with the
/// Calendar pushed from its toolbar — same-day rework). Receipts live in the Menu
/// (Job Records → All Receipts) and Stats on the Business screen (→ Statistics).
///
/// The modern `Tab(...)` API with `.tabViewStyle(.automatic)`: a bottom tab bar
/// everywhere this shell runs. (iPad regular-width sessions never see it — they
/// mount IPadRootSplitView's three-column split instead; this TabView is the
/// iPhone and compact-width shell.)
/// Top-level tab identity, so screenshot automation can select a tab programmatically.
enum ScreenTab: Hashable { case contacts, contracts, money, calendar, assistant }

struct RootTabView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(AppRouter.self) private var envRouter: AppRouter?
    private var router: AppRouter { envRouter ?? .fallback }
    @State private var showingMenu = false
    @State private var selection: ScreenTab = {
        #if DEBUG
        // The people -demoScreen names (customers/employees/subcontractors) all land on the
        // Contacts tab; WHICH segment shows is AppRouter's init reading the same argument.
        if let s = DemoMode.screen {
            if s == "contracts" || s == "calendar" || s == "calendar_pushed" {
                return .contracts
            }
            if s == "money" {
                return .money
            }
            if s == "assistant" {
                return .assistant
            }
        }
        return .contacts
        #else
        return .contacts
        #endif
    }()

    var body: some View {
        TabView(selection: $selection) {
            Tab(mbLoc("Contacts"), systemImage: "person.2", value: ScreenTab.contacts) {
                ContactsScreen()
            }
            Tab(mbLoc("Contracts"), systemImage: "doc.text.fill", value: ScreenTab.contracts) {
                // The Contracts tab lands on the contracts LIST (no more Jobs; Contracts is the core hub);
                // the Calendar is one tap away in its toolbar.
                AllContractsScreen(isTabRoot: true)
            }
            Tab(mbLoc("Money"), systemImage: "dollarsign.circle", value: ScreenTab.money) {
                MoneyScreen(onMenuTap: { showingMenu = true })
                    .mbMoneyHostEnvironment()
                    .sheet(isPresented: $showingMenu) {
                        MenuScreen().glAppearance(colorScheme)
                    }
            }
            if MBFeatureFlags.assistantEnabled {
                Tab(mbLoc("Sentinel"), systemImage: "sparkles", value: ScreenTab.assistant) {
                    AssistantScreen()
                }
            }
        }
        .onChange(of: router.selectedTab) { _, newTab in
            if selection != newTab { selection = newTab }
        }
        .onChange(of: selection) { _, newTab in
            if router.selectedTab != newTab { router.selectedTab = newTab }
        }
        .tabViewStyle(.automatic)
        // Scoped to the TabView only — iOS 26's tab bar ignores the global
        // accent asset and rendered the selected item SYSTEM BLUE once the
        // root tint was removed (the root tint had to go: an adaptive tint
        // above the iPad's NavigationSplitView un-bridges the sidebar
        // selection).
        .tint(Color("AccentColor"))
        // The tab bar shrinks on scroll-down (iOS 26 native)
        // (owner ask 2026-08-23; PARITY.md "The tab bar"). A
        // standalone behaviour: it needs no tab accessory, only a scroll view in
        // the tab, which every tab root here is.
        .tabBarMinimizeBehavior(.onScrollDown)
        .glAmbientBackground { PrimaryBackground() }
    }
}
