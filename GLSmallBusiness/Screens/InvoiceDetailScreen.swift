//
//  InvoiceDetailScreen.swift
//  GLSmallBusiness
//
//  Created by Gold Life LLC on 5/28/26.
//

import SwiftUI
import SwiftData
import MessageUI

struct InvoiceStatusBadge: View {
    let invoice: Invoice

    private var color: Color {
        if invoice.isPaid { return .green }
        if invoice.isOverdue { return .orange }
        if invoice.isPartiallyPaid { return .blue }
        switch invoice.status {
        case .draft: return .secondary
        case .sent: return .blue
        }
    }

    var body: some View {
        Text(invoice.displayStatus)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Capsule().fill(color.opacity(0.18)))
            .foregroundStyle(color)
    }
}

struct InvoiceDetailScreen: View {
    @Environment(\.colorScheme) private var colorScheme
    @Query private var businessProfiles: [BusinessProfile]
    let invoice: Invoice

    @State private var showingEdit = false
    @State private var showingRecordPayment = false
    @State private var showingSetAmountDue = false
    @State private var sendAction: SendAction?
    @State private var pdfURL: URL?
    @State private var showingProfilePrompt = false
    @State private var receiptPayment: InvoicePayment?
    @State private var showingNewChangeOrder = false
    @State private var selectedChangeOrder: ChangeOrder?

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
                if !invoice.serviceAddress.isEmpty {
                    serviceAddressCard
                }
                groupsView
                totalsCard
                paymentsCard
                changeOrdersCard
                if !invoice.customerNotes.isEmpty || !invoice.terms.isEmpty {
                    notesCard
                }
            }
            .padding()
        }
        .containerBackground(for: .navigation) {
            PrimaryBackground()
        }
        .navigationTitle(invoice.number.isEmpty ? String(localized: "Invoice") : invoice.number)
        .toolbarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Section {
                        Button { showingEdit = true } label: { Label("Edit invoice", systemImage: "pencil") }
                        Button { showingRecordPayment = true } label: { Label("Record payment", systemImage: "dollarsign.circle") }
                        Button { showingSetAmountDue = true } label: { Label("Set amount due", systemImage: "banknote") }
                    }
                    Section {
                        Button { showingNewChangeOrder = true } label: { Label("New change order", systemImage: "plus.rectangle.on.rectangle") }
                        if !invoice.sortedChangeOrders.isEmpty {
                            Menu {
                                ForEach(invoice.sortedChangeOrders) { changeOrder in
                                    Button { selectedChangeOrder = changeOrder } label: {
                                        Text(changeOrder.title.isEmpty ? changeOrder.number : "\(changeOrder.number) · \(changeOrder.title)")
                                    }
                                }
                            } label: { Label("Open change order", systemImage: "rectangle.on.rectangle") }
                        }
                    }
                    if !invoice.sortedPayments.isEmpty {
                        Menu {
                            ForEach(invoice.sortedPayments) { payment in
                                Button { receiptPayment = payment } label: {
                                    Text("\(payment.amount.formatted(.currency(code: "USD"))) · \(payment.date.formatted(date: .abbreviated, time: .omitted))")
                                }
                            }
                        } label: { Label("Send a receipt", systemImage: "doc.text") }
                    }
                    if let pdfURL {
                        Section {
                            if !invoice.customerEmail.isEmpty && MFMailComposeViewController.canSendMail() {
                                Button { sendAction = .email } label: { Label("Email invoice", systemImage: "envelope") }
                            }
                            if !invoice.customerPhone.isEmpty && MFMessageComposeViewController.canSendText() {
                                Button { sendAction = .text } label: { Label("Text invoice", systemImage: "message") }
                            }
                            ShareLink(item: pdfURL) { Label("Share invoice…", systemImage: "square.and.arrow.up") }
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
        .onChange(of: showingRecordPayment) { _, isShowing in
            if !isShowing { regeneratePDF() }
        }
        .onChange(of: showingSetAmountDue) { _, isShowing in
            if !isShowing { regeneratePDF() }
        }
        .sheet(isPresented: $showingEdit) {
            InvoiceFormScreen(editing: invoice).glAppearance(colorScheme)
        }
        .sheet(isPresented: $showingRecordPayment) {
            RecordPaymentSheet(invoice: invoice).glAppearance(colorScheme)
        }
        .sheet(isPresented: $showingSetAmountDue) {
            SetAmountDueSheet(invoice: invoice).glAppearance(colorScheme)
        }
        .sheet(item: $sendAction) { action in
            sendSheet(for: action).glAppearance(colorScheme)
        }
        .sheet(item: $receiptPayment) { payment in
            PaymentReceiptSheet(invoice: invoice, payment: payment).glAppearance(colorScheme)
        }
        .sheet(isPresented: $showingNewChangeOrder) {
            ChangeOrderFormScreen(invoice: invoice).glAppearance(colorScheme)
        }
        .sheet(item: $selectedChangeOrder) { changeOrder in
            ChangeOrderDetailSheet(changeOrder: changeOrder).glAppearance(colorScheme)
        }
        .onChange(of: showingNewChangeOrder) { _, isShowing in if !isShowing { regeneratePDF() } }
        .alert("Complete your business profile", isPresented: $showingProfilePrompt) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("Add your business name, phone, and email in Menu → My Company before sending an invoice.")
        }
    }

    /// The Mail / Messages compose sheet, pre-filled with branded content and attachments.
    @ViewBuilder
    private func sendSheet(for action: SendAction) -> some View {
        let business = businessProfiles.first
        switch action {
        case .email:
            MailComposeView(
                recipients: [invoice.recipientEmail],
                subject: InvoiceMessage.subject(invoice: invoice, business: business),
                body: InvoiceMessage.htmlBody(invoice: invoice, business: business),
                isHTML: true,
                attachmentURL: pdfURL
            ) { sendAction = nil }
        case .text:
            MessageComposeView(
                recipients: [invoice.recipientPhone],
                body: InvoiceMessage.plainBody(invoice: invoice, business: business),
                attachmentURLs: [EstimateMessage.logoAttachmentURL(business: business), pdfURL].compactMap { $0 }
            ) { sendAction = nil }
        }
    }

    private func regeneratePDF() {
        if let profile = businessProfiles.first, profile.isComplete {
            pdfURL = InvoicePDF.render(invoice, business: profile)
        } else {
            pdfURL = nil
        }
    }

    private var headerCard: some View {
        card {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(invoice.jobTitle.isEmpty ? String(localized: "Untitled invoice") : invoice.jobTitle)
                        .font(.title3.weight(.semibold))
                    Text(invoice.number)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    if let source = invoice.sourceEstimateNumber, !source.isEmpty {
                        Text("From \(source)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                InvoiceStatusBadge(invoice: invoice)
            }
            Divider()
            labeledRow(String(localized: "Created"), invoice.createdAt.formatted(date: .abbreviated, time: .omitted))
            labeledRow(String(localized: "Terms"), invoice.paymentTerms.label)
            labeledRow(String(localized: "Due"), invoice.dueDate.formatted(date: .abbreviated, time: .omitted))
        }
    }

    private var customerCard: some View {
        card {
            Text("Billed to")
                .font(.headline)
            Text(invoice.customerDisplayName)
                .font(.body.weight(.medium))
            if let business = invoice.customerBusinessName, !business.isEmpty {
                Text(business).foregroundStyle(.secondary)
            }
            let address = formattedAddress
            if !address.isEmpty {
                Text(address).foregroundStyle(.secondary)
            }
            if !invoice.customerEmail.isEmpty {
                Text(invoice.customerEmail).foregroundStyle(.secondary)
            }
            if !invoice.customerPhone.isEmpty {
                Text(invoice.customerPhone).foregroundStyle(.secondary)
            }
        }
    }

    private var serviceAddressCard: some View {
        card {
            Text("Service Address")
                .font(.headline)
            Text(invoice.serviceAddress.formattedMultiline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var groupsView: some View {
        ForEach(invoice.sortedGroups) { group in
            card {
                Text(group.name.isEmpty ? String(localized: "Line Items") : group.name)
                    .font(.headline)
                if !group.note.isEmpty {
                    Text(group.note).font(.subheadline).foregroundStyle(.secondary)
                }
                let items = group.sortedLineItems
                ForEach(items) { item in
                    lineItemRow(item)
                    if item.id != items.last?.id {
                        Divider()
                    }
                }
                if !group.name.isEmpty || invoice.sortedGroups.count > 1 {
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

    private func lineItemRow(_ item: InvoiceLineItem) -> some View {
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
            totalRow(String(localized: "Subtotal"), invoice.subtotal)
            if invoice.discountAmount > 0 { totalRow(String(localized: "Discount"), -invoice.discountAmount) }
            if invoice.taxAmount > 0 { totalRow(String(localized: "Tax") + " (\(invoice.taxRatePercent.formatted())%)", invoice.taxAmount) }
            Divider()
            totalRow(String(localized: "Total"), invoice.total, bold: true)
            if invoice.amountPaid > 0 {
                totalRow(String(localized: "Paid"), -invoice.amountPaid)
            }
            HStack {
                Text("Balance").foregroundStyle(.secondary)
                Spacer()
                Text(invoice.balanceDue.formatted(.currency(code: "USD")))
                    .foregroundStyle(invoice.isPaid ? .green : .primary)
            }
            .font(.subheadline)
            if invoice.hasAmountDueRequest {
                Divider()
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Amount due now").fontWeight(.bold)
                        if !invoice.amountDueDetail.isEmpty {
                            Text(invoice.amountDueDetail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Text(invoice.currentAmountDue.formatted(.currency(code: "USD")))
                        .fontWeight(.bold)
                        .foregroundStyle(gold)
                }
            }
        }
    }

    private var paymentsCard: some View {
        card {
            let payments = invoice.sortedPayments
            Text("Payments").font(.headline)
            if payments.isEmpty {
                Text("No payments recorded yet.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(payments) { payment in
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(payment.method.label)
                            HStack(spacing: 6) {
                                Text(payment.date.formatted(date: .abbreviated, time: .omitted))
                                if !payment.note.isEmpty {
                                    Text("· \(payment.note)").lineLimit(1)
                                }
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(payment.amount.formatted(.currency(code: "USD")))
                            .fontWeight(.medium)
                    }
                    .font(.subheadline)
                    if payment.id != payments.last?.id {
                        Divider()
                    }
                }
            }
        }
    }

    private var changeOrdersCard: some View {
        card {
            let orders = invoice.sortedChangeOrders
            Text("Change Orders").font(.headline)
            if orders.isEmpty {
                Text("None yet. Add one from the ••• menu when the job's scope changes.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                if invoice.approvedChangeOrderTotal != 0 {
                    HStack {
                        Text("Revised total").foregroundStyle(.secondary)
                        Spacer()
                        Text(invoice.revisedTotal.formatted(.currency(code: "USD"))).fontWeight(.semibold)
                    }
                    .font(.subheadline)
                    Divider()
                }
                ForEach(orders) { changeOrder in
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(changeOrder.title.isEmpty ? changeOrder.number : changeOrder.title)
                                .fontWeight(.medium)
                                .lineLimit(1)
                            HStack(spacing: 6) {
                                Text(changeOrder.number)
                                Text("· \(changeOrder.status.label)")
                                if changeOrder.appliedToInvoice { Text("· added") }
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text((changeOrder.total >= 0 ? "+" : "") + changeOrder.total.formatted(.currency(code: "USD")))
                            .fontWeight(.medium)
                    }
                    .font(.subheadline)
                    if changeOrder.id != orders.last?.id {
                        Divider()
                    }
                }
            }
        }
    }

    private var notesCard: some View {
        card {
            if !invoice.customerNotes.isEmpty {
                Text("Notes").font(.headline)
                Text(invoice.customerNotes).foregroundStyle(.secondary)
            }
            if !invoice.terms.isEmpty {
                Text("Terms").font(.headline).padding(.top, invoice.customerNotes.isEmpty ? 0 : 6)
                Text(invoice.terms).font(.footnote).foregroundStyle(.secondary)
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

    private var formattedAddress: String {
        let a = invoice.customerAddress
        let cityLine = [a.city, a.state].filter { !$0.isEmpty }.joined(separator: ", ")
        let cityZip = [cityLine, a.postalCode].filter { !$0.isEmpty }.joined(separator: " ")
        return [a.street1, a.street2 ?? "", cityZip]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }
}

// MARK: - Record payment

private struct RecordPaymentSheet: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    let invoice: Invoice

    @State private var amount: Double
    @State private var date = Date.now
    @State private var method: PaymentMethod = .check
    @State private var note = ""

    init(invoice: Invoice) {
        self.invoice = invoice
        _amount = State(initialValue: invoice.balanceDue)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Payment") {
                    LabeledContent("Amount") {
                        AutoClearNumberField(placeholder: "0", value: $amount, style: .currency, clearsAt: 0)
                            .multilineTextAlignment(.trailing)
                    }
                    DatePicker("Date", selection: $date, displayedComponents: .date)
                    Picker("Method", selection: $method) {
                        ForEach(PaymentMethod.allCases) { Text($0.label).tag($0) }
                    }
                    TextField("Note (optional)", text: $note)
                }
            }
            .glFormBackground()
            .navigationTitle("Record Payment")
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save).disabled(amount <= 0)
                }
            }
        }
    }

    private func save() {
        let payment = InvoicePayment(
            amount: amount,
            date: date,
            method: method,
            note: note.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        payment.invoice = invoice
        modelContext.insert(payment)
        // Draw down the current "amount due now" request as it gets paid, so it never goes stale.
        if invoice.amountDueNow > 0 {
            invoice.amountDueNow = max(0, invoice.amountDueNow - amount)
            if invoice.amountDueNow <= 0.005 { invoice.amountDueDetail = "" }
        }
        dismiss()
    }
}

// MARK: - Set amount due (milestone request)

private struct SetAmountDueSheet: View {
    @Environment(\.dismiss) private var dismiss
    let invoice: Invoice

    @State private var amount: Double
    @State private var detail: String

    init(invoice: Invoice) {
        self.invoice = invoice
        _amount = State(initialValue: invoice.amountDueNow)
        _detail = State(initialValue: invoice.amountDueDetail)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Amount due now") {
                        AutoClearNumberField(placeholder: "0", value: $amount, style: .currency, clearsAt: 0)
                            .multilineTextAlignment(.trailing)
                    }
                    TextField("What it's for (e.g. 30% progress payment)", text: $detail)
                } footer: {
                    Text("What you're asking the customer to pay now. Leave at $0 to request the full balance of \(invoice.balanceDue.formatted(.currency(code: "USD"))).")
                }
            }
            .glFormBackground()
            .navigationTitle("Amount Due")
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                }
            }
        }
    }

    private func save() {
        invoice.amountDueNow = amount
        invoice.amountDueDetail = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        dismiss()
    }
}

