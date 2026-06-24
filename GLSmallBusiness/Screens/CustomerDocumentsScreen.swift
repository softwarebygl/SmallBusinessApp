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
    case invoices
    case jobs
    case receipts

    var id: String { rawValue }

    var pluralTitle: String {
        switch self {
        case .estimates: String(localized: "Estimates")
        case .invoices: String(localized: "Invoices")
        case .jobs: String(localized: "Jobs")
        case .receipts: String(localized: "Receipts")
        }
    }

    var singularTitle: String {
        switch self {
        case .estimates: String(localized: "Estimate")
        case .invoices: String(localized: "Invoice")
        case .jobs: String(localized: "Job")
        case .receipts: String(localized: "Receipt")
        }
    }

    var systemImage: String {
        switch self {
        case .estimates: "doc.text"
        case .invoices: "banknote"
        case .jobs: "hammer"
        case .receipts: "list.bullet.rectangle"
        }
    }
}
