//
//  EstimateDetailScreen.swift
//  GLSmallBusiness
//
//  Created by Gold Life LLC on 5/28/26.
//

import SwiftUI
import SwiftData
import MessageUI

struct EstimateStatusBadge: View {
    let estimate: Estimate

    private var color: Color {
        if estimate.isExpired { return .orange }
        switch estimate.status {
        case .draft: return .secondary
        case .sent: return .blue
        case .accepted: return .green
        case .declined: return .red
        }
    }

    var body: some View {
        Text(estimate.displayStatus)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Capsule().fill(color.opacity(0.18)))
            .foregroundStyle(color)
    }
}

struct EstimateDetailScreen: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.modelContext) private var modelContext
    @Query private var businessProfiles: [BusinessProfile]
    @Query private var allInvoices: [Invoice]
    let estimate: Estimate

    @State private var showingEdit = false
    @State private var sendAction: SendAction?
    @State private var pdfURL: URL?
    @State private var showingPreview = false
    @State private var sendFailureMessage: String?
    @State private var showingProfilePrompt = false
    @State private var convertedInvoice: Invoice?
    @State private var showingSchedule = false

    private enum SendAction: Int, Identifiable {
        case email, text
        var id: Int { rawValue }
    }

    private var gold: Color { GLColor.gold.render(in: colorScheme) }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                headerCard
                customerCard
                if !estimate.serviceAddress.isEmpty {
                    serviceAddressCard
                }
                groupsView
                totalsCard
                if !estimate.customerNotes.isEmpty || !estimate.terms.isEmpty {
                    notesCard
                }
            }
            .padding()
        }
        .containerBackground(for: .navigation) {
            PrimaryBackground()
        }
        .navigationTitle(estimate.number.isEmpty ? String(localized: "Estimate") : estimate.number)
        .toolbarTitleDisplayMode(.inline)
        .navigationDestination(item: $convertedInvoice) { invoice in
            InvoiceDetailScreen(invoice: invoice)
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Section {
                        Button { showingEdit = true } label: { Label("Edit estimate", systemImage: "pencil") }
                        if estimate.status == .accepted {
                            Button { showingSchedule = true } label: { Label("Schedule", systemImage: "calendar.badge.plus") }
                        }
                        Button { convertToInvoice() } label: { Label("Convert to Invoice", systemImage: "arrow.right.doc.on.clipboard") }
                    }
                    if let pdfURL {
                        Section {
                            Button { showingPreview = true } label: { Label("Preview", systemImage: "eye") }
                            if !estimate.customerEmail.isEmpty && MFMailComposeViewController.canSendMail() {
                                Button { sendAction = .email } label: { Label("Email estimate", systemImage: "envelope") }
                            }
                            if !estimate.customerPhone.isEmpty && MFMessageComposeViewController.canSendText() {
                                Button { sendAction = .text } label: { Label("Text estimate", systemImage: "message") }
                            }
                            ShareLink(item: pdfURL) { Label("Share estimate…", systemImage: "square.and.arrow.up") }
                        }
                    } else if businessProfiles.first?.isComplete == true {
                        // Profile is complete, so the missing PDF means generation failed — offer a retry
                        // instead of the misleading "set up your profile" prompt.
                        Section {
                            Button { regeneratePDF() } label: {
                                Label("Couldn’t create the document — try again", systemImage: "arrow.clockwise")
                            }
                        }
                    } else {
                        Section {
                            Button { showingProfilePrompt = true } label: { Label("Set up business profile to send", systemImage: "exclamationmark.circle") }
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .accessibilityLabel("More")
            }
        }
        .onAppear { regeneratePDF() }
        .onChange(of: showingEdit) { _, isShowing in
            if !isShowing { regeneratePDF() }
        }
        .sheet(isPresented: $showingEdit) {
            EstimateFormScreen(editing: estimate).glAppearance(colorScheme)
        }
        .sheet(isPresented: $showingSchedule) {
            ScheduleJobSheet(source: .estimate(estimate)).glAppearance(colorScheme)
        }
        .sheet(item: $sendAction) { action in
            sendSheet(for: action).glAppearance(colorScheme)
        }
        .sheet(isPresented: $showingPreview) {
            if let pdfURL {
                DocumentPreviewSheet(url: pdfURL,
                                     title: estimate.number.isEmpty ? "Estimate" : "Estimate \(estimate.number)")
                    .glAppearance(colorScheme)
            }
        }
        .alert("Complete your business profile", isPresented: $showingProfilePrompt) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("Add your business name, phone, and email in Menu → My Company before sending an estimate.")
        }
        .alert("Couldn’t send", isPresented: Binding(get: { sendFailureMessage != nil },
                                                     set: { if !$0 { sendFailureMessage = nil } })) {
            Button("OK", role: .cancel) { sendFailureMessage = nil }
        } message: {
            Text(sendFailureMessage ?? "")
        }
    }

    /// After the Mail/Messages sheet closes, tell the user only when it actually failed — a sent or
    /// cancelled message needs no interruption.
    private func noteSend(_ outcome: SendOutcome) {
        if outcome == .failed {
            sendFailureMessage = "We couldn’t send your estimate. Check your internet connection and try again."
        }
    }

    private var headerCard: some View {
        card {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(estimate.jobTitle.isEmpty ? String(localized: "Untitled estimate") : estimate.jobTitle)
                        .font(.title3.weight(.semibold))
                    Text(estimate.number)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                EstimateStatusBadge(estimate: estimate)
            }
            Divider()
            labeledRow(String(localized: "Created"), estimate.createdAt.formatted(date: .abbreviated, time: .omitted))
            labeledRow(String(localized: "Valid until"), estimate.validUntil.formatted(date: .abbreviated, time: .omitted))
        }
    }

    private var customerCard: some View {
        card {
            Text("Prepared for")
                .font(.headline)
            Text(estimate.customerDisplayName)
                .font(.body.weight(.medium))
            if let business = estimate.customerBusinessName, !business.isEmpty {
                Text(business).foregroundStyle(.secondary)
            }
            let address = formattedAddress
            if !address.isEmpty {
                Text(address).foregroundStyle(.secondary)
            }
            if !estimate.customerEmail.isEmpty {
                Text(estimate.customerEmail).foregroundStyle(.secondary)
            }
            if !estimate.customerPhone.isEmpty {
                Text(estimate.customerPhone).foregroundStyle(.secondary)
            }
        }
    }

    private var serviceAddressCard: some View {
        card {
            Text("Service Address")
                .font(.headline)
            Text(estimate.serviceAddress.formattedMultiline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var groupsView: some View {
        ForEach(estimate.sortedGroups) { group in
            card {
                Text(group.name.isEmpty ? String(localized: "Line Items") : group.name)
                    .font(.headline)
                if !group.note.isEmpty {
                    Text(group.note).font(.subheadline).foregroundStyle(.secondary)
                }
                ForEach(group.sortedLineItems) { item in
                    lineItemRow(item)
                    if item.id != group.sortedLineItems.last?.id {
                        Divider()
                    }
                }
                if !group.name.isEmpty || estimate.sortedGroups.count > 1 {
                    Divider()
                    HStack {
                        Text("Subtotal").foregroundStyle(.secondary)
                        Spacer()
                        Text(group.subtotal.formatted(.currency(code: "USD"))).fontWeight(.medium)
                    }
                    .font(.subheadline)
                }
            }
        }
    }

    private func lineItemRow(_ item: EstimateLineItem) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(item.name)
                Spacer()
                Text(item.lineTotal.formatted(.currency(code: "USD")))
            }
            .font(.body.weight(.medium))
            if !item.details.isEmpty {
                Text(item.details).font(.footnote).foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                Text("\(item.quantity.formatted()) \(item.unit.abbreviation) × \(item.unitPrice.formatted(.currency(code: "USD")))")
                Text("·")
                Text(item.kind.label)
                if !item.isTaxable { Text("· non-taxable") }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var totalsCard: some View {
        card {
            totalRow(String(localized: "Subtotal"), estimate.subtotal)
            if estimate.discountAmount > 0 { totalRow(String(localized: "Discount"), -estimate.discountAmount) }
            if estimate.taxAmount > 0 { totalRow(String(localized: "Tax") + " (\(estimate.taxRatePercent.formatted())%)", estimate.taxAmount) }
            Divider()
            totalRow(String(localized: "Total"), estimate.total, bold: true)
            if estimate.depositAmount > 0 {
                totalRow(String(localized: "Required Deposit"), estimate.depositAmount)
            }
        }
    }

    private var notesCard: some View {
        card {
            if !estimate.customerNotes.isEmpty {
                Text("Notes").font(.headline)
                Text(estimate.customerNotes).foregroundStyle(.secondary)
            }
            if !estimate.terms.isEmpty {
                Text("Terms").font(.headline).padding(.top, estimate.customerNotes.isEmpty ? 0 : 6)
                Text(estimate.terms).font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Helpers

    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        GLCard { content() }
    }

    private func labeledRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value)
        }
        .font(.subheadline)
    }

    private func totalRow(_ label: String, _ amount: Double, bold: Bool = false) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(amount.formatted(.currency(code: "USD")))
        }
        .fontWeight(bold ? .bold : .regular)
    }

    /// The Mail / Messages compose sheet, pre-filled with branded content and attachments.
    @ViewBuilder
    private func sendSheet(for action: SendAction) -> some View {
        let business = businessProfiles.first
        switch action {
        case .email:
            MailComposeView(
                recipients: [estimate.recipientEmail],
                subject: EstimateMessage.subject(estimate: estimate, business: business),
                body: EstimateMessage.htmlBody(estimate: estimate, business: business),
                isHTML: true,
                attachmentURL: pdfURL
            ) { outcome in sendAction = nil; noteSend(outcome) }
        case .text:
            // Logo first (renders as an inline image), then the estimate PDF.
            MessageComposeView(
                recipients: [estimate.recipientPhone],
                body: EstimateMessage.plainBody(estimate: estimate, business: business),
                attachmentURLs: [EstimateMessage.logoAttachmentURL(business: business), pdfURL].compactMap { $0 }
            ) { outcome in sendAction = nil; noteSend(outcome) }
        }
    }

    private func regeneratePDF() {
        if let profile = businessProfiles.first, profile.isComplete {
            pdfURL = EstimatePDF.render(estimate, business: profile)
        } else {
            pdfURL = nil
        }
    }

    private func convertToInvoice() {
        let number = Invoice.nextNumber(after: allInvoices)
        convertedInvoice = Invoice.make(from: estimate, number: number, in: modelContext)
        // Persist the new invoice immediately so it's safe and shows in Stats right away.
        modelContext.saveChanges()
    }

    private var formattedAddress: String {
        let a = estimate.customerAddress
        let cityLine = [a.city, a.state].filter { !$0.isEmpty }.joined(separator: ", ")
        let cityZip = [cityLine, a.postalCode].filter { !$0.isEmpty }.joined(separator: " ")
        return [a.street1, a.street2 ?? "", cityZip]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }
}

#Preview {
    let estimate = Estimate(jobTitle: "Master bath tile install", customer: Customer(firstName: "Jane", lastName: "Doe"))
    estimate.number = "EST-0001"
    estimate.taxRatePercent = 8.25
    return NavigationStack {
        EstimateDetailScreen(estimate: estimate)
    }
    .modelContainer(for: [Customer.self, Estimate.self], inMemory: true)
}
