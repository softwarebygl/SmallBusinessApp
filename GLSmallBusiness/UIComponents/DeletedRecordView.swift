//
//  DeletedRecordView.swift
//  GLSmallBusiness
//
//  Created by Gold Life LLC on 6/23/26.
//
//  Shown over a detail screen when the record it's showing gets deleted out from under it — most
//  often because the same record was deleted on another device and the delete synced over. Instead
//  of leaving stale data on screen, the detail covers itself with this plain-language explanation
//  and a way back, so the user is never confused about why the numbers look frozen.
//

import SwiftUI
import GoldLifeUI

struct DeletedRecordView: View {
    @Environment(\.colorScheme) private var colorScheme
    /// The bar title (law 57: a pushed screen is never untitled) — the name the screen normally
    /// wears, resolved via mbLoc at the call site. When the live title is the record's own name or
    /// number, pass the record type instead: a deleted model's properties can't be read.
    let title: String
    /// The record that's gone, lowercase WITH its article, as a catalog key: "this invoice"
    /// (es "esta factura"). The article travels with the noun because Spanish gender picks it
    /// (este cliente / esta factura); a bare noun dropped into one sentence can't agree. (A change
    /// order passes "the change order": "this change order" would collide with the catalog's
    /// "This change order" when the catalog generates symbols.)
    let noun: String.LocalizationValue
    let onBack: () -> Void

    /// "This invoice was removed" / "Se eliminó esta factura", in the app's language.
    static func headline(_ noun: String.LocalizationValue) -> String {
        sentenceCased(mbLoc("\(mbLoc(noun)) was removed"))
    }

    /// The line under the headline, in the app's language.
    static func explanation(_ noun: String.LocalizationValue) -> String {
        mbLoc("It looks like \(mbLoc(noun)) was deleted — possibly on another device. Head back to the list.")
    }

    /// Capitalizes the first letter only ("this invoice was removed" → "This invoice was removed");
    /// the rest keeps the catalog's casing. A no-op where the noun isn't first (es "Se eliminó …").
    private static func sentenceCased(_ text: String) -> String {
        guard let first = text.first else { return text }
        return first.uppercased() + text.dropFirst()
    }

    var body: some View {
        ContentUnavailableView {
            Label(Self.headline(noun), systemImage: "person.crop.circle.badge.xmark")
        } description: {
            Text(Self.explanation(noun))
        } actions: {
            Button("Back", action: onBack)
                .buttonStyle(.borderedProminent)
                .tint(GLTheme.accentFill)
                .foregroundStyle(GLTheme.onAccent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(GLTheme.background.ignoresSafeArea())
        .navigationTitle(GLScript.padded(title))
        .toolbarTitleDisplayMode(.large)
        .contentMargins(.top, GLScript.titleClearance(for: GLScript.padded(title)), for: .scrollContent)
    }
}
