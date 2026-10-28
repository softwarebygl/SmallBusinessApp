//
//  AllReceiptsScreen.swift
//  GLSmallBusiness
//
//  The Records-section entry for receipts — reuses the universal ReceiptListView (the same list the
//  Receipts tab shows), so every receipt is browsable from one place alongside the other records.
//

import SwiftUI
import SwiftData

struct AllReceiptsScreen: View {
    @Query(sort: \Receipt.date, order: .reverse) private var receipts: [Receipt]
    /// Opens the scanner on arrival — the "Scan receipt" entry on the Jobs tab.
    var autoScan: Bool = false

    var body: some View {
        ReceiptListView(receipts: receipts, defaultCustomer: nil,
                        autoScan: autoScan,
                        showsAssignee: true, enablesFilters: true,
                        title: "All Expenses", showsMenuButton: false)
    }
}
