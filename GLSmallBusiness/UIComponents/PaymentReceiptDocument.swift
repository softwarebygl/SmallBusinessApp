//
//  PaymentReceiptDocument.swift
//  GLSmallBusiness
//
//  A *payment receipt* — confirms money received for an invoice. Unlike resending the invoice, it
//  reads as an acknowledgement (it leads with "Payment received"), and shows what's left as an
//  informational "remaining balance", never as an amount due now.
//

import SwiftUI
import GoldLifeUI

struct PaymentReceiptPDFDocument: View {
    let invoice: Invoice
    let payment: InvoicePayment
    let business: BusinessProfile?

    static let pageWidth: CGFloat = 612 // US Letter at 72 dpi

    private var gold: Color { GLTheme.paperAccent }
    private var green: Color { Color(red: 0.18, green: 0.49, blue: 0.20) }

    private var paidToDate: Double { invoice.paidThrough(payment) }
    private var remaining: Double { invoice.remainingAfter(payment) }
    private var paidInFull: Bool { remaining < 0.005 }

    private func money(_ value: Double) -> String { value.formatted(.money) }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            header
            parties
            receivedBlock
            summary
            if let business, business.receiptReviewLink != nil {
                reviewCTA(business.reviewsURL)
            }
            Spacer(minLength: 0)
            // Text per branch: a ternary of literals may resolve to the verbatim String init (F21).
            (paidInFull
                ? Text("Thank you — this invoice is now paid in full. We appreciate your business.")
                : Text("Thank you for your payment. This receipt confirms the amount received above."))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
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
                if let data = business?.documentLogoData, let uiImage = UIImage(data: data) {
                    Image(uiImage: uiImage)
                        .resizable().scaledToFit()
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
                Text("RECEIPT").font(.largeTitle.bold()).foregroundStyle(gold)
                if !invoice.number.isEmpty {
                    Text("For Invoice \(invoice.number)").font(.headline)
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("Date: \(payment.date.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted).locale(MBLocalization.currentLocale)))")
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                (paidInFull ? Text("PAID IN FULL") : Text("PAYMENT RECEIVED"))
                    .font(.caption.weight(.bold)).foregroundStyle(green)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: 220, alignment: .trailing)
        }
    }

    private var parties: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text("RECEIVED FROM").font(.caption2.weight(.bold)).foregroundStyle(gold)
                Text(invoice.customerDisplayName).font(.subheadline.bold())
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                if let biz = invoice.customerBusinessName, !biz.isEmpty {
                    Text(biz).font(.caption)
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
                Text("FOR").font(.caption2.weight(.bold)).foregroundStyle(gold)
                Text(invoice.jobTitle.isEmpty ? "—" : invoice.jobTitle)
                    .font(.subheadline.bold()).multilineTextAlignment(.trailing)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                if !invoice.number.isEmpty {
                    Text("Invoice \(invoice.number)").font(.caption).foregroundStyle(.secondary)
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: 250, alignment: .trailing)
        }
    }

    private var receivedBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("PAYMENT RECEIVED").font(.caption2.weight(.bold)).foregroundStyle(green)
            HStack(alignment: .firstTextBaseline) {
                Text(money(payment.amount)).font(.system(size: 34, weight: .bold)).foregroundStyle(green)
                Spacer(minLength: 8)
                Text("\(payment.date.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted).locale(MBLocalization.currentLocale))) · \(payment.method.label)")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !payment.note.isEmpty {
                Text(payment.note).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(green.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(green.opacity(0.35)))
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
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    (paidInFull ? Text("PAID IN FULL") : Text(verbatim: money(remaining)))
                        .font(.subheadline.bold())
                        .foregroundStyle(paidInFull ? green : .black)
                }
            }
            .frame(width: 270)
        }
    }

    /// `LocalizedStringKey`, never `String`: `Text(String)` draws the words as-is, so a Spanish
    /// receipt printed "Invoice total / Paid to date" in English (F21).
    private func summaryLine(_ label: LocalizedStringKey, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Text(value)
        }
        .font(.subheadline)
    }

    /// A prominent "leave us a review" call-out. The PDF text isn't tappable, but it's shown big and
    /// centered so the customer can't miss the link; the email/text versions make it one-tap clickable.
    private func reviewCTA(_ reviewsURL: String) -> some View {
        VStack(spacing: 5) {
            Text("★  Enjoyed working with us?").font(.headline).foregroundStyle(gold)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
            Text("Leave us a quick review:").font(.subheadline).foregroundStyle(.secondary)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
            Text(reviewsURL.trimmingCharacters(in: .whitespacesAndNewlines))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(gold)
                .multilineTextAlignment(.center)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(gold.opacity(0.10)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(gold.opacity(0.5)))
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
        let safeNumber = invoice.number.isEmpty ? "invoice" : invoice.number
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Receipt-\(safeNumber).pdf")
        return PaginatedPDF.render(PaymentReceiptPDFDocument(invoice: invoice, payment: payment, business: business),
                                   width: PaymentReceiptPDFDocument.pageWidth, to: url)
    }
}

// MARK: - Email / text wording

enum PaymentReceiptMessage {

    static let defaultClosing = "If anything looks off, just reply to this message."

