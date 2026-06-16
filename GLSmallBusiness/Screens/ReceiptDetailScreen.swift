//
//  ReceiptDetailScreen.swift
//  GLSmallBusiness
//
//  Created by Gold Life LLC on 5/28/26.
//

import SwiftUI
import SwiftData

struct ReceiptDetailScreen: View {
    @Environment(\.colorScheme) private var colorScheme
    let receipt: Receipt

    @State private var showingEdit = false

    private var gold: Color { GLColor.gold.render(in: colorScheme) }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                if let data = receipt.scanData, let uiImage = UIImage(data: data) {
                    Image(uiImage: uiImage)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(gold.opacity(0.25), lineWidth: 1))
                }
                detailsCard
                if !receipt.notes.isEmpty {
                    notesCard
                }
                if !receipt.recognizedText.isEmpty {
                    scannedTextCard
                }
            }
            .padding()
        }
        .containerBackground(for: .navigation) {
            PrimaryBackground()
        }
        .navigationTitle(receipt.displayVendor)
        .toolbarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { showingEdit = true } label: { Label("Edit receipt", systemImage: "pencil") }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .accessibilityLabel("More")
            }
        }
        .sheet(isPresented: $showingEdit) {
            ReceiptFormScreen(editing: receipt).glAppearance(colorScheme)
        }
    }

    private var detailsCard: some View {
        card {
            row("Vendor", receipt.displayVendor)
            row("Date", receipt.date.formatted(date: .abbreviated, time: .omitted))
            row("Total", receipt.total.formatted(.currency(code: "USD")))
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
        GLCard { content() }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).multilineTextAlignment(.trailing)
        }
        .font(.subheadline)
    }
}
