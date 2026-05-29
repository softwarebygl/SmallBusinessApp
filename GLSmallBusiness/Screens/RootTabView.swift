//
//  RootTabView.swift
//  GLSmallBusiness
//
//  Created by Gold Life LLC on 5/28/26.
//

import SwiftUI

/// App root: Customers, a universal Receipts tab, and Stats.
struct RootTabView: View {
    var body: some View {
        TabView {
            CustomersScreen()
                .tabItem {
                    Label("Customers", systemImage: "person.2")
                }
            ReceiptsTabScreen()
                .tabItem {
                    Label("Receipts", systemImage: "doc.viewfinder")
                }
            StatsScreen()
                .tabItem {
                    Label("Stats", systemImage: "chart.bar")
                }
        }
    }
}
