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
        let renderer = ImageRenderer(content: view)
        renderer.proposedSize = ProposedViewSize(width: pageWidth, height: nil)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("completion-\(UUID().uuidString).pdf")
        // The file is only an intermediate; the returned Data is what's merged, so don't leave it behind.
        defer { try? FileManager.default.removeItem(at: url) }
        var ok = false
        renderer.render { size, context in
            var box = CGRect(origin: .zero, size: size)
            guard let pdf = CGContext(url as CFURL, mediaBox: &box, nil) else { return }
            pdf.beginPDFPage(nil)
            context(pdf)
            pdf.endPDFPage()
            pdf.closePDF()
            ok = true
        }
        return ok ? try? Data(contentsOf: url) : nil
    }

    static func trimmed(_ value: String?) -> String { (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
}

// MARK: - Shared style

private let pdfGold = GLColor.gold.render(in: .light)
private let pdfGreen = Color(red: 0.18, green: 0.49, blue: 0.20)
private func money(_ value: Double) -> String { value.formatted(.currency(code: "USD")) }
private func addressText(_ a: Address) -> String {
    let cityLine = [a.city, a.state].filter { !$0.isEmpty }.joined(separator: ", ")
    let cityZip = [cityLine, a.postalCode].filter { !$0.isEmpty }.joined(separator: " ")
    return [a.street1, a.street2 ?? "", cityZip]
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
        .joined(separator: "\n")
}

private struct PDFHeader: View {
    let business: BusinessProfile?
    let docTitle: String
    let badge: String?
    let badgeColor: Color

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                if let data = business?.logoData, let image = UIImage(data: data) {
                    Image(uiImage: image).resizable().scaledToFit()
                        .frame(width: 84, height: 84).clipShape(RoundedRectangle(cornerRadius: 8))
                }
                if let business, !business.businessName.isEmpty {
                    Text(business.businessName).font(.title2.bold())
                }
                if let business {
                    let address = addressText(business.address)
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
                Text(docTitle).font(.title.bold()).foregroundStyle(pdfGold).multilineTextAlignment(.trailing)
                if let badge {
                    Text(badge).font(.caption.weight(.bold)).foregroundStyle(badgeColor)
                }
            }
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
            if !job.customerName.isEmpty { block("CUSTOMER", job.customerName) }
            if !job.serviceAddress.isEmpty { block("SERVICE ADDRESS", job.serviceAddress.formattedMultiline) }
            block("COMPLETION DATE",
                  (job.completedAt ?? .now).formatted(date: .long, time: .omitted))
            Spacer(minLength: 0)
            Text("This certifies the work above was completed and paid in full. Any warranty coverage begins from the completion date shown.")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    private func block(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption2.weight(.bold)).foregroundStyle(pdfGold)
            Text(value).font(.subheadline.bold()).frame(maxWidth: .infinity, alignment: .leading)
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
            .background(RoundedRectangle(cornerRadius: 12).fill(pdfGreen.opacity(0.08)))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(pdfGreen.opacity(0.35)))

            if !job.activeBillingInvoices.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("INVOICES").font(.caption2.weight(.bold)).foregroundStyle(pdfGold)
                    ForEach(job.activeBillingInvoices.sorted { $0.createdAt < $1.createdAt }) { invoice in
                        HStack {
                            Text(invoice.number.isEmpty ? invoice.jobTitle : invoice.number).font(.subheadline)
                            Spacer()
                            Text(invoice.createdAt.formatted(date: .abbreviated, time: .omitted))
                                .font(.caption).foregroundStyle(.secondary)
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
                        Spacer()
                        Text("PAID IN FULL").font(.subheadline.bold()).foregroundStyle(pdfGreen)
                    }
                }
                .frame(width: 260)
            }
            Spacer(minLength: 0)
        }
    }

    private func summaryLine(_ label: String, _ value: String) -> some View {
        HStack { Text(label).foregroundStyle(.secondary); Spacer(); Text(value) }.font(.subheadline)
    }
}

private struct CompletionWarrantyPage: View {
    let job: ScheduledJob
    let business: BusinessProfile?

    var body: some View {
        PDFPage {
            PDFHeader(business: business, docTitle: "WARRANTY", badge: nil, badgeColor: pdfGold)
            Text("Coverage begins \((job.completedAt ?? .now).formatted(date: .long, time: .omitted)) — the completion date.")
                .font(.caption).foregroundStyle(.secondary)
            Text(CompletionPackagePDF.trimmed(business?.warrantyText))
                .font(.subheadline)
                .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 0)
        }
    }
}
