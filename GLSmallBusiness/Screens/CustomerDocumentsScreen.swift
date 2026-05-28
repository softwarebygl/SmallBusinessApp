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
    case receipts

    var id: String { rawValue }

    var pluralTitle: String {
        switch self {
        case .estimates: "Estimates"
        case .invoices: "Invoices"
        case .receipts: "Receipts"
        }
    }

    var singularTitle: String {
        switch self {
        case .estimates: "Estimate"
        case .invoices: "Invoice"
        case .receipts: "Receipt"
        }
    }

    var systemImage: String {
        switch self {
        case .estimates: "doc.text"
        case .invoices: "banknote"
        case .receipts: "list.bullet.rectangle"
        }
    }
}

struct CustomerDocumentsScreen: View {
    let customer: Customer
    let kind: CustomerDocumentKind

    @State private var showingComingSoon = false

    var body: some View {
        ScrollView {
            ContentUnavailableView {
                Label("No \(kind.pluralTitle)", systemImage: kind.systemImage)
            } description: {
                Text("\(kind.pluralTitle) for \(customer.listDisplayName) will appear here.")
            }
            .padding(.top, 80)
        }
        .containerBackground(for: .navigation) {
            PrimaryBackground()
        }
        .navigationTitle(kind.pluralTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showingComingSoon = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("New \(kind.singularTitle)")
            }
        }
        .alert("Coming soon", isPresented: $showingComingSoon) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("Creating a new \(kind.singularTitle.lowercased()) isn't available yet.")
        }
    }
}

#Preview {
    NavigationStack {
        CustomerDocumentsScreen(
            customer: Customer(firstName: "Jane", lastName: "Doe"),
            kind: .estimates
        )
    }
    .modelContainer(for: Customer.self, inMemory: true)
}
