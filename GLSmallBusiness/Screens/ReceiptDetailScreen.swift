//
//  ReceiptDetailScreen.swift
//  GLSmallBusiness
//
//  Created by Gold Life LLC on 5/28/26.
//

import SwiftUI
import GoldLifeUI
import GoldLifeAI
import SwiftData

struct ReceiptDetailScreen: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query private var allReceipts: [Receipt]
    let receipt: Receipt

    /// The sparkles button (law 58, dual entry points). Off for a record the assistant itself
    /// pushed, so the assistant can never open inside the assistant.
    var showsAssistantButton = true

    /// What the model is told is on screen when the sparkles sheet opens.
    private var assistantRecord: GLAIOnScreen? {
        GLAIOnScreen(.receipt, receipt, label: receipt.displayVendor, in: modelContext)
    }

    @State private var showingEdit = false
    /// The stored photo decoded off the main thread, once per photo (never in `body`).
    @State private var photo: UIImage?

    /// False once this receipt is deleted out from under the view (e.g. its customer was deleted on
    /// another device, cascading the delete here).
    private var stillExists: Bool {
        allReceipts.contains { $0.persistentModelID == receipt.persistentModelID }
    }

    private var gold: Color { GLTheme.accentFill }

    var body: some View {
        // BRANCH, not overlay (CRUD audit 2026-09-02): an overlay still evaluates the body
        // against the deleted record — property reads on a dead @Model trap uncatchably.
        if stillExists { aliveBody } else { DeletedRecordView(title: mbLoc("Receipt"), noun: "this receipt") { dismiss() } }
    }

    @ViewBuilder private var aliveBody: some View {
        ScrollView {
            VStack(spacing: 20) {
                if receipt.scanData != nil, let photo {
                    Image(uiImage: photo)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(gold.opacity(0.25), lineWidth: 1))
                }
                detailsCard
                if !receipt.notes.isEmpty {
                    notesCard
                }
                if !receipt.recognizedText.isEmpty {
                    scannedTextCard
                }
            }
            .padding(.horizontal, GLLayout.rowCardInset)
            .padding(.vertical)
            // One column with the banners above (QA 2026-10-03 F50): capped at 640 pt, the gutter inside it.
            .glReadableWidth()
        }
        // Full width for reading; the cap keeps a very long multi-page scan from decoding into
        // a giant bitmap (6+ pages show a little narrower).
        .task(id: receipt.scanData) {
            guard let data = receipt.scanData else { photo = nil; return }
            let decoded = await ReceiptScanPages.displayImage(from: data, maxPixelSize: 8192)
            if !Task.isCancelled { photo = decoded }
        }
        .mbSystemBanners()
        .containerBackground(for: .navigation) {
            PrimaryBackground()
        }
        .navigationTitle(GLScript.padded(receipt.displayVendor))
        .toolbarTitleDisplayMode(.large)
        .contentMargins(.top, GLScript.titleClearance(for: GLScript.padded(receipt.displayVendor)), for: .scrollContent)
        .toolbar {
            // A pure check: the id is minted in the button's action, never in this builder.
            if showsAssistantButton, receipt.canBeNamedToAssistant {
                ToolbarItem(placement: .topBarTrailing) {
                    MBAssistantButton { assistantRecord }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                // Law 40: a one-option menu is banned — the action IS the button.
                Button("Edit") { showingEdit = true }
                    // The DeletedRecordView overlay only covers the content area — the nav bar stays
                    // tappable, so Edit must not open a form over a deleted model.
                    .disabled(!stillExists)
            }
        }
        .navigationDestination(isPresented: $showingEdit) {
            ReceiptFormScreen(editing: receipt)
        }
    }

    private var detailsCard: some View {
        card {
            row("Vendor", receipt.displayVendor)
            row("Date", receipt.date.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted).locale(MBLocalization.currentLocale)))
            row("Total", receipt.total.formatted(.appMoney))
            if !receipt.category.isEmpty { row("Category", receipt.category) }
        }
    }

    private var notesCard: some View {
        card {
            Text("Notes").font(.headline)
            Text(receipt.notes).foregroundStyle(.secondary)
        }
    }

    private var scannedTextCard: some View {
        card {
            DisclosureGroup("Scanned text") {
                Text(receipt.recognizedText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 6)
            }
            .tint(gold)
        }
    }

    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        MBTitledCard { content() }
    }

    private func row(_ label: LocalizedStringKey, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).multilineTextAlignment(.trailing)
        }
        .font(.subheadline)
    }
}
