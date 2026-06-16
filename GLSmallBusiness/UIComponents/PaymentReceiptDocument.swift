//
//  PaymentReceiptDocument.swift
//  GLSmallBusiness
//
//  A *payment receipt* — confirms money received for an invoice. Unlike resending the invoice, it
//  reads as an acknowledgement (it leads with "Payment received"), and shows what's left as an
//  informational "remaining balance", never as an amount due now.
//

import SwiftUI

struct PaymentReceiptPDFDocument: View {
    let invoice: Invoice
    let payment: InvoicePayment
    let business: BusinessProfile?

    static let pageWidth: CGFloat = 612 // US Letter at 72 dpi

    private var gold: Color { GLColor.gold.render(in: .light) }
    private var green: Color { Color(red: 0.18, green: 0.49, blue: 0.20) }

    private var paidToDate: Double { invoice.paidThrough(payment) }
    private var remaining: Double { invoice.remainingAfter(payment) }
    private var paidInFull: Bool { remaining < 0.005 }

    private func money(_ value: Double) -> String { value.formatted(.currency(code: "USD")) }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            header
            parties
            receivedBlock
            summary
            Spacer(minLength: 0)
            Text(paidInFull
                 ? "Thank you — this invoice is now paid in full. We appreciate your business."
                 : "Thank you for your payment. This receipt confirms the amount received above.")
                .font(.footnote)
                .foregroundStyle(.secondary)
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
                    Image(uiImage: uiImage)
                        .resizable().scaledToFit()
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
                Text("RECEIPT").font(.largeTitle.bold()).foregroundStyle(gold)
                if !invoice.number.isEmpty {
                    Text("For Invoice \(invoice.number)").font(.headline)
                }
                Text("Date: \(payment.date.formatted(date: .abbreviated, time: .omitted))")
                    .font(.caption).foregroundStyle(.secondary)
                Text(paidInFull ? "PAID IN FULL" : "PAYMENT RECEIVED")
                    .font(.caption.weight(.bold)).foregroundStyle(green)
            }
        }
    }

    private var parties: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text("RECEIVED FROM").font(.caption2.weight(.bold)).foregroundStyle(gold)
                Text(invoice.customerDisplayName).font(.subheadline.bold())
                if let biz = invoice.customerBusinessName, !biz.isEmpty {
                    Text(biz).font(.caption)
                }
                if !invoice.customerEmail.isEmpty { Text(invoice.customerEmail).font(.caption).foregroundStyle(.secondary) }
                if !invoice.customerPhone.isEmpty { Text(invoice.customerPhone).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text("FOR").font(.caption2.weight(.bold)).foregroundStyle(gold)
                Text(invoice.jobTitle.isEmpty ? "—" : invoice.jobTitle)
                    .font(.subheadline.bold()).multilineTextAlignment(.trailing)
                if !invoice.number.isEmpty {
                    Text("Invoice \(invoice.number)").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var receivedBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("PAYMENT RECEIVED").font(.caption2.weight(.bold)).foregroundStyle(green)
            HStack(alignment: .firstTextBaseline) {
                Text(money(payment.amount)).font(.system(size: 34, weight: .bold)).foregroundStyle(green)
                Spacer()
                Text("\(payment.date.formatted(date: .abbreviated, time: .omitted)) · \(payment.method.label)")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            if !payment.note.isEmpty {
                Text(payment.note).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(green.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(green.opacity(0.35)))
    }

    private var summary: some View {
        HStack {
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                summaryLine("Invoice total", money(invoice.total))
                summaryLine("Paid to date", money(paidToDate))
                Rectangle().fill(gold.opacity(0.4)).frame(height: 1).padding(.vertical, 2)
                HStack {
                    Text("Remaining balance").font(.subheadline.bold())
                    Spacer()
                    Text(paidInFull ? "PAID IN FULL" : money(remaining))
                        .font(.subheadline.bold())
                        .foregroundStyle(paidInFull ? green : .black)
                }
            }
            .frame(width: 260)
        }
    }

    private func summaryLine(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value)
        }
        .font(.subheadline)
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

enum PaymentReceiptPDF {
    @MainActor
    static func render(_ invoice: Invoice, payment: InvoicePayment, business: BusinessProfile?) -> URL? {
        let renderer = ImageRenderer(content: PaymentReceiptPDFDocument(invoice: invoice, payment: payment, business: business))
        renderer.proposedSize = ProposedViewSize(width: PaymentReceiptPDFDocument.pageWidth, height: nil)

        let safeNumber = invoice.number.isEmpty ? "invoice" : invoice.number
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Receipt-\(safeNumber).pdf")

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

enum PaymentReceiptMessage {
    static func subject(invoice: Invoice, business: BusinessProfile?) -> String {
        let company = trimmed(business?.businessName)
        let number = trimmed(invoice.number)
        let base = number.isEmpty ? "Payment receipt" : "Receipt for invoice \(number)"
        return company.isEmpty ? base : "\(base) from \(company)"
    }

    static func plainBody(invoice: Invoice, payment: InvoicePayment, business: BusinessProfile?) -> String {
        let name = trimmed(invoice.customerFirstName).isEmpty ? "there" : trimmed(invoice.customerFirstName)
        let company = trimmed(business?.businessName)
        let remaining = invoice.remainingAfter(payment)
        let paidInFull = remaining < 0.005
        let signoff = company.isEmpty ? "" : "\n\n— \(company)"

        var lines: [String] = []
        lines.append("Payment received: \(money(payment.amount)) (\(payment.method.label), \(payment.date.formatted(date: .abbreviated, time: .omitted)))")
        if !invoice.number.isEmpty { lines.append("Invoice: \(invoice.number)") }
        lines.append("Invoice total: \(money(invoice.total))")
        lines.append("Paid to date: \(money(invoice.paidThrough(payment)))")
        lines.append(paidInFull ? "Remaining balance: Paid in full" : "Remaining balance: \(money(remaining))")

        let thanks = paidInFull
            ? "Thank you — this invoice is now paid in full."
            : "Thank you for your payment. Your receipt is attached."
        return """
        Hi \(name),

        \(thanks)

        \(lines.joined(separator: "\n"))\(signoff)
        """
    }

    @MainActor
    static func htmlBody(invoice: Invoice, payment: InvoicePayment, business: BusinessProfile?) -> String {
        let name = esc(trimmed(invoice.customerFirstName).isEmpty ? "there" : trimmed(invoice.customerFirstName))
        let company = trimmed(business?.businessName)
        let remaining = invoice.remainingAfter(payment)
        let paidInFull = remaining < 0.005

        var logoTag = ""
        if let data = EstimateMessage.logoPNGData(business: business) {
            logoTag = "<img src=\"data:image/png;base64,\(data.base64EncodedString())\" width=\"140\" style=\"display:block;margin:0 0 20px;max-width:140px;height:auto;\" alt=\"\(esc(company))\" />"
        }

        var rows: [(label: String, value: String, strong: Bool)] = []
        rows.append(("Payment received", esc(money(payment.amount)), true))
        rows.append(("Method", "\(esc(payment.method.label)) · \(esc(payment.date.formatted(date: .abbreviated, time: .omitted)))", false))
        if !invoice.number.isEmpty { rows.append(("Invoice", esc(invoice.number), false)) }
        rows.append(("Invoice total", esc(money(invoice.total)), false))
        rows.append(("Paid to date", esc(money(invoice.paidThrough(payment))), false))
        rows.append(("Remaining balance", paidInFull ? "Paid in full" : esc(money(remaining)), true))

        var signature = "<strong style=\"color:#9C7A2E;\">\(esc(company))</strong>"
        if let phone = business?.phone, !phone.isEmpty { signature += "<br>\(esc(phone))" }
        if let email = business?.email, !email.isEmpty { signature += "<br>\(esc(email))" }

        let thanks = paidInFull
            ? "Thank you — this invoice is now <strong>paid in full</strong>. We appreciate your business."
            : "Thank you for your payment. This confirms the amount we received; your receipt is attached."

        let inner = """
        \(logoTag)
        <p style="margin:0 0 14px;">Hi \(name),</p>
        <p style="margin:0 0 16px;">\(thanks)</p>
        \(EmailHTML.summaryBox(rows))
        <p style="margin:0 0 16px;">If anything looks off, just reply to this message.</p>
        <p style="margin:20px 0 0;">\(signature)</p>
        """
        return EmailHTML.page(inner)
    }

    // MARK: - Helpers

    private static func money(_ value: Double) -> String { value.formatted(.currency(code: "USD")) }

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
