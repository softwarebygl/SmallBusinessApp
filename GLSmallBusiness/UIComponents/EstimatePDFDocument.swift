//
//  EstimatePDFDocument.swift
//  GLSmallBusiness
//
//  Created by Gold Life LLC on 5/28/26.
//

import SwiftUI

/// The print/PDF layout for an estimate. Rendered to a PDF by `EstimatePDF.render`.
/// Always laid out light (white page) regardless of device appearance.
struct EstimatePDFDocument: View {
    let estimate: Estimate
    let business: BusinessProfile?

    static let pageWidth: CGFloat = 612 // US Letter at 72 dpi

    private var gold: Color { GLColor.gold.render(in: .light) }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            header
            customerAndProject
            ForEach(estimate.sortedGroups) { group in
                groupBlock(group)
            }
            Rectangle().fill(gold.opacity(0.5)).frame(height: 1)
            totals
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
                Text("ESTIMATE").font(.largeTitle.bold()).foregroundStyle(gold)
                Text(estimate.number).font(.headline)
                Text("Date: \(estimate.createdAt.formatted(date: .abbreviated, time: .omitted))")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Valid until: \(estimate.validUntil.formatted(date: .abbreviated, time: .omitted))")
                    .font(.caption).foregroundStyle(.secondary)
                Text(estimate.displayStatus).font(.caption.weight(.semibold)).foregroundStyle(gold)
            }
        }
    }

    // MARK: - Customer + project

    private var customerAndProject: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text("PREPARED FOR").font(.caption2.weight(.bold)).foregroundStyle(gold)
                Text(estimate.customerDisplayName).font(.subheadline.bold())
                if let business = estimate.customerBusinessName, !business.isEmpty {
                    Text(business).font(.caption)
                }
                let address = formattedAddress(estimate.customerAddress)
                if !address.isEmpty { Text(address).font(.caption).foregroundStyle(.secondary) }
                if !estimate.customerEmail.isEmpty { Text(estimate.customerEmail).font(.caption).foregroundStyle(.secondary) }
                if !estimate.customerPhone.isEmpty { Text(estimate.customerPhone).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text("PROJECT").font(.caption2.weight(.bold)).foregroundStyle(gold)
                Text(estimate.jobTitle.isEmpty ? "—" : estimate.jobTitle)
                    .font(.subheadline.bold())
                    .multilineTextAlignment(.trailing)
            }
        }
    }

    // MARK: - Line item groups

    private func groupBlock(_ group: EstimateGroup) -> some View {
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
            if !group.name.isEmpty || estimate.sortedGroups.count > 1 {
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
                totalLine("Subtotal", estimate.subtotal)
                if estimate.discountAmount > 0 { totalLine("Discount", -estimate.discountAmount) }
                if estimate.taxAmount > 0 { totalLine("Tax (\(estimate.taxRatePercent.formatted())%)", estimate.taxAmount) }
                totalLine("Total", estimate.total, bold: true)
                if estimate.depositAmount > 0 { totalLine("Deposit due", estimate.depositAmount) }
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

    // MARK: - Notes

    private var notes: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !estimate.customerNotes.isEmpty {
                Text("Notes").font(.caption.weight(.bold)).foregroundStyle(gold)
                Text(estimate.customerNotes).font(.caption)
            }
            if !estimate.terms.isEmpty {
                Text("Terms").font(.caption.weight(.bold)).foregroundStyle(gold)
                Text(estimate.terms).font(.caption)
            }
        }
    }

    private func formattedAddress(_ a: Address) -> String {
        let cityLine = [a.city, a.state].filter { !$0.isEmpty }.joined(separator: ", ")
        let cityZip = [cityLine, a.postalCode].filter { !$0.isEmpty }.joined(separator: " ")
        return [a.street1, a.street2 ?? "", cityZip, a.country]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }
}

// MARK: - PDF rendering

enum EstimatePDF {
    /// Renders the estimate to a single-page PDF in the temp directory and returns its URL.
    @MainActor
    static func render(_ estimate: Estimate, business: BusinessProfile?) -> URL? {
        let renderer = ImageRenderer(content: EstimatePDFDocument(estimate: estimate, business: business))
        renderer.proposedSize = ProposedViewSize(width: EstimatePDFDocument.pageWidth, height: nil)

        let safeNumber = estimate.number.isEmpty ? "draft" : estimate.number
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Estimate-\(safeNumber).pdf")

        var didRender = false
        renderer.render { size, context in
            var box = CGRect(origin: .zero, size: size)
            guard let pdf = CGContext(url as CFURL, mediaBox: &box, nil) else { return }
            pdf.beginPDFPage(nil)
            context(pdf)
            pdf.endPDFPage()
            pdf.closePDF()
            didRender = true
        }
        return didRender ? url : nil
    }
}
