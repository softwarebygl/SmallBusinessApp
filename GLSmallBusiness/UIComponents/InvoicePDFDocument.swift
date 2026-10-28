//
//  InvoicePDFDocument.swift
//  GLSmallBusiness
//
//  Created by Gold Life LLC on 5/28/26.
//

import SwiftUI
import GoldLifeUI

/// The print/PDF layout for an invoice. Rendered to a PDF by `InvoicePDF.render`.
/// Always laid out light (white page) regardless of device appearance.
struct InvoicePDFDocument: View {
    let invoice: Invoice
    let business: BusinessProfile?

    static let pageWidth: CGFloat = 612 // US Letter at 72 dpi

    private var gold: Color { GLTheme.paperAccent }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            header
            customerAndProject
            ForEach(invoice.sortedGroups) { group in
                groupBlock(group)
            }
            Rectangle().fill(gold.opacity(0.5)).frame(height: 1)
            totals
            if invoice.includeZelle, let business, business.zelleIsConfigured {
                zelleSection(business)
            }
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
                Text("INVOICE").font(.largeTitle.bold()).foregroundStyle(gold)
                Text(invoice.number).font(.headline)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Date: \(invoice.createdAt.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted).locale(MBLocalization.currentLocale)))")
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Due: \(invoice.dueDate.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted).locale(MBLocalization.currentLocale)))")
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                if let source = invoice.sourceEstimateNumber, !source.isEmpty {
                    Text("Ref: \(source)").font(.caption).foregroundStyle(.secondary)
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(invoice.displayStatus).font(.caption.weight(.semibold)).foregroundStyle(gold)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: 220, alignment: .trailing)
        }
    }

    // MARK: - Customer + project

    private var customerAndProject: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text("BILL TO").font(.caption2.weight(.bold)).foregroundStyle(gold)
                Text(invoice.customerDisplayName).font(.subheadline.bold())
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                if let business = invoice.customerBusinessName, !business.isEmpty {
                    Text(business).font(.caption)
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)
                }
                let address = formattedAddress(invoice.customerAddress)
                if !address.isEmpty {
                    Text(address).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !invoice.customerEmail.isEmpty {
                    Text(invoice.customerEmail).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !invoice.customerPhone.isEmpty {
                    Text(invoice.customerPhone).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: 250, alignment: .leading)
            Spacer(minLength: 16)
            VStack(alignment: .trailing, spacing: 2) {
                Text("PROJECT").font(.caption2.weight(.bold)).foregroundStyle(gold)
                Text(invoice.jobTitle.isEmpty ? "—" : invoice.jobTitle)
                    .font(.subheadline.bold())
                    .multilineTextAlignment(.trailing)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                if !invoice.serviceAddress.isEmpty {
                    Text("SERVICE ADDRESS")
                        .font(.caption2.weight(.bold)).foregroundStyle(gold)
                        .padding(.top, 4)
                    Text(invoice.serviceAddress.formattedMultiline)
                        .font(.caption).foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("Terms: \(invoice.paymentTerms.label)").font(.caption).foregroundStyle(.secondary)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: 250, alignment: .trailing)
        }
    }

    // MARK: - Line item groups

    private func groupBlock(_ group: InvoiceGroup) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if !group.name.isEmpty {
                Text(group.name).font(.headline).foregroundStyle(gold)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !group.note.isEmpty {
                Text(group.note).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(group.sortedLineItems) { item in
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.name).font(.subheadline.weight(.medium))
                            .lineLimit(nil)
                            .fixedSize(horizontal: false, vertical: true)
                        if !item.details.isEmpty {
                            Text(item.details).font(.caption2).foregroundStyle(.secondary)
                                // Explicit "wrap, never truncate": on the owner's
                                // iPhone (iOS 26.6) long details rendered as ONE
                                // line ending in an ellipsis inside this
                                // HStack+Spacer row, while iOS 26.5 wraps the same
                                // code fine — an OS-side ImageRenderer difference.
                                // fixedSize(vertical: true) is the canonical guard
                                // and a no-op where wrapping already works.
                                .lineLimit(nil)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Text("\(item.quantity.formatted()) \(item.unit.abbreviation) × \(item.unitPrice.formatted(.money))")
                            .font(.caption2).foregroundStyle(.secondary)
                            .lineLimit(nil)
                            .fixedSize(horizontal: false, vertical: true)
                        if item.lineDiscount > 0 {
                            Text("Discount −\(item.lineDiscount.formatted(.money))")
                                .font(.caption2).foregroundStyle(.secondary)
                                .lineLimit(nil)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer()
                    Text(displayLineTotal(item).formatted(.money)).font(.subheadline)
                }
                Rectangle().fill(Color.black.opacity(0.08)).frame(height: 1)
            }
            if !group.name.isEmpty || invoice.sortedGroups.count > 1 {
                HStack {
                    Spacer()
                    Text("Subtotal  \(groupSubtotal(group).formatted(.money))")
                        .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// Change-order lines keep their sign so a credit prints negative — matching `Invoice.totals`,
    /// which bills them via `signedLineTotal`. Original work stays floored at 0 (an over-discounted
    /// line can't go negative). Without this, a credit would print $0.00 and the visible lines
    /// wouldn't reconcile with the printed Total.
    private func displayLineTotal(_ item: InvoiceLineItem) -> Double {
        DomainMoney.roundedToCents(item.exactShownTotal)
    }

    /// Group subtotal using the same signed math as the printed lines (`InvoiceGroup.shownSubtotal`).
    private func groupSubtotal(_ group: InvoiceGroup) -> Double { group.shownSubtotal }

    // MARK: - Totals

    private var totals: some View {
        HStack {
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                totalLine("Subtotal", invoice.subtotal)
                if invoice.discountAmount > 0 { totalLine("Discount", -invoice.discountAmount) }
                if invoice.taxAmount > 0 {
                    // Plain "Tax" when a change order bills at the rate it was signed at (QA F82).
                    if let rate = invoice.shownTaxRatePercent {
                        totalLine("Tax (\(rate.formatted())%)", invoice.taxAmount)
                    } else {
                        totalLine("Tax", invoice.taxAmount)
                    }
                }
                totalLine("Total", invoice.total, bold: true)
                if invoice.amountPaid > 0 { totalLine("Paid", -invoice.amountPaid) }
                // Paid more than the total (QA F85): what is owed back, so Paid − Credit due == Total.
                if invoice.creditDue > 0 { totalLine("Credit due", invoice.creditDue) }
                totalLine("Balance", invoice.balanceDue)
                if invoice.hasAmountDueRequest {
                    Rectangle().fill(gold.opacity(0.5)).frame(height: 1).padding(.vertical, 2)
                    HStack {
                        Text("Amount due now").font(.subheadline.bold())
                            .lineLimit(nil)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        Text(invoice.currentAmountDue.formatted(.money))
                            .font(.subheadline.bold()).foregroundStyle(gold)
                    }
                    if !invoice.amountDueDetail.isEmpty {
                        Text(invoice.amountDueDetail)
                            .font(.caption2).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                            .lineLimit(nil)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .frame(width: 250)
        }
    }

    /// `LocalizedStringKey`, never `String`: `Text(String)` draws the words as-is, so a Spanish
    /// invoice printed "Discount / Tax / Paid / Balance" in English (F21).
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

    // MARK: - Zelle

    private func zelleSection(_ business: BusinessProfile) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Pay with Zelle").font(.caption.weight(.bold)).foregroundStyle(gold)
            HStack(alignment: .top, spacing: 14) {
                if let data = business.zelleQRCodeData, let uiImage = UIImage(data: data) {
                    Image(uiImage: uiImage)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 80, height: 80)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                VStack(alignment: .leading, spacing: 4) {
                    if !business.zelleTag.isEmpty {
                        Text(verbatim: business.zelleTag)
                            .font(.caption.weight(.medium))
                    }
                    if !business.zelleEmail.isEmpty {
                        Text(verbatim: business.zelleEmail)
                            .font(.caption)
                    }
                    if !business.zellePhone.isEmpty {
                        Text(verbatim: business.zellePhone)
                            .font(.caption)
                    }
                }
                .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Payments

    private var payments: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Payments").font(.caption.weight(.bold)).foregroundStyle(gold)
            ForEach(invoice.sortedPayments) { payment in
                HStack {
                    Text("\(payment.date.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted).locale(MBLocalization.currentLocale))) · \(payment.method.label)")
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Text(payment.amount.formatted(.money)).font(.caption)
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
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !invoice.terms.isEmpty {
                Text("Terms").font(.caption.weight(.bold)).foregroundStyle(gold)
                Text(invoice.terms).font(.caption)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
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
