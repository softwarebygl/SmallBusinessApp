//
//  MenuButtonLabel.swift
//  GLSmallBusiness
//
//  Created by Gold Life LLC on 5/29/26.
//  Powered turnkey by GoldLifeUI.GLMenuButtonLabel (Law 54).
//

import SwiftUI
import GoldLifeUI
import SwiftData

struct MenuButtonLabel: View {
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(AppBranding.useCompanyLogoKey) private var useCompanyLogo = true
    @Query private var businessProfiles: [BusinessProfile]

    var body: some View {
        let uiImage = useCompanyLogo ? (businessProfiles.first?.logo(for: colorScheme)).flatMap(UIImage.init(data:)) : nil
        GLMenuButtonLabel(uiImage: uiImage)
    }
}

