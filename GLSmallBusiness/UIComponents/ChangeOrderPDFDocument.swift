//
//  ChangeOrderPDFDocument.swift
//  GLSmallBusiness
//
//  The print/PDF layout for a change order: what's changing, the price delta, the revised total,
//  and a signature line for the customer to approve.
//

import SwiftUI
import GoldLifeUI

struct ChangeOrderPDFDocument: View {
    let changeOrder: ChangeOrder
    let business: BusinessProfile?

    static let pageWidth: CGFloat = 612

    private var gold: Color { GLTheme.paperAccent }
    private var invoice: Invoice? { changeOrder.invoice }
    /// What this order ACTUALLY bills on the invoice right now: the linked group's items at the
    /// rate the invoice bills them (mirroring Invoice.totals) — the rate the order was signed at,
    /// whatever the invoice's own rate is now (law 87; QA F82). Falls back to the snapshotted CO
    /// total for pre-link applies. 0 when the order hasn't been applied. Internal for tests.
    var billedContribution: Double { DomainMoney.roundedToCents(exactBilledContribution) }
    /// The same, exact (law 60) — `originalTotal` backs it out before its own one rounding.
    private var exactBilledContribution: Decimal {
        guard changeOrder.appliedToInvoice else { return 0 }
        guard let invoice, let group = changeOrder.invoiceGroup else {
            return changeOrder.totals.exactTotal
        }
        let items = group.sortedLineItems
        return ChangeOrderMath.totals(lines: items.map { ($0.exactSignedLineTotal, $0.isTaxable) },
                                      taxRatePercent: group.changeOrderTaxRate(invoiceRate: invoice.taxRatePercent)).exactTotal
    }
    /// The invoice total BEFORE this change order. Once a CO is applied its items live in the
    /// invoice, so back out what they actually bill to keep "original" and "revised" honest.
    /// Backs out from the UNCLAMPED sum: `Invoice.totals` floors the billed total at $0, so
    /// subtracting a large credit from the clamped figure would fabricate the original
    /// ($0 − (−$500) would print $500 for a $100 invoice). Subtotal/discount/tax carry no floor,
    /// so their sum rebuilds the pre-clamp total; the original then gets the invoice's own floor.
    /// Internal for tests.
    var originalTotal: Double {
        if let invoice {
            let totals = invoice.totals
            let unclampedRevised = totals.exactSubtotal - totals.exactDiscount + totals.exactTax
            return DomainMoney.roundedToCents(max(0, unclampedRevised - exactBilledContribution))
        }
        if let contract = changeOrder.contract {
            let thisContribution = changeOrder.status == .approved ? changeOrder.total : 0
            return DomainMoney.roundedToCents(max(0, contract.contractedValue - thisContribution))
        }
        return 0
    }
    /// Applied → the invoice total already includes this order, so it IS the revised figure;
    /// adding `changeOrder.total` again would double-count. Internal for tests.
    var revisedTotal: Double { ChangeOrderMessage.revisedTotal(changeOrder) }

    private func money(_ value: Double) -> String { value.formatted(.money) }
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
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
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
                if let data = business?.documentLogoData, let uiImage = UIImage(data: data) {
                    Image(uiImage: uiImage).resizable().scaledToFit()
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
                Text("CHANGE ORDER").font(.title.bold()).foregroundStyle(gold)
                if !changeOrder.number.isEmpty {
                    Text(changeOrder.number).font(.headline)
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("Date: \(changeOrder.createdAt.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted).locale(MBLocalization.currentLocale)))")
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                if let number = invoice?.number, !number.isEmpty {
                    Text("For Invoice \(number)").font(.caption).foregroundStyle(.secondary)
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)
                } else if let contractNumber = changeOrder.contract?.number, !contractNumber.isEmpty {
                    Text("For Contract \(contractNumber)").font(.caption).foregroundStyle(.secondary)
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(changeOrder.status.label.uppercased())
                    .font(.caption.weight(.semibold)).foregroundStyle(gold)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: 220, alignment: .trailing)
        }
    }

    private var parties: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text("FOR").font(.caption2.weight(.bold)).foregroundStyle(gold)
                let customerName = changeOrder.customerDisplayName
                Text(customerName.isEmpty ? "—" : customerName).font(.subheadline.bold())
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                if let biz = changeOrder.customerBusinessName, !biz.isEmpty {
                    Text(biz).font(.caption)
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: 250, alignment: .leading)
            Spacer(minLength: 16)
            VStack(alignment: .trailing, spacing: 2) {
                Text("PROJECT").font(.caption2.weight(.bold)).foregroundStyle(gold)
                let jobTitle = changeOrder.projectTitle
                Text(jobTitle.isEmpty ? "—" : jobTitle)
                    .font(.subheadline.bold()).multilineTextAlignment(.trailing)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: 250, alignment: .trailing)
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
                        Text("\(item.quantity.formatted()) \(item.unit.abbreviation) × \(money(item.unitPrice))")
                            .font(.caption2).foregroundStyle(.secondary)
                            .lineLimit(nil)
                            .fixedSize(horizontal: false, vertical: true)
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
                totalLine(changeOrder.invoice != nil ? "Original invoice total" : "Original contract total", money(originalTotal))
                if changeOrder.taxAmount != 0 {
                    totalLine("Change subtotal", signed(changeOrder.subtotal))
                    // The rate the order was signed at — the rate the invoice bills it at (QA F82).
                    totalLine("Tax (\(changeOrder.taxRatePercent.formatted())%)", signed(changeOrder.taxAmount))
                }
                totalLine("This change order", signed(changeOrder.total), bold: true, gold: true)
                Rectangle().fill(gold.opacity(0.5)).frame(height: 1).padding(.vertical, 2)
                totalLine("Revised total", money(revisedTotal), bold: true)
            }
            .frame(width: 270)
        }
    }

    /// Labels are `LocalizedStringKey`, never `String`: `Text(String)` draws the words as-is, so a
    /// Spanish change order printed its totals and "Approved by" in English (F21).
    private func totalLine(_ label: LocalizedStringKey, _ value: String, bold: Bool = false, gold useGold: Bool = false) -> some View {
        HStack {
            Text(label)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Text(value).foregroundStyle(useGold ? gold : .black)
        }
        .font(bold ? .subheadline.bold() : .subheadline)
    }

    private var notes: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Notes").font(.caption.weight(.bold)).foregroundStyle(gold)
            Text(changeOrder.note).font(.caption)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var approval: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("By signing below, the customer approves this change to the project scope and the revised total above.")
                .font(.caption2).foregroundStyle(.secondary)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 24) {
                signatureLine("Approved by")
                signatureLine("Date")
            }
            .padding(.top, 18)
        }
    }

    private func signatureLine(_ label: LocalizedStringKey) -> some View {
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
        let safe = changeOrder.number.isEmpty ? "draft" : changeOrder.number
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ChangeOrder-\(safe).pdf")
        return PaginatedPDF.render(ChangeOrderPDFDocument(changeOrder: changeOrder, business: business),
                                   width: ChangeOrderPDFDocument.pageWidth, to: url)
    }
}

