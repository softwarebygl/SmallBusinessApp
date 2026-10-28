//
//  ContractPDFDocument.swift
//  GLSmallBusiness
//
//  The print/PDF layout for a contract, including original scope of work,
//  approved change orders, financial summary, terms, and client signature.
//  Rendered to a multi-page US Letter PDF by ContractPDF.render.
//

import SwiftUI
import GoldLifeUI

struct ContractPDFDocument: View {
    let contract: Contract
    let business: BusinessProfile?

    static let pageWidth: CGFloat = 612 // US Letter at 72 dpi

    private var gold: Color { GLTheme.paperAccent }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            header
            customerAndProject
            scopeOfWork
            if !contract.approvedChangeOrders.isEmpty {
                changeOrdersBlock
            }
            Rectangle().fill(gold.opacity(0.5)).frame(height: 1)
            totals
            if !contract.notes.isEmpty || !contract.terms.isEmpty {
                notesAndTerms
            }
            signaturesBlock
        }
        .padding(40)
        .frame(width: Self.pageWidth, alignment: .topLeading)
        .background(Color.white)
        .environment(\.colorScheme, .light)
        .foregroundStyle(.black)
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                if let data = business?.documentLogoData, let uiImage = UIImage(data: data) {
                    Image(uiImage: uiImage)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 90, height: 90)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                if let business, !business.businessName.isEmpty {
                    Text(business.businessName).font(.title2.bold())
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let business {
                    let address = formattedAddress(business.documentAddress)
                    if !address.isEmpty {
                        Text(address).font(.caption).foregroundStyle(.secondary)
                            .lineLimit(nil)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if !business.phone.isEmpty {
                        Text(business.phone).font(.caption).foregroundStyle(.secondary)
                            .lineLimit(nil)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if !business.email.isEmpty {
                        Text(business.email).font(.caption).foregroundStyle(.secondary)
                            .lineLimit(nil)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if !business.licenseNumber.isEmpty {
                        Text("License #\(business.licenseNumber)").font(.caption).foregroundStyle(.secondary)
                            .lineLimit(nil)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .frame(maxWidth: 300, alignment: .leading)
            Spacer(minLength: 16)
            VStack(alignment: .trailing, spacing: 4) {
                Text("CONTRACT").font(.largeTitle.bold()).foregroundStyle(gold)
                Text(verbatim: contract.number).font(.headline)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Date: \(contract.createdAt.formatted(date: .abbreviated, time: .omitted))")
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Start Date: \(contract.startDate.formatted(date: .abbreviated, time: .omitted))")
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                Text(verbatim: contract.status.label.uppercased())
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(contract.status == .completed || contract.status == .signed ? GLTheme.statusGood : gold)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: 220, alignment: .trailing)
        }
    }

    // MARK: - Customer + Project

    private var customerAndProject: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text("PREPARED FOR").font(.caption2.weight(.bold)).foregroundStyle(gold)
                Text(contract.displayCustomerName).font(.subheadline.bold())
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                if !contract.recipientEmail.isEmpty {
                    Text(contract.recipientEmail).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !contract.recipientPhone.isEmpty {
                    Text(contract.recipientPhone).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: 250, alignment: .leading)
            Spacer(minLength: 16)
            VStack(alignment: .trailing, spacing: 2) {
                Text("PROJECT").font(.caption2.weight(.bold)).foregroundStyle(gold)
                Text(contract.displayTitle)
                    .font(.subheadline.bold())
                    .multilineTextAlignment(.trailing)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                let addr = contract.serviceAddress
                if !addr.isEmpty {
                    Text("SERVICE ADDRESS")
                        .font(.caption2.weight(.bold)).foregroundStyle(gold)
                        .padding(.top, 4)
                    Text(addr.formattedMultiline)
                        .font(.caption).foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: 250, alignment: .trailing)
        }
    }

    // MARK: - Scope of Work

    private var scopeOfWork: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("SCOPE OF WORK").font(.caption.weight(.bold)).foregroundStyle(gold)
            if contract.sortedGroups.isEmpty {
                if let price = contract.agreedPrice {
                    HStack {
                        Text(contract.displayTitle).font(.subheadline)
                        Spacer()
                        Text(price.formatted(.money)).font(.subheadline.weight(.semibold))
                    }
                }
            } else {
                ForEach(contract.sortedGroups) { group in
                    groupBlock(group)
                }
            }
        }
    }

    private func groupBlock(_ group: ContractGroup) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if !group.name.isEmpty {
                Text(group.name).font(.subheadline.weight(.semibold)).foregroundStyle(gold)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(group.sortedLineItems) { item in
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(verbatim: item.name).font(.caption.weight(.medium))
                            .lineLimit(nil)
                            .fixedSize(horizontal: false, vertical: true)
                        if !item.details.isEmpty {
                            Text(verbatim: item.details).font(.caption2).foregroundStyle(.secondary)
                                .lineLimit(nil)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: 16)
                    Text(verbatim: "\(item.quantity.formatted()) \(item.unit.abbreviation)")
                        .font(.caption2).foregroundStyle(.secondary)
                        .frame(width: 80, alignment: .trailing)
                    Text(verbatim: item.unitPrice.formatted(.money))
                        .font(.caption2).foregroundStyle(.secondary)
                        .frame(width: 70, alignment: .trailing)
                    Text(verbatim: item.total.formatted(.money))
                        .font(.caption.weight(.medium))
                        .frame(width: 80, alignment: .trailing)
                }
                .padding(.vertical, 2)
            }
        }
    }

    // MARK: - Approved Change Orders

    private var changeOrdersBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("APPROVED CHANGE ORDERS").font(.caption.weight(.bold)).foregroundStyle(gold)
            ForEach(contract.approvedChangeOrders) { co in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(verbatim: co.title.isEmpty ? co.number : "\(co.number) · \(co.title)")
                            .font(.caption.weight(.semibold))
                        Spacer()
                        Text(verbatim: (co.total >= 0 ? "+" : "") + co.total.formatted(.money))
                            .font(.caption.weight(.bold))
                            .foregroundStyle(co.total >= 0 ? Color.black : GLTheme.statusCritical)
                    }
                    ForEach(co.sortedLineItems) { item in
                        HStack(alignment: .top) {
                            Text(verbatim: "• \(item.name)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(nil)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer()
                            Text(verbatim: "\(item.quantity.formatted()) \(item.unit.abbreviation)")
                                .font(.caption2).foregroundStyle(.secondary)
                            Text(verbatim: item.unitPrice.formatted(.money))
                                .font(.caption2).foregroundStyle(.secondary)
                            let prefix = item.unitPrice >= 0 ? "+" : ""
                            Text(verbatim: "\(prefix)\(item.lineTotal.formatted(.money))")
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(item.unitPrice >= 0 ? Color.black : GLTheme.statusCritical)
                        }
                    }
                }
                .padding(8)
                .background(Color(white: 0.96))
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
        }
    }

    // MARK: - Financial Summary / Totals

    private var totals: some View {
        HStack {
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                let base = contract.agreedPrice ?? contract.allLineItems.reduce(0.0) { $0 + $1.total }
                if !contract.approvedChangeOrders.isEmpty {
                    totalLine("Original Contract", base)
                    let coSum = contract.approvedChangeOrders.reduce(0.0) { $0 + $1.total }
                    totalLine("Change Orders (\(contract.approvedChangeOrders.count))", coSum)
                }
                totalLine("Total Contract Value", contract.contractedValue, bold: true)
                if contract.invoicedTotal > 0 {
                    totalLine("Invoiced to Date", contract.invoicedTotal)
                    totalLine("Remaining to Invoice", contract.remainingToInvoice, bold: true)
                }
            }
            .frame(width: 280)
        }
    }

    private func totalLine(_ label: LocalizedStringKey, _ amount: Double, bold: Bool = false) -> some View {
        HStack {
            Text(label)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Text(amount.formatted(.money))
        }
        .font(bold ? .subheadline.bold() : .subheadline)
    }

    // MARK: - Notes and Terms

    private var notesAndTerms: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !contract.notes.isEmpty {
                Text("Notes").font(.caption.weight(.bold)).foregroundStyle(gold)
                Text(contract.notes).font(.caption)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !contract.terms.isEmpty {
                Text("Terms & Conditions").font(.caption.weight(.bold)).foregroundStyle(gold)
                Text(contract.terms).font(.caption)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Signatures Block

    private var signaturesBlock: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("AUTHORIZATION & SIGNATURES").font(.caption.weight(.bold)).foregroundStyle(gold)
            HStack(alignment: .top, spacing: 30) {
                // Client Signature
                VStack(alignment: .leading, spacing: 6) {
                    Text("Client Authorization").font(.caption.weight(.semibold))
                    if let sigData = contract.signatureData, let uiImage = UIImage(data: sigData) {
                        Image(uiImage: uiImage)
                            .resizable()
                            .scaledToFit()
                            .frame(height: 50)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(4)
                            .background(Color(white: 0.97))
                            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                        if !contract.signerName.isEmpty {
                            Text("Signer: \(contract.signerName)").font(.caption2.weight(.medium))
                        }
                        if let signedAt = contract.signedAt {
                            Text("Date: \(signedAt.formatted(date: .abbreviated, time: .shortened))").font(.caption2).foregroundStyle(.secondary)
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Client Signature: _______________________").font(.caption)
                            Text("Date: _________________________________").font(.caption)
                            Text("Print Name: \(contract.displayCustomerName)").font(.caption2).foregroundStyle(.secondary)
                        }
                        .padding(.top, 10)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                // Provider Signature
                VStack(alignment: .leading, spacing: 6) {
                    Text("Authorized Representative").font(.caption.weight(.semibold))
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Signature: ___________________________").font(.caption)
                        Text("Date: _________________________________").font(.caption)
                        let company = business?.businessName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? (business?.businessName ?? "Contractor") : "Contractor"
                        Text("Company: \(company)").font(.caption2).foregroundStyle(.secondary)
                    }
                    .padding(.top, 10)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(12)
            .background(Color(white: 0.98))
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
    }

    private func formattedAddress(_ a: Address) -> String {
        let cityLine = [a.city, a.state].filter { !$0.isEmpty }.joined(separator: ", ")
        let cityZip = [cityLine, a.postalCode].filter { !$0.isEmpty }.joined(separator: " ")
        return [a.street1, a.street2 ?? "", cityZip]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }
}

// MARK: - PDF rendering

enum ContractPDF {
    /// Renders the contract to a multi-page US-Letter PDF in the temp directory and returns its URL.
    @MainActor
    static func render(_ contract: Contract, business: BusinessProfile?) -> URL? {
        let safeNumber = contract.number.isEmpty ? "draft" : contract.number
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Contract-\(safeNumber).pdf")
        return PaginatedPDF.render(ContractPDFDocument(contract: contract, business: business),
                                   width: ContractPDFDocument.pageWidth, to: url)
    }
}
