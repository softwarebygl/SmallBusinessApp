//
//  PrimaryBackground.swift
//  GLSmallBusiness
//
//  Created by Gold Life LLC on 5/27/26.
//

import SwiftUI
import SwiftData

struct PrimaryBackground: View {

    @Environment(\.colorScheme) var colorScheme
    @AppStorage(AppBranding.useCompanyLogoKey) private var useCompanyLogo = true
    @Query private var businessProfiles: [BusinessProfile]

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                GLColor.backgroundPrimary.render(in: colorScheme)
                if useCompanyLogo,
                   let data = businessProfiles.first?.logo(for: colorScheme),
                   let uiImage = UIImage(data: data) {
                    // Displayed exactly like the monogram below — only the image differs.
                    Image(uiImage: uiImage)
                        .resizable()
                        .scaledToFill()
                        .opacity(0.2)
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .clipped()
                } else {
                    Image("glLogo")
                        .renderingMode(.template)
                        .resizable()
                        .scaledToFill()
                        .foregroundStyle(GLColor.gold.render(in: colorScheme))
                        .opacity(0.2)
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .clipped()
                }
            }
        }
        .ignoresSafeArea()
    }
}

#Preview {
    PrimaryBackground()
        .modelContainer(for: BusinessProfile.self, inMemory: true)
}
