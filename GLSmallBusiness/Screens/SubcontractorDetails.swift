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
import GoldLifeUI

struct SubcontractorDetailsScreen: View {
    @Environment(\.colorScheme) private var colorScheme
    let subcontractor: Subcontractor
    @State private var showingEdit = false

    var body: some View {
        // F24: draws "This subcontractor was removed" once the subcontractor is deleted while open.
        LiveRecordGate(subcontractor, title: "More Info") { aliveBody }
    }

    @ViewBuilder private var aliveBody: some View {
        ScrollView {
            VStack(spacing: 20) {
                MBTitledCard(title: "Contact") {
                    infoRow("Name", subcontractor.fullName)
                    if !subcontractor.businessName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        infoRow("Business", subcontractor.businessName)
                    }
                    contactRow("Email", .email, subcontractor.email)
                    contactRow("Phone", .phone, subcontractor.phone)
                }

                MBTitledCard(title: "Address") {
                    if subcontractor.address.isEmpty {
                        Text("—")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        GLContactLink(.address, subcontractor.address.singleLine, display: subcontractor.address.formattedMultiline)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                MBTitledCard(title: "Tax & pay") {
                    infoRow("Tax ID", subcontractor.hasTIN
                            ? "\(subcontractor.w9TINType?.label ?? mbLoc("TIN")) \(subcontractor.maskedTIN)" : "—")
                    infoRow("Hourly rate", subcontractor.hourlyRate > 0
                            ? mbLoc("\(subcontractor.hourlyRate.formatted(.money))/hr") : "—")
                }

                if !subcontractor.notes.isEmpty {
                    MBTitledCard(title: "Notes") {
                        Text(subcontractor.notes).frame(maxWidth: .infinity, alignment: .leading)
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
        .contentMargins(.top, GLScript.titleClearance(for: GLScript.padded(mbLoc("More Info"))), for: .scrollContent)
        .mbSystemBanners()
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showingEdit = true } label: {
                    Label("Edit", systemImage: "pencil")
                }
            }
        }
        .navigationDestination(isPresented: $showingEdit) {
            SubcontractorFormScreen.editingLive(subcontractor)
        }
    }

    private func infoRow(_ label: LocalizedStringKey, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value.isEmpty ? "—" : value).multilineTextAlignment(.trailing).copyable(value)
        }
    }

    private func contactRow(_ label: LocalizedStringKey, _ kind: GLContactLink.Kind, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("—").foregroundStyle(.secondary)
            } else {
                GLContactLink(kind, value).multilineTextAlignment(.trailing)
            }
        }
    }
}
