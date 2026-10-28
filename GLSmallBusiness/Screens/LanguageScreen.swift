//
//  LanguageScreen.swift
//  GLSmallBusiness
//
//  The APP-LEVEL language picker.
//

import SwiftUI
import GoldLifeUI

struct LanguageScreen: View {
    @State private var loc = MBLocalization.shared

    var body: some View {
        GLLanguageScreen(
            selection: Binding(
                get: { loc.pref.rawValue },
                set: { AppSettingsService.setLanguage(MBLanguagePref(rawValue: $0) ?? .goldLife) }
            ),
            title: mbLoc("Language"),
            footer: mbLoc("Gold Life ID Setting follows the language saved to your Gold Life ID. Your choice here applies in this app only. Money and dates always use your region.")
        )
        .mbSystemBanners()
    }
}
