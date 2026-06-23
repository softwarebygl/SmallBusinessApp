//
//  SaveOnceButton.swift
//  GLSmallBusiness
//
//  Created by Gold Life LLC on 6/22/26.
//
//  A confirmation button that runs its action at most once. The create/record forms save
//  synchronously and then dismiss, but a fast double-tap can fire the action again during the
//  dismiss animation — which would insert a second record (a duplicate payment double-counts money).
//  This fires once, then stays disabled, so the screen that always dismisses on save can never
//  double-submit. (Forms that can stay open on a save error keep their own resettable guard instead.)
//

import SwiftUI

struct SaveOnceButton: View {
    var title: LocalizedStringKey = "Save"
    var disabled: Bool = false
    let action: () -> Void

    @State private var fired = false

    var body: some View {
        Button(title) {
            guard !fired else { return }
            fired = true
            action()
        }
        .disabled(disabled || fired)
    }
}
