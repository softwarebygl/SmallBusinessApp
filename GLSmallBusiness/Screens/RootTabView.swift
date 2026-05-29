//
//  RootTabView.swift
//  GLSmallBusiness
//
//  Created by Gold Life LLC on 5/28/26.
//

import SwiftUI

/// App root: Customers, a universal Receipts tab, and Stats.
///
/// Per Apple's documented pattern (WWDC24 "Elevate your tab and sidebar experience in iPadOS"
/// + HIG Tab bars): the modern `Tab(...)` API plus `.tabViewStyle(.sidebarAdaptable)` give
/// iPhone a bottom tab bar, iPad portrait a centered tab bar with a sidebar toggle, and iPad
/// landscape an auto-shown leading sidebar — letting the user choose, and letting each tab's
/// NavigationSplitView own the top bar cleanly when the sidebar is in use.
struct RootTabView: View {
    var body: some View {
        TabView {
            Tab("Customers", systemImage: "person.2") {
                CustomersScreen()
            }
            Tab("Receipts", systemImage: "doc.viewfinder") {
                ReceiptsTabScreen()
            }
            Tab("Stats", systemImage: "chart.bar") {
                StatsScreen()
            }
        }
        .tabViewStyle(.sidebarAdaptable)
    }
}
