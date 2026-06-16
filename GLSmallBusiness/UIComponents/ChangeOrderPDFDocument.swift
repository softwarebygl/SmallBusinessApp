//
//  ChangeOrderPDFDocument.swift
//  GLSmallBusiness
//
//  The print/PDF layout for a change order: what's changing, the price delta, the revised total,
//  and a signature line for the customer to approve.
//

import SwiftUI

struct ChangeOrderPDFDocument: View {
    let changeOrder: ChangeOrder
    let business: BusinessProfile?

    static let pageWidth: CGFloat = 612

    private var gold: Color { GLColor.gold.render(in: .light) }
    private var invoice: Invoice? { changeOrder.invoice }
    private var originalTotal: Double { invoice?.total ?? 0 }
    private var revisedTotal: Double { originalTotal + changeOrder.total }

    private func money(_ value: Double) -> String { value.formatted(.currency(code: "USD")) }
    /// Signed amount with an explicit + for additions.
    private func signed(_ value: Double) -> String {
        (value >= 0 ? "+" : "") + money(value)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            header
            parties
            if !changeOrder.title.isEmpty {
                Text(changeOrder.title).font(.headline).foregroundStyle(gold)
            }
            lineItems
            Rectangle().fill(gold.opacity(0.5)).frame(height: 1)
            totals
            if !changeOrder.note.isEmpty { notes }
            Spacer(minLength: 12)
            approval
        }
        .padding(40)
        .frame(width: Self.pageWidth, alignment: .topLeading)
        .background(Color.white)
        .environment(\.colorScheme, .light)
        .foregroundStyle(.black)
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                if let data = business?.logoData, let uiImage = UIImage(data: data) {
                    Image(uiImage: uiImage).resizable().scaledToFit()
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
                Text("CHANGE ORDER").font(.title.bold()).foregroundStyle(gold)
                if !changeOrder.number.isEmpty { Text(changeOrder.number).font(.headline) }
                Text("Date: \(changeOrder.createdAt.formatted(date: .abbreviated, time: .omitted))")
                    .font(.caption).foregroundStyle(.secondary)
                if let number = invoice?.number, !number.isEmpty {
                    Text("For Invoice \(number)").font(.caption).foregroundStyle(.secondary)
                }
                Text(changeOrder.status.label.uppercased())
                    .font(.caption.weight(.semibold)).foregroundStyle(gold)
            }
        }
    }

    private var parties: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text("FOR").font(.caption2.weight(.bold)).foregroundStyle(gold)
                Text(invoice?.customerDisplayName ?? "—").font(.subheadline.bold())
                if let biz = invoice?.customerBusinessName, !biz.isEmpty { Text(biz).font(.caption) }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text("PROJECT").font(.caption2.weight(.bold)).foregroundStyle(gold)
                Text((invoice?.jobTitle.isEmpty ?? true) ? "—" : invoice!.jobTitle)
                    .font(.subheadline.bold()).multilineTextAlignment(.trailing)
            }
        }
    }

    private var lineItems: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Scope changes").font(.caption.weight(.bold)).foregroundStyle(gold)
            if changeOrder.sortedLineItems.isEmpty {
                Text("No line items.").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(changeOrder.sortedLineItems) { item in
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.name).font(.subheadline.weight(.medium))
                        if !item.details.isEmpty {
                            Text(item.details).font(.caption2).foregroundStyle(.secondary)
                        }
                        Text("\(item.quantity.formatted()) \(item.unit.abbreviation) × \(money(item.unitPrice))")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(signed(item.lineTotal)).font(.subheadline)
                }
                Rectangle().fill(Color.black.opacity(0.08)).frame(height: 1)
            }
        }
    }

    private var totals: some View {
        HStack {
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                totalLine("Original invoice total", money(originalTotal))
                if changeOrder.taxAmount != 0 {
                    totalLine("Change subtotal", signed(changeOrder.subtotal))
                    totalLine("Tax", signed(changeOrder.taxAmount))
                }
                totalLine("This change order", signed(changeOrder.total), bold: true, gold: true)
                Rectangle().fill(gold.opacity(0.5)).frame(height: 1).padding(.vertical, 2)
                totalLine("Revised total", money(revisedTotal), bold: true)
            }
            .frame(width: 270)
        }
    }

    private func totalLine(_ label: String, _ value: String, bold: Bool = false, gold useGold: Bool = false) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value).foregroundStyle(useGold ? gold : .black)
        }
        .font(bold ? .subheadline.bold() : .subheadline)
    }

    private var notes: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Notes").font(.caption.weight(.bold)).foregroundStyle(gold)
            Text(changeOrder.note).font(.caption)
        }
    }

    private var approval: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("By signing below, the customer approves this change to the project scope and the revised total above.")
                .font(.caption2).foregroundStyle(.secondary)
            HStack(spacing: 24) {
                signatureLine("Approved by")
                signatureLine("Date")
            }
            .padding(.top, 18)
        }
    }

    private func signatureLine(_ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Rectangle().fill(Color.black.opacity(0.4)).frame(height: 1)
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
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

enum ChangeOrderPDF {
    @MainActor
    static func render(_ changeOrder: ChangeOrder, business: BusinessProfile?) -> URL? {
        let renderer = ImageRenderer(content: ChangeOrderPDFDocument(changeOrder: changeOrder, business: business))
        renderer.proposedSize = ProposedViewSize(width: ChangeOrderPDFDocument.pageWidth, height: nil)

        let safe = changeOrder.number.isEmpty ? "draft" : changeOrder.number
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ChangeOrder-\(safe).pdf")

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

// MARK: - Email / text wording

enum ChangeOrderMessage {
    static func subject(_ co: ChangeOrder, business: BusinessProfile?) -> String {
        let company = trimmed(business?.businessName)
        let base = co.number.isEmpty ? "Change order" : "Change order \(co.number)"
        return company.isEmpty ? base : "\(base) from \(company)"
    }

    static func plainBody(_ co: ChangeOrder, business: BusinessProfile?) -> String {
        let name = trimmed(co.invoice?.customerFirstName).isEmpty ? "there" : trimmed(co.invoice?.customerFirstName)
        let company = trimmed(business?.businessName)
        let original = co.invoice?.total ?? 0
        let signoff = company.isEmpty ? "" : "\n\n— \(company)"
        var lines: [String] = []
        if !co.title.isEmpty { lines.append(co.title) }
        lines.append("This change order: \(signedMoney(co.total))")
        lines.append("Revised total: \(money(original + co.total))")
        return """
        Hi \(name),

        Here's a change order for your approval covering an update to the project scope. Please review the attached document and reply to approve.

        \(lines.joined(separator: "\n"))\(signoff)
        """
    }

    @MainActor
    static func htmlBody(_ co: ChangeOrder, business: BusinessProfile?) -> String {
        let name = esc(trimmed(co.invoice?.customerFirstName).isEmpty ? "there" : trimmed(co.invoice?.customerFirstName))
        let company = trimmed(business?.businessName)
        let original = co.invoice?.total ?? 0

        var logoTag = ""
        if let data = EstimateMessage.logoPNGData(business: business) {
            logoTag = "<img src=\"data:image/png;base64,\(data.base64EncodedString())\" width=\"140\" style=\"display:block;margin:0 0 20px;max-width:140px;height:auto;\" alt=\"\(esc(company))\" />"
        }

        var rows: [(label: String, value: String, strong: Bool)] = []
        if !co.number.isEmpty { rows.append(("Change order", esc(co.number), false)) }
        if !co.title.isEmpty { rows.append(("Summary", esc(co.title), false)) }
        rows.append(("This change", esc(signedMoney(co.total)), true))
        rows.append(("Revised total", esc(money(original + co.total)), true))

        var signature = "<strong style=\"color:#9C7A2E;\">\(esc(company))</strong>"
        if let phone = business?.phone, !phone.isEmpty { signature += "<br>\(esc(phone))" }
        if let email = business?.email, !email.isEmpty { signature += "<br>\(esc(email))" }

        let inner = """
        \(logoTag)
        <p style="margin:0 0 14px;">Hi \(name),</p>
        <p style="margin:0 0 16px;">Here's a change order for your approval covering an update to the project scope. The attached document has the full details and a line to sign.</p>
        \(EmailHTML.summaryBox(rows))
        <p style="margin:0 0 16px;">Reply to this message to approve, or with any questions.</p>
        <p style="margin:20px 0 0;">\(signature)</p>
        """
        return EmailHTML.page(inner)
    }

    private static func money(_ value: Double) -> String { value.formatted(.currency(code: "USD")) }
    private static func signedMoney(_ value: Double) -> String { (value >= 0 ? "+" : "") + money(value) }
    private static func trimmed(_ value: String?) -> String {
        (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private static func esc(_ string: String) -> String {
        string
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
