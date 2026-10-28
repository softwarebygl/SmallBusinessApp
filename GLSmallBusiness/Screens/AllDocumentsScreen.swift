//
//  AllDocumentsScreen.swift
//  GLSmallBusiness
//
//  Every business document AND record behind ONE door (owner restructure,
//  2026-08-22: the Business hub keeps foundational details; the Job Records
//  lists moved here off the Menu the same day). Each row pushes the same
//  screen it always did.
//

import SwiftUI
import GoldLifeUI
import SwiftData

struct AllDocumentsScreen: View {
    let profile: BusinessProfile

    @Query private var projects: [Project]
    @State private var activeDocument: BusinessDocument?

    private enum BusinessDocument: String, Identifiable, Hashable {
        case insurance, taxReport, w9
        var id: String { rawValue }
    }

    private var gold: Color { GLTheme.accentFill }

    var body: some View {
        Form {
            Section("Job Records") {
                NavigationLink {
                    AllEstimatesScreen()
                } label: {
                    Label {
                        Text("All Estimates")
                    } icon: {
                        Image(systemName: "doc.text").foregroundStyle(gold)
                    }
                }
                NavigationLink {
                    AllInvoicesScreen()
                } label: {
                    Label {
                        Text("All Invoices")
                    } icon: {
                        Image(systemName: "doc.plaintext").foregroundStyle(gold)
                    }
                }
                NavigationLink {
                    AllJobsScreen()
                } label: {
                    Label {
                        Text("All Jobs")
                    } icon: {
                        Image(systemName: "hammer").foregroundStyle(gold)
                    }
                }
                if !projects.isEmpty {
                    NavigationLink {
                        AllProjectsScreen()
                    } label: {
                        Label {
                            Text("All Projects")
                        } icon: {
                            Image(systemName: "folder").foregroundStyle(gold)
                        }
                    }
                }
                NavigationLink {
                    AllChangeOrdersScreen()
                } label: {
                    Label {
                        Text("All Change Orders")
                    } icon: {
                        Image(systemName: "pencil.and.list.clipboard").foregroundStyle(gold)
                    }
                }
                NavigationLink {
                    AllReceiptsScreen()
                } label: {
                    Label {
                        Text("All Expenses")
                    } icon: {
                        Image(systemName: "doc.viewfinder").foregroundStyle(gold)
                    }
                }
            }

            Section("Catalog & Pricing") {
                NavigationLink {
                    PriceSheetScreen()
                } label: {
                    Label {
                        Text("Price Sheet")
                    } icon: {
                        Image(systemName: "tag").foregroundStyle(gold)
                    }
                }
            }

            Section {
                Button {
                    activeDocument = .insurance
                } label: {
                    row("Insurance & Licensing", systemImage: "checkmark.shield",
                        badge: profile.hasComplianceDocuments)
                }
                .buttonStyle(.plain)
                Button {
                    // The W-9 carries the full Tax ID, so it stays behind Face ID.
                    Task {
                        if await BiometricGate.authenticateInSession(reason: mbLoc("Unlock to generate your W-9.")) {
                            activeDocument = .w9
                        }
                    }
                } label: {
                    row("Generate a W-9", systemImage: "doc.plaintext")
                }
                .buttonStyle(.plain)
                Button {
                    activeDocument = .taxReport
                } label: {
                    row("Income & Expenses (Year-End)", systemImage: "doc.text")
                }
                .buttonStyle(.plain)
                // ONE DOOR for the accountant handoff. Three year-end exports lived in
                // three places, two of them named "Year-End Report", and the ONLY one a
                // contractor would find from here is the incomplete one: its Net is built
                // from StatsSummary, which carries no wage line and no subcontractor-payment
                // line, so it silently omits the two numbers an accountant needs most.
                // These two rows lead to the exports that hold them.
                NavigationLink {
                    EmployeesScreen(isWageDoor: true)
                } label: {
                    row("Employee Wages", systemImage: "person.2")
                }
                NavigationLink {
                    SubcontractorsScreen()
                } label: {
                    row("Subcontractor 1099s (Year-End)", systemImage: "person.text.rectangle")
                }
            } header: {
                Text("Business Documents")
            } footer: {
                Text("Income & Expenses does not include payroll or subcontractor payments — export those separately with the two rows above.")
            }
        }
        .glFormBackground()
        .contentMargins(.top, GLScript.titleClearance(for: GLScript.padded(mbLoc("Documents"))), for: .scrollContent)   // breathing room below the large title's descenders
        .navigationTitle(GLScript.padded(mbLoc("Documents")))
        .toolbarTitleDisplayMode(.large)
        .navigationDestination(item: $activeDocument) { document in
            switch document {
            case .insurance:
                ComplianceDocsManagerSheet(profile: profile)
            case .taxReport:
                YearEndTaxReportSheet()
            case .w9:
                W9DocumentSheet(profile: profile)
            }
        }
    }

    /// One document row: gold icon, title, optional compliance badge, chevron
    /// (these are pushes, drawn by hand because the rows are Buttons, not links).
    private func row(_ title: LocalizedStringKey, systemImage: String, badge: Bool = false) -> some View {
        Label {
            HStack {
                Text(title)
                    .foregroundStyle(GLTheme.textPrimary)
                Spacer()
                if badge {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.footnote)
                        .foregroundStyle(gold)
                }
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(GLTheme.textTertiary)
            }
        } icon: {
            Image(systemName: systemImage)
                .foregroundStyle(gold)
        }
        .contentShape(Rectangle())
    }
}
