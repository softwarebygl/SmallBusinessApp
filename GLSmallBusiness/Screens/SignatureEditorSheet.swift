//
//  SignatureEditorSheet.swift
//  GLSmallBusiness
//
//  Created by Gold Life LLC on 6/15/26.
//
//  Create or replace the saved signature by drawing, typing, or importing a photo.

import SwiftUI
import SwiftData
import PhotosUI
import PencilKit

struct SignatureEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    let profile: UserProfile

    enum Mode: String, CaseIterable, Identifiable {
        case draw, type, importPhoto
        var id: String { rawValue }
        var label: String {
            switch self {
            case .draw: return String(localized: "Draw")
            case .type: return String(localized: "Type")
            case .importPhoto: return String(localized: "Import")
            }
        }
    }

    @State private var mode: Mode = .draw
    @State private var drawing = PKDrawing()
    @State private var typedName = ""
    @State private var importedImage: UIImage?
    @State private var photoItem: PhotosPickerItem?

    private var gold: Color { GLColor.gold.render(in: colorScheme) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Method", selection: $mode) {
                        ForEach(Mode.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                }

                Section {
                    switch mode {
                    case .draw: drawArea
                    case .type: typeArea
                    case .importPhoto: importArea
                    }
                } header: {
                    InfoLabel("Your signature", info: "Stored privately in your iCloud account and protected by Face ID. Used to sign documents like your W-9.")
                }

                if profile.hasSignature {
                    Section {
                        Button(role: .destructive) {
                            profile.signatureData = nil
                            dismiss()
                        } label: {
                            Text("Delete saved signature")
                        }
                    }
                }
            }
            .glFormBackground()
            .navigationTitle("Signature")
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }.disabled(currentData() == nil)
                }
            }
            .task(id: photoItem) {
                guard let photoItem,
                      let data = try? await photoItem.loadTransferable(type: Data.self),
                      let image = UIImage(data: data) else { return }
                importedImage = image
            }
        }
    }

    // MARK: - Modes

    private var drawArea: some View {
        VStack(spacing: 10) {
            ZStack(alignment: .bottom) {
                SignatureCanvas(drawing: $drawing)
                    .frame(height: 180)
                // Fixed dark guide line so it stays visible on the white area in dark mode.
                Rectangle().fill(Color.black.opacity(0.25)).frame(height: 1)
                    .padding(.horizontal, 16).padding(.bottom, 36)
            }
            .background(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(.secondary.opacity(0.4)))

            Button("Clear") { drawing = PKDrawing() }
                .font(.subheadline.weight(.medium))
                .foregroundStyle(gold)
        }
        .listRowBackground(Color.clear)
    }

    private var typeArea: some View {
        VStack(spacing: 12) {
            TextField("Type your name", text: $typedName)
                .textContentType(.name)
            if !typedName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(typedName)
                    .font(.custom("SnellRoundhand-Bold", size: 44))
                    .foregroundStyle(.black)
                    .frame(maxWidth: .infinity, minHeight: 90)
                    .background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    private var importArea: some View {
        VStack(spacing: 12) {
            PhotosPicker(selection: $photoItem, matching: .images) {
                Label(importedImage == nil ? "Choose photo" : "Choose a different photo",
                      systemImage: "photo")
                    .foregroundStyle(gold)
            }
            if let importedImage {
                Image(uiImage: importedImage)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: 140)
                    .padding()
                    .background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    // MARK: - Output

    @MainActor
    private func currentData() -> Data? {
        switch mode {
        case .draw: return SignatureRender.png(from: drawing)
        case .type: return SignatureRender.png(typed: typedName)
        case .importPhoto:
            guard let importedImage else { return nil }
            return SignatureRender.transparentPNG(from: importedImage)
        }
    }

    private func save() {
        if let data = currentData() {
            profile.signatureData = data
        }
        dismiss()
    }
}
