//
//  ReceiptsTabScreen.swift
//  GLSmallBusiness
//
//  Created by Gold Life LLC on 5/28/26.
//

import SwiftUI
import SwiftData
import GoldLifeUI

/// The universal Receipts tab — every receipt across the business, built for quick capture:
/// scan, (optionally) assign a customer, done. New scans default to the business.
///
/// iPhone keeps the NavigationStack push flow; iPad uses a NavigationSplitView master-detail so
/// the list and the selected receipt sit side by side — matching the Customers tab.
struct ReceiptsTabScreen: View {
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Query(sort: \Receipt.date, order: .reverse) private var allReceipts: [Receipt]
    @State private var selectedReceiptID: PersistentIdentifier?

    private var selectedReceipt: Receipt? {
        allReceipts.first { $0.persistentModelID == selectedReceiptID }
    }

    var body: some View {
        if sizeClass == .regular {
            NavigationSplitView {
                ReceiptListView(receipts: allReceipts, defaultCustomer: nil, showsAssignee: true,
                                enablesFilters: true, selectionID: $selectedReceiptID,
                                showsMenuButton: true, solidBackground: true)
                    .glMinimalBackButtons()
            } detail: {
                NavigationStack {
                    Group {
                        if let selectedReceipt {
                            ReceiptDetailScreen(receipt: selectedReceipt)
                        } else {
                            ContentUnavailableView("Select a receipt", systemImage: "doc.viewfinder")
                                .containerBackground(for: .navigation) { PrimaryBackground() }
                        }
                    }
                    .glMinimalBackButtons()
                }
            }
            .onAppear { selectFirstOnIPad() }
            .onChange(of: allReceipts.map(\.persistentModelID)) { _, _ in selectFirstOnIPad() }
        } else {
            NavigationStack {
                ReceiptListView(receipts: allReceipts, defaultCustomer: nil, showsAssignee: true,
                                enablesFilters: true, showsMenuButton: true)
                    .glMinimalBackButtons()
            }
        }
    }

    private func selectFirstOnIPad() {
        guard sizeClass == .regular, selectedReceipt == nil else { return }
        selectedReceiptID = allReceipts.first?.persistentModelID
    }
}
