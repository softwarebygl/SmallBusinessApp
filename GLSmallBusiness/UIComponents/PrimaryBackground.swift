//
//  PrimaryBackground.swift
//  GLSmallBusiness
//
//  Created by Gold Life LLC on 5/27/26.
//

import SwiftUI
import GoldLifeUI
import SwiftData

struct PrimaryBackground: View {

    @Environment(\.colorScheme) var colorScheme
    @AppStorage(AppBranding.useCompanyLogoKey) private var useCompanyLogo = true
    @Query private var businessProfiles: [BusinessProfile]

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                GLTheme.background
                if useCompanyLogo,
                   let data = businessProfiles.first?.logo(for: colorScheme),
                   let uiImage = LogoImage.decoded(data) {
                    // Displayed exactly like the monogram below — only the image differs.
                    Image(uiImage: uiImage)
                        .resizable()
                        .scaledToFill()
                        .opacity(0.2)
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .clipped()
                        .accessibilityHidden(true)
                } else {
                    Image("glLogo")
                        .renderingMode(.template)
                        .resizable()
                        .scaledToFill()
                        .foregroundStyle(GLTheme.accentFill)
                        .opacity(0.2)
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .clipped()
                        .accessibilityHidden(true)
                }
            }
        }
        .ignoresSafeArea()
    }
}

/// The business logo as an image, decoded ONCE per logo (QA F154). The background behind every
/// screen and the Menu's logo slots draw it on every render; decoding the stored bytes each time
/// redid the work while scrolling. Cached by the bytes themselves (`NSData` hashes, then compares
/// in full), so a new or changed logo is decoded fresh and never shows the old picture. Small and
/// evictable: memory pressure clears it, and it only ever holds a handful of logos.
enum LogoImage {
    private static let cache: NSCache<NSData, UIImage> = {
        let cache = NSCache<NSData, UIImage>()
        cache.countLimit = 6
        return cache
    }()

    /// `data` as a ready-to-draw image, or nil when the bytes are not an image.
    static func decoded(_ data: Data) -> UIImage? {
        let key = data as NSData
        if let cached = cache.object(forKey: key) { return cached }
        guard let image = decodeUncached(data) else { return nil }
        cache.setObject(image, forKey: key)
        return image
    }

    /// The one decode: the bytes into pixels now, so drawing the cached image never decodes again.
    private static func decodeUncached(_ data: Data) -> UIImage? {
        guard let image = UIImage(data: data) else { return nil }
        return image.preparingForDisplay() ?? image
    }
}

#Preview {
    PrimaryBackground()
        .modelContainer(for: BusinessProfile.self, inMemory: true)
}
