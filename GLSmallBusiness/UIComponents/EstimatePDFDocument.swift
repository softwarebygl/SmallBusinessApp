//
//  EstimatePDFDocument.swift
//  GLSmallBusiness
//
//  Created by Gold Life LLC on 5/28/26.
//

import SwiftUI
import GoldLifeUI

/// The print/PDF layout for an estimate. Rendered to a PDF by `EstimatePDF.render`.
/// Always laid out light (white page) regardless of device appearance.
struct EstimatePDFDocument: View {
    let estimate: Estimate
    let business: BusinessProfile?

    static let pageWidth: CGFloat = 612 // US Letter at 72 dpi

    private var gold: Color { GLTheme.paperAccent }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            header
            customerAndProject
            ForEach(estimate.sortedGroups) { group in
                groupBlock(group)
            }
            if estimate.isOptionsMode {
                // An OPTIONS estimate has no grand total — each group priced
                // itself above; say so where the tally used to be.
                Text("Each option is priced on its own — choose the one that works best.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Rectangle().fill(gold.opacity(0.5)).frame(height: 1)
                totals
            }
            if !estimate.customerNotes.isEmpty || !estimate.terms.isEmpty {
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
                Text("ESTIMATE").font(.largeTitle.bold()).foregroundStyle(gold)
                Text(estimate.number).font(.headline)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Date: \(estimate.createdAt.formatted(date: .abbreviated, time: .omitted))")
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Valid until: \(estimate.validUntil.formatted(date: .abbreviated, time: .omitted))")
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                Text(estimate.displayStatus).font(.caption.weight(.semibold)).foregroundStyle(gold)
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
                Text("PREPARED FOR").font(.caption2.weight(.bold)).foregroundStyle(gold)
                Text(estimate.customerDisplayName).font(.subheadline.bold())
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                if let business = estimate.customerBusinessName, !business.isEmpty {
                    Text(business).font(.caption)
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)
                }
                let address = formattedAddress(estimate.customerAddress)
                if !address.isEmpty {
                    Text(address).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !estimate.customerEmail.isEmpty {
                    Text(estimate.customerEmail).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !estimate.customerPhone.isEmpty {
                    Text(estimate.customerPhone).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: 250, alignment: .leading)
            Spacer(minLength: 16)
            VStack(alignment: .trailing, spacing: 2) {
                Text("PROJECT").font(.caption2.weight(.bold)).foregroundStyle(gold)
                Text(estimate.jobTitle.isEmpty ? "—" : estimate.jobTitle)
                    .font(.subheadline.bold())
                    .multilineTextAlignment(.trailing)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                if !estimate.serviceAddress.isEmpty {
                    Text("SERVICE ADDRESS")
                        .font(.caption2.weight(.bold)).foregroundStyle(gold)
                        .padding(.top, 4)
                    Text(estimate.serviceAddress.formattedMultiline)
                        .font(.caption).foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: 250, alignment: .trailing)
        }
    }

    // MARK: - Line item groups

    private func groupBlock(_ group: EstimateGroup) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if !group.name.isEmpty {
                Text(group.name).font(.headline).foregroundStyle(gold)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
            } else if estimate.isOptionsMode {
                // An unnamed option still needs a header — it's a CHOICE the
                // customer must be able to refer to (QA 2026-09-01).
                Text("Option").font(.headline).foregroundStyle(gold)
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
                    Text(item.lineTotal.formatted(.money)).font(.subheadline)
                }
                Rectangle().fill(Color.black.opacity(0.08)).frame(height: 1)
            }
            if estimate.isOptionsMode {
                let option = group.optionTotals(taxRatePercent: estimate.taxRatePercent)
                VStack(alignment: .trailing, spacing: 2) {
                    Text("Subtotal  \(option.subtotal.formatted(.money))")
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)
                    if option.tax > 0 {
                        // Composed as a resolved string: a literal % inside an
                        // interpolated LocalizedStringKey is a format-spec trap
                        // (the catalog key never matches — QA 2026-09-01).
                        Text(verbatim: mbLoc("Tax") + " (\(estimate.taxRatePercent.formatted())%)  " + option.tax.formatted(.money))
                            .font(.caption).foregroundStyle(.secondary)
                            .lineLimit(nil)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text("Option total  \(option.total.formatted(.money))")
                        .font(.caption.weight(.semibold))
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            } else if !group.name.isEmpty || estimate.sortedGroups.count > 1 {
                HStack {
                    Spacer()
                    Text("Subtotal  \(group.subtotal.formatted(.money))")
                        .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: - Totals

    private var totals: some View {
        HStack {
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                totalLine("Subtotal", estimate.subtotal)
                if estimate.discountAmount > 0 { totalLine("Discount", -estimate.discountAmount) }
                if estimate.taxAmount > 0 { totalLine("Tax (\(estimate.taxRatePercent.formatted())%)", estimate.taxAmount) }
                totalLine("Total", estimate.total, bold: true)
                if estimate.depositAmount > 0 { totalLine("Required Deposit", estimate.depositAmount) }
            }
            .frame(width: 250)
        }
    }

    private func totalLine(_ label: String, _ amount: Double, bold: Bool = false) -> some View {
        HStack {
            Text(label)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Text(amount.formatted(.money))
        }
        .font(bold ? .subheadline.bold() : .subheadline)
    }

    // MARK: - Notes

    private var notes: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !estimate.customerNotes.isEmpty {
                Text("Notes").font(.caption.weight(.bold)).foregroundStyle(gold)
                Text(estimate.customerNotes).font(.caption)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !estimate.terms.isEmpty {
                Text("Terms").font(.caption.weight(.bold)).foregroundStyle(gold)
                Text(estimate.terms).font(.caption)
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

enum EstimatePDF {
    /// Renders the estimate to a multi-page US-Letter PDF in the temp directory and returns its URL.
    @MainActor
    static func render(_ estimate: Estimate, business: BusinessProfile?) -> URL? {
        let safeNumber = estimate.number.isEmpty ? "draft" : estimate.number
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Estimate-\(safeNumber).pdf")
        return PaginatedPDF.render(EstimatePDFDocument(estimate: estimate, business: business),
                                   width: EstimatePDFDocument.pageWidth, to: url)
    }
}
