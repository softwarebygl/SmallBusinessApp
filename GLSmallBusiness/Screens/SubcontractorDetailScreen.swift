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
import PhotosUI

struct SubcontractorDetailScreen: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query private var allSubcontractors: [Subcontractor]
    let subcontractor: Subcontractor

    /// False once this subcontractor is deleted out from under the view (e.g. on another device).
    private var stillExists: Bool {
        allSubcontractors.contains { $0.persistentModelID == subcontractor.persistentModelID }
    }

    @State private var activeSheet: ActiveSheet?
    @State private var showingSaveToContacts = false
    @State private var photoItem: PhotosPickerItem?
    @State private var imageToCrop: CroppableImage?
    @State private var photoLoadFailed = false

    private enum ActiveSheet: Identifiable {
        case payment(SubPayment?)
        case form1099
        case allActivity
        var id: String {
            switch self {
            case .payment(let p): "payment-\(p?.persistentModelID.hashValue ?? 0)"
            case .form1099: "1099"
            case .allActivity: "allActivity"
            }
        }
    }

    private var gold: Color { GLColor.gold.render(in: colorScheme) }

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                header
                contactCard
                moreInfoRow
                GLSection("Payments") {
                    balanceCard
                    activityCard
                }
                GLSection("Tax") {
                    w9Card
                }
            }
            .padding()
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
        }
        .containerBackground(for: .navigation) { PrimaryBackground() }
        .overlay {
            if !stillExists {
                DeletedRecordView(noun: "subcontractor") { dismiss() }
            }
        }
        .navigationTitle(subcontractor.listDisplayName)
        .toolbarTitleDisplayMode(.large)   // name is the large title; the whole nav chain is large
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
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
            case .payment(let payment):
                RecordSubPaymentSheet(subcontractor: subcontractor, existing: payment).glAppearance(colorScheme)
            case .form1099:
                Form1099NECSheet(subcontractor: subcontractor).glAppearance(colorScheme)
            case .allActivity:
                AllActivitySheet(subcontractor: subcontractor).glAppearance(colorScheme)
            }
        }
        .sheet(isPresented: $showingSaveToContacts) {
            NewContactView(contact: ContactsBridge.contact(from: subcontractor)) { showingSaveToContacts = false }
                .ignoresSafeArea()
        }
        .task(id: photoItem) {
            guard let photoItem else { return }
            guard let data = try? await photoItem.loadTransferable(type: Data.self),
                  let uiImage = UIImage(data: data) else {
                self.photoItem = nil
                photoLoadFailed = true
                return
            }
            imageToCrop = CroppableImage(image: uiImage)
            self.photoItem = nil
        }
        .photoLoadFailureAlert($photoLoadFailed)
        .fullScreenCover(item: $imageToCrop) { item in
            ImageCropView(image: item.image) {
                imageToCrop = nil
            } onCrop: { cropped in
                subcontractor.profileImageData = cropped.jpegData(compressionQuality: 0.85)
                imageToCrop = nil
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 12) {
            PhotosPicker(selection: $photoItem, matching: .images) {
                ProfileAvatar(imageData: subcontractor.profileImageData, initials: subcontractor.initials,
                              size: 110, showsCameraBadge: true)
            }
            .buttonStyle(.plain)

            // Title (listDisplayName) is the person; show the business under it so "Boyd Electric"
            // stays visible. Skipped when the business is itself the title (no person on file).
            if !subcontractor.businessName.isEmpty && !subcontractor.fullName.isEmpty {
                Text(subcontractor.businessName).font(.subheadline).foregroundStyle(.secondary)
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

    private var contactCard: some View {
        GLCard(title: "Contact") {
            infoRow("Email", subcontractor.email)
            infoRow("Phone", subcontractor.phone)
        }
    }

    private func infoRow(_ label: LocalizedStringKey, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value.isEmpty ? "—" : value).multilineTextAlignment(.trailing)
        }
    }

    private var moreInfoRow: some View {
        GLHubRow(title: "More Info") { SubcontractorDetailsScreen(subcontractor: subcontractor) }
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
        GLCard(title: "W-9") {
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
                    Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
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
        GLCard {
            let entries = subcontractor.sortedPayments
            HStack {
                Text("Activity").font(.headline)
                Spacer()
                if entries.count > 5 {
                    Button("View All") { activeSheet = .allActivity }
                        .font(.subheadline.weight(.medium)).foregroundStyle(gold)
                }
            }
            if entries.isEmpty {
                Text("No activity recorded yet.")
                    .font(.subheadline).foregroundStyle(.secondary)
            } else {
                let recent = Array(entries.prefix(5))
                ForEach(recent) { entry in
                    Button { activeSheet = .payment(entry) } label: { entryRow(entry) }
                        .buttonStyle(.plain)
                    if entry.id != recent.last?.id { Divider() }
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
            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
        }
        .font(.subheadline)
        .contentShape(Rectangle())
    }

}

// MARK: - All activity sheet (full, date-filterable list)

struct AllActivitySheet: View /* internal for render-coverage tests */ {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    let subcontractor: Subcontractor

    private var gold: Color { GLColor.gold.render(in: colorScheme) }

    private enum Range: String, CaseIterable, Identifiable {
        case all = "All", year = "This year", custom = "Custom"
        var id: String { rawValue }
    }
    @State private var range: Range = .all
    @State private var from: Date = Calendar.current.date(byAdding: .month, value: -3, to: .now) ?? .now
    @State private var to: Date = .now
    @State private var editing: SubPayment?
    @State private var searchText = ""

    private var filtered: [SubPayment] {
        let byDate = rangeFilter.apply(to: subcontractor.sortedPayments, date: \.date)
        return searchText.isEmpty ? byDate : byDate.filter { $0.matchesSearch(searchText) }
    }
    private var rangeFilter: DateRangeFilter {
        switch range {
        case .all: return .all
        case .year: return .year(Calendar.current.component(.year, from: .now))
        case .custom: return .custom(from: from, to: to)
        }
    }
    private var paidTotal: Double { filtered.filter(\.isPaid).reduce(0) { $0 + $1.amount } }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Range", selection: $range) {
                    ForEach(Range.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding()
                if range == .custom {
                    VStack(spacing: 6) {
                        DatePicker("From", selection: $from, displayedComponents: .date)
                        DatePicker("To", selection: $to, displayedComponents: .date)
                    }
                    .padding(.horizontal)
                    .padding(.bottom, 8)
                }
                List {
                    if filtered.isEmpty {
                        ContentUnavailableView(searchText.isEmpty ? "Nothing in this range" : "No matches",
                                               systemImage: searchText.isEmpty ? "tray" : "magnifyingglass")
                            .listRowBackground(Color.clear)
                    } else {
                        Section {
                            ForEach(filtered) { entry in
                                Button { editing = entry } label: { row(entry) }
                                    .buttonStyle(.plain)
                                    .listRowBackground(Color.clear)
                            }
                        } footer: {
                            Text("\(paidTotal.formatted(.currency(code: "USD"))) paid · \(filtered.count) \(filtered.count == 1 ? "entry" : "entries")")
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .searchable(text: $searchText, prompt: "Search activity")
            }
            .background { GLColor.backgroundPrimary.render(in: colorScheme).ignoresSafeArea() }
            .navigationTitle("All Activity")
            .toolbarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarLeading) { Button(role: .close) { dismiss() } } }
            .sheet(item: $editing) { entry in
                RecordSubPaymentSheet(subcontractor: subcontractor, existing: entry).glAppearance(colorScheme)
            }
        }
    }

    private func row(_ entry: SubPayment) -> some View {
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
        }
        .font(.subheadline)
        .contentShape(Rectangle())
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

struct Form1099NECSheet: View /* internal for render-coverage tests */ {
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
                    if let previewImage {
                        Image(uiImage: previewImage)
                            .resizable().scaledToFit()
                            .frame(maxWidth: .infinity)
                            .background(Color.white)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .overlay(RoundedRectangle(cornerRadius: 12).stroke(.black.opacity(0.1)))
                            .shadow(radius: 4, y: 2)
                        Text("Copy B — give this to \(subcontractor.payeeName). Keep a copy for your records. File Copy A with the IRS yourself (e-file) or hand your accountant the Year-End Report.")
                            .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    } else if canGenerate {
                        // Everything's filled in but the form didn't build — a generation failure, not
                        // missing data. Offer a retry instead of an empty "add details" checklist.
                        DocumentGenerationError { regenerate() }
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
            .navigationDestination(isPresented: $showingEditBusiness) {
                if let business { MyCompanyFormScreen(profile: business) }
            }
            .onChange(of: showingEditBusiness) { _, isPresented in
                if !isPresented { regenerate() }
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

struct RecordSubPaymentSheet: View /* internal for render-coverage tests */ {
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
                    SaveOnceButton(disabled: amount <= 0, action: save)
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
        modelContext.saveChanges()
        dismiss()
    }

    private func delete() {
        if let existing { modelContext.delete(existing); modelContext.saveChanges() }
        dismiss()
    }
}
