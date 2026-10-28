//
//  CompletionPackagePDF.swift
//  GLSmallBusiness
//
//  The job-completion package: a single shareable PDF that closes out a job — a completion summary,
//  a paid-in-full receipt rolled up across the job's billing invoices, and the business's warranty
//  page. Built only for a one-off job that is completed AND fully billed + collected. Mirrors the
//  Contractor Package's render-to-PDF + merge pipeline; nothing is signed.
//

import SwiftUI
import GoldLifeUI
import PDFKit

enum CompletionPackagePDF {
    static let pageWidth: CGFloat = 612   // US Letter at 72 dpi

    @MainActor
    static func render(job: ScheduledJob, business: BusinessProfile?) -> URL? {
        var pages: [Data] = []
        if let cover = pageData(CompletionCoverPage(job: job, business: business)) { pages.append(cover) }
        if let receipt = pageData(CompletionReceiptPage(job: job, business: business)) { pages.append(receipt) }
        if let warranty = trimmed(business?.warrantyText).isEmpty
            ? nil
            : pageData(CompletionWarrantyPage(job: job, business: business)) {
            pages.append(warranty)
        }
        guard !pages.isEmpty else { return nil }
        let safe = job.displayTitle.replacingOccurrences(of: "/", with: "-")
        return ContractorPackagePDF.merge(pages, fileName: "Completion-\(safe).pdf")
    }

    @MainActor
    private static func pageData<V: View>(_ view: V) -> Data? {
        // Route through the shared paginator so a long warranty/terms block splits across US-Letter
        // pages like every other document, instead of one oversized page that prints scaled-down.
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("completion-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: url) }   // intermediate; the returned Data is merged
        guard PaginatedPDF.render(view, width: pageWidth, to: url) != nil else { return nil }
        return try? Data(contentsOf: url)
    }

    static func trimmed(_ value: String?) -> String { (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
}

// MARK: - Shared style

private let pdfGold = GLTheme.paperAccent
private let pdfGreen = Color(red: 0.18, green: 0.49, blue: 0.20)
private func money(_ value: Double) -> String { value.formatted(.money) }
private func addressText(_ a: Address) -> String {
    let cityLine = [a.city, a.state].filter { !$0.isEmpty }.joined(separator: ", ")
    let cityZip = [cityLine, a.postalCode].filter { !$0.isEmpty }.joined(separator: " ")
    return [a.street1, a.street2 ?? "", cityZip]
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
        .joined(separator: "\n")
}

/// Titles and badges are `LocalizedStringKey`, never `String`: `Text(String)` draws the words
/// as-is, so a Spanish completion package printed every label in English (F21).
private struct PDFHeader: View {
    let business: BusinessProfile?
    let docTitle: LocalizedStringKey
    let badge: LocalizedStringKey?
    let badgeColor: Color

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                if let data = business?.documentLogoData, let image = UIImage(data: data) {
                    Image(uiImage: image).resizable().scaledToFit()
                        .frame(width: 84, height: 84).clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                if let business, !business.businessName.isEmpty {
                    Text(business.businessName).font(.title2.bold())
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let business {
                    let address = addressText(business.documentAddress)
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
                Text(docTitle).font(.title.bold()).foregroundStyle(pdfGold).multilineTextAlignment(.trailing)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                if let badge {
                    Text(badge).font(.caption.weight(.bold)).foregroundStyle(badgeColor)
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: 220, alignment: .trailing)
        }
    }
}

private struct PDFPage<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 22) { content }
            .padding(40)
            .frame(width: CompletionPackagePDF.pageWidth, alignment: .topLeading)
            .background(Color.white)
            .environment(\.colorScheme, .light)
            .foregroundStyle(.black)
    }
}

// MARK: - Pages

private struct CompletionCoverPage: View {
    let job: ScheduledJob
    let business: BusinessProfile?

    var body: some View {
        PDFPage {
            PDFHeader(business: business, docTitle: "COMPLETION\nCERTIFICATE", badge: "COMPLETED", badgeColor: pdfGreen)
            block("JOB", job.displayTitle)
            // "Customer", shown upper-cased: a "CUSTOMER" key would collide with the catalog's "customer"
            // symbol (Xcode generates one symbol per key, case-folded).
            if !job.customerName.isEmpty { block("Customer", job.customerName, upperCased: true) }
            if !job.serviceAddress.isEmpty { block("SERVICE ADDRESS", job.serviceAddress.formattedMultiline) }
            block("COMPLETION DATE",
                  (job.completedAt ?? .now).formatted(Date.FormatStyle(date: .long, time: .omitted).locale(MBLocalization.currentLocale)))
            Spacer(minLength: 0)
            Text("This certifies the work above was completed and paid in full. Any warranty coverage begins from the completion date shown.")
                .font(.footnote).foregroundStyle(.secondary)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func block(_ label: LocalizedStringKey, _ value: String, upperCased: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption2.weight(.bold)).foregroundStyle(pdfGold)
                .textCase(upperCased ? .uppercase : nil)
            Text(value).font(.subheadline.bold())
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct CompletionReceiptPage: View {
    let job: ScheduledJob
    let business: BusinessProfile?

    var body: some View {
        PDFPage {
            PDFHeader(business: business, docTitle: "PAID IN FULL", badge: "RECEIPT", badgeColor: pdfGreen)
            VStack(alignment: .leading, spacing: 4) {
                Text("TOTAL PAID").font(.caption2.weight(.bold)).foregroundStyle(pdfGreen)
                Text(money(job.amountPaid)).font(.system(size: 34, weight: .bold)).foregroundStyle(pdfGreen)
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(pdfGreen.opacity(0.08)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(pdfGreen.opacity(0.35)))

            if !job.activeBillingInvoices.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("INVOICES").font(.caption2.weight(.bold)).foregroundStyle(pdfGold)
                    ForEach(job.activeBillingInvoices.sorted { $0.createdAt < $1.createdAt }) { invoice in
                        HStack {
                            Text(invoice.number.isEmpty ? invoice.jobTitle : invoice.number).font(.subheadline)
                                .lineLimit(nil)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer()
                            Text(invoice.createdAt.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted).locale(MBLocalization.currentLocale)))
                                .font(.caption).foregroundStyle(.secondary)
                                .lineLimit(nil)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(money(invoice.total)).font(.subheadline.bold())
                        }
                    }
                }
            }

            HStack {
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    summaryLine("Contracted", money(job.contractedValue))
                    summaryLine("Invoiced", money(job.invoicedTotal))
                    Rectangle().fill(pdfGold.opacity(0.4)).frame(height: 1).padding(.vertical, 2)
                    HStack {
                        Text("Balance").font(.subheadline.bold())
                            .lineLimit(nil)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        Text("PAID IN FULL").font(.subheadline.bold()).foregroundStyle(pdfGreen)
                    }
                }
                .frame(width: 270)
            }
            Spacer(minLength: 0)
        }
    }

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
}

private struct CompletionWarrantyPage: View {
    let job: ScheduledJob
    let business: BusinessProfile?

    var body: some View {
        PDFPage {
            PDFHeader(business: business, docTitle: "WARRANTY", badge: nil, badgeColor: pdfGold)
            Text("Coverage begins \((job.completedAt ?? .now).formatted(Date.FormatStyle(date: .long, time: .omitted).locale(MBLocalization.currentLocale))) — the completion date.")
                .font(.caption).foregroundStyle(.secondary)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
            Text(CompletionPackagePDF.trimmed(business?.warrantyText))
                .font(.subheadline)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 0)
        }
    }
}
