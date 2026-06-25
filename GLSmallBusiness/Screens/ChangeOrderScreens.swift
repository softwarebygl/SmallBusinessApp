//
//  ChangeOrderScreens.swift
//  GLSmallBusiness
//
//  Create / edit a change order, and a detail sheet to preview, send, approve, and (once approved)
//  push it onto the invoice as a new line-item group.
//

import SwiftUI
import SwiftData
import MessageUI

// MARK: - Form

struct ChangeOrderFormScreen: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    let invoice: Invoice
    var editing: ChangeOrder?

    @State private var title: String
    @State private var note: String
    @State private var items: [DraftItem]

    struct DraftItem: Identifiable {
        let id = UUID()
        var name = ""
        var quantity: Double = 1
        var unit: UnitOfMeasure = .job
        var unitPrice: Double = 0
        var isCredit = false
        var isTaxable = false
        /// Signed total — credits subtract from the change order (removed work).
        var lineTotal: Double { quantity * abs(unitPrice) * (isCredit ? -1 : 1) }
    }

    init(invoice: Invoice, editing: ChangeOrder? = nil) {
        self.invoice = invoice
        self.editing = editing
        _title = State(initialValue: editing?.title ?? "")
        _note = State(initialValue: editing?.note ?? "")
        if let editing, !editing.sortedLineItems.isEmpty {
            _items = State(initialValue: editing.sortedLineItems.map {
                DraftItem(name: $0.name, quantity: $0.quantity, unit: $0.unit,
                          unitPrice: abs($0.unitPrice), isCredit: $0.unitPrice < 0, isTaxable: $0.isTaxable)
            })
        } else {
            _items = State(initialValue: [DraftItem()])
        }
    }

    private var changeTotal: Double {
        let subtotal = items.reduce(0) { $0 + $1.lineTotal }
        let taxable = items.filter { $0.isTaxable }.reduce(0) { $0 + $1.lineTotal }
        return subtotal + taxable * invoice.taxRatePercent / 100
    }
    private func money(_ v: Double) -> String { v.formatted(.currency(code: "USD")) }
    private func signed(_ v: Double) -> String { (v >= 0 ? "+" : "") + money(v) }

    var body: some View {
        Form {
            Section {
                TextField("Summary (e.g. Add second coat of sealer)", text: $title)
            } header: {
                InfoLabel("Change Order", info: "Set an item to Credit to subtract for removed work.")
            }

            Section("Items") {
                ForEach($items) { $item in
                    itemEditor($item)
                }
                .onDelete { items.remove(atOffsets: $0) }
                Button {
                    items.append(DraftItem())
                } label: {
                    Label("Add line item", systemImage: "plus.circle.fill")
                }
            }

            Section {
                TextField("Notes (optional)", text: $note, axis: .vertical)
            } footer: {
                HStack {
                    Text("This change")
                    Spacer()
                    Text(signed(changeTotal)).fontWeight(.semibold)
                }
                .font(.subheadline)
                .foregroundStyle(.primary)
            }
        }
        .glFormBackground()
        .navigationTitle(editing == nil ? "New Change Order" : "Edit Change Order")
        .toolbarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                SaveOnceButton(disabled: !canSave, action: save)
            }
        }
    }

    private var canSave: Bool {
        items.contains { !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    @ViewBuilder
    private func itemEditor(_ item: Binding<DraftItem>) -> some View {
        VStack(spacing: 10) {
            TextField("Description", text: item.name)
            HStack {
                AutoClearNumberField(placeholder: "1", value: item.quantity, style: .number, clearsAt: 0)
                    .frame(width: 56)
                Picker("", selection: item.unit) {
                    ForEach(UnitOfMeasure.allCases) { Text($0.abbreviation).tag($0) }
                }
                .labelsHidden()
                Spacer()
                if item.wrappedValue.isCredit {
                    Text("−").foregroundStyle(.red)
                }
                AutoClearNumberField(placeholder: "0", value: item.unitPrice, style: .currency, clearsAt: 0)
                    .multilineTextAlignment(.trailing)
            }
            Picker("", selection: item.isCredit) {
                Text("Charge").tag(false)
                Text("Credit").tag(true)
            }
            .pickerStyle(.segmented)
            Toggle("Taxable", isOn: item.isTaxable)
                .font(.subheadline)
        }
        .padding(.vertical, 4)
    }

    private func save() {
        let target: ChangeOrder
        if let editing {
            target = editing
            // Replace line items.
            for old in editing.sortedLineItems { modelContext.delete(old) }
        } else {
            let co = ChangeOrder(
                number: ChangeOrder.nextNumber(after: invoice.sortedChangeOrders),
                title: "",
                taxRatePercent: invoice.taxRatePercent
            )
            co.invoice = invoice
            modelContext.insert(co)
            target = co
        }
        target.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        target.note = note.trimmingCharacters(in: .whitespacesAndNewlines)
        target.taxRatePercent = invoice.taxRatePercent

        for (index, draft) in items.enumerated() where !draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let li = ChangeOrderLineItem(
                name: draft.name.trimmingCharacters(in: .whitespacesAndNewlines),
                quantity: draft.quantity,
                unit: draft.unit,
                unitPrice: (draft.isCredit ? -1 : 1) * abs(draft.unitPrice),
                isTaxable: draft.isTaxable,
                sortIndex: index
            )
            li.changeOrder = target
            modelContext.insert(li)
        }
        modelContext.saveChanges()
        dismiss()
    }
}

