//
//  CustomerDetails.swift
//  GLSmallBusiness
//
//  Created by Gold Life LLC on 6/21/26.
//
//  Read-only, categorized view of a customer's details (Contact + Address), reached via the
//  "More Info" row on the customer hub. Edit opens the same form. Mirrors CompanyDetailsScreen /
//  PersonalDetailsScreen so all three "More Info" screens are identical in shape.
//

import SwiftUI

struct CustomerDetailsScreen: View {
    @Environment(\.colorScheme) private var colorScheme
    let customer: Customer
    @State private var showingEdit = false

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                GLCard(title: "Contact") {
                    infoRow("Name", customer.fullName)
                    infoRow("Email", customer.email)
                    infoRow("Phone", customer.phoneNumber)
                    if !customer.officePhone.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        infoRow("Office", customer.officePhone)
                    }
                    if let business = customer.businessName?.trimmingCharacters(in: .whitespacesAndNewlines),
                       !business.isEmpty {
                        infoRow("Business", business)
                    }
                }

                GLCard(title: "Address") {
                    Text(customer.address.isEmpty ? "—" : customer.address.formattedMultiline)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding()
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
        }
        .background { GLColor.backgroundPrimary.render(in: colorScheme).ignoresSafeArea() }
        .navigationTitle("More Info")
        .toolbarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { showingEdit = true } label: { Label("Edit customer", systemImage: "pencil") }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .accessibilityLabel("More")
            }
        }
        .navigationDestination(isPresented: $showingEdit) {
            CustomerFormScreen(editing: customer)
        }
    }

    private func infoRow(_ label: LocalizedStringKey, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value.isEmpty ? "—" : value).multilineTextAlignment(.trailing)
        }
    }
}
