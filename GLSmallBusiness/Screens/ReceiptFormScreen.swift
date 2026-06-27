//
//  ReceiptFormScreen.swift
//  GLSmallBusiness
//
//  Created by Gold Life LLC on 5/28/26.
//

import SwiftUI
import SwiftData

struct ReceiptFormScreen: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @Query(sort: [SortDescriptor(\Customer.lastName), SortDescriptor(\Customer.firstName)])
    private var allCustomers: [Customer]

    private let editingReceipt: Receipt?
    private let scanImage: UIImage?
    /// When creating from a job-scoped list, the new receipt is attached to this job (in addition to
    /// its customer). Nil for the universal Receipts tab and ignored when editing.
    private let defaultJob: ScheduledJob?

    @State private var selectedCustomerID: PersistentIdentifier?
    @State private var vendor: String
    @State private var date: Date
    @State private var total: Double
    @State private var category: String
    @State private var notes: String
    @State private var recognizedText: String
    @State private var scanData: Data?
    @State private var isReadingScan = false

    init(defaultCustomer: Customer?, defaultJob: ScheduledJob? = nil, scanImage: UIImage?) {
        self.editingReceipt = nil
        self.scanImage = scanImage
        self.defaultJob = defaultJob
        _selectedCustomerID = State(initialValue: defaultCustomer?.persistentModelID)
        _vendor = State(initialValue: "")
        _date = State(initialValue: .now)
        _total = State(initialValue: 0)
        _category = State(initialValue: "")
        _notes = State(initialValue: "")
        _recognizedText = State(initialValue: "")
        // Downsize the scan before storing — a full-res VisionKit capture is multi-MB, bloating the
        // store and slowing CloudKit sync, for no visible receipt-quality gain.
        _scanData = State(initialValue: scanImage.flatMap { ImageDownsampler.downsizedJPEG($0, maxDimension: 2000) })
    }

    init(editing receipt: Receipt) {
        self.editingReceipt = receipt
        self.scanImage = nil
        self.defaultJob = nil   // editing preserves the receipt's existing job link
        _selectedCustomerID = State(initialValue: receipt.customer?.persistentModelID)
        _vendor = State(initialValue: receipt.vendor)
        _date = State(initialValue: receipt.date)
        _total = State(initialValue: receipt.total)
        _category = State(initialValue: receipt.category)
        _notes = State(initialValue: receipt.notes)
        _recognizedText = State(initialValue: receipt.recognizedText)
        _scanData = State(initialValue: receipt.scanData)
    }

    private var canSave: Bool {
        !vendor.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || total > 0 || scanData != nil
    }

    var body: some View {
        Form {
            if let scanData, let uiImage = UIImage(data: scanData) {
                Section {
                    Image(uiImage: uiImage)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity)
                        .frame(maxHeight: 260)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .overlay {
                            if isReadingScan {
                                ZStack {
                                    Color.black.opacity(0.35)
                                    VStack(spacing: 8) {
                                        ProgressView().tint(.white)
                                        Text("Reading receipt…").font(.caption).foregroundStyle(.white)
                                    }
                                }
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                            }
                        }
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }
            }

            Section("Details") {
                TextField("Vendor", text: $vendor)
                    .textContentType(.organizationName)
                    .textInputAutocapitalization(.words)
                DatePicker("Date", selection: $date, displayedComponents: .date)
                LabeledContent("Total") {
                    AutoClearNumberField(placeholder: "0", value: $total, style: .currency, clearsAt: 0)
                        .multilineTextAlignment(.trailing)
                }
                TextField("Category (e.g. Materials)", text: $category)
            }

            Section {
                Picker("Assigned to", selection: $selectedCustomerID) {
                    Text("Business").tag(PersistentIdentifier?.none)
                    ForEach(allCustomers) { customer in
                        Text(customer.listDisplayName).tag(customer.persistentModelID as PersistentIdentifier?)
                    }
                }
            } header: {
                InfoLabel("Assignment", info: "Leave as Business for general expenses, or assign this receipt to a customer's job.")
            }

            Section("Notes") {
                TextField("Notes", text: $notes, axis: .vertical)
                    .lineLimit(2...6)
            }
        }
        .glFormBackground()
        .navigationTitle(editingReceipt == nil ? "New Receipt" : "Edit Receipt")
        .toolbarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                SaveOnceButton(disabled: !canSave, action: save)
            }
        }
        .task { await readScanIfNeeded() }
    }

    /// For a freshly scanned receipt, OCR the image and prefill any blank fields.
    private func readScanIfNeeded() async {
        guard editingReceipt == nil, let scanImage else { return }
        isReadingScan = true
        let parsed = await ReceiptScanner.parse(scanImage)
        if vendor.isEmpty { vendor = parsed.vendor }
        if let parsedDate = parsed.date { date = parsedDate }
        if total == 0, let parsedTotal = parsed.total { total = parsedTotal }
        recognizedText = parsed.recognizedText
        isReadingScan = false
    }

    private func save() {
        let receipt: Receipt
        if let editingReceipt {
            receipt = editingReceipt
        } else {
            receipt = Receipt()
            modelContext.insert(receipt)
        }
        receipt.customer = allCustomers.first { $0.persistentModelID == selectedCustomerID }
        if editingReceipt == nil { receipt.job = defaultJob }   // attach a new scan to its job
        receipt.vendor = vendor.trimmingCharacters(in: .whitespacesAndNewlines)
        receipt.date = date
        receipt.total = total
        receipt.category = category.trimmingCharacters(in: .whitespacesAndNewlines)
        receipt.notes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        receipt.recognizedText = recognizedText
        receipt.scanData = scanData
        dismiss()
    }
}
