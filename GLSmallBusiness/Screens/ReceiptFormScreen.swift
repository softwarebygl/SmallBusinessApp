//
//  ReceiptFormScreen.swift
//  GLSmallBusiness
//
//  Created by Gold Life LLC on 5/28/26.
//

import SwiftUI
import SwiftData
import PhotosUI

struct ReceiptFormScreen: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @Query(sort: [SortDescriptor(\Customer.lastName), SortDescriptor(\Customer.firstName)])
    private var allCustomers: [Customer]

    @Query(sort: \ScheduledJob.startDate, order: .reverse)
    private var allJobs: [ScheduledJob]

    private let editingReceipt: Receipt?
    private let scanImage: UIImage?
    /// When creating from a job-scoped list, the new receipt is attached to this job (in addition to
    /// its customer). Nil for the universal Receipts tab and ignored when editing.
    private let defaultJob: ScheduledJob?

    @State private var selectedCustomerID: PersistentIdentifier?
    @State private var selectedJobID: PersistentIdentifier?
    @State private var vendor: String
    @State private var date: Date
    @State private var total: Double
    @State private var category: String
    @State private var notes: String
    @State private var recognizedText: String
    @State private var scanData: Data?
    @State private var isReadingScan = false
    @State private var photoItem: PhotosPickerItem?

    init(defaultCustomer: Customer?, defaultJob: ScheduledJob? = nil, scanImage: UIImage?) {
        self.editingReceipt = nil
        self.scanImage = scanImage
        self.defaultJob = defaultJob
        _selectedCustomerID = State(initialValue: defaultCustomer?.persistentModelID)
        _selectedJobID = State(initialValue: defaultJob?.persistentModelID)
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
        self.defaultJob = nil
        _selectedCustomerID = State(initialValue: receipt.customer?.persistentModelID)
        _selectedJobID = State(initialValue: receipt.job?.persistentModelID)
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

    /// Jobs offered in the picker: the selected customer's jobs (so the list stays relevant), or every
    /// job when the receipt is a general/Business expense with no customer.
    private var jobsForPicker: [ScheduledJob] {
        guard let selectedCustomerID else { return allJobs }
        return allJobs.filter { $0.customer?.persistentModelID == selectedCustomerID }
    }

    var body: some View {
        Form {
            // Receipt photo — scan with the camera (passed in) OR upload an existing image here.
            Section {
                if let scanData, let uiImage = UIImage(data: scanData) {
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
                PhotosPicker(selection: $photoItem, matching: .images) {
                    Label(scanData == nil ? "Upload a photo of the receipt" : "Replace photo",
                          systemImage: "photo")
                }
                if scanData != nil {
                    Button(role: .destructive) { scanData = nil } label: {
                        Label("Remove photo", systemImage: "trash")
                    }
                }
            } header: {
                InfoLabel("Receipt Photo", info: "Scan with the camera or upload an existing image. The vendor, date, and total are read from it automatically.")
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
                Picker("Job", selection: $selectedJobID) {
                    Text("None").tag(PersistentIdentifier?.none)
                    ForEach(jobsForPicker) { job in
                        Text(job.displayTitle).tag(job.persistentModelID as PersistentIdentifier?)
                    }
                }
            } header: {
                InfoLabel("Assignment", info: "Leave as Business for general expenses, or assign this receipt to a customer and, optionally, a specific job.")
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
        // Clear a stale job selection if the customer changes to one that doesn't own that job.
        .onChange(of: selectedCustomerID) { _, _ in
            if let id = selectedJobID, !jobsForPicker.contains(where: { $0.persistentModelID == id }) {
                selectedJobID = nil
            }
        }
        // Library upload: downsize, store, and OCR-prefill any blank fields — same as a camera scan.
        .task(id: photoItem) {
            guard let photoItem,
                  let data = try? await photoItem.loadTransferable(type: Data.self),
                  let uiImage = UIImage(data: data) else { return }
            self.photoItem = nil
            scanData = ImageDownsampler.downsizedJPEG(uiImage, maxDimension: 2000)
            await prefill(from: uiImage)
        }
    }

    /// For a freshly scanned receipt, OCR the image and prefill any blank fields.
    private func readScanIfNeeded() async {
        guard editingReceipt == nil, let scanImage else { return }
        await prefill(from: scanImage)
    }

    /// Reads vendor/date/total off the image via on-device OCR, filling only fields the user hasn't set.
    private func prefill(from uiImage: UIImage) async {
        isReadingScan = true
        let parsed = await ReceiptScanner.parse(uiImage)
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
        receipt.job = allJobs.first { $0.persistentModelID == selectedJobID }
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