// MARK: - Detail

struct ChangeOrderDetailSheet: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @Query private var businessProfiles: [BusinessProfile]
    @Bindable var changeOrder: ChangeOrder

    @State private var pdfURL: URL?
    @State private var pdfData: Data?
    @State private var generationFailed = false
    @State private var sendAction: SendAction?
    @State private var sendFailureMessage: String?
    @State private var showingEdit = false
    @State private var confirmDelete = false

    private enum SendAction: Int, Identifiable { case email, text; var id: Int { rawValue } }
    private var gold: Color { GLColor.gold.render(in: colorScheme) }
    private var business: BusinessProfile? { businessProfiles.first }
    private var invoice: Invoice? { changeOrder.invoice }
    private var canApply: Bool { changeOrder.status == .approved && !changeOrder.appliedToInvoice }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    if let pdfData {
                        CertificatePreview(data: pdfData)
                            .frame(height: 460)
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                            .overlay(RoundedRectangle(cornerRadius: 14).stroke(.black.opacity(0.12)))
                    } else if generationFailed {
                        DocumentGenerationError { regenerate() }.frame(height: 460)
                    } else {
                        ProgressView().frame(height: 460)
                    }

                    GLCard(title: "Status") {
                        Picker("Status", selection: $changeOrder.status) {
                            ForEach(ChangeOrderStatus.allCases) { Text($0.label).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }

                    if changeOrder.appliedToInvoice {
                        Label("Added to invoice", systemImage: "checkmark.circle.fill")
                            .font(.subheadline).foregroundStyle(.green)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding().glCardBackground()
                    } else if canApply {
                        DocActionRow(title: "Add items to invoice",
                                     subtitle: "Append this change to the invoice's line items.",
                                     systemImage: "plus.rectangle.on.rectangle") { addToInvoice() }
                    }

                    DocActionRow(title: "Edit change order",
                                 subtitle: "Update the summary, items, or notes.",
                                 systemImage: "square.and.pencil") { showingEdit = true }

                    Button(role: .destructive) { confirmDelete = true } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "trash").font(.title3).frame(width: 28).foregroundStyle(.red)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Delete change order").font(.subheadline.weight(.semibold)).foregroundStyle(.red)
                                Text("Remove this change order.").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 8)
                        }
                        .padding().frame(maxWidth: .infinity, alignment: .leading).glCardBackground()
                    }
                    .buttonStyle(.plain)
                }
                .padding()
                .frame(maxWidth: 640)
                .frame(maxWidth: .infinity)
            }
            .background { GLColor.backgroundPrimary.render(in: colorScheme).ignoresSafeArea() }
            .navigationTitle(changeOrder.number.isEmpty ? String(localized: "Change Order") : changeOrder.number)
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button(role: .close) { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        if let invoice, !invoice.customerEmail.isEmpty && MFMailComposeViewController.canSendMail() {
                            Button { sendAction = .email } label: { Label("Email change order", systemImage: "envelope") }
                        }
                        if let invoice, !invoice.customerPhone.isEmpty && MFMessageComposeViewController.canSendText() {
                            Button { sendAction = .text } label: { Label("Text change order", systemImage: "message") }
                        }
                        if let pdfURL {
                            ShareLink(item: pdfURL) { Label("Share change order…", systemImage: "square.and.arrow.up") }
                        }
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .tint(gold)
                }
            }
            .onAppear { regenerate() }
            .onChange(of: changeOrder.statusRaw) { _, _ in regenerate() }
            .onChange(of: showingEdit) { _, isShowing in if !isShowing { regenerate() } }
            .navigationDestination(isPresented: $showingEdit) {
                if let invoice {
                    ChangeOrderFormScreen(invoice: invoice, editing: changeOrder)
                }
            }
            .sheet(item: $sendAction) { action in sendSheet(action).glAppearance(colorScheme) }
            .alert("Couldn’t send", isPresented: Binding(get: { sendFailureMessage != nil },
                                                         set: { if !$0 { sendFailureMessage = nil } })) {
                Button("OK", role: .cancel) { sendFailureMessage = nil }
            } message: {
                Text(sendFailureMessage ?? "")
            }
            .confirmationDialog("Delete this change order?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    modelContext.delete(changeOrder)
                    dismiss()
                }
            }
        }
    }

    private func regenerate() {
        guard let url = ChangeOrderPDF.render(changeOrder, business: business),
              let data = try? Data(contentsOf: url) else {
            generationFailed = true
            return
        }
        pdfURL = url
        pdfData = data
        generationFailed = false
    }

    private func addToInvoice() {
        guard let invoice else { return }
        let name = changeOrder.title.isEmpty ? changeOrder.number : "\(changeOrder.number): \(changeOrder.title)"
        let group = InvoiceGroup(name: name, sortIndex: (invoice.sortedGroups.last?.sortIndex ?? 0) + 1)
        group.invoice = invoice
        modelContext.insert(group)
        for (index, item) in changeOrder.sortedLineItems.enumerated() {
            let li = InvoiceLineItem(
                name: item.name, details: item.details, quantity: item.quantity,
                unit: item.unit, unitPrice: item.unitPrice, kind: .labor,
                isTaxable: item.isTaxable, sortIndex: index
            )
            li.group = group
            modelContext.insert(li)
        }
        changeOrder.appliedToInvoice = true
    }

    @ViewBuilder
    private func sendSheet(_ action: SendAction) -> some View {
        if let invoice {
            switch action {
            case .email:
                MailComposeView(
                    recipients: [invoice.recipientEmail],
                    subject: ChangeOrderMessage.subject(changeOrder, business: business),
                    body: ChangeOrderMessage.htmlBody(changeOrder, business: business),
                    isHTML: true,
                    attachmentURL: pdfURL
                ) { outcome in sendAction = nil; noteSend(outcome) }
            case .text:
                MessageComposeView(
                    recipients: [invoice.recipientPhone],
                    body: ChangeOrderMessage.plainBody(changeOrder, business: business),
                    attachmentURLs: [pdfURL].compactMap { $0 }
                ) { outcome in sendAction = nil; noteSend(outcome) }
            }
        }
    }

    private func noteSend(_ outcome: SendOutcome) {
        if outcome == .failed {
            sendFailureMessage = "We couldn’t send your change order. Check your internet connection and try again."
        }
    }
}
