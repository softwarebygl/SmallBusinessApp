//
//  SubcontractorDetailScreen.swift
//  GLSmallBusiness
//
//  Created by Gold Life LLC on 6/21/26.
//
//  One subcontractor: the year-to-date 1099 status up top, then the payment history. Payments are
//  added/edited through the sheet at the bottom. Mirrors EmployeeDetailScreen's scaffold.
//

import SwiftUI
import SwiftData

struct SubcontractorDetailScreen: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.modelContext) private var modelContext
    let subcontractor: Subcontractor

    @State private var activeSheet: ActiveSheet?

    private enum ActiveSheet: Identifiable {
        case edit
        case payment(SubPayment?)
        case form1099
        var id: String {
            switch self {
            case .edit: "edit"
            case .payment(let p): "payment-\(p?.persistentModelID.hashValue ?? 0)"
            case .form1099: "1099"
            }
        }
    }

    private var gold: Color { GLColor.gold.render(in: colorScheme) }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                header
                statusCard
                w9Card
                paymentsCard
                if !subcontractor.notes.isEmpty { notesCard }
            }
            .padding()
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
        }
        .containerBackground(for: .navigation) { PrimaryBackground() }
        .navigationTitle(subcontractor.listDisplayName)
        .toolbarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { activeSheet = .edit } label: { Image(systemName: "pencil") }
                    .accessibilityLabel("Edit subcontractor")
            }
        }
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .edit:
                SubcontractorFormScreen(editing: subcontractor).glAppearance(colorScheme)
            case .payment(let payment):
                RecordSubPaymentSheet(subcontractor: subcontractor, existing: payment).glAppearance(colorScheme)
            case .form1099:
                Form1099NECSheet(subcontractor: subcontractor).glAppearance(colorScheme)
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle().fill(gold.opacity(0.18))
                Text(subcontractor.initials)
                    .font(.system(size: 36, weight: .semibold))
                    .foregroundStyle(gold)
            }
            .frame(width: 96, height: 96)

            Text(subcontractor.payeeName.isEmpty ? subcontractor.listDisplayName : subcontractor.payeeName)
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)

            if !subcontractor.businessName.isEmpty && !subcontractor.fullName.isEmpty {
                Text(subcontractor.fullName).font(.subheadline).foregroundStyle(.secondary)
            }

            if !subcontractor.isActive {
                Text("Inactive")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(Capsule().fill(Color.secondary.opacity(0.18)))
            }
        }
    }

    // MARK: - 1099 status

    private var statusCard: some View {
        let year = Calendar.current.component(.year, from: .now)
        let total = subcontractor.totalPaid(year: year)
        let needs1099 = subcontractor.requires1099(year: year)
        return GLCard {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("PAID IN \(String(year))")
                        .font(.caption2.weight(.semibold)).tracking(0.5).foregroundStyle(.secondary)
                    Text(total.formatted(.currency(code: "USD")))
                        .font(.title3.weight(.semibold)).foregroundStyle(gold)
                }
                Spacer()
                if needs1099 {
                    Label("1099-NEC", systemImage: "doc.badge.ellipsis")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(gold)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(Capsule().fill(gold.opacity(0.16)))
                }
            }
            Text(needs1099
                 ? "At or over the $600 threshold — a 1099-NEC is required this year."
                 : "Under the $600 threshold. No 1099-NEC required yet.")
                .font(.footnote).foregroundStyle(.secondary)
            Button { activeSheet = .payment(nil) } label: {
                Label("Record a payment", systemImage: "plus.circle")
                    .font(.subheadline.weight(.semibold)).foregroundStyle(gold)
            }
            .buttonStyle(.plain)
            .padding(.top, 2)
        }
    }

    // MARK: - W-9 & Tax ID

    private var w9Card: some View {
        GLCard(title: "W-9 & Tax ID") {
            HStack {
                Text("Tax ID").foregroundStyle(.secondary)
                Spacer()
                if subcontractor.hasTIN {
                    Text("\(subcontractor.w9TINType?.label ?? "TIN") \(subcontractor.maskedTIN)")
                } else {
                    Text("Not on file — add via Edit").foregroundStyle(.secondary)
                }
            }
            .font(.subheadline)
            Divider()
            NavigationLink {
                SubcontractorW9DetailScreen(subcontractor: subcontractor)
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "doc.plaintext").frame(width: 24).foregroundStyle(gold)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("W-9 on file")
                        Text(subcontractor.hasW9OnFile ? subcontractor.w9Name : "Tap to upload theirs")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                    Spacer()
                    if subcontractor.hasW9OnFile {
                        Image(systemName: "checkmark.seal.fill").font(.footnote).foregroundStyle(gold)
                    }
                    Image(systemName: "chevron.right").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                }
                .font(.subheadline)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Divider()
            Button { activeSheet = .form1099 } label: {
                Label("Generate 1099-NEC", systemImage: "doc.badge.plus")
                    .font(.subheadline.weight(.semibold)).foregroundStyle(gold)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Payments

    private var paymentsCard: some View {
        GLCard(title: "Payments") {
            let payments = subcontractor.sortedPayments
            if payments.isEmpty {
                Text("No payments recorded yet.")
                    .font(.subheadline).foregroundStyle(.secondary)
            } else {
                ForEach(payments.prefix(12)) { payment in
                    Button { activeSheet = .payment(payment) } label: { paymentRow(payment) }
                        .buttonStyle(.plain)
                    if payment.id != payments.prefix(12).last?.id { Divider() }
                }
                if payments.count > 12 {
                    Text("Showing the 12 most recent of \(payments.count).")
                        .font(.caption).foregroundStyle(.secondary).padding(.top, 2)
                }
            }
        }
    }

    private func paymentRow(_ payment: SubPayment) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(payment.date.formatted(date: .abbreviated, time: .omitted))
                if !payment.detail.isEmpty {
                    Text(payment.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                } else if let customer = payment.customer {
                    Text(customer.listDisplayName).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Text(payment.amount.formatted(.currency(code: "USD"))).foregroundStyle(.secondary)
            Image(systemName: "chevron.right").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
        }
        .font(.subheadline)
        .contentShape(Rectangle())
    }

    private var notesCard: some View {
        GLCard(title: "Notes") {
            Text(subcontractor.notes).font(.subheadline)
        }
    }
}

// MARK: - W-9 document (view / upload / replace / remove)

/// A thin wrapper over the shared `DocumentDetailScreen`, backed by the subcontractor's uploaded
/// W-9 PDF — mirrors `CustomerCOIDetailScreen`.
struct SubcontractorW9DetailScreen: View {
    @Query private var profiles: [BusinessProfile]
    let subcontractor: Subcontractor

    var body: some View {
        DocumentDetailScreen(slot: DocumentSlot(
            title: String(localized: "W-9"),
            data: subcontractor.w9Data,
            name: subcontractor.w9Name,
            fallbackFileName: "W-9.pdf",
            businessName: profiles.first?.businessName ?? "",
            removeTitle: "Remove W-9",
            removeSubtitle: "Delete this subcontractor's uploaded W-9.",
            store: { subcontractor.w9Data = $0; subcontractor.w9Name = $1 }
        ))
    }
}

// MARK: - 1099-NEC sheet (generate the real IRS Copy B)

private struct Form1099NECSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @Query private var profiles: [BusinessProfile]
    let subcontractor: Subcontractor

    @State private var pdfURL: URL?
    @State private var previewImage: UIImage?
    @State private var showingEditSub = false
    @State private var showingEditBusiness = false

    private var gold: Color { GLColor.gold.render(in: colorScheme) }
    private var business: BusinessProfile? { profiles.first }
    private var year: Int { Calendar.current.component(.year, from: .now) }
    private var amount: Double { subcontractor.totalPaid(year: year) }

    /// What's still needed before a valid 1099-NEC can be produced.
    private var missing: [String] {
        var items: [String] = []
        let name = (business?.w9LegalName.isEmpty == false ? business?.w9LegalName : business?.businessName) ?? ""
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { items.append("Your business name") }
        if business?.secureTIN.filter(\.isNumber).count != 9 { items.append("Your business Tax ID") }
        if subcontractor.secureTIN.filter(\.isNumber).count != 9 {
            items.append("\(subcontractor.payeeName)'s Tax ID (from their W-9)")
        }
        return items
    }
    private var canGenerate: Bool { missing.isEmpty }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    if canGenerate, let previewImage {
                        Image(uiImage: previewImage)
                            .resizable().scaledToFit()
                            .frame(maxWidth: .infinity)
                            .background(Color.white)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .overlay(RoundedRectangle(cornerRadius: 12).stroke(.black.opacity(0.1)))
                            .shadow(radius: 4, y: 2)
                        Text("Copy B — give this to \(subcontractor.payeeName). Keep a copy for your records. File Copy A with the IRS yourself (e-file) or hand your accountant the Year-End Report.")
                            .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    } else {
                        missingCard
                    }
                }
                .padding()
                .frame(maxWidth: 640)
                .frame(maxWidth: .infinity)
            }
            .background { GLColor.backgroundPrimary.render(in: colorScheme).ignoresSafeArea() }
            .navigationTitle("1099-NEC")
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button(role: .close) { dismiss() } }
                if let pdfURL {
                    ToolbarItem(placement: .topBarTrailing) {
                        ShareLink(item: pdfURL,
                                  subject: Text("Form 1099-NEC — \(year)"),
                                  message: Text("Attached is your \(year) Form 1099-NEC.")) {
                            Image(systemName: "square.and.arrow.up")
                        }
                        .tint(gold)
                    }
                }
            }
            .onAppear { regenerate() }
            .sheet(isPresented: $showingEditSub, onDismiss: regenerate) {
                SubcontractorFormScreen(editing: subcontractor).glAppearance(colorScheme)
            }
            .sheet(isPresented: $showingEditBusiness, onDismiss: regenerate) {
                if let business { MyCompanyFormScreen(profile: business).glAppearance(colorScheme) }
            }
        }
    }

    private var missingCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Add a few details first", systemImage: "exclamationmark.circle")
                .font(.headline).foregroundStyle(gold)
            Text("A 1099-NEC needs the following before it can be generated:")
                .font(.subheadline).foregroundStyle(.secondary)
            ForEach(missing, id: \.self) { item in
                Label(item, systemImage: "circle").font(.subheadline).labelStyle(.titleAndIcon)
            }
            if subcontractor.secureTIN.filter(\.isNumber).count != 9 {
                Button { showingEditSub = true } label: {
                    Label("Edit \(subcontractor.payeeName)", systemImage: "pencil")
                        .font(.subheadline.weight(.semibold)).foregroundStyle(gold)
                }
                .buttonStyle(.plain)
            }
            if business != nil {
                Button { showingEditBusiness = true } label: {
                    Label("Edit business details", systemImage: "building.2")
                        .font(.subheadline.weight(.semibold)).foregroundStyle(gold)
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .glCardBackground()
    }

    private func regenerate() {
        guard canGenerate, let business else { pdfURL = nil; previewImage = nil; return }
        pdfURL = Form1099NECPDF.render(payer: business, recipient: subcontractor, amount: amount, year: year)
        previewImage = pdfURL.flatMap { Form1099NECPDF.pageImage(from: $0) }
    }
}

