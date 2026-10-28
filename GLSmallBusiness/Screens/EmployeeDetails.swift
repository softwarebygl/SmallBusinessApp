//
//  EmployeeDetails.swift
//  GLSmallBusiness
//
//  Created by Gold Life LLC on 6/21/26.
//
//  Read-only, categorized view of an employee's profile (Contact, Pay, Employment, Notes), reached
//  via the "More Info" row on the employee hub. Edit opens the same form. Mirrors CompanyDetails /
//  PersonalDetails / CustomerDetails so every "More Info" screen is identical in shape.
//

import SwiftUI
import GoldLifeUI

struct EmployeeDetailsScreen: View {
    @Environment(\.colorScheme) private var colorScheme
    let employee: Employee
    @State private var showingEdit = false

    var body: some View {
        // F24: draws "This employee was removed" once the employee is deleted while open.
        LiveRecordGate(employee, title: "More Info") { aliveBody }
    }

    @ViewBuilder private var aliveBody: some View {
        ScrollView {
            VStack(spacing: 20) {
                MBTitledCard(title: "Contact") {
                    infoRow("Name", employee.fullName)
                    contactRow("Email", .email, employee.email)
                    contactRow("Phone", .phone, employee.phone)
                }

                MBTitledCard(title: "Pay") {
                    infoRow("Type", employee.payType.label)
                    if employee.payType == .hourly {
                        infoRow("Rate", mbLoc("\(employee.hourlyRate.formatted(.appMoney))/hr"))
                    } else {
                        infoRow("Salary", mbLoc("\(employee.annualSalary.formatted(.appMoney))/yr"))
                    }
                    infoRow("Pays", employee.payFrequency.label)
                    // Rolled forward from the anchor — the raw anchorPayday drifts into the past.
                    infoRow("Next payday", employee.nextPayday().formatted(Date.FormatStyle(date: .abbreviated, time: .omitted).locale(MBLocalization.currentLocale)))
                }

                MBTitledCard(title: "Employment") {
                    infoRow("Hire date", employee.hireDate.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted).locale(MBLocalization.currentLocale)))
                    infoRow("Status", employee.isActive ? mbLoc("Active") : mbLoc("Inactive"))
                }

                if !employee.notes.isEmpty {
                    MBTitledCard(title: "Notes") {
                        Text(employee.notes).frame(maxWidth: .infinity, alignment: .leading)
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
            EmployeeFormScreen.editingLive(employee)
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
