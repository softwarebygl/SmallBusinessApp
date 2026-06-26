//
//  InvoicePDFDocument.swift
//  GLSmallBusiness
//
//  Created by Gold Life LLC on 5/28/26.
//

import SwiftUI

/// The print/PDF layout for an invoice. Rendered to a PDF by `InvoicePDF.render`.
/// Always laid out light (white page) regardless of device appearance.
struct InvoicePDFDocument: View {
    let invoice: Invoice
    let business: BusinessProfile?

    static let pageWidth: CGFloat = 612 // US Letter at 72 dpi

    private var gold: Color { GLColor.gold.render(in: .light) }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            header
            customerAndProject
            ForEach(invoice.sortedGroups) { group in
                groupBlock(group)
            }
            Rectangle().fill(gold.opacity(0.5)).frame(height: 1)
            totals
            if !invoice.sortedPayments.isEmpty {
                payments
            }
            if !invoice.customerNotes.isEmpty || !invoice.terms.isEmpty {
                notes
            }
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
                if let data = business?.logoData, let uiImage = UIImage(data: data) {
                    Image(uiImage: uiImage)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 90, height: 90)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                if let business, !business.businessName.isEmpty {
                    Text(business.businessName).font(.title2.bold())
                }
                if let business {
                    let address = formattedAddress(business.address)
                    if !address.isEmpty { Text(address).font(.caption).foregroundStyle(.secondary) }
                    if !business.phone.isEmpty { Text(business.phone).font(.caption).foregroundStyle(.secondary) }
                    if !business.email.isEmpty { Text(business.email).font(.caption).foregroundStyle(.secondary) }
                    if !business.licenseNumber.isEmpty {
                        Text("License #\(business.licenseNumber)").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                Text("INVOICE").font(.largeTitle.bold()).foregroundStyle(gold)
                Text(invoice.number).font(.headline)
                Text("Date: \(invoice.createdAt.formatted(date: .abbreviated, time: .omitted))")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Due: \(invoice.dueDate.formatted(date: .abbreviated, time: .omitted))")
                    .font(.caption).foregroundStyle(.secondary)
                if let source = invoice.sourceEstimateNumber, !source.isEmpty {
                    Text("Ref: \(source)").font(.caption).foregroundStyle(.secondary)
                }
                Text(invoice.displayStatus).font(.caption.weight(.semibold)).foregroundStyle(gold)
            }
        }
    }

    // MARK: - Customer + project

    private var customerAndProject: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text("BILL TO").font(.caption2.weight(.bold)).foregroundStyle(gold)
                Text(invoice.customerDisplayName).font(.subheadline.bold())
                if let business = invoice.customerBusinessName, !business.isEmpty {
                    Text(business).font(.caption)
                }
                let address = formattedAddress(invoice.customerAddress)
                if !address.isEmpty { Text(address).font(.caption).foregroundStyle(.secondary) }
                if !invoice.customerEmail.isEmpty { Text(invoice.customerEmail).font(.caption).foregroundStyle(.secondary) }
                if !invoice.customerPhone.isEmpty { Text(invoice.customerPhone).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text("PROJECT").font(.caption2.weight(.bold)).foregroundStyle(gold)
                Text(invoice.jobTitle.isEmpty ? "—" : invoice.jobTitle)
                    .font(.subheadline.bold())
                    .multilineTextAlignment(.trailing)
                if !invoice.serviceAddress.isEmpty {
                    Text("SERVICE ADDRESS")
                        .font(.caption2.weight(.bold)).foregroundStyle(gold)
                        .padding(.top, 4)
                    Text(invoice.serviceAddress.formattedMultiline)
                        .font(.caption).foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                }
                Text("Terms: \(invoice.paymentTerms.label)").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Line item groups

    private func groupBlock(_ group: InvoiceGroup) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if !group.name.isEmpty {
                Text(group.name).font(.headline).foregroundStyle(gold)
            }
            if !group.note.isEmpty {
                Text(group.note).font(.caption).foregroundStyle(.secondary)
            }
            ForEach(group.sortedLineItems) { item in
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.name).font(.subheadline.weight(.medium))
                        if !item.details.isEmpty {
                            Text(item.details).font(.caption2).foregroundStyle(.secondary)
                        }
                        Text("\(item.quantity.formatted()) \(item.unit.abbreviation) × \(item.unitPrice.formatted(.currency(code: "USD")))")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(item.lineTotal.formatted(.currency(code: "USD"))).font(.subheadline)
                }
                Rectangle().fill(Color.black.opacity(0.08)).frame(height: 1)
            }
            if !group.name.isEmpty || invoice.sortedGroups.count > 1 {
                HStack {
                    Spacer()
                    Text("Subtotal  \(group.subtotal.formatted(.currency(code: "USD")))")
                        .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Totals

    private var totals: some View {
        HStack {
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                totalLine("Subtotal", invoice.subtotal)
                if invoice.discountAmount > 0 { totalLine("Discount", -invoice.discountAmount) }
                if invoice.taxAmount > 0 { totalLine("Tax (\(invoice.taxRatePercent.formatted())%)", invoice.taxAmount) }
                totalLine("Total", invoice.total, bold: true)
                if invoice.amountPaid > 0 { totalLine("Paid", -invoice.amountPaid) }
                totalLine("Balance", invoice.balanceDue)
                if invoice.hasAmountDueRequest {
                    Rectangle().fill(gold.opacity(0.5)).frame(height: 1).padding(.vertical, 2)
                    HStack {
                        Text("Amount due now").font(.subheadline.bold())
                        Spacer()
                        Text(invoice.currentAmountDue.formatted(.currency(code: "USD")))
                            .font(.subheadline.bold()).foregroundStyle(gold)
                    }
                    if !invoice.amountDueDetail.isEmpty {
                        Text(invoice.amountDueDetail)
                            .font(.caption2).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }
            }
            .frame(width: 250)
        }
    }

    private func totalLine(_ label: String, _ amount: Double, bold: Bool = false) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(amount.formatted(.currency(code: "USD")))
        }
        .font(bold ? .subheadline.bold() : .subheadline)
    }

    // MARK: - Payments

    private var payments: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Payments").font(.caption.weight(.bold)).foregroundStyle(gold)
            ForEach(invoice.sortedPayments) { payment in
                HStack {
                    Text("\(payment.date.formatted(date: .abbreviated, time: .omitted)) · \(payment.method.label)")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text(payment.amount.formatted(.currency(code: "USD"))).font(.caption)
                }
            }
        }
    }

    // MARK: - Notes

    private var notes: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !invoice.customerNotes.isEmpty {
                Text("Notes").font(.caption.weight(.bold)).foregroundStyle(gold)
                Text(invoice.customerNotes).font(.caption)
            }
            if !invoice.terms.isEmpty {
                Text("Terms").font(.caption.weight(.bold)).foregroundStyle(gold)
                Text(invoice.terms).font(.caption)
            }
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

enum InvoicePDF {
    /// Renders the invoice to a multi-page US-Letter PDF in the temp directory and returns its URL.
    @MainActor
    static func render(_ invoice: Invoice, business: BusinessProfile?) -> URL? {
        let safeNumber = invoice.number.isEmpty ? "draft" : invoice.number
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Invoice-\(safeNumber).pdf")
        return PaginatedPDF.render(InvoicePDFDocument(invoice: invoice, business: business),
                                   width: InvoicePDFDocument.pageWidth, to: url)
    }
}
