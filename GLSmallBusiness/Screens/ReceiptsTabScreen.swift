//
//  ReceiptsTabScreen.swift
//  GLSmallBusiness
//
//  Created by Gold Life LLC on 5/28/26.
//

import SwiftUI
import SwiftData

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
                                enablesFilters: true, selectionID: $selectedReceiptID, showsMenuButton: true)
            } detail: {
                NavigationStack {
                    if let selectedReceipt {
                        ReceiptDetailScreen(receipt: selectedReceipt)
                    } else {
                        ContentUnavailableView("Select a Receipt", systemImage: "doc.viewfinder")
                            .containerBackground(for: .navigation) { PrimaryBackground() }
                    }
                }
            }
            .onAppear { selectFirstOnIPad() }
            .onChange(of: allReceipts.map(\.persistentModelID)) { _, _ in selectFirstOnIPad() }
        } else {
            NavigationStack {
                ReceiptListView(receipts: allReceipts, defaultCustomer: nil, showsAssignee: true,
                                enablesFilters: true, showsMenuButton: true)
            }
        }
    }

    private func selectFirstOnIPad() {
        guard sizeClass == .regular, selectedReceipt == nil else { return }
        selectedReceiptID = allReceipts.first?.persistentModelID
    }
}

/// The business's own receipts (those not assigned to a customer), shown from My Company.
struct BusinessReceiptsScreen: View {
    @Query(sort: \Receipt.date, order: .reverse) private var allReceipts: [Receipt]

    var body: some View {
        ReceiptListView(
            receipts: allReceipts.filter { $0.customer == nil },
            defaultCustomer: nil
        )
    }
}
