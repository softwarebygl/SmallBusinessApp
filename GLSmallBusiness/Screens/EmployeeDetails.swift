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

struct EmployeeDetailsScreen: View {
    @Environment(\.colorScheme) private var colorScheme
    let employee: Employee
    @State private var showingEdit = false

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                GLCard(title: "Contact") {
                    infoRow("Name", employee.fullName)
                    infoRow("Email", employee.email)
                    infoRow("Phone", employee.phone)
                }

                GLCard(title: "Pay") {
                    infoRow("Type", employee.payType.label)
                    if employee.payType == .hourly {
                        infoRow("Rate", "\(employee.hourlyRate.formatted(.currency(code: "USD")))/hr")
                    } else {
                        infoRow("Salary", "\(employee.annualSalary.formatted(.currency(code: "USD")))/yr")
                    }
                    infoRow("Pays", employee.payFrequency.label)
                    infoRow("Next payday", employee.anchorPayday.formatted(date: .abbreviated, time: .omitted))
                }

                GLCard(title: "Employment") {
                    infoRow("Hire date", employee.hireDate.formatted(date: .abbreviated, time: .omitted))
                    infoRow("Status", employee.isActive ? "Active" : "Inactive")
                }

                if !employee.notes.isEmpty {
                    GLCard(title: "Notes") {
                        Text(employee.notes).frame(maxWidth: .infinity, alignment: .leading)
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
            EmployeeFormScreen(editing: employee)
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
