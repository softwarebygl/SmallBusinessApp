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
    @State private var showingSaveToContacts = false

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
                balanceCard
                w9Card
                activityCard
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
                Menu {
                    Button { activeSheet = .edit } label: { Label("Edit subcontractor", systemImage: "pencil") }
                    Button { showingSaveToContacts = true } label: {
                        Label("Save to Contacts", systemImage: "person.crop.circle.badge.plus")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .accessibilityLabel("More")
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
        .sheet(isPresented: $showingSaveToContacts) {
            NewContactView(contact: ContactsBridge.contact(from: subcontractor)) { showingSaveToContacts = false }
                .ignoresSafeArea()
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

    // MARK: - Balance (owed + paid this year)

    private var balanceCard: some View {
        let year = Calendar.current.component(.year, from: .now)
        let owed = subcontractor.outstanding
        let paid = subcontractor.totalPaid(year: year)
        let needs1099 = subcontractor.requires1099(year: year)
        return GLCard {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("OWED (UNPAID)")
                        .font(.caption2.weight(.semibold)).tracking(0.5).foregroundStyle(.secondary)
                    Text(owed.formatted(.currency(code: "USD")))
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(owed > 0.005 ? gold : .secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    Text("PAID IN \(String(year))")
                        .font(.caption2.weight(.semibold)).tracking(0.5).foregroundStyle(.secondary)
                    Text(paid.formatted(.currency(code: "USD")))
                        .font(.title3.weight(.semibold))
                    if needs1099 {
                        Text("1099-NEC due")
                            .font(.caption2.weight(.bold)).foregroundStyle(gold)
                    }
                }
            }
            Button { activeSheet = .payment(nil) } label: {
                Label("Record what you owe", systemImage: "plus.circle")
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

    // MARK: - Activity (owed + paid entries)

    private var activityCard: some View {
        GLCard(title: "Activity") {
            let entries = subcontractor.sortedPayments
            if entries.isEmpty {
                Text("Nothing recorded yet. Tap “Record what you owe” above.")
                    .font(.subheadline).foregroundStyle(.secondary)
            } else {
                ForEach(entries.prefix(12)) { entry in
                    Button { activeSheet = .payment(entry) } label: { entryRow(entry) }
                        .buttonStyle(.plain)
                    if entry.id != entries.prefix(12).last?.id { Divider() }
                }
                if entries.count > 12 {
                    Text("Showing the 12 most recent of \(entries.count).")
                        .font(.caption).foregroundStyle(.secondary).padding(.top, 2)
                }
            }
        }
    }

    private func entryRow(_ entry: SubPayment) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(entry.date.formatted(date: .abbreviated, time: .omitted))
                    if !entry.isPaid {
                        Text("OWED")
                            .font(.caption2.weight(.bold)).foregroundStyle(gold)
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Capsule().fill(gold.opacity(0.16)))
                    }
                }
                let sub = entry.detail.isEmpty ? (entry.customer?.listDisplayName ?? "") : entry.detail
                if !sub.isEmpty {
                    Text(sub).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            Text(entry.amount.formatted(.currency(code: "USD")))
                .foregroundStyle(entry.isPaid ? .secondary : .primary)
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

// MARK: - Ledger entry sheet (record what you owe, or a payment)

private struct RecordSubPaymentSheet: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: [SortDescriptor(\Customer.lastName), SortDescriptor(\Customer.firstName)])
    private var customers: [Customer]

    let subcontractor: Subcontractor
    let existing: SubPayment?

    @State private var hours: Double
    @State private var amount: Double
    @State private var date: Date
    @State private var detail: String
    @State private var customerID: PersistentIdentifier?
    @State private var isPaid: Bool
    @State private var paidDate: Date
    @State private var method: PaymentMethod

    private var gold: Color { GLColor.gold.render(in: colorScheme) }
    private var rate: Double { subcontractor.hourlyRate }
    private var hasRate: Bool { rate > 0 }

    init(subcontractor: Subcontractor, existing: SubPayment?) {
        self.subcontractor = subcontractor
        self.existing = existing
        _hours = State(initialValue: existing?.hours ?? 0)
        _amount = State(initialValue: existing?.amount ?? 0)
        _date = State(initialValue: existing?.date ?? .now)
        _detail = State(initialValue: existing?.detail ?? "")
        _customerID = State(initialValue: existing?.customer?.persistentModelID)
        _isPaid = State(initialValue: existing?.isPaid ?? false)
        _paidDate = State(initialValue: existing?.paidDate ?? .now)
        _method = State(initialValue: existing?.method ?? .check)
    }

    private var selectedCustomer: Customer? {
        customers.first { $0.persistentModelID == customerID }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if hasRate {
                        LabeledContent("Hours") {
                            AutoClearNumberField(placeholder: "0", value: $hours, style: .number)
                                .multilineTextAlignment(.trailing)
                        }
                    }
                    LabeledContent("Amount") {
                        AutoClearNumberField(placeholder: "$0.00", value: $amount, style: .currency)
                            .multilineTextAlignment(.trailing)
                    }
                    DatePicker("Work date", selection: $date, displayedComponents: .date)
                } footer: {
                    if hasRate {
                        Text("Enter hours and it fills the amount at \(rate.formatted(.currency(code: "USD")))/hr — or just type an amount.")
                            .textCase(nil)
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
                Section {
                    Toggle("Paid", isOn: $isPaid)
                    if isPaid {
                        DatePicker("Paid on", selection: $paidDate, displayedComponents: .date)
                        Picker("Method", selection: $method) {
                            ForEach(PaymentMethod.allCases) { Text($0.label).tag($0) }
                        }
                    }
                } footer: {
                    Text(isPaid ? "Counts toward this year's total and the 1099-NEC."
                                : "Leave off to track it as owed. It won't count toward the 1099 until you mark it paid.")
                        .textCase(nil)
                }
                if existing != nil {
                    Section {
                        Button(role: .destructive) { delete() } label: { Text("Delete entry") }
                    }
                }
            }
            .glFormBackground()
            .navigationTitle(existing == nil ? "Record Amount" : "Edit Entry")
            .toolbarTitleDisplayMode(.inline)
            .onChange(of: hours) { _, newHours in
                if hasRate { amount = newHours * rate }   // hours drive the amount when a rate is set
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save).disabled(amount <= 0)
                }
            }
        }
    }

    private func save() {
        let target = existing ?? {
            let new = SubPayment(subcontractor: subcontractor)
            modelContext.insert(new)
            return new
        }()
        target.hours = hasRate ? hours : 0
        target.amount = amount
        target.date = date
        target.detail = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        target.customer = selectedCustomer
        target.paidDate = isPaid ? paidDate : nil
        target.method = method
        try? modelContext.save()
        dismiss()
    }

    private func delete() {
        if let existing { modelContext.delete(existing); try? modelContext.save() }
        dismiss()
    }
}
