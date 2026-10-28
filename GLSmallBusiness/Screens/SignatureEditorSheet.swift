//
//  SignatureEditorSheet.swift
//  GLSmallBusiness
//
//  Created by Gold Life LLC on 6/15/26.
//
//  Create or replace the saved signature by drawing, typing, or importing a photo.
//  The signature is the person's, so it is saved in their Gold Life ID (law 48a;
//  audit 2026-10-03 F19 / F70), never on a local row.

import SwiftUI
import GoldLifeUI
import SwiftData
import PhotosUI
import PencilKit
import GoldLifeID

struct SignatureEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.modelContext) private var modelContext
    private let identity = MBIdentity.shared

    enum Mode: String, CaseIterable, Identifiable {
        case draw, type, importPhoto
        var id: String { rawValue }
        var label: String {
            switch self {
            case .draw: return mbLoc("Draw")
            case .type: return mbLoc("Type")
            case .importPhoto: return mbLoc("Import")
            }
        }
    }

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var mode: Mode = .draw
    @State private var drawing = PKDrawing()
    @State private var typedName = ""
    @State private var importedImage: UIImage?
    @State private var photoItem: PhotosPickerItem?
    @State private var photoLoadFailed = false
    @State private var renderFailed = false
    /// The saved-signature delete waits for the standard alert (law 8a).
    @State private var confirmingDelete = false
    /// Set when a lapsed subscription refuses a write — the alert names it (ReadOnlyGate.swift).
    @State private var readOnlyRefusal: MBWriteOperation?
    /// A save or delete is on its way to the Gold Life ID; Save and Delete wait for it.
    @State private var saving = false
    /// The Gold Life ID refused or couldn't be reached; the sheet stays open with the drawing.
    @State private var saveFailed = false
    /// The signature couldn't be shrunk to what the Gold Life ID takes.
    @State private var tooLarge = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    // Segmented at normal sizes; a menu at accessibility sizes, where the
                    // three segments truncate their labels. The two styles are different
                    // types, so the branch is at the view level, not a ternary
                    // (MMGoldLifeSignInSheet recipe).
                    Group {
                        if dynamicTypeSize.isAccessibilitySize {
                            Picker("Method", selection: $mode) {
                                ForEach(Mode.allCases) { Text($0.label).tag($0) }
                            }
                            .pickerStyle(.menu)
                        } else {
                            Picker("Method", selection: $mode) {
                                ForEach(Mode.allCases) { Text($0.label).tag($0) }
                            }
                            .pickerStyle(.segmented)
                        }
                    }
                    .listRowBackground(Color.clear)
                    // Zero row insets so the control spans the full card width
                    // (EmployeeDetailScreen year-picker recipe).
                    .listRowInsets(EdgeInsets())
                }

                Section {
                    switch mode {
                    case .draw:
                        drawArea
                        // Zero-height companion keeps the tall clear row above out
                        // of single-row capsule geometry, whose deeper arcs clip
                        // content (the List clear-row gotchas, 2026-08-22). Draw
                        // mode only — beside the card rows of Type/Import, a clear
                        // row would square their masked corners.
                        Color.clear
                            .frame(height: 0)
                            .listRowBackground(Color.clear)
                            .listRowInsets(EdgeInsets())
                            .listRowSeparator(.hidden)
                    case .type: typeArea
                    case .importPhoto: importArea
                    }
                } header: {
                    InfoLabel("Your signature", info: "Stored privately in your Gold Life account and protected by Face ID. Used to sign documents like your W-9.", topic: "Your signature")
                }

                if identity.signatureData != nil {
                    Section {
                        Button("Delete saved signature", role: .destructive) {
                            // A lapsed app says so before asking a question it would then refuse.
                            guard ReadOnlyGate.allows(.saveSignature, into: $readOnlyRefusal) else { return }
                            confirmingDelete = true
                        }
                        .disabled(saving)
                    }
                }
            }
            .glFormBackground()
            .readOnlyRefusalAlert($readOnlyRefusal)
            .deleteConfirmation($confirmingDelete, title: "Delete saved signature?") {
                guard ReadOnlyGate.allows(.saveSignature, into: $readOnlyRefusal) else { return }
                store(nil)
            }
            .navigationTitle(GLScript.padded(mbLoc("Signature")))
            .toolbarTitleDisplayMode(.large)
            .contentMargins(.top, GLScript.titleClearance(for: GLScript.padded(mbLoc("Signature"))), for: .scrollContent)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button(role: .close) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }.disabled(!canSave || saving)
                }
            }
            .task(id: photoItem) {
                guard let photoItem else { return }
                guard let data = try? await photoItem.loadTransferable(type: Data.self),
                      let image = await Self.importedSignatureImage(from: data) else {
                    self.photoItem = nil
                    photoLoadFailed = true
                    return
                }
                importedImage = image
            }
            .photoLoadFailureAlert($photoLoadFailed)
            .alert("Couldn\u{2019}t save that signature", isPresented: $renderFailed) {
                Button("OK", role: .cancel) { }
            } message: {
                renderFailureMessage
            }
            .alert("Couldn\u{2019}t save that signature", isPresented: $tooLarge) {
                Button("OK", role: .cancel) { }
            } message: {
                mode == .importPhoto
                    ? Text("That photo is too large for a signature. Try a closer photo of just your signature.")
                    : renderFailureMessage
            }
            .alert("Couldn\u{2019}t save that signature", isPresented: $saveFailed) {
                Button("OK", role: .cancel) { }
            } message: {
                GoldLifeID.shared.isOnline
                    ? Text("Try again in a minute.")
                    : Text("You\u{2019}re offline. Connect to the internet and try again.")
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
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(GLTheme.textSecondary.opacity(0.4)))

            Button("Clear") { drawing = PKDrawing() }
                .font(.subheadline.weight(.medium))
                .foregroundStyle(GLTheme.accentText)
        }
        // 12pt top padding clears iOS 26's section corner mask, and the full-width
        // frame keeps this clear row from centering (the List clear-row gotchas,
        // 2026-08-22); its zero-height companion rides just below it in `body`.
        .padding(.top, 12)
        .frame(maxWidth: .infinity)
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets())
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
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
    }

    private var importArea: some View {
        VStack(spacing: 12) {
            PhotosPicker(selection: $photoItem, matching: .images) {
                Label(importedImage == nil ? "Choose photo" : "Choose a different photo",
                      systemImage: "photo")
                    .foregroundStyle(GLTheme.accentText)
            }
            if let importedImage {
                Image(uiImage: importedImage)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: 140)
                    .padding(.horizontal, GLLayout.rowCardInset)
                    .padding(.vertical)
                    .background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
    }

    // MARK: - Output

    /// A picked photo, shrunk to at most 1024 px on its long edge as it comes in (law 62),
    /// so the knockout and the save never hold a 12 MP picture.
    nonisolated static func importedSignatureImage(from data: Data) async -> UIImage? {
        await ImageDownsampler.intakeImage(from: data)
    }

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

    /// Whether Save should be tappable, decided from the INPUTS rather than by
    /// rendering the output. `currentData()` used to drive `.disabled`, so every
    /// body pass re-rasterized the signature — and for an imported photo that is a
    /// per-pixel knockout over the full-resolution image (measured at ~0.5s for a
    /// 12MP photo, seconds for a 48MP one) on the main actor, on every keystroke
    /// and every redraw. This is the same question answered in constant time.
    private var canSave: Bool {
        switch mode {
        case .draw:      return SignatureRender.hasDrawnInput(bounds: drawing.bounds)
        case .type:      return SignatureRender.hasTypedInput(typedName)
        case .importPhoto: return importedImage != nil
        }
    }

    /// Names the cause for the mode the person is actually in. Listing every possible
    /// remedy ("drawing it again, typing a shorter name, or choosing a different
    /// photo") makes them work out which one applies to them, which is the confusion
    /// the message exists to prevent. In `.type` the cause is always length: `save()`
    /// is only reachable with a non-blank name, and the only other way the render
    /// fails is a name too wide to rasterize.
    private var renderFailureMessage: Text {
        switch mode {
        case .draw:
            return Text("The signature didn\u{2019}t come through \u{2014} it may have been too small to pick up. Try signing again, a little larger.")
        case .type:
            return Text("That name is too long to fit on a signature line. Try a shorter version \u{2014} a first initial and last name works well.")
        case .importPhoto:
            return Text("That photo couldn\u{2019}t be turned into a signature. Try a clearer picture of your signature on plain paper.")
        }
    }

    private func save() {
        guard ReadOnlyGate.allows(.saveSignature, into: $readOnlyRefusal) else { return }
        // Render once, here, where a failure has somewhere to go. Rendering can
        // still fail on input `canSave` can't see through (an image with no
        // decodable backing, a name of glyphs that won't rasterize), and a silent
        // dismiss would look exactly like a successful save.
        guard let data = currentData() else {
            renderFailed = true
            return
        }
        store(data)
    }

    /// Saves (`data`) or deletes (`nil`) the signature in the Gold Life ID. The sheet closes
    /// only once it landed; a refusal keeps it open and says so (no silent "saved" look).
    private func store(_ data: Data?) {
        guard !saving else { return }
        saving = true
        Task {
            defer { saving = false }
            do {
                try await identity.saveSignature(data, legacyIn: modelContext)
                dismiss()
            } catch MBSignatureError.tooLarge {
                tooLarge = true
            } catch {
                saveFailed = true
            }
        }
    }
}
