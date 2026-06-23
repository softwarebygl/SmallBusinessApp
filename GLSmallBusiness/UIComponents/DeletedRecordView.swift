//
//  DeletedRecordView.swift
//  GLSmallBusiness
//
//  Created by Gold Life LLC on 6/23/26.
//
//  Shown over a detail screen when the record it's showing gets deleted out from under it — most
//  often because the same record was deleted on another device and synced over via iCloud. Instead
//  of leaving stale data on screen, the detail covers itself with this plain-language explanation
//  and a way back, so the user is never confused about why the numbers look frozen.
//

import SwiftUI

struct DeletedRecordView: View {
    @Environment(\.colorScheme) private var colorScheme
    /// The thing that's gone, lowercase — e.g. "customer", "employee", "subcontractor".
    let noun: String
    let onBack: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("This \(noun) was removed", systemImage: "person.crop.circle.badge.xmark")
        } description: {
            Text("It looks like this \(noun) was deleted — possibly on another device. Head back to the list.")
        } actions: {
            Button("Back", action: onBack)
                .buttonStyle(.borderedProminent)
                .tint(GLColor.gold.render(in: colorScheme))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(GLColor.backgroundPrimary.render(in: colorScheme).ignoresSafeArea())
    }
}
