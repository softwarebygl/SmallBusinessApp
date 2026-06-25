//
//  SubcontractorDetails.swift
//  GLSmallBusiness
//
//  Created by Gold Life LLC on 6/21/26.
//
//  Read-only, categorized view of a subcontractor's profile (Contact, Business, Address, Tax, Notes),
//  reached via the "More Info" row on the subcontractor hub. Edit opens the same form. Mirrors
//  CompanyDetails / PersonalDetails / CustomerDetails / EmployeeDetails so all "More Info" screens match.
//

import SwiftUI

struct SubcontractorDetailsScreen: View {
    @Environment(\.colorScheme) private var colorScheme
    let subcontractor: Subcontractor
    @State private var showingEdit = false

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                GLCard(title: "Contact") {
                    infoRow("Name", subcontractor.fullName)
                    if !subcontractor.businessName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        infoRow("Business", subcontractor.businessName)
                    }
                    infoRow("Email", subcontractor.email)
                    infoRow("Phone", subcontractor.phone)
                }

                GLCard(title: "Address") {
                    Text(subcontractor.address.isEmpty ? "—" : subcontractor.address.formattedMultiline)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                GLCard(title: "Tax & pay") {
                    infoRow("Tax ID", subcontractor.hasTIN
                            ? "\(subcontractor.w9TINType?.label ?? "TIN") \(subcontractor.maskedTIN)" : "—")
                    infoRow("Hourly rate", subcontractor.hourlyRate > 0
                            ? "\(subcontractor.hourlyRate.formatted(.currency(code: "USD")))/hr" : "—")
                }

                if !subcontractor.notes.isEmpty {
                    GLCard(title: "Notes") {
                        Text(subcontractor.notes).frame(maxWidth: .infinity, alignment: .leading)
                    }
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
                    Button { showingEdit = true } label: { Label("Edit", systemImage: "pencil") }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .accessibilityLabel("More")
            }
        }
        .navigationDestination(isPresented: $showingEdit) {
            SubcontractorFormScreen(editing: subcontractor)
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
