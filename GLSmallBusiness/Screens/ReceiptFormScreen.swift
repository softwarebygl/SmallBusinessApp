//
//  ReceiptFormScreen.swift
//  GLSmallBusiness
//
//  Created by Gold Life LLC on 5/28/26.
//

import GoldLifeUI
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
    /// A finished camera scan (stitched and encoded off the main thread by the Receipts list);
    /// nil for a manual receipt and when editing.
    private let scanImage: ReceiptScanImage?
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
    /// `scanData` decoded small for the preview, off the main thread (never in `body`).
    @State private var previewImage: UIImage?
    @State private var isReadingScan = false
    /// Set when a lapsed subscription refuses a write — the alert names it (ReadOnlyGate.swift).
    @State private var readOnlyRefusal: MBWriteOperation?
    /// A refusal ReceiptService threw that the form did not predict (DomainErrorAlert.swift).
    @State private var domainError: DomainError?
    @State private var photoItem: PhotosPickerItem?
    // OCR only fills the date while the user hasn't picked one themselves — a Date has no natural
    // "empty" value like the blank vendor / zero total, so track it explicitly. Editing an existing
    // receipt counts as user-set (a photo replace must not clobber a corrected date).
    @State private var dateSetByUser: Bool
    @State private var autofilledDate: Date?

    init(defaultCustomer: Customer?, defaultJob: ScheduledJob? = nil, scanImage: ReceiptScanImage?) {
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
        _dateSetByUser = State(initialValue: false)
        // The scan arrives already shrunk and encoded (law 62), so nothing is re-encoded here:
        // this initializer runs again every time SwiftUI re-creates the view.
        _scanData = State(initialValue: scanImage?.jpeg)
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
        _dateSetByUser = State(initialValue: true)
    }

    private var canSave: Bool { draft.hasDetails }

    /// The form's fields as ReceiptService takes them.
    private var draft: ReceiptDraft {
        ReceiptDraft(vendor: vendor, date: date, total: total, category: category, notes: notes,
                     recognizedText: recognizedText, scanData: scanData,
                     customer: allCustomers.first { $0.persistentModelID == selectedCustomerID },
                     job: allJobs.first { $0.persistentModelID == selectedJobID })
    }

    /// Jobs offered in the picker: the selected customer's jobs (so the list stays relevant), or every
    /// job when the receipt is a general/Business expense with no customer.
    private var jobsForPicker: [ScheduledJob] {
        guard let selectedCustomerID else { return allJobs }
        return allJobs.filter { $0.customer?.persistentModelID == selectedCustomerID }
    }

    @State private var initialDigest: String?
    private var digest: String {
        "\(String(describing: selectedCustomerID))|\(String(describing: selectedJobID))|\(vendor)|\(category)|\(notes)|\(date)|\(total)|\(scanData?.count ?? 0)"
    }
    private var isDirty: Bool { initialDigest.map { $0 != digest } ?? false }

    var body: some View {
        Form {
            // Receipt photo — scan with the camera (passed in) OR upload an existing image here.
            Section {
                if scanData != nil, let previewImage {
                    Image(uiImage: previewImage)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity)
                        .frame(maxHeight: 260)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay {
                            if isReadingScan {
                                ZStack {
                                    Color.black.opacity(0.35)
                                    VStack(spacing: 8) {
                                        ProgressView().tint(.white)
                                        Text("Reading receipt…").font(.caption).foregroundStyle(.white)
                                    }
                                }
                                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
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
                InfoLabel("Receipt Photo", info: "Scan with the camera or upload an existing image. The vendor, date, and total are read from it automatically.", topic: "Receipt Photo")
            }

            Section("Details") {
                TextField("Vendor", text: $vendor)
                    .textContentType(.organizationName)
                    .textInputAutocapitalization(.words)
                DatePicker("Date", selection: $date, displayedComponents: .date)
                LabeledContent("Total") {
                    AutoClearNumberField(placeholder: "0", value: $total, style: .currency, clearsAt: 0, wholeCents: true)
                        .multilineTextAlignment(.trailing)
                        .accessibilityIdentifier("receiptTotalField")
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
                .accessibilityIdentifier("receiptJobPicker")
            } header: {
                InfoLabel("Assignment", info: "Leave as Business for general expenses, or assign this receipt to a customer and, optionally, a specific job.", topic: "Assignment")
            }

            Section("Notes") {
                TextField("Notes", text: $notes, axis: .vertical)
                    .lineLimit(2...6)
            }
        }
        .glFormBackground()
        .readOnlyRefusalAlert($readOnlyRefusal)
        .domainErrorAlert($domainError)
        .onAppear { if initialDigest == nil { initialDigest = digest } }
        .discardChangesGuard(isDirty: isDirty)
        .navigationTitle(GLScript.padded(editingReceipt == nil ? mbLoc("New Receipt") : mbLoc("Edit Receipt")))
        .toolbarTitleDisplayMode(.large)
        .contentMargins(.top, GLScript.titleClearance(for: GLScript.padded(editingReceipt == nil ? mbLoc("New Receipt") : mbLoc("Edit Receipt"))), for: .scrollContent)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                SaveOnceButton(disabled: !canSave, action: save)
            }
        }
        .task { await readScanIfNeeded() }
        // The preview is decoded once per photo, small (3× its 260 pt frame), off the main thread.
        .task(id: scanData) {
            guard let scanData else { previewImage = nil; return }
            let decoded = await ReceiptScanPages.displayImage(from: scanData, maxPixelSize: 260 * 3)
            if !Task.isCancelled { previewImage = decoded }
        }
        // A date change that didn't come from OCR autofill means the user picked it — stop autofilling.
        .onChange(of: date) { _, newValue in
            if newValue != autofilledDate { dateSetByUser = true }
        }
        // Clear a stale job selection if the customer changes to one that doesn't own that job.
        .onChange(of: selectedCustomerID) { _, _ in
            if let id = selectedJobID, !jobsForPicker.contains(where: { $0.persistentModelID == id }) {
                selectedJobID = nil
            }
        }
        // Library upload: downsize, store, and OCR-prefill any blank fields — same as a camera scan.
        // The pick is shrunk to 1024 px, upright, and encoded once, all off the main thread (law 62).
        .task(id: photoItem) {
            guard let photoItem,
                  let data = try? await photoItem.loadTransferable(type: Data.self),
                  let uiImage = await ImageDownsampler.intakeImage(from: data),
                  let picked = await ReceiptScanPages.prepared([uiImage]) else { return }
            self.photoItem = nil
            scanData = picked.jpeg
            await prefill(from: picked.image)
        }
    }

    /// For a freshly scanned receipt, OCR the image and prefill any blank fields.
    private func readScanIfNeeded() async {
        guard editingReceipt == nil, let scanImage else { return }
        await prefill(from: scanImage.image)
    }

    /// Reads vendor/date/total off the image via on-device OCR, filling only fields the user hasn't set.
    private func prefill(from uiImage: UIImage) async {
        isReadingScan = true
        let parsed = await ReceiptService.read(uiImage)
        // ReceiptService.prefill owns the rule (blanks only; the date only while unpicked).
        var filled = draft
        if let parsedDate = ReceiptService.prefill(&filled, from: parsed, keepDate: dateSetByUser) {
            autofilledDate = parsedDate
            date = parsedDate
        }
        vendor = filled.vendor
        total = filled.total
        recognizedText = filled.recognizedText
        isReadingScan = false
    }

    /// Returns whether the save committed — false re-arms `SaveOnceButton` so a refused tap can be
    /// retried after the person reactivates.
    @discardableResult
    private func save() -> Bool {
        guard ReadOnlyGate.allows(.saveReceipt, into: $readOnlyRefusal) else { return false }
        // ReceiptService trims, validates (including the job-belongs-to-the-customer rule) and
        // saves — the same path the assistant uses.
        do {
            if let editingReceipt {
                try ReceiptService.update(editingReceipt, with: draft, origin: .screen, in: modelContext)
            } else {
                try ReceiptService.create(draft, origin: .screen, in: modelContext)
            }
        } catch {
            DomainError.present(error, readOnly: $readOnlyRefusal, domainError: $domainError)
            return false
        }
        dismiss()
        return true
    }
}
