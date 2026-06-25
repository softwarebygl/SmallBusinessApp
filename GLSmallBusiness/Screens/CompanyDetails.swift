//
//  CompanyDetails.swift
//  GLSmallBusiness
//
//  Created by Gold Life LLC on 6/15/26.
//
//  Read-only, categorized view of everything entered in the My Company edit form — Contact, License,
//  Address, the estimate/invoice messages, and the W-9 tax details. Surfaces the details that the
//  backend uses but that were previously only visible in edit mode. Edit opens the same form.

import SwiftUI

struct CompanyDetailsScreen: View {
    @Environment(\.colorScheme) private var colorScheme
    let profile: BusinessProfile
    @State private var showingEdit = false

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                GLCard(title: "Contact") {
                    infoRow("Name", profile.ownerFullName)
                    infoRow("Email", profile.email)
                    infoRow("Phone", profile.phone)
                }

                GLCard(title: "License") {
                    infoRow("License #", profile.licenseNumber)
                }

                GLCard(title: "Address") {
                    Text(addressText.isEmpty ? "—" : addressText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                GLCard(title: "Estimate message") {
                    messageBlock("Subject", custom: profile.estimateMessageSubject, fallback: "Estimate # from your business")
                    Divider()
                    messageBlock("Intro", custom: profile.messageIntro, fallback: EstimateMessage.defaultIntro)
                    Divider()
                    messageBlock("Closing", custom: profile.messageClosing, fallback: EstimateMessage.defaultClosing)
                }

                GLCard(title: "Invoice message") {
                    messageBlock("Subject", custom: profile.invoiceMessageSubject, fallback: "Invoice # from your business")
                    Divider()
                    messageBlock("Intro", custom: profile.invoiceMessageIntro, fallback: InvoiceMessage.defaultIntro)
                    Divider()
                    messageBlock("Closing", custom: profile.invoiceMessageClosing, fallback: InvoiceMessage.defaultClosing)
                }

                GLCard(title: "Receipt message") {
                    messageBlock("Subject", custom: profile.receiptMessageSubject, fallback: "Receipt for invoice # from your business")
                    Divider()
                    messageBlock("Intro", custom: profile.receiptMessageIntro, fallback: "Thank you for your payment. Your receipt is attached.")
                    Divider()
                    messageBlock("Closing", custom: profile.receiptMessageClosing, fallback: PaymentReceiptMessage.defaultClosing)
                }

                GLCard(title: "Change order message") {
                    messageBlock("Subject", custom: profile.changeOrderMessageSubject, fallback: "Change order # from your business")
                    Divider()
                    messageBlock("Intro", custom: profile.changeOrderMessageIntro, fallback: ChangeOrderMessage.defaultIntro)
                    Divider()
                    messageBlock("Closing", custom: profile.changeOrderMessageClosing, fallback: ChangeOrderMessage.defaultClosing)
                }

                GLCard(title: "Contractor package message") {
                    messageBlock("Subject", custom: profile.packageMessageSubject, fallback: "Contractor package from your business")
                    Divider()
                    messageBlock("Intro", custom: profile.packageMessageIntro, fallback: ContractorPackageMessage.defaultIntro)
                    Divider()
                    messageBlock("Closing", custom: profile.packageMessageClosing, fallback: ContractorPackageMessage.defaultClosing)
                }

                GLCard(title: "Completion package message") {
                    messageBlock("Subject", custom: profile.completionMessageSubject, fallback: "Completion package from your business")
                    Divider()
                    messageBlock("Intro", custom: profile.completionMessageIntro, fallback: CompletionPackageMessage.defaultIntro)
                    Divider()
                    messageBlock("Closing", custom: profile.completionMessageClosing, fallback: CompletionPackageMessage.defaultClosing)
                }

                GLCard(title: "Tax details (W-9)") {
                    infoRow("Name", profile.w9Name)
                    infoRow("Classification", classificationText)
                    infoRow("Tax ID", maskedTIN)
                    infoRow("Exempt payee code", profile.w9ExemptPayeeCode)
                    infoRow("FATCA code", profile.w9FATCACode)
                }

                GLCard(title: "Warranty") {
                    if profile.warrantyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text("Not set. Add your warranty terms in Edit details — they’re attached to each completion package.")
                            .font(.subheadline).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        Text(profile.warrantyText)
                            .font(.subheadline)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text("Coverage starts from each job’s completion date.")
                            .font(.caption).foregroundStyle(.secondary)
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
                    Button { showingEdit = true } label: { Label("Edit details", systemImage: "pencil") }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .accessibilityLabel("More")
            }
        }
        .navigationDestination(isPresented: $showingEdit) {
            MyCompanyFormScreen(profile: profile)
        }
    }

    // MARK: - Rows

    private func infoRow(_ label: LocalizedStringKey, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value.isEmpty ? "—" : value).multilineTextAlignment(.trailing)
        }
    }

    private func messageBlock(_ label: LocalizedStringKey, custom: String, fallback: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(label).font(.caption).foregroundStyle(.secondary)
                Spacer()
                if custom.isEmpty {
                    Text("Default").font(.caption2).foregroundStyle(.secondary)
                }
            }
            Text(custom.isEmpty ? fallback : custom)
                .font(.subheadline)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Derived values

    private var addressText: String {
        let a = profile.address
        let cityLine = [a.city, a.state].filter { !$0.isEmpty }.joined(separator: ", ")
        let cityZip = [cityLine, a.postalCode].filter { !$0.isEmpty }.joined(separator: " ")
        return [a.street1, a.street2 ?? "", cityZip]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    private var classificationText: String {
        guard let classification = profile.w9TaxClassification else { return "—" }
        switch classification {
        case .llc:
            return profile.w9LLCClassification.isEmpty
                ? classification.label
                : "\(classification.label) (\(profile.w9LLCClassification))"
        case .other:
            return profile.w9OtherClassification.isEmpty
                ? classification.label
                : "\(classification.label): \(profile.w9OtherClassification)"
        default:
            return classification.label
        }
    }

    /// Masks the taxpayer ID to its last four digits — it's an SSN/EIN, so it isn't shown in full
    /// on this read-only screen.
    private var maskedTIN: String {
        let digits = profile.secureTIN.filter(\.isNumber)
        guard let type = profile.w9TINType, !digits.isEmpty else { return "—" }
        let last4 = String(digits.suffix(4))
        return "\(type.label) ••• \(last4)"
    }
}
