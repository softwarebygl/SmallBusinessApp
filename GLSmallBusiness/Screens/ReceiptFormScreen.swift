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
    @Environment(\.colorScheme) private var colorScheme

    private let editingReceipt: Receipt?
    private let customer: Customer?
    private let scanImage: UIImage?

    @State private var vendor: String
    @State private var date: Date
    @State private var total: Double
    @State private var category: String
    @State private var notes: String
    @State private var recognizedText: String
    @State private var scanData: Data?
    @State private var isReadingScan = false

    init(customer: Customer, scanImage: UIImage?) {
        self.customer = customer
        self.editingReceipt = nil
        self.scanImage = scanImage
        _vendor = State(initialValue: "")
        _date = State(initialValue: .now)
        _total = State(initialValue: 0)
        _category = State(initialValue: "")
        _notes = State(initialValue: "")
        _recognizedText = State(initialValue: "")
        _scanData = State(initialValue: scanImage?.jpegData(compressionQuality: 0.7))
    }

    init(editing receipt: Receipt) {
        self.customer = receipt.customer
        self.editingReceipt = receipt
        self.scanImage = nil
        _vendor = State(initialValue: receipt.vendor)
        _date = State(initialValue: receipt.date)
        _total = State(initialValue: receipt.total)
        _category = State(initialValue: receipt.category)
        _notes = State(initialValue: receipt.notes)
        _recognizedText = State(initialValue: receipt.recognizedText)
        _scanData = State(initialValue: receipt.scanData)
    }

    var body: some View {
        NavigationStack {
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
                    DatePicker("Date", selection: $date, displayedComponents: .date)
                    LabeledContent("Total") {
                        AutoClearNumberField(placeholder: "0", value: $total, style: .currency, clearsAt: 0)
                            .multilineTextAlignment(.trailing)
                    }
                    TextField("Category (e.g. Materials)", text: $category)
                }

                Section("Notes") {
                    TextField("Notes", text: $notes, axis: .vertical)
                        .lineLimit(2...6)
                }
            }
            .scrollContentBackground(.hidden)
            .background {
                GLColor.backgroundPrimary.render(in: colorScheme).ignoresSafeArea()
            }
            .navigationTitle(editingReceipt == nil ? "New Receipt" : "Edit Receipt")
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                }
            }
            .task { await readScanIfNeeded() }
        }
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
            receipt = Receipt(customer: customer)
            modelContext.insert(receipt)
        }
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
