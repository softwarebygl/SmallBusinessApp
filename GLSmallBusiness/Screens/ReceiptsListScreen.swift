//
//  ReceiptsListScreen.swift
//  GLSmallBusiness
//
//  Created by Gold Life LLC on 5/28/26.
//

import SwiftUI
import SwiftData
import VisionKit

private struct ReceiptFormInput: Identifiable {
    let id = UUID()
    let image: UIImage?
}

struct ReceiptsListScreen: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.modelContext) private var modelContext
    let customer: Customer

    @State private var showingScanner = false
    @State private var scannedImage: UIImage?
    @State private var formInput: ReceiptFormInput?
    @State private var selectedReceipt: Receipt?
    @State private var isEditing = false
    @State private var selection = Set<PersistentIdentifier>()

    private var gold: Color { GLColor.gold.render(in: colorScheme) }
    private var scannerSupported: Bool { VNDocumentCameraViewController.isSupported }

    private var receipts: [Receipt] {
        (customer.receipts ?? []).sorted { $0.date > $1.date }
    }

    var body: some View {
        List {
            if receipts.isEmpty {
                ContentUnavailableView {
                    Label("No Receipts", systemImage: "doc.viewfinder")
                } description: {
                    Text(scannerSupported
                         ? "Tap + to scan a receipt for \(customer.listDisplayName)."
                         : "Tap + to add a receipt. Scanning needs a device with a camera.")
                }
                .listRowBackground(Color.clear)
            } else {
                ForEach(receipts) { receipt in
                    Button {
                        if isEditing { toggleSelection(receipt) } else { selectedReceipt = receipt }
                    } label: {
                        HStack(spacing: 12) {
                            if isEditing {
                                Image(systemName: selection.contains(receipt.persistentModelID) ? "checkmark.circle.fill" : "circle")
                                    .font(.title3)
                                    .foregroundStyle(selection.contains(receipt.persistentModelID) ? gold : Color.secondary)
                            }
                            HStack(spacing: 12) {
                                thumbnail(receipt)
                                rowContent(receipt)
                                if !isEditing {
                                    Image(systemName: "chevron.right")
                                        .font(.footnote.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(.horizontal, GLLayout.rowContentPadding)
                            .padding(.vertical, GLLayout.rowContentVerticalPadding)
                            .frame(maxWidth: .infinity)
                            .background(RoundedRectangle(cornerRadius: 12).fill(gold.opacity(0.12)))
                        }
                        .padding(.horizontal, GLLayout.rowCardInset)
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets())
                }
                .onDelete(perform: delete)
            }
        }
        .scrollContentBackground(.hidden)
        .listStyle(.plain)
        .containerBackground(for: .navigation) {
            PrimaryBackground()
        }
        .navigationTitle("Receipts")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $selectedReceipt) { receipt in
            ReceiptDetailScreen(receipt: receipt)
        }
        .toolbar {
            if isEditing {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { toggleEditing() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(role: .destructive) {
                        deleteSelected()
                    } label: {
                        Text(selection.isEmpty ? "Delete" : "Delete (\(selection.count))")
                    }
                    .tint(.red)
                    .disabled(selection.isEmpty)
                }
            } else {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        if scannerSupported {
                            Button {
                                showingScanner = true
                            } label: {
                                Label("Scan Receipt", systemImage: "doc.viewfinder")
                            }
                        }
                        Button {
                            formInput = ReceiptFormInput(image: nil)
                        } label: {
                            Label("Add Manually", systemImage: "square.and.pencil")
                        }
                        if !receipts.isEmpty {
                            Button {
                                toggleEditing()
                            } label: {
                                Label("Select", systemImage: "checkmark.circle")
                            }
                        }
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Add Receipt")
                }
            }
        }
        .fullScreenCover(isPresented: $showingScanner, onDismiss: {
            // Present the prefilled form only after the scanner is fully dismissed.
            if let image = scannedImage {
                scannedImage = nil
                formInput = ReceiptFormInput(image: image)
            }
        }) {
            DocumentScannerView(
                onComplete: { images in
                    scannedImage = images.first
                    showingScanner = false
                },
                onCancel: { showingScanner = false }
            )
            .ignoresSafeArea()
        }
        .sheet(item: $formInput) { input in
            ReceiptFormScreen(customer: customer, scanImage: input.image)
        }
    }

    private func thumbnail(_ receipt: Receipt) -> some View {
        Group {
            if let data = receipt.scanData, let uiImage = UIImage(data: data) {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    gold.opacity(0.15)
                    Image(systemName: "doc.text.image")
                        .foregroundStyle(gold)
                }
            }
        }
        .frame(width: 44, height: 44)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func rowContent(_ receipt: Receipt) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(receipt.displayVendor)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                Text(receipt.total.formatted(.currency(code: "USD")))
                    .font(.headline)
            }
            HStack(spacing: 8) {
                Text(receipt.date.formatted(date: .abbreviated, time: .omitted))
                if !receipt.category.isEmpty {
                    Text("·")
                    Text(receipt.category).lineLimit(1)
                }
                Spacer()
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private func toggleSelection(_ receipt: Receipt) {
        let id = receipt.persistentModelID
        if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
    }

    private func toggleEditing() {
        withAnimation {
            isEditing.toggle()
            if !isEditing { selection.removeAll() }
        }
    }

    private func deleteSelected() {
        withAnimation {
            for receipt in receipts where selection.contains(receipt.persistentModelID) {
                modelContext.delete(receipt)
            }
            selection.removeAll()
        }
    }

    private func delete(at offsets: IndexSet) {
        for receipt in offsets.map({ receipts[$0] }) {
            modelContext.delete(receipt)
        }
    }
}