    static func subject(invoice: Invoice, business: BusinessProfile?) -> String {
        let custom = trimmed(business?.receiptMessageSubject)
        if !custom.isEmpty { return custom }
        let company = trimmed(business?.businessName)
        let number = trimmed(invoice.number)
        let base = number.isEmpty ? "Payment receipt" : "Receipt for invoice \(number)"
        return company.isEmpty ? base : "\(base) from \(company)"
    }

    /// Intro paragraph: custom override, else a default that reflects whether the invoice is settled.
    static func intro(paidInFull: Bool, business: BusinessProfile?) -> String {
        let custom = trimmed(business?.receiptMessageIntro)
        if !custom.isEmpty { return custom }
        return paidInFull
            ? "Thank you — this invoice is now paid in full."
            : "Thank you for your payment. Your receipt is attached."
    }

    static func closing(business: BusinessProfile?) -> String {
        let custom = trimmed(business?.receiptMessageClosing)
        return custom.isEmpty ? defaultClosing : custom
    }

    static func plainBody(invoice: Invoice, payment: InvoicePayment, business: BusinessProfile?) -> String {
        let name = trimmed(invoice.customerFirstName).isEmpty ? "there" : trimmed(invoice.customerFirstName)
        let company = trimmed(business?.businessName)
        let remaining = invoice.remainingAfter(payment)
        let paidInFull = remaining < 0.005
        let signoff = company.isEmpty ? "" : "\n\n— \(company)"

        var lines: [String] = []
        lines.append("Payment received: \(money(payment.amount)) (\(payment.method.englishLabel), \(payment.date.formatted(.englishMessageDate)))")
        if !invoice.number.isEmpty { lines.append("Invoice: \(invoice.number)") }
        lines.append("Invoice total: \(money(invoice.total))")
        lines.append("Paid to date: \(money(invoice.paidThrough(payment)))")
        lines.append(paidInFull ? "Remaining balance: Paid in full" : "Remaining balance: \(money(remaining))")

        return """
        Hi \(name),

        \(intro(paidInFull: paidInFull, business: business))

        \(lines.joined(separator: "\n"))

        \(closing(business: business))\(reviewPlain(business: business))\(signoff)
        """
    }

    @MainActor
    static func htmlBody(invoice: Invoice, payment: InvoicePayment, business: BusinessProfile?) -> String {
        let name = esc(trimmed(invoice.customerFirstName).isEmpty ? "there" : trimmed(invoice.customerFirstName))
        let remaining = invoice.remainingAfter(payment)
        let paidInFull = remaining < 0.005

        let logoTag = EmailSignature.logoTag(business: business)

        var rows: [(label: String, value: String, strong: Bool)] = []
        rows.append(("Payment received", esc(money(payment.amount)), true))
        rows.append(("Method", "\(esc(payment.method.englishLabel)) · \(esc(payment.date.formatted(.englishMessageDate)))", false))
        if !invoice.number.isEmpty { rows.append(("Invoice", esc(invoice.number), false)) }
        rows.append(("Invoice total", esc(money(invoice.total)), false))
        rows.append(("Paid to date", esc(money(invoice.paidThrough(payment))), false))
        rows.append(("Remaining balance", paidInFull ? "Paid in full" : esc(money(remaining)), true))

        let signature = EmailSignature.block(business: business)

        let inner = """
        \(logoTag)
        <p style="margin:0 0 14px;">Hi \(name),</p>
        <p style="margin:0 0 16px;">\(htmlText(intro(paidInFull: paidInFull, business: business)))</p>
        \(EmailHTML.summaryBox(rows))
        <p style="margin:0 0 16px;">\(htmlText(closing(business: business)))</p>
        \(reviewHTML(business: business))
        \(signature.isEmpty ? "" : "<p style=\"margin:20px 0 0;\">\(signature)</p>")
        """
        return EmailHTML.page(inner)
    }

    // MARK: - Helpers

    private static func money(_ value: Double) -> String { value.formatted(.money) }

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

    /// Escapes user-entered prose for HTML and preserves their line breaks as `<br>`.
    private static func htmlText(_ string: String) -> String {
        esc(string).replacingOccurrences(of: "\n", with: "<br>")
    }

    /// A review ask for the plain-text (SMS) body — empty when no reviews link is set or the owner
    /// hasn't turned receipt inclusion on. SMS clients auto-link the URL, so it's tappable.
    private static func reviewPlain(business: BusinessProfile?) -> String {
        guard let url = business?.receiptReviewLink else { return "" }
        return "\n\nEnjoyed the work? Please leave us a quick review: \(url.absoluteString)"
    }

    /// A prominent, tappable review button for the HTML email — empty when no reviews link is set or
    /// the owner hasn't turned receipt inclusion on.
    private static func reviewHTML(business: BusinessProfile?) -> String {
        guard let url = business?.receiptReviewLink else { return "" }
        let href = esc(url.absoluteString)
        return """
        <p style="margin:0 0 18px;text-align:center;">
          <a href="\(href)" style="display:inline-block;background-color:#9C7A2E;color:#ffffff;text-decoration:none;padding:12px 24px;border-radius:8px;font-weight:600;">★ Leave us a review</a>
        </p>
        """
    }
}
