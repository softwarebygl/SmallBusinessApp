//
//  CustomerDocumentsScreen.swift
//  GLSmallBusiness
//
//  Created by Gold Life LLC on 5/28/26.
//

import SwiftUI
import SwiftData

enum CustomerDocumentKind: String, CaseIterable, Identifiable, Hashable {
    case estimates
    case contracts
    case invoices
    case jobs
    case receipts
    /// A change order is the customer's paper trail — the document they signed when the
    /// scope changed. It was reachable only from the invoice that owns it, or the global
    /// list under Documents; never from the customer it belongs to.
    case changeOrders

    var id: String { rawValue }

    var pluralTitle: String {
        switch self {
        case .estimates: mbLoc("Estimates")
        case .contracts: mbLoc("Contracts")
        case .invoices: mbLoc("Invoices")
        case .jobs: mbLoc("Jobs")
        case .receipts: mbLoc("Expenses")
        case .changeOrders: mbLoc("Change Orders")
        }
    }

    var singularTitle: String {
        switch self {
        case .estimates: mbLoc("Estimate")
        case .contracts: mbLoc("Contract")
        case .invoices: mbLoc("Invoice")
        case .jobs: mbLoc("Job")
        case .receipts: mbLoc("Expense")
        case .changeOrders: mbLoc("Change Order")
        }
    }

    var systemImage: String {
        switch self {
        case .estimates: "doc.text"
        case .contracts: "doc.text.fill"
        case .invoices: "banknote"
        case .jobs: "hammer"
        case .receipts: "list.bullet.rectangle"
        case .changeOrders: "pencil.and.list.clipboard"
        }
    }
}