// MARK: - Email / text wording

enum ChangeOrderMessage {

    static let defaultIntro = "Here's a change order for your approval covering an update to the project scope. Please review the attached document and reply to approve."
    static let defaultClosing = "Reply to this message to approve, or with any questions."

    static func subject(_ co: ChangeOrder, business: BusinessProfile?) -> String {
        let custom = trimmed(business?.changeOrderMessageSubject)
        if !custom.isEmpty { return custom }
        let company = trimmed(business?.businessName)
        let base = co.number.isEmpty ? "Change order" : "Change order \(co.number)"
        return company.isEmpty ? base : "\(base) from \(company)"
    }

    static func intro(business: BusinessProfile?) -> String {
        let custom = trimmed(business?.changeOrderMessageIntro)
        return custom.isEmpty ? defaultIntro : custom
    }

    static func closing(business: BusinessProfile?) -> String {
        let custom = trimmed(business?.changeOrderMessageClosing)
        return custom.isEmpty ? defaultClosing : custom
    }

    static func plainBody(_ co: ChangeOrder, business: BusinessProfile?) -> String {
        let name = trimmed(co.customerFirstName).isEmpty ? "there" : trimmed(co.customerFirstName)
        let company = trimmed(business?.businessName)
        let signoff = company.isEmpty ? "" : "\n\n— \(company)"
        var lines: [String] = []
        if !co.title.isEmpty { lines.append(co.title) }
        lines.append("This change order: \(signedMoney(co.total))")
        lines.append("Revised total: \(money(revisedTotal(co)))")
        return """
        Hi \(name),

        \(intro(business: business))

        \(lines.joined(separator: "\n"))

        \(closing(business: business))\(signoff)
        """
    }

    @MainActor
    static func htmlBody(_ co: ChangeOrder, business: BusinessProfile?) -> String {
        let name = esc(trimmed(co.customerFirstName).isEmpty ? "there" : trimmed(co.customerFirstName))

        let logoTag = EmailSignature.logoTag(business: business)

        var rows: [(label: String, value: String, strong: Bool)] = []
        if !co.number.isEmpty { rows.append(("Change order", esc(co.number), false)) }
        if !co.title.isEmpty { rows.append(("Summary", esc(co.title), false)) }
        rows.append(("This change", esc(signedMoney(co.total)), true))
        rows.append(("Revised total", esc(money(revisedTotal(co))), true))

        let signature = EmailSignature.block(business: business)

        let inner = """
        \(logoTag)
        <p style="margin:0 0 14px;">Hi \(name),</p>
        <p style="margin:0 0 16px;">\(htmlText(intro(business: business)))</p>
        \(EmailHTML.summaryBox(rows))
        <p style="margin:0 0 16px;">\(htmlText(closing(business: business)))</p>
        \(signature.isEmpty ? "" : "<p style=\"margin:20px 0 0;\">\(signature)</p>")
        """
        return EmailHTML.page(inner)
    }

    /// Once a change order is applied, the invoice's total already includes it — adding `co.total`
    /// on top would double-count. Before that, the invoice's exact total plus this order's, rounded
    /// once — the total the invoice bills once it is added. The attached PDF reads this same figure.
    static func revisedTotal(_ co: ChangeOrder) -> Double {
        if let invoice = co.invoice {
            return co.appliedToInvoice
                ? invoice.total : DomainMoney.roundedToCents(invoice.totals.exactTotal + co.totals.exactTotal)
        }
        if let contract = co.contract {
            return co.status == .approved
                ? contract.contractedValue : DomainMoney.roundedToCents(contract.contractedValue + co.total)
        }
        return co.appliedToInvoice ? 0 : co.total
    }

    private static func money(_ value: Double) -> String { value.formatted(.money) }
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

    /// Escapes user-entered prose for HTML and preserves their line breaks as `<br>`.
    private static func htmlText(_ string: String) -> String {
        esc(string).replacingOccurrences(of: "\n", with: "<br>")
    }
}
