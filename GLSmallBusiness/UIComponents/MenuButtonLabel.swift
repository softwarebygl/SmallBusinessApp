//
//  MenuButtonLabel.swift
//  GLSmallBusiness
//
//  Created by Gold Life LLC on 5/29/26.
//

import SwiftUI
import SwiftData

/// The icon for the leading "Menu" button shared by every tab's landing screen. Shows the
/// business's uploaded logo when one is set, otherwise the Gold Life monogram. Defined once here
/// so the Menu button looks identical across Customers, Receipts, and Stats.
struct MenuButtonLabel: View {
    @Environment(\.colorScheme) private var colorScheme
    @Query private var businessProfiles: [BusinessProfile]

    var body: some View {
        if let data = businessProfiles.first?.logo(for: colorScheme), let uiImage = UIImage(data: data) {
            Image(uiImage: uiImage)
                .resizable()
                .scaledToFill()
                .frame(width: 36, height: 36)
                .clipShape(Circle())
                .padding(-7)
        } else {
            Image("glLogo")
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .foregroundStyle(GLColor.gold.render(in: colorScheme))
                .frame(width: 32, height: 32)
        }
    }
}