// MARK: - Record payment sheet

private struct RecordSubPaymentSheet: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: [SortDescriptor(\Customer.lastName), SortDescriptor(\Customer.firstName)])
    private var customers: [Customer]

    let subcontractor: Subcontractor
    let existing: SubPayment?

    @State private var amount: Double
    @State private var date: Date
    @State private var method: PaymentMethod
    @State private var detail: String
    @State private var customerID: PersistentIdentifier?

    init(subcontractor: Subcontractor, existing: SubPayment?) {
        self.subcontractor = subcontractor
        self.existing = existing
        _amount = State(initialValue: existing?.amount ?? 0)
        _date = State(initialValue: existing?.date ?? .now)
        _method = State(initialValue: existing?.method ?? .check)
        _detail = State(initialValue: existing?.detail ?? "")
        _customerID = State(initialValue: existing?.customer?.persistentModelID)
    }

    private var selectedCustomer: Customer? {
        customers.first { $0.persistentModelID == customerID }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Amount") {
                        AutoClearNumberField(placeholder: "$0.00", value: $amount, style: .currency)
                            .multilineTextAlignment(.trailing)
                    }
                    DatePicker("Date", selection: $date, displayedComponents: .date)
                    Picker("Method", selection: $method) {
                        ForEach(PaymentMethod.allCases) { Text($0.label).tag($0) }
                    }
                }
                Section("For") {
                    TextField("What was this for? (optional)", text: $detail, axis: .vertical)
                        .lineLimit(1...4)
                    Picker("Job / customer", selection: $customerID) {
                        Text("None").tag(PersistentIdentifier?.none)
                        ForEach(customers) { customer in
                            Text(customer.listDisplayName).tag(PersistentIdentifier?.some(customer.persistentModelID))
                        }
                    }
                }
                if existing != nil {
                    Section {
                        Button(role: .destructive) { delete() } label: { Text("Delete payment") }
                    }
                }
            }
            .glFormBackground()
            .navigationTitle(existing == nil ? "Record Payment" : "Edit Payment")
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save).disabled(amount <= 0)
                }
            }
        }
    }

    private func save() {
        if let payment = existing {
            payment.amount = amount
            payment.date = date
            payment.method = method
            payment.detail = detail.trimmingCharacters(in: .whitespacesAndNewlines)
            payment.customer = selectedCustomer
        } else {
            let payment = SubPayment(
                amount: amount, date: date, method: method,
                detail: detail.trimmingCharacters(in: .whitespacesAndNewlines),
                subcontractor: subcontractor, customer: selectedCustomer
            )
            modelContext.insert(payment)
        }
        try? modelContext.save()
        dismiss()
    }

    private func delete() {
        if let payment = existing { modelContext.delete(payment); try? modelContext.save() }
        dismiss()
    }
}
