//
//  GLSmallBusinessApp.swift
//  GLSmallBusiness
//
//  Created by Gold Life LLC on 5/27/26.
//

import SwiftUI
import SwiftData
import CoreText
#if canImport(UIKit)
import UIKit
#endif

@main
struct GLSmallBusinessApp: App {
    init() {
        registerBundledFonts()
        configureNavigationBarAppearance()
    }

    var body: some Scene {
        WindowGroup {
            CustomersScreen()
        }
        .modelContainer(for: [Customer.self, Estimate.self, BusinessProfile.self])
    }

    private func registerBundledFonts() {
        let filenames = [
            "Italianno-Regular",
            "Inter-VariableFont_opsz,wght",
            "Inter-Italic-VariableFont_opsz,wght",
        ]
        for name in filenames {
            guard let url = Bundle.main.url(forResource: name, withExtension: "ttf") else {
                print("[Font] Not in bundle: \(name).ttf")
                continue
            }
            var error: Unmanaged<CFError>?
            if !CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) {
                let err = error?.takeRetainedValue()
                print("[Font] Failed to register \(name):", err as Any)
            }
        }
    }

    private func configureNavigationBarAppearance() {
        #if canImport(UIKit)
        let appearance = UINavigationBarAppearance()
        appearance.configureWithDefaultBackground()
        if let largeFont = UIFont(name: "Italianno-Regular", size: 48) {
            appearance.largeTitleTextAttributes[.font] = largeFont
        }
        if let inlineFont = UIFont(name: "Italianno-Regular", size: 28) {
            appearance.titleTextAttributes[.font] = inlineFont
        }
        UINavigationBar.appearance().standardAppearance = appearance
        UINavigationBar.appearance().scrollEdgeAppearance = appearance
        UINavigationBar.appearance().compactAppearance = appearance
        #endif
    }
}
