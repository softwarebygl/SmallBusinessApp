//
//  PhotoLoadAlert.swift
//  GLSmallBusiness
//
//  Created by Gold Life LLC on 6/22/26.
//
//  A shared, plain-language alert for when a picked photo can't be loaded (corrupted, an
//  unsupported format, or an iCloud-photo download that failed). Used by every PhotosPicker
//  (logo, personal photo, customer photo, signature import) so a failed pick never silently
//  does nothing — the user is told, in their words, to try a different photo.
//

import SwiftUI

extension View {
    func photoLoadFailureAlert(_ isPresented: Binding<Bool>) -> some View {
        alert("Couldn’t use that photo", isPresented: isPresented) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("That photo couldn’t be opened — it may be in a format we can’t read, or it didn’t finish downloading from iCloud. Please try a different one.")
        }
    }
}
