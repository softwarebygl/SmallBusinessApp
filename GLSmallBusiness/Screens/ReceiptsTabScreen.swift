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
struct ReceiptsTabScreen: View {
    @Query(sort: \Receipt.date, order: .reverse) private var allReceipts: [Receipt]

    var body: some View {
        NavigationStack {
            ReceiptListView(receipts: allReceipts, defaultCustomer: nil, showsAssignee: true, enablesFilters: true)
        }
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
