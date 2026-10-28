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
import GoldLifeUI

struct CustomerDetailsScreen: View {
    @Environment(\.colorScheme) private var colorScheme
    let customer: Customer
    @State private var showingEdit = false

    var body: some View {
        // F24: draws "This customer was removed" once the customer is deleted while open.
        LiveRecordGate(customer, title: "More Info") { aliveBody }
    }

    @ViewBuilder private var aliveBody: some View {
        ScrollView {
            VStack(spacing: 20) {
                MBTitledCard(title: "Contact") {
                    infoRow("Name", customer.fullName)
                    contactRow("Email", .email, customer.email)
                    contactRow("Phone", .phone, customer.phoneNumber)
                    if !customer.officePhone.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        contactRow("Office", .phone, customer.officePhone)
                    }
                    if let business = customer.businessName?.trimmingCharacters(in: .whitespacesAndNewlines),
                       !business.isEmpty {
                        infoRow("Business", business)
                    }
                }

                MBTitledCard(title: "Billing Address") {
                    if customer.address.isEmpty {
                        Text("—")
                            .foregroundStyle(GLTheme.textSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        GLContactLink(.address, customer.address.singleLine, display: customer.address.formattedMultiline)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                MBTitledCard(title: "Service Address") {
                    if customer.sameAsBillingAddress {
                        HStack {
                            Text("Same as billing address")
                                .foregroundStyle(GLTheme.textSecondary)
                            Spacer()
                        }
                        if !customer.address.isEmpty {
                            GLContactLink(.address, customer.address.singleLine, display: customer.address.formattedMultiline)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    } else if customer.serviceAddress.isEmpty {
                        Text("—")
                            .foregroundStyle(GLTheme.textSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        GLContactLink(.address, customer.serviceAddress.singleLine, display: customer.serviceAddress.formattedMultiline)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(.horizontal, GLLayout.rowCardInset)
            .padding(.vertical)
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
        }
        .background { GLTheme.background.ignoresSafeArea() }
        .navigationTitle(GLScript.padded(mbLoc("More Info")))
        .toolbarTitleDisplayMode(.large)
        // Whole points (QA 2026-10-03 L15): a fractional clearance (18.696 pt for "EST-0001",
        // 30.664 for "More Info") leaves the scroll view a fraction of a pixel below its top at
        // load, so UIKit opens the screen with the large title already collapsed.
        .contentMargins(.top, GLScript.titleClearance(for: GLScript.padded(mbLoc("More Info"))).rounded(.up), for: .scrollContent)
        .mbSystemBanners()
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showingEdit = true } label: {
                    Label("Edit", systemImage: "pencil")
                }
            }
        }
        .navigationDestination(isPresented: $showingEdit) {
            CustomerFormScreen.editingLive(customer)
        }
    }

    private func infoRow(_ label: LocalizedStringKey, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(label).foregroundStyle(GLTheme.textSecondary)
            Spacer()
            Text(value.isEmpty ? "—" : value).multilineTextAlignment(.trailing).copyable(value)
        }
    }

    private func contactRow(_ label: LocalizedStringKey, _ kind: GLContactLink.Kind, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(label).foregroundStyle(GLTheme.textSecondary)
            Spacer()
            if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("—").foregroundStyle(GLTheme.textSecondary)
            } else {
                GLContactLink(kind, value).multilineTextAlignment(.trailing)
            }
        }
    }
}