// MARK: - Payment receipt

/// Previews the payment receipt (the W-9-style flow: see it, then send) and sends it to the
/// customer by email/text or shares the PDF. Receipt wording shows the remaining balance as
/// information, never as an amount due.
private struct PaymentReceiptSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @Query private var businessProfiles: [BusinessProfile]
    let invoice: Invoice
    let payment: InvoicePayment

    @State private var pdfURL: URL?
    @State private var pdfData: Data?
    @State private var sendAction: SendAction?

    private enum SendAction: Int, Identifiable { case email, text; var id: Int { rawValue } }
    private var gold: Color { GLColor.gold.render(in: colorScheme) }
    private var business: BusinessProfile? { businessProfiles.first }

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                if let pdfData {
                    CertificatePreview(data: pdfData)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                        .overlay(RoundedRectangle(cornerRadius: 14).stroke(.black.opacity(0.12)))
                } else {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
            }
            .padding()
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
            .background { GLColor.backgroundPrimary.render(in: colorScheme).ignoresSafeArea() }
            .navigationTitle("Payment Receipt")
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button(role: .close) { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        if !invoice.customerEmail.isEmpty && MFMailComposeViewController.canSendMail() {
                            Button { sendAction = .email } label: { Label("Email receipt", systemImage: "envelope") }
                        }
                        if !invoice.customerPhone.isEmpty && MFMessageComposeViewController.canSendText() {
                            Button { sendAction = .text } label: { Label("Text receipt", systemImage: "message") }
                        }
                        if let pdfURL {
                            ShareLink(item: pdfURL) { Label("Share receipt…", systemImage: "square.and.arrow.up") }
                        }
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .tint(gold)
                }
            }
            .onAppear { regenerate() }
            .sheet(item: $sendAction) { action in sendSheet(action).glAppearance(colorScheme) }
        }
    }

    private func regenerate() {
        guard let url = PaymentReceiptPDF.render(invoice, payment: payment, business: business) else { return }
        pdfURL = url
        pdfData = try? Data(contentsOf: url)
    }

    @ViewBuilder
    private func sendSheet(_ action: SendAction) -> some View {
        switch action {
        case .email:
            MailComposeView(
                recipients: [invoice.recipientEmail],
                subject: PaymentReceiptMessage.subject(invoice: invoice, business: business),
                body: PaymentReceiptMessage.htmlBody(invoice: invoice, payment: payment, business: business),
                isHTML: true,
                attachmentURL: pdfURL
            ) { sendAction = nil }
        case .text:
            MessageComposeView(
                recipients: [invoice.recipientPhone],
                body: PaymentReceiptMessage.plainBody(invoice: invoice, payment: payment, business: business),
                attachmentURLs: [pdfURL].compactMap { $0 }
            ) { sendAction = nil }
        }
    }
}

#Preview {
    let invoice = Invoice(jobTitle: "Master bath tile install", customer: Customer(firstName: "Jane", lastName: "Doe"))
    invoice.number = "INV-0001"
    return NavigationStack {
        InvoiceDetailScreen(invoice: invoice)
    }
    .modelContainer(for: [Customer.self, Invoice.self], inMemory: true)
}
